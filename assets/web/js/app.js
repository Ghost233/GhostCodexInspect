/**
 * GhostCodexInspect 远程端入口：顶栏交互、连接状态、WS 与 Replayer 接线。
 */
import { RelayClient, parseHashParams, defaultWsUrl } from './ws-client.js';
import { DomReplaySession } from './replay.js';
import { InputCaptureLayer } from './input.js';
import { ScreencastView } from './screencast.js';

const $ = (id) => document.getElementById(id);

/* ---------- 顶栏：双模式切换 ---------- */

function setupModeSwitch() {
  const buttons = document.querySelectorAll('.mode-btn');
  const panes = {
    dom: $('stage-dom'),
    screencast: $('stage-screencast'),
  };
  for (const btn of buttons) {
    btn.addEventListener('click', () => {
      for (const b of buttons) {
        const active = b === btn;
        b.classList.toggle('active', active);
        b.setAttribute('aria-selected', String(active));
      }
      for (const [mode, pane] of Object.entries(panes)) {
        pane.classList.toggle('hidden', mode !== btn.dataset.mode);
      }
    });
  }
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

/* ---------- 启动 ---------- */

function main() {
  setupModeSwitch();

  const host = $('replayer-host');
  const session = new DomReplaySession(host);

  // token 鉴权：从 location.hash 读 token；可用 ws 参数覆盖中转地址
  const params = parseHashParams(location.hash);
  const wsUrl = params.ws || defaultWsUrl(location);

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
        session.handleDomMessage(envelope.t, envelope.data);
        // 首份全量快照到达后撤下占位层，露出重建画面
        if (envelope.t === 'full') {
          const placeholder = $('stage-placeholder');
          if (placeholder) placeholder.classList.add('hidden');
        }
      } else if (envelope.ch === 'frame') {
        screencastView.handleFrameMessage(envelope.t, envelope.data);
      }
      // ctrl 的其余类型：本期留钩子，不处理
    },
  });

  // 画面流视图（#12）：帧渲染 + 输入回灌；客户端创建后实例化（传 client）
  const screencastView = new ScreencastView($('screencast-host'), client);

  // 输入捕获层（#11）：overlay 盖在 iframe 上，事件换算源 CSS px 后经
  // input 通道回宿主转 CDP trusted 输入（lib/dom/input_dispatcher.dart）
  const inputLayer = new InputCaptureLayer(host, session, client);

  // 中转不可达（如本地静态伺服预览）属预期：页面显示「未连接」并自动重连
  client.connect();

  // 暴露调试句柄（方便在控制台验证接入点）
  window.__remote = { client, session, inputLayer, screencastView };
}

main();
