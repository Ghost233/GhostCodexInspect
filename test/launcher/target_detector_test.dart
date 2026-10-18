// 前提校验单元测试：用临时目录构造真假 .app 结构。
import 'dart:io';

import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在临时目录构造一个最小 .app bundle。
///
/// [frameworks]：要创建的 `Contents/Frameworks/<name>.framework` 列表。
/// [asars]：要创建的 `Contents/Resources/<name>` 列表。
/// [plistEntries]：写入 Info.plist 的键值（XML plist）。
Future<Directory> makeFakeApp(
  Directory parent,
  String name, {
  List<String> frameworks = const [],
  List<String> asars = const [],
  Map<String, String> plistEntries = const {},
}) async {
  final app = Directory('${parent.path}/$name.app');
  await Directory('${app.path}/Contents/Frameworks').create(recursive: true);
  await Directory('${app.path}/Contents/Resources').create(recursive: true);
  await Directory('${app.path}/Contents/MacOS').create(recursive: true);
  for (final framework in frameworks) {
    await Directory('${app.path}/Contents/Frameworks/$framework.framework')
        .create(recursive: true);
  }
  for (final asar in asars) {
    await File('${app.path}/Contents/Resources/$asar').writeAsString('fake');
  }
  final entries = plistEntries.entries
      .map((e) => '<key>${e.key}</key><string>${e.value}</string>')
      .join('\n    ');
  await File('${app.path}/Contents/Info.plist').writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    $entries
</dict>
</plist>
''');
  return app;
}

/// 测试用 profile：指向给定假 bundle，关闭真实签名执行。
TargetProfile testProfile(
  String appPath, {
  List<String> frameworkNames = const ['Codex Framework', 'Electron Framework'],
  String? expectedPrincipalClass = 'BrowserCrApplication',
  String? expectedAsarName = 'app.asar',
}) {
  return TargetProfile(
    id: 'test-target',
    displayName: '测试目标',
    bundleId: 'com.example.test',
    appPath: appPath,
    frameworkNames: frameworkNames,
    expectedPrincipalClass: expectedPrincipalClass,
    expectedAsarName: expectedAsarName,
    shellUrlSchemes: const ['app'],
  );
}

/// 测试用检测器：桩掉 codesign（临时假 bundle 无签名），plist 走真 plutil。
TargetDetector testDetector() =>
    TargetDetector(codesignRunner: (_) async => null);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gci_preflight_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('前提校验（临时目录假 .app）', () {
    test('重命名框架（Codex Framework）+ app.asar + 匹配 plist → 通过', () async {
      final app = await makeFakeApp(
        tempDir,
        'ChatGPT',
        frameworks: ['Codex Framework'],
        asars: ['app.asar'],
        plistEntries: {
          'CFBundleIdentifier': 'com.example.test',
          'CFBundleShortVersionString': '1.2.3',
          'CFBundleVersion': '456',
          'CFBundleExecutable': 'ChatGPT',
          'NSPrincipalClass': 'BrowserCrApplication',
        },
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isTrue, reason: report.toString());
      expect(
        report.inspection.frameworkPath,
        contains('Codex Framework.framework'),
      );
      expect(report.inspection.principalClass, 'BrowserCrApplication');
      expect(report.inspection.asarPaths, contains('app.asar'));
      expect(report.inspection.version, '1.2.3');
      expect(report.inspection.buildNumber, '456');
      expect(
        report.inspection.executablePath,
        endsWith('Contents/MacOS/ChatGPT'),
      );
    });

    test('标准 Electron Framework 回退判据命中 → 通过', () async {
      final app = await makeFakeApp(
        tempDir,
        'Stock',
        frameworks: ['Electron Framework'],
        asars: ['app.asar'],
        plistEntries: {
          'CFBundleIdentifier': 'com.example.test',
          'CFBundleExecutable': 'Stock',
          'NSPrincipalClass': 'BrowserCrApplication',
        },
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isTrue, reason: report.toString());
      expect(
        report.inspection.frameworkPath,
        contains('Electron Framework.framework'),
      );
    });

    test('任意 *.asar 均可满足未指定期望名的 asar 判据', () async {
      final app = await makeFakeApp(
        tempDir,
        'AnyAsar',
        frameworks: ['Electron Framework'],
        asars: ['default_app.asar'],
        plistEntries: {'CFBundleIdentifier': 'com.example.test'},
      );
      final report = await testDetector().preflight(
        testProfile(
          app.path,
          expectedPrincipalClass: null,
          expectedAsarName: null,
        ),
      );

      expect(report.passed, isTrue, reason: report.toString());
    });

    test('bundle 不存在 → 失败，且只有 bundle-exists 一项', () async {
      final missing = '${tempDir.path}/Missing.app';
      final report = await testDetector().preflight(testProfile(missing));

      expect(report.passed, isFalse);
      expect(report.checks, hasLength(1));
      expect(report.checks.single.name, 'bundle-exists');
      expect(report.inspection.bundleExists, isFalse);
    });

    test('缺少 Electron 框架 → 失败（electron-framework 致命）', () async {
      final app = await makeFakeApp(
        tempDir,
        'NoFramework',
        asars: ['app.asar'],
        plistEntries: {'CFBundleIdentifier': 'com.example.test'},
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isFalse);
      final check = report.checks.firstWhere(
        (c) => c.name == 'electron-framework',
      );
      expect(check.passed, isFalse);
      expect(check.fatal, isTrue);
    });

    test('缺少 asar 载荷 → 失败（asar-payload 致命）', () async {
      final app = await makeFakeApp(
        tempDir,
        'NoAsar',
        frameworks: ['Codex Framework'],
        plistEntries: {'CFBundleIdentifier': 'com.example.test'},
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isFalse);
      final check = report.checks.firstWhere((c) => c.name == 'asar-payload');
      expect(check.passed, isFalse);
    });

    test('期望 app.asar 但只有 default_app.asar → 失败', () async {
      final app = await makeFakeApp(
        tempDir,
        'WrongAsar',
        frameworks: ['Electron Framework'],
        asars: ['default_app.asar'],
        plistEntries: {'CFBundleIdentifier': 'com.example.test'},
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isFalse);
      final check = report.checks.firstWhere((c) => c.name == 'asar-payload');
      expect(check.passed, isFalse);
    });

    test('NSPrincipalClass 不匹配仅告警（非致命）', () async {
      final app = await makeFakeApp(
        tempDir,
        'Alien',
        frameworks: ['Codex Framework'],
        asars: ['app.asar'],
        plistEntries: {
          'CFBundleIdentifier': 'com.example.test',
          'NSPrincipalClass': 'NSApplication',
        },
      );
      final report = await testDetector().preflight(testProfile(app.path));

      expect(report.passed, isTrue, reason: report.toString());
      final check = report.checks.firstWhere(
        (c) => c.name == 'principal-class',
      );
      expect(check.passed, isFalse);
      expect(check.fatal, isFalse);
    });
  });

  group('SignatureStatus.parse', () {
    test('解析 hardened runtime 与 TeamID', () {
      // 真实 codesign -dv 输出：flags 嵌在 CodeDirectory 行中间。
      const output = '''
CodeDirectory v=20500 size=764 flags=0x10000(runtime) hashes=13+7 location=embedded
Executable=/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
Identifier=com.openai.codex
Authority=Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)
TeamIdentifier=2DC432GLL2
''';
      final status = SignatureStatus.parse(output);
      expect(status.checked, isTrue);
      expect(status.teamId, '2DC432GLL2');
      expect(status.hardenedRuntime, isTrue);
      expect(status.authority, contains('OpenAI'));
    });

    test('无 runtime flag 时 hardenedRuntime 为 false', () {
      const output =
          'CodeDirectory v=20400 size=100 flags=0x0(none)\nTeamIdentifier=ABCDE12345\n';
      final status = SignatureStatus.parse(output);
      expect(status.hardenedRuntime, isFalse);
    });
  });
}
