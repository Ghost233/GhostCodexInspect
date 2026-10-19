// 视频流视图（工单 #22/#25）：video 通道 AU → 双引擎播放。
//
// 编码格式（videoMeta.codec 分派）：
// - h264 / hevc：Annex B AU（h264 单字节 NAL 头；hevc 双字节头，
//   type=(b>>1)&0x3f，参数集 VPS(32)/SPS(33)/PPS(34)）
// - av1：低开销 OBU 流（IVF 拆帧载荷；序列头 OBU type 1 即关键帧标记）
//
// 引擎 1 WebCodecs（首选，低延迟）：Annex B/OBU 直喂 VideoDecoder。
// 引擎 2 MSE（兜底）：转 AVCC/封装后经 mp4-muxer 出 fMP4 分片喂
// SourceBuffer。解码偏好映射 hardwareAcceleration。
// 输入复用 Input 域链路。VP9 不支持（宿主侧只有 libvpx 软编，#25）。
import { computeScale } from './coord.js';
import { KeyboardForwarder } from './input.js';
import { Muxer, StreamTarget } from '../vendor/mp4-muxer.mjs';

// ===================== 位流解析 =====================

/** Annex B AU → NAL 数组 [{type, data(含头字节)}]。codec: h264|hevc */
export function splitNals(au, codec = 'h264') {
  const nals = [];
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
    const type = codec === 'hevc'
      ? (au[header] >> 1) & 0x3f
      : au[header] & 0x1f;
    nals.push({ type, data: au.subarray(header, end) });
    found = next;
  }
  return nals;
}

/** 低开销 OBU 流 → [{type, data(含 OBU 头)}]。type=(b>>3)&0x0f */
export function splitObus(payload) {
  const obus = [];
  let i = 0;
  while (i + 1 < payload.length) {
    const header = payload[i];
    const type = (header >> 3) & 0x0f;
    const hasExt = (header & 0x04) !== 0;
    const hasSize = (header & 0x02) !== 0;
    let j = i + 1 + (hasExt ? 1 : 0);
    let size = payload.length - j;
    if (hasSize) {
      size = 0;
      let shift = 0;
      while (j < payload.length) {
        const b = payload[j++];
        size |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7;
      }
    }
    obus.push({ type, data: payload.subarray(i, j + size) });
    i = j + size;
  }
  return obus;
}

/** AU 是否关键帧 */
export function isKeyframeAu(au, codec = 'h264') {
  if (codec === 'av1') return splitObus(au).some((o) => o.type === 1);
  if (codec === 'hevc') {
    return splitNals(au, 'hevc').some((n) => n.type === 19 || n.type === 20);
  }
  return splitNals(au, 'h264').some((n) => n.type === 5);
}

/** h264 SPS NAL → codec 字符串（avc1.PPCCLL） */
export function codecStringFromSps(spsData) {
  if (spsData.length < 4) return 'avc1.640028';
  const hex = (b) => b.toString(16).padStart(2, '0').toUpperCase();
  return 'avc1.' + hex(spsData[1]) + hex(spsData[2]) + hex(spsData[3]);
}

/** Annex B AU → AVCC（4B 大端长度前缀）+ 参数集提取（h264/hevc） */
export function annexbToAvcc(au, codec = 'h264') {
  const nals = splitNals(au, codec);
  const parts = [];
  let vps = null;
  let sps = null;
  let pps = null;
  const paramTypes = codec === 'hevc' ? { 32: 'vps', 33: 'sps', 34: 'pps' }
    : { 7: 'sps', 8: 'pps' };
  const skipTypes = codec === 'hevc' ? new Set([39, 40]) : new Set([6]);
  for (const nal of nals) {
    const role = paramTypes[nal.type];
    if (role === 'vps') { vps = nal.data; continue; }
    if (role === 'sps') { sps = nal.data; continue; }
    if (role === 'pps') { pps = nal.data; continue; }
    if (skipTypes.has(nal.type)) continue; // SEI 丢弃
    const len = new DataView(new ArrayBuffer(4));
    len.setUint32(0, nal.data.length);
    parts.push(new Uint8Array(len.buffer), nal.data);
  }
  const total = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return { avcc: out, vps, sps, pps };
}

/** h264：SPS/PPS → avcC description */
export function buildAvccDescription(sps, pps) {
  const body = [
    0x01, sps[1], sps[2], sps[3],
    0xFF, 0xE1,
    (sps.length >> 8) & 0xff, sps.length & 0xff,
  ];
  for (const b of sps) body.push(b);
  body.push(0x01, (pps.length >> 8) & 0xff, pps.length & 0xff);
  for (const b of pps) body.push(b);
  return new Uint8Array(body);
}

