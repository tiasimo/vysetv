import 'tmdb.dart' show Media;
import 'app_settings.dart';

/// What is playing, for the language choices: films, TV series and anime each keep their own.
enum PlayKind {
  movie('Film'),
  tv('Serie TV'),
  anime('Anime');

  const PlayKind(this.label);
  final String label;
}

/// Lorewatch: the audio language, the subtitle language and whether subtitles switch on by
/// themselves, kept apart for each [PlayKind] so that changing one never changes the others.
abstract final class PlaybackPrefs {
  /// The kind of the video on screen. The player sets it when it opens, so everything that asks
  /// for "the subtitle language" while it plays gets the one for this kind.
  static PlayKind current = PlayKind.movie;

  static PlayKind of(Media media, {bool anime = false}) =>
      anime || media.anime ? PlayKind.anime : (media.isTv ? PlayKind.tv : PlayKind.movie);

  /// '' = the original language of the video.
  static Setting<String> audio(PlayKind k) => switch (k) {
    PlayKind.movie => AppSettings.movieAudio,
    PlayKind.tv => AppSettings.tvAudio,
    PlayKind.anime => AppSettings.animeAudio,
  };

  static Setting<String> subtitles(PlayKind k) => switch (k) {
    PlayKind.movie => AppSettings.movieSubs,
    PlayKind.tv => AppSettings.tvSubs,
    PlayKind.anime => AppSettings.animeSubs,
  };

  /// 'Off' = no subtitles for this kind of video (the "Nessuno" choice).
  static const none = 'Off';

  /// Whether subtitles switch on by themselves for kind [k].
  static bool autoOn(PlayKind k) => autoSubtitles(k).value && subtitles(k).value != none;

  static Setting<bool> autoSubtitles(PlayKind k) => switch (k) {
    PlayKind.movie => AppSettings.movieAutoSubs,
    PlayKind.tv => AppSettings.tvAutoSubs,
    PlayKind.anime => AppSettings.animeAutoSubs,
  };
}
