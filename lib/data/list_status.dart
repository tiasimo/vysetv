import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anilist.dart';
import 'tmdb.dart';
import 'trackers/anilist_tracker.dart';
import 'trackers/library_import.dart';
import 'trackers/token_store.dart';
import 'trackers/tracker.dart';
import 'watch_progress.dart';

/// Lorewatch: keeps My List's lists (Da vedere, In corso, Completati, Abbandonati) moving with
/// what you watch, and tells AniList when you move an anime yourself.
abstract final class ListStatusSync {
  /// Starting a title on Da vedere moves it to In corso; finishing a film moves it to Completati.
  /// Titles you put on Completati or Abbandonati yourself stay there.
  static void start() {
    WatchProgress.entries.addListener(_progressChanged);
    _progressChanged();
  }

  static void _progressChanged() {
    final byKey = <String, WatchStatus>{};
    for (final e in WatchProgress.entries.value) {
      final now = MyList.statusOf(e.media);
      if (now == null || now == WatchStatus.completed || now == WatchStatus.dropped) continue;
      final film = !e.media.isTv && !e.media.anime;
      if (film && e.finished) {
        byKey[e.media.key] = WatchStatus.completed;
      } else if (now == WatchStatus.planning && e.position > Duration.zero) {
        byKey[e.media.key] = WatchStatus.watching;
      }
    }
    if (byKey.isNotEmpty) MyList.setStatuses(byKey);
  }

  /// Lorewatch: brings your AniList manga list into My List (Manga), each on its list, and
  /// keeps the lists in step. Runs at start and after an AniList import.
  static Future<void> syncManga() async {
    try {
      final list = await AniListTracker.mangaList();
      if (list.isEmpty) return;
      MyList.addAll([
        for (final e in list) SavedTitle(e.media, e.added.millisecondsSinceEpoch > 0 ? e.added : DateTime.now(), WatchStatus.fromAniList(e.status)),
      ], updateStatus: true);
      await MangaChapters.setAll({for (final e in list) e.media.id: e.progress});
    } catch (e) {
      debugPrint('[ListStatus] AniList manga: $e');
    }
  }

  /// Lorewatch: at every start, the episodes watched on AniList since last time come into
  /// History (so My List shows where each anime is), along with any anime newly on a list.
  static Future<void> syncAniList() async {
    try {
      if (await TokenStore.read(TrackerId.anilist) == null) return;
      final p = await LibraryImport.plan(TrackerId.anilist);
      if (!p.isEmpty) await LibraryImport.apply(p, list: true, watched: true);
    } catch (e) {
      debugPrint('[ListStatus] AniList sync: $e');
    }
    await syncManga();
  }

  /// Moves [titles] to [status] in My List (adding them when they aren't there) and, for anime
  /// while AniList is connected, on AniList too.
  static Future<void> set(Iterable<Media> titles, WatchStatus status) async {
    final list = titles.toList();
    MyList.setStatuses({for (final m in list) m.key: status}, add: list);
    final anime = list.where((m) => m.anime || m.manga).toList();
    if (anime.isEmpty) return;
    final t = await TokenStore.read(TrackerId.anilist);
    if (t == null) return;
    for (final m in anime) {
      try {
        await AniListTracker.setListStatus(t, m.id, status.anilist);
      } catch (e) {
        debugPrint('[ListStatus] AniList: $e');
      }
    }
  }
}


/// Lorewatch: chapters read of each AniList manga (from AniList, and from reading here), and
/// which manga in the Manga libraries is which AniList one, so reading a chapter here moves
/// AniList's count too.
abstract final class MangaChapters {
  static const _readKey = 'lw.manga.read', _linkKey = 'lw.manga.links';

