// Playing a title from your own server in Lorewatch's player.
//
// The player gets a stand-in Media (not a TMDB title) and a ServerPlayback that hands it the
// stream, the server's subtitles and skip markers, and the show's seasons and episodes. Progress
// goes back to the server, never into Lorewatch's own history, so Plex / Jellyfin / Emby stay
// in charge of what you've watched.

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../data/intro_db.dart' show Segment, SegmentKind;
import '../data/outside_play.dart';
import '../data/sources.dart' show StreamSource;
import '../data/subtitles.dart' as sub;
import '../data/tmdb.dart' show Media, Season;
import '../plezy/media/media_item.dart';
import '../plezy/media/media_kind.dart';
import '../plezy/media/media_server_client.dart';
import '../plezy/services/playback_initialization_types.dart';
import '../screens/player_episodes.dart' show EpisodeInfo, EpisodeStore;
import '../screens/player_page.dart' show PlayerEpisode;
import 'media_servers.dart';
import 'watched_rule.dart';

export '../data/outside_play.dart' show ServerStream;

class ServerPlayback implements OutsidePlayback {
  ServerPlayback._(this.server, this.client, this.media, this.episode, this._movie, this.episodes, this._fromStart);

  /// Goes up by one each time a player playing from a server has closed and the server has been
  /// told where you stopped. The Servers pages listen, to show your new place and what you've
  /// now watched.
  static final ended = ValueNotifier<int>(0);

  final MediaServer server;
  final MediaServerClient client;

  /// The title as the player shows it (a stand-in, not a TMDB title).
  @override
  final Media media;

  /// The episode to start on (shows).
  @override
  final PlayerEpisode? episode;
  final MediaItem? _movie;

  /// The show's seasons and episodes, for the player's episode list and Up next.
  @override
  final ServerEpisodeStore? episodes;
  bool _fromStart;

  /// "Plex · Living room", for the player's sources list.
  @override
  String get label => '${server.product} · ${server.name}';

  @override
  String get note => 'Straight from your server';

  /// The show's or film's clear logo, when the server has one.
  @override
  String? get logo => _logo;
  String? _logo;

  /// Gets [item] ready to play: a film or an episode as it is, a show from where you are
  /// (the next episode to watch), a season from its first unwatched episode.
  static Future<ServerPlayback> prepare(MediaServer server, MediaItem item, {bool fromStart = false}) async {
    final client = await MediaServers.instance.client(server);
    var target = item;
    if (item.kind == MediaKind.show) {
      final onDeck = await client.fetchItemWithOnDeck(item.id).catchError((Object _) => (item: null, onDeckEpisode: null));
      target = onDeck.onDeckEpisode ?? await _firstEpisode(client, item.id) ?? item;
    } else if (item.kind == MediaKind.season) {
      final eps = await client.fetchChildren(item.id);
      target = eps.where((e) => !e.isWatched).firstOrNull ?? eps.firstOrNull ?? item;
    }
    if (target.kind != MediaKind.movie && target.kind != MediaKind.episode && target.kind != MediaKind.clip) {
      throw StateError('Nothing to play here yet');
    }
    final isEp = target.kind == MediaKind.episode;
    String? img(String? path, {int w = 780}) => path == null || path.isEmpty ? null : client.thumbnailUrl(path, width: w);
    final title = isEp ? (target.grandparentTitle ?? target.title ?? '') : (target.title ?? '');
    final media = Media(
      id: target.globalKey.hashCode & 0x3fffffff,
      title: title,
      isTv: isEp,
      overview: target.summary ?? '',
      posterPath: img(isEp ? (target.grandparentThumbPath ?? target.thumbPath) : target.thumbPath, w: 400),
      backdropPath: img(isEp ? (target.grandparentArtPath ?? target.artPath) : target.artPath, w: 1280),
      year: target.year?.toString(),
    );
    final ep = isEp ? _toPlayer(target, 0) : null;
    final showId = isEp ? target.grandparentId : null;
    final playback = ServerPlayback._(
      server,
      client,
      media,
      ep,
      isEp ? null : target,
      showId == null ? null : ServerEpisodeStore(client, showId, media),
      fromStart,
    );
    playback.episodes?._known[(ep!.season, ep.number)] = target;
    playback._logo = img(isEp ? null : target.clearLogoPath, w: 800);
    if (isEp) {
      unawaited(client.fetchItem(showId!).then((show) {
        playback._logo = img(show?.clearLogoPath, w: 800);
      }, onError: (Object _) {}));
    }
    return playback;
  }

