import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local HLS relay on 127.0.0.1, modelled on the London relay's stream-proxy + nginx pipes.
///
/// * Playlists are fetched with spoofed Referer/Origin and every URL is rewritten back through here.
/// * Segments are piped with the same headers, no compression, and their real content type.
/// * mpv's HLS demuxer can't seek inside fMP4 playlists (it reads the new segment with stale
///   sample offsets). Those play as an EDL timeline of their segments instead ([timeline]);
///   when that isn't possible, `from` trims a playlist to start at the segment holding that
///   second and the player reopens it instead of seeking.
class StreamProxy {
  StreamProxy._();
  static final instance = StreamProxy._();

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final _client = HttpClient()
    ..autoUncompress = false
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 16
    ..connectionTimeout = const Duration(seconds: 10);
  final _vod = <String, String>{}; // finished (VOD) playlists never change; keep their text
  final _hosts = <String, Map<String, String>>{}; // hosts that want their own headers (anime sources)
  final _exact = <String>{}; // of those, the ones that get nothing else (a link you pasted)

  /// The headers [url]'s host insists on (Referer, Origin, a cookie…), sent instead of the
  /// spoofed ones. The hosts its playlists point to (segment CDNs) get the same, unless they
  /// have their own.
  ///
  /// [exact]: and nothing more. Without it the relay still adds the Referer and Origin it sends
  /// everywhere (Movy's), which the sources were tested with; a link of your own gets none.
  void useHeaders(String url, Map<String, String> headers, {bool exact = false}) {
    final host = Uri.parse(url).host;
    if (exact) {
      _exact.add(host);
      _hosts[host] = headers;
    } else if (headers.isNotEmpty) {
      _hosts[host] = headers;
    }
  }

  // ── for downloads ──

  /// A playlist's text, fetched as the relay fetches it for the player (same headers). The
  /// part after a `#` (a master narrowed to one quality) is not sent.
  Future<String> fetchText(String url) => _text(url.split('#').first);

  /// A piece of a stream (a segment, an init section, a key), fetched as for the player.
  Future<HttpClientResponse> fetch(String url, {String? range}) => _get(url, range: range);

  final _folders = <String, String>{}; // token → a downloaded stream's folder

  /// An address the player can open for a stream saved in [dir] (its playlists and pieces, with
  /// the names they have on disk): `<answer>/index.m3u8`. Served from this device only.
  Future<String> serveFolder(String dir) async {
    final s = await _start();
    final token = _enc(dir);
    _folders[token] = dir;
    return 'http://127.0.0.1:${s.port}/files/$token';
  }

