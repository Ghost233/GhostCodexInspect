import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/bind_policy.dart';
import 'package:ghost_codex_inspect/relay/relay_server.dart';
import 'package:ghost_codex_inspect/relay/relay_token.dart';

void main() {
  group('访问令牌', () {
    test('每次生成为 128 bit 的 base64url 串且互不相同', () {
      final tokens = {for (var i = 0; i < 100; i++) RelayToken.generate()};
      expect(tokens.length, 100, reason: '100 次生成不应出现重复');
      for (final token in tokens) {
        // 16 字节 → base64url 22 字符（去 padding）。
        expect(token.length, 22);
        expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      }
    });

    test('令牌比较：相同接受、不同拒绝、长度不同也拒绝', () {
      final token = RelayToken.generate();
      expect(RelayToken.equals(token, token), isTrue);
      expect(RelayToken.equals(token, RelayToken.generate()), isFalse);
      expect(RelayToken.equals(token, '${token}x'), isFalse);
      expect(RelayToken.equals(token, token.substring(1)), isFalse);
      expect(RelayToken.equals(token, ''), isFalse);
    });
  });

  group('Origin/Host 校验（防 DNS rebinding）', () {
    const allowed = {'127.0.0.1', 'localhost'};

    test('绑定主机名与放行主机名一致时通过', () {
      expect(
        checkWebSocketHeaders(
          hostHeader: '127.0.0.1:8080',
          originHeader: 'http://127.0.0.1:8080',
          allowedHosts: allowed,
        ),
        isNull,
      );
      expect(
        checkWebSocketHeaders(
          hostHeader: 'localhost:9000',
          originHeader: 'http://localhost:9000',
          allowedHosts: allowed,
        ),
        isNull,
      );
    });

    test('非浏览器客户端（无 Origin）但 Host 合法时通过', () {
      expect(
        checkWebSocketHeaders(
          hostHeader: '127.0.0.1:8080',
          originHeader: null,
          allowedHosts: allowed,
        ),
        isNull,
      );
    });

    test('Host 头缺失或不在清单被拒绝', () {
      expect(
        checkWebSocketHeaders(
          hostHeader: null,
          originHeader: null,
          allowedHosts: allowed,
        ),
        isNotNull,
      );
      // DNS rebinding 场景：攻击域名解析到 127.0.0.1，Host 是攻击域名。
      expect(
        checkWebSocketHeaders(
          hostHeader: 'evil.example.com:8080',
          originHeader: 'http://evil.example.com:8080',
          allowedHosts: allowed,
        ),
        isNotNull,
      );
    });

    test('跨站 Origin 被拒绝', () {
      expect(
        checkWebSocketHeaders(
          hostHeader: '127.0.0.1:8080',
          originHeader: 'https://attacker.example',
          allowedHosts: allowed,
        ),
        isNotNull,
      );
      // 非 http/https scheme 的 Origin 同样拒绝。
      expect(
        checkWebSocketHeaders(
          hostHeader: '127.0.0.1:8080',
          originHeader: 'file:///tmp/x',
          allowedHosts: allowed,
        ),
        isNotNull,
      );
    });
  });

  group('绑定地址选择', () {
    test('默认（局域网开关关闭）返回 127.0.0.1', () async {
      final address = await resolveBindAddress(allowLanAccess: false);
      expect(address, InternetAddress.loopbackIPv4);
      expect(address.isLoopback, isTrue);
    });

    test('纯选择逻辑：跳过回环与 IPv6，取第一个非回环 IPv4', () {
      final lan = InternetAddress('192.168.1.23');
      expect(pickLanAddress([InternetAddress.loopbackIPv4, lan]), lan);
      expect(
        pickLanAddress([InternetAddress('fe80::1'), InternetAddress('::1'), lan]),
        lan,
      );
    });

    test('纯选择逻辑：只有回环时返回 null（绝不退回 0.0.0.0）', () {
      expect(pickLanAddress([InternetAddress.loopbackIPv4]), isNull);
      expect(pickLanAddress(const []), isNull);
    });
  });
}