  static Future<MediaItem?> _firstEpisode(MediaServerClient client, String showId) async {
    final seasons = await client.fetchChildren(showId);
    final real = seasons.where((s) => (s.index ?? 0) > 0).toList();
    final season = (real.isNotEmpty ? real : seasons).firstOrNull;
    if (season == null) return null;
    final eps = await client.fetchChildren(season.id);
    return eps.firstOrNull;
  }

  static PlayerEpisode _toPlayer(MediaItem e, int fallback) => PlayerEpisode(
    season: e.parentIndex ?? 1,
    number: e.index ?? fallback,
    name: e.title,
    runtime: e.durationMs == null ? null : (e.durationMs! / 60000).round(),
  );

  // ── the item playing, for progress reports ──

  MediaItem? _item;
  PlaybackInitializationResult? _result;
  bool _reportedStart = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  /// What the server has been shown of the title that's open: decides who marks it watched.
  late WatchedRule _rule = WatchedRule(client.watchedThreshold);

  /// Opens [ep] (null for a film): its stream, where you left off, its subtitles and markers.
  @override
  Future<ServerStream> open(PlayerEpisode? ep) async {
    stopped();
    final MediaItem? base = ep == null || episodes == null ? _movie : await episodes!.item(ep);
    if (base == null) throw StateError("This episode isn't on the server");
    final item = await client.fetchItem(base.id).catchError((Object _) => null) ?? base;
    final result = await client.getPlaybackInitialization(PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0));
    final url = result.videoUrl;
    if (url == null || url.isEmpty) throw StateError("The server didn't give a way to play this");
    _item = item;
    _result = result;
    _reportedStart = false;
    _pos = _dur = Duration.zero;
    _rule = WatchedRule(client.watchedThreshold);

    final headers = client.streamHeaders;
    final resume = _fromStart || !item.hasActiveProgress ? null : Duration(milliseconds: item.viewOffsetMs!);
    _fromStart = false; // the next episodes pick up where you left them

    final subs = <sub.SubtitleTrack>[
      for (final s in result.subtitleSidecars)
        if (s.track.uri != null)
          sub.subtitleTrack(
            'server-${s.track.id}',
            server.product,
            s.track.language ?? 'und',
            _withToken(s.track.uri!, headers),
            release: s.track.title ?? '',
            format: switch (s.track.codec?.toLowerCase()) {
              'ass' || 'ssa' => 'ass',
              'vtt' || 'webvtt' => 'vtt',
              _ => 'srt',
            },
          ),
    ];

    final segments = client.fetchPlaybackExtras(item.id).then(
      (x) => [
        for (final m in x.markers)
          if (_kind(m.type) case final kind?) Segment(kind, m.startTime, m.endTime <= m.startTime ? null : m.endTime),
      ],
      onError: (Object _) => const <Segment>[],
    );

