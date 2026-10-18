/// 目标应用检测与前提校验（Preflight Check）。
///
/// 校验目标应用是否为可被 CDP 接管的 Electron 应用：
/// 主判据为 `Contents/Frameworks/` 下的 Electron 框架（适配重命名，
/// 见 [TargetProfile.frameworkNames]），辅助判据为 NSPrincipalClass 与
/// Resources 下的 asar 载荷；同时记录版本、bundle id 与签名状态。
///
/// 术语见根目录 GLOSSARY.md（目标应用、前提校验、加固）。
library;

import 'dart:convert';
import 'dart:io';

import 'target_profile.dart';

/// 单项前提校验结果。
class PreflightCheck {
  const PreflightCheck({
    required this.name,
    required this.passed,
    required this.detail,
    this.fatal = true,
  });

  /// 检查项名称（如 `electron-framework`）。
  final String name;

  /// 是否通过。
  final bool passed;

  /// 人类可读细节（实测值、路径或失败原因）。
  final String detail;

  /// 未通过时是否导致前提校验整体失败（辅助判据可为 false 仅告警）。
  final bool fatal;

  @override
  String toString() =>
      '[${passed ? 'PASS' : (fatal ? 'FAIL' : 'WARN')}] $name: $detail';
}

/// 目标应用签名校验状态（`codesign -dv` 解析结果）。
class SignatureStatus {
  const SignatureStatus({
    required this.checked,
    this.teamId,
    this.authority,
    this.hardenedRuntime = false,
    this.error,
  });

  /// 未执行校验（非 macOS 或进程执行失败）。
  const SignatureStatus.unchecked([String? reason])
    : checked = false,
      teamId = null,
      authority = null,
      hardenedRuntime = false,
      error = reason;

  /// 是否成功执行了解析。
  final bool checked;
  final String? teamId;
  final String? authority;

  /// 是否带 hardened runtime（加固手段之一，见 GLOSSARY「加固」）。
  final bool hardenedRuntime;
  final String? error;

  /// 从 `codesign -dv --verbose=4` 的 stderr 文本解析签名状态。
  static SignatureStatus parse(String codesignOutput) {
    String? pick(String key) {
      final match = RegExp(
        '^$key=(.*)\$',
        multiLine: true,
      ).firstMatch(codesignOutput);
      return match?.group(1)?.trim();
    }

    // flags 出现在 `CodeDirectory ... flags=0x10000(runtime) ...` 行中间，
    // 不能用行首锚定；单独提取括号内的 flag 描述。
    final flagsDesc =
        RegExp(r'flags=0x[0-9a-fA-F]+\(([^)]*)\)')
            .firstMatch(codesignOutput)
            ?.group(1) ??
        '';
    return SignatureStatus(
      checked: true,
      teamId: pick('TeamIdentifier'),
      authority: pick('Authority'),
      hardenedRuntime: flagsDesc
          .split(',')
          .map((f) => f.trim())
          .contains('runtime'),
    );
  }
}

/// 对目标应用 bundle 的一次完整勘察结果。
class TargetInspection {
  const TargetInspection({
    required this.bundleExists,
    this.frameworkPath,
    this.principalClass,
    this.asarPaths = const [],
    this.bundleId,
    this.version,
    this.buildNumber,
    this.executablePath,
    this.signature = const SignatureStatus.unchecked(),
  });

  /// `.app` bundle 是否存在。
  final bool bundleExists;

  /// 命中的 Electron 框架路径（`Contents/Frameworks/<name>.framework`）。
  final String? frameworkPath;

  /// Info.plist 的 NSPrincipalClass 实测值。
  final String? principalClass;

  /// Resources 下发现的 `*.asar` 文件名列表。
  final List<String> asarPaths;

  /// Info.plist 的 CFBundleIdentifier 实测值。
  final String? bundleId;

  /// CFBundleShortVersionString。
  final String? version;

  /// CFBundleVersion。
  final String? buildNumber;

  /// 主可执行文件路径（`Contents/MacOS/<CFBundleExecutable>`）。
  final String? executablePath;

  /// 签名校验状态。
  final SignatureStatus signature;
}

