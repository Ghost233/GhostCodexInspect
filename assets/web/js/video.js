// 视频流视图（工单 #22）：video 通道 Annex B AU → 双引擎播放。
//
// 引擎 1 WebCodecs（首选，低延迟 ~300ms）：Annex B AU 直接喂
// VideoDecoder（无 description 即 Annex B 格式），canvas 上屏。
// 引擎 2 MSE（兼容兜底）：Annex B → AVCC 转换后经 mp4-muxer 封装
// fMP4 分片，SourceBuffer 喂 <video>。
// 播放路径 auto=探测 WebCodecs，失败落 MSE；解码偏好映射
// hardwareAcceleration。输入复用 Input 域链路（与画面流同构）。
import { computeScale } from './coord.js';
import { KeyboardForwarder } from './input.js';
import { Muxer, StreamTarget } from '../vendor/mp4-muxer.mjs';

/** Annex B AU → NAL 单元数组 [{type, data(Uint8Array 含头字节)}] */
export function splitNals(au) {
  const nals = [];
  let i = 0;
  const n = au.length;
  const findStart = (from) => {
    for (let j = from; j + 2 < n; j++) {
      if (au[j] === 0 && au[j + 1] === 0) {
        if (au[j + 2] === 1) return [j, 3];
        if (j + 3 < n && au[j + 2] === 0 && au[j + 3] === 1) return [j, 4];
      }
    }
    return null;
  };
  let found = findStart(0);
  while (found) {
    const [start, prefixLen] = found;
    const header = start + prefixLen;
    if (header >= n) break;
    const next = findStart(header + 1);
    const end = next ? next[0] : n;
    nals.push({ type: au[header] & 0x1f, data: au.subarray(header, end) });
    found = next;
  }
  return nals;
}

/** SPS NAL → WebCodecs codec 字符串（avc1.PPCCLL） */
export function codecStringFromSps(spsData) {
  // spsData[0] = NAL 头；[1]=profile_idc [2]=constraint [3]=level_idc
  if (spsData.length < 4) return 'avc1.640028';
  const hex = (b) => b.toString(16).padStart(2, '0').toUpperCase();
  return 'avc1.' + hex(spsData[1]) + hex(spsData[2]) + hex(spsData[3]);
}

/** AU 是否含 IDR（关键帧） */
export function isKeyframeAu(au) {
  return splitNals(au).some((nal) => nal.type === 5);
}

/** Annex B AU → AVCC（4 字节大端长度前缀）+ 可选提取 SPS/PPS */
export function annexbToAvcc(au) {
  const nals = splitNals(au);
  const parts = [];
  let sps = null;
  let pps = null;
  for (const nal of nals) {
    if (nal.type === 7) { sps = nal.data; continue; }
    if (nal.type === 8) { pps = nal.data; continue; }
    if (nal.type === 6) continue; // SEI 丢弃
    const len = new DataView(new ArrayBuffer(4));
    len.setUint32(0, nal.data.length);
    parts.push(new Uint8Array(len.buffer), nal.data);
  }
  const total = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return { avcc: out, sps, pps };
}

/** SPS/PPS → avcC description（MSE 路径的 decoderConfig.description） */
export function buildAvccDescription(sps, pps) {
  const body = [
    0x01, sps[1], sps[2], sps[3], // version + profile/compat/level
    0xFF, // 6bit reserved + lengthSizeMinusOne=3
    0xE1, // 3bit reserved + numSPS=1
    (sps.length >> 8) & 0xff, sps.length & 0xff,
  ];
  for (const b of sps) body.push(b);
  body.push(0x01, (pps.length >> 8) & 0xff, pps.length & 0xff);
  for (const b of pps) body.push(b);
  return new Uint8Array(body);
}

const DECODE_PREF_MAP = {
  auto: 'no-preference',
  hardware: 'prefer-hardware',
  software: 'prefer-software',
};

/**
 * 视频流视图。host 内放 canvas（WebCodecs 路径）与 video（MSE 路径），
 * 按生效引擎切换可见性。
 */
export class VideoView {
  constructor(host, client, { readOnly = false, decodePref = 'auto' } = {}) {
    this.host = host;
    this.client = client;
    this.readOnly = readOnly;
    this.decodePref = decodePref;
    this.playbackPath = 'auto'; // auto | webcodecs | mse
    this.viewportWidth = 0;
    this.viewportHeight = 0;
    this.framesDecoded = 0;
    this.lastError = null;
    this._decoder = null;
    this._decoderConfigured = false;
    this._hasKey = false;
    this._pts = 0;
    this._mse = null; // {mediaSource, sourceBuffer, muxer, queue, video}
    this._engine = null; // 'webcodecs' | 'mse'
    this.ausReceived = 0; // 诊断：累计收到的 AU 数
    this.mseKeyWaits = 0; // 诊断：MSE 等关键帧期间丢弃的非关键 AU 数

    this.canvas = document.createElement('canvas');
    this.canvas.className = 'video-canvas';
    this.video = document.createElement('video');
    this.video.className = 'video-mse hidden';
    this.video.muted = true;
    this.video.autoplay = true;
    host.appendChild(this.canvas);
    host.appendChild(this.video);

    this._keyboard = null;
    if (!readOnly) {
      this._bindInput();
      this._keyboard = new KeyboardForwarder(host, {
        onText: (text) => this.client.sendInput({ kind: 'text', text }),
        onKey: (key) => this.client.sendInput({ kind: 'key', key }),
      });
    }

    new ResizeObserver(() => this._fit()).observe(host);
  }

