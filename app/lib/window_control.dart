import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// What [WindowControl.grow] did, so [WindowControl.shrink] can undo exactly
/// that: [added] logical pixels of width, and [shift] logical pixels the
/// window moved left because the screen ended.
class WindowGrowth {
  final double added, shift;
  const WindowGrowth(this.added, this.shift);
  static const none = WindowGrowth(0, 0);
}

/// Resizing and titling this process's own window, without a plugin (see
/// tray.dart for why). Windows goes through user32 directly; macOS and Linux
/// through the `beacle/window` channel in their runners.
class WindowControl {
  WindowControl._();

  static const _channel = MethodChannel('beacle/window');

  /// Widens the window to the right by [by] logical pixels for the split
  /// view, Telegram-style. Clamped to the screen's work area; a maximized or
  /// fullscreen window does not grow at all.
  static Future<WindowGrowth> grow(double by, double devicePixelRatio) async {
    try {
      if (Platform.isWindows) return _Win32.grow(by, devicePixelRatio);
      final r = await _channel.invokeListMethod<double>('grow', {'by': by.toDouble()});
      if (r == null || r.length < 2) return WindowGrowth.none;
      return WindowGrowth(r[0], r[1]);
    } on MissingPluginException {
      return WindowGrowth.none;
    } on PlatformException {
      return WindowGrowth.none;
    }
  }

  /// Gives back what [grow] took.
  static Future<void> shrink(WindowGrowth g, double devicePixelRatio) async {
    if (g.added == 0 && g.shift == 0) return;
    try {
      if (Platform.isWindows) return _Win32.shrink(g, devicePixelRatio);
      await _channel.invokeMethod('shrink', {'by': g.added.toDouble(), 'shift': g.shift.toDouble()});
    } on MissingPluginException {
      // older runner: leave the window as it is
    } on PlatformException {
      // same
    }
  }

  /// Brings this window to the front (a tool window asked for again).
  static Future<void> focus() async {
    try {
      if (Platform.isWindows) return _Win32.focus();
      await _channel.invokeMethod('focus');
    } on MissingPluginException {
      // nothing to do
    } on PlatformException {
      // same
    }
  }

  /// Windows only lets the foreground process hand focus on. The main window
  /// calls this before asking a tool window [pid] to come to the front.
  static void allowForeground(int pid) {
    if (Platform.isWindows) _Win32.allowSetForeground(pid);
  }

  static Future<void> setTitle(String title) async {
    try {
      if (Platform.isWindows) return _Win32.setTitle(title);
      await _channel.invokeMethod('setTitle', {'title': title});
    } on MissingPluginException {
      // keep the default title
    } on PlatformException {
      // same
    }
  }
}

// --- Windows ------------------------------------------------------------------

final class _Rect extends Struct {
  @Int32()
  external int left, top, right, bottom;
}

final class _MonitorInfo extends Struct {
  @Uint32()
  external int cbSize;
  external _Rect rcMonitor;
  external _Rect rcWork;
  @Uint32()
  external int dwFlags;
}

typedef _EnumProc = Int32 Function(Pointer hwnd, IntPtr lParam);

