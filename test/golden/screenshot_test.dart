/// UI 验收截图生成（工单 #13，macos-ui-standards 验收）：golden 渲染
/// 四模块页面 × 浅/深主题，1280×800，真实字体（STHeiti + Menlo +
/// MaterialIcons）。
///
/// 生成：flutter test test/golden/screenshot_test.dart --update-goldens
/// 产物落在 docs/screenshots/ticket13/（随仓提交，作为验收记录）。
///
/// 注意：字体取自本机系统路径；缺字体的机器上整组 skip，不阻塞测试套件。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/ui/home_shell.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:ghost_codex_inspect/ui/theme.dart';

const _cjkFontPath = '/System/Library/Fonts/STHeiti Medium.ttc';
const _monoFontPath = '/System/Library/Fonts/Menlo.ttc';
const _iconsFontPath =
    '/Users/ghost233/flutter/bin/cache/artifacts/material_fonts/'
    'MaterialIcons-Regular.otf';

/// 主题与 MonoText 写死的 'Menlo' 对应的注册族名保持一致。
Future<bool> loadScreenshotFonts() async {
  if (!File(_cjkFontPath).existsSync() ||
      !File(_monoFontPath).existsSync() ||
      !File(_iconsFontPath).existsSync()) {
    return false;
  }
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family)
      ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
    await loader.load();
  }

  await load('GciCjk', _cjkFontPath);
  await load('Menlo', _monoFontPath);
  await load('MaterialIcons', _iconsFontPath);
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pages = ['launcher', 'inspector', 'relay', 'preview'];
  const tabs = ['启动器', '检查器', '中转台', '远程视图'];

  for (final brightness in Brightness.values) {
    for (var i = 0; i < pages.length; i++) {
      final themeName = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('screenshot ${pages[i]}-$themeName', (tester) async {
        // testWidgets 体内是假异步：真实文件 I/O 与字体注册必须走 runAsync。
        final fontsReady = await tester.runAsync(loadScreenshotFonts) ?? false;
        if (!fontsReady) return; // 缺字体环境跳过（CI/他机不阻塞）

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final controller = HostController(autoRefresh: false);
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(brightness, fontFamily: 'GciCjk'),
            home: HomeShell(controller: controller),
          ),
        );
        await tester.pump();

        if (i > 0) {
          await tester.tap(find.text(tabs[i]));
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 100));

        await expectLater(
          find.byType(HomeShell),
          matchesGoldenFile(
            '../../docs/screenshots/ticket13/${pages[i]}-$themeName.png',
          ),
        );
      });
    }
  }
}
