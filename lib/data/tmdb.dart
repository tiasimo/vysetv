import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// TMDB v3 key. Override at build time with --dart-define=TMDB_API_KEY=...
const _apiKey = String.fromEnvironment(
  'TMDB_API_KEY',
  defaultValue: 'b3556f3b206e16f82df4d1f6fd4545e6',
);

const _imageBase = 'https://image.tmdb.org/t/p';

class Media {
  const Media({
    required this.id,
    required this.title,
    required this.isTv,
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.rating = 0,
    this.year,
    this.genreIds = const [],
    this.popularity = 0,
    this.voteCount = 0,
    this.date = '',
    this.anime = false,
    this.originalLanguage = '',
  });

  /// TMDB's original language ("ja", "en"…), when it was sent.
  final String originalLanguage;

  /// Lorewatch: a Japanese animated series on TMDB, i.e. an anime. Anime have their own section
  /// (from AniList), so they're kept out of TV series.
  bool get tmdbAnime => !anime && genreIds.contains(16) && originalLanguage == 'ja';

  /// [id] is TMDB's, or AniList's when [anime] is set.
  final int id;
  final String title;
  final bool isTv;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final double rating;
  final String? year;
  final List<int> genreIds;
  final double popularity;
  final int voteCount;

  /// Release / first-air date as TMDB sends it (yyyy-mm-dd), for sorting merged lists.
  final String date;

  /// An anime from AniList, not a TMDB title: its pages, player and episodes are the anime ones,
  /// and [posterPath] / [backdropPath] are full image addresses.
  final bool anime;

  factory Media.fromJson(Map<String, dynamic> j, {bool? tv}) {
    final isTv = tv ?? (j['media_type'] == 'tv' || j.containsKey('first_air_date'));
    final date = (j['release_date'] ?? j['first_air_date'] ?? '') as String;
    return Media(
      id: j['id'] as int,
      title: (j['title'] ?? j['name'] ?? 'Untitled') as String,
      isTv: isTv,
      overview: (j['overview'] ?? '') as String,
      posterPath: j['poster_path'] as String?,
      backdropPath: j['backdrop_path'] as String?,
      rating: (j['vote_average'] as num?)?.toDouble() ?? 0,
      year: date.length >= 4 ? date.substring(0, 4) : null,
      genreIds: ((j['genre_ids'] as List?) ?? const []).cast<int>(),
      popularity: (j['popularity'] as num?)?.toDouble() ?? 0,
      voteCount: (j['vote_count'] as num?)?.toInt() ?? 0,
      date: date,
      anime: j['anime'] == true,
      originalLanguage: (j['original_language'] as String?) ?? '',
    );
  }

  String get kind => anime ? 'Anime' : (isTv ? 'Series' : 'Movie');

  /// Stable identity across rows, lists and TMDB URLs, e.g. `tv/1399`.
  String get key => anime ? 'anime/$id' : '${isTv ? 'tv' : 'movie'}/$id';
  String get tmdbUrl => anime ? 'https://anilist.co/anime/$id' : 'https://www.themoviedb.org/$key';
  String? poster([String size = 'w342']) => _image(posterPath, size);
  String? backdrop([String size = 'w1280']) => _image(backdropPath, size);
  static String? _image(String? path, String size) => path == null ? null : (path.startsWith('http') ? path : '$_imageBase/$size$path');
}

/// "S2:E5", or "E5" for anime (numbered straight through, season 0).
String episodeLabel(int? season, int episode, {String gap = ':'}) =>
    season == null || season == 0 ? 'E$episode' : 'S$season${gap}E$episode';

class WatchProvider {
  const WatchProvider(this.id, this.name, this.logoPath);
  final int id;
  final String name;
  final String? logoPath;
  String? get logo => logoPath == null ? null : '$_imageBase/w154$logoPath';
}

