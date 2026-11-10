import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/viewport_override.dart';

void main() {
  test('parseViewportRequest：合法尺寸解析', () {
    expect(parseViewportRequest({'width': 1280, 'height': 720}), (
      width: 1280,
      height: 720,
      deviceScaleFactor: 1.0,
    ));
    // 小数取整
    expect(parseViewportRequest({'width': 1280.6, 'height': 719.4}), (
      width: 1281,
      height: 719,
      deviceScaleFactor: 1.0,
    ));
  });

  test('10% 缩放允许手机的大逻辑视口，实际画面仍受原像素上限约束', () {
    expect(
      parseViewportRequest({
        'width': 3900,
        'height': 7500,
        'deviceScaleFactor': 0.1,
      }),
      (width: 3900, height: 7500, deviceScaleFactor: 0.1),
    );
    expect(
      parseViewportRequest({
        'width': 76800,
        'height': 43200,
        'deviceScaleFactor': 0.1,
      }),
      isNotNull,
    );
    expect(
      parseViewportRequest({
        'width': 76810,
        'height': 43200,
        'deviceScaleFactor': 0.1,
      }),
      isNull,
    );
    expect(parseViewportRequest({'width': 3900, 'height': 7500}), isNull);
    for (final scale in [0.05, 8.05, double.nan, double.infinity, '0.1']) {
      expect(
        parseViewportRequest({
          'width': 390,
          'height': 750,
          'deviceScaleFactor': scale,
        }),
        isNull,
      );
    }
  });

  test('高 DPR 手机允许高密度采集，同时保留实际像素上限', () {
    expect(
      parseViewportRequest({
        'width': 390,
        'height': 740,
        'deviceScaleFactor': 3,
      }),
      (width: 390, height: 740, deviceScaleFactor: 3.0),
    );
    expect(
      parseViewportRequest({
        'width': 195,
        'height': 370,
        'deviceScaleFactor': 6,
      }),
      (width: 195, height: 370, deviceScaleFactor: 6.0),
    );
    expect(
      parseViewportRequest({
        'width': 3000,
        'height': 2000,
        'deviceScaleFactor': 3,
      }),
      isNull,
    );
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
