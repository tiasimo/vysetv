import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../account.dart';
import '../tmdb.dart' show Media;
import 'live_upload.dart';
import 'watch_party.dart';

export 'live_upload.dart' show LiveShareError;

/// The relay couldn't get the channel: from the VPS that's what the upload is there for.
class _ServerRefused extends LiveShareError {
  const _ServerRefused() : super("This channel didn't send any video. Try again.");
}

/// Live TV in a watch party. Most channels allow one connection, so the relay on the VPS opens it
/// and everyone in the room, the host too, plays from the relay. If the provider won't let the VPS
/// in, the host's device opens it and sends it to the relay instead. The host's app checks in every
/// few seconds either way: if it stops (Stop, a crash, a dead connection), the relay closes the
/// channel and wipes everything it held.
class PartyLive {
  static const _checkIn = Duration(seconds: 5); // the relay gives up after 20

  /// Something went wrong after it started; the room page shows it.
  static final problem = ValueNotifier<String?>(null);

  static bool _starting = false;
  static String? _id;
  static String? _token;
  static String? _base;
  static Timer? _ping;
  static LiveUpload? _upload;
  static final _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  static void start() => WatchParty.state.addListener(_changed);

  /// Whatever ended the stream in your room (Stop, leaving, playing something else), this ends.
  static void _changed() {
    if (_starting) return;
    final s = WatchParty.state.value;
    if (_id != null) {
      if (s == null || !s.isLive || !s.mine) unawaited(_shutDown());
    } else if (s != null && s.isLive && s.mine) {
      unawaited(WatchParty.stop()); // back after a restart: nothing's checking in for it now
    }
  }

  /// Where the room plays the live stream from: the relay, for everyone.
  static String urlFor(WatchState s) => '${s.live?['url'] ?? ''}';

  static String _at(String action) => '$_base/$_id/$action?t=${Uri.encodeQueryComponent(_token ?? '')}';

  /// Puts the channel at [url] on for your room. Close your own player on it first: the relay
  /// needs the one connection. Throws [LiveShareError] when it can't. [onUploading] is called if
  /// the relay couldn't open it and this device is about to try sending it instead.
  static Future<void> host({required String url, required String title, String? logo, VoidCallback? onUploading}) async {
    await _shutDown();
    problem.value = null;
    _starting = true;
    try {
      final j = await Account.pb.send('/api/vyse/rooms/live', method: 'POST') as Map<String, dynamic>;
      _id = j['id'] as String;
      _token = j['token'] as String;
      _base = j['base'] as String;
      try {
        // quick: if no video comes soon, the relay says so and this device opens it instead
        await _open({'url': url, 'title': title, 'quick': true});
      } on _ServerRefused {
        onUploading?.call();
        final upload = _upload = LiveUpload(link: url, push: _at('push'), onLost: _lost);
        await upload.connect();
        final opened = _open({'upload': true, 'title': title});
        upload.pump();
        await opened;
      }
      _ping = Timer.periodic(_checkIn, (_) => _checkInNow());
      await WatchParty.hostState(
        WatchState(
          media: Media(id: _number(url), title: title, isTv: false, posterPath: logo, backdropPath: logo),
          live: {'url': '$_base/$_id/index.m3u8', 'logo': logo ?? ''},
          playing: true,
          by: WatchParty.me,
        ),
      );
    } catch (e) {
      await _shutDown();
      if (e is LiveShareError) rethrow;
      throw LiveShareError(Account.describe(e));
    } finally {
      _starting = false;
    }
  }

  /// The channel died on this device and wouldn't come back. While starting, host says so.
  static void _lost() {
    if (_starting) return;
    problem.value = 'The channel stopped.';
    unawaited(WatchParty.stop());
  }

  /// Asks the relay to open a channel, or to expect it from this device; it answers once a few
  /// seconds of it are ready.
  static Future<void> _open(Map<String, Object> what) async {
    try {
      final q = await _client.postUrl(Uri.parse(_at('start')));
      q.headers.contentType = ContentType.json;
      q.write(jsonEncode(what));
      final r = await q.close().timeout(const Duration(seconds: 35));
      final body = await r.transform(utf8.decoder).join();
      if (r.statusCode == HttpStatus.noContent) return;
      var reason = '';
      try {
        reason = '${(jsonDecode(body) as Map<String, dynamic>)['reason']}';
      } catch (_) {}
      if (reason == 'unreachable') throw const _ServerRefused();
      throw LiveShareError(switch (reason) {
        'format' => "This channel's format can't be shared yet.",
        'heavy' => 'This channel is too heavy to share.',
        'full' => 'Live rooms are full right now. Try again soon.',
        _ => "Couldn't share this channel. Try again.",
      });
    } on LiveShareError {
      rethrow;
    } catch (_) {
      throw const LiveShareError("Couldn't reach the relay. Try again.");
    }
  }

  static Future<void> _checkInNow() async {
    final id = _id;
    try {
      final q = await _client.postUrl(Uri.parse(_at('ping')));
      final r = await q.close().timeout(const Duration(seconds: 4));
      await r.drain<void>();
      // the channel died on the relay's side, or the 12 hours a token lasts are up
      if ((r.statusCode == HttpStatus.notFound || r.statusCode == HttpStatus.forbidden) && id == _id) {
        problem.value = 'The channel stopped.';
        unawaited(WatchParty.stop());
      }
    } catch (_) {
      // a blip: the relay allows for a few missed ones
    }
  }

  static Future<void> _shutDown() async {
    _ping?.cancel();
    _ping = null;
    _upload?.stop();
    _upload = null;
    final at = _id == null ? null : '$_base/$_id?t=${Uri.encodeQueryComponent(_token ?? '')}';
    _id = _token = _base = null;
    if (at == null) return;
    // wiped now; if this never arrives, the relay does it by itself when check-ins stop
    try {
      final r = await (await _client.deleteUrl(Uri.parse(at))).close().timeout(const Duration(seconds: 5));
      await r.drain<void>();
    } catch (_) {}
  }

  static int _number(String s) {
    var h = 2166136261;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 16777619) & 0x7fffffff;
    }
    return h == 0 ? 1 : h;
  }
}
