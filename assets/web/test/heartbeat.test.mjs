import test from 'node:test';
import assert from 'node:assert/strict';
import { RelayClient } from '../js/ws-client.js';

class FakeWebSocket {
  static OPEN = 1;
  constructor() { this.readyState = 1; this.sent = []; }
  send(data) { this.sent.push(JSON.parse(data)); }
  close(code = 1000) { this.readyState = 3; this.onclose?.({ code }); }
  receive(t, data) { this.onmessage({ data: JSON.stringify({ ch: 'ctrl', t, data }) }); }
}

function setup(t) {
  let now = 0;
  t.mock.timers.enable({ apis: ['setInterval', 'setTimeout'] });
  t.mock.method(performance, 'now', () => now);
  const originalWebSocket = globalThis.WebSocket;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.window = {};
  t.after(() => { globalThis.WebSocket = originalWebSocket; delete globalThis.window; });
  const states = [];
  const client = new RelayClient({ url: 'ws://localhost/ws', onState: (state) => states.push(state) });
  t.after(() => client.disconnect());
  client.connect();
  const ws = client.ws;
  ws.onopen();
  return {
    client, ws, states,
    advance(ms) { now += ms; t.mock.timers.tick(ms); },
    ping() { return ws.sent.filter((message) => message.t === 'ping').at(-1); },
  };
}

test('鉴权后立即测量 RTT，静止画面也每 5 秒发送心跳', (t) => {
  const { client, ws, advance, ping } = setup(t);
  assert.deepEqual(ws.sent.map((message) => message.t), ['auth']);
  advance(5000);
  assert.equal(ping(), undefined);
  ws.receive('authOk', {});
  assert.ok(ping());
  advance(24);
  ws.receive('pong', ping().data);
  assert.equal(client.roundTripMs, 24);
  advance(4976);
  assert.equal(ws.sent.filter((message) => message.t === 'ping').length, 2);
  advance(18);
  ws.receive('pong', ping().data);
  assert.equal(client.roundTripMs, 18);
});

test('等待或无关 pong 不会累加、覆盖最近一次有效 RTT', (t) => {
  const { client, ws, advance, ping } = setup(t);
  ws.receive('authOk', {});
  const first = ping();
  advance(20);
  ws.receive('pong', first.data);
  advance(4980);
  const second = ping();
  ws.receive('pong', first.data);
  assert.equal(client.roundTripMs, 20);
  t.mock.method(Date, 'now', () => -1000000);
  advance(30);
  ws.receive('pong', second.data);
  assert.equal(client.roundTripMs, 30);
});

test('15 秒没有心跳响应时断开并自动重连，旧 RTT 清零', (t) => {
  const { client, ws, advance, states } = setup(t);
  ws.receive('authOk', {});
  advance(15000);
  assert.equal(ws.readyState, 3);
  assert.equal(client.roundTripMs, null);
  assert.ok(states.includes('disconnected'));
  advance(1000);
  assert.notEqual(client.ws, ws);
  const next = client.ws;
  next.onopen();
  next.receive('authOk', {});
  assert.ok(next.sent.some((message) => message.t === 'ping'));
});

test('主动断开后停止心跳且不重连', (t) => {
  const { client, ws, advance } = setup(t);
  ws.receive('authOk', {});
  client.disconnect();
  const sent = ws.sent.length;
  advance(60000);
  assert.equal(ws.sent.length, sent);
  assert.equal(client.ws, null);
  assert.equal(client.roundTripMs, null);
});
