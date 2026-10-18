/**
 * WS 客户端：连接中转（Relay），鉴权、自动重连、断线 resync 接入点。
 *
 * ============ 与宿主中转的协议对齐（权威来源：lib/relay/envelope.dart） ============
 * 信封线格式（短键）：
 *   { "v": 1, "ch": "dom"|"frame"|"input"|"ctrl", "t": "<type>", "seq": n,
 *     "ts": <UTC 毫秒>, "data": <任意 JSON> }
 * - dom   通道：DOM 重绘模式的 rrweb 事件（meta / full / inc / batch，见 docs/research/dom-replay.md §2）
 * - frame 通道：画面流模式的画面帧（本期未接通）
 * - input 通道：远程端 → 中转的可信输入（t='input'，#11 接通）
 * - ctrl  通道：鉴权、resync、心跳等控制消息
 *
 * 鉴权：
 * - WS 建立后首消息：{ v:1, ch:'ctrl', t:'auth', seq:1, data:{ token } }
 * - 成功：中转回 { ch:'ctrl', t:'authOk' }；
 *   失败：{ ch:'ctrl', t:'authErr', data:{reason} } 后以关闭码 4401 断开；
 *   鉴权超时（5s）同样 4401。鉴权通过前发送其他消息会被拒。
 * - 心跳：发 { ch:'ctrl', t:'ping' }，中转回 { ch:'ctrl', t:'pong', data 原样 }。
 * - 中转主动停服以关闭码 1000 踢连接（走正常重连流程，不算鉴权失败）。
 * - seq：各方向各自单调递增（客户端出站从 1 开始，服务端每连接从 0 开始）；
 *   断线重连后 seq 重置并请求全量 resync。
 * =================================================================================
 *
 * WS 地址：默认同源 `/ws` 路径（ws(s)://<location.host>/ws），
 * 可用 location.hash 的 ws 参数覆盖。宿主访问链接形如
 * http://<addr>:<port>/#t=<token>（token 参数名为 t，兼容裸 #<token> 与 #token=）。
 * 压缩（#14）：大 payload 的 data 为 {"z":"fflate","b64":"<base64(zlib(json))>"}
 * 包装（宿主侧 lib/relay/compression.dart），本模块在分发前解压还原，
 * 上层（replay.js 等）始终看到原始 payload。
 *
 * 信封 v2 二进制帧（#15 二期）：
 * - 鉴权握手声明能力：auth 的 data 带 caps:['bin.v2']；中转 authOk 回显
 *   服务端 caps。协商成功后 dom（zlib 压缩 JSON）与 frame（JPEG 原始
 *   字节）的大流量下行走二进制帧，免 JSON/base64 开销。
 * - 帧布局：15 字节固定头 + 原始 payload。[0]=0x02；[1]=通道 id
 *   （dom=1 frame=2 input=3 ctrl=4）；[2]=类型 id（meta=1 full=2 inc=3
 *   batch=4 resync=5 ping=6 pong=7 auth=8 authOk=9 authErr=10 input=11
 *   frame=12）；[3..6]=seq uint32 小端；[7..14]=ts int64 小端。
 * - 本模块把二进制帧还原成与文本信封同形的 {ch,t,seq,ts,data} 再分发：
 *   dom 的 data 为解压后的 JSON 对象；frame 的 data 为 Uint8Array（JPEG）。
 *   旧中转不回显 bin.v2 时本模块也始终兼容纯文本帧。
 */

import { unzlibSync, strFromU8 } from '../vendor/fflate.js';

const RECONNECT_BASE_MS = 1000; // 重连起步延迟
const RECONNECT_MAX_MS = 15000; // 重连延迟上限

const PROTOCOL_VERSION = 1;
/** 中转鉴权失败/超时的自定义关闭码（与 lib/relay/relay_server.dart 一致） */
const CLOSE_UNAUTHORIZED = 4401;

