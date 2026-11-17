import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb.dart';

/// Where the viewer is (or was) in a film or a show. One per title; the newest first.
class WatchEntry {
  const WatchEntry({
    required this.media,
    required this.position,
    required this.duration,
    required this.updated,
    this.season,
    this.episode,
    this.episodeName,
    this.hidden = false,
    this.episodes = const {},
    this.subtitle,
    this.subDelay = 0,
  });

  final Media media;
  final int? season;
  final int? episode;
  final String? episodeName;
  final Duration position;
  final Duration duration;
  final DateTime updated;

  /// Taken off the Continue watching row by hand (still in History).
  final bool hidden;

  /// Shows: furthest point reached in each episode watched, keyed "S1E2", 0..1.
  final Map<String, double> episodes;

  /// The subtitle that was on for this film or episode (the file: provider, id, url, language…),
  /// or {'off': true} when they were turned off; null when nothing was chosen. Picked up again
  /// when you carry on watching, ahead of the default in Settings.
  final Map<String, dynamic>? subtitle;

  /// Its timing nudge, in seconds.
  final double subDelay;

  double get fraction => duration.inMilliseconds <= 0 ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  Duration get left => duration - position;
  bool get finished => fraction >= WatchProgress.finishedAt;
  bool get inContinue => !finished && !hidden;
  int get episodesFinished => episodes.values.where((f) => f >= WatchProgress.finishedAt).length;

  WatchEntry copyWith({bool? hidden}) => WatchEntry(
    media: media,
    position: position,
    duration: duration,
    updated: updated,
    season: season,
    episode: episode,
    episodeName: episodeName,
    hidden: hidden ?? this.hidden,
    episodes: episodes,
    subtitle: subtitle,
    subDelay: subDelay,
  );

  Map<String, dynamic> toJson() => {
    'media': {
      'id': media.id,
      'title': media.title,
      'tv': media.isTv,
      'overview': media.overview,
      'poster_path': media.posterPath,
      'backdrop_path': media.backdropPath,
      'vote_average': media.rating,
      'genre_ids': media.genreIds,
      'date': media.date.isNotEmpty ? media.date : (media.year ?? ''),
      if (media.anime) 'anime': true,
    },
    if (season != null) 's': season,
    if (episode != null) 'e': episode,
    if (episodeName != null) 'n': episodeName,
    'p': position.inMilliseconds,
    'd': duration.inMilliseconds,
    'u': updated.millisecondsSinceEpoch,
    if (hidden) 'h': true,
    if (episodes.isNotEmpty) 'x': episodes,
    'sub': ?subtitle,
    if (subDelay != 0) 'sd': subDelay,
  };

