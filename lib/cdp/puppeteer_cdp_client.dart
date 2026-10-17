/// CDP 客户端优先实现：puppeteer Dart 包。
///
/// 只用 `puppeteer.connect` attach 到目标应用调试端口，不使用其浏览器
/// 下载/拉起功能（见 docs/research/host-backend.md）。
library;

import 'dart:async';

import 'package:puppeteer/puppeteer.dart' as pp;

import 'cdp_client.dart';

/// puppeteer 版 [CdpClient]。
class PuppeteerCdpClient implements CdpClient {
  PuppeteerCdpClient({required this.debugPort, this.host = '127.0.0.1'});

  /// 目标应用调试端口。
  final int debugPort;
  final String host;

  pp.Browser? _browser;

  @override
  String get implementationName => 'puppeteer';

  pp.Browser get _requireBrowser {
    final browser = _browser;
    if (browser == null) {
      throw StateError('尚未 connect() 到调试端口 $host:$debugPort');
    }
    return browser;
  }

  @override
  Future<void> connect() async {
    _browser = await pp.puppeteer.connect(browserUrl: 'http://$host:$debugPort');
  }

  @override
  Future<List<CdpTargetInfo>> listTargets() async {
    return [
      for (final target in _requireBrowser.targets)
        CdpTargetInfo(
          id: target.targetInfo.targetId.value,
          type: target.type,
          url: target.url,
          title: target.targetInfo.title,
        ),
    ];
  }

  @override
  Future<CdpPage> attachTo(CdpTargetInfo target) async {
    final native = _requireBrowser.targets.firstWhere(
      (t) => t.targetInfo.targetId.value == target.id,
      orElse: () => throw StateError('target 已消失：${target.id}'),
    );
    return PuppeteerCdpPage(target, await native.page);
  }

  @override
  Future<void> close() async {
    // disconnect 而非 close：不杀目标应用进程，仅断开 CDP 连接。
    _browser?.disconnect();
    _browser = null;
  }
}

class PuppeteerCdpPage implements CdpPage {
  PuppeteerCdpPage(this.target, this._page);

  @override
  final CdpTargetInfo target;

  final pp.Page _page;

  @override
  Future<Object?> evaluate(String expression) =>
      _page.evaluate<Object?>(expression);

  @override
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final result = await _page.devTools.client.send(method, params);
    return result;
  }

  @override
  Future<Stream<String>> exposeBinding(String name) async {
    // puppeteer 的 exposeFunction 内部即 Runtime.addBinding + 跨导航重装
    // （binding 在 addScriptToEvaluateOnNewDocument 注入的脚本中同样可用）。
    // 采集器约定单参数 JSON 字符串，这里只取第一个参数。
    final controller = StreamController<String>();
    await _page.exposeFunction(name, (String payload) {
      if (!controller.isClosed) controller.add(payload);
    });
    return controller.stream;
  }

  @override
  Future<void> close() async {
    // 仅释放 puppeteer 侧会话，不关闭目标应用页面。
  }
}
