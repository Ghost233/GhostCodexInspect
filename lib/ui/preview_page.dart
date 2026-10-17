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
  const PreviewPage({super.key, required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final relayRunning = controller.relayStatus.running;
        final sessionActive = controller.sessionKind != SessionKind.none;
        final url = controller.previewUrl?.toString();
        return PageScaffold(
          title: '远程视图',
          actions: [
            if (url != null) CopyButton(text: url, label: '复制预览地址'),
          ],
          children: [
            SectionCard(
              title: '本机只读预览',
              trailing: Row(
                children: [
                  const StatusChip(label: '只读 ro=1', tone: StatusTone.neutral),
                  const SizedBox(width: 8),
                  StatusChip(
                    label: controller.sessionKind.label,
                    tone: sessionActive ? StatusTone.success : StatusTone.neutral,
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
                  else
                    Text(
                      '输入只放远程端：此预览以只读参数加载，不捕获键鼠。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (url != null) _PreviewWebView(url: url, enabled: sessionActive),
          ].whereType<Widget>().toList(),
        );
      },
    );
  }
}

class _PreviewWebView extends StatelessWidget {
  const _PreviewWebView({required this.url, required this.enabled});

  final String url;
  final bool enabled;

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
      child: enabled
          ? InAppWebView(
              key: ValueKey(url),
              initialUrlRequest: URLRequest(url: WebUri(url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: true,
              ),
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.monitor_outlined,
                    size: 32,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '等待中继会话启动',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
    );
  }
}
