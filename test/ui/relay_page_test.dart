import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:ghost_codex_inspect/ui/relay_page.dart';
import 'package:ghost_codex_inspect/ui/theme.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('中转未运行时编码格式设置可见且可选择（#26 回归）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = HostController(autoRefresh: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    await tester.pumpAndSettle();

    // 会话卡始终渲染（2026-10-19 用户反馈修复：设置曾只在
    // 中转运行时可见，导致「不能选择编码格式」）
    final codec = find.widgetWithText(DropdownButton<VideoCodecKind>, 'H.264');
    await tester.scrollUntilVisible(
      codec,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(codec, findsOneWidget);

    await tester.tap(codec);
    await tester.pumpAndSettle();
    await tester.tap(find.text('H.265').last);
    await tester.pumpAndSettle();
    expect(c.videoCodec, VideoCodecKind.hevc);

    // 会话启动按钮在中转未运行时应禁用
    final domBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'DOM 重绘模式'),
    );
    expect(domBtn.onPressed, isNull);
  });
}
