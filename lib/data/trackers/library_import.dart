import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../anilist.dart' show AniList;
import '../app_settings.dart';
import '../tmdb.dart';
import '../watch_progress.dart';
import 'anilist_tracker.dart';
import 'media_ref.dart';
import 'remote_library.dart';
import 'simkl_tracker.dart';
import 'token_store.dart';
import 'tracker.dart';
import 'trakt_tracker.dart';

/// What an import would bring in, worked out before anything changes.
class ImportPlan {
  ImportPlan(this.id, {required this.list, required this.history, required this.resume, required this.baseline, required this.found, this.cursor});

  final TrackerId id;

  /// On the watchlist there and not in My List here, newest first.
  final List<RemoteTitle> list;

  /// Watched there more recently than here, newest first.
  final List<RemoteTitle> history;

  /// Paused part-way there more recently than here, newest first.
  final List<RemoteTitle> resume;

  /// The watchlist as it stands, to follow from now on.
  final Set<String> baseline;

  /// Titles found there in all.
  final int found;

  final String? cursor;

  bool get isEmpty => list.isEmpty && history.isEmpty && resume.isEmpty;
}

/// Brings what's on Trakt, Simkl and AniList into Lorewatch: the watchlist into My
/// List, the newest watches into History, resume points into Continue watching. After that,
/// titles added to the watchlist there (or taken off it) follow into My List at app start.
///
/// Only the newest [historyCap] watches and [resumeCap] resume points come in, and one only
/// replaces what's here when it's newer, so History stays light and Continue watching stays
/// yours. Nothing is sent back: an import doesn't change anything on the service.
class LibraryImport {
  static const historyCap = 100;
  static const resumeCap = 20;
  static const _followEvery = Duration(hours: 6);

  static Future<RemoteLibrary> _pull(TrackerId id, {bool watchlistOnly = false}) => switch (id) {
    TrackerId.trakt => TraktTracker.library(watchlistOnly: watchlistOnly),
    TrackerId.simkl => SimklTracker.library(),
    TrackerId.anilist => AniListTracker.library(),
  };

  /// Reads [id]'s lists and works out what's new to Lorewatch. Changes nothing.
  static Future<ImportPlan> plan(TrackerId id) async {
    final lib = await _pull(id);
    final everything = [...lib.watchlist, ...lib.history, ...lib.resume, ...lib.listed];
    await _resolveIds(everything);
    final saved = MyList.saved.value, seen = <String>{};
    final list = [
      for (final t in lib.watchlist)
        if (t.key case final k? when !saved.contains(k) && seen.add(k)) t,
    ]..sort((a, b) => b.at.compareTo(a.at));

    // the newest news per title: a later pause beats an earlier watch, and the other way round
    final latest = <String, RemoteTitle>{};
    for (final t in [...lib.history, ...lib.resume]) {
      final k = t.key;
      if (k == null || (t.progress != null && (t.progress! < 1 || t.progress! >= 95))) continue;
      final old = latest[k];
      if (old == null || t.at.isAfter(old.at)) latest[k] = t;
    }
    final here = {for (final e in WatchProgress.entries.value) e.media.key: e.updated};
    bool newer(RemoteTitle t) => here[t.key] == null || t.at.isAfter(here[t.key]!);
    final fresh = latest.values.where(newer).toList()..sort((a, b) => b.at.compareTo(a.at));
    return ImportPlan(
      id,
      list: list,
      history: fresh.where((t) => t.progress == null).take(historyCap).toList(),
      resume: fresh.where((t) => t.progress != null).take(resumeCap).toList(),
      baseline: {for (final t in lib.watchlist) ?t.key},
      found: {for (final t in everything) ?t.key}.length,
      cursor: lib.cursor,
    );
  }

