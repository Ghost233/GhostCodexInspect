// v2 二进制帧解码的远程端单测（#15）：与 lib/relay/envelope.dart 的
// encodeBinaryEnvelope 布局对齐（node 侧手工构造 15 字节头 + payload）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { decodeBinaryFrame } from '../js/ws-client.js';

const CHANNELS = { dom: 1, frame: 2, input: 3, ctrl: 4 };
const TYPES = {
  meta: 1, full: 2, inc: 3, batch: 4, resync: 5, ping: 6, pong: 7,
  auth: 8, authOk: 9, authErr: 10, input: 11, frame: 12,
};

// 与 Dart encodeBinaryEnvelope 同布局：[0]=2 [1]=通道 [2]=类型
// [3..6]=seq uint32 LE [7..14]=ts int64 LE [15..]=payload。
function buildFrame(channel, type, seq, ts, payload) {
  const head = Buffer.alloc(15);
  head.writeUInt8(2, 0);
  head.writeUInt8(CHANNELS[channel], 1);
  head.writeUInt8(TYPES[type], 2);
  head.writeUInt32LE(seq, 3);
  head.writeBigUInt64LE(BigInt(ts), 7);
  return Buffer.concat([head, Buffer.from(payload)]);
}

test('dom 通道：zlib 压缩 JSON 还原为对象', () => {
  const payload = { type: 3, data: { note: '增量'.repeat(100) } };
  const raw = buildFrame('dom', 'batch', 7, 1730000000000,
    deflateSync(Buffer.from(JSON.stringify(payload), 'utf8')));
  const env = decodeBinaryFrame(new Uint8Array(raw).buffer);
  assert.equal(env.ch, 'dom');
  assert.equal(env.t, 'batch');
  assert.equal(env.seq, 7);
  assert.equal(env.ts, 1730000000000);
  assert.deepEqual(env.data, payload);
});

test('frame 通道：payload 原样为 Uint8Array（JPEG 字节不触碰）', () => {
  const jpeg = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const env = decodeBinaryFrame(buildFrame('frame', 'frame', 1, 5, jpeg));
  assert.equal(env.ch, 'frame');
  assert.equal(env.t, 'frame');
  assert.ok(env.data instanceof Uint8Array);
  assert.deepEqual([...env.data], [...jpeg]);
});

test('坏帧拒绝：短帧 / 坏版本 / 未知通道 / 未知类型', () => {
  assert.throws(() => decodeBinaryFrame(new Uint8Array(3).buffer), /短于/);
  const badVersion = buildFrame('dom', 'full', 0, 0, new Uint8Array(0));
  badVersion[0] = 9;
  assert.throws(() => decodeBinaryFrame(badVersion), /版本/);
  const badChannel = buildFrame('dom', 'full', 0, 0, new Uint8Array(0));
  badChannel[1] = 99;
  assert.throws(() => decodeBinaryFrame(badChannel), /通道/);
  const badType = buildFrame('dom', 'full', 0, 0, new Uint8Array(0));
  badType[2] = 99;
  assert.throws(() => decodeBinaryFrame(badType), /类型/);
});
