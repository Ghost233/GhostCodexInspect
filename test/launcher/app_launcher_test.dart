import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';

void main() {
  group('AppLauncher.isDebugPortAlive（端口预检，工单 #14）', () {
    test('端口上有 CDP 端点（/json/version 200）时返回 true', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..statusCode = 200
          ..write('{"Browser":"fake"}')
          ..close();
      });
      expect(await AppLauncher().isDebugPortAlive(server.port), isTrue);
    });

    test('端口未被占用时返回 false', () async {
      // 先借一个端口再释放，拿到一个几乎必然空闲的端口号。
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();
      expect(await AppLauncher().isDebugPortAlive(freePort), isFalse);
    });
  });
}