/** hevc：VPS/SPS/PPS → 最小 hvcC description（profile/level 从 SPS 解析，
 *  假定 max_sub_layers_minus1=0——VideoToolbox/libx265 默认如此） */
export function buildHvccDescription(vps, sps, pps) {
  const s = sps; // 含 2 字节 NAL 头
  const body = [
    0x01, // configurationVersion
    s[3] & 0x1f, // profile_space/tier/profile_idc（取 SPS PTL 首字节）
    s[4], s[5], s[6], s[7], // profile_compatibility_flags
    s[8], s[9], s[10], s[11], s[12], s[13], // constraint_indicator_flags
    s[14] || 93, // level_idc
    0xF0, 0x00, // min_spatial_segmentation_idc
    0xFC, // parallelismType=0
    0xFD, // chromaFormat=1 (4:2:0)
    0xF8, 0xF8, // bitDepth 8/8
    0x00, 0x00, // avgFrameRate
    0x07, // constantFrameRate=0 numTemporalLayers=1 temporalIdNested=1 len-1=3
    0x03, // numArrays: vps/sps/pps
  ];
  const pushArray = (type, nal) => {
    body.push(0x80 | type, 0x00, 0x01, (nal.length >> 8) & 0xff, nal.length & 0xff);
    for (const b of nal) body.push(b);
  };
  pushArray(32, vps);
  pushArray(33, sps);
  pushArray(34, pps);
  return new Uint8Array(body);
}

/** av1：av1C description（profile0/level 由参数指定）+ 序列头 OBU */
export function buildAv1cDescription(seqHeaderObu, level = 8) {
  const body = [0x80 | (0 << 5) | level, 0x0C, 0x00, 0x00];
  if (seqHeaderObu) for (const b of seqHeaderObu) body.push(b);
  return new Uint8Array(body);
}

/** 各格式 codec 字符串候选（首个被 isConfigSupported 接受的胜出） */
const CODEC_CANDIDATES = {
  h264: ['avc1.640028'],
  hevc: ['hev1.1.6.L93.B0', 'hev1.1.6.L120.90', 'hvc1.1.6.L93.B0', 'hvc1.1.6.L120.90'],
  av1: ['av01.0.08M.08', 'av01.0.04M.08'],
};

/** 探测解码支持矩阵（#25 用户要求④：收侧硬解/软解检查）。
 * 返回 [{codec, engine: 'webcodecs'|'mse', pref, supported, used}] */
export async function probeDecodeSupport() {
  const rows = [];
  for (const [name, candidates] of Object.entries(CODEC_CANDIDATES)) {
    for (const [pref, label] of [['no-preference', 'auto'], ['prefer-hardware', 'hardware'], ['prefer-software', 'software']]) {
      let supported = false;
      let used = null;
      if (typeof VideoDecoder !== 'undefined') {
        for (const c of candidates) {
          try {
            const r = await VideoDecoder.isConfigSupported({ codec: c, hardwareAcceleration: pref });
            if (r.supported) { supported = true; used = c; break; }
          } catch (_) { /* 探测失败按不支持计 */ }
        }
      }
      rows.push({ codec: name, engine: 'webcodecs', pref: label, supported, used });
    }
    let mseOk = false;
    let mseCodec = null;
    if (typeof MediaSource !== 'undefined') {
      for (const c of candidates) {
        if (MediaSource.isTypeSupported(`video/mp4; codecs="${c}"`)) { mseOk = true; mseCodec = c; break; }
      }
    }
    rows.push({ codec: name, engine: 'mse', pref: 'auto', supported: mseOk, used: mseCodec });
  }
  return rows;
}

const DECODE_PREF_MAP = {
  auto: 'no-preference',
  hardware: 'prefer-hardware',
  software: 'prefer-software',
};

