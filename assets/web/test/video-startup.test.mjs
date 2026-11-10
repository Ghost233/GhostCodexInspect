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
  let updateEnd;
  const originalDocument = globalThis.document;
  const originalMediaSource = globalThis.MediaSource;
  const originalObserver = globalThis.ResizeObserver;
  globalThis.document = { createElement: () => new Element() };
  globalThis.ResizeObserver = class { observe() {} };
  globalThis.MediaSource = class {
    addEventListener(_, fn) { open = fn; }
    addSourceBuffer(value) { mime = value; return { updating: false, mode: '', addEventListener(_,fn) { updateEnd=fn; }, appendBuffer: (data) => appended.push(data) }; }
  };
  t.mock.method(URL, 'createObjectURL', () => 'blob:test');
  t.after(() => { globalThis.document = originalDocument; globalThis.MediaSource = originalMediaSource; globalThis.ResizeObserver = originalObserver; });
  const view = new VideoView(new Element(), {}, { readOnly: true });
  view.setPlaybackPath('mse');
  view.handleVideoMessage('videoMeta', { viewportWidth: 640, viewportHeight: 480, deviceScaleFactor: 3 });
  const key = new Uint8Array([0,0,0,1,0x67,0x64,0,0x28,0xaa,0,0,0,1,0x68,1,0,0,0,1,0x65,0x88]);
  view.handleVideoMessage('videoFrame', key);
  open();
  view.handleVideoMessage('videoFrame', key);
  assert.ok(appended.reduce((n, data) => n + data.byteLength, 0) > 100, view.lastError || '尚未输出可播放片段');
  assert.equal(mime, 'video/mp4; codecs="avc1.640028"');
  const bytes=Buffer.concat(appended.map((data)=>Buffer.from(data)));
  const type=bytes.indexOf('tkhd');
  assert.ok(type>=4);
  const end=type-4+bytes.readUInt32BE(type-4);
  assert.equal(bytes.readUInt32BE(end-8)/65536,1920,'MP4 轨道宽度必须声明实际像素');
  assert.equal(bytes.readUInt32BE(end-4)/65536,1440,'MP4 轨道高度必须声明实际像素');
  const before = bytes.byteLength;
  view.handleVideoMessage('videoFrame', new Uint8Array([0,0,0,1,0x41,0x88]));
  assert.ok(appended.reduce((n,data)=>n+data.byteLength,0)>before,
    '普通帧应立即冲刷前一帧，不等下一个关键帧才显示点击反馈');
  view.video.currentTime=1;
  view.video.buffered={length:1,start:()=>0,end:()=>4};
  updateEnd();
  assert.ok(view.video.currentTime>3.8,'直播落后时应追到最新画面，而非顺序播放旧缓冲');
  appended.length=0;
  view.handleVideoMessage('videoMeta', {streamId:1,viewportWidth:640,viewportHeight:480,frameRate:15});
  view.handleVideoMessage('videoFrame',key);
  open();
  view.handleVideoMessage('videoFrame',new Uint8Array([0,0,0,1,0x41,0x88]));
  const restarted=Buffer.concat(appended.map((data)=>Buffer.from(data)));
  const mdhd=restarted.indexOf('mdhd');
  const tfhd=restarted.indexOf('tfhd');
  assert.ok(mdhd>=0 && tfhd>=0,'新编码流必须重新输出初始化信息');
  const duration=restarted.readUInt32BE(tfhd+12)/restarted.readUInt32BE(mdhd+16);
  assert.ok(Math.abs(duration-1/15)<0.0001,'片段时长必须跟随实际选择的帧率');
});
