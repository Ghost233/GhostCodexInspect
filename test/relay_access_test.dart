import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';

void main() {
  late RelayServer server;
  late HttpClient http;
  const key = 'test-access-key';
  const token = 'fixed-test-token';

  setUp(() async {
    server = RelayServer();
    await server.start(accessKey: key, fixedToken: token);
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  Future<HttpClientResponse> login(String value) async {
    final request = await http.postUrl(url('auth'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'key': value}));
    return request.close();
  }

  Future<String> sessionCookie() async {
    final response = await login(key);
    expect(response.statusCode, HttpStatus.ok);
    final cookie = response.cookies.single;
    expect(cookie.httpOnly, isTrue);
    expect(cookie.sameSite, SameSite.strict);
    await response.drain<void>();
    return '${cookie.name}=${cookie.value}';
  }

  Future<WebSocket> connect(String cookie) => WebSocket.connect(
    url('ws').replace(scheme: 'ws').toString(),
    headers: {'Cookie': cookie},
  );

  void auth(WebSocket socket, String value) => socket.add(
    RelayEnvelope(
      channel: RelayChannel.ctrl,
      type: RelayMessageType.auth,
      seq: 0,
      data: {'token': value},
    ).encode(),
  );

  test('登录前仅显示密钥页面，静态资源与 WebSocket 均受保护', () async {
    final response = await (await http.getUrl(url(''))).close();
    expect(response.statusCode, HttpStatus.ok);
    final body = await response.transform(utf8.decoder).join();
    expect(body, contains('访问密钥'));
    expect(body, isNot(contains('id="stage-dom"')));

    final script = await (await http.getUrl(url('js/app.js'))).close();
    expect(script.statusCode, HttpStatus.unauthorized);
    await script.drain<void>();
    await expectLater(connect(''), throwsA(isA<WebSocketException>()));
  });

  test('错误密钥不发 cookie，正确密钥才允许进入远程页面', () async {
    final wrong = await login('wrong-key');
    expect(wrong.statusCode, HttpStatus.unauthorized);
    expect(wrong.cookies, isEmpty);
    await wrong.drain<void>();

    final cookie = await sessionCookie();
    final request = await http.getUrl(url(''));
    request.headers.set(HttpHeaders.cookieHeader, cookie);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(
      await response.transform(utf8.decoder).join(),
      contains('id="stage-dom"'),
    );
  });

  test('通过密钥后仍须正确 token，轮转踢掉旧连接并使旧登录失效', () async {
    final cookie = await sessionCookie();
    final wrong = await connect(cookie);
    auth(wrong, 'wrong-token');
    expect(
      RelayEnvelope.decode(await wrong.first as String).type,
      RelayMessageType.authErr,
    );
    await wrong.close();

    final socket = await connect(cookie);
    final messages = socket.asBroadcastStream();
    final reply = messages.first;
    auth(socket, token);
    expect(
      RelayEnvelope.decode(await reply as String).type,
      RelayMessageType.authOk,
    );
    final closed = messages.drain<void>();
    await server.rotateToken();
    await closed.timeout(const Duration(seconds: 5));
    expect(server.token, isNot(token));
    expect(server.clientCount, 0);
    await expectLater(connect(cookie), throwsA(isA<WebSocketException>()));

    final fresh = await connect(await sessionCookie());
    auth(fresh, token);
    expect(
      RelayEnvelope.decode(await fresh.first as String).type,
      RelayMessageType.authErr,
    );
    await fresh.close();
  });

  test('固定 token 跨中转重启保持一致，访问密钥修改立即撤销旧登录', () async {
    final cookie = await sessionCookie();
    await server.setAccessKey('replacement-key');
    await expectLater(connect(cookie), throwsA(isA<WebSocketException>()));
    final oldKey = await login(key);
    expect(oldKey.statusCode, HttpStatus.unauthorized);
    await oldKey.drain<void>();
    await server.stop();
    await server.start(accessKey: key, fixedToken: token);
    expect(server.token, token);
  });

  test('远程访问监听所有 IPv4 接口，复制链接使用可访问地址', () async {
    await server.stop();
    await server.start(allowLanAccess: true, accessKey: key);
    expect(server.bindAddress, InternetAddress.anyIPv4);
    expect(server.accessUrl!.host, isNot('0.0.0.0'));
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    );
    final hosts = server.accessUrls.map((url) => url.host).toList();
    expect(
      hosts,
      containsAll([
        '127.0.0.1',
        'localhost',
        ...interfaces.expand((i) => i.addresses).map((a) => a.address),
      ]),
    );
    expect(hosts, isNot(contains('0.0.0.0')));
    expect(hosts.toSet(), hasLength(hosts.length));
    expect(
      server.accessUrls.every(
        (url) => url.port == server.port && url.fragment == 't=${server.token}',
      ),
      isTrue,
    );
    await server.rotateToken();
    expect(
      server.accessUrls.every((url) => url.fragment == 't=${server.token}'),
      isTrue,
    );
    await server.stop();
    expect(server.accessUrls, isEmpty);
  });

  test('仅本机监听时不列出其他网卡地址', () {
    expect(server.accessUrls.map((url) => url.host), [
      '127.0.0.1',
      'localhost',
    ]);
  });
}