/** 视频流视图。host 内放 canvas（WebCodecs）与 video（MSE）。 */
export class VideoView {
  constructor(host, client, { readOnly = false, decodePref = 'auto' } = {}) {
    this.host = host;
    this.client = client;
    this.readOnly = readOnly;
    this.decodePref = decodePref;
    this.playbackPath = 'auto'; // auto | webcodecs | mse
    this.codec = 'h264'; // videoMeta 下发（#25）
    this.sizeMode = 'fit';
    this.viewportWidth = 0;
    this.viewportHeight = 0;
    this.framesDecoded = 0;
    this.lastError = null;
    this._decoder = null;
    this._decoderConfigured = false;
    this._configuring = null; // hevc/av1 异步选 codec 字符串期间的 Promise
    this._codecString = null; // 探测选定的 codec 字符串
    this._hasKey = false;
    this._pts = 0;
    this._mse = null; // {mediaSource, sourceBuffer, muxer, queue, description}
    this._engine = null;
    this.ausReceived = 0;
    this.keyAusReceived = 0;
    this.mseKeyWaits = 0;
    // 参数集缓存（VT 管道模式只在首 IDR 带参数集，后续裸 IDR 复用缓存）
    this._vps = null;
    this._sps = null;
    this._pps = null;
    this._seqHeader = null; // av1 序列头 OBU

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
    if (this.sizeMode === 'stretch') {
      // 拉伸填满舞台：宽高各自缩放（画面变形，2026-10-19 用户选择）；
      // 输入坐标换算按轴独立（_toSource 用 rect 宽高分别折算），不受影响
      for (const el of [this.canvas, this.video]) {
        el.style.width = w + 'px';
        el.style.height = h + 'px';
      }
      return;
    }
    const scale = computeScale(this.viewportWidth, this.viewportHeight, w, h);
    for (const el of [this.canvas, this.video]) {
      el.style.width = Math.round(this.viewportWidth * scale) + 'px';
      el.style.height = Math.round(this.viewportHeight * scale) + 'px';
    }
  }