/// 前提校验报告。
class PreflightReport {
  const PreflightReport({
    required this.profile,
    required this.inspection,
    required this.checks,
  });

  final TargetProfile profile;
  final TargetInspection inspection;
  final List<PreflightCheck> checks;

  /// 全部致命检查均通过：CDP 路线在结构层面可行。
  ///（是否拦截调试参数仍需实测，见 GLOSSARY「前提校验」。）
  bool get passed => checks.every((c) => c.passed || !c.fatal);

  @override
  String toString() =>
      'PreflightReport(${profile.id}: ${passed ? 'PASSED' : 'FAILED'}\n  ${checks.join('\n  ')})';
}

/// 读取 Info.plist 单个键的可注入函数（默认实现走 `plutil`）。
typedef PlistValueReader = Future<String?> Function(
  String plistPath,
  String key,
);

/// 执行 `codesign -dv` 的可注入函数（返回其 stderr 文本）。
typedef CodesignRunner = Future<String?> Function(String appPath);

/// 默认 plist 读取：`plutil -extract <key> raw`。
Future<String?> plutilRead(String plistPath, String key) async {
  try {
    final result = await Process.run('plutil', [
      '-extract',
      key,
      'raw',
      '-o',
      '-',
      plistPath,
    ]);
    if (result.exitCode != 0) return null;
    final value = '${result.stdout}'.trim();
    return value.isEmpty ? null : value;
  } on ProcessException {
    return null;
  }
}

/// 默认签名执行：`codesign -dv --verbose=4`（输出在 stderr）。
Future<String?> runCodesign(String appPath) async {
  try {
    final result = await Process.run('codesign', [
      '-dv',
      '--verbose=4',
      appPath,
    ]);
    final output = '${result.stderr}';
    return output.isEmpty ? null : output;
  } on ProcessException {
    return null;
  }
}

/// 目标应用检测器：勘察 bundle 并给出前提校验报告。
class TargetDetector {
  const TargetDetector({
    this.plistReader = plutilRead,
    this.codesignRunner = runCodesign,
  });

  final PlistValueReader plistReader;
  final CodesignRunner codesignRunner;

  /// 勘察目标应用 bundle（不做通过/失败判断）。
  Future<TargetInspection> inspect(TargetProfile profile) async {
    final appDir = Directory(profile.appPath);
    if (!appDir.existsSync()) {
      return const TargetInspection(bundleExists: false);
    }

    final plistPath = '${profile.appPath}/Contents/Info.plist';
    final principalClass = await plistReader(plistPath, 'NSPrincipalClass');
    final bundleId = await plistReader(plistPath, 'CFBundleIdentifier');
    final version = await plistReader(plistPath, 'CFBundleShortVersionString');
    final buildNumber = await plistReader(plistPath, 'CFBundleVersion');
    final executableName = await plistReader(plistPath, 'CFBundleExecutable');

    // 框架判据：按候选顺序命中第一个存在的 <name>.framework。
    String? frameworkPath;
    for (final name in profile.frameworkNames) {
      final candidate =
          '${profile.appPath}/Contents/Frameworks/$name.framework';
      if (Directory(candidate).existsSync()) {
        frameworkPath = candidate;
        break;
      }
    }

    // asar 判据：Resources 下任意 *.asar。
    final resourcesDir = Directory('${profile.appPath}/Contents/Resources');
    final asarPaths = <String>[];
    if (resourcesDir.existsSync()) {
      for (final entity in resourcesDir.listSync()) {
        if (entity is File && entity.path.endsWith('.asar')) {
          asarPaths.add(entity.uri.pathSegments.last);
        }
      }
    }

    final executablePath =
        profile.executablePathOverride ??
        (executableName == null
            ? null
            : '${profile.appPath}/Contents/MacOS/$executableName');

    final codesignOutput = await codesignRunner(profile.appPath);
    final signature = codesignOutput == null
        ? const SignatureStatus.unchecked('codesign 执行失败或不可用')
        : SignatureStatus.parse(codesignOutput);

    return TargetInspection(
      bundleExists: true,
      frameworkPath: frameworkPath,
      principalClass: principalClass,
      asarPaths: asarPaths,
      bundleId: bundleId,
      version: version,
      buildNumber: buildNumber,
      executablePath: executablePath,
      signature: signature,
    );
  }

