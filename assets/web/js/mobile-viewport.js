/** 键盘占用视觉视口时保持舞台尺寸，仅上移画面使输入位置可见。 */
export function setupMobileViewport(win, doc) {
  const stage = doc.querySelector('.stage');
  const viewport = win.visualViewport;
  if (!stage || !viewport) return;
  let height = win.innerHeight;
  let focusY = null;
  const update = () => {
    const proxy = doc.activeElement;
    const editing = proxy?.classList.contains('ime-proxy') && proxy.inputMode !== 'none';
    if (!editing) {
      height = win.innerHeight;
      focusY = null;
      doc.body.style.height = '';
      stage.style.transform = '';
      return;
    }
    if (focusY === null) focusY = proxy._remoteFocusY ?? height - 48;
    doc.body.style.height = `${height}px`;
    const covered = Math.max(0, height - viewport.height - viewport.offsetTop);
    const shift = covered > 100
      ? Math.min(covered, Math.max(0, focusY + 48 - viewport.height - viewport.offsetTop)) : 0;
    stage.style.transform = shift ? `translateY(-${shift}px)` : '';
  };
  doc.addEventListener('focusin', update);
  doc.addEventListener('focusout', () => win.setTimeout(update, 0));
  viewport.addEventListener('resize', update);
  viewport.addEventListener('scroll', update);
  win.addEventListener('resize', update);
}
