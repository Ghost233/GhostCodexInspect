/**
 * Replayer liveMode 接入点（DOM 重绘模式远端重建）
 *
 * 方案（docs/research/dom-replay.md §2、§3.1）：
 * - 用 @rrweb/replay 的 Replayer（liveMode: true），不用 rrweb-player。
 * - 握手时中转依次推 meta（视口/href）→ full（FullSnapshot）→ inc/batch 增量流。
 * - Replayer 以缓冲基线 startLive(Date.now() - BUFFER_MS) 吸收网络与节流延迟。
 * - 重建在 sandboxed iframe 中进行（Replayer 内部强制沙箱）。
 *
 * 本期状态：数据通道（dom）由 #11 接通，本模块提供完整入口函数；
 * 无数据时所有函数安全无操作，不报错。
 */
import { Replayer } from '../vendor/rrweb-replay.js';
import { computeScale } from './coord.js';

const LIVE_BUFFER_MS = 1000; // liveMode 缓冲基线（官方 live-mode 配方建议值）

/**
 * DOM 重绘会话：持有一个 Replayer 实例与握手期缓存的事件。
 */
export class DomReplaySession {
  /**
   * @param {HTMLElement} host 挂载 Replayer iframe 的容器
   */
  constructor(host) {
    this.host = host;
    this.replayer = null;
    /** @type {object|null} 缓存的 meta 事件（full 未到时先存着） */
    this._metaEvent = null;
    /** @type {object[]} full 到达前暂存的增量事件（防乱序丢失） */
    this._pendingInc = [];
    /** 视图尺寸模式（#17）：'fit' 自适应舞台 | 'actual' 原始尺寸（可滚动）。 */
    this.sizeMode = 'fit';

    // 自适应重排（#17）：窗口 resize 与页签 hidden→visible 都要重新适配。
    // actual 模式下无需缩放，跳过。
    const refit = () => {
      if (this.sizeMode === 'fit') this.fitToViewport(this._metaEvent);
    };
    window.addEventListener('resize', refit);
    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(refit).observe(host);
    }
  }

  /**
   * 切换视图尺寸模式（#17）：'fit' 等比缩放适配舞台；'actual' 原始尺寸
   * （iframe 按源视口 CSS px 平铺，宿主容器滚动查看，缩放系数为 1）。
   * 'stretch' 回落为 fit：DOM 重绘不做非等比拉伸（iframe 非均匀缩放
   * 会让输入坐标映射失真）。
   */
  setSizeMode(mode) {
    this.sizeMode = mode === 'actual' ? 'actual' : 'fit';
    this.host.classList.toggle('actual', this.sizeMode === 'actual');
    this.fitToViewport(this._metaEvent);
  }

  /**
   * 接收一条 dom 通道事件（入口函数，由 ws-client 分发调用）。
   * 协议对齐点：dom 通道 type ∈ { meta, full, inc, batch }（见 docs/research/dom-replay.md §2）。
   * @param {string} type 信封 type
   * @param {object|object[]} payload rrweb 事件（batch 为数组）
   */
  handleDomMessage(type, payload) {
    switch (type) {
      case 'meta':
        this._metaEvent = payload;
        break;
      case 'full':
        this._mountReplayer(this._metaEvent, payload);
        break;
      case 'inc':
        this._addIncremental(payload);
        break;
      case 'batch':
        if (Array.isArray(payload)) {
          for (const ev of payload) this._addIncremental(ev);
        }
        break;
      default:
        // 未知类型静默忽略（协议演进期保持宽容）
        break;
    }
  }

  /** 收到 full 快照：创建（或重建）Replayer 并进入 liveMode */
  _mountReplayer(metaEvent, fullEvent) {
    this._destroyReplayer();

    const events = [];
    if (metaEvent) events.push(metaEvent);
    if (fullEvent) events.push(fullEvent);
    if (events.length === 0) return; // 无数据不报错

    try {
      this.replayer = new Replayer(events, {
        root: this.host,
        liveMode: true,
        // 远程操作模式下关闭 rrweb 自带的模拟回放鼠标（docs/research/dom-replay.md §3.2）
        mouseTail: false,
        // 无数据期不打印告警噪音
        showWarning: false,
      });
      this.replayer.startLive(Date.now() - LIVE_BUFFER_MS);
    } catch (err) {
      // 快照数据异常时降级为「未重建」状态，等待下一次 full（resync）
      this.replayer = null;
      return;
    }

    // 回放握手期暂存的增量事件
    const pending = this._pendingInc;
    this._pendingInc = [];
    for (const ev of pending) this._addIncremental(ev);

    // 按源视口尺寸适配缩放（输入反向的缩放系数同源，见 coord.js）
    this.fitToViewport(metaEvent);
  }

  /** 增量事件：Replayer 未就绪时暂存，就绪后直接 addEvent */
  _addIncremental(event) {
    if (!event) return;
    if (!this.replayer) {
      this._pendingInc.push(event);
      return;
    }
    try {
      this.replayer.addEvent(event);
    } catch {
      // 增量引用悬空（如中转丢帧）：由上层触发 resync，这里不抛
    }
  }

  /**
   * 按 meta 事件中的源视口尺寸适配 iframe 排版（#17 尺寸模式）：
   * - fit：等比缩放适配远程端舞台；
   * - actual：原始尺寸（scale=1，宿主容器滚动查看）。
   * 缩放系数同时是输入反向的换算依据（coord.js：源 CSS px = 远端 px ÷ s）。
   * @returns {number|null} 当前缩放系数，无数据时为 null
   */
  fitToViewport(metaEvent) {
    const data = metaEvent && metaEvent.data;
    if (!data || !data.width || !data.height) return null;
    const rect = this.host.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return null;
    const scale = this.sizeMode === 'actual'
        ? 1
        : computeScale(data.width, data.height, rect.width, rect.height);
    const iframe = this.host.querySelector('iframe');
    if (iframe) {
      iframe.style.width = data.width + 'px';
      iframe.style.height = data.height + 'px';
      iframe.style.transform = `scale(${scale})`;
    }
    this._scale = scale;
    return scale;
  }

  /** 当前缩放系数（#11 输入反向用；未重建时为 null） */
  get scale() {
    return this._scale ?? null;
  }

  /** 销毁 Replayer（resync 重建前调用） */
  _destroyReplayer() {
    if (this.replayer) {
      try { this.replayer.destroy(); } catch { /* 忽略 */ }
      this.replayer = null;
    }
    this._pendingInc = [];
    this._scale = null;
  }
}