  /// AniList id -> chapters read. My List shows it on manga ("Cap. 120").
  static final read = ValueNotifier<Map<int, int>>(const {});
  static Map<String, int> _links = {}; // library manga id -> AniList id

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final r = json.decode(prefs.getString(_readKey) ?? '{}') as Map;
      read.value = {for (final e in r.entries) int.parse('${e.key}'): (e.value as num).toInt()};
      final l = json.decode(prefs.getString(_linkKey) ?? '{}') as Map;
      _links = {for (final e in l.entries) '${e.key}': (e.value as num).toInt()};
    } catch (_) {}
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_readKey, json.encode({for (final e in read.value.entries) '${e.key}': e.value}));
    await prefs.setString(_linkKey, json.encode(_links));
  }

  static Future<void> setAll(Map<int, int> fromAniList) async {
    read.value = {...read.value, ...fromAniList};
    await _save();
  }

  /// Remembers that library manga [libraryId] is AniList manga [anilistId].
  static Future<void> link(String libraryId, int anilistId) async {
    if (_links[libraryId] == anilistId) return;
    _links[libraryId] = anilistId;
    await _save();
  }

  /// Called as you read: chapter [number] of library manga [libraryId], [started] once past its
  /// first page. When it's an AniList manga and further than before, AniList hears about it.
  static Future<void> reading(String libraryId, double? number, {required bool started}) async {
    final id = _links[libraryId];
    if (id == null || number == null) return;
    final done = started ? number.floor() : number.floor() - 1;
    final before = read.value[id] ?? 0;
    if (done <= before) return;
    read.value = {...read.value, id: done};
    await _save();
    final t = await TokenStore.read(TrackerId.anilist);
    if (t == null) return;
    try {
      final planning = MyList.items.value.where((s) => s.media.manga && s.media.id == id).firstOrNull?.status == WatchStatus.planning;
      await AniListTracker.setMangaProgress(t, id, done, start: planning);
      if (planning) {
        MyList.setStatuses({'manga/$id': WatchStatus.watching});
      }
    } catch (e) {
      debugPrint('[MangaChapters] AniList: $e');
    }
  }
}

/// Lorewatch: how many episodes a show has, for "E16/24" in My List. Anime: AniList's count
/// (key '0'); TMDB shows: each season's. Kept on the device and looked at again every few days
/// (shows still airing grow).
abstract final class EpisodeTotals {
  static const _key = 'lw.ep.totals';
  static const _stale = Duration(days: 1);

  /// Bumps when new counts arrive.
  static final revision = ValueNotifier<int>(0);

  /// Ticks every minute, for the countdowns.
  static final minute = _MinuteTicker();

