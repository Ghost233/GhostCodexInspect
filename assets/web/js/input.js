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

/**
 * 键盘转发器（#17）：隐藏 textarea 代理承接焦点与输入法（IME）。
 *
 * 为什么需要 textarea：IME 的 composition 事件只发生在可编辑元素上，
 * 普通 div 收不到中文输入法的成字事件（noVNC 同款方案）。
 *
 * 行为：
 * - compositionstart~compositionend 期间：keydown 一律不转发（避免把
 *   拼音过程串当按键发下去），compositionend 时把成字文本走 text 通道；
 * - 非组合期：可打印字符 → text（preventDefault 保持 textarea 为空），
 *   白名单特殊键 → key；
 * - 组合键（meta/ctrl）不放行（与本仓既有约定一致）。
 */
export class KeyboardForwarder {
  /**
   * @param {HTMLElement} host 代理挂载容器（position:relative）
   * @param {{ onText: (text: string) => void, onKey: (key: string) => void }} handlers
   */
  constructor(host, { onText, onKey }) {
    const ta = document.createElement('textarea');
    ta.className = 'ime-proxy';
    ta.setAttribute('aria-label', '远程键盘输入代理');
    ta.autocapitalize = 'off';
    ta.autocomplete = 'off';
    ta.spellcheck = false;
    host.appendChild(ta);
    this.proxy = ta;
    this._composing = false;

    ta.addEventListener('compositionstart', () => { this._composing = true; });
    ta.addEventListener('compositionend', (e) => {
      this._composing = false;
      if (e.data) onText(e.data);
      ta.value = '';
    });
    ta.addEventListener('compositioncancel', () => {
      this._composing = false;
      ta.value = '';
    });
    ta.addEventListener('keydown', (e) => {
      if (this._composing || e.isComposing) return; // IME 接管期
      if (e.metaKey || e.ctrlKey) return;
      if (e.key.length === 1) {
        e.preventDefault();
        onText(e.key);
      } else if (KEY_FORWARD_SET.has(e.key)) {
        e.preventDefault();
        onKey(e.key);
      }
    });
    // 兜底：非合成路径残留进 textarea 的内容（如粘贴）清空，保持代理无状态
    ta.addEventListener('input', () => { if (!this._composing) ta.value = ''; });
  }

  /** 把键盘焦点交给代理（点击视图后调用）。 */
  focus() {
    this.proxy.focus();
  }
}

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
    overlay.className = 'input-capture-overlay';
    overlay.setAttribute('aria-label', '远程输入捕获层');
    this.overlay = overlay;
    host.appendChild(overlay);

    // 键盘经隐藏 textarea 代理转发（#17：IME 支持）
    this.keyboard = new KeyboardForwarder(overlay, {
      onText: (text) => this._send({ kind: 'text', text }),
      onKey: (key) => this._send({ kind: 'key', key }),
    });

    overlay.addEventListener('mousedown', (e) => this._onMouse(e, 'down'));
    overlay.addEventListener('mouseup', (e) => this._onMouse(e, 'up'));
    overlay.addEventListener('mousemove', (e) => this._onMouse(e, 'move'));
    overlay.addEventListener('wheel', (e) => this._onWheel(e), { passive: false });
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
    if (action === 'down') this.keyboard.focus(); // 点击后代理接管键盘/IME
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
}