  static WatchEntry fromJson(Map<String, dynamic> j) {
    final m = j['media'] as Map<String, dynamic>;
    final tv = m['tv'] as bool;
    final date = (m['date'] ?? '') as String;
    return WatchEntry(
      media: Media.fromJson({...m, tv ? 'first_air_date' : 'release_date': date}, tv: tv),
      season: j['s'] as int?,
      episode: j['e'] as int?,
      episodeName: j['n'] as String?,
      position: Duration(milliseconds: j['p'] as int),
      duration: Duration(milliseconds: j['d'] as int),
      updated: DateTime.fromMillisecondsSinceEpoch(j['u'] as int),
      hidden: j['h'] == true,
      episodes: {for (final e in ((j['x'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toDouble()},
      subtitle: j['sub'] is Map ? Map<String, dynamic>.from(j['sub'] as Map) : null,
      subDelay: (j['sd'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Watch history, kept on this device. The Continue watching row is the unfinished part of it;
/// History shows all of it.
class WatchProgress {
  static final entries = ValueNotifier<List<WatchEntry>>(const []);
  static const _key = 'watch.progress';
  static const _max = 3000; // Lorewatch: room for a whole AniList / Refract history

  /// At or past this, a title counts as finished: it leaves Continue watching, stays in History.
  static const finishedAt = .95;
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final p = _prefs = await SharedPreferences.getInstance();
    try {
      final raw = p.getString(_key);
      if (raw == null) return;
      entries.value = [for (final e in (json.decode(raw) as List).cast<Map<String, dynamic>>()) ?_tryParse(e)];
    } catch (_) {}
  }

  static WatchEntry? _tryParse(Map<String, dynamic> j) {
    try {
      return WatchEntry.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static bool _same(Media a, Media b) => a.key == b.key;

  static WatchEntry? find(Media m) => entries.value.where((e) => _same(e.media, m)).firstOrNull;

  /// What the Continue watching row shows.
  static List<WatchEntry> get continueWatching => entries.value.where((e) => e.inContinue).toList();

  /// Seconds into [media] (that episode, for shows) where you left it, or 0 when you didn't or
  /// finished it: where a watch party you start carries on from.
  static double resumeSeconds(Media media, {int? season, int? episode}) {
    final s = find(media);
    if (s == null || s.season != season || s.episode != episode || s.fraction >= finishedAt) return 0;
    return s.position.inMilliseconds / 1000;
  }

  /// Records where playback is. Anything actually started counts.
  static void record(
    Media media, {
    required Duration position,
    required Duration duration,
    int? season,
    int? episode,
    String? episodeName,
    Map<String, dynamic>? subtitle,
    double subDelay = 0,
  }) {
    if (duration < const Duration(minutes: 1) || position < const Duration(seconds: 3)) return;
    final old = find(media);
    final f = (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final episodes = {...?old?.episodes};
    if (season != null && episode != null) {
      final k = 'S${season}E$episode';
      if (f > (episodes[k] ?? 0)) episodes[k] = f;
    }
    _set([
      WatchEntry(
        media: media,
        season: season,
        episode: episode,
        episodeName: episodeName,
        position: position,
        duration: duration,
        updated: DateTime.now(),
        episodes: episodes,
        subtitle: subtitle,
        subDelay: subDelay,
      ),
      ...entries.value.where((e) => !_same(e.media, media)),
    ].take(_max).toList());
  }

  /// Off the Continue watching row only.
  static void dismiss(Media media) =>
      _set([for (final e in entries.value) _same(e.media, media) ? e.copyWith(hidden: true) : e]);

  /// Out of History altogether.
  static void remove(Media media) => _set(entries.value.where((e) => !_same(e.media, media)).toList());

  static void clear() => _set(const []);

  /// Titles brought in from another service (Trakt, Simkl, AniList). One only
  /// replaces what's here when it's newer, and keeps the episodes already watched here. The
  /// oldest fall off the end first, so an import never pushes out recent watching.
  static void merge(List<WatchEntry> incoming) {
    final byKey = {for (final e in entries.value) e.media.key: e};
    for (final w in incoming) {
      final old = byKey[w.media.key];
      if (old != null && !w.updated.isAfter(old.updated)) continue;
      final episodes = {...?old?.episodes};
      w.episodes.forEach((k, f) {
        if (f > (episodes[k] ?? 0)) episodes[k] = f;
      });
      byKey[w.media.key] = WatchEntry(
        media: w.media,
        season: w.season,
        episode: w.episode,
        episodeName: w.episodeName,
        position: w.position,
        duration: w.duration,
        updated: w.updated,
        episodes: episodes,
        // an import knows nothing of subtitles: keep this device's for the same episode
        subtitle: w.subtitle ?? (old != null && old.season == w.season && old.episode == w.episode ? old.subtitle : null),
        subDelay: w.subtitle != null ? w.subDelay : (old != null && old.season == w.season && old.episode == w.episode ? old.subDelay : 0),
      );
    }
    final list = byKey.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));
    _set(list.take(_max).toList());
  }

  // ── account sync ──

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async => {for (final e in entries.value) e.media.key: e.toJson()};

  static Future<void> syncApply(String key, Map<String, dynamic>? data) async {
    final list = entries.value.where((e) => e.media.key != key).toList();
    final w = data == null ? null : _tryParse(data);
    if (w != null) {
      list.add(w);
      list.sort((a, b) => b.updated.compareTo(a.updated));
    }
    _set(list.take(_max).toList());
  }

  static Future<void> syncApplyAll(Map<String, Map<String, dynamic>?> changes) async {
    final list = entries.value.where((e) => !changes.containsKey(e.media.key)).toList();
    for (final d in changes.values) {
      final w = d == null ? null : _tryParse(d);
      if (w != null) list.add(w);
    }
    list.sort((a, b) => b.updated.compareTo(a.updated));
    _set(list.take(_max).toList());
  }

  static void _set(List<WatchEntry> list) {
    entries.value = list;
    _prefs?.setString(_key, json.encode([for (final e in list) e.toJson()]));
  }
}
