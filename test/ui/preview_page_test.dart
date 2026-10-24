import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:ghost_codex_inspect/ui/preview_page.dart';
import 'package:ghost_codex_inspect/ui/theme.dart';

/// 2026-10-25 用户反馈回归：中转运行 + 会话启动时，未打开「远程视图」
/// 页也会自动连上中转（幽灵 client）并立刻触发编码。
///
/// 根因：外壳 IndexedStack 急切构建全部页面，预览页内嵌 WebView 无条件
/// 挂载。修复后 WebView 仅在页面可见（active）时挂载。
class _FakeController extends HostController {
  _FakeController({this.relayOn = true}) : super(autoRefresh: false);

  final bool relayOn;

  @override
  RelayServerStatus get relayStatus => RelayServerStatus(
    running: relayOn,
    address: relayOn ? '127.0.0.1' : null,
    port: relayOn ? 40000 : null,
    clientCount: 0,
    observedAt: DateTime.utc(2026, 10, 25),
  );

  @override
  Uri? get previewUrl =>
      relayOn ? Uri.parse('http://127.0.0.1:40000/#t=abc&ro=1') : null;

  @override
  SessionKind get sessionKind => SessionKind.video;
}

void main() {
  test('shouldLoadPreview：页面不可见时一律不挂载 WebView', () {
    final url = Uri.parse('http://127.0.0.1:40000/#t=abc&ro=1');
    // 后台页（未选中）→ 无论中转/会话状态如何都不加载
    expect(
      PreviewPage.shouldLoadPreview(
        active: false,
        sessionActive: true,
        url: url,
      ),
      isFalse,
    );
    expect(
      PreviewPage.shouldLoadPreview(
        active: false,
        sessionActive: false,
        url: url,
      ),
      isFalse,
    );
    // 页面可见且会话运行、有链接 → 加载
    expect(
      PreviewPage.shouldLoadPreview(
        active: true,
        sessionActive: true,
        url: url,
      ),
      isTrue,
    );
    // 页面可见但无链接/无会话 → 不加载
    expect(
      PreviewPage.shouldLoadPreview(
        active: true,
        sessionActive: true,
        url: null,
      ),
      isFalse,
    );
    expect(
      PreviewPage.shouldLoadPreview(
        active: true,
        sessionActive: false,
        url: url,
      ),
      isFalse,
    );
  });

  testWidgets('页面未选中时预览 WebView 不挂载（幽灵 client 回归）', (tester) async {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = _FakeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: PreviewPage(controller: controller, active: false),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('预览未加载：切到本页时才连接中转（避免后台自动连接占用编码资源）。'), findsOneWidget);
  });

  testWidgets('中转未运行时给出启动提示且不挂载预览', (tester) async {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = _FakeController(relayOn: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: PreviewPage(controller: controller, active: true)),
      ),
    );
    await tester.pump();

    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('中转未运行。到「中转台」启动中转后，这里会内嵌加载远程端单页。'), findsOneWidget);
  });
}
