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

import { Trackpad } from './trackpad.js';

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
 * - 非组合期：桌面按键及手机 input 正文 → text，白名单特殊键 → key；
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
    ta.inputMode = 'text';
    ta.enterKeyHint = 'enter';
    ta.spellcheck = false;
    host.appendChild(ta);
    this.proxy = ta;
    this._composing = false;
    this.targets = [];

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
    ta.addEventListener('beforeinput', (e) => {
      if (this._composing || e.isComposing) return;
      const key = {
        deleteContentBackward: 'Backspace',
        deleteContentForward: 'Delete',
        insertLineBreak: 'Enter',
        insertParagraph: 'Enter',
      }[e.inputType];
      if (key) {
        e.preventDefault();
        onKey(key);
      }
    });
    ta.addEventListener('input', (e) => {
      if (this._composing || e.isComposing) return;
      if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph') {
        ta.value = '';
        return;
      }
      // Android 输入法不一定提供可打印 keydown，正文以实际编辑值为准。
      // compositionend 已转发并清空代理，随后的 input 不会重复发送。
      if (ta.value === '\n') onKey('Enter');
      else if (ta.value) onText(ta.value);
      ta.value = '';
    });
  }

  /** 把键盘焦点交给代理（点击视图后调用）。 */
  setTargets(targets) {
    this.targets = Array.isArray(targets) ? targets : [];
  }

  contains(point) {
    return this.targets.some((r) => point.x >= r.x && point.y >= r.y &&
      point.x <= r.x + r.width && point.y <= r.y + r.height);
  }

  focus(point, soft = true) {
    this.proxy.inputMode = soft ? 'text' : 'none';
    this.proxy._remoteFocusY = point?.y;
    this.proxy.focus({ preventScroll: true });
  }

  blur() { this.proxy.blur?.(); }
}

