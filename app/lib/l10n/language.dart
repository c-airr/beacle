/// Supported UI languages. English is the default; the onboarding wizard asks
/// on first run and the choice can be changed later in Settings.
enum AppLanguage { en, pl, de, es, fr, it, pt, zh }

extension AppLanguageWire on AppLanguage {
  String get wire => name;

  static AppLanguage fromWire(String? v) =>
      AppLanguage.values.firstWhere((l) => l.name == v, orElse: () => AppLanguage.en);

  /// The language's own name for itself, so it can be found by someone who
  /// does not read the current one.
  String get label => switch (this) {
        AppLanguage.en => 'English',
        AppLanguage.pl => 'Polski',
        AppLanguage.de => 'Deutsch',
        AppLanguage.es => 'Español',
        AppLanguage.fr => 'Français',
        AppLanguage.it => 'Italiano',
        AppLanguage.pt => 'Português',
        AppLanguage.zh => '简体中文',
      };
}
