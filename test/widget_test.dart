import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/main.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:ghost_codex_inspect/ui/relay_page.dart';

void main() {
  testWidgets('主界面冒烟：侧栏四模块 + 启动器页渲染', (tester) async {
    final controller = HostController(autoRefresh: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      GhostCodexInspectApp(autoConnect: false, controller: controller),
    );
    await tester.pump();

    // 侧栏四模块
    expect(find.text('启动器'), findsWidgets);
    expect(find.text('检查器'), findsOneWidget);
    expect(find.text('中转台'), findsOneWidget);
    expect(find.text('远程视图'), findsOneWidget);

    // 默认落启动器页：目标应用卡 + 前提校验卡 + 运行状态卡
    expect(find.text('目标应用'), findsOneWidget);
    expect(find.text('前提校验'), findsOneWidget);
    expect(find.text('运行状态'), findsOneWidget);
    expect(find.text('带参启动'), findsWidgets);
  });

  testWidgets('侧栏切换到中转台：空态与开关渲染', (tester) async {
    final controller = HostController(autoRefresh: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      GhostCodexInspectApp(autoConnect: false, controller: controller),
    );
    await tester.pump();

    await tester.tap(find.text('中转台'));
    await tester.pump();

    expect(find.text('WebSocket 服务'), findsOneWidget);
    expect(find.text('启动中转'), findsOneWidget);
    expect(find.text('允许远程访问'), findsWidgets);
    // 会话卡（含视频参数）常驻后页面变长，安全边界卡需滚入视口
    await tester.scrollUntilVisible(
      find.text('安全边界'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(RelayPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('安全边界'), findsOneWidget);
  });
}
