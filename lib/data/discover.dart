import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'tmdb.dart';

enum MediaType { all, movie, tv }

enum SortBy {
  popular('Popolari'),
  topRated('Più votati'),
  newest('Più recenti'),
  mostVoted('Più recensiti'),
  az('A–Z'),
  oldest('Più vecchi');

  const SortBy(this.label);
  final String label;
}

/// One genre across both TMDB catalogues (movie and TV use different ids, and TV lumps some
/// together, e.g. "Sci-Fi & Fantasy").
class DiscoverGenre {
  const DiscoverGenre(this.name, {this.movie, this.tv, this.aliases = const []});
  final String name;
  final int? movie;
  final int? tv;
  final List<String> aliases;

  int? idFor({required bool tv}) => tv ? this.tv : movie;

  static DiscoverGenre? byName(String name) {
    final n = name.toLowerCase();
    for (final g in discoverGenres) {
      if (g.name.toLowerCase() == n || g.aliases.any((a) => a.toLowerCase() == n)) return g;
    }
    return null;
  }
}

const discoverGenres = [
  DiscoverGenre('Action', movie: 28, tv: 10759, aliases: ['Action & Adventure']),
  DiscoverGenre('Adventure', movie: 12, tv: 10759),
  DiscoverGenre('Animation', movie: 16, tv: 16),
  DiscoverGenre('Comedy', movie: 35, tv: 35),
  DiscoverGenre('Crime', movie: 80, tv: 80),
  DiscoverGenre('Documentary', movie: 99, tv: 99),
  DiscoverGenre('Drama', movie: 18, tv: 18),
  DiscoverGenre('Family', movie: 10751, tv: 10751),
  DiscoverGenre('Fantasy', movie: 14, tv: 10765),
  DiscoverGenre('History', movie: 36),
  DiscoverGenre('Horror', movie: 27),
  DiscoverGenre('Kids', tv: 10762),
  DiscoverGenre('Music', movie: 10402),
  DiscoverGenre('Mystery', movie: 9648, tv: 9648),
  DiscoverGenre('Reality', tv: 10764),
  DiscoverGenre('Romance', movie: 10749),
  DiscoverGenre('Sci-Fi', movie: 878, tv: 10765, aliases: ['Science Fiction', 'Sci-Fi & Fantasy']),
  DiscoverGenre('Thriller', movie: 53),
  DiscoverGenre('War', movie: 10752, tv: 10768, aliases: ['War & Politics']),
  DiscoverGenre('Western', movie: 37, tv: 37),
];

const discoverLanguages = <(String?, String)>[
  (null, 'Any language'),
  ('en', 'English'),
  ('ja', 'Japanese'),
  ('ko', 'Korean'),
  ('es', 'Spanish'),
  ('fr', 'French'),
  ('hi', 'Hindi'),
  ('zh', 'Chinese'),
  ('it', 'Italian'),
  ('de', 'German'),
  ('pt', 'Portuguese'),
  ('tr', 'Turkish'),
  ('th', 'Thai'),
  ('sv', 'Swedish'),
  ('da', 'Danish'),
];

String languageName(String? code) =>
    discoverLanguages.firstWhere((l) => l.$1 == code, orElse: () => (code, code?.toUpperCase() ?? '')).$2;

const _keep = Object();

@immutable
class DiscoverQuery {
  const DiscoverQuery({
    this.type = MediaType.all,
    this.sort = SortBy.popular,
    this.genres = const {},
    this.yearFrom,
    this.yearTo,
    this.upcoming = false,
    this.minRating = 0,
    this.maxRating = 10,
    this.minVotes,
    this.language,
    this.providers = const {},
    this.companies = const {},
    this.networks = const {},
  });

  final MediaType type;
  final SortBy sort;
  final Set<String> genres;
  final int? yearFrom;
  final int? yearTo;
  final bool upcoming;
  final double minRating;
  final double maxRating;

  /// null = pick a sensible floor for the sort (see [_autoVotes]).
  final int? minVotes;
  final String? language;
  final Set<int> providers;

  /// Page identity for studio / network pages: not user filters, so [cleared] keeps them.
  final Set<int> companies;
  final Set<int> networks;

