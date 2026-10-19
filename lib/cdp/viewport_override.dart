/// 目标页视口覆盖（Emulation.setDeviceMetricsOverride）。
///
/// 2026-10-19 用户需求：「自适应」不是把画面拉伸/缩放到远程端舞台，
/// 而是让 Codex 页面内部视口跟随远程舞台尺寸——内容真正重排、原生
/// 填满、不模糊不变形。实现为远程端把舞台 CSS 尺寸经 ctrl
/// `setViewport` 回传，宿主对当前会话页面应用设备指标覆盖（不改
/// 本机真实窗口大小）；会话停止时清除覆盖恢复原视口。
library;

import 'cdp_client.dart';

/// 视口尺寸的合法范围（防御远程端异常值）。
const int kViewportMin = 64;
const int kViewportMaxWidth = 7680;
const int kViewportMaxHeight = 4320;

/// 从 setViewport 信封 data 解析并校验尺寸；非法返回 null。
({int width, int height})? parseViewportRequest(Object? data) {
  if (data is! Map) return null;
  final w = data['width'];
  final h = data['height'];
  if (w is! num || h is! num) return null;
  final width = w.round();
  final height = h.round();
  if (width < kViewportMin ||
      width > kViewportMaxWidth ||
      height < kViewportMin ||
      height > kViewportMaxHeight) {
    return null;
  }
  return (width: width, height: height);
}

/// 应用视口覆盖。deviceScaleFactor 固定 1：远程端按 CSS px 显示与
/// 映射输入，高倍率只会让编码帧变大、带宽变高。
Future<void> applyViewportOverride(CdpPage page, int width, int height) {
  return page.send('Emulation.setDeviceMetricsOverride', {
    'width': width,
    'height': height,
    'deviceScaleFactor': 1,
    'mobile': false,
  });
}

/// 清除视口覆盖（会话停止时恢复原视口）。best effort：页面可能已
/// 断开，调用方自行 catch。
Future<void> clearViewportOverride(CdpPage page) {
  return page.send('Emulation.clearDeviceMetricsOverride');
}
