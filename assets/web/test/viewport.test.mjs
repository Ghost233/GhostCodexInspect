import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const app = readFileSync(new URL('../js/app.js', import.meta.url), 'utf8')
  .replace(/^import .*;$/gm, '').replace(/^main\(\);$/m, '');

test('等待宿主回显期间，相同尺寸只发一次，避免 DOM 重建循环', () => {
  const pane = { clientWidth: 390, clientHeight: 740, classList: { contains: () => false } };
  const sent = [];
  let pending;
  const context = {
    document: { getElementById: () => pane },
    ResizeObserver: class { observe() {} },
    setTimeout(fn) { pending = fn; return 1; }, clearTimeout() {},
    client: { setViewport: (...args) => sent.push(args) },
  };
  runInNewContext(app + `
    currentMode = 'video';
    setupViewportSync(client, {}, {viewportWidth:1280,viewportHeight:720}, false);
    viewportSync();
  `, context);
  pending();
  runInNewContext('viewportSync();', context);
  pending();
  assert.deepEqual(sent, [[390, 740, 1]]);
  pane.clientWidth = 400;
  runInNewContext('viewportSync();', context);
  pending();
  assert.deepEqual(sent.at(-1), [400, 740, 1]);
});