class TmdbException implements Exception {
  TmdbException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Tmdb {
  static final _client = http.Client();

  static Future<Map<String, dynamic>> _get(String path, [Map<String, String> query = const {}]) async {
    final uri = Uri.https('api.themoviedb.org', '/3$path', {
      'api_key': _apiKey,
      'language': 'en-US',
      ...query,
    });
    final res = await _client.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw TmdbException('TMDB returned ${res.statusCode} for $path');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<Media>> search(String q, {required bool tv}) =>
      list('/search/${tv ? 'tv' : 'movie'}', tv: tv, keepAnime: true, query: {'query': q, 'include_adult': 'false'});

  static Future<PersonDetails> person(int id) async {
    final json = await _get('/person/$id', {'append_to_response': 'combined_credits,images,external_ids'});
    return PersonDetails.fromJson(json);
  }

  static Future<List<Studio>> searchCompanies(String q) async {
    final json = await _get('/search/company', {'query': q});
    return (json['results'] as List)
        .cast<Map<String, dynamic>>()
        .map((c) => Studio.fromJson(c, isNetwork: false))
        .toList();
  }

  static Future<Studio> network(int id) async => Studio.fromJson(await _get('/network/$id'), isNetwork: true);

  static Future<List<Person>> searchPeople(String q) async {
    final json = await _get('/search/person', {'query': q, 'include_adult': 'false'});
    return (json['results'] as List).cast<Map<String, dynamic>>().map(Person.fromJson).toList();
  }

  /// Raw JSON for endpoints that need paging metadata (e.g. /discover).
  static Future<Map<String, dynamic>> get(String path, [Map<String, String> query = const {}]) => _get(path, query);

  /// Lorewatch: series lists leave anime out ([Media.tmdbAnime]) unless [keepAnime].
  static Future<List<Media>> list(String path, {Map<String, String> query = const {}, bool? tv, bool keepAnime = false}) async {
    final json = await _get(path, query);
    return (json['results'] as List)
        .cast<Map<String, dynamic>>()
        .where((m) => m['media_type'] != 'person')
        .map((m) => Media.fromJson(m, tv: tv))
        .where((m) => keepAnime || !(m.isTv && m.tmdbAnime))
        .toList();
  }

  static Future<MediaDetails> details(Media m) async {
    if (m.anime) throw UnsupportedError('${m.title} is an AniList title');
    final json = await _get('/${m.isTv ? 'tv' : 'movie'}/${m.id}', {
      'append_to_response': m.isTv
          ? 'credits,videos,recommendations,similar,content_ratings'
          : 'credits,videos,recommendations,similar,release_dates',
    });
    return MediaDetails.fromJson(m, json);
  }

  /// The title's logo artwork (English or language-neutral), if TMDB has one.
  static Future<String?> logo(Media m) async {
    if (m.anime) return null;
    final json = await _get('/${m.isTv ? 'tv' : 'movie'}/${m.id}/images', {'include_image_language': 'en,null'});
    final logos = (json['logos'] as List).cast<Map<String, dynamic>>();
    if (logos.isEmpty) return null;
    final pick = logos.firstWhere((l) => l['iso_639_1'] == 'en', orElse: () => logos.first);
    return '$_imageBase/w500${pick['file_path']}';
  }

  /// Best-voted poster with no text on it (TMDB's language-less posters), for portrait screens.
  static Future<String?> textlessPoster(Media m) async {
    if (m.anime) return null;
    final json = await _get('/${m.isTv ? 'tv' : 'movie'}/${m.id}/images', {'include_image_language': 'null'});
    final posters = (json['posters'] as List).cast<Map<String, dynamic>>();
    if (posters.isEmpty) return null;
    posters.sort((a, b) => ((b['vote_average'] as num?) ?? 0).compareTo((a['vote_average'] as num?) ?? 0));
    return '$_imageBase/w780${posters.first['file_path']}';
  }

  /// Big streamers, in the order we want to show them.
  static const _featuredProviders = [
    8, 337, 9, 1899, 15, 350, 2303, 283, 386, 43, 34, 526, 520, 1768, 73, 300, 207, 538, 257, 2383, 299, 457, 430, 99,
    151, 87, 258, 11, 191, 212, 192, 188, 2, 10, 3, 7,
  ];

  static Future<List<WatchProvider>> providers() async {
    // Movie and TV lists differ (fubo, BritBox…), so merge both.
    final lists = await Future.wait([
      _get('/watch/providers/movie', {'watch_region': 'US'}),
      _get('/watch/providers/tv', {'watch_region': 'US'}),
    ]);
    final all = {
      for (final json in lists)
        for (final p in (json['results'] as List).cast<Map<String, dynamic>>())
        p['provider_id'] as int: WatchProvider(
          p['provider_id'] as int,
          p['provider_name'] as String,
          p['logo_path'] as String?,
        ),
    };
    return [for (final id in _featuredProviders) ?all[id]];
  }
}

class Genre {
  const Genre(this.id, this.name, this.colors);
  final int id;
  final String name;
  final List<int> colors;
}

const homeGenres = [
  Genre(28, 'Action', [0xFFFF5F3A, 0xFF7A1A2E]),
  Genre(35, 'Comedy', [0xFFFFC23A, 0xFF8A4B12]),
  Genre(18, 'Drama', [0xFF5B8CFF, 0xFF1C2A6B]),
  Genre(878, 'Sci-Fi', [0xFF3AE0FF, 0xFF143F6B]),
  Genre(27, 'Horror', [0xFFB01E3A, 0xFF2A0710]),
  Genre(16, 'Animation', [0xFFB46BFF, 0xFF3A1A7A]),
  Genre(10749, 'Romance', [0xFFFF6BA8, 0xFF6B1A44]),
  Genre(53, 'Thriller', [0xFF8C93B8, 0xFF22263D]),
  Genre(99, 'Documentary', [0xFF5BE0A0, 0xFF0F4A3A]),
  Genre(14, 'Fantasy', [0xFF9C7BFF, 0xFF2B1A6B]),
];

/// Every row on the home page, fetched in parallel. Created once so the intro can warm it up.
class HomeFeed {
  HomeFeed._();
  static final instance = HomeFeed._();

  final _cache = <String, Future<Object>>{};

  /// Shares one request per row; a failed request is forgotten so the next call retries.
  Future<T> _memo<T extends Object>(String key, Future<T> Function() fetch) {
    final cached = _cache[key];
    if (cached != null) return cached as Future<T>;
    final f = fetch();
    _cache[key] = f;
    f.then((_) {}, onError: (_) {
      _cache.remove(key);
    });
    return f;
  }

  Future<List<Media>> hero() => _memo('hero', () => Tmdb.list('/trending/all/week'));
  Future<List<Media>> topMoviesToday() => _memo('topMovies', () => Tmdb.list('/trending/movie/day', tv: false));
  Future<List<WatchProvider>> providers() => _memo('providers', Tmdb.providers);
  Future<List<Media>> popularTv() => _memo('popularTv', () => Tmdb.list('/tv/popular', tv: true));
  Future<List<Media>> nowPlaying() => _memo('nowPlaying', () => Tmdb.list('/movie/now_playing', tv: false));
  Future<List<Media>> topTvToday() => _memo('topTv', () => Tmdb.list('/trending/tv/day', tv: true));
  Future<List<Media>> anime() => _memo('anime', () => Tmdb.list('/discover/tv', tv: true, keepAnime: true, query: {
        'with_genres': '16',
        'with_original_language': 'ja',
        'sort_by': 'popularity.desc',
      }));
  Future<List<Media>> topRated() => _memo('topRated', () => Tmdb.list('/movie/top_rated', tv: false));
  Future<List<Media>> upcoming() => _memo('upcoming', () => Tmdb.list('/movie/upcoming', tv: false));
  Future<List<Media>> trendingToday() => _memo('trendingToday', () => Tmdb.list('/trending/all/day'));
  Future<List<Media>> searchMedia(String q, {required bool tv}) =>
      _memo('search/${tv ? 'tv' : 'movie'}/${q.toLowerCase()}', () => Tmdb.search(q, tv: tv));
  Future<List<Person>> searchPeople(String q) =>
      _memo('search/person/${q.toLowerCase()}', () => Tmdb.searchPeople(q));

  Future<PersonDetails> person(int id) => _memo('person/$id', () => Tmdb.person(id));
  Future<Studio> network(int id) => _memo('network/$id', () => Tmdb.network(id));

  /// Studios from TMDB's company search, plus TV networks matched against [knownNetworks]
  /// (TMDB has no network search). Networks are confirmed against TMDB's own name before showing.
  Future<List<Studio>> searchStudios(String q) => _memo('search/studio/${q.toLowerCase()}', () async {
        final needle = _norm(q);
        final candidates = knownNetworks.where((n) => _norm(n.$2).contains(needle) || needle.contains(_norm(n.$2)));
        final networks = await Future.wait(candidates.take(6).map((n) async {
          try {
            final s = await network(n.$1);
            final real = _norm(s.name), expected = _norm(n.$2);
            return real.contains(expected) || expected.contains(real) ? s : null;
          } catch (_) {
            return null;
          }
        }));
        final companies = await Tmdb.searchCompanies(q);
        // Studios with logos are the recognisable ones; keep them first.
        companies.sort((a, b) => (b.logoPath != null ? 1 : 0) - (a.logoPath != null ? 1 : 0));
        return [...networks.nonNulls, ...companies.take(20)];
      });

  Future<MediaDetails> details(Media m) => _memo('details/${m.key}', () => Tmdb.details(m));

  Future<List<Media>> because(Media m) => m.anime ? Future.value(const []) : _memo(
      'rec${m.isTv}${m.id}', () => Tmdb.list('/${m.isTv ? 'tv' : 'movie'}/${m.id}/recommendations', tv: m.isTv));

  final _phoneArt = <String, Future<String?>>{};

  /// Portrait art for the phone hero: a textless poster, or null to fall back to the backdrop.
  Future<String?> phoneArt(Media m) {
    final key = m.key;
    return _phoneArt[key] ??= Tmdb.textlessPoster(m).catchError((Object _) {
      _phoneArt.remove(key);
      return null;
    });
  }

  final _logos = <String, Future<String?>>{};
  Future<String?> logo(Media m) {
    final key = m.key;
    return _logos[key] ??= Tmdb.logo(m).catchError((Object _) {
      _logos.remove(key);
      return null;
    });
  }

  Future<List<Media>> genre(int id) => _memo('genre$id', () => Tmdb.list('/discover/movie', tv: false, query: {
        'with_genres': '$id',
        'sort_by': 'popularity.desc',
      }));

  void warmUp() {
    // Errors surface later in the rows themselves.
    for (final f in [hero(), topMoviesToday(), providers(), popularTv()]) {
      f.ignore();
    }
  }
}

// ───────────────────────── Details ─────────────────────────

class CastMember {
  const CastMember(this.id, this.name, this.character, this.profilePath);
  final int id;
  final String name;
  final String character;
  final String? profilePath;

  factory CastMember.fromJson(Map<String, dynamic> j) => CastMember(
        j['id'] as int,
        (j['name'] ?? '') as String,
        (j['character'] ?? '') as String,
        j['profile_path'] as String?,
      );

  String? get photo => profilePath == null ? null : '$_imageBase/w185$profilePath';
}

class Season {
  const Season(this.number, this.name, this.episodes, this.year, this.posterPath);
  final int number;
  final String name;
  final int episodes;
  final String? year;
  final String? posterPath;

  factory Season.fromJson(Map<String, dynamic> j) {
    final date = (j['air_date'] ?? '') as String;
    return Season(
      j['season_number'] as int,
      (j['name'] ?? 'Season ${j['season_number']}') as String,
      (j['episode_count'] as num?)?.toInt() ?? 0,
      date.length >= 4 ? date.substring(0, 4) : null,
      j['poster_path'] as String?,
    );
  }

  String? get poster => posterPath == null ? null : '$_imageBase/w342$posterPath';
}

class Video {
  const Video(this.key, this.name, this.type, this.official);
  final String key;
  final String name;
  final String type;
  final bool official;

  factory Video.fromJson(Map<String, dynamic> j) => Video(
        j['key'] as String,
        (j['name'] ?? '') as String,
        (j['type'] ?? '') as String,
        (j['official'] ?? false) as bool,
      );

  String get url => 'https://www.youtube.com/watch?v=$key';
  String get thumbnail => 'https://i.ytimg.com/vi/$key/hqdefault.jpg';

  /// Official trailers first, then teasers, clips, featurettes.
  int get rank {
    final i = const ['Trailer', 'Teaser', 'Clip', 'Featurette'].indexOf(type);
    return (i == -1 ? 8 : i * 2) + (official ? 0 : 1);
  }
}

class MediaDetails {
  const MediaDetails({
    required this.media,
    this.runtime,
    this.genres = const [],
    this.status,
    this.released,
    this.tagline,
    this.certification,
    this.directors = const [],
    this.writers = const [],
    this.studios = const [],
    this.networks = const [],
    this.countries = const [],
    this.language,
    this.budget = 0,
    this.revenue = 0,
    this.seasonCount,
    this.episodeCount,
    this.voteCount = 0,
    this.cast = const [],
    this.seasons = const [],
    this.videos = const [],
    this.recommendations = const [],
  });

  final Media media;
  final int? runtime;
  final List<String> genres;
  final String? status;
  final DateTime? released;
  final String? tagline;
  final String? certification;

  /// Directors for films, creators for series.
  final List<String> directors;
  final List<String> writers;
  final List<Studio> studios;
  final List<Studio> networks;
  final List<String> countries;
  final String? language;
  final int budget;
  final int revenue;
  final int? seasonCount;
  final int? episodeCount;
  final int voteCount;
  final List<CastMember> cast;
  final List<Season> seasons;
  final List<Video> videos;
  final List<Media> recommendations;

  Video? get trailer => videos.firstOrNull;

  factory MediaDetails.fromJson(Media base, Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(Object? v) => ((v as List?) ?? const []).cast<Map<String, dynamic>>();
    List<String> names(Object? v) =>
        maps(v).map((e) => (e['name'] ?? '') as String).where((s) => s.isNotEmpty).toList();
    Map<String, dynamic> obj(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};

    final tv = base.isTv;
    final credits = obj(j['credits']);
    final crew = maps(credits['crew']);

    List<Media> titles(Object? block) =>
        maps(obj(block)['results']).map((r) => Media.fromJson(r, tv: tv)).where((m) => m.posterPath != null).toList();
    var recs = titles(j['recommendations']);
    if (recs.isEmpty) recs = titles(j['similar']);

    String? certification;
    if (tv) {
      certification = maps(obj(j['content_ratings'])['results'])
          .where((r) => r['iso_3166_1'] == 'US')
          .map((r) => r['rating'] as String?)
          .firstOrNull;
    } else {
      final us = maps(obj(j['release_dates'])['results']).where((r) => r['iso_3166_1'] == 'US').firstOrNull;
      certification = maps(us?['release_dates'])
          .map((d) => (d['certification'] ?? '') as String)
          .where((c) => c.isNotEmpty)
          .firstOrNull;
    }

    final runtime = tv
        ? (((j['episode_run_time'] as List?) ?? const []).cast<num>().firstOrNull?.toInt() ??
            (obj(j['last_episode_to_air'])['runtime'] as num?)?.toInt())
        : (j['runtime'] as num?)?.toInt();

    final languages = maps(j['spoken_languages'])
        .map((l) => (l['english_name'] ?? l['name'] ?? '') as String)
        .where((s) => s.isNotEmpty);

    final videos = maps(obj(j['videos'])['results'])
        .where((v) => v['site'] == 'YouTube' && v['key'] != null)
        .map(Video.fromJson)
        .toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));

    return MediaDetails(
      media: Media(
        id: base.id,
        title: (j['title'] ?? j['name'] ?? base.title) as String,
        isTv: tv,
        overview: (j['overview'] as String?)?.isNotEmpty == true ? j['overview'] as String : base.overview,
        posterPath: (j['poster_path'] as String?) ?? base.posterPath,
        backdropPath: (j['backdrop_path'] as String?) ?? base.backdropPath,
        rating: (j['vote_average'] as num?)?.toDouble() ?? base.rating,
        year: base.year,
        genreIds: base.genreIds,
      ),
      runtime: runtime == 0 ? null : runtime,
      genres: names(j['genres']),
      status: j['status'] as String?,
      released: DateTime.tryParse(((tv ? j['first_air_date'] : j['release_date']) ?? '') as String),
      tagline: (j['tagline'] as String?)?.trim().isEmpty == true ? null : j['tagline'] as String?,
      certification: certification,
      directors: tv
          ? names(j['created_by'])
          : crew.where((c) => c['job'] == 'Director').map((c) => c['name'] as String).toList(),
      writers: crew
          .where((c) => c['department'] == 'Writing')
          .map((c) => c['name'] as String)
          .toSet()
          .take(3)
          .toList(),
      studios: maps(j['production_companies']).map((c) => Studio.fromJson(c, isNetwork: false)).take(3).toList(),
      networks: maps(j['networks']).map((c) => Studio.fromJson(c, isNetwork: true)).take(3).toList(),
      countries: names(j['production_countries']).take(2).toList(),
      language: languages.firstOrNull ?? (j['original_language'] as String?)?.toUpperCase(),
      budget: (j['budget'] as num?)?.toInt() ?? 0,
      revenue: (j['revenue'] as num?)?.toInt() ?? 0,
      seasonCount: (j['number_of_seasons'] as num?)?.toInt(),
      episodeCount: (j['number_of_episodes'] as num?)?.toInt(),
      voteCount: (j['vote_count'] as num?)?.toInt() ?? 0,
      cast: maps(credits['cast']).take(24).map(CastMember.fromJson).toList(),
      seasons: maps(j['seasons']).where((s) => (s['season_number'] as int? ?? 0) > 0).map(Season.fromJson).toList(),
      videos: videos.take(12).toList(),
      recommendations: recs,
    );
  }
}

