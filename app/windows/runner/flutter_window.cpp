#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Dart talks to the tray over this. Named after the app rather than a plugin,
// because there is no plugin — see tray_handler.h for why.
constexpr const char kTrayChannel[] = "beacle/tray";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  tray_.on_show = [this]() { RestoreFromTray(); };
  tray_.on_quit = [this]() { QuitForReal(); };
  tray_.Create(GetHandle());

  SetUpTrayChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Starting in the tray means never showing the window; the engine still
    // runs, so alerts and their sounds arrive as usual.
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpTrayChannel() {
  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kTrayChannel,
      &flutter::StandardMethodCodec::GetInstance());

  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();

        if (method == "setCloseToTray") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          close_to_tray_ = enabled != nullptr && *enabled;
          result->Success();
          return;
        }
        if (method == "show") {
          RestoreFromTray();
          result->Success();
          return;
        }
        if (method == "hide") {
          ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
          return;
        }
        if (method == "quit") {
          QuitForReal();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::RestoreFromTray() {
  HWND handle = GetHandle();
  if (!handle) {
    return;
  }
  ShowWindow(handle, IsIconic(handle) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(handle);
}

void FlutterWindow::QuitForReal() {
  quitting_ = true;
  // The icon has to go before the window does, or the shell leaves a dead one
  // behind until something makes it repaint that corner of the tray.
  tray_.Destroy();
  DestroyWindow(GetHandle());
}

void FlutterWindow::OnDestroy() {
  tray_.Destroy();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The tray gets first refusal on its own messages. Flutter has no interest
  // in them and WM_COMMAND from a popup menu would otherwise fall through to
  // DefWindowProc and be lost.
  if (std::optional<LRESULT> handled =
          tray_.HandleMessage(hwnd, message, wparam, lparam)) {
    return *handled;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      // Hiding rather than closing keeps the backend, its WebSockets and every
      // agent connection alive — which is the entire point of the setting.
      if (close_to_tray_ && !quitting_) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
