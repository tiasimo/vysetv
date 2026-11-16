// Playing something that isn't a title from VyseTV's catalogue: a film from your own server, a
// link you pasted, a file you downloaded.
//
// The player gets a stand-in Media (not a TMDB title) and an OutsidePlayback that hands it the
// stream. None of it reaches VyseTV's history, your trackers or Party: the player keeps those for
// catalogue titles.

import 'dart:async';

import 'package:http/http.dart' as http;

import '../screens/player_episodes.dart' show EpisodeStore;
import '../screens/player_page.dart' show PlayerEpisode;
import 'intro_db.dart' show Segment;
import 'net.dart';
import 'sources.dart' show StreamSource;
import 'stream_proxy.dart';
import 'subtitles.dart' as sub;
import 'tmdb.dart' show Media;

/// What the player opens for one title or episode.
class ServerStream {
  const ServerStream({required this.source, this.resumeAt, this.subtitles = const [], this.segments});
  final StreamSource source;
  final Duration? resumeAt;
  final List<sub.SubtitleTrack> subtitles;

  /// Intro / credits markers, when whoever serves it has them.
  final Future<List<Segment>>? segments;
}

/// Something the player plays from outside the catalogue.
abstract class OutsidePlayback {
  /// The title as the player shows it (a stand-in, not a TMDB title).
  Media get media;

  /// The episode to start on (shows).
  PlayerEpisode? get episode;

  /// A show's seasons and episodes, for the player's episode list and Up next.
  EpisodeStore? get episodes;

  /// Its name in the player's sources list ("Plex · Living room", "Link", "Downloaded").
  String get label;

  /// One line under that name.
  String get note;

  /// The title's clear logo, when there is one.
  String? get logo;

  /// Opens [ep] (null for a film or a single file).
  Future<ServerStream> open(PlayerEpisode? ep);

  /// Where you are, every few seconds and on pause.
  void progress(Duration position, Duration duration, {required bool paused});

  /// The player is closing for good.
  Future<void> close();
}

const _browser = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// A link or a file played as it is: something pasted into Search, or a finished download.
class DirectPlayback implements OutsidePlayback {
  DirectPlayback({
    required String title,
    required this.url,
    this.headers = const {},
    this.label = 'Link',
    this.note = 'A link you pasted',
    this.hls,
    this.resumeAt,
    this.onProgress,
    this.onClose,
    this.downloadable = true,
    String? poster,
    String? backdrop,
  }) : media = Media(id: url.hashCode & 0x3fffffff, title: title, isTv: false, posterPath: poster, backdropPath: backdrop);

  /// An http(s) address, or a path on this device.
  final String url;

  /// What its host wants sent with every request (a debrid link, a source's stream).
  final Map<String, String> headers;

  /// Whether it's an HLS playlist. Null: found out when it's opened.
  final bool? hls;

  /// Where to carry on from (a download remembers).
  final Duration? resumeAt;

  /// Whether the player offers to download it (not something already downloaded).
  final bool downloadable;

  /// Told where you are, so a download remembers its place.
  final void Function(Duration position, Duration duration)? onProgress;
  final FutureOr<void> Function()? onClose;

  @override
  final Media media;
  @override
  final String label;
  @override
  final String note;
  @override
  PlayerEpisode? get episode => null;
  @override
  EpisodeStore? get episodes => null;
  @override
  String? get logo => null;

  bool get isLocal => !url.startsWith('http://') && !url.startsWith('https://');

  @override
  Future<ServerStream> open(PlayerEpisode? ep) async {
    // files on this device, playlists included, go straight to the player
    final isHls = !isLocal && (hls ?? await _isPlaylist());
    final sent = {
      if (!isLocal && !headers.keys.any((k) => k.toLowerCase() == 'user-agent')) 'User-Agent': _browser,
      ...headers,
    };
    // the relay sends this host what it was given and nothing of its own
    if (isHls) StreamProxy.instance.useHeaders(url, sent, exact: true);
    String? pick(String key) => sent.entries.where((e) => e.key.toLowerCase() == key).firstOrNull?.value;
    return ServerStream(
      source: StreamSource(
        url: url,
        server: label,
        quality: '',
        referrer: pick('referer') ?? '',
        userAgent: pick('user-agent') ?? '',
        headers: isLocal ? const {} : sent,
        hls: isHls,
      ),
      resumeAt: resumeAt,
    );
  }

  /// Reads the start of the link: a playlist says so in its first line.
  Future<bool> _isPlaylist() async {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8') || path.endsWith('.m3u')) return true;
    if (RegExp(r'\.(mp4|mkv|webm|avi|mov|m4v|ts|mpd|flv|wmv|mp3|m4a|flac)$').hasMatch(path)) return false;
    try {
      final rq = http.Request('GET', Uri.parse(url))
        ..headers.addAll({'User-Agent': _browser, ...headers, 'Range': 'bytes=0-511'});
      final res = await netClient.send(rq).timeout(const Duration(seconds: 8));
      final type = (res.headers['content-type'] ?? '').toLowerCase();
      final first = await res.stream.first.timeout(const Duration(seconds: 8), onTimeout: () => const <int>[]);
      if (type.contains('mpegurl')) return true;
      return String.fromCharCodes(first.take(16)).trimLeft().startsWith('#EXTM3U');
    } catch (_) {
      return false;
    }
  }

  @override
  void progress(Duration position, Duration duration, {required bool paused}) => onProgress?.call(position, duration);

  @override
  Future<void> close() async => await onClose?.call();
}

/// A name for a link with nothing better to go by: its file name, or its host.
String titleOfLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 'Link';
  final file = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
  var name = Uri.decodeComponent(file).replaceAll(RegExp(r'\.(m3u8?|mp4|mkv|webm|avi|mov|m4v|ts|mpd)$', caseSensitive: false), '');
  name = name.replaceAll(RegExp(r'[._]+'), ' ').trim();
  if (name.length < 3 || RegExp(r'^(index|master|playlist|video|stream|manifest)$', caseSensitive: false).hasMatch(name)) {
    return uri.host.isEmpty ? 'Link' : uri.host.replaceFirst(RegExp(r'^www\.'), '');
  }
  return name;
}
