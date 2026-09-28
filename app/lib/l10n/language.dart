/// Supported UI languages. English is the default; the onboarding wizard asks
/// on first run and the choice can be changed later in Settings.
enum AppLanguage { en, pl }

extension AppLanguageWire on AppLanguage {
  String get wire => name;

  static AppLanguage fromWire(String? v) => v == 'pl' ? AppLanguage.pl : AppLanguage.en;

  String get label => switch (this) {
        AppLanguage.en => 'English',
        AppLanguage.pl => 'Polski',
      };
}
