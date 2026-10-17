/// DOM 重绘采集器（工单 #11）：rrweb record 注入脚本的构建与事件分类。
///
/// 采集侧方案（docs/research/dom-replay.md §2、§3.1）：
/// - `assets/web/vendor/rrweb-record.js`（@rrweb/record 2.1.1，官方 ESM）
///   剥掉 `export` 行后与采集 glue 拼成一个经典脚本，经 CDP
///   `Page.addScriptToEvaluateOnNewDocument`（未来导航）+ `Runtime.evaluate`
///   （当前文档）注入目标页面；目标页面不联网、不加载外部脚本。
/// - 页面内 glue 把 rrweb 事件微批聚合，经 CDP Runtime binding
///   （全局函数 [kEmitBindingName]）回传 JSON 字符串给宿主。
/// - resync：页面调用 `window.__gciResync()`（[kResyncFunctionName]）补发
///   meta + 强制全量快照。
library;

import 'dart:convert';
import 'dart:io';

/// 采集器回传事件的 CDP binding 名（页面全局函数 `window.__gciEmit`）。
const String kEmitBindingName = '__gciEmit';

/// 页面内 resync 入口（宿主 evaluate 调用以强制全量快照）。
const String kResyncFunctionName = '__gciResync';

/// rrweb record 官方 ESM 构建的 vendor 相对路径（相对仓库根 /
/// Flutter 宿主进程工作目录）。
const String kRecorderAssetPath = 'assets/web/vendor/rrweb-record.js';

/// rrweb 事件类型号（rrweb EventType 枚举，线协议即数值）。
const int kEventTypeFullSnapshot = 2;
const int kEventTypeIncremental = 3;
const int kEventTypeMeta = 4;

/// 采集 glue：微批聚合 + binding 回传 + resync 入口。
///
/// 约束：注入为经典脚本（非 module），不得使用 import/export；
/// 依赖拼接在前的 recorder 源码提供顶层 `record` 绑定。
const String kCollectorGlue = r'''
;(function () {
  if (window.__gciCollectorInstalled) return;
  window.__gciCollectorInstalled = true;
  var BUF = [];
  var FLUSH_TIMER = null;
  var FLUSH_MS = 150;
  var MAX_BATCH = 200;
  function flush() {
    if (FLUSH_TIMER) { clearTimeout(FLUSH_TIMER); FLUSH_TIMER = null; }
    if (!BUF.length) return;
    var out = BUF;
    BUF = [];
    try {
      window.__gciEmit(JSON.stringify(out));
    } catch (e) {
      // binding 未就绪（注入早于 binding 注册）：事件放回缓冲等下一批
      BUF = out.concat(BUF);
    }
  }
  function schedule() {
    if (BUF.length >= MAX_BATCH) { flush(); return; }
    if (!FLUSH_TIMER) FLUSH_TIMER = setTimeout(flush, FLUSH_MS);
  }
  function metaEvent() {
    return {
      type: 4,
      data: {
        href: location.href,
        width: window.innerWidth,
        height: window.innerHeight,
      },
      timestamp: Date.now(),
    };
  }
  function start() {
    record({
      emit: function (ev) { BUF.push(ev); schedule(); },
      // 周期性全量快照兜底（长时间增量链断裂自愈）
      checkoutEveryNms: 60000,
    });
  }
  window.__gciResync = function () {
    BUF.push(metaEvent());
    try { record.takeFullSnapshot(false); } catch (e) { /* 未 start 时忽略 */ }
    flush();
  };
  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
''';

/// 构建注入脚本源码：recorder ESM 源码剥掉 `export {...}` 行与行尾
/// sourceMappingURL 注释行后拼接采集 glue。
///
/// 两条剥离规则都锚定整行（`^...$`）：vendor 构建内有字符串字面量
/// 内嵌 `\n//# sourceMappingURL=...`（canvas worker 源码字符串），非锚定的
/// `\S*` 会把字符串收尾的 `';` 一并吃掉，造成未闭合字符串语法错误。
String buildCollectorSource(String recorderSource) {
  final stripped = recorderSource
      .replaceAll(
        RegExp(r'^\s*export\s*\{[^}]*\};?\s*$', multiLine: true),
        '',
      )
      .replaceAll(
        RegExp(r'^[ \t]*//#[ \t]*sourceMappingURL=.*$', multiLine: true),
        '',
      );
  return '$stripped\n$kCollectorGlue';
}

/// 从默认 vendor 路径读取 recorder 源码并构建注入脚本。
///
/// [recorderPath] 可覆盖（测试用）；默认 [kRecorderAssetPath]
/// （相对进程工作目录，tool 脚本与 Flutter debug run 均为仓库根）。
Future<String> loadCollectorSource({String? recorderPath}) async {
  final file = File(recorderPath ?? kRecorderAssetPath);
  if (!file.existsSync()) {
    throw StateError('未找到 rrweb record vendor 文件：${file.path}');
  }
  return buildCollectorSource(await file.readAsString());
}

/// 一批 rrweb 事件的分类结果（宿主据此映射信封类型）。
class ClassifiedEvents {
  ClassifiedEvents({required this.meta, required this.full, required this.inc});

  /// meta 事件（type 4，视口/href）。
  final List<Map<String, dynamic>> meta;

  /// 全量快照事件（type 2；resync/周期 checkout 时可能一批多个）。
  final List<Map<String, dynamic>> full;

  /// 增量事件（type 3 及其余）。
  final List<Map<String, dynamic>> inc;

  bool get isEmpty => meta.isEmpty && full.isEmpty && inc.isEmpty;
}

/// 把采集器回传的一批 rrweb 事件（JSON 数组字符串）按类型分类。
///
/// 非法 JSON 或非数组抛 [FormatException]；非 Map 元素被丢弃。
ClassifiedEvents classifyEventBatch(String payloadJson) {
  final decoded = jsonDecode(payloadJson);
  if (decoded is! List) {
    throw FormatException('采集器回传必须是 JSON 数组：$payloadJson');
  }
  final meta = <Map<String, dynamic>>[];
  final full = <Map<String, dynamic>>[];
  final inc = <Map<String, dynamic>>[];
  for (final item in decoded) {
    if (item is! Map<String, dynamic>) continue;
    switch (item['type']) {
      case kEventTypeMeta:
        meta.add(item);
      case kEventTypeFullSnapshot:
        full.add(item);
      default:
        inc.add(item);
    }
  }
  return ClassifiedEvents(meta: meta, full: full, inc: inc);
}