  handleVideoMessage(type, payload) {
    if (type === 'videoMeta') {
      const meta = typeof payload === 'string' ? JSON.parse(payload) : payload;
      const newCodec = meta.codec || 'h264';
      if (newCodec !== this.codec) {
        this.codec = newCodec;
        this._teardownEngines(); // 格式变了必须重建解码器
      }
      this.viewportWidth = meta.viewportWidth || 0;
      this.viewportHeight = meta.viewportHeight || 0;
      // 注意：canvas 后备尺寸不再随 meta 设置——编码帧可能被
      // 分辨率模式缩放（#27），后备尺寸以实际解码帧为准（见
      // WebCodecs output），CSS 显示尺寸仍按 meta 视口比例布局。
      this._fit();
      this.host.classList.add('has-frame-pending');
      return;
    }
    if (type !== 'videoFrame') return;
    this.ausReceived++;
    const au = payload instanceof Uint8Array
      ? payload
      : Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
    if (isKeyframeAu(au, this.codec)) this.keyAusReceived++;
    // 参数集缓存（#22 VT 裸 IDR 踩坑；av1 缓存序列头 OBU）
    if (this.codec === 'av1') {
      for (const obu of splitObus(au)) {
        if (obu.type === 1) this._seqHeader = obu.data;
      }
    } else if (this.codec === 'hevc') {
      for (const nal of splitNals(au, 'hevc')) {
        if (nal.type === 32) this._vps = nal.data;
        else if (nal.type === 33) this._sps = nal.data;
        else if (nal.type === 34) this._pps = nal.data;
      }
    } else {
      for (const nal of splitNals(au, 'h264')) {
        if (nal.type === 7) this._sps = nal.data;
        else if (nal.type === 8) this._pps = nal.data;
      }
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

  /** 选 codec 字符串：h264 从 SPS 构造；hevc/av1 探测候选（异步） */
  async _resolveCodecString() {
    if (this._codecString) return this._codecString;
    if (this.codec === 'h264') {
      this._codecString = this._sps
        ? codecStringFromSps(this._sps)
        : CODEC_CANDIDATES.h264[0];
      return this._codecString;
    }
    for (const c of CODEC_CANDIDATES[this.codec] || []) {
      try {
        const r = await VideoDecoder.isConfigSupported({
          codec: c,
          hardwareAcceleration: DECODE_PREF_MAP[this.decodePref] || 'no-preference',
        });
        if (r.supported) { this._codecString = c; return c; }
      } catch (_) { /* 继续下一个候选 */ }
    }
    // 探测全败：退回候选首位（让 configure 报错浮出 lastError）
    this._codecString = (CODEC_CANDIDATES[this.codec] || CODEC_CANDIDATES.h264)[0];
    return this._codecString;
  }

  // ---- WebCodecs 路径 ----

  _feedWebCodecs(au) {
    this._engine = 'webcodecs';
    const key = isKeyframeAu(au, this.codec);
    if (this._configuring) {
      // hevc/av1 的 codec 字符串异步探测期间：挂起后续帧
      this._configuring.then(() => this._feedWebCodecs(au));
      return;
    }
    if (!this._decoderConfigured) {
      if (!key) return; // 等首个关键帧
      this._configuring = this._resolveCodecString().then((codecStr) => {
        this._configuring = null;
        this._teardownEngines();
        this._engine = 'webcodecs';
        this._decoder = new VideoDecoder({
          output: (frame) => {
            // 后备尺寸跟随真实解码帧（编码侧可能按分辨率模式缩放），
            // drawImage 才能整幅填满不拉伸、不留旧内容（2026-10-19
            // 用户反馈：画面「突然过大/小一圈」）。
            if (this.canvas.width !== frame.displayWidth ||
                this.canvas.height !== frame.displayHeight) {
              this.canvas.width = frame.displayWidth;
              this.canvas.height = frame.displayHeight;
            }
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
          codec: codecStr,
          hardwareAcceleration: DECODE_PREF_MAP[this.decodePref] || 'no-preference',
          optimizeForLatency: true,
          // 无 description → h264/hevc Annex B；av1 低开销 OBU
        });
        this._decoderConfigured = true;
        this._hasKey = false;
        this._feedWebCodecs(au); // 补喂触发帧
      }).catch((e) => {
        this._configuring = null;
        this.lastError = 'configure: ' + e;
      });
      return;
    }
    if (!this._hasKey && !key) return;
    if (key) this._hasKey = true;
    this._pts += 33333;
    try {
      this._decoder.decode(new EncodedVideoChunk({
        type: key ? 'key' : 'delta',
        timestamp: this._pts,
        data: au,
      }));
    } catch (e) {
      this.lastError = 'decode: ' + e;
    }
  }

  // ---- MSE 路径 ----

  _mseMime() {
    const c = this._codecString || CODEC_CANDIDATES[this.codec][0];
    return `video/mp4; codecs="${c}"`;
  }

  _mseDescription() {
    if (this.codec === 'hevc') {
      if (!this._vps || !this._sps || !this._pps) return null;
      return buildHvccDescription(this._vps, this._sps, this._pps);
    }
    if (this.codec === 'av1') {
      return buildAv1cDescription(this._seqHeader, 8);
    }
    if (!this._sps || !this._pps) return null;
    return buildAvccDescription(this._sps, this._pps);
  }

  _msePayload(au) {
    if (this.codec === 'av1') return au; // 低开销 OBU 直接喂
    return annexbToAvcc(au, this.codec).avcc;
  }

  _feedMse(au) {
    this._engine = 'mse';
    const key = isKeyframeAu(au, this.codec);
    if (!this._mse) {
      if (!key) { this.mseKeyWaits++; return; }
      const description = this._mseDescription();
      if (!description) { this.mseMissingSps = (this.mseMissingSps || 0) + 1; return; }
      const mediaSource = new MediaSource();
      this.video.src = URL.createObjectURL(mediaSource);
      this._mse = { mediaSource, sourceBuffer: null, muxer: null, queue: [], description };
      mediaSource.addEventListener('sourceopen', () => {
        try {
          const sb = mediaSource.addSourceBuffer(this._mseMime());
          sb.mode = 'segments';
          sb.addEventListener('updateend', () => {
            const next = this._mse.queue.shift();
            if (next) sb.appendBuffer(next);
          });
          this._mse.sourceBuffer = sb;
          this._mse.muxer = new Muxer({
            target: new StreamTarget({
              onData: (data, position) => { // position 对 MSE 顺序 append 无意义
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
              codec: this.codec === 'av1' ? 'av1' : this.codec === 'hevc' ? 'hevc' : 'avc',
              width: this.viewportWidth || 1280,
              height: this.viewportHeight || 720,
            },
            fastStart: 'fragmented',
            firstTimestampBehavior: 'offset',
          });
          this.canvas.classList.add('hidden');
          this.video.classList.remove('hidden');
          this.host.classList.add('has-frame');
          this._feedMseAu(au, true); // 补喂首帧
        } catch (err) {
          this.lastError = 'sourceopen: ' + (err && err.stack || err);
        }
      });
      return;
    }
    if (!this._mse.muxer) return; // sourceopen 未到
    this._feedMseAu(au, key);
  }

  _feedMseAu(au, key) {
    let payload;
    try {
      payload = this._msePayload(au);
    } catch (err) { this.lastError = 'payload: ' + err; return; }
    if (!payload || !payload.length) { this.lastError = 'payload empty'; return; }
    this._pts += 33333;
    try {
      this._mse.muxer.addVideoChunkRaw(
        payload,
        key ? 'key' : 'delta',
        this._pts,
        33333,
        key ? {
          decoderConfig: {
            codec: this._codecString || CODEC_CANDIDATES[this.codec][0],
            description: this._mse.description,
          },
        } : undefined,
      );
      // fastStart=fragmented 时片段在新关键帧到达时自动冲刷，无需手动 finalize
    } catch (err) { this.lastError = 'muxer: ' + err; return; }
    this.framesDecoded++;
  }

  // ---- 输入（坐标按显示元素尺寸 → 源视口换算） ----

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
    this._codecString = null;
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
