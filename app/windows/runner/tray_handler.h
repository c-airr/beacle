#ifndef RUNNER_TRAY_HANDLER_H_
#define RUNNER_TRAY_HANDLER_H_

#include <windows.h>

#include <functional>
#include <optional>

// The notification-area icon, implemented directly in the runner rather than
// through a plugin.
//
// A Flutter plugin would have been less code, but every plugin on Windows makes
// the build create symlinks, and Windows only allows that with Developer Mode
// on. Putting the tray here keeps `flutter build windows` working on a plain
// machine with nothing switched on.
//
// The usual hard part of a Win32 tray icon — owning a window and pumping its
// messages — is already solved: the runner has both, so this only needs to be
// handed the messages it cares about.
class TrayHandler {
 public:
  TrayHandler();
  ~TrayHandler();

  // Adds the icon. |owner| receives the callback messages, so it must outlive
  // this object; the runner's own window is the natural choice.
  bool Create(HWND owner);

  // Removes the icon. Safe to call more than once. Skipping it leaves a ghost
  // icon in the tray until the user waves the mouse over it.
  void Destroy();

  // Handles the messages this owns and reports whether it did, so the caller
  // can pass everything else along untouched.
  std::optional<LRESULT> HandleMessage(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam);

  // Fired from the tray menu and from double-clicking the icon.
  std::function<void()> on_show;
  std::function<void()> on_quit;

 private:
  void ShowContextMenu(HWND window);

  NOTIFYICONDATA icon_data_{};
  bool created_ = false;
};

#endif  // RUNNER_TRAY_HANDLER_H_
