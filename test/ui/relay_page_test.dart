import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';
import 'package:ghost_codex_inspect/ui/relay_page.dart';
import 'package:ghost_codex_inspect/ui/theme.dart';
import 'package:ghost_codex_inspect/ui/widgets.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AddressListController extends HostController {
  _AddressListController() : super(autoRefresh: false);

  @override
  List<Uri> get accessUrls => [
    for (final host in ['192.168.1.23', '100.64.0.2', '127.0.0.1', 'localhost'])
      Uri.parse('http://$host:9410/#t=fixed-token'),
  ];

  @override
  String? get relayToken => 'fixed-token';

  @override
  RelayServerStatus get relayStatus => RelayServerStatus(
    running: true,
    address: '0.0.0.0',
    port: 9410,
    clientCount: 0,
    observedAt: DateTime.utc(2026, 11, 10),
  );
}

class _WindowController extends _AddressListController {
  int windows = 0;
  SessionKind kind = SessionKind.none;

  @override
  int get remoteWindowCount => windows;

  @override
  SessionKind get sessionKind => kind;

  @override
  Future<void> createRemoteWindow() async {
    windows++;
    notifyListeners();
  }
}

void main() {
  testWidgets('端口设置在页面创建后加载时显示已保存端口', (tester) async {
    SharedPreferences.setMockInitialValues({'gci.relayPort': 57303});
    final c = HostController(autoRefresh: false);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    final port = find.byType(TextField).first;
    expect(tester.widget<TextField>(port).controller!.text, '0');
    await c.loadSettings();
    await tester.pumpAndSettle();
    expect(c.relayPort, 57303);
    expect(tester.widget<TextField>(port).controller!.text, '57303');
    await tester.enterText(port, '57304');
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(port).controller!.text, '57304');
  });

  testWidgets('端口应用后保存并在新控制器和页面中恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = HostController(autoRefresh: false);
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    final port = find.byType(TextField).first;
    await tester.enterText(port, '57303');
    await tester.tap(find.widgetWithText(TextButton, '应用'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getInt('gci.relayPort'),
      57303,
    );
    await tester.pumpWidget(const SizedBox());
    final restored = HostController(autoRefresh: false);
    addTearDown(restored.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RelayPage(controller: restored)),
      ),
    );
    await restored.loadSettings();
    await tester.pumpAndSettle();
    expect(restored.relayPort, 57303);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '57303',
    );
  });

  testWidgets('可新建专用窗口并显示接管范围，会话运行时禁用新建', (tester) async {
    final c = _WindowController();
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    expect(find.text('当前主窗口（与本机共用）'), findsOneWidget);
    final button = find.widgetWithText(OutlinedButton, '新建远程专用窗口');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('远程专用窗口（1 个）'), findsOneWidget);
    c.kind = SessionKind.video;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });

  testWidgets('访问入口列出全部地址，移除复制按钮并保留轮转', (tester) async {
    final c = _AddressListController();
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    for (final url in c.accessUrls) {
      expect(find.text(url.toString()), findsOneWidget);
    }
    final card = find.ancestor(
      of: find.text('远程访问入口'),
      matching: find.byType(SectionCard),
    );
    expect(
      find.descendant(of: card, matching: find.byType(CopyButton)),
      findsNothing,
    );
    expect(find.text('立即轮转 token'), findsOneWidget);
  });

  testWidgets('远程访问凭据可在停止时设置，校验短密钥并可固定 token', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final c = HostController(autoRefresh: false);
    addTearDown(c.dispose);
    await c.loadSettings();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: RelayPage(controller: c)),
      ),
    );
    final keyField = find.widgetWithText(TextField, '访问密钥');
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, 'short');
    await tester.tap(find.text('保存密钥'));
    await tester.pumpAndSettle();
    expect(find.text('访问密钥至少 8 个字符'), findsOneWidget);
    await tester.enterText(keyField, 'custom-access-key');
    await tester.tap(find.text('保存密钥'));
    await tester.pumpAndSettle();
    expect(c.hasRelayAccessKey, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getString('gci.relayAccessKey'),
      'custom-access-key',
    );
    expect(tester.widget<TextField>(keyField).controller!.text, isEmpty);
    expect(find.text('密钥不提供查看或复制，遗失后请重新设置。'), findsOneWidget);
    expect(find.text('访问密钥至少 8 个字符'), findsNothing);
    await tester.tap(find.text('固定 token（手动轮转）'));
    await tester.pumpAndSettle();
    expect(c.useFixedRelayToken, isTrue);
    final token = c.relayToken;
    await tester.tap(find.text('立即轮转 token'));
    await tester.pumpAndSettle();
    expect(c.relayToken, isNot(token));
  });

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
