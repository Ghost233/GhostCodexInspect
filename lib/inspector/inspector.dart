/// 检查器（Inspector）模块：目标应用可注入性验证与 CDP 连接健康状况。
///
/// 实现工单：#10（核心逻辑）与 #4（真机实测依据）。
/// 本文件是薄壳：把启动器模块的检测/前提校验与 CDP 模块的 attach 组合成
/// 一份检查报告，供控制面 UI 消费；界面逻辑留待检查器界面工单充实。
library;

import '../cdp/cdp.dart';
import '../launcher/launcher.dart';

/// 检查器对目标应用的一次完整检查报告。
class InspectorReport {
  const InspectorReport({
    required this.preflight,
    this.connection,
    this.shellTarget,
    this.shellTitle,
    this.error,
  });

  /// 前提校验报告（bundle 结构层面）。
  final PreflightReport preflight;

  /// CDP attach 结果（前提校验通过且目标在运行时才非空）。
  final CdpConnection? connection;

  /// 命中的 shell 页面 target。
  final CdpTargetInfo? shellTarget;

  /// 经 `Runtime.evaluate` 读回的 `document.title`（健康探针）。
  final String? shellTitle;

  /// 检查过程中的异常（非致命，记录供诊断）。
  final Object? error;

  /// 全链路健康：前提校验通过且 CDP attach + shell 枚举 + evaluate 成功。
  bool get healthy =>
      preflight.passed &&
      connection != null &&
      shellTarget != null &&
      error == null;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('InspectorReport(${preflight.profile.id}): healthy=$healthy')
      ..writeln('  preflight: ${preflight.passed ? 'PASSED' : 'FAILED'}');
    for (final check in preflight.checks) {
      buffer.writeln('    $check');
    }
    if (connection != null) {
      buffer.writeln(
        '  cdp: ${connection!.implementationName}'
        '${connection!.fellBack ? '（回退，原因：${connection!.puppeteerError}）' : ''}',
      );
    }
    if (shellTarget != null) buffer.writeln('  shell: $shellTarget');
    if (shellTitle != null) buffer.writeln('  document.title: $shellTitle');
    if (error != null) buffer.writeln('  error: $error');
    return buffer.toString();
  }
}

/// 检查器：组合前提校验与 CDP 健康探针。
class Inspector {
  Inspector({this._detector = const TargetDetector()});

  final TargetDetector _detector;

  /// 仅做结构层面的前提校验（不要求目标在运行）。
  Future<PreflightReport> checkPreflight(TargetProfile profile) =>
      _detector.preflight(profile);

  /// CDP 健康探针：attach 调试端口、枚举 target、过滤 shell、读回标题。
  ///
  /// 前提是目标应用已带调试端口运行；失败时异常进 [InspectorReport.error]。
  /// 返回前会断开 CDP 连接（探针不持有长连接）。
  Future<InspectorReport> probe(
    TargetProfile profile, {
    int? debugPort,
    bool preferRaw = false,
  }) async {
    final preflight = await _detector.preflight(profile);
    if (!preflight.passed) {
      return InspectorReport(preflight: preflight, error: '前提校验未通过');
    }
    CdpConnection? connection;
    try {
      connection = await connectCdp(
        debugPort: debugPort ?? profile.defaultDebugPort,
        preferRaw: preferRaw,
      );
      final targets = await connection.client.listTargets();
      final shell = findShellTarget(targets, profile.shellUrlSchemes);
      final page = await connection.client.attachTo(shell);
      final title = await page.evaluate('document.title');
      return InspectorReport(
        preflight: preflight,
        connection: connection,
        shellTarget: shell,
        shellTitle: title as String?,
      );
    } on Object catch (error) {
      return InspectorReport(
        preflight: preflight,
        connection: connection,
        error: error,
      );
    } finally {
      await connection?.client.close();
    }
  }
}
