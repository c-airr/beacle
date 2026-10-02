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

    super.awakeFromNib()
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