  DiscoverQuery copyWith({
    MediaType? type,
    SortBy? sort,
    Set<String>? genres,
    Object? yearFrom = _keep,
    Object? yearTo = _keep,
    bool? upcoming,
    double? minRating,
    double? maxRating,
    Object? minVotes = _keep,
    Object? language = _keep,
    Set<int>? providers,
  }) =>
      DiscoverQuery(
        type: type ?? this.type,
        sort: sort ?? this.sort,
        genres: genres ?? this.genres,
        yearFrom: identical(yearFrom, _keep) ? this.yearFrom : yearFrom as int?,
        yearTo: identical(yearTo, _keep) ? this.yearTo : yearTo as int?,
        upcoming: upcoming ?? this.upcoming,
        minRating: minRating ?? this.minRating,
        maxRating: maxRating ?? this.maxRating,
        minVotes: identical(minVotes, _keep) ? this.minVotes : minVotes as int?,
        language: identical(language, _keep) ? this.language : language as String?,
        providers: providers ?? this.providers,
        companies: companies,
        networks: networks,
      );

  /// Everything except type, sort and the page's studio / network.
  DiscoverQuery cleared() => DiscoverQuery(type: type, sort: sort, companies: companies, networks: networks);

  bool get hasRating => minRating > 0 || maxRating < 10;
  bool get hasYears => yearFrom != null || yearTo != null;

  int get activeFilters =>
      genres.length +
      (hasYears ? 1 : 0) +
      (upcoming ? 1 : 0) +
      (hasRating ? 1 : 0) +
      (minVotes != null ? 1 : 0) +
      (language != null ? 1 : 0) +
      providers.length;

  /// Genres the current type can actually filter by.
  bool genreAvailable(DiscoverGenre g) => switch (type) {
        MediaType.all => true,
        MediaType.movie => g.movie != null,
        MediaType.tv => g.tv != null,
      };

  /// Which catalogues to query. A side drops out if a chosen genre doesn't exist there
  /// (Horror has no TV id, so "Horror" under All shows films only).
  List<bool> get sides => [
        for (final tv in [false, true])
          if ((tv ? type != MediaType.movie : type != MediaType.tv) &&
              (tv || networks.isEmpty) && // networks only air series
              genres.every((g) => DiscoverGenre.byName(g)?.idFor(tv: tv) != null))
            tv,
      ];

  int get _autoVotes => switch (sort) {
        SortBy.topRated => 300,
        SortBy.az || SortBy.oldest => 50,
        SortBy.newest => 5,
        SortBy.popular || SortBy.mostVoted => 0,
      };

  Map<String, String> params({required bool tv, required int page}) {
    final dateKey = tv ? 'first_air_date' : 'primary_release_date';
    final now = DateTime.now();
    final today = '${now.year}-${_two(now.month)}-${_two(now.day)}';

    String? lte = yearTo == null ? null : '$yearTo-12-31';
    if (!upcoming && (lte == null || lte.compareTo(today) > 0)) lte = today;

    final ids = {for (final g in genres) DiscoverGenre.byName(g)!.idFor(tv: tv)!};

    return {
      'page': '$page',
      'include_adult': 'false',
      'sort_by': switch (sort) {
        SortBy.popular => 'popularity.desc',
        SortBy.topRated => 'vote_average.desc',
        SortBy.newest => '$dateKey.desc',
        SortBy.mostVoted => 'vote_count.desc',
        SortBy.az => tv ? 'name.asc' : 'title.asc',
        SortBy.oldest => '$dateKey.asc',
      },
      if (yearFrom != null) '$dateKey.gte': '$yearFrom-01-01',
      '$dateKey.lte': ?lte,
      if (minRating > 0) 'vote_average.gte': minRating.toStringAsFixed(1),
      if (maxRating < 10) 'vote_average.lte': maxRating.toStringAsFixed(1),
      'vote_count.gte': '${minVotes ?? _autoVotes}',
      if (ids.isNotEmpty) 'with_genres': ids.join(','),
      'with_original_language': ?language,
      if (providers.isNotEmpty) ...{'with_watch_providers': providers.join('|'), 'watch_region': 'US'},
      if (companies.isNotEmpty) 'with_companies': companies.join('|'),
      if (networks.isNotEmpty) 'with_networks': networks.join('|'),
      // Lorewatch: no anime among TV series (TMDB's "anime" keyword); they have their own section
      if (tv && language != 'ja') 'without_keywords': '210024',
    };
  }

