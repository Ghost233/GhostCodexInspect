import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/dom/dom_collector.dart';

void main() {
  group('buildCollectorSource', () {
    test('剥掉 ESM export 与 sourceMappingURL 后拼接 glue', () {
      const recorder =
          'function record(){}\n'
          '//# sourceMappingURL=record.js.map\n'
          'export { record };\n';
      final source = buildCollectorSource(recorder);
      expect(source, contains('function record(){}'));
      expect(source, isNot(contains('export')));
      expect(source, isNot(contains('sourceMappingURL')));
      expect(source, contains(kEmitBindingName));
      expect(source, contains(kResyncFunctionName));
    });

    test('整体包 IIFE：重复 evaluate 幂等安全（真机再注入事故修复）', () {
      // 真机主 shell 页面被 rrweb 干跑探针 evaluate 过剥离 bundle 后，
      // 顶层 let/const 永久留在全局词法环境；不包 IIFE 再注入即抛
      // "Identifier 'testableAccessors' has already been declared"。
      final source = buildCollectorSource(
        'let testableAccessors = 1;\n'
        'function record(){}\n'
        'export { record };\n',
      );
      expect(source, startsWith(';(function () {'));
      expect(source.trimRight(), endsWith('})();'));
    });

    test('回归：字符串字面量内嵌的 sourceMappingURL 文本不被误剥', () {
      // @rrweb/record 2.1.1 的 canvas worker 源码字符串内含
      // `\n//# sourceMappingURL=...\n';`（\n 为两字符转义，物理上同一行）。
      // 非锚定的 sourceMappingURL 剥离会连带吃掉字符串收尾 `';`，
      // 造成注入脚本 SyntaxError（e2e 一期实测踩中）。
      const recorder =
          "const js = '(function(){\\n//# sourceMappingURL=w.js.map\\n';\n"
          'export { record };\n';
      final source = buildCollectorSource(recorder);
      expect(
        source,
        contains(
          "const js = '(function(){\\n//# sourceMappingURL=w.js.map\\n';",
        ),
      );
      expect(source, isNot(contains('export { record }')));
    });
  });

  group('classifyEventBatch', () {
    Map<String, dynamic> ev(int type) => <String, dynamic>{
      'type': type,
      'data': <String, dynamic>{},
      'timestamp': 1,
    };

    test('按 type 分流 meta/full/inc', () {
      final payload = jsonEncode([ev(4), ev(2), ev(3), ev(3), ev(5), ev(6)]);
      final c = classifyEventBatch(payload);
      expect(c.meta, hasLength(1));
      expect(c.full, hasLength(1));
      expect(c.inc, hasLength(4)); // type 3/5/6 都归增量
      expect(c.isEmpty, isFalse);
    });

    test('空数组返回空分类', () {
      final c = classifyEventBatch('[]');
      expect(c.isEmpty, isTrue);
    });

    test('非 Map 元素被丢弃', () {
      final c = classifyEventBatch('[42,"x",{"type":2}]');
      expect(c.full, hasLength(1));
      expect(c.meta, isEmpty);
      expect(c.inc, isEmpty);
    });

    test('非法 JSON / 非数组抛 FormatException', () {
      expect(() => classifyEventBatch('not json'), throwsFormatException);
      expect(() => classifyEventBatch('{"type":2}'), throwsFormatException);
    });
  });
}
