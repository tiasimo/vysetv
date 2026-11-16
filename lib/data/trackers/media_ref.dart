import '../anilist.dart' show Anime;
import '../tmdb.dart' show Media;

enum MediaKind { movie, show, anime }

/// A title (and episode) as the tracking services need it: its ids, name and year. Small
/// enough to wait in the outbox.
class MediaRef {
  const MediaRef({
    required this.kind,
    required this.key,
    required this.title,
    this.year,
    this.tmdb,
    this.anilist,
    this.mal,
    this.season,
    this.episode,
    this.film = false,
  });

  final MediaKind kind;
  final String key; // Vyse's own key for the title (Media.key)
  final String title;
  final int? year;
  final int? tmdb; // films and shows
  final int? anilist; // anime
  final int? mal;
  final int? season; // shows (TMDB numbering)
  final int? episode; // shows; anime: counted straight through (a film is 1)
  final bool film; // an anime film

  /// This exact episode (or the film).
  String get itemKey => '$key/${season ?? ''}/${episode ?? ''}';

  /// What the player is playing: an anime from AniList when [anime] is given (or [media] is
  /// one), else a TMDB film, or a TMDB show's episode (null without one).
  static MediaRef? playing(Media media, {Anime? anime, int? season, int? episode}) {
    if (anime != null || media.anime) {
      final n = episode ?? (anime?.isMovie ?? !media.isTv ? 1 : null);
      if (n == null) return null;
      return MediaRef(
        kind: MediaKind.anime,
        key: media.key,
        title: anime?.title ?? media.title,
        year: anime?.year ?? int.tryParse(media.year ?? ''),
        anilist: anime?.id ?? media.id,
        mal: anime?.idMal,
        episode: n,
        film: anime?.isMovie ?? false,
      );
    }
    if (media.isTv && (season == null || episode == null)) return null;
    return MediaRef(
      kind: media.isTv ? MediaKind.show : MediaKind.movie,
      key: media.key,
      title: media.title,
      year: int.tryParse(media.year ?? ''),
      tmdb: media.id,
      season: media.isTv ? season : null,
      episode: media.isTv ? episode : null,
    );
  }

  /// A whole title (My List, History).
  static MediaRef whole(Media media) => MediaRef(
    kind: media.anime ? MediaKind.anime : (media.isTv ? MediaKind.show : MediaKind.movie),
    key: media.key,
    title: media.title,
    year: int.tryParse(media.year ?? ''),
    tmdb: media.anime ? null : media.id,
    anilist: media.anime ? media.id : null,
  );

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'key': key,
    't': title,
    'y': ?year,
    'tmdb': ?tmdb,
    'al': ?anilist,
    'mal': ?mal,
    's': ?season,
    'e': ?episode,
    if (film) 'f': true,
  };

  static MediaRef? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      int? i(String k) => (j[k] as num?)?.toInt();
      return MediaRef(
        kind: MediaKind.values.byName(j['k'] as String),
        key: j['key'] as String,
        title: '${j['t'] ?? ''}',
        year: i('y'),
        tmdb: i('tmdb'),
        anilist: i('al'),
        mal: i('mal'),
        season: i('s'),
        episode: i('e'),
        film: j['f'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