    final v = result.selectedVersion;
    return ServerStream(
      source: StreamSource(
        url: url,
        server: label,
        quality: _quality(v?.videoResolution),
        referrer: '',
        userAgent: '',
        headers: headers,
        hls: false,
      ),
      resumeAt: resume,
      subtitles: subs,
      segments: segments,
    );
  }

  static SegmentKind? _kind(String type) => switch (type.toLowerCase()) {
    'intro' => SegmentKind.intro,
    'credits' || 'outro' => SegmentKind.credits,
    'recap' => SegmentKind.recap,
    'preview' => SegmentKind.preview,
    _ => null,
  };

  static String _quality(String? res) => switch (res?.toLowerCase()) {
    null || '' => '',
    '4k' || '2160' || '2160p' => '4K',
    final r when r.endsWith('p') || r == 'sd' => r.toUpperCase() == 'SD' ? 'SD' : r,
    final r => '${r}p',
  };

  /// Plex sidecar subtitles need the token on the link (Lorewatch fetches them without headers).
  static String _withToken(String url, Map<String, String> headers) {
    final token = headers['X-Plex-Token'];
    if (token == null || url.contains('X-Plex-Token')) return url;
    return '$url${url.contains('?') ? '&' : '?'}X-Plex-Token=${Uri.encodeQueryComponent(token)}';
  }

  /// Where you are, every few seconds and on pause: the server keeps your place.
  @override
  void progress(Duration position, Duration duration, {required bool paused}) {
    final item = _item, r = _result;
    if (item == null || r == null || duration <= Duration.zero) return;
    _pos = position;
    _dur = duration;
    final rule = _rule; // an answer that comes late still counts for this title, not the next
    void delivered(void _) => rule.delivered(position, duration);
    if (!_reportedStart) {
      _reportedStart = true;
      unawaited(client
          .reportPlaybackStarted(
            itemId: item.id,
            position: position,
            duration: duration,
            playSessionId: r.playSessionId,
            playMethod: r.playMethod,
            mediaSourceId: r.selectedMediaSourceId,
          )
          .then(delivered, onError: (Object _) {}));
      return;
    }
    unawaited(client
        .reportPlaybackProgress(
          itemId: item.id,
          position: position,
          duration: duration,
          isPaused: paused,
          playSessionId: r.playSessionId,
          playMethod: r.playMethod,
          mediaSourceId: r.selectedMediaSourceId,
        )
        .then(delivered, onError: (Object _) {}));
  }

  /// What the last [stopped] is still telling the server.
  Future<void> _ending = Future.value();

  /// The episode or film is over here (the player moved on, or is closing): the server is told
  /// where you stopped, and that you watched it when you got past its "watched" point.
  void stopped() {
    final item = _item, r = _result;
    _item = null;
    _result = null;
    if (item == null || r == null || !_reportedStart || _dur <= Duration.zero) return;
    _ending = Future.wait([_ending, _end(item, r, _rule, _pos, _dur)]);
  }

  Future<void> _end(MediaItem item, PlaybackInitializationResult r, WatchedRule rule, Duration position, Duration duration) async {
    try {
      await client.reportPlaybackStopped(
        itemId: item.id,
        position: position,
        duration: duration,
        playSessionId: r.playSessionId,
        mediaSourceId: r.selectedMediaSourceId,
      );
      rule.delivered(position, duration); // the stop is a report too
    } catch (_) {}
    if (!rule.isWatched(position, duration)) return;
    try {
      if (rule.serverMarked) {
        client.notifyWatchedFromPlaybackSession(item); // the server marked it: nothing to send
      } else {
        await client.markWatchedFromPlaybackStop(item);
      }
    } catch (_) {}
  }

  /// The player is closing for good. Tells the server (as [stopped]), waits for it to have
  /// heard, then lets the Servers pages know ([ended]).
  @override
  Future<void> close() async {
    stopped();
    try {
      await _ending.timeout(const Duration(seconds: 8));
    } catch (_) {}
    ended.value++;
  }
}

/// A show's seasons and episodes from the server, in the shape the player's episode list wants.
class ServerEpisodeStore extends EpisodeStore {
  ServerEpisodeStore(this.client, this.showId, super.show);
  final MediaServerClient client;
  final String showId;

  final _known = <(int, int), MediaItem>{};
  final _bySeason = <int, Future<List<EpisodeInfo>>>{};
  late final Future<List<MediaItem>> _seasonItems = client.fetchChildren(showId).then(
    (list) => list.where((s) => s.kind == MediaKind.season).toList(),
  );

  String? _img(String? path) => path == null || path.isEmpty ? null : client.thumbnailUrl(path, width: 480);

  @override
  Future<List<Season>> get seasons => _seasonItems.then((items) {
    final list = [
      for (final s in items)
        Season(s.index ?? 0, s.title ?? 'Season ${s.index ?? 0}', s.leafCount ?? 0, s.year?.toString(), _img(s.thumbPath)),
    ];
    list.sort((a, b) => a.number == 0 ? 1 : (b.number == 0 ? -1 : a.number.compareTo(b.number)));
    return list;
  });

  @override
  Future<List<EpisodeInfo>> season(int n) => _bySeason.putIfAbsent(n, () async {
    try {
      final s = (await _seasonItems).where((x) => (x.index ?? 0) == n).firstOrNull;
      if (s == null) return const [];
      final eps = (await client.fetchChildren(s.id)).where((e) => e.kind == MediaKind.episode).toList();
      return [
        for (final (i, e) in eps.indexed)
          () {
            final number = e.index ?? i + 1;
            _known[(n, number)] = e;
            return EpisodeInfo(
              n,
              number,
              (e.title ?? '').trim().isEmpty ? 'Episode $number' : e.title!,
              e.summary ?? '',
              _img(e.thumbPath),
              e.durationMs == null ? null : (e.durationMs! / 60000).round(),
              DateTime.tryParse(e.originallyAvailableAt ?? ''),
            );
          }(),
      ];
    } catch (_) {
      _bySeason.remove(n);
      rethrow;
    }
  });

  /// The server's item for [ep].
  Future<MediaItem?> item(PlayerEpisode ep) async {
    final hit = _known[(ep.season, ep.number)];
    if (hit != null) return hit;
    await season(ep.season);
    return _known[(ep.season, ep.number)];
  }
}
