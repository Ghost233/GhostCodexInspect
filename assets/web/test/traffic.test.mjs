import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { RelayClient } from '../js/ws-client.js';

class FakeWebSocket {
  static OPEN = 1;
  constructor() { this.readyState = 1; this.sent = []; }
  send(data) { this.sent.push(data); }
  close() { this.readyState = 3; this.onclose?.({ code: 1000 }); }
}

function setup(t) {
  let now = 0;
  t.mock.method(performance, 'now', () => now);
  const originalWebSocket = globalThis.WebSocket;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.window = {};
  t.after(() => { globalThis.WebSocket = originalWebSocket; delete globalThis.window; });
  const client = new RelayClient({ url: 'ws://localhost/ws', token: 'test-token' });
  t.after(() => client.disconnect());
  return { client, advance: (ms) => { now += ms; } };
}

test('启动时统计为零，平均流量不会出现 Infinity 或 NaN', (t) => {
  const { client } = setup(t);
  assert.deepEqual(client.traffic, { receivedBytes: 0, sentBytes: 0, totalBytes: 0, averageBytesPerSecond: 0 });
});

test('文本按 UTF-8 字节计量，二进制按压缩后的完整消息计量', (t) => {
  const { client, advance } = setup(t);
  client.connect();
  const text = JSON.stringify({ ch: 'ctrl', t: 'meta', data: '你好🙂' });
  client.ws.onmessage({ data: text });
  const payload = deflateSync(Buffer.from(JSON.stringify({ note: '增量'.repeat(1000) })));
  const frame = new Uint8Array(15 + payload.byteLength);
  frame.set([2, 1, 2]);
  frame.set(payload, 15);
  client.ws.onmessage({ data: frame.buffer });
  advance(2000);
  const expected = new TextEncoder().encode(text).byteLength + frame.byteLength;
  assert.equal(client.traffic.receivedBytes, expected);
  assert.equal(client.traffic.totalBytes, expected);
  assert.equal(client.traffic.averageBytesPerSecond, expected / 2);
});

test('仅成功发送的消息计入上行，鉴权与输入消息均计入总流量', (t) => {
  const { client, advance } = setup(t);
  assert.equal(client.sendInput({ kind: 'text', text: '未连接' }), false);
  assert.equal(client.traffic.sentBytes, 0);
  client.connect();
  client.ws.onopen();
  client.sendInput({ kind: 'text', text: '你好' });
  const expected = client.ws.sent.reduce((sum, message) => sum + new TextEncoder().encode(message).byteLength, 0);
  advance(1000);
  assert.equal(client.traffic.sentBytes, expected);
  assert.equal(client.traffic.totalBytes, expected);
  assert.equal(client.traffic.averageBytesPerSecond, expected);
  client.disconnect();
  assert.equal(client.sendInput({ kind: 'key', key: 'Enter' }), false);
  assert.equal(client.traffic.totalBytes, expected);
});

test('重连保留累计值和启动计时，新页面客户端重新计数', (t) => {
  const { client, advance } = setup(t);
  client.connect();
  client.ws.onmessage({ data: '{}' });
  advance(1000);
  client.disconnect();
  advance(1000);
  client.connect();
  client.ws.onmessage({ data: '{}' });
  assert.equal(client.traffic.totalBytes, 4);
  assert.equal(client.traffic.averageBytesPerSecond, 2);
  const fresh = new RelayClient({ url: 'ws://localhost/ws' });
  assert.equal(fresh.traffic.totalBytes, 0);
});