  /// Brings in what [p] found: with [list], into My List (and follows the watchlist from now
  /// on); with [watched], into History and Continue watching. Returns how many came in.
  static Future<int> apply(ImportPlan p, {required bool list, required bool watched}) async {
    final media = await _media([if (list) ...p.list, if (watched) ...p.history, if (watched) ...p.resume]);
    var n = 0;
    if (list) {
      final add = [
        for (final t in p.list)
          if (media[t.key] case final m?) SavedTitle(m.media, t.at),
      ];
      MyList.addAll(add);
      n += add.length;
      await _follow(p.id, p.baseline, cursor: p.cursor);
    }
    if (watched) {
      final entries = <WatchEntry>[];
      for (final t in p.history) {
        final m = media[t.key];
        if (m == null) continue;
        final d = Duration(minutes: t.runtime ?? m.runtime ?? 45);
        final episode = (t.episode ?? 0) > 0 ? t.episode : null;
        // a long anime's every episode would weigh History down: keep just the latest then
        final eps = t.episodes.length > 300 ? <String>{} : {...t.episodes};
        if (t.season != null && episode != null) eps.add('S${t.season}E$episode');
        entries.add(
          WatchEntry(
            media: m.media,
            season: episode == null ? null : t.season,
            episode: episode,
            position: d,
            duration: d,
            updated: t.at,
            episodes: {for (final k in eps) k: 1.0},
          ),
        );
      }
      for (final t in p.resume) {
        final m = media[t.key];
        if (m == null) continue;
        final minutes = t.runtime ?? (t.kind == MediaKind.movie ? m.runtime : await _episodeRuntime(t));
        // without the real length the resume point would land in the wrong place: skip it
        if (minutes == null || minutes <= 0) continue;
        final d = Duration(minutes: minutes);
        entries.add(WatchEntry(media: m.media, season: t.season, episode: t.episode, position: d * (t.progress! / 100), duration: d, updated: t.at));
      }
      WatchProgress.merge(entries);
      n += entries.length;
    }
    return n;
  }

  // ── following the watchlist ──

  static String _k(TrackerId id, String what) => 'trackers.${id.name}.$what';