  /// Ordering for merging a movie page with a TV page.
  int compare(Media a, Media b) => switch (sort) {
        SortBy.popular => b.popularity.compareTo(a.popularity),
        SortBy.topRated => b.rating.compareTo(a.rating),
        SortBy.newest => b.date.compareTo(a.date),
        SortBy.mostVoted => b.voteCount.compareTo(a.voteCount),
        SortBy.az => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        SortBy.oldest => a.date.compareTo(b.date),
      };

  @override
  bool operator ==(Object other) =>
      other is DiscoverQuery &&
      other.type == type &&
      other.sort == sort &&
      setEquals(other.genres, genres) &&
      other.yearFrom == yearFrom &&
      other.yearTo == yearTo &&
      other.upcoming == upcoming &&
      other.minRating == minRating &&
      other.maxRating == maxRating &&
      other.minVotes == minVotes &&
      other.language == language &&
      setEquals(other.providers, providers) &&
      setEquals(other.companies, companies) &&
      setEquals(other.networks, networks);

  @override
  int get hashCode => Object.hash(type, sort, Object.hashAllUnordered(genres), yearFrom, yearTo, upcoming, minRating,
      maxRating, minVotes, language, Object.hashAllUnordered(providers), Object.hashAllUnordered(companies),
      Object.hashAllUnordered(networks));
}

String _two(int n) => n.toString().padLeft(2, '0');

typedef DiscoverResult = ({List<Media> items, int total, int pages});

Future<DiscoverResult> fetchDiscover(DiscoverQuery q, int page) async {
  final sides = q.sides;
  if (sides.isEmpty) return (items: <Media>[], total: 0, pages: 0);

  final responses = await Future.wait(sides.map((tv) async {
    try {
      return (tv: tv, json: await Tmdb.get('/discover/${tv ? 'tv' : 'movie'}', q.params(tv: tv, page: page)));
    } catch (_) {
      // One catalogue running out of pages before the other is normal; a real failure on page 1 isn't.
      if (page == 1) rethrow;
      return (tv: tv, json: const <String, dynamic>{});
    }
  }));

  final items = <Media>[];
  var total = 0, pages = 0;
  for (final r in responses) {
    items.addAll(((r.json['results'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((m) => Media.fromJson(m, tv: r.tv))
        .where((m) => q.language == 'ja' || !(m.isTv && m.tmdbAnime)));
    total += (r.json['total_results'] as num?)?.toInt() ?? 0;
    pages = math.max(pages, (r.json['total_pages'] as num?)?.toInt() ?? 0);
  }
  if (sides.length > 1) items.sort(q.compare);
  return (items: items, total: total, pages: pages);
}

/// Holds the live query and the accumulated, de-duplicated results with infinite paging.
class DiscoverController extends ChangeNotifier {
  DiscoverController(this._query) {
    _load(reset: true);
  }

  DiscoverQuery _query;
  DiscoverQuery get query => _query;

  final List<Media> items = [];
  final _seen = <String>{};
  int total = 0;
  int _page = 0;
  int _pages = 1;
  int _token = 0;

  /// Bumped whenever a fresh result set lands, so cards re-run their entrance.
  int generation = 0;
  bool loading = false;
  bool reloading = false;
  Object? error;
  Timer? _debounce;

  bool get hasMore => _page < _pages && _page < 500;
  bool get initialLoading => loading && items.isEmpty;

  void update(DiscoverQuery q, {bool debounce = false}) {
    if (q == _query) return;
    _query = q;
    _debounce?.cancel();
    if (debounce) {
      notifyListeners();
      _debounce = Timer(const Duration(milliseconds: 320), () => _load(reset: true));
    } else {
      _load(reset: true);
    }
  }

  void loadMore() {
    if (loading || !hasMore || error != null) return;
    _load(reset: false);
  }

  void retry() => _load(reset: items.isEmpty);

  Future<void> _load({required bool reset}) async {
    final token = ++_token;
    loading = true;
    reloading = reset && items.isNotEmpty;
    error = null;
    notifyListeners();

    final page = reset ? 1 : _page + 1;
    try {
      final r = await fetchDiscover(_query, page);
      if (token != _token) return;
      if (reset) {
        items.clear();
        _seen.clear();
        generation++;
      }
      for (final m in r.items) {
        if (_seen.add(m.key)) items.add(m);
      }
      total = r.total;
      _pages = r.pages;
      _page = page;
    } catch (e) {
      if (token != _token) return;
      error = e;
    }
    loading = false;
    reloading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _token++;
    super.dispose();
  }
}
