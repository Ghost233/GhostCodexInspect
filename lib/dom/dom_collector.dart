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

import '../relay/relay_server.dart';

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

/// 采集 glue：微批聚合 + binding 回传 + resync 入口 + 生命周期令牌。
///
/// 约束：注入为经典脚本（非 module），不得使用 import/export；
/// 依赖拼接在前的 recorder 源码提供同作用域的 `record` 绑定。
///
/// 守卫设计（2026-10-18 真机 stale 守卫事故）：
/// - 健康重复注入（同文档重复 evaluate）：`__gciCollector.alive` 为真 → 早退；
/// - 健康旧版（v1，无令牌但有 resync 句柄）→ 早退，避免双采集器；
/// - 陈旧/残缺安装（布尔标志为真但无令牌无 resync，或令牌 stop 可用）：
///   能停则停后重装——真机页面曾被探针/异常死亡会话留下
///   `__gciCollectorInstalled=true` 而无活动采集器，裸布尔守卫会永久卡死。
/// - `stop()` 句柄让宿主正常停止时页面侧零残留（v1 丢弃了 record 的
///   stop 返回值，采集器只能等页面导航才停）。
const String kCollectorGlue = r'''
;(function () {
  var prev = window.__gciCollector;
  if (prev && prev.alive) return;
  if (!prev && window.__gciCollectorInstalled &&
      typeof window.__gciResync === 'function') return;
  if (prev && typeof prev.stop === 'function') { try { prev.stop(); } catch (e) {} }
  var BUF = [];
  var FLUSH_TIMER = null;
  var FLUSH_MS = 150;
  var MAX_BATCH = 200;
  var STOP = null;
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
    try {
      STOP = record({
        emit: function (ev) { BUF.push(ev); schedule(); },
        // 周期性全量快照兜底（长时间增量链断裂自愈）
        checkoutEveryNms: 60000,
      });
    } catch (e) { /* record 不可用（注入残缺）时保持未启动 */ }
  }
  var api = {
    alive: true,
    resync: function () {
      BUF.push(metaEvent());
      try { record.takeFullSnapshot(false); } catch (e) { /* 未 start 时忽略 */ }
      flush();
    },
    stop: function () {
      if (!api.alive) return;
      api.alive = false;
      try { if (STOP) STOP(); } catch (e) {}
      flush();
    },
  };
  window.__gciCollector = api;
  window.__gciCollectorInstalled = true;
  window.__gciResync = function () { api.resync(); };
  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
''';

/// 构建注入脚本源码：recorder ESM 源码剥掉 `export {...}` 行与行尾
/// sourceMappingURL 注释行后拼接采集 glue，整体再包一层 IIFE。
///
/// 两条剥离规则都锚定整行（`^...$`）：vendor 构建内有字符串字面量
/// 内嵌 `\n//# sourceMappingURL=...`（canvas worker 源码字符串），非锚定的
/// `\S*` 会把字符串收尾的 `';` 一并吃掉，造成未闭合字符串语法错误。
///
/// IIFE 包裹（2026-10-18 真机事故）：bundle 顶层是 `let/const` 声明，
/// 作为经典脚本 evaluate 时会进入页面的全局词法环境且**永不回收**
/// （stop 采集器清不掉）。真机主 shell 页面此前被 rrweb 干跑探针
/// evaluate 过一次（real_machine_probe），再次注入同一份 bundle 即抛
/// `SyntaxError: Identifier 'testableAccessors' has already been declared`。
/// 包进 IIFE 后所有声明落在函数作用域，重复注入/导航重注入均幂等安全；
/// glue 的幂等守卫是 `window.__gciCollectorInstalled`。
String buildCollectorSource(String recorderSource) {
  final stripped = recorderSource
      .replaceAll(RegExp(r'^\s*export\s*\{[^}]*\};?\s*$', multiLine: true), '')
      .replaceAll(
        RegExp(r'^[ \t]*//#[ \t]*sourceMappingURL=.*$', multiLine: true),
        '',
      );
  return ';(function () {\n$stripped\n$kCollectorGlue\n})();\n';
}

/// 从默认 vendor 路径读取 recorder 源码并构建注入脚本。
///
/// [recorderPath] 可覆盖（测试用）。默认依次尝试：相对进程工作目录的
/// [kRecorderAssetPath]（tool 脚本与 Flutter debug run 为仓库根）→
/// [RelayServer.resolveWebRoot] 的 vendor 子路径（打包 app / 集成测试
/// 运行时 cwd 不是仓库根，与静态根同一套解析）。
Future<String> loadCollectorSource({String? recorderPath}) async {
  if (recorderPath != null) {
    final file = File(recorderPath);
    if (!file.existsSync()) {
      throw StateError('未找到 rrweb record vendor 文件：$recorderPath');
    }
    return buildCollectorSource(await file.readAsString());
  }
  final candidates = {
    kRecorderAssetPath,
    '${RelayServer.resolveWebRoot()}/vendor/rrweb-record.js',
  };
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return buildCollectorSource(await file.readAsString());
    }
  }
  throw StateError('未找到 rrweb record vendor 文件（已尝试：${candidates.join('、')}）');
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
