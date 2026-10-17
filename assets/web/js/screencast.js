/**
 * 画面流视图（工单 #12）：兜底模式的远程端渲染与输入。
 *
 * 数据面：frame 通道信封——
 * - meta：JSON 字符串 `{viewportWidth, viewportHeight, dpr}`，坐标映射基准
 *   （与 JPEG 像素尺寸解耦：Input 域坐标是视口 CSS px，dpr 不参与换算）；
 * - frame：`{data: <base64 jpeg>, metadata: {...}}`，刷新 <img>。
 *
 * 输入面：点击/滚轮/键盘直接监听在 img 与宿主容器上（画面流无 sandboxed
 * iframe，不需要 overlay）；坐标 = (clientX - imgRect.left) / 显示缩放，
 * 显示缩放 = img.clientWidth / viewportWidth（img 被显式定尺寸为
 * viewportWidth × scale，见 _fit）。
 */
import { computeScale } from './coord.js';

/** 转发的特殊键白名单（与 input.js 同一约定）。 */
const KEY_FORWARD_SET = new Set([
  'Backspace', 'Enter', 'Tab', 'Escape',
  'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
  'Delete', 'Home', 'End',
]);

export class ScreencastView {
  /**
   * @param {HTMLElement} host #screencast-host 容器（tabindex=0）
   * @param {import('./ws-client.js').RelayClient} client 中转客户端
   * @param {{ readOnly?: boolean }} [options] readOnly=true 时只渲染不捕获输入
   *   （工单 #13：宿主内嵌只读预览 ro=1）
   */
  constructor(host, client, options = {}) {
    this.host = host;
    this.client = client;
    this.img = host.querySelector('img');
    this.placeholder = host.querySelector('.stage-placeholder');
    /** 视口元信息（meta 信封到达前为 null，输入拒绝发送）。 */
    this.viewport = null;

    if (!options.readOnly) {
      this._bindInput();
    }
    window.addEventListener('resize', () => this._fit());
    // 模式页签 hidden→visible 时 clientWidth 从 0 变为真实值：观察宿主尺寸
    // 变化触发重排（_fit 在尺寸为 0 时静默跳过，见下）。
    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(() => this._fit()).observe(host);
    }
  }

  /** 处理 frame 通道信封。 */
  handleFrameMessage(type, data) {
    if (type === 'meta') {
      try {
        this.viewport = typeof data === 'string' ? JSON.parse(data) : data;
        this._fit();
      } catch (e) {
        console.warn('[screencast] 非法 meta：', e);
      }
      return;
    }
    if (type === 'frame' && data && typeof data.data === 'string') {
      this.img.src = 'data:image/jpeg;base64,' + data.data;
      if (this.placeholder) this.placeholder.classList.add('hidden');
      this.img.classList.add('has-frame');
    }
  }

  /** 按舞台可用空间等比缩放 img（contain 语义）。舞台隐藏（尺寸 0）时跳过。 */
  _fit() {
    if (!this.viewport) return;
    const stage = this.host.parentElement;
    if (!stage || stage.clientWidth === 0 || stage.clientHeight === 0) return;
    const scale = computeScale(
      this.viewport.viewportWidth,
      this.viewport.viewportHeight,
      stage.clientWidth,
      stage.clientHeight,
    );
    this.img.style.width = `${this.viewport.viewportWidth * scale}px`;
    this.img.style.height = `${this.viewport.viewportHeight * scale}px`;
  }

  /** 事件坐标 → 源视口 CSS px；视口未知或越界返回 null。 */
  _toSource(event) {
    if (!this.viewport || !this.img.classList.contains('has-frame')) return null;
    const rect = this.img.getBoundingClientRect();
    const scale = this.img.clientWidth / this.viewport.viewportWidth;
    const x = (event.clientX - rect.left) / scale;
    const y = (event.clientY - rect.top) / scale;
    if (x < 0 || y < 0 || x > this.viewport.viewportWidth ||
        y > this.viewport.viewportHeight) {
      return null;
    }
    return { x, y };
  }

  _bindInput() {
    const send = (payload) => this.client.sendInput(payload);
    // 与 input.js 同一约定：e.button 数值 → CDP 字符串
    const buttonName = (b) => b === 2 ? 'right' : b === 1 ? 'middle' : 'left';

    this.img.addEventListener('mousedown', (e) => {
      e.preventDefault();
      this.host.focus();
      const p = this._toSource(e);
      if (p) send({ kind: 'mouse', action: 'down', ...p, button: buttonName(e.button), clickCount: e.detail || 1 });
    });
    this.img.addEventListener('mouseup', (e) => {
      const p = this._toSource(e);
      if (p) send({ kind: 'mouse', action: 'up', ...p, button: buttonName(e.button), clickCount: e.detail || 1 });
    });
    this.host.addEventListener('wheel', (e) => {
      e.preventDefault();
      const p = this._toSource(e);
      if (!p) return;
      // deltaMode 折算与 input.js 同一约定：0=像素 1=行 2=页
      const factor = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1;
      send({
        kind: 'wheel', ...p,
        deltaX: e.deltaX * factor,
        deltaY: e.deltaY * factor,
      });
    }, { passive: false });

    this.host.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey) return; // 组合键不放行（避免远程触发本机快捷键语义）
      if (e.key.length === 1) {
        e.preventDefault();
        send({ kind: 'text', text: e.key });
      } else if (KEY_FORWARD_SET.has(e.key)) {
        e.preventDefault();
        send({ kind: 'key', key: e.key });
      }
    });
  }
}
