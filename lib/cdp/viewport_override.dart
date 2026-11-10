/// 目标页视口覆盖（Emulation.setDeviceMetricsOverride）。
///
/// 2026-10-19 用户需求：「自适应」不是把画面拉伸/缩放到远程端舞台，
/// 而是让 Codex 页面内部视口跟随远程舞台尺寸——内容真正重排、原生
/// 填满、不模糊不变形。实现为远程端把舞台 CSS 尺寸经 ctrl
/// `setViewport` 回传，宿主对当前会话页面应用设备指标覆盖（不改
/// 本机真实窗口大小）；会话停止时清除覆盖恢复原视口。
library;

import 'cdp_client.dart';

/// 渲染画面的像素范围；缩小时逻辑视口可扩大，实际输出仍受此限制。
const int kViewportMin = 64;
const int kViewportMaxWidth = 7680;
const int kViewportMaxHeight = 4320;

/// 从 setViewport 信封 data 解析并校验尺寸；非法返回 null。
({int width, int height, double deviceScaleFactor})? parseViewportRequest(
  Object? data,
) {
  if (data is! Map) return null;
  final w = data['width'];
  final h = data['height'];
  final scale = data['deviceScaleFactor'] ?? 1;
  if (w is! num ||
      h is! num ||
      !w.isFinite ||
      !h.isFinite ||
      scale is! num ||
      !scale.isFinite ||
      scale < 0.1 ||
      scale > 8) {
    return null;
  }
  final width = w.round();
  final height = h.round();
  if (width < kViewportMin ||
      width * scale > kViewportMaxWidth ||
      height < kViewportMin ||
      height * scale > kViewportMaxHeight) {
    return null;
  }
  return (width: width, height: height, deviceScaleFactor: scale.toDouble());
}

/// 应用视口覆盖：CSS 逻辑尺寸决定布局，像素比例限制渲染输出。
Future<void> applyViewportOverride(
  CdpPage page,
  int width,
  int height, {
  double deviceScaleFactor = 1,
  double? nativeDeviceScaleFactor,
}) async {
  await page.send('Emulation.setDeviceMetricsOverride', {
    'width': width,
    'height': height,
    'deviceScaleFactor': deviceScaleFactor,
    'mobile': false,
    if (nativeDeviceScaleFactor != null) ...{
      'scale': 1,
      'dontSetVisibleSize': true,
    },
  });
  if (nativeDeviceScaleFactor != null) {
    // Chromium 实时采集取原生表面；让表面容纳手机要求的实际像素。
    await page.send('Emulation.setVisibleSize', {
      'width': (width * deviceScaleFactor / nativeDeviceScaleFactor).ceil(),
      'height': (height * deviceScaleFactor / nativeDeviceScaleFactor).ceil(),
    });
  }
}

/// 清除视口覆盖（会话停止时恢复原视口）。best effort：页面可能已
/// 断开，调用方自行 catch。
Future<void> clearViewportOverride(CdpPage page) {
  return page.send('Emulation.clearDeviceMetricsOverride');
}
