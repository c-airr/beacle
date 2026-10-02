import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerDialogChannel(flutterViewController)
    registerWindowChannel(flutterViewController)

    super.awakeFromNib()
  }

  // Window size and title for lib/window_control.dart: the split view widens
  // the window to the right (shifting left only when the screen ends), and a
  // tool window gets its own title.
  private func registerWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "beacle/window", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "grow":
        let by = CGFloat(args["by"] as? Double ?? 0)
        guard by > 0, !self.styleMask.contains(.fullScreen), !self.isZoomed,
          let visible = self.screen?.visibleFrame
        else {
          result([0.0, 0.0])
          return
        }
        var frame = self.frame
        let oldX = frame.origin.x
        let oldWidth = frame.size.width
        frame.size.width = min(oldWidth + by, max(oldWidth, visible.width))
        if frame.maxX > visible.maxX {
          frame.origin.x = max(visible.minX, visible.maxX - frame.size.width)
        }
        self.setFrame(frame, display: true, animate: true)
        result([Double(frame.size.width - oldWidth), Double(oldX - frame.origin.x)])
      case "shrink":
        let by = CGFloat(args["by"] as? Double ?? 0)
        let shift = CGFloat(args["shift"] as? Double ?? 0)
        if self.styleMask.contains(.fullScreen) || self.isZoomed {
          result(nil)
          return
        }
        var frame = self.frame
        if frame.size.width - by < 400 {
          result(nil)
          return
        }
        frame.size.width -= by
        frame.origin.x += shift
        self.setFrame(frame, display: true, animate: true)
        result(nil)
      case "focus":
        NSApp.activate(ignoringOtherApps: true)
        self.makeKeyAndOrderFront(nil)
        result(nil)
      case "setTitle":
        if let title = args["title"] as? String {
          self.title = title
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Save/open panels for the file explorer (lib/native_dialogs.dart). Done
  // here rather than with a plugin, and through NSSavePanel/NSOpenPanel
  // because the sandbox only grants access to files the user picked in them.
  private func registerDialogChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "beacle/dialogs", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "save":
        let panel = NSSavePanel()
        if let args = call.arguments as? [String: Any], let name = args["name"] as? String {
          panel.nameFieldStringValue = name
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      case "open":
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.urls.map { $0.path } : [])
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
