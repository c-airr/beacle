import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native "save as" and "open files" dialogs without a Flutter plugin.
///
/// Plugins make the Windows build create symlinks, which needs Developer Mode
/// (see tray.dart), so each platform is done by hand:
/// - Windows: comdlg32 through FFI, on a helper isolate so the app keeps
///   painting while the dialog is open.
/// - macOS: NSSavePanel/NSOpenPanel in the runner (MainFlutterWindow.swift).
///   The sandbox only grants access to files picked through those panels, so
///   a helper process like osascript would not do.
/// - Linux: zenity, or kdialog on KDE.
class NativeDialogs {
  NativeDialogs._();

  static const _mac = MethodChannel('beacle/dialogs');

  /// Asks where to save [suggestedName]. Null when cancelled.
  static Future<String?> saveFile(String suggestedName) async {
    if (Platform.isWindows) return Isolate.run(() => _winSave(suggestedName));
    if (Platform.isMacOS) return _mac.invokeMethod<String>('save', {'name': suggestedName});
    return _linux(['--file-selection', '--save', '--confirm-overwrite', '--filename=$suggestedName'],
        ['--getsavefilename', suggestedName]).then((r) => r.firstOrNull);
  }

  /// Lets the user pick files to upload. Empty when cancelled.
  static Future<List<String>> openFiles() async {
    if (Platform.isWindows) return Isolate.run(_winOpen);
    if (Platform.isMacOS) {
      final r = await _mac.invokeListMethod<String>('open');
      return r ?? const [];
    }
    return _linux(['--file-selection', '--multiple', '--separator=\n'], ['--getopenfilename', '.', '--multiple', '--separate-output']);
  }

  static Future<List<String>> _linux(List<String> zenityArgs, List<String> kdialogArgs) async {
    for (final (bin, args) in [('zenity', zenityArgs), ('kdialog', kdialogArgs)]) {
      final ProcessResult r;
      try {
        r = await Process.run(bin, args);
      } on ProcessException {
        continue; // not installed, try the next one
      }
      // Both exit 1 on cancel.
      if (r.exitCode != 0) return const [];
      return (r.stdout as String).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    }
    throw const NativeDialogUnavailable();
  }
}

class NativeDialogUnavailable implements Exception {
  const NativeDialogUnavailable();
  @override
  String toString() => 'No file dialog available — install zenity or kdialog.';
}

// --- Windows ------------------------------------------------------------------

/// Size Windows expects in lStructSize; checked by a test on 64-bit.
@visibleForTesting
int get openFileNameSize => sizeOf<_OpenFileName>();

final class _OpenFileName extends Struct {
  @Uint32()
  external int lStructSize;
  external Pointer hwndOwner;
  external Pointer hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  @IntPtr()
  external int lCustData;
  external Pointer lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int flagsEx;
}

typedef _OfnNative = Int32 Function(Pointer<_OpenFileName>);
typedef _OfnDart = int Function(Pointer<_OpenFileName>);

const _ofnOverwritePrompt = 0x00000002;
const _ofnNoChangeDir = 0x00000008;
const _ofnAllowMultiSelect = 0x00000200;
const _ofnPathMustExist = 0x00000800;
const _ofnFileMustExist = 0x00001000;
const _ofnExplorer = 0x00080000;

/// Room for a multi-select answer: directory plus many names.
const _fileBufChars = 32 * 1024;

/// The app's main window, so the dialog sits on top of it and blocks it.
Pointer _winOwner() {
  final user32 = DynamicLibrary.open('user32.dll');
  final findWindow = user32.lookupFunction<Pointer Function(Pointer<Utf16>, Pointer<Utf16>),
      Pointer Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    return findWindow(cls, nullptr);
  } finally {
    calloc.free(cls);
  }
}

void _coInit() {
  final ole32 = DynamicLibrary.open('ole32.dll');
  final init = ole32.lookupFunction<Int32 Function(Pointer, Uint32), int Function(Pointer, int)>('CoInitializeEx');
  init(nullptr, 0x2 | 0x4); // apartment-threaded, no OLE1/DDE
}

String? _winDialog({required bool save, String suggested = ''}) {
  _coInit();
  final comdlg = DynamicLibrary.open('comdlg32.dll');
  final call = comdlg.lookupFunction<_OfnNative, _OfnDart>(save ? 'GetSaveFileNameW' : 'GetOpenFileNameW');
  final ofn = calloc<_OpenFileName>();
  final buf = calloc<Uint16>(_fileBufChars);
  final filter = 'All files\u0000*.*\u0000\u0000'.toNativeUtf16();
  try {
    final name = suggested.codeUnits.take(_fileBufChars - 1).toList();
    for (var i = 0; i < name.length; i++) {
      buf[i] = name[i];
    }
    ofn.ref
      ..lStructSize = sizeOf<_OpenFileName>()
      ..hwndOwner = _winOwner()
      ..lpstrFilter = filter
      ..lpstrFile = buf.cast()
      ..nMaxFile = _fileBufChars
      ..flags = _ofnExplorer |
          _ofnNoChangeDir |
          _ofnPathMustExist |
          (save ? _ofnOverwritePrompt : _ofnFileMustExist | _ofnAllowMultiSelect);
    if (call(ofn) == 0) return null; // cancelled (or failed)
    // Multi-select comes back NUL-separated and double-NUL-terminated; keep
    // the raw characters up to the double NUL.
    final chars = <int>[];
    for (var i = 0; i < _fileBufChars - 1; i++) {
      if (buf[i] == 0 && buf[i + 1] == 0) break;
      chars.add(buf[i]);
    }
    return String.fromCharCodes(chars);
  } finally {
    calloc.free(filter);
    calloc.free(buf);
    calloc.free(ofn);
  }
}

String? _winSave(String suggested) => _winDialog(save: true, suggested: suggested);

List<String> _winOpen() {
  final raw = _winDialog(save: false);
  if (raw == null || raw.isEmpty) return const [];
  final parts = raw.split('\u0000');
  if (parts.length == 1) return parts; // one file: the full path
  final dir = parts.first;
  return [for (final n in parts.skip(1)) '$dir\\$n'];
}
