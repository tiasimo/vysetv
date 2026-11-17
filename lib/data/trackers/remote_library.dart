import 'media_ref.dart';

/// One title as a tracker has it: on the watchlist, watched, or paused part-way.
class RemoteTitle {
  RemoteTitle({
    required this.kind,
    required this.at,
    this.tmdb,
    this.imdb,
    this.tvdb,
    this.anilist,
    this.mal,
    this.title = '',
    this.year,
    this.season,
    this.episode,
    this.progress,
    this.runtime,
    this.episodes = const {},
    this.listStatus,
  });

  final MediaKind kind;

  /// When it was listed, last watched, or paused (whichever list it's on).
  final DateTime at;
  int? tmdb;
  final String? imdb;
  final int? tvdb;
  int? anilist;
  final int? mal;
  final String title;
  final int? year;

  /// The episode last watched, or the one paused in. Anime count straight through (season 0).
  final int? season;
  final int? episode;

  /// Resume points: how far in, 0–100.
  final double? progress;

  /// Minutes, when the service says.
  final int? runtime;

  /// Episodes watched, keyed the way History keeps them ("S1E2").
  final Set<String> episodes;

  /// Lorewatch: AniList's list for it (PLANNING, CURRENT, COMPLETED, DROPPED, PAUSED, REPEATING).
  final String? listStatus;

  /// Lorewatch's key for it (`movie/1`, `tv/2`, `anime/3`), once its id is known.
  String? get key => switch (kind) {
    MediaKind.anime => anilist == null ? null : 'anime/$anilist',
    MediaKind.movie => tmdb == null ? null : 'movie/$tmdb',
    MediaKind.show => tmdb == null ? null : 'tv/$tmdb',
  };
}

/// What a tracker holds for this user.
class RemoteLibrary {
  RemoteLibrary({this.watchlist = const [], this.history = const [], this.resume = const [], this.listed = const [], this.cursor});

  final List<RemoteTitle> watchlist;
  final List<RemoteTitle> history;
  final List<RemoteTitle> resume;

  /// AniList: every anime on the list, whatever its status, so a title that
  /// moved from Planning to Watching isn't mistaken for one that was deleted.
  final List<RemoteTitle> listed;

  /// Simkl: its activity time from just before the read.
  final String? cursor;
}

int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

DateTime? asTime(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// "S01E04" (Simkl) as a season and episode.
(int, int)? parseEpisode(Object? v) {
  final m = RegExp(r'^S(\d+)E(\d+)$').firstMatch('${v ?? ''}');
  return m == null ? null : (int.parse(m[1]!), int.parse(m[2]!));
}

/// Episodes 1..[n] of an anime, as History keys them.
Set<String> animeEpisodes(int n) => {for (var e = 1; e <= n.clamp(0, 3000); e++) 'S0E$e'};
