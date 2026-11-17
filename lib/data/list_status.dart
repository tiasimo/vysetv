import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tmdb.dart';
import 'trackers/anilist_tracker.dart';
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

  /// Moves [titles] to [status] in My List (adding them when they aren't there) and, for anime
  /// while AniList is connected, on AniList too.
  static Future<void> set(Iterable<Media> titles, WatchStatus status) async {
    final list = titles.toList();
    MyList.setStatuses({for (final m in list) m.key: status}, add: list);
    final anime = list.where((m) => m.anime).toList();
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
