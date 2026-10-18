/**
 * GhostCodexInspect 远程端入口：顶栏交互、连接状态、WS 与 Replayer 接线。
 */
import { RelayClient, parseHashParams, defaultWsUrl } from './ws-client.js';
import { DomReplaySession } from './replay.js';
import { InputCaptureLayer } from './input.js';
import { ScreencastView } from './screencast.js';

const $ = (id) => document.getElementById(id);

/* ---------- 顶栏：双模式切换 ---------- */

/** 当前显示模式（#17 新鲜度指示按模式取对应通道的数据时间）。 */
let currentMode = 'dom';

function setupModeSwitch() {
  const buttons = document.querySelectorAll('.mode-btn');
  const panes = {
    dom: $('stage-dom'),
    screencast: $('stage-screencast'),
  };
  for (const btn of buttons) {
    btn.addEventListener('click', () => {
      currentMode = btn.dataset.mode;
      for (const b of buttons) {
        const active = b === btn;
        b.classList.toggle('active', active);
        b.setAttribute('aria-selected', String(active));
      }
      for (const [mode, pane] of Object.entries(panes)) {
        pane.classList.toggle('hidden', mode !== btn.dataset.mode);
      }
      updateFreshness(); // 切模式立即刷新指示（另一模式可能久无数据）
    });
  }
}

/* ---------- 顶栏：视图尺寸模式切换（#17 问题 1） ---------- */

const SIZE_MODE_KEY = 'gci.viewSizeMode';

/**
 * @param {import('./replay.js').DomReplaySession} session
 * @param {import('./screencast.js').ScreencastView} screencastView
 */
function setupSizeToggle(session, screencastView) {
  const btn = $('size-toggle');
  if (!btn) return;
  const apply = (mode) => {
    session.setSizeMode(mode);
    screencastView.setSizeMode(mode);
    btn.textContent = mode === 'actual' ? '原始尺寸' : '自适应';
    btn.title = mode === 'actual'
      ? '按源视口原始尺寸显示（可滚动查看），点击切换为自适应'
      : '等比缩放适配窗口，点击切换为原始尺寸';
    btn.setAttribute('aria-pressed', String(mode === 'actual'));
  };
  btn.addEventListener('click', () => {
    const next = session.sizeMode === 'actual' ? 'fit' : 'actual';
    try { localStorage.setItem(SIZE_MODE_KEY, next); } catch { /* 隐私模式等忽略 */ }
    apply(next);
  });
  let stored = 'fit';
  try { stored = localStorage.getItem(SIZE_MODE_KEY) === 'actual' ? 'actual' : 'fit'; }
  catch { /* 忽略 */ }
  apply(stored);
}

/* ---------- 顶栏：刷新新鲜度指示（#17 问题 3） ---------- */

/** 各通道最近一次数据到达时间（ms epoch）。 */
const lastDataAt = { dom: 0, frame: 0 };
const FRESH_STALE_MS = 3000;

function updateFreshness() {
  const el = $('freshness');
  if (!el) return;
  const last = currentMode === 'screencast' ? lastDataAt.frame : lastDataAt.dom;
  if (!last) {
    el.classList.add('hidden');
    return;
  }
  const ms = Date.now() - last;
  el.classList.remove('hidden');
  el.textContent = `距上次刷新 ${ms}ms`;
  el.classList.toggle('stale', ms > FRESH_STALE_MS);
}

/* ---------- 舞台指针指示点（#17 问题 4） ---------- */

/** 远端鼠标移动时在舞台上显示指示点（双模式通用，只读预览同样生效）。 */
function setupCursorDot() {
  const dot = document.createElement('div');
  dot.className = 'cursor-dot hidden';
  document.body.appendChild(dot);
  const stage = document.querySelector('.stage');
  if (!stage) return;
  stage.addEventListener('mousemove', (e) => {
    dot.classList.remove('hidden');
    dot.style.left = `${e.clientX}px`;
    dot.style.top = `${e.clientY}px`;
  });
  stage.addEventListener('mouseleave', () => dot.classList.add('hidden'));
}

/* ---------- 连接状态指示与错误横幅 ---------- */

const connIndicator = $('conn-indicator');
const connText = $('conn-text');
const errorBanner = $('error-banner');

const STATE_LABELS = {
  connecting: '连接中…',
  connected: '已连接，鉴权中…',
  authed: '已连接',
  disconnected: '未连接',
  auth_failed: '鉴权失败',
};

function setConnState(state, detail) {
  const cls = {
    connecting: 'connecting',
    connected: 'connecting',
    authed: 'connected',
    disconnected: 'disconnected',
    auth_failed: 'error',
  }[state] || 'disconnected';
  connIndicator.className = 'conn-indicator ' + cls;
  connText.textContent = STATE_LABELS[state] || state;

  if (state === 'auth_failed') {
    showError('鉴权失败：' + (detail || 'token 无效或已过期') +
      '。请从宿主重新获取带 token 的访问链接（URL # 后的部分）。');
  } else if (state === 'authed' || state === 'disconnected' || state === 'connecting') {
    hideError();
  }
}

function showError(msg) {
  errorBanner.textContent = msg;
  errorBanner.classList.remove('hidden');
}

function hideError() {
  errorBanner.classList.add('hidden');
}