class _Win32 {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _enumWindows = _user32.lookupFunction<
      Int32 Function(Pointer<NativeFunction<_EnumProc>>, IntPtr),
      int Function(Pointer<NativeFunction<_EnumProc>>, int)>('EnumWindows');
  static final _getWindowThreadProcessId = _user32.lookupFunction<Uint32 Function(Pointer, Pointer<Uint32>),
      int Function(Pointer, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _getClassName = _user32.lookupFunction<Int32 Function(Pointer, Pointer<Utf16>, Int32),
      int Function(Pointer, Pointer<Utf16>, int)>('GetClassNameW');
  static final _getCurrentProcessId =
      _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final _getWindowRect =
      _user32.lookupFunction<Int32 Function(Pointer, Pointer<_Rect>), int Function(Pointer, Pointer<_Rect>)>(
          'GetWindowRect');
  static final _isZoomed = _user32.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>('IsZoomed');
  static final _monitorFromWindow =
      _user32.lookupFunction<Pointer Function(Pointer, Uint32), Pointer Function(Pointer, int)>('MonitorFromWindow');
  static final _getMonitorInfo = _user32.lookupFunction<Int32 Function(Pointer, Pointer<_MonitorInfo>),
      int Function(Pointer, Pointer<_MonitorInfo>)>('GetMonitorInfoW');
  static final _setWindowPos = _user32.lookupFunction<
      Int32 Function(Pointer, Pointer, Int32, Int32, Int32, Int32, Uint32),
      int Function(Pointer, Pointer, int, int, int, int, int)>('SetWindowPos');
  static final _setWindowText = _user32.lookupFunction<Int32 Function(Pointer, Pointer<Utf16>),
      int Function(Pointer, Pointer<Utf16>)>('SetWindowTextW');
  static final _isIconic = _user32.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>('IsIconic');
  static final _showWindow =
      _user32.lookupFunction<Int32 Function(Pointer, Int32), int Function(Pointer, int)>('ShowWindow');
  static final _setForegroundWindow =
      _user32.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>('SetForegroundWindow');
  static final _allowSetForegroundWindow =
      _user32.lookupFunction<Int32 Function(Uint32), int Function(int)>('AllowSetForegroundWindow');

  static void allowSetForeground(int pid) => _allowSetForegroundWindow(pid);

  static const _swpNoZOrder = 0x0004;
  static const _swpNoActivate = 0x0010;
  static const _monitorDefaultToNearest = 2;

  static Pointer? _found;

  static int _enumCallback(Pointer hwnd, int lParam) {
    final pid = calloc<Uint32>();
    final cls = calloc<Uint16>(64).cast<Utf16>();
    try {
      _getWindowThreadProcessId(hwnd, pid);
      if (pid.value != lParam) return 1;
      final n = _getClassName(hwnd, cls, 64);
      if (n > 0 && cls.toDartString(length: n) == 'FLUTTER_RUNNER_WIN32_WINDOW') {
        _found = hwnd;
        return 0; // stop
      }
      return 1;
    } finally {
      calloc.free(pid);
      calloc.free(cls);
    }
  }

  /// This process's top-level Flutter window. FindWindow would happily
  /// return another Beacle's (a tool window is a second process).
  static Pointer? ownWindow() {
    _found = null;
    final cb = NativeCallable<_EnumProc>.isolateLocal(_enumCallback, exceptionalReturn: 0);
    try {
      _enumWindows(cb.nativeFunction, _getCurrentProcessId());
    } finally {
      cb.close();
    }
    return _found;
  }

  static WindowGrowth grow(double by, double dpr) {
    final hwnd = ownWindow();
    if (hwnd == null || _isZoomed(hwnd) != 0) return WindowGrowth.none;
    final rect = calloc<_Rect>();
    final mi = calloc<_MonitorInfo>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return WindowGrowth.none;
      mi.ref.cbSize = sizeOf<_MonitorInfo>();
      if (_getMonitorInfo(_monitorFromWindow(hwnd, _monitorDefaultToNearest), mi) == 0) return WindowGrowth.none;
      final work = mi.ref.rcWork;
      final x = rect.ref.left, y = rect.ref.top;
      final w = rect.ref.right - rect.ref.left, h = rect.ref.bottom - rect.ref.top;
      final maxW = work.right - work.left;
      final newW = (w + (by * dpr).round()).clamp(w, maxW < w ? w : maxW);
      var newX = x;
      if (newX + newW > work.right) newX = (work.right - newW).clamp(work.left, x);
      if (newW == w && newX == x) return WindowGrowth.none;
      _setWindowPos(hwnd, nullptr, newX, y, newW, h, _swpNoZOrder | _swpNoActivate);
      return WindowGrowth((newW - w) / dpr, (x - newX) / dpr);
    } finally {
      calloc.free(rect);
      calloc.free(mi);
    }
  }

  static void shrink(WindowGrowth g, double dpr) {
    final hwnd = ownWindow();
    // Maximized since: Windows restores the old size itself, leave it.
    if (hwnd == null || _isZoomed(hwnd) != 0) return;
    final rect = calloc<_Rect>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return;
      final w = rect.ref.right - rect.ref.left, h = rect.ref.bottom - rect.ref.top;
      final newW = w - (g.added * dpr).round();
      if (newW < 400) return; // resized by hand meanwhile; do not crush it
      _setWindowPos(hwnd, nullptr, rect.ref.left + (g.shift * dpr).round(), rect.ref.top, newW, h,
          _swpNoZOrder | _swpNoActivate);
    } finally {
      calloc.free(rect);
    }
  }

  static void focus() {
    final hwnd = ownWindow();
    if (hwnd == null) return;
    if (_isIconic(hwnd) != 0) _showWindow(hwnd, 9); // SW_RESTORE
    _setForegroundWindow(hwnd);
  }

  static void setTitle(String title) {
    final hwnd = ownWindow();
    if (hwnd == null) return;
    final t = title.toNativeUtf16();
    try {
      _setWindowText(hwnd, t);
    } finally {
      calloc.free(t);
    }
  }
}

/// For native_dialogs.dart: the window to own a file dialog.
Pointer? ownWin32Window() => Platform.isWindows ? _Win32.ownWindow() : null;
