// 宿主 UI 真机走查（goal-f20a78c1 剩余验收项①）。
//
// 前提：真机 ChatGPT.app 已带 `--remote-debugging-port=9238` 运行
// （用户手动执行过 tool/restart_target_debug 系列脚本）。
// 全程约束：不启动/不停止目标应用，探测只读；DOM 会话短暂启动后立即停止
// （glue v2 的页面侧清理保证零残留）。
//
// 运行：`flutter test integration_test/host_walkthrough_test.dart -d macos`

import 'package:flutter/material.dart' show FilledButton, Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/main.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('四模块真机走查：检测→探测→中转→DOM 会话→只读预览', (tester) async {
    final controller = HostController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      GhostCodexInspectApp(autoConnect: false, controller: controller),
    );
    await tester.pumpAndSettle();

    String dump() =>
        'lastError=${controller.lastError}; relay=${controller.relayStatus.running}; '
        'session=${controller.sessionKind}; busy=${controller.busyAction}; '
        '文本：${tester.widgetList(find.byType(Text)).map((w) => (w as Text).data).whereType<String>().join(' | ')}';

    Future<void> settle([int seconds = 1]) async {
      // 集成测试跑在真实事件循环：真实异步（进程调用 / CDP / WS）需要时间。
      await Future<void>.delayed(Duration(seconds: seconds));
      await tester.pump();
      await tester.pumpAndSettle();
    }

    Future<void> tapText(String label) async {
      final finder = find.text(label);
      expect(finder, findsWidgets, reason: '应能找到「$label」');
      await tester.tap(finder.first);
      await tester.pump();
    }

    Future<void> tapButton(Type buttonType, String label) async {
      // 按钮标签可能与区块标题同文案（如「CDP 探测」），按控件类型定位。
      final finder = find.widgetWithText(buttonType, label);
      expect(finder, findsOneWidget, reason: '应能找到按钮「$label」');
      await tester.tap(finder);
      await tester.pump();
    }

    void expectText(String substr, String why) {
      expect(
        find.textContaining(substr),
        findsWidgets,
        reason: '$why。${dump()}',
      );
    }

    // ── ① 启动器：检测真实目标 ──────────────────────────────
    await tapText('重新检测');
    await settle(3);
    expectText('已检测到', '真机应检测到 /Applications/ChatGPT.app');
    expectText('Electron 框架', '前提校验应列出 Electron 框架检查（适配 Codex Framework 重命名）');
    expectText('ElectronAsarIntegrity', '前提校验应列出加固检测');

    // ── ② 检查器：CDP 只读探测 ──────────────────────────────
    await tapText('检查器');
    await settle();
    await tapButton(FilledButton, 'CDP 探测');
    await settle(10);
    expectText('健康', '9238 在监听，CDP 探测应健康');
    expectText('app://', 'shell 页面列表应枚举出 app:// 目标');

    // ── ③ 中转台：启动中转 + DOM 会话 ───────────────────────
    await tapText('中转台');
    await settle();
    await tapText('启动中转');
    await settle(3);
    expectText('#t=', '中转运行后应展示带 token 的访问地址');

    await tapText('DOM 重绘模式');
    await settle(8); // 注入 + 首份全量快照（真机 2.86MB，经压缩下发）
    expectText('停止会话', '会话控制区应可用');

    // ── ④ 远程视图：本机只读预览 ────────────────────────────
    await tapText('远程视图');
    await settle(4);
    expectText('只读 ro=1', '预览页应显示只读徽标 chip');

    // ── 收尾：停会话（触发页面侧清理）→ 停中转 ──────────────
    await tapText('中转台');
    await settle();
    await tapText('停止会话');
    await settle(2);
    await tapText('停止中转');
    await settle(2);
    expectText('中转未运行', '停止中转后应回到空态');
  });
}
