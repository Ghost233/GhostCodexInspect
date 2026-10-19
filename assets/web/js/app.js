/**
 * GhostCodexInspect 远程端入口：顶栏交互、连接状态、WS 与 Replayer 接线。
 */
import { RelayClient, parseHashParams, defaultWsUrl } from './ws-client.js';
import { DomReplaySession } from './replay.js';
import { InputCaptureLayer } from './input.js';
import { VideoView } from './video.js';

const $ = (id) => document.getElementById(id);

/* ---------- 模式指示：跟随宿主会话自动切换（不再手选） ---------- */

/**
 * 当前显示模式。null=尚无会话数据；'dom'|'video' 由到达的数据通道
 * 推断（宿主侧会话互斥，同一时刻只有一种会话在广播）。
 * 2026-10-19 用户反馈：手选模式与宿主会话不一致时看到空画面，
 * 改为完全自动跟随。
 */
let currentMode = null;

const MODE_LABELS = { dom: 'DOM 重绘模式', video: '视频流模式' };

function applyMode(mode) {
  if (mode === currentMode) return;
  currentMode = mode;
  const panes = { dom: $('stage-dom'), video: $('stage-video') };
  for (const [m, pane] of Object.entries(panes)) {
    if (pane) pane.classList.toggle('hidden', m !== mode);
  }
  // #22：视频设置只在视频流模式显示
  const videoSettings = $('video-settings');
  if (videoSettings) videoSettings.classList.toggle('hidden', mode !== 'video');
  const label = $('mode-label');
  if (label) label.textContent = MODE_LABELS[mode] || '等待会话…';
  updateFreshness(); // 切模式立即刷新指示（另一模式可能久无数据）
  if (viewportSync) viewportSync(); // 新模式窗格尺寸回传宿主
}

/* ---------- 自适应视口跟随（2026-10-19 需求） ----------
 * 「自适应」= Codex 页面内部视口跟随本浏览器舞台尺寸：ResizeObserver
 * 监听舞台，防抖 300ms 后经 ctrl setViewport 回传宿主，宿主用
 * Emulation.setDeviceMetricsOverride 让目标页按该尺寸原生重排。
 * 只在 fit 尺寸模式下回传；只读预览（ro=1）不回传（多远端并存时
 * 以操作端为准）。 */
let viewportSync = null; // () => void，main() 装配
let currentSizeMode = 'fit'; // 尺寸切换三态循环的权威状态

function setupViewportSync(client, session, readOnly) {
  if (readOnly) return;
  let timer = null;
  const send = () => {
    if (session.sizeMode !== 'fit') return;
    const pane = currentMode === 'video' ? $('stage-video') : $('stage-dom');
    if (!pane || pane.classList.contains('hidden')) return;
    const w = Math.floor(pane.clientWidth);
    const h = Math.floor(pane.clientHeight);
    if (w >= 64 && h >= 64) client.setViewport(w, h);
  };
  viewportSync = () => {
    clearTimeout(timer);
    timer = setTimeout(send, 300);
  };
  const observer = new ResizeObserver(() => viewportSync());
  for (const id of ['stage-dom', 'stage-video']) {
    const pane = $(id);
    if (pane) observer.observe(pane);
  }
}

/* ---------- 顶栏：视图尺寸模式切换（#17 问题 1） ---------- */

const SIZE_MODE_KEY = 'gci.viewSizeMode';

/**
 * @param {import('./replay.js').DomReplaySession} session
 * @param {import('./video.js').VideoView} [videoView]
 */
function setupSizeToggle(session, videoView) {
  const btn = $('size-toggle');
  if (!btn) return;
  // 三态循环：自适应（等比内嵌）→ 拉伸填满（变形填舞台，2026-10-19
  // 用户选择）→ 原始尺寸（1:1 滚动查看）
  const MODES = ['fit', 'stretch', 'actual'];
  const LABELS = { fit: '自适应', stretch: '拉伸填满', actual: '原始尺寸' };
  const TITLES = {
    fit: '等比缩放适配窗口（比例不符时留边），点击切换',
    stretch: '拉伸填满舞台（画面会变形），点击切换',
    actual: '按源视口原始尺寸显示（可滚动查看），点击切换',
  };
  const apply = (mode) => {
    currentSizeMode = mode; // 循环基准：DOM 在 stretch 回落 fit，不能读 session.sizeMode
    session.setSizeMode(mode);
    if (videoView) videoView.setSizeMode(mode);
    btn.textContent = LABELS[mode];
    btn.title = TITLES[mode];
    btn.setAttribute('aria-pressed', String(mode !== 'fit'));
    // 切回自适应时立即回传一次舞台尺寸（让目标页视口跟随重排）
    if (mode === 'fit' && viewportSync) viewportSync();
  };
  btn.addEventListener('click', () => {
    const next = MODES[(MODES.indexOf(currentSizeMode) + 1) % MODES.length];
    try { localStorage.setItem(SIZE_MODE_KEY, next); } catch { /* 隐私模式等忽略 */ }
    apply(next);
  });
  let stored = 'fit';
  try {
    const v = localStorage.getItem(SIZE_MODE_KEY);
    if (v && MODES.includes(v)) stored = v;
  } catch { /* 忽略 */ }
  apply(stored);
}

/* ---------- 视频流设置（#22）：播放路径 + 解码偏好 ---------- */

const PLAYBACK_PATH_KEY = 'gci.videoPlaybackPath';
const DECODE_PREF_KEY = 'gci.videoDecodePref';