  static Future<void> _follow(TrackerId id, Set<String> watchlist, {String? cursor}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k(id, 'watchlist'), json.encode(watchlist.toList()));
    await p.setInt(_k(id, 'followed'), DateTime.now().millisecondsSinceEpoch);
    if (cursor != null) await p.setString(_k(id, 'cursor'), cursor);
  }

  /// Stops following [id]'s watchlist (when it's disconnected).
  static Future<void> forget(TrackerId id) async {
    final p = await SharedPreferences.getInstance();
    for (final what in const ['watchlist', 'followed', 'cursor']) {
      await p.remove(_k(id, what));
    }
  }

  /// At app start, at most every six hours a service: titles added to a watchlist you imported
  /// come into My List, and ones taken off it there leave, unless you've started them here.
  /// On Trakt and Simkl this needs "Sync My List" on.
  static Future<void> follow() async {
    final p = await SharedPreferences.getInstance();
    for (final id in TrackerId.values) {
      final raw = p.getString(_k(id, 'watchlist'));
      final last = DateTime.fromMillisecondsSinceEpoch(p.getInt(_k(id, 'followed')) ?? 0);
      if (raw == null || DateTime.now().difference(last) < _followEvery) continue;
      if (id == TrackerId.trakt && !AppSettings.traktList.value) continue;
      if (id == TrackerId.simkl && !AppSettings.simklList.value) continue;
      if (await TokenStore.read(id) == null) continue;
      try {
        await _followOne(id, (json.decode(raw) as List).cast<String>().toSet(), p.getString(_k(id, 'cursor')));
      } catch (_) {
        // offline, signed out or busy: next start tries again
      }
    }
  }

  static Future<void> _followOne(TrackerId id, Set<String> before, String? cursor) async {
    final List<RemoteTitle> added;
    final Set<String> after;
    var gone = <String>{};
    String? next;
    if (id == TrackerId.simkl) {
      if (cursor == null) return;
      final c = await SimklTracker.changes(cursor);
      await _resolveIds([...c.planned, ...c.moved]);
      next = c.cursor;
      added = [
        for (final t in c.planned)
          if (t.key case final k? when !before.contains(k)) t,
      ];
      // Simkl only says what changed, and a title that moved on to Watching stays in My List
      after = {
        ...before.difference({for (final t in c.moved) ?t.key}),
        for (final t in c.planned) ?t.key,
      };
    } else {
      final lib = await _pull(id, watchlistOnly: true);
      final complete = await _resolveIds([...lib.watchlist, ...lib.listed]);
      after = {for (final t in lib.watchlist) ?t.key};
      added = [
        for (final t in lib.watchlist)
          if (t.key case final k? when !before.contains(k)) t,
      ];
      // on AniList only a title off the list altogether was removed; one that
      // moved on to Watching stays
      final onList = id == TrackerId.trakt ? after : {for (final t in lib.listed) ?t.key};
      if (complete) gone = before.difference(onList);
    }
    if (added.isNotEmpty) {
      final media = await _media(added);
      MyList.addAll([
        for (final t in added)
          if (media[t.key] case final m?) SavedTitle(m.media, t.at),
      ]);
    }
    // a title started here stays (Trakt drops watched ones from the watchlist by itself), and a
    // watchlist that suddenly lost most of itself is more likely a hiccup than a clear-out
    final started = {for (final e in WatchProgress.entries.value) e.media.key};
    final drop = gone.difference(started);
    if (drop.isNotEmpty && !(drop.length > 10 && drop.length > before.length ~/ 2)) MyList.removeAll(drop);
    await _follow(id, after, cursor: next);
  }

  // ── matching titles ──

  /// Fills in the ids Lorewatch goes by: AniList ids for anime Simkl only knows by their
  /// MyAnimeList id, TMDB ids for titles that came with only an IMDb or TheTVDB one. False when
  /// a lookup failed.
  static Future<bool> _resolveIds(List<RemoteTitle> titles) async {
    var complete = true;
    final mal = [
      for (final t in titles)
        if (t.kind == MediaKind.anime && t.anilist == null) ?t.mal,
    ];
    if (mal.isNotEmpty) {
      final map = await AniList.idsForMal(mal);
      for (final t in titles) {
        if (t.anilist == null && t.mal != null) t.anilist = map[t.mal];
      }
    }
    final found = <String, int?>{};
    for (final t in titles) {
      if (t.kind == MediaKind.anime || t.tmdb != null) continue;
      final (id, source) = t.imdb != null ? (t.imdb!, 'imdb_id') : (t.tvdb != null ? ('${t.tvdb}', 'tvdb_id') : ('', ''));
      if (id.isEmpty) continue;
      final at = '$source/$id/${t.kind.name}';
      if (!found.containsKey(at)) {
        if (found.length >= 60) continue; // a few is normal; hundreds would take too long
        try {
          final j = await Tmdb.get('/find/$id', {'external_source': source});
          final hits = j[t.kind == MediaKind.movie ? 'movie_results' : 'tv_results'];
          found[at] = hits is List && hits.isNotEmpty && hits.first is Map ? asInt((hits.first as Map)['id']) : null;
        } catch (_) {
          found[at] = null;
          complete = false;
        }
      }
      t.tmdb = found[at];
    }
    return complete;
  }

  /// Each title as Lorewatch shows it (poster, overview…), with its length in minutes if known.
  static Future<Map<String, ({Media media, int? runtime})>> _media(List<RemoteTitle> titles) async {
    final out = <String, ({Media media, int? runtime})>{};
    final anime = {
      for (final t in titles)
        if (t.kind == MediaKind.anime) ?t.anilist,
    };
    if (anime.isNotEmpty) {
      for (final a in await AniList.byIds(anime.toList())) {
        out[a.media.key] = (media: a.media, runtime: a.duration);
      }
    }
    final keys = {
      for (final t in titles)
        if (t.kind != MediaKind.anime) ?t.key,
    }.toList();
    await _each(keys, (k) async {
      try {
        final tv = k.startsWith('tv/');
        final j = await Tmdb.get('/$k');
        final genres = [for (final g in ((j['genres'] as List?) ?? const []).whereType<Map>()) ?asInt(g['id'])];
        final runtime = tv ? asInt(((j['episode_run_time'] as List?) ?? const []).firstOrNull) : asInt(j['runtime']);
        out[k] = (media: Media.fromJson({...j, 'genre_ids': genres}, tv: tv), runtime: runtime);
      } catch (_) {
        // gone from TMDB, or a hiccup: that one's left out
      }
    });
    return out;
  }

  static Future<int?> _episodeRuntime(RemoteTitle t) async {
    if (t.tmdb == null || t.season == null || t.episode == null) return null;
    try {
      return asInt((await Tmdb.get('/tv/${t.tmdb}/season/${t.season}/episode/${t.episode}'))['runtime']);
    } catch (_) {
      return null;
    }
  }

  /// Runs [run] over [items], four at a time.
  static Future<void> _each<T>(List<T> items, Future<void> Function(T) run) async {
    var next = 0;
    Future<void> lane() async {
      while (next < items.length) {
        await run(items[next++]);
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) lane()]);
  }
}
