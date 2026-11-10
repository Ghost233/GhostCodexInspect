import 'dart:async';

import 'cdp_client.dart';
import 'cdp_connector.dart';

/// 通过 Codex 自有的新建窗口入口创建主页面，不复用辅助窗口。
Future<CdpTargetInfo> createCodexRemoteWindow(
  CdpClient client,
  List<String> shellUrlSchemes,
) async {
  final before = await client.listTargets();
  final existingIds = before.map((t) => t.id).toSet();
  final source = findShellTarget(before, shellUrlSchemes);
  final page = await client.attachTo(source);
  try {
    final result = await page
        .send('Runtime.evaluate', {
          'expression': '''(async () => {
        if (typeof window.electronBridge?.sendMessageFromView !== 'function') {
          throw new Error('当前客户端不支持新建远程窗口');
        }
        await window.electronBridge.sendMessageFromView({type: 'open-in-new-window', path: '/'});
        return true;
      })()''',
          'awaitPromise': true,
          'returnByValue': true,
        })
        .timeout(const Duration(seconds: 15));
    if (result['exceptionDetails'] != null ||
        (result['result'] as Map?)?['value'] != true) {
      throw StateError('新建远程窗口失败：当前 Codex 未完成新建窗口请求');
    }
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 15)) {
      final created = (await client.listTargets())
          .where(
            (t) =>
                isPrimaryShellTarget(t, shellUrlSchemes) &&
                !existingIds.contains(t.id),
          )
          .toList();
      if (created.length > 1) {
        throw StateError('同时出现多个新窗口，无法确定远程窗口，请避免同时新建窗口后重试');
      }
      if (created.length == 1) {
        // 原生入口会激活新窗口，创建完后把原窗口放回前面。
        await page.send('Page.bringToFront');
        return created.single;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('等待远程窗口创建超时，请检查 Codex 客户端');
  } finally {
    await page.close();
  }
}
