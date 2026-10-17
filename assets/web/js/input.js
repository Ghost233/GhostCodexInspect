/**
 * 输入捕获层（工单 #11）：在 Replayer iframe 上盖一层透明 overlay，
 * 把远端鼠标/键盘事件换算成源视口 CSS px 后经 input 通道发往中转，
 * 由宿主转成 CDP Input 域可信事件（lib/dom/input_dispatcher.dart）。
 *
 * 坐标换算（docs/research/dom-replay.md §4.2）：
 *   iframe.getBoundingClientRect() 已含 transform scale 的视觉位置；
 *   源 CSS px = (事件 clientX/Y − 视觉 rect 原点) ÷ scale。
 *
 * 协议对齐点：payload schema 见 lib/dom/input_dispatcher.dart
 * （mouse / wheel / text / key 四种 kind）。
 */

/** 可打印键之外的转发白名单（与宿主 kKeyEventParams 对齐） */
const KEY_FORWARD_SET = new Set([
  'Backspace', 'Enter', 'Tab', 'Escape',
  'ArrowLeft', 'ArrowUp', 'ArrowRight', 'ArrowDown',
  'Delete', 'Home', 'End',
]);

const MOUSE_MOVE_MIN_MS = 50; // 鼠标移动节流（远端轨迹无需满帧率）

export class InputCaptureLayer {
  /**
   * @param {HTMLElement} host    #replayer-host（Replayer iframe 的容器，需 position:relative）
   * @param {import('./replay.js').DomReplaySession} session 提供 scale 与 iframe
   * @param {import('./ws-client.js').RelayClient} client    提供 sendInput
   */
  constructor(host, session, client) {
    this.host = host;
    this.session = session;
    this.client = client;
    this._lastMoveSentAt = 0;

    const overlay = document.createElement('div');
    overlay.id = 'input-capture-overlay';
    overlay.tabIndex = 0; // 可聚焦以接收键盘
    overlay.className = 'input-capture-overlay';
    overlay.setAttribute('aria-label', '远程输入捕获层');
    this.overlay = overlay;
    host.appendChild(overlay);

    overlay.addEventListener('mousedown', (e) => this._onMouse(e, 'down'));
    overlay.addEventListener('mouseup', (e) => this._onMouse(e, 'up'));
    overlay.addEventListener('mousemove', (e) => this._onMouse(e, 'move'));
    overlay.addEventListener('wheel', (e) => this._onWheel(e), { passive: false });
    overlay.addEventListener('keydown', (e) => this._onKey(e));
    overlay.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  /** 事件 client 坐标 → 源视口 CSS px；超出 iframe 视觉范围时返回 null */
  _toSource(clientX, clientY) {
    const scale = this.session.scale;
    const iframe = this.host.querySelector('iframe');
    if (!scale || !iframe) return null;
    const rect = iframe.getBoundingClientRect(); // 已含 scale 的视觉位置
    const x = clientX - rect.left;
    const y = clientY - rect.top;
    if (x < 0 || y < 0 || x > rect.width || y > rect.height) return null;
    return { x: x / scale, y: y / scale };
  }

  _send(payload) {
    // 未鉴权/未连接时 sendInput 安全返回 false，无需额外判断
    this.client.sendInput(payload);
  }

  _onMouse(e, action) {
    e.preventDefault();
    if (action === 'down') this.overlay.focus(); // 点击后接管键盘
    if (action === 'move') {
      const now = performance.now();
      if (now - this._lastMoveSentAt < MOUSE_MOVE_MIN_MS) return;
      this._lastMoveSentAt = now;
    }
    const pt = this._toSource(e.clientX, e.clientY);
    if (!pt) return;
    const payload = { kind: 'mouse', action, x: pt.x, y: pt.y };
    if (action !== 'move') {
      payload.button = e.button === 2 ? 'right' : e.button === 1 ? 'middle' : 'left';
      payload.clickCount = 1;
    }
    this._send(payload);
  }

  _onWheel(e) {
    e.preventDefault();
    const pt = this._toSource(e.clientX, e.clientY);
    if (!pt) return;
    // deltaMode：1=行、2=页，统一折算成像素（浏览器行高约 16px，页约 800px）
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1;
    this._send({
      kind: 'wheel',
      x: pt.x,
      y: pt.y,
      deltaX: e.deltaX * unit,
      deltaY: e.deltaY * unit,
    });
  }

  _onKey(e) {
    // 组合键（Cmd/Ctrl）不放行，避免误触浏览器快捷键语义
    if (e.metaKey || e.ctrlKey) return;
    if (e.key.length === 1) {
      // 可打印字符：走 insertText 路径（输入法/粘贴等也归此通道）
      e.preventDefault();
      this._send({ kind: 'text', text: e.key });
      return;
    }
    if (KEY_FORWARD_SET.has(e.key)) {
      e.preventDefault();
      this._send({ kind: 'key', key: e.key });
    }
  }
}
