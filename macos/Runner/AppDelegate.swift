import Cocoa
import FlutterMacOS

/// 菜单栏常驻 + 优雅退出（参考 GhostModelDeck 同款实现）：
/// - 关闭主窗口不退出：转入菜单栏（accessory 策略，Dock 图标隐藏）；
/// - 菜单栏入口：打开主窗口 / 退出；被 MacLauncher 托管时隐藏
///   （setEntryManaged，由启动器菜单栏统一呈现）；
/// - 退出前经 shutdownChannel 调 Dart 侧 prepareToQuit 收尾（停会话/
///   中转），Dart 回报 true 才放行。
@main
class AppDelegate: FlutterAppDelegate {
  var shutdownChannel: FlutterMethodChannel?
  private var terminating = false
  private var statusItem: NSStatusItem?
  private var entryManaged = false

  func configureWindow(_ window: NSWindow) {
    mainFlutterWindow = window
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      let image = NSImage(named: NSImage.applicationIconName)?.copy() as? NSImage
      image?.size = NSSize(width: 18, height: 18)
      button.image = image ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Ghost Codex Inspect")
      button.toolTip = "Ghost Codex Inspect"
      button.setAccessibilityLabel("Ghost Codex Inspect")
    }
    let menu = NSMenu()
    let openItem = NSMenuItem(title: "打开 Ghost Codex Inspect", action: #selector(showMainWindow(_:)), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(title: "退出 Ghost Codex Inspect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    item.menu = menu
    statusItem = item
    item.isVisible = !entryManaged
    NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: window)
  }

  /// MacLauncher 托管：隐藏自有菜单栏入口（启动器菜单栏已代为呈现）。
  func setEntryManaged(_ managed: Bool) -> Bool {
    entryManaged = managed
    guard let item = statusItem else { return false }
    item.isVisible = !managed
    return item.isVisible == !managed
  }

  @objc private func mainWindowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  @objc func showMainWindow(_ sender: Any?) {
    guard let window = mainFlutterWindow else { return }
    NSApp.setActivationPolicy(.regular)
    if window.isMiniaturized { window.deminiaturize(sender) }
    window.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let channel = shutdownChannel else { return .terminateNow }
    if terminating { return .terminateLater }
    terminating = true
    channel.invokeMethod("prepareToQuit", arguments: nil) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let finished = result as? Bool == true
        if !finished {
          self.terminating = false
          NSApp.activate(ignoringOtherApps: true)
          let alert = NSAlert()
          alert.messageText = "退出未完成"
          alert.informativeText = (result as? FlutterError)?.message ?? "中继会话或中转尚未完成收尾。"
          alert.runModal()
        }
        sender.reply(toApplicationShouldTerminate: finished)
      }
    }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow(sender)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
