import 'dart:async';
import 'dart:convert';

import 'net.dart';
import 'trackers/rate_gate.dart';
import 'tmdb.dart' show Media;

/// Anime from AniList (https://anilist.co): browsing with all of its filters, and full details.
/// Adult titles come only when the query asks for them (the app keeps that behind an 18+ switch).
/// AniList allows ~30 requests a minute, so lists are cached
/// and a "slow down" answer is waited out and retried.
class AniList {
  static const _url = 'https://graphql.anilist.co';

  static Future<Map<String, dynamic>> query(String query, [Map<String, dynamic> variables = const {}]) async {
    for (var attempt = 0;; attempt++) {
      // one pace for the whole app: browsing and list updates share AniList's per-minute limit
      final r = await aniListGate.run(
        () => netClient
            .post(
              Uri.parse(_url),
              headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: json.encode({'query': query, 'variables': variables}),
            )
            .timeout(const Duration(seconds: 20)),
      );
      observeAniListHeaders(r.headers);
      if (r.statusCode == 429 && attempt < 2) {
        final wait = int.tryParse(r.headers['retry-after'] ?? '') ?? 5;
        aniListGate.blockFor(Duration(seconds: wait.clamp(1, 60)));
        continue;
      }
      final body = json.decode(r.body);
      final errors = body is Map ? body['errors'] : null;
      if (r.statusCode != 200 || (errors is List && errors.isNotEmpty)) {
        final message = errors is List && errors.isNotEmpty ? '${(errors.first as Map)['message']}' : 'HTTP ${r.statusCode}';
        throw AniListException(message);
      }
      return (body as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    }
  }

  /// One page of anime matching [q] (30 a page).
  static Future<AnimeResults> browse(AnimeQuery q, {int page = 1}) async {
    final args = q.arguments;
    final d = await query(
      'query (\$page: Int${[for (var i = 0; i < args.length; i++) ', \$a$i: ${args[i].$2}'].join()}) {'
      ' Page(page: \$page, perPage: 30) { pageInfo { total hasNextPage }'
      ' media(type: ANIME${[for (var i = 0; i < args.length; i++) ', ${args[i].$1}: \$a$i'].join()}) { $_card } } }',
      {'page': page, for (var i = 0; i < args.length; i++) 'a$i': args[i].$3},
    );
    final p = d['Page'] as Map<String, dynamic>;
    final info = p['pageInfo'] as Map<String, dynamic>;
    return AnimeResults(
      [for (final m in (p['media'] as List).cast<Map<String, dynamic>>()) Anime.fromJson(m)],
      hasMore: info['hasNextPage'] == true,
      total: (info['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// Anime by AniList id, 50 to a request (titles brought in from a tracker).
  static Future<List<Anime>> byIds(List<int> ids) async {
    final out = <Anime>[];
    for (var i = 0; i < ids.length; i += 50) {
      final d = await query(
        'query (\$ids: [Int]) { Page(perPage: 50) { media(id_in: \$ids, type: ANIME) { $_card } } }',
        {'ids': ids.skip(i).take(50).toList()},
      );
      out.addAll([for (final m in ((d['Page'] as Map)['media'] as List).cast<Map<String, dynamic>>()) Anime.fromJson(m)]);
    }
    return out;
  }

  /// AniList ids for MyAnimeList ones, 50 to a request. Ones AniList doesn't know are left out.
  static Future<Map<int, int>> idsForMal(Iterable<int> malIds) async {
    final ids = malIds.toSet().toList(), out = <int, int>{};
    for (var i = 0; i < ids.length; i += 50) {
      final d = await query(
        r'query ($ids: [Int]) { Page(perPage: 50) { media(idMal_in: $ids, type: ANIME) { id idMal } } }',
        {'ids': ids.skip(i).take(50).toList()},
      );
      for (final m in ((d['Page'] as Map)['media'] as List).whereType<Map>()) {
        if (m['idMal'] is int && m['id'] is int) out[m['idMal'] as int] = m['id'] as int;
      }
    }
    return out;
  }

  static final _details = <int, Future<Anime>>{};

  /// Everything about one title: description, studios, tags, relations, recommendations and
  /// episode titles.
  static Future<Anime> details(int id) => _details[id] ??= query(_detailsQuery, {'id': id})
      .then((d) => Anime.fromJson(d['Media'] as Map<String, dynamic>))
      .catchError((Object e) {
        _details.remove(id);
        throw e;
      });

  static Future<List<String>>? _genres;
  static Future<List<String>> genres() => _genres ??= query('{ GenreCollection }')
      .then((d) => (d['GenreCollection'] as List).cast<String>())
      .catchError((Object e) {
        _genres = null;
        throw e;
      });

  static Future<List<AnimeTag>>? _tags;
  static Future<List<AnimeTag>> tags() => _tags ??= query('{ MediaTagCollection { name category description isAdult } }')
      .then((d) => [
            for (final t in (d['MediaTagCollection'] as List).cast<Map<String, dynamic>>())
              AnimeTag('${t['name']}', '${t['category'] ?? ''}', '${t['description'] ?? ''}', adult: t['isAdult'] == true),
          ]..sort((a, b) => a.name.compareTo(b.name)))
      .catchError((Object e) {
        _tags = null;
        throw e;
      });

  static Future<List<StreamingSite>>? _sites;

  /// Where anime is licensed to stream (one entry per service; regional versions share it).
  static Future<List<StreamingSite>> streamingSites() => _sites ??= query(
        '{ ExternalLinkSourceCollection(mediaType: ANIME, type: STREAMING) { id site color icon } }',
      ).then((d) {
        final bySite = <String, StreamingSite>{};
        for (final s in (d['ExternalLinkSourceCollection'] as List).cast<Map<String, dynamic>>()) {
          final name = '${s['site']}';
          final had = bySite[name];
          bySite[name] = StreamingSite(name, [...?had?.ids, (s['id'] as num).toInt()], had?.icon ?? s['icon'] as String?);
        }
        return bySite.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }).catchError((Object e) {
        _sites = null;
        throw e;
      });
}

class AniListException implements Exception {
  AniListException(this.message);
  final String message;
  @override
  String toString() => 'AniList: $message';
}

class AnimeResults {
  const AnimeResults(this.items, {required this.hasMore, required this.total});
  final List<Anime> items;
  final bool hasMore;
  final int total;
}

class AnimeTag {
  const AnimeTag(this.name, this.category, this.description, {this.adult = false});
  final String name;
  final String category;
  final String description;
  final bool adult; // only shown with adult titles switched on
}

/// The genre AniList keeps for adult titles.
const adultGenres = {'Hentai'};

/// Adult titles in the results: left out, mixed in, or nothing else.
enum AdultFilter { hide, include, only }

class StreamingSite {
  const StreamingSite(this.name, this.ids, this.icon);
  final String name;
  final List<int> ids;
  final String? icon;
}

/// A character and the Japanese voice actor playing them.
class AnimeCharacter {
  const AnimeCharacter({required this.name, required this.role, this.image, this.actor, this.url});
  final String name;
  final String role; // MAIN, SUPPORTING, BACKGROUND
  final String? image;
  final String? actor;
  final String? url;

  factory AnimeCharacter.fromJson(Map e) {
    final n = e['node'] as Map;
    final va = ((e['voiceActors'] as List?) ?? const []).cast<Map>().firstOrNull;
    return AnimeCharacter(
      name: '${(n['name'] as Map?)?['full'] ?? ''}',
      role: '${e['role'] ?? ''}',
      image: (n['image'] as Map?)?['large'] as String?,
      actor: (va?['name'] as Map?)?['full'] as String?,
      url: n['siteUrl'] as String?,
    );
  }

  String get roleLabel => switch (role) {
        'MAIN' => 'Main',
        'SUPPORTING' => 'Supporting',
        'BACKGROUND' => 'Background',
        _ => role,
      };
}

/// One episode, with whatever's known about it.
class AnimeEpisode {
  const AnimeEpisode(
    this.number, {
    required this.title,
    this.overview = '',
    this.image,
    this.aired,
    this.runtime,
    this.rating = 0,
    this.upcoming = false,
    this.tvdbId,
    this.absolute,
  });
  final int number;
  final String title;
  final String overview;
  final String? image;
  final DateTime? aired;
  final int? runtime;
  final double rating; // out of 10
  final bool upcoming;

  /// The same episode on TheTVDB (its own id, and its number counted from the show's start):
  /// how Trakt, which has no anime ids, finds it.
  final int? tvdbId;
  final int? absolute;
}

/// What AniList doesn't keep: every episode's title, synopsis and still, plus 16:9 fan art for
/// the backdrop. From ani.zip (the anime databases AniDB and TheTVDB, by AniList id).
class AnimeExtras {
  const AnimeExtras({this.episodes = const {}, this.fanart, this.kitsuId, this.imdbId, this.malId, this.tvdbId, this.tmdbId});
  final Map<int, AnimeEpisode> episodes;
  final String? fanart;

  /// The same anime elsewhere, for Stremio addons ("kitsu:12:1093", or IMDb for films).
  final int? kitsuId;
  final String? imdbId;

  /// MyAnimeList's id, for list sync when AniList has none (it only puts it on a series' first part).
  final int? malId;

  /// The show on TheTVDB / TMDB (a cour is part of a longer show there), for Trakt.
  final int? tvdbId;
  final int? tmdbId;

  static final _cache = <int, Future<AnimeExtras>>{};

  static Future<AnimeExtras> of(int anilistId) => _cache[anilistId] ??= () async {
        try {
          final r = await netClient.get(Uri.parse('https://api.ani.zip/mappings?anilist_id=$anilistId')).timeout(const Duration(seconds: 20));
          final j = r.statusCode == 200 ? json.decode(r.body) : null;
          if (j is! Map) return const AnimeExtras();
          final now = DateTime.now();
          final episodes = <int, AnimeEpisode>{};
          for (final e in ((j['episodes'] as Map?) ?? const {}).entries) {
            final n = int.tryParse('${e.key}');
            final v = e.value;
            if (n == null || v is! Map) continue; // "S1" and the like are specials
            final t = v['title'] is Map ? v['title'] as Map : const {};
            final title = ['en', 'x-jat', 'ja'].map((k) => t[k]).whereType<String>().where((s) => s.trim().isNotEmpty).firstOrNull;
            final aired = DateTime.tryParse('${v['airDateUtc'] ?? v['airDate'] ?? v['airdate'] ?? ''}');
            // the databases write apostrophes as backticks ("I`m Luffy")
            episodes[n] = AnimeEpisode(
              n,
              title: title?.trim().replaceAll('`', '’') ?? 'Episode $n',
              overview: '${v['overview'] ?? v['summary'] ?? ''}'.trim().replaceAll('`', '’'),
              image: v['image'] as String?,
              aired: aired,
              runtime: int.tryParse('${v['runtime'] ?? v['length'] ?? ''}'),
              rating: double.tryParse('${v['rating'] ?? ''}') ?? 0,
              upcoming: aired != null && aired.isAfter(now),
              tvdbId: int.tryParse('${v['tvdbId'] ?? ''}'),
              absolute: int.tryParse('${v['absoluteEpisodeNumber'] ?? ''}'),
            );
          }
          final images = ((j['images'] as List?) ?? const []).cast<Map>();
          final fanart = images.where((i) => i['coverType'] == 'Fanart').map((i) => i['url'] as String?).nonNulls.firstOrNull;
          final ids = j['mappings'] is Map ? j['mappings'] as Map : const {};
          final imdb = '${ids['imdb_id'] ?? ''}';
          return AnimeExtras(
            episodes: episodes,
            fanart: fanart,
            kitsuId: int.tryParse('${ids['kitsu_id'] ?? ''}'),
            imdbId: imdb.startsWith('tt') ? imdb : null,
            malId: int.tryParse('${ids['mal_id'] ?? ''}'),
            tvdbId: int.tryParse('${ids['thetvdb_id'] ?? ''}'),
            tmdbId: int.tryParse('${ids['themoviedb_id'] ?? ''}'),
          );
        } catch (_) {
          _cache.remove(anilistId); // try again next time
          return const AnimeExtras();
        }
      }();

  /// Every episode of [a] (One Piece: all of them, not just what a streaming service lists),
  /// numbered from 1; AniList's own episode titles fill in where the databases have none.
  static Future<List<AnimeEpisode>> episodesOf(Anime a) async {
    final x = await of(a.id);
    final known = x.episodes.keys.fold(0, (m, n) => n > m ? n : m);
    final count = a.status == 'FINISHED' && a.episodes != null ? a.episodes! : [a.episodes ?? 0, a.aired ?? 0, known].reduce((m, n) => n > m ? n : m);
    AnimeEpisode episode(int n) {
      final e = x.episodes[n];
      final named = e != null && e.title != 'Episode $n';
      return AnimeEpisode(
        n,
        title: named ? e.title : (a.episodeTitle(n) ?? 'Episode $n'),
        overview: e?.overview ?? '',
        image: e?.image ?? a.episodeThumbnail(n),
        aired: e?.aired,
        runtime: e?.runtime ?? a.duration,
        rating: e?.rating ?? 0,
        upcoming: (e?.upcoming ?? false) || a.status == 'NOT_YET_RELEASED' || (a.nextEpisode != null && n >= a.nextEpisode!),
      );
    }

    return [for (var n = 1; n <= count; n++) episode(n)];
  }
}

/// How AniList relates two titles (prequel, sequel, side story…), with the other title.
class AnimeRelation {
  const AnimeRelation(this.type, this.anime);
  final String type;
  final Anime anime;

  String get label => switch (type) {
        'SIDE_STORY' => 'Side story',
        'SPIN_OFF' => 'Spin-off',
        'PARENT' => 'Parent story',
        'ALTERNATIVE' => 'Alternative',
        _ => type[0] + type.substring(1).toLowerCase().replaceAll('_', ' '),
      };
}

class Anime {
  const Anime({
    required this.id,
    this.idMal,
    this.romaji = '',
    this.english = '',
    this.native = '',
    this.synonyms = const [],
    this.cover,
    this.coverSmall,
    this.color,
    this.banner,
    this.type = 'ANIME',
    this.format = '',
    this.status = '',
    this.episodes,
    this.duration,
    this.season,
    this.year,
    this.score,
    this.popularity = 0,
    this.favourites = 0,
    this.genres = const [],
    this.nextEpisode,
    this.nextEpisodeAt,
    this.description = '',
    this.studios = const [],
    this.source,
    this.country,
    this.tags = const [],
    this.relations = const [],
    this.recommendations = const [],
    this.trailer,
    this.episodeTitles = const [],
    this.siteUrl,
    this.isAdult = false,
    this.characters = const [],
    this.started,
    this.ended,
  });

  final int id;
  final int? idMal;
  final String romaji;
  final String english;
  final String native;
  final List<String> synonyms;
  final String? cover; // extra large
  final String? coverSmall;
  final String? color; // the cover's main colour, #rrggbb
  final String? banner;
  final String type; // ANIME or MANGA (relations can point at manga)
  final String format; // TV, TV_SHORT, MOVIE, SPECIAL, OVA, ONA, MUSIC
  final String status; // RELEASING, FINISHED, NOT_YET_RELEASED, CANCELLED, HIATUS
  final int? episodes;
  final int? duration; // minutes per episode
  final String? season; // WINTER, SPRING, SUMMER, FALL
  final int? year;
  final int? score; // average, out of 100
  final int popularity;
  final int favourites;
  final List<String> genres;
  final int? nextEpisode;
  final DateTime? nextEpisodeAt;
  final String description; // plain text
  final List<String> studios;
  final String? source;
  final String? country;
  final List<({String name, int rank, bool spoiler})> tags;
  final List<AnimeRelation> relations;
  final List<Anime> recommendations;
  final String? trailer; // YouTube id
  final List<({String title, String? thumbnail})> episodeTitles;
  final String? siteUrl;
  final bool isAdult; // AniList marks it 18+
  final List<AnimeCharacter> characters;
  final DateTime? started;
  final DateTime? ended;

  String get title => english.isNotEmpty ? english : (romaji.isNotEmpty ? romaji : native);

  /// What a saved title knows (from My List, Continue watching, a watch party), for opening
  /// its page right away; the rest loads in.
  factory Anime.fromMedia(Media m) => Anime(
    id: m.id,
    english: m.title,
    cover: m.posterPath,
    banner: m.backdropPath,
    format: m.isTv ? 'TV' : 'MOVIE',
    description: m.overview,
    year: int.tryParse(m.year ?? ''),
  );

  /// This anime as a title for My List, Continue watching, History and watch parties
  /// (key `anime/<id>`; synced with the account like any other).
  Media get media => Media(
    id: id,
    title: title,
    isTv: !isMovie,
    anime: true,
    overview: description,
    posterPath: cover ?? coverSmall,
    backdropPath: banner,
    rating: (score ?? 0) / 10,
    year: year?.toString(),
    popularity: popularity.toDouble(),
    date: started == null ? '' : started!.toIso8601String().substring(0, 10),
  );
  bool get isMovie => format == 'MOVIE';

  /// Episodes out so far (all of them once it's finished).
  int? get aired => nextEpisode != null ? nextEpisode! - 1 : episodes;

  String get formatLabel => animeFormats[format] ?? format;

  factory Anime.fromJson(Map<String, dynamic> j) {
    final t = (j['title'] as Map?) ?? const {};
    final c = (j['coverImage'] as Map?) ?? const {};
    final next = j['nextAiringEpisode'] as Map?;
    final trailer = j['trailer'] as Map?;
    return Anime(
      id: (j['id'] as num).toInt(),
      idMal: (j['idMal'] as num?)?.toInt(),
      romaji: '${t['romaji'] ?? ''}',
      english: '${t['english'] ?? ''}',
      native: '${t['native'] ?? ''}',
      synonyms: ((j['synonyms'] as List?) ?? const []).cast<String>(),
      cover: (c['extraLarge'] ?? c['large']) as String?,
      coverSmall: (c['large'] ?? c['extraLarge']) as String?,
      color: c['color'] as String?,
      banner: j['bannerImage'] as String?,
      type: '${j['type'] ?? 'ANIME'}',
      format: '${j['format'] ?? ''}',
      status: '${j['status'] ?? ''}',
      episodes: (j['episodes'] as num?)?.toInt(),
      duration: (j['duration'] as num?)?.toInt(),
      season: j['season'] as String?,
      year: (j['seasonYear'] as num?)?.toInt() ?? ((j['startDate'] as Map?)?['year'] as num?)?.toInt(),
      score: (j['averageScore'] as num?)?.toInt() ?? (j['meanScore'] as num?)?.toInt(),
      popularity: (j['popularity'] as num?)?.toInt() ?? 0,
      favourites: (j['favourites'] as num?)?.toInt() ?? 0,
      genres: ((j['genres'] as List?) ?? const []).cast<String>(),
      nextEpisode: (next?['episode'] as num?)?.toInt(),
      nextEpisodeAt: next?['airingAt'] is num ? DateTime.fromMillisecondsSinceEpoch((next!['airingAt'] as num).toInt() * 1000) : null,
      description: _plain('${j['description'] ?? ''}'),
      studios: [for (final s in (((j['studios'] as Map?)?['nodes'] as List?) ?? const []).cast<Map>()) '${s['name']}'],
      source: j['source'] as String?,
      country: j['countryOfOrigin'] as String?,
      tags: [
        for (final g in ((j['tags'] as List?) ?? const []).cast<Map>())
          (name: '${g['name']}', rank: (g['rank'] as num?)?.toInt() ?? 0, spoiler: g['isMediaSpoiler'] == true || g['isGeneralSpoiler'] == true),
      ],
      relations: [
        for (final e in (((j['relations'] as Map?)?['edges'] as List?) ?? const []).cast<Map>())
          if (e['node'] is Map) AnimeRelation('${e['relationType']}', Anime.fromJson((e['node'] as Map).cast<String, dynamic>())),
      ],
      recommendations: [
        for (final n in (((j['recommendations'] as Map?)?['nodes'] as List?) ?? const []).cast<Map>())
          if (n['mediaRecommendation'] is Map) Anime.fromJson((n['mediaRecommendation'] as Map).cast<String, dynamic>()),
      ],
      trailer: trailer != null && trailer['site'] == 'youtube' ? trailer['id'] as String? : null,
      episodeTitles: [
        for (final e in ((j['streamingEpisodes'] as List?) ?? const []).cast<Map>())
          (title: '${e['title'] ?? ''}', thumbnail: e['thumbnail'] as String?),
      ],
      siteUrl: j['siteUrl'] as String?,
      isAdult: j['isAdult'] == true,
      characters: [
        for (final e in (((j['characters'] as Map?)?['edges'] as List?) ?? const []).cast<Map>())
          if (e['node'] is Map) AnimeCharacter.fromJson(e),
      ],
      started: _date(j['startDate']),
      ended: _date(j['endDate']),
    );
  }

  static DateTime? _date(Object? d) {
    if (d is! Map || d['year'] == null) return null;
    return DateTime((d['year'] as num).toInt(), (d['month'] as num?)?.toInt() ?? 1, (d['day'] as num?)?.toInt() ?? 1);
  }

  /// The title AniList's streaming partners gave episode [n] ("Episode 3 - The Promise" → "The Promise").
  String? episodeTitle(int n) {
    for (final e in episodeTitles) {
      final m = RegExp(r'^Episode\s+(\d+)\s*[-–:]\s*(.+)$', caseSensitive: false).firstMatch(e.title);
      if (m != null && int.parse(m[1]!) == n) return m[2]!.trim();
    }
    return null;
  }

  String? episodeThumbnail(int n) {
    for (final e in episodeTitles) {
      final m = RegExp(r'^Episode\s+(\d+)\b', caseSensitive: false).firstMatch(e.title);
      if (m != null && int.parse(m[1]!) == n) return e.thumbnail;
    }
    return null;
  }
}

/// AniList descriptions carry a little HTML (<br>, <i>, links); this keeps the words and breaks.
String _plain(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#039;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

// ───────────────────────── Filters ─────────────────────────

const animeFormats = {
  'TV': 'TV',
  'TV_SHORT': 'TV short',
  'MOVIE': 'Movie',
  'SPECIAL': 'Special',
  'OVA': 'OVA',
  'ONA': 'ONA',
  'MUSIC': 'Music',
};

const animeStatuses = {
  'RELEASING': 'Airing',
  'FINISHED': 'Finished',
  'NOT_YET_RELEASED': 'Not yet aired',
  'HIATUS': 'On hiatus',
  'CANCELLED': 'Cancelled',
};

const animeSeasons = {'WINTER': 'Winter', 'SPRING': 'Spring', 'SUMMER': 'Summer', 'FALL': 'Fall'};

const animeSources = {
  'ORIGINAL': 'Original',
  'MANGA': 'Manga',
  'LIGHT_NOVEL': 'Light novel',
  'WEB_NOVEL': 'Web novel',
  'NOVEL': 'Novel',
  'VISUAL_NOVEL': 'Visual novel',
  'VIDEO_GAME': 'Video game',
  'GAME': 'Game',
  'COMIC': 'Comic',
  'DOUJINSHI': 'Doujinshi',
  'ANIME': 'Anime',
  'LIVE_ACTION': 'Live action',
  'MULTIMEDIA_PROJECT': 'Multimedia project',
  'PICTURE_BOOK': 'Picture book',
  'OTHER': 'Other',
};

const animeCountries = {'JP': 'Japan', 'KR': 'South Korea', 'CN': 'China', 'TW': 'Taiwan'};

enum AnimeSort {
  trending('Di tendenza', ['TRENDING_DESC', 'POPULARITY_DESC']),
  popular('Popolari', ['POPULARITY_DESC']),
  score('Più votati', ['SCORE_DESC']),
  favourites('Più amati', ['FAVOURITES_DESC']),
  newest('Più recenti', ['START_DATE_DESC']),
  added('Aggiunti di recente', ['ID_DESC']),
  title('A–Z', ['TITLE_ROMAJI']);

  const AnimeSort(this.label, this.keys);
  final String label;
  final List<String> keys;
}

const _keep = Object();

/// Everything AniList's own browse page filters by (minus the ones that need an AniList login).
/// Ranges use the slider ends to mean "no limit".
class AnimeQuery {
  const AnimeQuery({
    this.search = '',
    this.sort = AnimeSort.trending,
    this.genres = const {},
    this.genresNot = const {},
    this.tags = const {},
    this.tagsNot = const {},
    this.formats = const {},
    this.statuses = const {},
    this.season,
    this.yearFrom,
    this.yearTo,
    this.sources = const {},
    this.country,
    this.streaming = const {},
    this.episodesMin,
    this.episodesMax,
    this.durationMin,
    this.durationMax,
    this.scoreMin,
    this.scoreMax,
    this.doujin = false,
    this.adult = AdultFilter.hide,
    this.tagRank,
  });

  final String search;
  final AnimeSort sort;
  final Set<String> genres;
  final Set<String> genresNot;
  final Set<String> tags;
  final Set<String> tagsNot;
  final Set<String> formats;
  final Set<String> statuses;
  final String? season;
  final int? yearFrom;
  final int? yearTo;
  final Set<String> sources;
  final String? country;
  final Set<String> streaming; // service names (each may have several AniList ids)
  final int? episodesMin;
  final int? episodesMax;
  final int? durationMin;
  final int? durationMax;
  final int? scoreMin; // out of 100
  final int? scoreMax;
  final bool doujin; // only unlicensed fan works
  final AdultFilter adult;
  final int? tagRank; // the picked tags must be at least this % relevant

  static const maxEpisodes = 150, maxDuration = 170;

  AnimeQuery copyWith({
    String? search,
    AnimeSort? sort,
    Set<String>? genres,
    Set<String>? genresNot,
    Set<String>? tags,
    Set<String>? tagsNot,
    Set<String>? formats,
    Set<String>? statuses,
    Object? season = _keep,
    Object? yearFrom = _keep,
    Object? yearTo = _keep,
    Set<String>? sources,
    Object? country = _keep,
    Set<String>? streaming,
    Object? episodesMin = _keep,
    Object? episodesMax = _keep,
    Object? durationMin = _keep,
    Object? durationMax = _keep,
    Object? scoreMin = _keep,
    Object? scoreMax = _keep,
    bool? doujin,
    AdultFilter? adult,
    Object? tagRank = _keep,
  }) =>
      AnimeQuery(
        search: search ?? this.search,
        sort: sort ?? this.sort,
        genres: genres ?? this.genres,
        genresNot: genresNot ?? this.genresNot,
        tags: tags ?? this.tags,
        tagsNot: tagsNot ?? this.tagsNot,
        formats: formats ?? this.formats,
        statuses: statuses ?? this.statuses,
        season: identical(season, _keep) ? this.season : season as String?,
        yearFrom: identical(yearFrom, _keep) ? this.yearFrom : yearFrom as int?,
        yearTo: identical(yearTo, _keep) ? this.yearTo : yearTo as int?,
        sources: sources ?? this.sources,
        country: identical(country, _keep) ? this.country : country as String?,
        streaming: streaming ?? this.streaming,
        episodesMin: identical(episodesMin, _keep) ? this.episodesMin : episodesMin as int?,
        episodesMax: identical(episodesMax, _keep) ? this.episodesMax : episodesMax as int?,
        durationMin: identical(durationMin, _keep) ? this.durationMin : durationMin as int?,
        durationMax: identical(durationMax, _keep) ? this.durationMax : durationMax as int?,
        scoreMin: identical(scoreMin, _keep) ? this.scoreMin : scoreMin as int?,
        scoreMax: identical(scoreMax, _keep) ? this.scoreMax : scoreMax as int?,
        doujin: doujin ?? this.doujin,
        adult: adult ?? this.adult,
        tagRank: identical(tagRank, _keep) ? this.tagRank : tagRank as int?,
      );

  /// No filters (the search, the sort and how adult titles are treated stay).
  AnimeQuery cleared() => AnimeQuery(search: search, sort: sort, adult: adult);

  /// Adult titles and their genre and tags taken out (the 18+ switch is off).
  AnimeQuery withoutAdult(Set<String> adultTags) => copyWith(
        adult: AdultFilter.hide,
        genres: genres.difference(adultGenres),
        genresNot: genresNot.difference(adultGenres),
        tags: tags.difference(adultTags),
        tagsNot: tagsNot.difference(adultTags),
      );

  int get activeFilters => [
        genres.length + genresNot.length,
        tags.length + tagsNot.length,
        formats.length,
        statuses.length,
        if (season != null) 1,
        if (yearFrom != null || yearTo != null) 1,
        sources.length,
        if (country != null) 1,
        streaming.length,
        if (episodesMin != null || episodesMax != null) 1,
        if (durationMin != null || durationMax != null) 1,
        if (scoreMin != null || scoreMax != null) 1,
        if (doujin) 1,
        if (adult == AdultFilter.only) 1,
        if (tagRank != null) 1,
      ].fold(0, (a, b) => a + b);

  /// AniList's ids for the picked streaming services, filled in by the filter panel.
  static final streamingIds = <String, List<int>>{};

  /// The filters that are set, as (AniList argument, GraphQL type, value). Only these go into
  /// the query: AniList fails on several of its arguments when they're sent empty.
  List<(String, String, Object)> get arguments {
    final out = <(String, String, Object)>[];
    void add(String arg, String type, Object? v) {
      if (v == null || (v is Iterable && v.isEmpty)) return;
      out.add((arg, type, v is Iterable ? v.toList() : v));
    }

    final single = yearFrom != null && yearFrom == yearTo;
    // the _greater/_lesser arguments leave out the number itself, so the ends move out by one
    add('search', 'String', search.trim().isEmpty ? null : search.trim());
    // best match first while searching, unless another order was picked
    add('sort', '[MediaSort]', search.trim().isNotEmpty && sort == AnimeSort.trending ? const ['SEARCH_MATCH'] : sort.keys);
    add('genre_in', '[String]', genres);
    add('genre_not_in', '[String]', genresNot);
    add('tag_in', '[String]', tags);
    add('tag_not_in', '[String]', tagsNot);
    add('format_in', '[MediaFormat]', formats);
    add('status_in', '[MediaStatus]', statuses);
    add('season', 'MediaSeason', season);
    add('seasonYear', 'Int', single ? yearFrom : null);
    add('startDate_greater', 'FuzzyDateInt', !single && yearFrom != null ? yearFrom! * 10000 : null);
    add('startDate_lesser', 'FuzzyDateInt', !single && yearTo != null ? (yearTo! + 1) * 10000 : null);
    add('source_in', '[MediaSource]', sources);
    add('countryOfOrigin', 'CountryCode', country);
    add('licensedById_in', '[Int]', [for (final s in streaming) ...?streamingIds[s]]);
    add('episodes_greater', 'Int', episodesMin != null ? episodesMin! - 1 : null);
    add('episodes_lesser', 'Int', episodesMax != null ? episodesMax! + 1 : null);
    add('duration_greater', 'Int', durationMin != null ? durationMin! - 1 : null);
    add('duration_lesser', 'Int', durationMax != null ? durationMax! + 1 : null);
    add('averageScore_greater', 'Int', scoreMin != null ? scoreMin! - 1 : null);
    add('averageScore_lesser', 'Int', scoreMax != null ? scoreMax! + 1 : null);
    add('isLicensed', 'Boolean', doujin ? false : null);
    add('isAdult', 'Boolean', switch (adult) {
      AdultFilter.hide => false,
      AdultFilter.only => true,
      AdultFilter.include => null,
    });
    add('minimumTagRank', 'Int', tags.isEmpty && tagsNot.isEmpty ? null : tagRank);
    return out;
  }
}

const _card = '''
  id idMal type format status episodes duration season seasonYear averageScore popularity favourites genres isAdult
  title { romaji english native }
  coverImage { extraLarge large color }
  nextAiringEpisode { episode airingAt }
''';

const _detailsQuery = '''
query (\$id: Int) {
  Media(id: \$id, type: ANIME) {
    $_card
    synonyms bannerImage source countryOfOrigin siteUrl meanScore
    description(asHtml: false)
    startDate { year month day }
    endDate { year month day }
    trailer { id site }
    characters(sort: [ROLE, RELEVANCE, ID], perPage: 18) {
      edges { role node { name { full } image { large } siteUrl } voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { name { full } } }
    }
    studios(isMain: true) { nodes { name } }
    tags { name rank isMediaSpoiler isGeneralSpoiler }
    streamingEpisodes { title thumbnail }
    recommendations(sort: RATING_DESC, perPage: 15) { nodes { mediaRecommendation { $_card } } }
    relations { edges { relationType(version: 2) node { $_card } } }
  }
}
''';