/// Lorewatch: where a title in My List stands, like AniList's lists. Films and series have one
/// too, not just anime.
enum WatchStatus {
  planning('Da vedere', 'PLANNING'),
  watching('In corso', 'CURRENT'),
  completed('Completati', 'COMPLETED'),
  dropped('Abbandonati', 'DROPPED');

  const WatchStatus(this.label, this.anilist);
  final String label;

  /// AniList's name for the list.
  final String anilist;

  /// AniList's list names as Lorewatch's (Paused and Rewatching count as watching).
  static WatchStatus fromAniList(String? s) => switch (s) {
    'PLANNING' => planning,
    'COMPLETED' => completed,
    'DROPPED' => dropped,
    _ => watching,
  };

  static WatchStatus byName(String? s) => values.firstWhere((v) => v.name == s, orElse: () => planning);
}

class SavedTitle {
  const SavedTitle(this.media, this.added, [this.status = WatchStatus.planning]);
  final Media media;
  final DateTime added;
  final WatchStatus status;

  SavedTitle withStatus(WatchStatus s) => SavedTitle(media, added, s);
}

/// "My List", kept on this device. [saved] holds the keys for the + / Save buttons; [items] the
/// full titles (newest first) for the My List page.
class MyList {
  static final saved = ValueNotifier<Set<String>>(const {});
  static final items = ValueNotifier<List<SavedTitle>>(const []);
  static const _key = 'mylist.items';
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final p = _prefs = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_key);
      if (raw == null) return;
      _set([for (final j in (json.decode(raw) as List).cast<Map<String, dynamic>>()) ?_fromJson(j)], persist: false);
    } catch (_) {}
  }

  static Map<String, dynamic> _toJson(SavedTitle s) => {
    'm': {
      'id': s.media.id,
      'title': s.media.title,
      'tv': s.media.isTv,
      'overview': s.media.overview,
      'poster_path': s.media.posterPath,
      'backdrop_path': s.media.backdropPath,
      'vote_average': s.media.rating,
      'genre_ids': s.media.genreIds,
      'popularity': s.media.popularity,
      'vote_count': s.media.voteCount,
      'date': s.media.date.isNotEmpty ? s.media.date : (s.media.year ?? ''),
      if (s.media.anime) 'anime': true,
    },
    'a': s.added.millisecondsSinceEpoch,
    if (s.status != WatchStatus.planning) 's': s.status.name,
  };

  static SavedTitle? _fromJson(Map<String, dynamic> j) {
    try {
      final m = Map<String, dynamic>.from(j['m'] as Map);
      final tv = m['tv'] as bool;
      final date = (m['date'] ?? '') as String;
      return SavedTitle(
        Media.fromJson({...m, tv ? 'first_air_date' : 'release_date': date}, tv: tv),
        DateTime.fromMillisecondsSinceEpoch((j['a'] as num).toInt()),
        WatchStatus.byName(j['s'] as String?),
      );
    } catch (_) {
      return null;
    }
  }

  // ── account sync ──

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async => {for (final s in items.value) s.media.key: _toJson(s)};

  static Future<void> syncApply(String key, Map<String, dynamic>? data) async {
    final list = items.value.where((s) => s.media.key != key).toList();
    final s = data == null ? null : _fromJson(data);
    if (s != null) {
      list.add(s);
      list.sort((a, b) => b.added.compareTo(a.added));
    }
    _set(list);
  }

  static bool has(Media m) => saved.value.contains(m.key);

  /// The list [m] is on, or null when it isn't in My List.
  static WatchStatus? statusOf(Media m) {
    for (final s in items.value) {
      if (s.media.key == m.key) return s.status;
    }
    return null;
  }

  /// Puts [m] on list [status], adding it to My List when it isn't there yet.
  static void setStatus(Media m, WatchStatus status) => setStatuses({m.key: status}, add: [m]);

  /// Moves the titles in [byKey] to their lists. Titles in [add] that aren't saved yet come in.
  static void setStatuses(Map<String, WatchStatus> byKey, {Iterable<Media> add = const []}) {
    var changed = false;
    final list = <SavedTitle>[];
    for (final s in items.value) {
      final st = byKey[s.media.key];
      if (st != null && st != s.status) {
        changed = true;
        list.add(s.withStatus(st));
      } else {
        list.add(s);
      }
    }
    final have = {for (final s in list) s.media.key};
    for (final m in add) {
      final st = byKey[m.key];
      if (st == null || !have.add(m.key)) continue;
      list.insert(0, SavedTitle(m, DateTime.now(), st));
      changed = true;
    }
    if (changed) _set(list);
  }

  static void toggle(Media m) {
    if (has(m)) {
      removeAll({m.key});
    } else {
      _set([SavedTitle(m, DateTime.now()), ...items.value]);
    }
  }

  static void removeAll(Set<String> keys) => _set(items.value.where((s) => !keys.contains(s.media.key)).toList());

  /// Titles brought in from another service, each dated when it was listed there. Ones already
  /// saved stay as they are.
  static void addAll(Iterable<SavedTitle> titles, {bool updateStatus = false}) {
    if (updateStatus) setStatuses({for (final s in titles) if (saved.value.contains(s.media.key)) s.media.key: s.status});
    final keys = {...saved.value};
    final add = [for (final s in titles) if (keys.add(s.media.key)) s];
    if (add.isEmpty) return;
    _set([...items.value, ...add]..sort((a, b) => b.added.compareTo(a.added)));
  }

  static void _set(List<SavedTitle> list, {bool persist = true}) {
    items.value = list;
    saved.value = {for (final s in list) s.media.key};
    if (!persist) return;
    _prefs?.setString(_key, json.encode([for (final s in list) _toJson(s)]));
  }
}