/** 解析 location.hash 中的参数（支持 #t=xxx&ws=... 形式；t 为 token 的权威键名） */
export function parseHashParams(hash) {
  const raw = (hash || '').replace(/^#/, '');
  const params = {};
  if (!raw) return params;
  for (const pair of raw.split('&')) {
    if (!pair) continue;
    const eq = pair.indexOf('=');
    if (eq === -1) {
      // 兼容裸 token 形式（#abcdef）
      params.token = decodeURIComponent(pair);
      continue;
    }
    params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
  }
  // 权威键名为 t（宿主 accessUrl 生成 #t=<token>），兼容 token= 写法
  if (params.t && !params.token) params.token = params.t;
  return params;
}

/** 由页面地址推导默认 WS 地址 */
export function defaultWsUrl(loc) {
  const scheme = loc.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${loc.host}/ws`;
}

function b64ToU8(b64) {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

/** v2 二进制帧固定头长度（见本文件头注释与 lib/relay/envelope.dart） */
const BINARY_HEADER_LENGTH = 15;
/** 能力协商标记（auth caps / authOk caps 回显） */
const BINARY_CAPABILITY = 'bin.v2';
/** 通道 id ↔ 名（与 RelayChannel 枚举序一致，id = 序 + 1） */
const CHANNEL_NAMES = ['dom', 'frame', 'input', 'ctrl'];
/** 类型 id ↔ 名（与 RelayMessageType 枚举序一致，id = 序 + 1） */
const TYPE_NAMES = [
  'meta', 'full', 'inc', 'batch', 'resync', 'ping', 'pong',
  'auth', 'authOk', 'authErr', 'input', 'frame', 'shells', 'switchTarget',
  'fileChooserHint',
];

/**
 * 解析 v2 二进制帧为与文本信封同形的对象。
 * dom 通道 payload 是 zlib 压缩的 JSON（解压后还原对象）；frame 通道
 * payload 是 JPEG 原始字节（data 为 Uint8Array 交给 screencast.js）。
 * 格式非法抛异常（调用方按坏帧处理）。
 */
export function decodeBinaryFrame(buf) {
  const u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  if (u8.length < BINARY_HEADER_LENGTH) {
    throw new Error('二进制帧短于 15 字节头：' + u8.length);
  }
  const view = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  if (view.getUint8(0) !== 2) throw new Error('不支持的二进制帧版本：' + view.getUint8(0));
  const channel = CHANNEL_NAMES[view.getUint8(1) - 1];
  const type = TYPE_NAMES[view.getUint8(2) - 1];
  if (!channel) throw new Error('未知通道 id：' + view.getUint8(1));
  if (!type) throw new Error('未知消息类型 id：' + view.getUint8(2));
  const payload = u8.subarray(BINARY_HEADER_LENGTH);
  return {
    ch: channel,
    t: type,
    seq: view.getUint32(3, true),
    ts: Number(view.getBigUint64(7, true)),
    data: channel === 'dom'
      ? JSON.parse(strFromU8(unzlibSync(payload)))
      : payload,
  };
}

/**
 * 压缩包装解压（协议对齐：lib/relay/compression.dart）。
 * data 为 {"z":"fflate","b64":...} 时解压还原原始 payload，否则原样返回。
 * 包装损坏抛异常（调用方按坏帧处理）。
 */
export function maybeDecompress(data) {
  if (!data || typeof data !== 'object' || data.z !== 'fflate') return data;
  if (typeof data.b64 !== 'string') throw new Error('压缩包装缺 b64 字段');
  return JSON.parse(strFromU8(unzlibSync(b64ToU8(data.b64))));
}

export class RelayClient {
  /**
   * @param {object} opts
   * @param {string} opts.url    WS 地址
   * @param {string} opts.token  鉴权 token
   * @param {(state: string, detail?: string) => void} opts.onState
   *        状态回调：'connecting' | 'connected' | 'authed' | 'disconnected' | 'auth_failed'
   * @param {(envelope: object) => void} opts.onMessage 收到合法信封时回调（按 ch 分发由上层做）
   */
  constructor(opts) {
    this.url = opts.url;
    this.token = opts.token || '';
    this.onState = opts.onState || (() => {});
    this.onMessage = opts.onMessage || (() => {});

    this.ws = null;
    this.seq = 0;               // 出站信封序号，每连接从 0 开始（首条 auth 为 1）
    this.authed = false;
    this.reconnectDelay = RECONNECT_BASE_MS;
    this.reconnectTimer = null;
    this.closedByUser = false;
  }

  /** 建立连接（失败自动重连，指数退避） */
  connect() {
    this.closedByUser = false;
    this._open();
  }

  /** 主动断开（不再重连） */
  disconnect() {
    this.closedByUser = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close(1000, 'client disconnect');
      this.ws = null;
    }
  }

  _open() {
    this._setState('connecting');
    this.authed = false;
    this.seq = 0;

    let ws;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      // URL 非法等同步异常：进入重连流程而不是抛出
      this._scheduleReconnect();
      return;
    }
    this.ws = ws;
    // v2 二进制帧以 ArrayBuffer 收取（#15）
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      this._setState('connected');
      this.reconnectDelay = RECONNECT_BASE_MS;
      // 协议对齐点：WS 建立后首消息为鉴权；caps 声明 v2 二进制能力（#15）
      this._send('ctrl', 'auth', { token: this.token, caps: [BINARY_CAPABILITY] });
    };

    ws.onmessage = (ev) => {
      let envelope;
      if (ev.data instanceof ArrayBuffer) {
        // v2 二进制帧：还原成文本信封同形对象后走同一分发路径
        try {
          envelope = decodeBinaryFrame(ev.data);
        } catch (err) {
          console.warn('[ws-client] 二进制帧解析失败，丢弃本帧', err);
          return;
        }
        this.onMessage(envelope);
        return;
      }
      try {
        envelope = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (!envelope || typeof envelope !== 'object') return;

      // 鉴权结果处理（权威：authOk / authErr + 4401）
      if (envelope.ch === 'ctrl') {
        if (envelope.t === 'authOk') {
          this.authed = true;
          // 服务端回显的能力清单（诊断用；旧中转无 caps 字段则视为纯文本）
          this.serverCaps = (envelope.data && envelope.data.caps) || [];
          this.binaryEnabled = this.serverCaps.includes(BINARY_CAPABILITY);
          this._setState('authed');
          return;
        }
        if (envelope.t === 'authErr') {
          this.closedByUser = true; // 鉴权失败不重连，等用户处理
          const reason = envelope.data && envelope.data.reason;
          this._setState('auth_failed', reason || '中转拒绝了鉴权 token');
          try { ws.close(); } catch { /* 忽略 */ }
          return;
        }
      }
      // 压缩包装在分发前解压（见 maybeDecompress）
      try {
        envelope.data = maybeDecompress(envelope.data);
      } catch (err) {
        console.warn('[ws-client] 压缩 payload 解压失败，丢弃本帧', err);
        return;
      }
      this.onMessage(envelope);
    };

    ws.onclose = (ev) => {
      this.ws = null;
      const wasAuthed = this.authed;
      this.authed = false;
      if (this.closedByUser) return;

      // 鉴权失败/超时：中转关闭码 4401
      if (ev.code === CLOSE_UNAUTHORIZED) {
        this._setState('auth_failed', '中转以关闭码 ' + ev.code + ' 拒绝了连接（鉴权失败）');
        return;
      }
      this._setState('disconnected');
      // 断线后重连；重连成功（重新鉴权）后请求 resync
      this._needsResync = wasAuthed || this._needsResync;
      this._scheduleReconnect();
    };

    ws.onerror = () => {
      // 错误细节由随后的 close 事件统一处理
    };
  }

  _scheduleReconnect() {
    if (this.closedByUser || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this._open();
    }, this.reconnectDelay);
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
  }

  /**
   * 发送信封（线格式与 lib/relay/envelope.dart 一致：v/ch/t/seq/ts/data）。
   * 本期数据通道未接通：dom/frame 无出站；input 通道为 #11 预留。
   * @returns {boolean} 是否真实发出（未连接时返回 false，不抛异常）
   */
  _send(channel, type, data) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.seq += 1;
    this.ws.send(JSON.stringify({
      v: PROTOCOL_VERSION,
      ch: channel,
      t: type,
      seq: this.seq,
      ts: Date.now(),
      data,
    }));
    return true;
  }

  /**
   * 请求全量 resync（断线重连后的接入点）。
   * 协议对齐点：ctrl 通道 resync 消息（resync 属控制面，与鉴权/心跳同通道），
   * 宿主收到后触发页面全量快照，重发 meta → full → inc 流
   * （宿主侧 DomSession 同时宽容受理 dom 通道 resync）。
   */
  requestResync() {
    return this._send('ctrl', 'resync', {});
  }

  /** 可信输入发送口（input 通道、t='input'；#11 接通后使用，本期为占位，未连接时安全返回 false） */
  sendInput(payload) {
    return this._send('input', 'input', payload);
  }

  /**
   * 请求切换到指定 shell 页面（ctrl 通道 switchTarget，#16 tab 切换）。
   * 宿主停当前会话、attach 目标页后以相同模式重建会话，随后重新广播
   * shells 清单（activeId 更新）与新页面的 meta/full。
   */
  switchTarget(targetId) {
    return this._send('ctrl', 'switchTarget', { targetId });
  }

  _setState(state, detail) {
    this.onState(state, detail);
    // 重连并完成鉴权后，自动补发 resync
    if (state === 'authed' && this._needsResync) {
      this._needsResync = false;
      this.requestResync();
    }
  }
}
