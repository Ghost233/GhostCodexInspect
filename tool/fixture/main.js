// GhostCodexInspect 开发期最小 Electron 替身主进程。
// 仅创建一个加载 index.html 的窗口；调试端口由命令行参数
// --remote-debugging-port 注入（由宿主启动器透传）。
const { app, BrowserWindow } = require('electron');

// 反节流（2026-10-19 E2E 间歇性帧停滞根因）：fixture 窗口被前台应用
// 遮挡时 Chromium 会暂停/大幅减速合成器，screencast 随之停滞
// （实测低至 0-8 帧/20s）。三个开关让遮挡窗口照常渲染出帧。
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-background-timer-throttling');

function createWindow() {
  const win = new BrowserWindow({ width: 720, height: 480, show: false });
  win.loadFile('index.html');
}

// --gci-second-window：开第二窗口（加载 second.html），用于 #16
// 多 shell tab 切换的 E2E（tool/verify_tab_switch.dart）。
const openSecondWindow = process.argv.includes('--gci-second-window');

app.whenReady().then(() => {
  createWindow();
  if (openSecondWindow) {
    const second = new BrowserWindow({ width: 480, height: 320, show: false });
    second.loadFile('second.html');
  }
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
