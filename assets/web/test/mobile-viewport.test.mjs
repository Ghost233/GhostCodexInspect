import test from 'node:test';
import assert from 'node:assert/strict';
import { setupMobileViewport } from '../js/mobile-viewport.js';

test('键盘弹出保持舞台高度，只向上平移；收起后复原', () => {
  const events = new Map();
  const visual = { height: 800, offsetTop: 0, addEventListener: (name, fn) => events.set(`v:${name}`, fn) };
  const stage = { style: {} };
  const body = { style: {} };
  const doc = { body, activeElement: null, querySelector: () => stage,
    addEventListener: (name, fn) => events.set(name, fn) };
  const win = { innerHeight: 800, visualViewport: visual, setTimeout: (fn) => fn(), addEventListener: (name, fn) => events.set(`w:${name}`, fn) };
  setupMobileViewport(win, doc);
  doc.activeElement = { inputMode: 'text', _remoteFocusY: 720, classList: { contains: () => true } };
  events.get('focusin')();
  win.innerHeight = 500;
  visual.height = 500;
  events.get('v:resize')();
  assert.equal(body.style.height, '800px');
  assert.equal(stage.style.transform, 'translateY(-268px)');
  doc.activeElement = null;
  events.get('focusout')();
  assert.equal(body.style.height, '');
  assert.equal(stage.style.transform, '');
});
