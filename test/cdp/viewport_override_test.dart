import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/viewport_override.dart';

void main() {
  test('parseViewportRequest：合法尺寸解析', () {
    expect(parseViewportRequest({'width': 1280, 'height': 720}), (
      width: 1280,
      height: 720,
    ));
    // 小数取整
    expect(parseViewportRequest({'width': 1280.6, 'height': 719.4}), (
      width: 1281,
      height: 719,
    ));
  });

  test('parseViewportRequest：非法输入一律 null', () {
    expect(parseViewportRequest(null), isNull);
    expect(parseViewportRequest('x'), isNull);
    expect(parseViewportRequest({'width': 1280}), isNull);
    expect(parseViewportRequest({'width': 'a', 'height': 100}), isNull);
    expect(parseViewportRequest({'width': 1, 'height': 100}), isNull);
    expect(parseViewportRequest({'width': 100, 'height': 1}), isNull);
    expect(parseViewportRequest({'width': 99999, 'height': 100}), isNull);
    expect(parseViewportRequest({'width': 100, 'height': 99999}), isNull);
  });
}
