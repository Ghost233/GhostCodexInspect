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

    super.awakeFromNib()
  }
}
