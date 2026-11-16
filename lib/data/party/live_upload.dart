import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Why a channel couldn't be shared, in words for people.
class LiveShareError implements Exception {
  const LiveShareError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Refused implements Exception {
  const _Refused(this.status);
  final int status;
}

class _NotVideo implements Exception {
  const _NotVideo();
}

/// The fallback for when the relay can't open a channel itself: many providers refuse servers or
/// lock a line to the subscriber's address. This holds the channel's one connection on this device,
/// the way it does when the host watches alone, and sends it to the relay a stretch at a time.
class LiveUpload {
  LiveUpload({required this.link, required this.push, required this.onLost, this.patience = const Duration(seconds: 60)});

  final String link;

  /// The relay's address for this stream, with its token.
  final String push;

  /// The channel or the upload died and wouldn't come back. Not called after [stop].
  final void Function() onLost;

  /// How long to wait for the provider to free the slot this device's own player just let go of.
  final Duration patience;

  static const _format = "This channel's format can't be shared yet.";
  static const _quiet = Duration(seconds: 15); // the channel went silent: reconnect
  static const _hold = Duration(seconds: 30); // retrying one stretch; the relay gives up at 45
  static const _stretch = 512 << 10;
  static const _every = Duration(seconds: 1); // so a light channel isn't held back
  static const _realData = 1 << 20; // less than this from a connection doesn't count as it working
  static const _maxFails = 5;
  static const _bestRate = 8000000; // picks the best variant under this

  final _channel = HttpClient()
    ..userAgent = 'libmpv' // what this app's player sends, so the provider sees the same client
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = false;
  final _relay = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  late final _in = StreamIterator(_read());

  bool _stopped = false;
  bool _flowing = false;
  bool _cutOff = false;
  int _sent = 0;
  int _stretches = 0;

  /// Returns once the channel is sending. Throws [LiveShareError] when it won't.
  Future<void> connect() async {
    if (!await _in.moveNext()) throw const LiveShareError("Couldn't open this channel. Try again.");
    _flowing = true;
  }

  /// Sends the channel to the relay until [stop]. Call it after [connect].
  void pump() => unawaited(_pump());

  /// Hangs up on the channel straight away: the slot is needed by whoever opens it next.
  void stop() {
    _stopped = true;
    _channel.close(force: true);
    _relay.close(force: true);
    unawaited(_in.cancel().catchError((_) {}));
  }

  Future<void> _pump() async {
    final out = BytesBuilder(copy: false);
    final clock = Stopwatch()..start();
    var sending = Future<void>.value();
    try {
      do {
        out.add(_in.current);
        if (out.length >= _stretch || clock.elapsed >= _every) {
          await sending; // one at a time, and it holds the channel back if the upload can't keep up
          sending = _post(out.takeBytes());
          clock.reset();
        }
      } while (!_stopped && !_cutOff && await _in.moveNext());
      await sending;
    } catch (_) {
      // the channel is gone: said below
    }
    if (!_stopped) onLost();
  }

