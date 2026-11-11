/** 手机触控板：本地光标、相对移动、双指滚轮和可信鼠标按键。 */
export class Trackpad {
  constructor(target, { toSource, getRect, send, keyboard, isEditable, onCancel }) {
    Object.assign(this, { target, toSource, getRect, send, keyboard, isEditable, onCancel });
    this.mode = 'direct';
    this.position = { x: 0.5, y: 0.5 };
    this.dragLocked = false;
    this.onChange = () => {};
    this.touches = new Map();
    this.pressed = false;
    this.lastTap = 0;
    this.moveTimer = null;
    this.cursor = document.createElement('div');
    this.cursor.className = 'trackpad-cursor hidden';
    this.cursor.innerHTML = '<svg width="20" height="28" viewBox="0 0 24 32" aria-hidden="true"><path d="M2 2v25l6-7 5 10 5-2-5-10h9Z" fill="white" stroke="#161616" stroke-width="1.5" stroke-linejoin="round"/></svg>';
    target.appendChild(this.cursor);
    target.addEventListener('pointerdown', (e) => this.down(e));
    target.addEventListener('pointermove', (e) => this.move(e));
    target.addEventListener('pointerup', (e) => this.up(e));
    for (const name of ['pointercancel', 'lostpointercapture']) {
      target.addEventListener(name, (e) => { if (this.touches.has(e.pointerId)) this.cancel(); });
    }
    new ResizeObserver(() => this.render()).observe(target);
    // DOM 重绘 iframe 获取焦点也会触发 window blur，此时仍在同一页面内。
    globalThis.addEventListener?.('blur', () => { if (!document.hasFocus()) this.cancel(); });
    globalThis.addEventListener?.('pagehide', () => this.cancel());
  }

  handles(e) { return this.mode === 'trackpad' && e.pointerType === 'touch'; }

  setMode(mode) {
    this.cancel();
    this.mode = mode;
    this.render();
  }

  geometry() {
    const image = this.getRect();
    const host = this.target.getBoundingClientRect();
    if (!image?.width || !image.height) return null;
    const left = Math.max(image.left, host.left), top = Math.max(image.top, host.top);
    const right = Math.min(image.left + image.width, host.left + host.width);
    const bottom = Math.min(image.top + image.height, host.top + host.height);
    return right > left && bottom > top ? { left, top, width: right - left, height: bottom - top, host } : null;
  }

  point() {
    const r = this.geometry();
    if (!r) return null;
    const x = r.left + this.position.x * (r.width - 1);
    const y = r.top + this.position.y * (r.height - 1);
    const source = this.toSource({ clientX: x, clientY: y });
    return source ? { x, y, source, rect: r } : null;
  }

  render() {
    const point = this.mode === 'trackpad' ? this.point() : null;
    this.cursor.classList.toggle('hidden', !point);
    if (point) this.cursor.style.transform = `translate(${point.x - point.rect.host.left}px, ${point.y - point.rect.host.top}px)`;
  }

  mouse(action, button = 'left', clickCount = 1) {
    const point = this.point();
    if (!point) return;
    this.send({ kind: 'mouse', action, ...point.source, button,
      buttons: action === 'up' ? 0 : button === 'right' ? 2 : this.pressed || action === 'down' ? 1 : 0,
      ...(action === 'move' ? {} : { clickCount }) });
  }

  flushMove() {
    if (this.moveTimer === null) return;
    clearTimeout(this.moveTimer);
    this.moveTimer = null;
    this.mouse('move', this.pressed ? 'left' : 'none');
  }

  focusInput() {
    const point = this.point();
    if (point && this.isEditable(point.source)) this.keyboard.focus({ x: point.x, y: point.y });
    else this.keyboard.blur?.();
  }

  click(button = 'left', count = 1) {
    if (this.mode !== 'trackpad') return;
    if (button !== 'left') this.lastTap = 0;
    this.flushMove();
    if (this.pressed) this.cancel();
    this.mouse('down', button, count);
    this.mouse('up', button, count);
    if (button === 'left') this.focusInput();
  }

  toggleDrag() {
    if (this.mode !== 'trackpad') return;
    this.lastTap = 0;
    this.flushMove();
    this.dragLocked = !this.dragLocked;
    this.pressed = this.dragLocked;
    this.mouse(this.pressed ? 'down' : 'up');
    this.onChange();
  }

  cancel() {
    this.onCancel?.();
    this.flushMove();
    if (this.pressed) this.mouse('up', 'left', this.double ? 2 : 1);
    this.pressed = this.dragLocked = false;
    this.double = false;
    this.lastTap = 0;
    this.touches.clear();
    this.onChange();
  }

  down(e) {
    if (!this.handles(e)) return;
    if (!this.geometry()) return;
    e.preventDefault();
    this.target.setPointerCapture(e.pointerId);
    const now = performance.now();
    this.touches.set(e.pointerId, { x: e.clientX, y: e.clientY, startX: e.clientX, startY: e.clientY });
    if (this.touches.size === 1) {
      this.started = now;
      this.multi = false;
      this.distance = 0;
      this.double = this.lastTap > 0 && now - this.lastTap < 300;
      if (this.double && !this.dragLocked) { this.pressed = true; this.mouse('down', 'left', 2); }
    } else {
      this.multi = true;
      if (this.pressed) { this.mouse('up'); this.pressed = this.dragLocked = false; this.onChange(); }
      this.lastTap = 0;
    }
    this.render();
  }

  move(e) {
    if (!this.handles(e)) return;
    const touch = this.touches.get(e.pointerId);
    if (!touch) return;
    e.preventDefault();
    const dx = e.clientX - touch.x, dy = e.clientY - touch.y;
    Object.assign(touch, { x: e.clientX, y: e.clientY });
    this.distance = Math.max(this.distance, Math.hypot(touch.x - touch.startX, touch.y - touch.startY));
    if (this.multi) {
      if (this.touches.size < 2) return;
      const point = this.point();
      if (point) this.send({ kind: 'wheel', ...point.source, deltaX: -dx / 2, deltaY: -dy / 2 });
      return;
    }
    const r = this.geometry();
    if (!r) return;
    this.position.x = Math.max(0, Math.min(1, this.position.x + dx / r.width));
    this.position.y = Math.max(0, Math.min(1, this.position.y + dy / r.height));
    this.render(); // 本地立即反馈，不等待视频往返。
    if (this.moveTimer === null) this.moveTimer = setTimeout(() => this.flushMove(), 16);
  }

  up(e) {
    if (!this.handles(e) || !this.touches.has(e.pointerId)) return;
    e.preventDefault();
    this.touches.delete(e.pointerId);
    this.flushMove();
    if (this.touches.size) return;
    const tapped = this.distance < 8 && performance.now() - this.started < 300;
    if (this.multi) {
      if (tapped) this.click('right');
      this.lastTap = 0;
    } else if (this.double && !this.dragLocked) {
      this.mouse('up', 'left', 2);
      this.pressed = false;
      if (tapped) this.focusInput();
      this.lastTap = 0;
    } else if (!this.dragLocked && tapped) {
      this.click();
      this.lastTap = performance.now();
    } else this.lastTap = 0;
    this.double = false;
  }
}