/**
 * @param {import('./video.js').VideoView} videoView
 */
function setupVideoSettings(videoView) {
  const pathSel = $('playback-path');
  const prefSel = $('decode-pref');
  if (!pathSel || !prefSel) return;
  try {
    const storedPath = localStorage.getItem(PLAYBACK_PATH_KEY);
    if (storedPath) pathSel.value = storedPath;
    const storedPref = localStorage.getItem(DECODE_PREF_KEY);
    if (storedPref) prefSel.value = storedPref;
  } catch { /* 隐私模式等忽略 */ }
  videoView.setPlaybackPath(pathSel.value);
  videoView.setDecodePref(prefSel.value);
  pathSel.addEventListener('change', () => {
    try { localStorage.setItem(PLAYBACK_PATH_KEY, pathSel.value); } catch { /* 忽略 */ }
    videoView.setPlaybackPath(pathSel.value);
  });
  prefSel.addEventListener('change', () => {
    try { localStorage.setItem(DECODE_PREF_KEY, prefSel.value); } catch { /* 忽略 */ }
    videoView.setDecodePref(prefSel.value);
  });
  // #25：解码支持检测（本浏览器硬解/软解矩阵）
  const probeBtn = $('probe-decode');
  const supportEl = $('decode-support');
  if (probeBtn && supportEl) {
    probeBtn.addEventListener('click', async () => {
      probeBtn.disabled = true;
      try {
        const { probeDecodeSupport } = await import('./video.js');
        const rows = await probeDecodeSupport();
        const label = { h264: 'H.264', hevc: 'H.265', av1: 'AV1' };
        const parts = ['h264', 'hevc', 'av1'].map((c) => {
          const wc = rows.filter((r) => r.codec === c && r.engine === 'webcodecs');
          const hw = wc.find((r) => r.pref === 'hardware')?.supported;
          const sw = wc.find((r) => r.pref === 'software')?.supported;
          const mse = rows.find((r) => r.codec === c && r.engine === 'mse')?.supported;
          return `${label[c]} 硬${hw ? '✓' : '✗'}软${sw ? '✓' : '✗'} MSE${mse ? '✓' : '✗'}`;
        });
        supportEl.textContent = parts.join(' ｜ ');
        supportEl.classList.remove('hidden');
      } finally {
        probeBtn.disabled = false;
      }
    });
  }
}

/* ---------- 顶栏：刷新新鲜度指示（#17 问题 3） ---------- */

/** 各通道最近一次数据到达时间（ms epoch）。 */
const lastDataAt = { dom: 0, video: 0 };
const FRESH_STALE_MS = 3000;

function updateFreshness() {
  const el = $('freshness');
  if (!el) return;
  if (!currentMode) {
    el.classList.add('hidden');
    return;
  }
  const last = currentMode === 'video' ? lastDataAt.video : lastDataAt.dom;
  if (!last) {
    el.classList.add('hidden');
    return;
  }
  const ms = Date.now() - last;
  el.classList.remove('hidden');
  el.innerHTML =
      '距上次刷新 <span class="freshness-num">' + ms + '</span>ms';
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
        applyMode('dom'); // 模式跟随宿主会话
        lastDataAt.dom = Date.now(); // #17 新鲜度指示
        session.handleDomMessage(envelope.t, envelope.data);
        // 首份全量快照到达后撤下占位层，露出重建画面
        if (envelope.t === 'full') {
          const placeholder = $('stage-placeholder');
          if (placeholder) placeholder.classList.add('hidden');
        }
      } else if (envelope.ch === 'video') {
        // #22 视频流：videoMeta/videoFrame（v2 二进制 payload 为 Uint8Array）
        applyMode('video'); // 模式跟随宿主会话
        lastDataAt.video = Date.now();
        videoView.handleVideoMessage(envelope.t, envelope.data);
        if (envelope.t === 'videoFrame') {
          const placeholder = $('video-placeholder');
          if (placeholder) placeholder.classList.add('hidden');
        }
      } else if (envelope.ch === 'ctrl' && envelope.t === 'shells') {
        // #16：shell 页签栏；点击切换时先复位三个视图，再请求宿主重建会话
        renderShellTabs(envelope.data, client, () => {
          const placeholder = $('stage-placeholder');
          if (placeholder) placeholder.classList.remove('hidden');
          videoView.reset();
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

  // 视频流视图（#22）：H.264 Annex B → WebCodecs/MSE 双引擎
  const videoView = new VideoView($('video-host'), client, { readOnly });
  setupVideoSettings(videoView);

  // 输入捕获层（#11）：overlay 盖在 iframe 上，事件换算源 CSS px 后经
  // input 通道回宿主转 CDP trusted 输入（lib/dom/input_dispatcher.dart）；
  // 只读预览（ro=1）不挂载。
  const inputLayer = readOnly
    ? null
    : new InputCaptureLayer(host, session, client);

  // #17：视图尺寸模式切换（自适应/原始尺寸，双模式同步）+ 新鲜度指示
  setupSizeToggle(session, videoView);
  // 自适应视口跟随：舞台尺寸回传宿主覆盖目标页视口
  setupViewportSync(client, session, readOnly);
  setInterval(updateFreshness, 250);

  // 中转不可达（如本地静态伺服预览）属预期：页面显示「未连接」并自动重连
  client.connect();

  // 暴露调试句柄（方便在控制台验证接入点）
  window.__remote = { client, session, inputLayer, videoView };
}

main();
