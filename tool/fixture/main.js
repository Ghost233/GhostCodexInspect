// GhostCodexInspect 开发期最小 Electron 替身主进程。
// 仅创建一个加载 index.html 的窗口；调试端口由命令行参数
// --remote-debugging-port 注入（由宿主启动器透传）。
const { app, BrowserWindow } = require('electron');

function createWindow() {
  const win = new BrowserWindow({ width: 720, height: 480 });
  win.loadFile('index.html');
}

// --gci-second-window：开第二窗口（加载 second.html），用于 #16
// 多 shell tab 切换的 E2E（tool/verify_tab_switch.dart）。
const openSecondWindow = process.argv.includes('--gci-second-window');

app.whenReady().then(() => {
  createWindow();
  if (openSecondWindow) {
    const second = new BrowserWindow({ width: 480, height: 320 });
    second.loadFile('second.html');
  }
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
