// CDP 层纯逻辑单元测试：shell target 过滤与 pgrep 输出解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';

void main() {
  group('isShellTarget（shell 页面过滤）', () {
    test('page + app:// scheme 命中', () {
      const target = CdpTargetInfo(
        id: '1',
        type: 'page',
        url: 'app://index.html',
        title: 'shell',
      );
      expect(isShellTarget(target, ['app', 'codex-sandbox']), isTrue);
    });

    test('page + file:// scheme 命中（fixture）', () {
      const target = CdpTargetInfo(
        id: '1',
        type: 'page',
        url: 'file:///Users/x/index.html',
        title: 'fixture',
      );
      expect(isShellTarget(target, ['file']), isTrue);
    });

    test('非 page 类型不命中', () {
      const target = CdpTargetInfo(
        id: '1',
        type: 'service_worker',
        url: 'app://worker.js',
        title: 'worker',
      );
      expect(isShellTarget(target, ['app']), isFalse);
    });

    test('scheme 不匹配不命中（http 页面不算 shell）', () {
      const target = CdpTargetInfo(
        id: '1',
        type: 'page',
        url: 'https://chatgpt.com/',
        title: 'web',
      );
      expect(isShellTarget(target, ['app', 'codex-sandbox']), isFalse);
    });

    test('devtools 页面不命中', () {
      const target = CdpTargetInfo(
        id: '1',
        type: 'page',
        url: 'devtools://devtools/bundled/inspector.html',
        title: 'devtools',
      );
      expect(isShellTarget(target, ['app']), isFalse);
    });
  });

  group('findShellTarget', () {
    const targets = [
      CdpTargetInfo(id: 'b', type: 'browser', url: '', title: ''),
      CdpTargetInfo(id: 'w', type: 'service_worker', url: 'app://w.js', title: ''),
      CdpTargetInfo(id: 'p', type: 'page', url: 'app://index.html', title: 'shell'),
    ];

    test('返回第一个命中的 shell target', () {
      expect(findShellTarget(targets, ['app']).id, 'p');
    });

    test('未命中时抛出带 target 清单的异常', () {
      expect(
        () => findShellTarget(targets, ['codex-sandbox']),
        throwsStateError,
      );
    });
  });

  // #4 实测：真机有 3 个 app:// shell page，非主窗口一律带 initialRoute 参数
  //（docs/research/codex-cdp-probe.md 结论 2；工单 #14 Scope 1）。
  group('isPrimaryShellTarget / findShellTarget 多 shell 场景（#14）', () {
    const mainShell = CdpTargetInfo(
      id: 'main',
      type: 'page',
      url: 'app://-/index.html',
      title: 'ChatGPT',
    );
    const detached = CdpTargetInfo(
      id: 'det',
      type: 'page',
      url: 'app://-/detached-window.html?initialRoute=%2Fdetached-window',
      title: 'detached',
    );
    const avatar = CdpTargetInfo(
      id: 'ava',
      type: 'page',
      url: 'app://-/index.html?initialRoute=%2Favatar-overlay',
      title: 'avatar',
    );

    test('主窗口（无 initialRoute）是主 shell，其余不是', () {
      expect(isPrimaryShellTarget(mainShell, ['app']), isTrue);
      expect(isPrimaryShellTarget(detached, ['app']), isFalse);
      expect(isPrimaryShellTarget(avatar, ['app']), isFalse);
    });

    test('fixture file:// 无查询参数，天然是主 shell', () {
      const fixture = CdpTargetInfo(
        id: 'f',
        type: 'page',
        url: 'file:///x/index.html',
        title: 'fixture',
      );
      expect(isPrimaryShellTarget(fixture, ['file']), isTrue);
    });

    test('三 shell 并存时选中主窗口（无论枚举顺序）', () {
      expect(findShellTarget([avatar, detached, mainShell], ['app']).id, 'main');
      expect(findShellTarget([mainShell, avatar], ['app']).id, 'main');
    });

    test('shell 存在但无一个主窗口时抛错（不静默挑浮层）', () {
      expect(
        () => findShellTarget([detached, avatar], ['app']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('都不是主窗口'),
          ),
        ),
      );
    });
  });

  group('parsePgrepOutput', () {
    test('解析每行一个 pid', () {
      expect(parsePgrepOutput('123\n456\n'), [123, 456]);
    });

    test('空输出与杂行被忽略', () {
      expect(parsePgrepOutput(''), isEmpty);
      expect(parsePgrepOutput('abc\n 789 \n'), [789]);
    });
  });
}