/* ---------- shell 页签栏（#16）：多 shell 页面切换 ---------- */

/**
 * 渲染 shell 页签。data = {targets: [{id,title,url,primary}], activeId}
 * （宿主 ctrl shells 广播）。单个 shell 时隐藏整栏。
 * @param {import('./ws-client.js').RelayClient} client
 * @param {() => void} onBeforeSwitch 切换前的视图复位（占位层/帧清理）
 */
function renderShellTabs(data, client, onBeforeSwitch) {
  const bar = $('shell-tabs');
  if (!bar) return;
  const targets = (data && Array.isArray(data.targets)) ? data.targets : [];
  if (targets.length < 2) {
    bar.classList.add('hidden');
    bar.replaceChildren();
    return;
  }
  bar.classList.remove('hidden');
  bar.replaceChildren();
  for (const t of targets) {
    const btn = document.createElement('button');
    btn.className = 'shell-tab';
    btn.setAttribute('role', 'tab');
    const active = t.id === data.activeId;
    btn.classList.toggle('active', active);
    btn.setAttribute('aria-selected', String(active));
    // 标签：标题优先；空标题用 url 尾部；主窗口加标记
    let label = (t.title || '').trim();
    if (!label) {
      try { label = new URL(t.url).pathname.split('/').pop() || t.url; }
      catch { label = t.url || t.id; }
    }
    btn.textContent = t.primary ? `${label} · 主窗口` : label;
    btn.title = t.url || '';
    btn.addEventListener('click', () => {
      if (active) return;
      onBeforeSwitch();
      client.switchTarget(t.id);
    });
    bar.appendChild(btn);
  }
}

/* ---------- 启动 ---------- */

function main() {
  setupModeSwitch();
  setupCursorDot();

  const host = $('replayer-host');
  const session = new DomReplaySession(host);

  // token 鉴权：从 location.hash 读 token；可用 ws 参数覆盖中转地址
  const params = parseHashParams(location.hash);
  const wsUrl = params.ws || defaultWsUrl(location);

  // 工单 #13：宿主「远程视图」页内嵌 WebView 以 #t=<token>&ro=1 加载 → 只读预览，
  // 不挂输入捕获层（输入只放远程端；host 侧照常处理其他远程端的输入）。
  const readOnly = params.ro === '1';
  if (readOnly) {
    $('ro-badge')?.classList.remove('hidden');
  }

  if (!params.token) {
    setConnState('disconnected');
    showError('缺少鉴权 token：访问链接应形如 http://<宿主地址>:<端口>/#t=<令牌>' +
      '。页面骨架可正常浏览，但不会连接中转。');
    return; // 无 token 时不发起连接，骨架页面保持可用
  }

  const client = new RelayClient({
    url: wsUrl,
    token: params.token,
    onState: setConnState,
    onMessage: (envelope) => {
      // 按通道分发（线格式权威：lib/relay/envelope.dart，键名 ch/t/data）
      if (envelope.ch === 'dom') {
        lastDataAt.dom = Date.now(); // #17 新鲜度指示
        session.handleDomMessage(envelope.t, envelope.data);
        // 首份全量快照到达后撤下占位层，露出重建画面
        if (envelope.t === 'full') {
          const placeholder = $('stage-placeholder');
          if (placeholder) placeholder.classList.add('hidden');
        }
      } else if (envelope.ch === 'frame') {
        lastDataAt.frame = Date.now(); // #17 新鲜度指示
        screencastView.handleFrameMessage(envelope.t, envelope.data);
      } else if (envelope.ch === 'ctrl' && envelope.t === 'shells') {
        // #16：shell 页签栏；点击切换时先复位两个视图，再请求宿主重建会话
        renderShellTabs(envelope.data, client, () => {
          const placeholder = $('stage-placeholder');
          if (placeholder) placeholder.classList.remove('hidden');
          screencastView.reset();
        });
      } else if (envelope.ch === 'ctrl' && envelope.t === 'fileChooserHint') {
        // #20：文件对话框被拦截，提示回本机操作
        const hint = (envelope.data && envelope.data.message) ||
          '文件选择需要回本机操作';
        showError(hint);
      }
      // ctrl 的其余类型：本期留钩子，不处理
    },
  });

  // 画面流视图（#12）：帧渲染 + 输入回灌；客户端创建后实例化（传 client）
  const screencastView = new ScreencastView($('screencast-host'), client, {
    readOnly,
  });

  // 输入捕获层（#11）：overlay 盖在 iframe 上，事件换算源 CSS px 后经
  // input 通道回宿主转 CDP trusted 输入（lib/dom/input_dispatcher.dart）；
  // 只读预览（ro=1）不挂载。
  const inputLayer = readOnly
    ? null
    : new InputCaptureLayer(host, session, client);

  // #17：视图尺寸模式切换（自适应/原始尺寸，双模式同步）+ 新鲜度指示
  setupSizeToggle(session, screencastView);
  setInterval(updateFreshness, 250);

  // 中转不可达（如本地静态伺服预览）属预期：页面显示「未连接」并自动重连
  client.connect();

  // 暴露调试句柄（方便在控制台验证接入点）
  window.__remote = { client, session, inputLayer, screencastView };
}

main();
