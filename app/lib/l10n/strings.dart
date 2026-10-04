import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'language.dart';

part 'strings_de.dart';
part 'strings_en.dart';
part 'strings_es.dart';
part 'strings_fr.dart';
part 'strings_it.dart';
part 'strings_pl.dart';
part 'strings_pt.dart';
part 'strings_zh.dart';

/// Hand-rolled localization (no codegen step). Every string falls back to
/// English when an entry is missing, so a half-translated screen keeps
/// working instead of showing a key; test/l10n_test.dart makes sure none is.
///
/// Usage: `context.l.t('cancel')` or with parameters
/// `context.l.f('dockerRunning', {'r': 3, 't': 5, 'h': 2})`.
class L {
  final AppLanguage lang;
  const L(this.lang);

  // Nullable lookups: a widget shown outside the app (a test, a dialog
  // pumped on its own) reads English instead of throwing.
  static L of(BuildContext context) => L(context.watch<AppState?>()?.language ?? AppLanguage.en);
  static L read(BuildContext context) => L(context.read<AppState?>()?.language ?? AppLanguage.en);

  /// Every language's table, for the completeness test.
  @visibleForTesting
  static Map<AppLanguage, Map<String, String>> get tables => _table;

  String t(String key) => _table[lang]?[key] ?? _table[AppLanguage.en]![key] ?? key;

  String f(String key, [Map<String, Object?> params = const {}]) {
    var s = t(key);
    params.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    return s;
  }

  /// "just now", "5m ago" — how long since [when], in this language.
  String ago(DateTime when) {
    final sec = DateTime.now().difference(when.toLocal()).inSeconds;
    if (sec < 5) return t('agoNow');
    if (sec < 60) return f('agoS', {'n': sec});
    if (sec < 3600) return f('agoM', {'n': sec ~/ 60});
    if (sec < 86400) return f('agoH', {'n': sec ~/ 3600});
    return f('agoD', {'n': sec ~/ 86400});
  }

  /// "3d 4h", "2h 15m", "40m" — how long a machine has been up.
  String uptime(int seconds) {
    final d = seconds ~/ 86400, h = (seconds % 86400) ~/ 3600, m = (seconds % 3600) ~/ 60;
    if (d > 0) return f('upDH', {'d': d, 'h': h});
    if (h > 0) return f('upHM', {'h': h, 'm': m});
    return f('upM', {'m': m});
  }
}

extension LContext on BuildContext {
  L get l => L.of(this);
}

const _table = <AppLanguage, Map<String, String>>{
  AppLanguage.en: _en,
  AppLanguage.pl: _pl,
  AppLanguage.de: _de,
  AppLanguage.es: _es,
  AppLanguage.fr: _fr,
  AppLanguage.it: _it,
  AppLanguage.pt: _pt,
  AppLanguage.zh: _zh,
};
