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
 */

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

    ws.onopen = () => {
      this._setState('connected');
      this.reconnectDelay = RECONNECT_BASE_MS;
      // 协议对齐点：WS 建立后首消息为鉴权
      this._send('ctrl', 'auth', { token: this.token });
    };

    ws.onmessage = (ev) => {
      let envelope;
      try {
        envelope = JSON.parse(ev.data);
      } catch {
        // 非 JSON 帧：忽略（也可能是后续的二进制批量帧，本期不处理）
        return;
      }
      if (!envelope || typeof envelope !== 'object') return;

      // 鉴权结果处理（权威：authOk / authErr + 4401）
      if (envelope.ch === 'ctrl') {
        if (envelope.t === 'authOk') {
          this.authed = true;
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

  _setState(state, detail) {
    this.onState(state, detail);
    // 重连并完成鉴权后，自动补发 resync
    if (state === 'authed' && this._needsResync) {
      this._needsResync = false;
      this.requestResync();
    }
  }
}
