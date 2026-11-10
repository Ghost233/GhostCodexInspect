// 双窗口真实 Electron 回归：连接不改窗口，视口覆盖仅作用于选中页。
// 运行：dart run tool/verify_window_isolation.dart
// 需先在 tool/fixture 安装锁定的 Electron 依赖；使用独立端口与临时配置。
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/cdp/raw_cdp_client.dart';
import 'package:ghost_codex_inspect/cdp/puppeteer_cdp_client.dart';
import 'package:ghost_codex_inspect/cdp/viewport_override.dart';

Future<void> main(List<String> args) async {
  final root = args.isEmpty ? Directory.current.path : args.single;
  final fixture = '$root/tool/fixture';
  final profile = await Directory.systemTemp.createTemp(
    'gci-window-isolation-',
  );
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port;
  await reservation.close();
  final process = await Process.start(
    '$fixture/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron',
    [
      fixture,
      '--remote-debugging-port=$port',
      '--gci-second-window',
      '--user-data-dir=${profile.path}',
    ],
    workingDirectory: fixture,
  );
  final output = process.stdout.drain<void>();
  final errors = process.stderr.drain<void>();
  final raw = RawCdpClient(debugPort: port);
  final puppeteer = PuppeteerCdpClient(debugPort: port);
  try {
    List<CdpTargetInfo> targets = [];
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await raw.connect();
        targets = (await raw.listTargets())
            .where(
              (target) =>
                  target.type == 'page' && target.url.startsWith('file:'),
            )
            .toList();
        if (targets.length == 2) {
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (targets.length != 2) {
      throw StateError('Two isolated fixture windows did not become ready');
    }
    final pages = <CdpPage>[];
    for (final target in targets) {
      pages.add(await raw.attachTo(target));
    }
    Future<List<Object?>> sizes() async => [
      for (final page in pages)
        jsonDecode(
          await page.evaluate(
            'JSON.stringify({width:innerWidth,height:innerHeight})',
          ) as String,
        ),
    ];
    final before = await sizes();
    await puppeteer.connect();
    final connected = await sizes();
    stdout.writeln(jsonEncode({'before': before, 'afterConnect': connected}));
    if (jsonEncode(connected) != jsonEncode(before)) {
      throw StateError(
        'Connecting the production client resized unselected native windows',
      );
    }
    final selected = await puppeteer.attachTo(targets.last);
    await applyViewportOverride(selected, 640, 480);
    final during = await sizes();
    stdout.writeln(
      jsonEncode({'selected': targets.last.id, 'duringRemoteOverride': during}),
    );
    if (jsonEncode(during.first) != jsonEncode(before.first)) {
      throw StateError('Remote viewport changed the local window');
    }
    if (jsonEncode(during.last) != jsonEncode({'width': 640, 'height': 480})) {
      throw StateError(
        'Remote viewport did not follow its own requested dimensions',
      );
    }
    await clearViewportOverride(selected);
    final restored = await sizes();
    if (jsonEncode(restored) != jsonEncode(before)) {
      throw StateError('Viewport cleanup did not restore the selected window');
    }
    stdout.writeln(
      'PASS: connection and selected viewport preserve the other native window',
    );
  } finally {
    await puppeteer.close();
    await raw.close();
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 5));
    await output;
    await errors;
    await profile.delete(recursive: true);
  }
}
