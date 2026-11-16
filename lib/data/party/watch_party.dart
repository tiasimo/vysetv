import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account.dart';
import '../addons.dart';
import '../app_settings.dart';
import '../film_sources/source_settings.dart';
import '../tmdb.dart' show Media;
import 'rooms.dart';

Map<String, dynamic> _mediaJson(Media m) => {
  'id': m.id,
  'title': m.title,
  'tv': m.isTv,
  'overview': m.overview,
  'poster_path': m.posterPath,
  'backdrop_path': m.backdropPath,
  'vote_average': m.rating,
  'genre_ids': m.genreIds,
  'date': m.date.isNotEmpty ? m.date : (m.year ?? ''),
  if (m.anime) 'anime': true,
};

Media _mediaFrom(Map<String, dynamic> m) {
  final tv = m['tv'] == true;
  final date = (m['date'] ?? '') as String;
  return Media.fromJson({...m, tv ? 'first_air_date' : 'release_date': date}, tv: tv);
}

/// A song as the room sees it.
@immutable
class PartySong {
  const PartySong({required this.id, required this.title, this.artist = '', this.album = '', this.cover = '', this.seconds = 0});
  final String id;
  final String title;
  final String artist;
  final String album;
  final String cover;
  final int seconds;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'album': album, 'cover': cover, 'seconds': seconds};

  static PartySong? fromJson(Object? j) => j is Map<String, dynamic>
      ? PartySong(
          id: '${j['id'] ?? ''}',
          title: j['title'] as String? ?? '',
          artist: j['artist'] as String? ?? '',
          album: j['album'] as String? ?? '',
          cover: j['cover'] as String? ?? '',
          seconds: (j['seconds'] as num?)?.toInt() ?? 0,
        )
      : null;
}

