import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:beacle/l10n/language.dart';
import 'package:beacle/l10n/strings.dart';

/// A missing entry falls back to English at runtime, which is invisible until
/// someone reads the screen in that language. These catch it at test time.
void main() {
  final en = L.tables[AppLanguage.en]!;
  Set<String> params(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m[1]!).toSet();

  test('every language has a table', () {
    for (final lang in AppLanguage.values) {
      expect(L.tables[lang], isNotNull, reason: '$lang');
    }
  });

  for (final lang in AppLanguage.values.where((l) => l != AppLanguage.en)) {
    test('${lang.name} translates every English key, with the same placeholders', () {
      final table = L.tables[lang]!;
      final missing = en.keys.where((k) => !table.containsKey(k)).toList();
      final extra = table.keys.where((k) => !en.containsKey(k)).toList();
      expect(missing, isEmpty, reason: 'missing in ${lang.name}');
      expect(extra, isEmpty, reason: 'not in English (${lang.name})');
      for (final k in en.keys) {
        // The call passes both the verb and its label; a language may need
        // the label where English reads better with the verb.
        if (k == 'confirmBody') continue;
        expect(params(table[k]!), params(en[k]!), reason: '${lang.name}: $k');
      }
    });
  }

  test('every key the code asks for exists', () {
    final used = <String>{};
    final call = RegExp(r"""\.(?:t|f)\(\s*'([A-Za-z0-9_]+)'""");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(f.readAsStringSync())) {
        used.add(m[1]!);
      }
    }
    final unknown = used.where((k) => !en.containsKey(k)).toList()..sort();
    expect(unknown, isEmpty);
  });
}
