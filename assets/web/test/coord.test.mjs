/**
 * coord.js 最小自测（node --test）
 *
 * 运行方式：node --test assets/web/test/coord.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { computeScale, toSourceCssPx, toRemoteCssPx } from '../js/coord.js';

test('无缩放（1:1）时坐标原样透传', () => {
  assert.deepEqual(toSourceCssPx(100, 50, 1), { x: 100, y: 50 });
});

test('远端缩小一半显示时，远端坐标 ÷ 0.5 = 源坐标', () => {
  // 源视口 1000×800，远端舞台 500×400 → s = 0.5
  const s = computeScale(1000, 800, 500, 400);
  assert.equal(s, 0.5);
  assert.deepEqual(toSourceCssPx(250, 200, s), { x: 500, y: 400 });
});

test('远端放大显示时，远端坐标 ÷ s 还原源坐标', () => {
  // 源视口 800×600，远端舞台 1600×1200 → s = 2
  const s = computeScale(800, 600, 1600, 1200);
  assert.equal(s, 2);
  assert.deepEqual(toSourceCssPx(300, 100, s), { x: 150, y: 50 });
});

test('宽高比不一致时取较小比值（contain 等比内嵌）', () => {
  // 宽比 1.5、高比 0.75 → 取 0.75，画面完整内嵌
  const s = computeScale(1000, 800, 1500, 600);
  assert.equal(s, 0.75);
});

test('往返换算：toSource(toRemote(p)) === p', () => {
  const s = computeScale(1440, 900, 700, 500);
  const remote = toRemoteCssPx(320, 240, s);
  const back = toSourceCssPx(remote.x, remote.y, s);
  assert.ok(Math.abs(back.x - 320) < 1e-9);
  assert.ok(Math.abs(back.y - 240) < 1e-9);
});

test('非法尺寸与非法 scale 抛出 RangeError', () => {
  assert.throws(() => computeScale(0, 800, 500, 400), RangeError);
  assert.throws(() => computeScale(1000, 800, -1, 400), RangeError);
  assert.throws(() => computeScale(1000, 800, NaN, 400), RangeError);
  assert.throws(() => toSourceCssPx(10, 10, 0), RangeError);
  assert.throws(() => toSourceCssPx(10, 10, -0.5), RangeError);
  assert.throws(() => toRemoteCssPx(10, 10, Infinity), RangeError);
});