  setPlaybackPath(mode) {
    this.playbackPath = mode;
    this._teardownEngines();
  }

  setDecodePref(pref) {
    this.decodePref = pref;
    this._teardownEngines();
  }

  setSizeMode(mode) {
    this.sizeMode = mode;
    this.host.classList.toggle('actual', mode === 'actual');
    this._fit();
  }

  _fit() {
    const stage = this.host.parentElement;
    if (!stage || !this.viewportWidth) return;
    if (this.sizeMode === 'actual') {
      for (const el of [this.canvas, this.video]) {
        el.style.width = this.viewportWidth + 'px';
        el.style.height = this.viewportHeight + 'px';
      }
      return;
    }
    const w = stage.clientWidth;
    const h = stage.clientHeight;
    if (!w || !h) return;
    const scale = computeScale(this.viewportWidth, this.viewportHeight, w, h);
    for (const el of [this.canvas, this.video]) {
      el.style.width = Math.round(this.viewportWidth * scale) + 'px';
      el.style.height = Math.round(this.viewportHeight * scale) + 'px';
    }
  }

  handleVideoMessage(type, payload) {
    if (type === 'videoMeta') {
      const meta = typeof payload === 'string' ? JSON.parse(payload) : payload;
      this.viewportWidth = meta.viewportWidth || 0;
      this.viewportHeight = meta.viewportHeight || 0;
      this.canvas.width = this.viewportWidth;
      this.canvas.height = this.viewportHeight;
      this._fit();
      this.host.classList.add('has-frame-pending');
      return;
    }
    if (type !== 'videoFrame') return;
    this.ausReceived++;
    const au = payload instanceof Uint8Array
      ? payload
      : Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
    if (isKeyframeAu(au)) this.keyAusReceived = (this.keyAusReceived || 0) + 1;
    // SPS/PPS 全局缓存：VideoToolbox 管道模式下只在首 IDR 带参数集，
    // 后续 IDR 是裸的——MSE 中途接管必须复用缓存的参数集（#22 踩坑）。
    for (const nal of splitNals(au)) {
      if (nal.type === 7) this._sps = nal.data;
      else if (nal.type === 8) this._pps = nal.data;
    }
    this._feed(au);
  }

  _pickEngine() {
    if (this.playbackPath === 'webcodecs') return 'webcodecs';
    if (this.playbackPath === 'mse') return 'mse';
    return typeof VideoDecoder !== 'undefined' ? 'webcodecs' : 'mse';
  }

  _feed(au) {
    const engine = this._pickEngine();
    if (engine === 'webcodecs') this._feedWebCodecs(au);
    else this._feedMse(au);
  }

  // ---- WebCodecs 路径 ----

  _feedWebCodecs(au) {
    this._engine = 'webcodecs';
    const key = isKeyframeAu(au);
    if (!this._decoderConfigured) {
      if (!key) return; // 等首个关键帧取 SPS
      const sps = splitNals(au).find((nal) => nal.type === 7);
      const codec = sps ? codecStringFromSps(sps.data) : 'avc1.640028';
      this._teardownEngines();
      this._engine = 'webcodecs';
      this._decoder = new VideoDecoder({
        output: (frame) => {
          const ctx = this.canvas.getContext('2d');
          ctx.drawImage(frame, 0, 0);
          frame.close();
          this.framesDecoded++;
          this.host.classList.add('has-frame');
          this.canvas.classList.remove('hidden');
          this.video.classList.add('hidden');
        },
        error: (e) => { this.lastError = String(e); },
      });
      this._decoder.configure({
        codec,
        hardwareAcceleration: DECODE_PREF_MAP[this.decodePref] || 'no-preference',
        optimizeForLatency: true,
        // 无 description → Annex B 格式
      });
      this._decoderConfigured = true;
      this._hasKey = false;
    }
    if (!this._hasKey && !key) return; // 关键帧前丢 delta
    if (key) this._hasKey = true;
    this._pts += 33333;
    this._decoder.decode(new EncodedVideoChunk({
      type: key ? 'key' : 'delta',
      timestamp: this._pts,
      data: au,
    }));
  }

  // ---- MSE 路径 ----

