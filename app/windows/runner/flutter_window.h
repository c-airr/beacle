#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "tray_handler.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden| keeps the window off screen at launch, for the
  // start-in-the-tray setting; the tray icon is the way back to it.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Brings the window back from the tray, restoring it if it was minimised.
  void RestoreFromTray();

  // Tears down for real, whatever the close-to-tray setting says.
  void QuitForReal();

  void SetUpTrayChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  TrayHandler tray_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;

  // Closing the window hides it instead of ending the process. Defaults to
  // false so a build where Dart never gets far enough to send the setting
  // still behaves like an ordinary window.
  bool close_to_tray_ = false;

  bool start_hidden_ = false;

  // Set once the user really means it, so the WM_CLOSE handler stops
  // intercepting.
  bool quitting_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
