import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  static let frameName = "Studio"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Extend content under the titlebar and reclaim that band for the shell.
    // The traffic lights stay real — they just float over our content, which
    // insets itself on the left to clear them.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true

    // Where it was last closed, at the size it had: AppKit keeps the frame
    // in the studio's defaults under this name as the window moves and
    // resizes, and the first launch keeps the nib's. After the style above,
    // which keeps the content's size and so would take the title bar's
    // height off a frame restored before it, on every launch. When macOS
    // restores the window itself, after an app was killed rather than quit,
    // its frame comes after this one and is the same last frame.
    self.setFrameUsingName(Self.frameName)
    self.setFrameAutosaveName(Self.frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    EmbedderTexturePlugin.register(
      with: flutterViewController.registrar(forPlugin: "EmbedderTexturePlugin"))
    ClipboardImagePlugin.register(
      with: flutterViewController.registrar(forPlugin: "ClipboardImagePlugin"))
    registerWindowChannel(
      flutterViewController.registrar(forPlugin: "WindowChannel"))

    super.awakeFromNib()
  }

  /// Lets Dart name this window after the project it was opened on.
  ///
  /// Small enough to live here rather than in its own plugin file, which would
  /// mean editing the Xcode project. Note [titleVisibility] is `.hidden` above,
  /// so the title never appears in the window itself — it reaches the user
  /// through Mission Control, the Window menu, and the Dock icon's menu.
  private func registerWindowChannel(_ registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutterware/window",
      binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTitle":
        guard let title = call.arguments as? String else {
          result(FlutterError(code: "bad_args",
                              message: "title string required", details: nil))
          return
        }
        self?.title = title
        result(nil)
      // Which project this window is, in the Dock and in ⌘-Tab. Measured: the
      // switcher does follow applicationIconImage, and neither surface honours
      // per-size representations — so one image is all there is to send.
      case "setIcon":
        guard let png = call.arguments as? FlutterStandardTypedData,
              let image = NSImage(data: png.data) else {
          result(FlutterError(code: "bad_args",
                              message: "png bytes required", details: nil))
          return
        }
        NSApplication.shared.applicationIconImage = image
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