  /// 前提校验：基于勘察结果逐条判定。
  Future<PreflightReport> preflight(TargetProfile profile) async {
    final inspection = await inspect(profile);
    final checks = <PreflightCheck>[];

    checks.add(
      PreflightCheck(
        name: 'bundle-exists',
        passed: inspection.bundleExists,
        detail: inspection.bundleExists
            ? profile.appPath
            : '目标应用不存在：${profile.appPath}',
      ),
    );
    if (!inspection.bundleExists) {
      return PreflightReport(
        profile: profile,
        inspection: inspection,
        checks: checks,
      );
    }

    checks.add(
      PreflightCheck(
        name: 'electron-framework',
        passed: inspection.frameworkPath != null,
        detail: inspection.frameworkPath != null
            ? '命中框架：${inspection.frameworkPath}'
            : '未找到 Electron 框架（候选：${profile.frameworkNames.join(', ')}）',
      ),
    );

    final expectedPrincipal = profile.expectedPrincipalClass;
    if (expectedPrincipal == null) {
      checks.add(
        PreflightCheck(
          name: 'principal-class',
          passed: true,
          fatal: false,
          detail:
              'NSPrincipalClass=${inspection.principalClass ?? '(缺失)'}（仅记录）',
        ),
      );
    } else {
      checks.add(
        PreflightCheck(
          name: 'principal-class',
          passed: inspection.principalClass == expectedPrincipal,
          fatal: false,
          detail:
              'NSPrincipalClass=${inspection.principalClass ?? '(缺失)'}，期望 $expectedPrincipal',
        ),
      );
    }

    final expectedAsar = profile.expectedAsarName;
    final asarHit = expectedAsar == null
        ? inspection.asarPaths.isNotEmpty
        : inspection.asarPaths.contains(expectedAsar);
    checks.add(
      PreflightCheck(
        name: 'asar-payload',
        passed: asarHit,
        detail: inspection.asarPaths.isEmpty
            ? 'Resources 下未发现 asar 载荷'
            : '发现 asar：${inspection.asarPaths.join(', ')}'
                  '${expectedAsar == null ? '' : '（期望 $expectedAsar）'}',
      ),
    );

    checks.add(
      PreflightCheck(
        name: 'bundle-id',
        passed: inspection.bundleId == profile.bundleId,
        fatal: false,
        detail:
            'CFBundleIdentifier=${inspection.bundleId ?? '(缺失)'}，期望 ${profile.bundleId}',
      ),
    );

    final sig = inspection.signature;
    checks.add(
      PreflightCheck(
        name: 'signature',
        passed: sig.checked,
        fatal: false,
        detail: sig.checked
            ? 'TeamID=${sig.teamId ?? '?'}，hardened runtime=${sig.hardenedRuntime}'
            : '签名状态未解析：${sig.error ?? '未知原因'}',
      ),
    );

    return PreflightReport(
      profile: profile,
      inspection: inspection,
      checks: checks,
    );
  }
}

/// 供测试与调试使用的 JSON 序列化。
extension PreflightReportJson on PreflightReport {
  Map<String, Object?> toJson() => {
    'profile': profile.id,
    'passed': passed,
    'inspection': {
      'bundleExists': inspection.bundleExists,
      'frameworkPath': inspection.frameworkPath,
      'principalClass': inspection.principalClass,
      'asarPaths': inspection.asarPaths,
      'bundleId': inspection.bundleId,
      'version': inspection.version,
      'buildNumber': inspection.buildNumber,
      'executablePath': inspection.executablePath,
      'signature': {
        'checked': inspection.signature.checked,
        'teamId': inspection.signature.teamId,
        'hardenedRuntime': inspection.signature.hardenedRuntime,
      },
    },
    'checks': [
      for (final c in checks)
        {
          'name': c.name,
          'passed': c.passed,
          'fatal': c.fatal,
          'detail': c.detail,
        },
    ],
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
