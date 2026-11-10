import test from 'node:test';
import assert from 'node:assert/strict';
import { VideoView } from '../js/video.js';

class Element {
  constructor() { this.style = {}; this.classList = { add() {}, remove() {}, toggle() {} }; }
  appendChild() {}
}

test('HTTP 兼容播放在小片段就输出，不等待 16KB 缓冲且 MIME 匹配 SPS', (t) => {
  const appended = [];
  let mime;
  let open;
  const originalDocument = globalThis.document;
  const originalMediaSource = globalThis.MediaSource;
  const originalObserver = globalThis.ResizeObserver;
  globalThis.document = { createElement: () => new Element() };
  globalThis.ResizeObserver = class { observe() {} };
  globalThis.MediaSource = class {
    addEventListener(_, fn) { open = fn; }
    addSourceBuffer(value) { mime = value; return { updating: false, mode: '', addEventListener() {}, appendBuffer: (data) => appended.push(data) }; }
  };
  t.mock.method(URL, 'createObjectURL', () => 'blob:test');
  t.after(() => { globalThis.document = originalDocument; globalThis.MediaSource = originalMediaSource; globalThis.ResizeObserver = originalObserver; });
  const view = new VideoView(new Element(), {}, { readOnly: true });
  view.setPlaybackPath('mse');
  view.handleVideoMessage('videoMeta', { viewportWidth: 640, viewportHeight: 480 });
  const key = new Uint8Array([0,0,0,1,0x67,0x64,0,0x28,0xaa,0,0,0,1,0x68,1,0,0,0,1,0x65,0x88]);
  view.handleVideoMessage('videoFrame', key);
  open();
  view.handleVideoMessage('videoFrame', key);
  assert.ok(appended.reduce((n, data) => n + data.byteLength, 0) > 100, view.lastError || '尚未输出可播放片段');
  assert.equal(mime, 'video/mp4; codecs="avc1.640028"');
});