  Future<HttpServer> _start() => _starting ??= () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle);
    return _server = s;
  }();

  /// A URL mpv can open in place of [url], optionally starting at the segment holding [from].
  Future<String> wrap(String url, {double? from}) async {
    final s = await _start();
    return 'http://127.0.0.1:${s.port}/hls/${_enc(url)}.m3u8${from == null ? '' : '?from=${from.toStringAsFixed(3)}'}';
  }

  /// For fMP4 streams: where a playlist trimmed at [from] really starts (in seconds).
  /// Null when the stream is MPEG-TS, which mpv seeks normally.
  Future<double?> fragmentedStart(String url, double from) async {
    var text = await _text(url);
    var base = url;
    if (text.contains('#EXT-X-STREAM-INF')) {
      final variant = _onlyOf(url) ??
          const LineSplitter().convert(text).map((l) => l.trim()).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
      if (variant.isEmpty) return null;
      base = Uri.parse(url).resolve(variant).toString();
      text = await _text(base);
    }
    if (!text.contains('#EXT-X-MAP')) return null;
    return _trim(text, from).start;
  }

  /// Off for now: after seeking around, mpv carried on from wherever it was last reading and
  /// jumped ahead (a Movy episode skipped 32:01 to 32:30 every time). Without it, fMP4 streams use
  /// trimmed playlists, reopened on far seeks.
  static const _useTimeline = false;

  /// An fMP4 stream as an mpv EDL timeline: one entry per segment, all sharing the init
  /// fragment. mpv opens whichever segment a seek lands in, so even a far seek stays in the same
  /// stream: no reopen, no black screen. Null when the stream can't be described that way
  /// (MPEG-TS, encrypted, byte ranges, live).
  Future<String?> timeline(String url) async {
    if (!_useTimeline) return null;
    final port = (await _start()).port;
    var text = await _text(url);
    var media = url;
    final audio = <({String url, String? lang, String? name})>[];
    if (text.contains('#EXT-X-STREAM-INF')) {
      // the best rendition, and the separate audio it plays with (if any)
      final lines = const LineSplitter().convert(text).map((l) => l.trim()).toList();
      String? best, group;
      var bw = -1;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        final b = int.tryParse(RegExp(r'[^-]BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '') ?? 0;
        final next = lines.skip(i + 1).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
        final only = _onlyOf(url);
        if (only != null && Uri.parse(url).resolve(next).toString() != only) continue; // a quality was picked
        if (next.isNotEmpty && b > bw) {
          bw = b;
          best = next;
          group = _attr(lines[i], 'AUDIO');
        }
      }
      if (best == null) return null;
      for (final l in lines) {
        if (!l.startsWith('#EXT-X-MEDIA:') || _attr(l, 'TYPE') != 'AUDIO' || _attr(l, 'GROUP-ID') != group) continue;
        final u = _attr(l, 'URI');
        if (u != null) audio.add((url: Uri.parse(url).resolve(u).toString(), lang: _attr(l, 'LANGUAGE'), name: _attr(l, 'NAME')));
      }
      media = Uri.parse(url).resolve(best).toString();
    }
    final video = await _dash(media, port);
    if (video == null) return null;
    final parts = ['# mpv EDL v0', '!no_chapters', ...video];
    for (final a in audio) {
      final lines = await _dash(a.url, port);
      if (lines == null) return null;
      parts.add('!new_stream');
      if (a.lang != null || a.name != null) {
        parts.add('!track_meta${a.lang == null ? '' : ',lang=${_esc(a.lang!)}'}${a.name == null ? '' : ',title=${_esc(a.name!)}'}');
      }
      parts.addAll(lines);
    }
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_edl');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${media.hashCode.toUnsigned(32)}_$port.edl');
    await file.writeAsString('${parts.join('\n')}\n');
    return file.path;
  }

  /// One fMP4 media playlist as EDL lines: the init fragment, then each segment with its length.
  Future<List<String>?> _dash(String url, int port) async {
    final text = await _text(url);
    if (!text.contains('#EXT-X-ENDLIST') || text.contains('#EXT-X-BYTERANGE')) return null;
    if ('#EXT-X-MAP'.allMatches(text).length != 1 || RegExp(r'#EXT-X-KEY:.*METHOD=(?!NONE)').hasMatch(text)) return null;
    final base = Uri.parse(url);
    String piped(String u) => 'http://127.0.0.1:$port/seg/${_enc(base.resolve(u).toString())}';
    final out = <String>[];
    double? dur;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        final u = _uriRe.firstMatch(line)?.group(1);
        if (u == null) return null;
        out.add('!mp4_dash,init=${_esc(piped(u))}');
      } else if (line.startsWith('#EXTINF:')) {
        dur = double.tryParse(line.substring(8).split(',').first);
      } else if (!line.startsWith('#')) {
        if (dur == null || out.isEmpty) return null;
        out.add('${_esc(piped(line))},length=${dur.toStringAsFixed(3)}');
        dur = null;
      }
    }
    return out.length > 1 ? out : null;
  }

  /// The renditions a master playlist offers, best first. Empty for a single-quality stream.
  Future<List<StreamVariant>> variants(String url) async {
    final text = await _text(url);
    if (!text.contains('#EXT-X-STREAM-INF')) return const [];
    final base = Uri.parse(url);
    // audio kept as its own track (anime sources): a quality's own playlist is silent, so each
    // quality plays as the master narrowed to it
    final splitAudio = RegExp(r'#EXT-X-MEDIA:[^\n]*TYPE=AUDIO[^\n]*URI=').hasMatch(text);
    final out = <StreamVariant>[];
    final seen = <int>{};
    String? inf;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        inf = line;
      } else if (inf != null && line.isNotEmpty && !line.startsWith('#')) {
        final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(inf);
        final bw = int.tryParse(RegExp(r'[^-]BANDWIDTH=(\d+)').firstMatch(inf)?.group(1) ?? '') ?? 0;
        final w = int.tryParse(res?.group(1) ?? '') ?? 0, h = int.tryParse(res?.group(2) ?? '') ?? 0;
        final v = base.resolve(line).toString();
        if (seen.add(w * 100000 + h)) out.add(StreamVariant(url: splitAudio ? _narrowed(url, v) : v, width: w, height: h, bandwidth: bw));
        inf = null;
      }
    }
    out.sort((a, b) => b.width != a.width ? b.width - a.width : b.bandwidth - a.bandwidth);
    return out;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }

  // ── routes ──

  Future<void> _handle(HttpRequest req) async {
    final seg = req.uri.pathSegments;
    try {
      if (seg.length == 2 && seg[0] == 'hls') {
        await _playlist(req, _dec(seg[1].replaceAll('.m3u8', '')), double.tryParse(req.uri.queryParameters['from'] ?? ''));
      } else if (seg.length == 2 && seg[0] == 'seg') {
        await _segment(req, _dec(seg[1]));
      } else if (seg.length >= 3 && seg[0] == 'files') {
        await _saved(req, seg[1], seg.sublist(2));
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _playlist(HttpRequest req, String target, double? from) async {
    var text = await _text(target);
    if (!text.contains('#EXTM3U')) throw const HttpException('not a playlist');
    final base = Uri.parse(target);
    final port = _server!.port;
    final q = from == null ? '' : '?from=${from.toStringAsFixed(3)}';
    String hls(String u) => 'http://127.0.0.1:$port/hls/${_enc(u)}.m3u8$q';
    String piped(String u) => 'http://127.0.0.1:$port/seg/${_enc(u)}';
    final own = _hosts[base.host];
    String abs(String u) {
      final r = base.resolve(u).toString();
      if (own != null) {
        final host = Uri.parse(r).host;
        if (!_hosts.containsKey(host)) {
          _hosts[host] = own;
          if (_exact.contains(base.host)) _exact.add(host);
        }
      }
      return r;
    }

    final master = text.contains('#EXT-X-STREAM-INF');
    if (!master && from != null && text.contains('#EXT-X-MAP')) text = _trim(text, from).text;
    final only = master ? _onlyOf(target) : null;

    var streamInf = false;
    String? inf; // a narrowed master holds each quality's line until it knows which it is
    final out = StringBuffer();
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          streamInf = true;
          if (only != null) {
            inf = line;
            continue;
          }
        }
        if (line.startsWith('#EXT-X-MEDIA:') || line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
          out.writeln(_replaceUri(line, (u) => hls(abs(u))));
        } else if (line.startsWith('#EXT-X-MAP:') || line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-SESSION-KEY:')) {
          out.writeln(_replaceUri(line, (u) => piped(abs(u))));
        } else {
          out.writeln(line);
        }
        continue;
      }
      final u = abs(line);
      if (only != null && streamInf) {
        if (u == only) {
          out
            ..writeln(inf)
            ..writeln(hls(u));
        }
        inf = null;
        streamInf = false;
      } else if (streamInf || u.contains('.m3u8')) {
        out.writeln(hls(u));
        streamInf = false;
      } else {
        out.writeln(piped(u));
      }
    }
    final body = utf8.encode(out.toString());
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
      ..headers.contentLength = body.length
      ..add(body);
    await req.response.close();
  }

  Future<void> _segment(HttpRequest req, String target) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    // a cold CDN edge can stall or fail the first ask for a piece while it pulls it in (ReCloud's
    // does); a second ask usually gets it, so the player never sees that first failure
    HttpClientResponse? up;
    for (var i = 0; up == null; i++) {
      try {
        final r = await _get(target, range: range);
        if (r.statusCode >= 500 && i == 0) {
          await r.drain<void>();
          continue;
        }
        up = r;
      } catch (_) {
        if (i > 0) rethrow;
      }
    }
    final res = req.response..statusCode = up.statusCode;
    res.headers.contentType = _segmentType(up.headers.contentType, target);
    final zipped = _gzipped(up);
    if (up.contentLength >= 0 && !zipped) res.headers.contentLength = up.contentLength;
    final cr = up.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) res.headers.set(HttpHeaders.contentRangeHeader, cr);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (req.method == 'HEAD') {
      await up.drain<void>();
    } else {
      await res.addStream(zipped ? up.cast<List<int>>().transform(gzip.decoder) : up);
    }
    await res.close();
  }

  /// One file of a downloaded stream ([serveFolder]), whole or the range asked for.
  Future<void> _saved(HttpRequest req, String token, List<String> path) async {
    final dir = _folders[token];
    final res = req.response;
    if (dir == null || path.any((p) => p.isEmpty || p == '..' || p == '.' || p.contains('\\') || p.contains(':'))) {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    final file = File([dir, ...path].join(Platform.pathSeparator));
    if (!await file.exists()) {
      res.statusCode = HttpStatus.notFound;
      return res.close();
    }
    final length = await file.length();
    final name = path.last.toLowerCase();
    res.headers.contentType = name.endsWith('.m3u8')
        ? ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
        : name.endsWith('.ts')
        ? ContentType('video', 'mp2t')
        : name.endsWith('.vtt') || name.endsWith('.webvtt')
        ? ContentType('text', 'vtt', charset: 'utf-8')
        : name.endsWith('.m4s') || name.endsWith('.mp4') || name.endsWith('.m4a')
        ? ContentType('video', 'mp4')
        : ContentType.binary;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    var start = 0, end = length - 1;
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (m != null && length > 0) {
      final a = int.tryParse(m[1]!), b = int.tryParse(m[2]!);
      if (a == null && b != null) {
        start = length - b < 0 ? 0 : length - b; // the last b bytes
      } else if (a != null) {
        start = a;
        if (b != null && b < end) end = b;
      }
      if (start > end || start >= length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return res.close();
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    }
    res.headers.contentLength = length == 0 ? 0 : end - start + 1;
    if (req.method != 'HEAD' && length > 0) await res.addStream(file.openRead(start, end + 1));
    await res.close();
  }

  // ── playlists ──

  Future<String> _text(String url) async {
    final hit = _vod[url];
    if (hit != null) return hit;
    final up = await _get(url);
    final text = await utf8.decodeStream(_gzipped(up) ? up.cast<List<int>>().transform(gzip.decoder) : up);
    if (up.statusCode >= 300) throw HttpException('playlist ${up.statusCode}');
    if (text.contains('#EXT-X-ENDLIST') || text.contains('#EXT-X-STREAM-INF')) _vod[url] = text;
    return text;
  }

  /// Drops the segments that end before [from]. Header tags stay; per-segment tags go with
  /// their segment.
  static ({String text, double start}) _trim(String text, double from) {
    final out = StringBuffer();
    final pending = <String>[];
    var t = 0.0, start = 0.0;
    var keeping = false;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (keeping) {
        out.writeln(line);
        continue;
      }
      if (line.startsWith('#EXTINF') || line.startsWith('#EXT-X-BYTERANGE') || line.startsWith('#EXT-X-DISCONTINUITY') || line.startsWith('#EXT-X-PROGRAM-DATE-TIME')) {
        pending.add(line);
      } else if (line.startsWith('#')) {
        out.writeln(line);
      } else {
        final inf = pending.firstWhere((l) => l.startsWith('#EXTINF'), orElse: () => '#EXTINF:0');
        final dur = double.tryParse(inf.substring(8).split(',').first) ?? 0;
        if (t + dur > from) {
          keeping = true;
          start = t;
          pending.forEach(out.writeln);
          out.writeln(line);
        }
        pending.clear();
        t += dur;
      }
    }
    return (text: out.toString(), start: start);
  }

  // ── upstream ──

  Future<HttpClientResponse> _get(String url, {String? range}) async {
    final uri = Uri.parse(url);
    final (referer, origin) = _spoof(uri.host);
    final rq = await _client.getUrl(uri);
    rq.headers
      ..removeAll(HttpHeaders.acceptEncodingHeader)
      ..set(HttpHeaders.userAgentHeader, _ua)
      ..set(HttpHeaders.acceptHeader, '*/*');
    if (referer.isNotEmpty && !_exact.contains(uri.host)) {
      rq.headers
        ..set(HttpHeaders.refererHeader, referer)
        ..set('Origin', origin);
    }
    _hosts[uri.host]?.forEach(rq.headers.set);
    if (range != null) rq.headers.set(HttpHeaders.rangeHeader, range);
    return rq.close().timeout(const Duration(seconds: 20));
  }

  /// `.top` video hosts and the Movy API take movy.sx, as in the relay's `$pipe_referer` map;
  /// vimeos.net answers 403 to any site at all, so it gets neither; everything else (the
  /// workers.dev shards) answers to vidy.st.
  static (String, String) _spoof(String host) {
    if (host.endsWith('vimeos.net')) return ('', '');
    if (host.endsWith('.top') || host.contains('wecollege') || host.contains('movy.sx')) {
      return ('https://www.movy.sx/', 'https://www.movy.sx');
    }
    return ('https://www.vidy.st/', 'https://www.vidy.st');
  }

  /// Some hosts compress whatever they send, asked or not (the relay never asks).
  static bool _gzipped(HttpClientResponse r) => (r.headers.value(HttpHeaders.contentEncodingHeader) ?? '').contains('gzip');

  /// Disguised segments arrive as text/html or text/css; say what they really are.
  static ContentType _segmentType(ContentType? t, String url) {
    final m = t?.mimeType ?? '';
    if (m.startsWith('video/') || m.startsWith('audio/')) return t!;
    if (url.contains('.m4s') || url.contains('.mp4')) return ContentType('video', 'mp4');
    return ContentType('video', 'mp2t');
  }

  // ── helpers ──

  /// [master] narrowed to one of its qualities, [variant], keeping the audio it plays with.
  static String _narrowed(String master, String variant) => '$master#only=${Uri.encodeComponent(variant)}';

  /// The quality a narrowed master keeps, or null.
  static String? _onlyOf(String url) {
    final i = url.indexOf('#only=');
    return i < 0 ? null : Uri.decodeComponent(url.substring(i + 6));
  }

  static final _uriRe = RegExp(r'''URI=["']?([^"',\s]+)["']?''');
  static String _replaceUri(String line, String Function(String) f) => line.replaceFirstMapped(_uriRe, (m) => 'URI="${f(m.group(1)!)}"');
  static String? _attr(String line, String name) {
    final m = RegExp('(?:^|[,:])$name=(?:"([^"]*)"|([^,]*))').firstMatch(line);
    return m == null ? null : (m.group(1) ?? m.group(2));
  }

  /// EDL's length-prefixed value, safe for any characters.
  static String _esc(String s) => '%${utf8.encode(s).length}%$s';
  static String _enc(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  static String _dec(String s) => utf8.decode(base64Url.decode(base64Url.normalize(s)));
}

class StreamVariant {
  const StreamVariant({required this.url, this.width = 0, this.height = 0, this.bandwidth = 0, this.name});
  final String url;
  final int width;
  final int height;
  final int bandwidth;
  final String? name;

  String get label => name ?? qualityLabel(width, height);
}

/// Named by width so widescreen films (1920x800) still read as 1080p.
String qualityLabel(int width, int height) {
  if (width >= 3200 || height >= 2000) return '4K';
  if (width >= 2500 && height >= 1300) return '1440p';
  if (width >= 1700 || height >= 1000) return '1080p';
  if (width >= 1200 || height >= 700) return '720p';
  if (width >= 800 || height >= 460) return '480p';
  if (width > 0) return '360p';
  return 'Auto';
}
