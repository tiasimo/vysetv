// VyseTV stand-in for Plezy's i18n/app_locale_utils.dart: English only.
import 'strings.g.dart';

extension AppLocaleExternalFormats on AppLocale {
  String get intlLocaleName => languageCode;
  String get durationLocaleName => languageCode;
  String get plexLanguageCode => languageCode;
}
