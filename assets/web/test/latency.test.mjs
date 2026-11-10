import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const app = readFileSync(new URL('../js/app.js', import.meta.url), 'utf8')
  .replace(/^import .*;$/gm, '')
  .replace(/^main\(\);$/m, '');

function page() {
  let now = 1000;
  const classes = new Set();
  const freshness = {
    innerHTML: '',
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name),
    },
  };
  const client = { authed: true, roundTripMs: 24 };
  const context = {
    document: { getElementById: () => freshness },
    Date: { now: () => now },
    client,
  };
  runInNewContext(app, context);
  return {
    freshness, classes, client,
    update() { runInNewContext('updateLatency(client);', context); },
    advance(ms) { now += ms; },
  };
}

test('静止画面不让延迟读数随等待时间不断增长', () => {
  const { freshness, classes, update, advance } = page();
  update();
  const initial = freshness.innerHTML;
  assert.match(initial, /网络延迟.*24/);
  advance(60000);
  update();
  assert.equal(freshness.innerHTML, initial);
  assert.equal(classes.has('stale'), false);
});

test('延迟随有效 RTT 更新，等待首个心跳与断线状态不显示旧测量值', () => {
  const { freshness, classes, client, update } = page();
  client.roundTripMs = null;
  update();
  assert.match(freshness.innerHTML, /测量中/);
  client.roundTripMs = 42.3;
  update();
  assert.match(freshness.innerHTML, /42<\/span>/);
  client.roundTripMs = 4000;
  update();
  assert.equal(classes.has('stale'), true);
  client.authed = false;
  update();
  assert.equal(classes.has('hidden'), true);
});
