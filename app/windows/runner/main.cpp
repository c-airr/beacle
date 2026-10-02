#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // The autostart entry appends this so a login launch goes straight to the
  // tray. It is read here rather than in Dart because the window is created
  // long before Dart could answer.
  bool start_hidden = false;
  // --tool=ssh / --tool=files: a separate window for one tool, started by the
  // main window (lib/tool_window.dart). No tray icon, a title of its own.
  const wchar_t* title = L"beacle";
  bool tool_window = false;
  for (const auto& argument : command_line_arguments) {
    if (argument == "--minimised" || argument == "--minimized") {
      start_hidden = true;
    } else if (argument == "--tool=ssh") {
      tool_window = true;
      title = L"Beacle - SSH";
    } else if (argument == "--tool=files") {
      tool_window = true;
      title = L"Beacle - Files";
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden, tool_window);
  Win32Window::Point origin(tool_window ? 80 : 10, tool_window ? 80 : 10);
  Win32Window::Size size(tool_window ? 1000 : 1280, tool_window ? 640 : 720);
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
