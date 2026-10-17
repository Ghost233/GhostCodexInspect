// 压缩包装解压的远程端单测（#14）：与 lib/relay/compression.dart 的
// zlib/base64/JSON 线格式对齐（node 侧用 zlib 模块构造等效包装）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateSync } from 'node:zlib';
import { maybeDecompress } from '../js/ws-client.js';

// node 的 deflateSync 产出 RFC 1950 zlib 流，与 dart:io zlib.encode 同格式。
function wrap(payload) {
  const b64 = deflateSync(Buffer.from(JSON.stringify(payload), 'utf8')).toString('base64');
  return { z: 'fflate', b64 };
}

test('压缩包装解压还原对象', () => {
  const big = { type: 2, data: { payload: '快照内容'.repeat(2000) } };
  assert.deepEqual(maybeDecompress(wrap(big)), big);
});

test('数组 payload（batch）还原', () => {
  const batch = Array.from({ length: 50 }, (_, i) => ({ type: 3, i }));
  assert.deepEqual(maybeDecompress(wrap(batch)), batch);
});

test('非压缩 payload 原样透传', () => {
  const plain = { type: 4, data: {} };
  assert.equal(maybeDecompress(plain), plain);
  assert.equal(maybeDecompress(null), null);
  assert.equal(maybeDecompress('str'), 'str');
});

test('z 非 fflate 的 Map 不当作压缩包装', () => {
  const other = { z: 'other', b64: 'x' };
  assert.equal(maybeDecompress(other), other);
});

test('损坏包装抛异常', () => {
  assert.throws(() => maybeDecompress({ z: 'fflate' }), /b64/);
  assert.throws(() => maybeDecompress({ z: 'fflate', b64: '!!!' }));
});