class Person {
  const Person(this.id, this.name, this.profilePath, this.department, this.knownFor, this.popularity);
  final int id;
  final String name;
  final String? profilePath;
  final String department;
  final List<String> knownFor;
  final double popularity;

  factory Person.fromJson(Map<String, dynamic> j) => Person(
        j['id'] as int,
        (j['name'] ?? '') as String,
        j['profile_path'] as String?,
        (j['known_for_department'] ?? '') as String,
        ((j['known_for'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map((k) => (k['title'] ?? k['name'] ?? '') as String)
            .where((s) => s.isNotEmpty)
            .toList(),
        (j['popularity'] as num?)?.toDouble() ?? 0,
      );

  String? get photo => profilePath == null ? null : '$_imageBase/w185$profilePath';
  String? get photoLarge => profilePath == null ? null : '$_imageBase/h632$profilePath';
  String get tmdbUrl => 'https://www.themoviedb.org/person/$id';
}

/// Recent searches for this session, newest first.
class RecentSearches {
  static final items = ValueNotifier<List<String>>(const []);

  static void add(String q) {
    final t = q.trim();
    if (t.length < 2) return;
    items.value = [t, ...items.value.where((s) => s.toLowerCase() != t.toLowerCase())].take(8).toList();
  }

  static void remove(String q) => items.value = items.value.where((s) => s != q).toList();
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9+]'), '');

/// A production company or a TV network.
class Studio {
  const Studio(this.id, this.name, this.logoPath, {required this.isNetwork, this.country});
  final int id;
  final String name;
  final String? logoPath;
  final bool isNetwork;
  final String? country;

  factory Studio.fromJson(Map<String, dynamic> j, {required bool isNetwork}) => Studio(
        j['id'] as int,
        (j['name'] ?? '') as String,
        j['logo_path'] as String?,
        isNetwork: isNetwork,
        country: (j['origin_country'] as String?)?.isEmpty == true ? null : j['origin_country'] as String?,
      );

  String? get logo => logoPath == null ? null : '$_imageBase/w300$logoPath';
  String get kind => isNetwork ? 'TV network' : 'Studio';
}

/// Major networks by TMDB id. Used only to find candidates; names and logos come from TMDB.
const knownNetworks = <(int, String)>[
  (213, 'Netflix'), (49, 'HBO'), (3186, 'Max'), (2739, 'Disney+'), (2552, 'Apple TV+'),
  (1024, 'Prime Video'), (453, 'Hulu'), (4330, 'Paramount+'), (3353, 'Peacock'), (1112, 'Crunchyroll'),
  (174, 'AMC'), (2, 'ABC'), (6, 'NBC'), (16, 'CBS'), (19, 'FOX'), (71, 'The CW'), (88, 'FX'),
  (67, 'Showtime'), (318, 'Starz'), (4, 'BBC One'), (332, 'BBC Two'), (26, 'Channel 4'), (9, 'ITV1'),
  (80, 'Adult Swim'), (56, 'Cartoon Network'), (13, 'Nickelodeon'), (54, 'Disney Channel'),
  (47, 'Comedy Central'), (77, 'Syfy'), (30, 'USA Network'), (41, 'TNT'), (614, 'Tokyo MX'),
  (1, 'Fuji TV'), (98, 'TV Tokyo'), (94, 'MBS'), (866, 'tvN'), (885, 'JTBC'), (342, 'KBS2'), (156, 'SBS'),
];

/// One role in someone's filmography (merged if they did several jobs on the same title).
class Credit {
  const Credit(this.media, this.role, this.department, {this.episodes = 0});
  final Media media;
  final String role;
  final String department;
  final int episodes;
}

class PersonDetails {
  const PersonDetails({
    required this.person,
    this.biography = '',
    this.birthday,
    this.deathday,
    this.birthplace,
    this.alsoKnownAs = const [],
    this.photos = const [],
    this.imdbId,
    this.instagram,
    this.twitter,
    this.tiktok,
    this.credits = const {},
    this.knownFor = const [],
  });

  final Person person;
  final String biography;
  final DateTime? birthday;
  final DateTime? deathday;
  final String? birthplace;
  final List<String> alsoKnownAs;
  final List<String> photos;
  final String? imdbId;
  final String? instagram;
  final String? twitter;
  final String? tiktok;

  /// Department ("Acting", "Directing", ...) → credits, newest first, undated (upcoming) on top.
  final Map<String, List<Credit>> credits;
  final List<Media> knownFor;

  int get creditCount => {for (final l in credits.values) for (final c in l) c.media.key}.length;

  int? get age {
    final b = birthday;
    if (b == null) return null;
    final end = deathday ?? DateTime.now();
    var years = end.year - b.year;
    if (end.month < b.month || (end.month == b.month && end.day < b.day)) years--;
    return years;
  }

  factory PersonDetails.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(Object? v) => ((v as List?) ?? const []).cast<Map<String, dynamic>>();
    Map<String, dynamic> obj(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
    String? nonEmpty(Object? v) => (v as String?)?.trim().isEmpty ?? true ? null : (v as String).trim();

    final combined = obj(j['combined_credits']);
    final byDept = <String, Map<String, Credit>>{};
    void add(Map<String, dynamic> raw, String dept, String role) {
      if (raw['media_type'] != 'movie' && raw['media_type'] != 'tv') return;
      final m = Media.fromJson(raw);
      final bucket = byDept.putIfAbsent(dept, () => {});
      final prev = bucket[m.key];
      final roles = {...?prev?.role.split(', ').where((r) => r.isNotEmpty), if (role.isNotEmpty) role};
      bucket[m.key] = Credit(m, roles.join(', '), dept,
          episodes: (raw['episode_count'] as num?)?.toInt() ?? prev?.episodes ?? 0);
    }

    for (final c in maps(combined['cast'])) {
      add(c, 'Acting', (c['character'] ?? '') as String);
    }
    for (final c in maps(combined['crew'])) {
      add(c, (c['department'] ?? 'Crew') as String, (c['job'] ?? '') as String);
    }

    int newestFirst(Credit a, Credit b) {
      if (a.media.date.isEmpty != b.media.date.isEmpty) return a.media.date.isEmpty ? -1 : 1;
      return b.media.date.compareTo(a.media.date);
    }

    final credits = {
      for (final e in byDept.entries) e.key: e.value.values.toList()..sort(newestFirst),
    };
    // Their main department first, then by size.
    final dept = (j['known_for_department'] ?? 'Acting') as String;
    final ordered = Map.fromEntries(credits.entries.toList()
      ..sort((a, b) => a.key == dept ? -1 : (b.key == dept ? 1 : b.value.length.compareTo(a.value.length))));

    // Skip talk shows and award broadcasts, where everyone "appears".
    final seen = <String>{};
    final knownFor = [
      for (final c in [...?ordered[dept], ...ordered.values.expand((l) => l)])
        if (c.media.posterPath != null && !c.media.genreIds.contains(10767) && !c.media.genreIds.contains(10763) && seen.add(c.media.key))
          c.media,
    ]..sort((a, b) => b.voteCount.compareTo(a.voteCount));

    final ext = obj(j['external_ids']);
    return PersonDetails(
      person: Person(
        j['id'] as int,
        (j['name'] ?? '') as String,
        j['profile_path'] as String?,
        dept,
        const [],
        (j['popularity'] as num?)?.toDouble() ?? 0,
      ),
      biography: ((j['biography'] ?? '') as String).trim(),
      birthday: DateTime.tryParse((j['birthday'] ?? '') as String),
      deathday: DateTime.tryParse((j['deathday'] ?? '') as String),
      birthplace: nonEmpty(j['place_of_birth']),
      alsoKnownAs: ((j['also_known_as'] as List?) ?? const []).cast<String>().take(3).toList(),
      photos: maps(obj(j['images'])['profiles']).map((p) => '$_imageBase/h632${p['file_path']}').take(20).toList(),
      imdbId: nonEmpty(ext['imdb_id']),
      instagram: nonEmpty(ext['instagram_id']),
      twitter: nonEmpty(ext['twitter_id']),
      tiktok: nonEmpty(ext['tiktok_id']),
      credits: ordered,
      knownFor: knownFor.take(20).toList(),
    );
  }
}
