import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Mobile-POS friendly min size so the responsive (phone/tablet) layouts
    // can both be demonstrated on desktop by resizing the window.
    self.minSize = NSSize(width: 380, height: 720)

    super.awakeFromNib()
  }
}
