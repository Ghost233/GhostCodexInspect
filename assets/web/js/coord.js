/**
 * 坐标换算工具（DOM 重绘模式 → 输入反向专用，#11 接入）
 *
 * 背景（docs/research/dom-replay.md §4.2）：
 * - 远程端在 iframe 中重建目标应用 DOM；当远程端视口与源视口尺寸不一致时，
 *   iframe 用 CSS transform scale(s) 等比缩放显示。
 * - 远端点击坐标是「iframe 内 CSS px」，需除以缩放系数 s 还原为「源视口 CSS px」。
 * - CDP Input 域的坐标就是 CSS px，devicePixelRatio 不参与换算。
 *
 * 即：源 CSS px = 远端 iframe CSS px ÷ 缩放系数 s
 */

/**
 * 由源视口尺寸与远程端显示尺寸计算缩放系数。
 * 取宽、高中较小的比值，保证完整画面等比内嵌（contain 语义）。
 *
 * @param {number} sourceWidth  源视口宽（目标应用窗口 innerWidth，CSS px）
 * @param {number} sourceHeight 源视口高（CSS px）
 * @param {number} remoteWidth  远程端舞台可用宽（CSS px）
 * @param {number} remoteHeight 远程端舞台可用高（CSS px）
 * @returns {number} 缩放系数 s（远端显示尺寸 = 源尺寸 × s）
 */
export function computeScale(sourceWidth, sourceHeight, remoteWidth, remoteHeight) {
  if (
    !Number.isFinite(sourceWidth) || !Number.isFinite(sourceHeight) ||
    !Number.isFinite(remoteWidth) || !Number.isFinite(remoteHeight) ||
    sourceWidth <= 0 || sourceHeight <= 0 ||
    remoteWidth <= 0 || remoteHeight <= 0
  ) {
    throw new RangeError('computeScale: 尺寸必须为正数');
  }
  return Math.min(remoteWidth / sourceWidth, remoteHeight / sourceHeight);
}

/**
 * 远端 iframe 内坐标 → 源视口 CSS px 坐标（供 CDP Input.dispatchMouseEvent）。
 *
 * @param {number} x 远端 iframe 内 x（CSS px）
 * @param {number} y 远端 iframe 内 y（CSS px）
 * @param {number} scale 缩放系数 s（由 computeScale 得到；1 表示无缩放）
 * @returns {{x: number, y: number}} 源视口 CSS px 坐标
 */
export function toSourceCssPx(x, y, scale) {
  if (!Number.isFinite(scale) || scale <= 0) {
    throw new RangeError('toSourceCssPx: scale 必须为正数');
  }
  return { x: x / scale, y: y / scale };
}

/**
 * 反向换算：源视口坐标 → 远端 iframe 显示坐标。
 * 用途：未来在远端叠加提示（如焦点高亮框）时，把源侧元素 rect 画回远端。
 *
 * @param {number} x 源视口 x（CSS px）
 * @param {number} y 源视口 y（CSS px）
 * @param {number} scale 缩放系数 s
 * @returns {{x: number, y: number}} 远端 iframe 显示坐标（CSS px）
 */
export function toRemoteCssPx(x, y, scale) {
  if (!Number.isFinite(scale) || scale <= 0) {
    throw new RangeError('toRemoteCssPx: scale 必须为正数');
  }
  return { x: x * scale, y: y * scale };
}
