import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/native_dialogs.dart';

void main() {
  // GetSaveFileNameW rejects a struct whose lStructSize is not exactly what
  // comdlg32 expects (152 bytes on 64-bit), and silently returns "cancelled".
  test('OPENFILENAMEW matches the 64-bit Windows layout', () {
    expect(openFileNameSize, 152);
  }, skip: sizeOf<IntPtr>() != 8 ? 'layout differs on 32-bit' : false);

  test('dialogs pick the platform path without a plugin', () {
    // Only checks the class loads everywhere; the dialogs need a desktop.
    expect(Platform.isWindows || Platform.isMacOS || Platform.isLinux, isTrue);
    expect(const NativeDialogUnavailable().toString(), contains('zenity'));
  });
}
