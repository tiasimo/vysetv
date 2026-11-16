// VyseTV stand-in for Plezy's SettingsService (the real one is ~1,600 lines of
// app preferences). The lifted server layer only reads a handful of them; each
// answers with Plezy's default. VyseTV can override any via [SettingsService.overrides].

import '../media/ids.dart';
import 'base_shared_preferences_service.dart'
    show BaseSharedPreferencesService, BoolPref, EnumPref, IntPref, Pref, StringListPref;

export 'base_shared_preferences_service.dart' show Pref;

enum EpisodePosterMode { seriesPoster, seasonPoster, episodeThumbnail }

enum SpecialsOrdering { respectServer, airDate, specialsLast }

/// What the server layer needs from the app locale (Plex wants a language code).
class AppLocaleValue {
  const AppLocaleValue(this.plexLanguageCode);
  final String plexLanguageCode;
}

class _AppLocalePref extends Pref<AppLocaleValue> {
  const _AppLocalePref() : super('app_locale');

  @override
  AppLocaleValue get resolvedDefault => const AppLocaleValue('en');

  @override
  AppLocaleValue readFrom(BaseSharedPreferencesService svc) => resolvedDefault;

  @override
  Future<void> writeTo(BaseSharedPreferencesService svc, AppLocaleValue value) async {}
}

class SettingsService {
  SettingsService._();

  static final SettingsService _instance = SettingsService._();
  static SettingsService? get instanceOrNull => _instance;
  static Future<SettingsService> getInstance() async => _instance;

  /// VyseTV overrides by preference key.
  static final Map<String, Object?> overrides = {};

  T read<T>(Pref<T> pref) {
    final o = overrides[pref.key];
    if (o is T) return o;
    return pref.resolvedDefault;
  }

  Future<void> write<T>(Pref<T> pref, T value) async => overrides[pref.key] = value;

  static const rememberTrackSelections = BoolPref('remember_track_selections', defaultValue: true);
  static const directPlayCoveredQuality = BoolPref('direct_play_covered_quality', defaultValue: true);
  static const refusedVideoCodecs = StringListPref('refused_video_codecs');
  static const specialsOrdering = EnumPref<SpecialsOrdering>(
    'specials_ordering',
    values: SpecialsOrdering.values,
    defaultValue: SpecialsOrdering.respectServer,
  );
  static const appLocale = _AppLocalePref();
  static IntPref watchedThresholdPref(ServerId serverId) => IntPref('watched_threshold_$serverId', defaultValue: 90);
}
