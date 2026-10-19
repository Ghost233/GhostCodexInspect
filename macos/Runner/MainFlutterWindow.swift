import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // 工单 #13：四模块布局（侧栏 224 + 内容区）的最小可用窗口尺寸。
    let windowFrame = self.frame
    self.contentMinSize = NSSize(width: 960, height: 640)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 原生 seam（菜单栏托管 / 窗口激活 / 退出收尾），Dart 侧见
    // lib/sdk/native_window.dart 与 launcher_connection.dart。
    let nativeChannel = FlutterMethodChannel(
      name: "com.ghost233.ghostcodexinspect/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.shutdownChannel = nativeChannel
    nativeChannel.setMethodCallHandler { call, result in
      if call.method == "setEntryManaged" {
        guard let managed = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_argument", message: "managed 必须为布尔值", details: nil))
          return
        }
        result((NSApp.delegate as? AppDelegate)?.setEntryManaged(managed) ?? false)
        return
      }
      if call.method == "activateMainWindow" {
        (NSApp.delegate as? AppDelegate)?.showMainWindow(nil)
        result(nil)
        return
      }
      result(FlutterMethodNotImplemented)
    }

    // 关闭窗口不销毁（菜单栏常驻后可随时重新打开）
    self.isReleasedWhenClosed = false

    super.awakeFromNib()
    DispatchQueue.main.async { [weak self] in
      guard let window = self, let delegate = NSApp.delegate as? AppDelegate else { return }
      delegate.configureWindow(window)
    }
  }
}
