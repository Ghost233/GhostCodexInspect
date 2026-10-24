/// 远程视图页面（工单 #13）：本机只读预览，内嵌 WebView 加载中转伺服
/// 地址（带 token + ro=1 只读参数）。
///
/// 输入只放远程端：预览一律带 ro=1，远程端识别后跳过输入捕获层
///（双向防御：本机不捕获输入，目标侧仍照常处理远程端输入）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'home_shell.dart';
import 'host_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class PreviewPage extends StatelessWidget {
  const PreviewPage({super.key, required this.controller, this.active = false});

  final HostController controller;

  /// 当前页是否被选中显示。
  ///
  /// 2026-10-25 用户反馈修复：外壳用 IndexedStack 急切构建全部页面，
  /// 之前只要中转运行 + 会话启动，内嵌 WebView 就会以当前 token 自动
  /// 连上中转 —— 表现为「没人打开远程端却有一个 client 连上，并立刻
  /// 开始编码」。预览只在页面真正可见时才加载。
  final bool active;

  /// 预览是否应挂载 WebView（纯函数，回归测试锚点）。
  ///
  /// 三个条件同时满足才加载：页面可见（[active]）、会话运行中、有访问
  /// 链接。缺一不可——尤其 [active]，防止后台自动连接中转。
  @visibleForTesting
  static bool shouldLoadPreview({
    required bool active,
    required bool sessionActive,
    required Uri? url,
  }) => active && sessionActive && url != null;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final relayRunning = controller.relayStatus.running;
        final sessionActive = controller.sessionKind != SessionKind.none;
        final url = controller.previewUrl?.toString();
        final showPreview = shouldLoadPreview(
          active: active,
          sessionActive: sessionActive,
          url: url == null ? null : Uri.parse(url),
        );
        return PageScaffold(
          title: '远程视图',
          actions: [if (url != null) CopyButton(text: url, label: '复制预览地址')],
          children: [
            SectionCard(
              title: '本机只读预览',
              trailing: Row(
                children: [
                  const StatusChip(label: '只读 ro=1', tone: StatusTone.neutral),
                  const SizedBox(width: 8),
                  StatusChip(
                    label: controller.sessionKind.label,
                    tone: sessionActive
                        ? StatusTone.success
                        : StatusTone.neutral,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!relayRunning)
                    Text(
                      '中转未运行。到「中转台」启动中转后，这里会内嵌加载远程端单页。',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else if (!sessionActive)
                    Text(
                      '中转运行中，但中继会话未启动。到「中转台」启动 '
                      'DOM 重绘或画面流模式后可预览。',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else if (!active)
                    Text(
                      '预览未加载：切到本页时才连接中转（避免后台自动连接'
                      '占用编码资源）。',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Text(
                      '输入只放远程端：此预览以只读参数加载，不捕获键鼠。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (showPreview && url != null) _PreviewWebView(url: url),
          ].whereType<Widget>().toList(),
        );
      },
    );
  }
}

class _PreviewWebView extends StatelessWidget {
  const _PreviewWebView({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 520,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: .4),
        ),
      ),
      child: InAppWebView(
        key: ValueKey(url),
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: true,
        ),
      ),
    );
  }
}
