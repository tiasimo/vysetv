import 'dart:async';

import 'package:flutter/foundation.dart';

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
