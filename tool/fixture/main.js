// GhostCodexInspect 开发期最小 Electron 替身主进程。
// 仅创建一个加载 index.html 的窗口；调试端口由命令行参数
// --remote-debugging-port 注入（由宿主启动器透传）。
const { app, BrowserWindow } = require('electron');

function createWindow() {
  const win = new BrowserWindow({ width: 720, height: 480 });
  win.loadFile('index.html');
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  app.quit();
});
