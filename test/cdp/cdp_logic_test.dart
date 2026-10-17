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
