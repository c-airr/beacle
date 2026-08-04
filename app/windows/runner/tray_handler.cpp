#include "tray_handler.h"

#include <shellapi.h>

#include "resource.h"

namespace {

// Private message the shell sends us for icon events. Anything in the
// WM_APP range is ours to name.
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Menu command ids.
constexpr UINT kMenuShow = 1001;
constexpr UINT kMenuQuit = 1002;

constexpr UINT kIconId = 1;

}  // namespace

TrayHandler::TrayHandler() {}

TrayHandler::~TrayHandler() {
  Destroy();
}

bool TrayHandler::Create(HWND owner) {
  if (created_) {
    return true;
  }

  icon_data_ = {};
  icon_data_.cbSize = sizeof(NOTIFYICONDATA);
  icon_data_.hWnd = owner;
  icon_data_.uID = kIconId;
  icon_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon_data_.uCallbackMessage = kTrayCallbackMessage;
  icon_data_.hIcon = static_cast<HICON>(
      LoadImage(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON),
                IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  if (!icon_data_.hIcon) {
    // Better a default icon than no tray at all: without one there is no way
    // back to a window that has been hidden.
    icon_data_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  wcscpy_s(icon_data_.szTip, L"Beacle");

  created_ = Shell_NotifyIcon(NIM_ADD, &icon_data_) != FALSE;
  return created_;
}

void TrayHandler::Destroy() {
  if (!created_) {
    return;
  }
  Shell_NotifyIcon(NIM_DELETE, &icon_data_);
  created_ = false;
}

std::optional<LRESULT> TrayHandler::HandleMessage(HWND window, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  if (message == kTrayCallbackMessage && LOWORD(wparam) == kIconId) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONDBLCLK:
        if (on_show) {
          on_show();
        }
        return 0;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowContextMenu(window);
        return 0;
      default:
        return 0;
    }
  }

  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kMenuShow:
        if (on_show) {
          on_show();
        }
        return 0;
      case kMenuQuit:
        if (on_quit) {
          on_quit();
        }
        return 0;
      default:
        break;
    }
  }

  return std::nullopt;
}

void TrayHandler::ShowContextMenu(HWND window) {
  POINT cursor;
  GetCursorPos(&cursor);

  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return;
  }
  AppendMenu(menu, MF_STRING, kMenuShow, L"Show Beacle");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kMenuQuit, L"Quit");

  // Without this the menu refuses to close when the user clicks elsewhere,
  // which is the single most common bug in hand-rolled tray menus.
  SetForegroundWindow(window);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, cursor.x, cursor.y, 0,
                 window, nullptr);
  PostMessage(window, WM_NULL, 0, 0);

  DestroyMenu(menu);
}
