import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/main.dart';

void main() {
  testWidgets('脚手架冒烟：窗口渲染且发起启动器连接', (tester) async {
    await tester.pumpWidget(const GhostCodexInspectApp(autoConnect: false));
    expect(find.text('GhostCodexInspect'), findsOneWidget);
    expect(find.textContaining('启动器连接'), findsWidgets);
  });
}