  /// Never throws: it's left running while the next stretch is read.
  Future<void> _post(Uint8List bytes) async {
    final n = ++_stretches;
    final began = DateTime.now();
    while (!_stopped) {
      HttpClientRequest? q;
      try {
        q = await _relay.postUrl(Uri.parse('$push&n=$n'));
        q.headers.contentType = ContentType.binary;
        q.contentLength = bytes.length;
        q.add(bytes);
        final r = await q.close().timeout(const Duration(seconds: 20));
        await r.drain<void>();
        if (r.statusCode == HttpStatus.noContent) {
          _sent += bytes.length;
          return;
        }
      } catch (_) {
        q?.abort(); // a blip: the same stretch goes again, and the relay won't take it twice
      }
      if (DateTime.now().difference(began) > _hold) {
        _cutOff = true;
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// The channel's video, one connection after another. Waiting for the first, it keeps trying
  /// until [patience] runs out; once it's flowing, a channel that keeps dying is given up on.
  Stream<List<int>> _read() async* {
    final began = DateTime.now();
    var fails = 0;
    var why = "Couldn't open this channel. Try again.";
    while (!_stopped) {
      final before = _sent;
      try {
        await for (final chunk in _once()) {
          yield chunk;
        }
      } on LiveShareError {
        rethrow;
      } on _Refused catch (e) {
        why = 'Your provider refused this channel (HTTP ${e.status}). Try again in a minute.';
      } on _NotVideo {
        why = "Your provider didn't send video for this channel. Try again in a minute.";
      } catch (_) {
        // dropped, or it went silent
      }
      if (_stopped) return;
      fails = _sent - before >= _realData ? 0 : fails + 1;
      if (_flowing ? fails >= _maxFails : DateTime.now().difference(began) > patience) throw LiveShareError(why);
      await Future<void>.delayed(Duration(seconds: min(2 * (fails + 1), 8))); // gently: panels ban what hammers them
    }
  }

  /// One connection's worth.
  Stream<List<int>> _once() async* {
    final from = Uri.parse(link);
    final r = await _get(from);
    final it = StreamIterator(r.timeout(_quiet));
    try {
      if (!await it.moveNext()) return;
      final head = it.current;
      if (utf8.decode(head.take(7).toList(), allowMalformed: true) == '#EXTM3U') {
        final text = BytesBuilder(copy: false)..add(head);
        while (text.length < 1 << 20 && await it.moveNext()) {
          text.add(it.current);
        }
        final at = r.redirects.isEmpty ? from : from.resolveUri(r.redirects.last.location);
        await for (final chunk in _hls(at, utf8.decode(text.takeBytes(), allowMalformed: true))) {
          yield chunk;
        }
        return;
      }
      if (!_video(head)) throw const _NotVideo();
      yield head;
      while (await it.moveNext()) {
        yield it.current;
      }
    } finally {
      await it.cancel();
    }
  }

  Future<HttpClientResponse> _get(Uri u) async {
    final q = await _channel.getUrl(u);
    final r = await q.close().timeout(const Duration(seconds: 12));
    if (r.statusCode >= 400) {
      unawaited(r.drain<void>().catchError((_) {}));
      throw _Refused(r.statusCode);
    }
    return r;
  }

  Future<String> _text(Uri u) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in (await _get(u)).timeout(_quiet)) {
      b.add(chunk);
      if (b.length > 1 << 20) break;
    }
    return utf8.decode(b.takeBytes(), allowMalformed: true);
  }

  /// A channel that comes as HLS, one request at a time, like one player would.
  Stream<List<int>> _hls(Uri at, String body) async* {
    if (body.contains('#EXT-X-STREAM-INF')) {
      at = _variant(at, body);
      body = await _text(at);
    }
    var done = -1;
    while (!_stopped) {
      final key = RegExp(r'#EXT-X-KEY:METHOD=([A-Za-z0-9-]+)').allMatches(body);
      if (body.contains('#EXT-X-MAP') || key.any((m) => m[1]!.toUpperCase() != 'NONE')) {
        throw const LiveShareError(_format);
      }
      var seq = 0;
      var target = 4.0;
      final files = <String>[];
      for (final raw in const LineSplitter().convert(body)) {
        final l = raw.trim();
        if (l.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          seq = int.tryParse(l.substring(22).trim()) ?? 0;
        } else if (l.startsWith('#EXT-X-TARGETDURATION:')) {
          target = double.tryParse(l.substring(22).trim()) ?? 4;
        } else if (l.isNotEmpty && !l.startsWith('#')) {
          files.add(l);
        }
      }
      // joining: the last few; after that, whatever's new
      for (var i = done < 0 ? max(0, files.length - 3) : max(0, done + 1 - seq); i < files.length && !_stopped; i++) {
        try {
          var first = true;
          await for (final chunk in (await _get(at.resolve(files[i]))).timeout(_quiet)) {
            if (first && !_video(chunk)) throw const LiveShareError(_format);
            first = false;
            yield chunk;
          }
          done = seq + i;
        } on LiveShareError {
          rethrow;
        } catch (_) {
          // gone already; the next one will do
        }
      }
      if (body.contains('#EXT-X-ENDLIST')) return;
      await Future<void>.delayed(Duration(milliseconds: (max(1.0, target / 2) * 1000).round()));
      body = await _text(at);
    }
  }

  static Uri _variant(Uri at, String body) {
    final lines = const LineSplitter().convert(body);
    String? best, lightest;
    var bestAt = -1, lightestAt = 1 << 62;
    for (var i = 0; i + 1 < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final rate = int.tryParse(RegExp(r'[:,]BANDWIDTH=(\d+)').firstMatch(lines[i])?[1] ?? '') ?? 0;
      final file = lines[i + 1].trim();
      if (rate <= _bestRate && rate > bestAt) {
        best = file;
        bestAt = rate;
      }
      if (rate < lightestAt) {
        lightest = file;
        lightestAt = rate;
      }
    }
    final pick = best ?? lightest;
    if (pick == null) throw const LiveShareError(_format);
    return at.resolve(pick);
  }

  /// Whether this starts like the video the relay can cut: packets 188 bytes apart.
  static bool _video(List<int> b) {
    if (b.length < 565) return b.isNotEmpty && b.first == 0x47;
    for (var i = 0; i < 188; i++) {
      if (b[i] == 0x47 && b[i + 188] == 0x47 && b[i + 376] == 0x47) return true;
    }
    return false;
  }
}