  _feedMse(au) {
    this._engine = 'mse';
    const key = isKeyframeAu(au);
    if (!this._mse) {
      if (!key) { this.mseKeyWaits++; return; }
      const extracted = annexbToAvcc(au);
      const sps = extracted.sps || this._sps;
      const pps = extracted.pps || this._pps;
      if (!sps || !pps) { this.mseMissingSps = (this.mseMissingSps || 0) + 1; return; }
      const mediaSource = new MediaSource();
      this.video.src = URL.createObjectURL(mediaSource);
      this._mse = {
        mediaSource,
        sourceBuffer: null,
        muxer: null,
        queue: [],
        description: buildAvccDescription(sps, pps),
      };
      mediaSource.addEventListener('sourceopen', () => {
       try {
        const mime = 'video/mp4; codecs="avc1.640028"';
        const sb = mediaSource.addSourceBuffer(mime);
        sb.mode = 'segments';
        sb.addEventListener('updateend', () => {
          const next = this._mse.queue.shift();
          if (next) sb.appendBuffer(next);
        });
        this._mse.sourceBuffer = sb;
        this._mse.muxer = new Muxer({
          target: new StreamTarget({
            onData: (data, position) => {  // position 对 MSE 顺序 append 无意义（fragmented 流单调递增）
              try {
                const copy = data.slice(0);
                if (sb.updating) this._mse.queue.push(copy);
                else sb.appendBuffer(copy);
                this.mseBytesAppended = (this.mseBytesAppended || 0) + copy.byteLength;
              } catch (err) { this.lastError = 'append: ' + err; }
            },
            chunked: true,
            // 默认 16MB 攒满才发 onData——直播场景必须小 chunk（#22 踩坑）
            chunkSize: 16384,
          }),
          video: {
            codec: 'avc',
            width: this.viewportWidth || 1280,
            height: this.viewportHeight || 720,
          },
          fastStart: 'fragmented',
          firstTimestampBehavior: 'offset',
        });
        this.canvas.classList.add('hidden');
        this.video.classList.remove('hidden');
        this.host.classList.add('has-frame');
        // 补喂首帧
        this._feedMseAu(au, true);
       } catch (err) { this.lastError = 'sourceopen: ' + (err && err.stack || err); }
      });
      return;
    }
    if (!this._mse.muxer) return; // sourceopen 未到
    this._feedMseAu(au, key);
  }

  _feedMseAu(au, key) {
    let avcc;
    try {
      ({ avcc } = annexbToAvcc(au));
    } catch (err) { this.lastError = 'avcc: ' + err; return; }
    if (!avcc.length) { this.lastError = 'avcc empty'; return; }
    try {
    this._pts += 33333;
    this._mse.muxer.addVideoChunkRaw(
      avcc,
      key ? 'key' : 'delta',
      this._pts,
      33333,
      key ? { decoderConfig: { codec: 'avc1.640028', description: this._mse.description } } : undefined,
    );
      // fastStart=fragmented 时片段在新关键帧到达时自动冲刷，无需手动 finalize
    } catch (err) { this.lastError = 'muxer: ' + err; return; }
    this.framesDecoded++;
  }

  // ---- 输入（与画面流同构：坐标按 canvas 显示尺寸 → 源视口换算） ----

  _bindInput() {
    const target = this.host;
    target.addEventListener('mousedown', (e) => {
      if (this._keyboard) this._keyboard.focus();
      const p = this._toSource(e);
      if (p) this.client.sendInput({ kind: 'mouse', action: 'down', x: p.x, y: p.y, button: 'left', clickCount: 1 });
    });
    target.addEventListener('mouseup', (e) => {
      const p = this._toSource(e);
      if (p) this.client.sendInput({ kind: 'mouse', action: 'up', x: p.x, y: p.y, button: 'left', clickCount: 1 });
    });
    target.addEventListener('mousemove', (e) => {
      const now = performance.now();
      if (now - (this._lastMove || 0) < 50) return;
      this._lastMove = now;
      const p = this._toSource(e);
      if (p) this.client.sendInput({ kind: 'mouse', action: 'move', x: p.x, y: p.y });
    });
    target.addEventListener('wheel', (e) => {
      e.preventDefault();
      const p = this._toSource(e);
      if (!p) return;
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1;
      this.client.sendInput({ kind: 'wheel', x: p.x, y: p.y, deltaX: e.deltaX * unit, deltaY: e.deltaY * unit });
    }, { passive: false });
  }

  _toSource(e) {
    const el = this._engine === 'mse' ? this.video : this.canvas;
    const rect = el.getBoundingClientRect();
    if (!rect.width || !this.viewportWidth) return null;
    const x = (e.clientX - rect.left) * (this.viewportWidth / rect.width);
    const y = (e.clientY - rect.top) * (this.viewportHeight / rect.height);
    if (x < 0 || y < 0 || x > this.viewportWidth || y > this.viewportHeight) {
      return null;
    }
    return { x, y };
  }

  _teardownEngines() {
    if (this._decoder) {
      try { this._decoder.close(); } catch (_) { /* 已关闭 */ }
      this._decoder = null;
    }
    this._decoderConfigured = false;
    this._hasKey = false;
    if (this._mse) {
      try { this._mse.mediaSource.endOfStream(); } catch (_) { /* 忽略 */ }
      this._mse = null;
    }
  }

  reset() {
    this._teardownEngines();
    const ctx = this.canvas.getContext('2d');
    if (ctx) ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.video.removeAttribute('src');
    this.host.classList.remove('has-frame');
  }
}
