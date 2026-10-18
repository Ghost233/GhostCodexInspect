// 真机输入受控验收（工单 #18 Scope 2，用户在场执行）。
//
// attach 9238 → 主 shell → 找到可视文本输入区（composer）→
// ① 中性点击一次（鼠标链路）→ ② insertText 写测试文本 → 读回断言 →
// 清空复原（绝不触发发送）→ 会话即停 → 页面零残留校验。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/demo_real_input.dart
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';

const debugPort = 9238;
const testText = '输入链路验收测试（勿发送）';

/// 找主 shell 里最大的可视文本输入元素，返回其中点坐标与描述。
const findComposerJs = '''
(function () {
  const cands = Array.from(document.querySelectorAll(
      'textarea, [contenteditable="true"], input[type="text"]'))
    .filter((el) => {
      const r = el.getBoundingClientRect();
      return r.width > 40 && r.height > 12 &&
          r.bottom > 0 && r.right > 0 &&
          r.top < innerHeight && r.left < innerWidth;
    })
    .map((el) => {
      const r = el.getBoundingClientRect();
      return {
        el: el,
        x: r.left + r.width / 2, y: r.top + r.height / 2,
        area: r.width * r.height,
        tag: el.tagName, ce: el.isContentEditable,
      };
    })
    .sort((a, b) => b.area - a.area);
  // 中心点被覆盖层挡住的候选不可用（真机实测 main shell 存在覆盖层）。
  for (const c of cands) {
    const hit = document.elementFromPoint(c.x, c.y);
    if (hit && (hit === c.el || c.el.contains(hit) || hit.contains(c.el))) {
      return JSON.stringify(
        {x: c.x, y: c.y, area: c.area, tag: c.tag, ce: c.ce});
    }
  }
  return 'null';
})()
''';

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  final launcher = AppLauncher();
  if (!await launcher.isDebugPortAlive(debugPort)) {
    stderr.writeln('调试端口 $debugPort 未监听：请先带参启动目标应用。');
    exitCode = 2;
    return;
  }

  step('1/5 CDP attach + 定位主 shell 页面');
  final connection = await connectCdp(debugPort: debugPort);
  final shell = findShellTarget(
    await connection.client.listTargets(),
    TargetProfile.chatGpt.shellUrlSchemes,
  );
  stdout.writeln('主 shell：${shell.url}');
  final page = await connection.client.attachTo(shell);

  final urlBefore = '${await page.evaluate('location.href')}';
  var inputs = 0;
  var failed = false;
  try {
    step('2/5 定位 composer 并中性点击一次');
    final foundRaw = '${await page.evaluate(findComposerJs)}';
    if (foundRaw == 'null') {
      stderr.writeln('主 shell 未找到可视文本输入区（页面可能未加载会话视图）。');
      failed = true;
    } else {
      final m = RegExp(r'"x":([\d.]+),"y":([\d.]+)').firstMatch(foundRaw)!;
      final x = double.parse(m.group(1)!);
      final y = double.parse(m.group(2)!);
      stdout.writeln('composer 中点：($x, $y)  $foundRaw');
      await dispatchInput(page, {
        'kind': 'mouse', 'type': 'down', 'x': x, 'y': y, 'button': 'left',
      });
      inputs++;
      await dispatchInput(page, {
        'kind': 'mouse', 'type': 'up', 'x': x, 'y': y, 'button': 'left',
      });
      inputs++;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final focused = await page.evaluate(
        'JSON.stringify({tag: document.activeElement && '
        'document.activeElement.tagName, ce: !!(document.activeElement && '
        '(document.activeElement.isContentEditable || '
        'document.activeElement.tagName === "TEXTAREA" || '
        'document.activeElement.tagName === "INPUT"))})',
      );
      stdout.writeln('点击后焦点：$focused');
      // 焦点未转移（覆盖层/窗口未聚焦）时用 JS focus 兜底继续测文本链路，
      // 点击聚焦与文本输入分开判定（真机实测发现 main shell 存在覆盖层）。
      if (!'$focused'.contains('ce":true')) {
        stdout.writeln('点击未聚焦编辑区，改用 JS focus 兜底（单独记录）');
        await page.evaluate('''
(function () {
  const cands = Array.from(document.querySelectorAll(
      'textarea, [contenteditable="true"], input[type="text"]'))
    .filter((el) => el.getBoundingClientRect().width > 40)
    .sort((a, b) => {
      const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
      return rb.width * rb.height - ra.width * ra.height;
    });
  if (cands[0]) cands[0].focus();
})()
''');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      step('3/5 insertText 写入测试文本并读回');
      await dispatchInput(page, {'kind': 'text', 'text': testText});
      inputs++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final readBack = '${await page.evaluate('''
(function () {
  const el = document.activeElement;
  if (!el) return '';
  if (el.isContentEditable) return el.innerText;
  return el.value ?? '';
})()
''')}';
      stdout.writeln('读回：$readBack');
      if (!readBack.contains(testText)) {
        stderr.writeln('读回不含测试文本——输入未生效！');
        failed = true;
      }

      step('4/5 清空复原（不触发发送）');
      await page.evaluate('''
(function () {
  const el = document.activeElement;
  if (!el) return;
  el.focus();
  if (el.isContentEditable) {
    document.execCommand('selectAll', false, null);
    document.execCommand('delete', false, null);
  } else {
    el.value = '';
    el.dispatchEvent(new Event('input', {bubbles: true}));
  }
})()
''');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final after = '${await page.evaluate('''
(function () {
  const el = document.activeElement;
  if (!el) return '';
  return (el.isContentEditable ? el.innerText : el.value) ?? '';
})()
''')}';
      stdout.writeln('清空后内容："$after"（应为空）');
      if (after.trim().isNotEmpty) {
        stderr.writeln('清空后仍有内容——请人工检查 composer！');
        failed = true;
      }
    }

    step('5/5 完整性核对');
    final urlAfter = '${await page.evaluate('location.href')}';
    stdout.writeln('URL 前：$urlBefore');
    stdout.writeln('URL 后：$urlAfter（应一致，未触发导航）');
    stdout.writeln('输入下发计数：$inputs（预期 3：点击 down/up + insertText）');
    if (urlBefore != urlAfter) {
      stderr.writeln('URL 发生变化——点击产生了导航，需要人工检查！');
      failed = true;
    }
    final residue = await page.evaluate('''
JSON.stringify({
  installed: !!window.__gciCollectorInstalled,
  collector: typeof window.__gciCollector,
  resync: typeof window.__gciResync,
})
''');
    stdout.writeln('残留检查：$residue');
  } catch (e) {
    stderr.writeln('验收失败：$e');
    failed = true;
  } finally {
    await connection.client.close();
  }
  stdout.writeln(failed ? '\n✗ 输入验收未通过' : '\n✓ 输入验收通过');
  if (failed) exitCode = 1;
}