/// What the host of a watch party is doing: the title, where they are, and the settings
/// everyone follows (speed, subtitle file and its timing).
class WatchState {
  WatchState({
    required this.media,
    this.season,
    this.episode,
    this.episodeName,
    this.position = 0,
    this.playing = false,
    this.rate = 1,
    this.subtitle,
    this.subDelay = 0,
    this.by = '',
    this.seq = 0,
    this.song,
    this.track,
    this.upNext = const [],
    this.live,
    this.source,
    this.sources,
    this.server,
    this.link,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final Media media;
  final int? season;
  final int? episode;
  final String? episodeName;
  final double position; // seconds, at [at]
  final bool playing;
  final double rate;
  final Map<String, dynamic>? subtitle; // the exact file: provider, id, url, lang, language, format…
  final double subDelay; // seconds
  final String by; // who sent it
  final int seq;
  final DateTime at; // when [position] was true, on this device's clock

  // Listening together: the song, the full track for each player to open, and what's next.
  final PartySong? song;
  final Map<String, dynamic>? track;
  final List<PartySong> upNext;

  bool get isMusic => song != null;

  /// Live TV: where the relay serves it, for everyone but the host.
  final Map<String, dynamic>? live;

  bool get isLive => live != null;

  /// The host picked a source from their addons (streaming mode off): that exact link, or
  /// torrent, plays for everyone. Null: each device finds its own copy on Lorewatch's servers.
  final Map<String, dynamic>? source;

  /// The host's film and TV sources, in their order: everyone looks in that order.
  final List<String>? sources;

  /// The Movy server or source the host is playing ([FilmLink.partyKey]): tried first.
  final String? server;

  /// The link the host is streaming, for guests to play too: url, headers, hls, qualities.
  /// `{'own': true}` when theirs only plays on their machine (our torrent engine, their media
  /// server): guests find their own. Null while it's still loading.
  final Map<String, dynamic>? link;

  /// Where the host is right now.
  double get now => position + (playing ? DateTime.now().difference(at).inMilliseconds / 1000 * rate : 0);

  bool get mine => by == Account.user.value?.id;

  /// Same film, or same episode of the same show.
  bool sameTitle(WatchState? o) => o != null && o.media.key == media.key && o.season == season && o.episode == episode;

  Map<String, dynamic> toJson() => {
    'media': {..._mediaJson(media), if (song != null) 'music': true, if (live != null) 'live': true},
    'season': ?season,
    'episode': ?episode,
    'episodeName': ?episodeName,
    'position': position,
    'playing': playing,
    'rate': rate,
    'subtitle': subtitle,
    'subDelay': subDelay,
    'song': ?song?.toJson(),
    'track': ?track,
    'live': ?live,
    'source': ?source,
    'sources': ?sources,
    'server': ?server,
    'link': ?link,
    if (upNext.isNotEmpty) 'upNext': [for (final s in upNext) s.toJson()],
  };

  static WatchState? fromJson(Map<String, dynamic> j, {DateTime? at}) {
    final m = j['media'];
    if (m is! Map<String, dynamic>) return null;
    return WatchState(
      media: _mediaFrom(m),
      season: (j['season'] as num?)?.toInt(),
      episode: (j['episode'] as num?)?.toInt(),
      episodeName: j['episodeName'] as String?,
      position: (j['position'] as num?)?.toDouble() ?? 0,
      playing: j['playing'] == true,
      rate: (j['rate'] as num?)?.toDouble() ?? 1,
      subtitle: j['subtitle'] is Map<String, dynamic> ? j['subtitle'] as Map<String, dynamic> : null,
      subDelay: (j['subDelay'] as num?)?.toDouble() ?? 0,
      by: j['by'] as String? ?? '',
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      song: PartySong.fromJson(j['song']),
      track: j['track'] is Map<String, dynamic> ? j['track'] as Map<String, dynamic> : null,
      live: j['live'] is Map<String, dynamic> ? j['live'] as Map<String, dynamic> : null,
      source: j['source'] is Map<String, dynamic> ? j['source'] as Map<String, dynamic> : null,
      sources: j['sources'] is List ? [for (final x in j['sources'] as List) if (x is String) x] : null,
      server: j['server'] as String?,
      link: j['link'] is Map ? (j['link'] as Map).cast<String, dynamic>() : null,
      upNext: [
        if (j['upNext'] is List)
          for (final x in j['upNext'] as List) ?PartySong.fromJson(x),
      ],
      at: at,
    );
  }
}

/// Play, pause or seek from a member the owner gave playback control.
class WatchCommand {
  const WatchCommand(this.action, this.position, this.by, this.byName);
  final String action; // play, pause, seek
  final double? position; // seconds, for seek
  final String by;
  final String byName;
}

/// Someone in the room whose player is still loading or buffering.
class WatchWaiter {
  const WatchWaiter(this.id, this.name, this.since);
  final String id;
  final String name;
  final DateTime since; // on this device's clock
}

/// Watching together in your room. The host (the room's owner, or anyone when the owner allows
/// it) reports what their player does; everyone else's player follows: timeline, play/pause,
/// speed, and the same subtitle file with the same timing. Like Jellyfin's SyncPlay, the room
/// waits for anyone still loading instead of making them chase the host.
class WatchParty {
  /// The watch going on in your room, or null.
  static final state = ValueNotifier<WatchState?>(null);

  /// Others in the room whose player is loading or buffering.
  static final waiting = ValueNotifier<List<WatchWaiter>>(const []);
  static final _skipUntil = <String, DateTime>{};
  static bool? _sentWait;

  /// Party players open right now (so a "join the watch" nudge isn't shown inside one).
  static int playerOpen = 0;

  static final _unsubs = <UnsubscribeFunc>[];
  static String? _uid;
  static String? _room;

  /// You host it: the room's owner starts, steers and stops it, and everyone follows their player.
  static bool get canControl => Rooms.mine.value?.iOwn == true;

  /// You may play, pause and seek for everyone: the host, or a member the owner allowed.
  static bool get canCommand {
    final r = Rooms.mine.value;
    return r != null && (r.iOwn || r.everyoneControls || r.members.any((m) => m.isMe && m.controls));
  }

  /// Play, pause and seek from members with control, for the host's player to carry out.
  static Stream<WatchCommand> get commands => _commands.stream;
  static final _commands = StreamController<WatchCommand>.broadcast();

  /// A member with control plays, pauses or seeks (to [position] seconds) for the room.
  static Future<void> command(String action, {double? position}) =>
      Account.pb.send('/api/vyse/rooms/watch/command', method: 'POST', body: {'action': action, 'position': ?position});

  static String get me => Account.user.value?.id ?? '';

  // ── a source picked from the host's addons ──

  /// [p] as it travels in the watch state (the addon's name only, never its link, which can
  /// hold the host's keys).
  static Map<String, dynamic> sourceJson(AddonPick p) {
    final s = p.stream, t = p.target;
    String cut(String x) => x.length > 600 ? x.substring(0, 600) : x;
    return {
      'addon': {'id': s.addon.id, 'name': s.addon.name},
      'url': s.url,
      'infoHash': ?s.infoHash,
      'fileIdx': ?s.fileIdx,
      if (s.trackers.isNotEmpty) 'trackers': s.trackers.take(20).toList(),
      'text': cut(s.text),
      'name': s.name,
      'description': cut(s.description),
      'filename': ?s.filename,
      'bingeGroup': ?s.bingeGroup,
      if (s.headers.isNotEmpty) 'headers': s.headers,
      'size': ?s.sizeBytes,
      't': {'type': t.type, 'imdb': ?t.imdb, 'tmdb': ?t.tmdb, 'kitsu': ?t.kitsu, 'season': ?t.season, 'episode': ?t.episode, 'anime': t.anime},
    };
  }

  /// The source [s] shares, when it's for the episode [s] is on (null while the host's player
  /// is still finding the next episode's, or when there's none).
  static AddonPick? sourcePick(WatchState? s) {
    final j = s?.source;
    if (j == null) return null;
    try {
      final t = j['t'] as Map<String, dynamic>;
      final target = AddonTarget(
        type: t['type'] as String,
        imdb: t['imdb'] as String?,
        tmdb: (t['tmdb'] as num?)?.toInt(),
        kitsu: (t['kitsu'] as num?)?.toInt(),
        season: (t['season'] as num?)?.toInt(),
        episode: (t['episode'] as num?)?.toInt(),
        anime: t['anime'] == true,
      );
      if (s!.episode != null && (target.episode != s.episode || (!target.anime && target.season != s.season))) return null;
      final a = j['addon'] as Map<String, dynamic>;
      final id = '${a['id'] ?? ''}', name = '${a['name'] ?? 'Addon'}';
      final addon = Addons.list.value.where((x) => x.id == id).firstOrNull ?? Addon(manifestUrl: '', id: id, name: name);
      final hash = j['infoHash'] as String?;
      return AddonPick(
        AddonStream(
          addon: addon,
          url: '${j['url'] ?? ''}',
          text: '${j['text'] ?? ''}',
          name: '${j['name'] ?? ''}',
          description: '${j['description'] ?? ''}',
          filename: j['filename'] as String?,
          bingeGroup: j['bingeGroup'] as String?,
          headers: {for (final e in ((j['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
          sizeBytes: (j['size'] as num?)?.toInt(),
          infoHash: hash,
          fileIdx: hash == null ? null : (j['fileIdx'] as num?)?.toInt(),
          trackers: [for (final x in (j['trackers'] as List?) ?? const []) '$x'],
        ),
        target,
      );
    } catch (_) {
      return null;
    }
  }

  // ── P2P together: everyone in the room allows it before a torrent plays for them ──

  /// The host asks the room; whoever has P2P streaming off is asked on their screen (the name
  /// of who asks).
  static Stream<String> get p2pAsks => _p2pAsks.stream;
  static final _p2pAsks = StreamController<String>.broadcast();

  /// The answers to the last ask: user id → allowed.
  static final p2pReplies = ValueNotifier<Map<String, bool>>(const {});

  static Future<void> askP2p() {
    p2pReplies.value = const {};
    return Account.pb.send('/api/vyse/rooms/watch/p2p', method: 'POST', body: {'ask': true});
  }

  static Future<void> replyP2p(bool on) =>
      Account.pb.send('/api/vyse/rooms/watch/p2p', method: 'POST', body: {'on': on}).catchError((Object _) => null);

  static void start() {
    Account.user.addListener(_userChanged);
    Rooms.mine.addListener(_roomChanged);
    _userChanged();
  }

  static void _userChanged() {
    final u = Account.user.value;
    final id = u != null && u.termsAt != null ? u.id : null;
    if (id == _uid) return;
    _uid = id;
    for (final u in _unsubs) {
      u().catchError((Object _) {});
    }
    _unsubs.clear();
    state.value = null;
    _clearWaiting();
    if (id == null) return;
    Account.pb.realtime.subscribe('vyse_watch', (e) => _incoming(e.data)).then(_unsubs.add, onError: (Object _) {});
  }

  static void _roomChanged() {
    final id = Rooms.mine.value?.id;
    if (id == _room) return;
    _room = id;
    state.value = null;
    _clearWaiting();
    if (id != null) unawaited(refresh());
  }

  static void _clearWaiting() {
    waiting.value = const [];
    _skipUntil.clear();
    _sentWait = null;
  }

  /// A follower's player tells the room it's loading (or ready again). Only changes are sent.
  static void wait(bool loading) {
    if (_sentWait == loading || _room == null) return;
    _sentWait = loading;
    unawaited(Account.pb.send('/api/vyse/rooms/watch/wait', method: 'POST', body: {'waiting': loading}).catchError((Object _) {
      _sentWait = null; // try again on the next check
    }));
  }

  /// Who the room is waiting for right now. A player still loading after 20 s is left to catch
  /// up on its own (and not waited for again for a minute), so one bad connection can't hold up
  /// everyone.
  static List<String> blocking() {
    final now = DateTime.now();
    final out = <String>[];
    for (final w in waiting.value) {
      final skip = _skipUntil[w.id];
      if (skip != null && now.isBefore(skip)) continue;
      if (now.difference(w.since) > const Duration(seconds: 20)) {
        _skipUntil[w.id] = now.add(const Duration(minutes: 1));
        continue;
      }
      out.add(w.name);
    }
    return out;
  }

  /// The host plays anyway: stop waiting for whoever is loading now.
  static void skipWaiting() {
    final until = DateTime.now().add(const Duration(minutes: 1));
    for (final w in waiting.value) {
      _skipUntil[w.id] = until;
    }
  }

  /// Catches up with the watch in your room (after joining it, or the app starting).
  static Future<void> refresh() async {
    if (_room == null) return;
    try {
      final j = await Account.pb.send('/api/vyse/rooms/watch') as Map<String, dynamic>;
      final s = j['state'];
      if (s is! Map<String, dynamic>) {
        state.value = null;
        return;
      }
      // how long ago the host's position was true, by the server's clock
      final age = ((j['serverNow'] as num?)?.toInt() ?? 0) - ((s['serverAt'] as num?)?.toInt() ?? 0);
      state.value = WatchState.fromJson(s, at: DateTime.now().subtract(Duration(milliseconds: age.clamp(0, 600000))));
    } catch (_) {}
  }

  static void _incoming(String data) {
    try {
      final j = jsonDecode(data) as Map<String, dynamic>;
      if (j['room'] != _room) return;
      if (j['p2pAsk'] == true) {
        if (j['by'] == me) return;
        // already on: say so without asking
        if (AppSettings.p2pStreaming.value) {
          unawaited(replyP2p(true));
        } else {
          _p2pAsks.add('${j['byName'] ?? 'The host'}');
        }
        return;
      }
      if (j['p2pReply'] is bool) {
        p2pReplies.value = {...p2pReplies.value, '${j['by']}': j['p2pReply'] as bool};
        return;
      }
      final action = j['command'];
      if (action is String) {
        _commands.add(WatchCommand(action, (j['position'] as num?)?.toDouble(), '${j['by'] ?? ''}', '${j['byName'] ?? 'Someone'}'));
        return;
      }
      final list = j['waiting'];
      if (list is List) {
        final me = Account.user.value?.id, now = DateTime.now(), had = {for (final w in waiting.value) w.id: w};
        waiting.value = [
          for (final w in list.cast<Map<String, dynamic>>())
            if (w['id'] != me)
              had[w['id']] ??
                  WatchWaiter('${w['id']}', '${w['name'] ?? 'Someone'}', now.subtract(Duration(milliseconds: (w['for'] as num?)?.toInt() ?? 0))),
        ];
        return;
      }
      if (j['stopped'] == true) {
        state.value = null;
        waiting.value = const [];
        return;
      }
      final s = WatchState.fromJson(j);
      if (s == null) return;
      final cur = state.value;
      if (s.mine && cur != null && cur.mine) return; // our own echo
      if (cur != null && s.seq != 0 && s.seq <= cur.seq && !cur.mine) return; // out of order
      state.value = s;
    } catch (_) {}
  }

  /// The host's player reports a change (or its heartbeat).
  static Future<void> report(WatchState s) async {
    state.value = s;
    try {
      await Account.pb.send('/api/vyse/rooms/watch', method: 'POST', body: {'state': s.toJson()});
    } catch (_) {}
  }

  /// Starts watching [media] (an episode for shows) with the room. Throws when you can't.
  /// [position]: where to start, in seconds (carrying on from Continue watching).
  static Future<void> host(Media media, {int? season, int? episode, String? episodeName, double position = 0}) async {
    final s = WatchState(
      media: media,
      season: season,
      episode: episode,
      episodeName: episodeName,
      position: position,
      playing: true,
      by: Account.user.value?.id ?? '',
      sources: [for (final s in activeFilmSources()) s.id],
    );
    state.value = s;
    await Account.pb.send('/api/vyse/rooms/watch', method: 'POST', body: {'state': s.toJson()});
  }

  /// Starts [s] for the room. Throws when you can't.
  static Future<void> hostState(WatchState s) async {
    state.value = s;
    await Account.pb.send('/api/vyse/rooms/watch', method: 'POST', body: {'state': s.toJson()});
  }

  static Future<void> stop() async {
    state.value = null;
    try {
      await Account.pb.send('/api/vyse/rooms/watch', method: 'POST', body: {'state': null});
    } catch (_) {}
  }
}