/** 两种画面共享的鼠标/触摸输入，避免浏览器兼容鼠标事件重复或丢失。 */
export function bindPointerInput(target, { toSource, send, keyboard, getRect = () => target.getBoundingClientRect(), isEditable = (point) => keyboard.contains?.(point) || false }) {
  let pointerId = null;
  let lastPoint = null;
  let button = 'left';
  let lastMove = 0;
  let start = null;
  let pressed = false;
  let multiTouch = false;
  const touches = new Map();
  const cancelDirect = () => {
    if (pressed) send({ kind: 'mouse', action: 'up', ...lastPoint, button, clickCount: 1 });
    pointerId = lastPoint = start = null;
    pressed = multiTouch = false;
    touches.clear();
  };
  const press = () => {
    if (pressed) return;
    send({ kind: 'mouse', action: 'down', ...start.point, button, clickCount: 1 });
    pressed = true;
  };
  const trackpad = new Trackpad(target, { toSource, getRect, send, keyboard, isEditable, onCancel: cancelDirect });
  const center = () => {
    const [a, b] = touches.values();
    return { clientX: (a.clientX + b.clientX) / 2, clientY: (a.clientY + b.clientY) / 2 };
  };
  target.style.touchAction = 'none';
  target.addEventListener('pointerdown', (e) => {
    if (trackpad.handles(e)) return;
    const touch = e.pointerType === 'touch';
    if (touches.has(e.pointerId)) return;
    if ((!touch || touches.size === 0) && (e.isPrimary === false || pointerId !== null)) return;
    const point = toSource(e);
    if (!point) return;
    e.preventDefault();
    target.setPointerCapture(e.pointerId);
    if (touch) {
      touches.set(e.pointerId, { clientX: e.clientX, clientY: e.clientY });
      if (touches.size > 1 || multiTouch) {
        multiTouch = true;
        if (pressed) send({ kind: 'mouse', action: 'up', ...lastPoint, button, clickCount: 1 });
        pressed = false;
        return;
      }
    }
    pointerId = e.pointerId;
    lastPoint = point;
    start = { x: e.clientX, y: e.clientY, point };
    button = e.button === 2 ? 'right' : e.button === 1 ? 'middle' : 'left';
    // 触摸先判定单指点击/拖动，避免第二指落下前就误按远程按钮。
    if (!touch) { press(); keyboard.focus(undefined, isEditable(point)); }
  });
  target.addEventListener('pointermove', (e) => {
    if (trackpad.handles(e)) return;
    if (touches.has(e.pointerId)) {
      e.preventDefault();
      const before = multiTouch && touches.size === 2 ? toSource(center()) : null;
      touches.set(e.pointerId, { clientX: e.clientX, clientY: e.clientY });
      if (multiTouch) {
        const point = touches.size === 2 ? toSource(center()) : null;
        if (before && point) send({ kind: 'wheel', ...point, deltaX: before.x - point.x, deltaY: before.y - point.y });
        return;
      }
    }
    if (e.isPrimary === false || (e.pointerType === 'touch' && pointerId !== e.pointerId)) return;
    const point = toSource(e);
    if (!point) return;
    lastPoint = point;
    if (e.pointerType === 'touch' && !pressed) {
      if (Math.hypot(e.clientX - start.x, e.clientY - start.y) < 12) return;
      press();
    }
    const now = performance.now();
    if (now - lastMove < MOUSE_MOVE_MIN_MS) return;
    lastMove = now;
    send({ kind: 'mouse', action: 'move', ...point,
      ...(pointerId !== null ? { button, buttons: button === 'right' ? 2 : button === 'middle' ? 4 : 1 } : { buttons: 0 }) });
  });
  const finish = (e, cancelled) => {
    if (trackpad.handles(e)) return;
    if (e.pointerType === 'touch') {
      if (!touches.delete(e.pointerId)) return;
      e.preventDefault();
      if (multiTouch) {
        // 双指结束后，剩余单指仍属于此次滚动，全部抬起才恢复点击。
        if (touches.size === 0) cancelDirect();
        return;
      }
    }
    if (pointerId !== e.pointerId) return;
    e.preventDefault();
    const point = toSource(e) || lastPoint;
    if (!cancelled) press();
    if (pressed) send({ kind: 'mouse', action: 'up', ...point, button, clickCount: 1 });
    pressed = false;
    if (!cancelled && e.pointerType === 'touch') {
      const tapped = Math.hypot(e.clientX - start.x, e.clientY - start.y) < 12;
      if (tapped && isEditable(point)) keyboard.focus({ x: e.clientX, y: e.clientY });
      else keyboard.blur?.();
    }
    cancelDirect();
  };
  target.addEventListener('pointerup', (e) => finish(e, false));
  target.addEventListener('pointercancel', (e) => finish(e, true));
  target.addEventListener('lostpointercapture', (e) => finish(e, true));
  target.addEventListener('wheel', (e) => {
    e.preventDefault();
    const point = toSource(e);
    if (!point) return;
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1;
    send({ kind: 'wheel', ...point, deltaX: e.deltaX * unit, deltaY: e.deltaY * unit });
  }, { passive: false });
  target.addEventListener('contextmenu', (e) => e.preventDefault());
  return trackpad;
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

    this.pointer = bindPointerInput(overlay, {
      toSource: (e) => this._toSource(e.clientX, e.clientY),
      getRect: () => host.querySelector('iframe')?.getBoundingClientRect(),
      send: (payload) => this._send(payload),
      keyboard: this.keyboard,
      isEditable: (point) => {
        const doc = this.host.querySelector('iframe')?.contentDocument;
        const el = doc?.elementFromPoint(point.x, point.y)?.closest('input,textarea,[contenteditable]');
        if (!el || el.disabled || el.readOnly) return false;
        return el.isContentEditable || el.tagName === 'TEXTAREA' ||
          (el.tagName === 'INPUT' && !['hidden','button','submit','reset','checkbox','radio','range','color','file','image'].includes(el.type));
      },
    });
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

}