  static Map<String, Map<String, int>> _totals = {};
  static Map<String, int> _fetched = {};
  static Map<String, List<int>> _next = {}; // key -> [airs at (ms), episode, season]
  static final _queue = <String, Media>{};
  static final _asked = <String>{};
  static Timer? _timer;
  static bool _running = false;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = json.decode(p.getString(_key) ?? '{}') as Map;
      _totals = {
        for (final e in ((raw['t'] as Map?) ?? const {}).entries)
          '${e.key}': {for (final s in (e.value as Map).entries) '${s.key}': (s.value as num).toInt()},
      };
      _fetched = {for (final e in ((raw['f'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()};
      _next = {
        for (final e in ((raw['n'] as Map?) ?? const {}).entries) '${e.key}': [for (final v in e.value as List) (v as num).toInt()],
      };
    } catch (_) {}
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, json.encode({'t': _totals, 'f': _fetched, 'n': _next}));
  }

  /// Episodes in [m] (that [season], for TMDB shows), or null while unknown (it's then looked up).
  static int? of(Media m, int? season) {
    if (!m.isTv && !m.anime) return null;
    final t = _totals[m.key];
    final f = _fetched[m.key];
    if (f == null || DateTime.now().millisecondsSinceEpoch - f > _stale.inMilliseconds) _want(m);
    if (t == null) return null;
    final n = m.anime ? t['0'] : t['${season ?? 1}'];
    return n == null || n <= 0 ? null : n;
  }

  /// The next episode of [m] still to come out: when, and which. Null when none is known.
  static ({DateTime at, int episode, int? season})? next(Media m) {
    if (!m.isTv && !m.anime) return null;
    final f = _fetched[m.key];
    final n = _next[m.key];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (f == null || now - f > _stale.inMilliseconds || (n != null && n[0] <= now)) _want(m);
    if (n == null || n[0] <= now) return null;
    return (at: DateTime.fromMillisecondsSinceEpoch(n[0]), episode: n[1], season: n.length > 2 && n[2] > 0 ? n[2] : null);
  }

  static void _want(Media m) {
    if (!_asked.add(m.key)) return; // once per run
    _queue[m.key] = m;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), _run);
  }

  static Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.values.toList();
        _queue.clear();
        final now = DateTime.now().millisecondsSinceEpoch;
        // anime: 50 at a time in one AniList query
        final anime = batch.where((m) => m.anime).toList();
        for (var i = 0; i < anime.length; i += 50) {
          final ids = anime.skip(i).take(50).map((m) => m.id).toList();
          try {
            final d = await AniList.query(
              r'query($ids:[Int]){Page(perPage:50){media(id_in:$ids,type:ANIME){id episodes nextAiringEpisode{episode airingAt}}}}',
              {'ids': ids},
            );
            for (final x in ((d['Page'] as Map)['media'] as List).cast<Map<String, dynamic>>()) {
              final n = (x['episodes'] as num?)?.toInt();
              final key = anime.firstWhere((m) => m.id == x['id']).key;
              if (n != null) _totals[key] = {'0': n};
              final na = x['nextAiringEpisode'] as Map?;
              if (na != null && na['airingAt'] is num) {
                _next[key] = [(na['airingAt'] as num).toInt() * 1000, (na['episode'] as num? ?? 0).toInt(), 0];
              } else {
                _next.remove(key);
              }
              _fetched[key] = now;
            }
          } catch (e) {
            debugPrint('[EpisodeTotals] AniList: $e');
          }
          revision.value++;
        }
        // TMDB shows: a few at a time
        final shows = batch.where((m) => !m.anime).toList();
        for (var i = 0; i < shows.length; i += 4) {
          await Future.wait([
            for (final m in shows.skip(i).take(4))
              () async {
                try {
                  final j = await Tmdb.get('/tv/${m.id}');
                  final seasons = (j['seasons'] as List? ?? const []).cast<Map<String, dynamic>>();
                  _totals[m.key] = {
                    for (final s in seasons)
                      if ((s['season_number'] as num? ?? 0) > 0) '${s['season_number']}': (s['episode_count'] as num? ?? 0).toInt(),
                  };
                  final na = j['next_episode_to_air'] as Map?;
                  final day = DateTime.tryParse('${na?['air_date'] ?? ''}');
                  if (na != null && day != null) {
                    // TMDB knows the day, not the hour: count to the evening (21:00 here)
                    _next[m.key] = [
                      DateTime(day.year, day.month, day.day, 21).millisecondsSinceEpoch,
                      (na['episode_number'] as num? ?? 0).toInt(),
                      (na['season_number'] as num? ?? 0).toInt(),
                    ];
                  } else {
                    _next.remove(m.key);
                  }
                  _fetched[m.key] = now;
                } catch (_) {}
              }(),
          ]);
          revision.value++;
        }
        await _save();
      }
    } finally {
      _running = false;
    }
  }
}

class _MinuteTicker extends ChangeNotifier {
  _MinuteTicker() {
    Timer.periodic(const Duration(minutes: 1), (_) => notifyListeners());
  }
}

/// "2g 5h", "5h 20m", "20m".
String countdownLabel(DateTime at) {
  final d = at.difference(DateTime.now());
  if (d.inDays >= 1) return '${d.inDays}g ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${math.max(1, d.inMinutes)}m';
}
