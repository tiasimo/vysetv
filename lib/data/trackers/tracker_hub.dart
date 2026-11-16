import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../anilist.dart' show Anime;
import '../app_settings.dart';
import '../tmdb.dart' show Media, MyList;
import '../watch_progress.dart';
import 'anilist_tracker.dart';
import 'library_import.dart';
import 'loopback_auth.dart';
import 'media_ref.dart';
import 'outbox.dart';
import 'simkl_tracker.dart';
import 'token_store.dart';
import 'trakt_tracker.dart';
import 'tracker.dart';
import 'tracker_keys.dart';

/// One player's live session with the scrobbling services.
class _Session {
  _Session(this.ref, this.startPct) : furthest = startPct, pct = startPct;
  final MediaRef ref;
  final double startPct; // where it opened (a resume near the end isn't a new watch)
  double pct;
  double furthest;
  bool told = false; // a start has gone out
  bool playingThere = false; // the services think it's playing
  bool finishedQueued = false;
  Timer? timer;
  // for noticing a seek: where it was at the last update, and when
  Duration lastPos = Duration.zero;
  DateTime? lastAt;
  bool lastPlaying = false;
}

/// Keeps your lists on other sites up to date with what you watch in VyseTV.
///
/// Only what you do on this device reaches a service: what the player plays, and the My List and
/// History changes you make here. Changes arriving from your other devices (through Vyse Sync)
/// never go out again from here, and nothing read from one service is ever sent to another.
/// Each service's sign-in stays on this device. Updates wait in an [Outbox] while offline or
/// signed out, and go when they can.
class TrackerHub {
  static final states = ValueNotifier<Map<TrackerId, TrackerState>>({
    for (final id in TrackerId.values) id: TrackerState(configured: _clientId(id).isNotEmpty),
  });

  static const _finishedPct = WatchProgress.finishedAt * 100; // 95: VyseTV's "watched"
  static const _writeAheadDelay = Duration(hours: 3);
  static final _finished = <String>{}; // "anilistId:episode" already queued this session
  static final _sessions = <Object, _Session>{};
  static Timer? _timer;
  static bool _pumping = false;

  static String _clientId(TrackerId id) => switch (id) {
    TrackerId.anilist => TrackerKeys.anilistClientId.isNotEmpty ? TrackerKeys.anilistClientId : TrackerKeys.anilistPinClientId,
    TrackerId.simkl => TrackerKeys.simklClientId,
    TrackerId.trakt => TrackerKeys.traktClientId,
  };

  static Future<void> initialize() async {
    await Outbox.load();
    final next = <TrackerId, TrackerState>{};
    for (final id in TrackerId.values) {
      final t = await TokenStore.read(id);
      final expired = t != null && t.refresh == null && t.expiresWithin(Duration.zero);
      final held = Outbox.items.any((i) => i.service == id && i.waitingAuth);
      next[id] = TrackerState(
        configured: _clientId(id).isNotEmpty,
        connected: t != null,
        userName: t?.userName ?? '',
        reconnect: t != null && (expired || held),
        pending: Outbox.count(id),
        expiresSoon: id == TrackerId.anilist && t != null && t.expiresWithin(const Duration(days: 14)),
      );
    }
    states.value = next;
    unawaited(_pump());
    // imported watchlists: what changed there since (once the app has settled)
    unawaited(Future<void>.delayed(const Duration(seconds: 20), LibraryImport.follow));
  }

  static void _set(TrackerId id, TrackerState Function(TrackerState s) change) {
    final all = {...states.value};
    all[id] = change(all[id] ?? const TrackerState());
    states.value = all;
  }

  static bool _live(TrackerId id) {
    final s = states.value[id];
    return s != null && s.connected;
  }

  static bool _enabled(TrackerId id) => switch (id) {
    TrackerId.anilist => AppSettings.trackAniList.value,
    TrackerId.simkl => AppSettings.simklScrobble.value,
    TrackerId.trakt => AppSettings.traktScrobble.value,
  };

  static bool _listEnabled(TrackerId id) => switch (id) {
    TrackerId.simkl => AppSettings.simklList.value,
    TrackerId.trakt => AppSettings.traktList.value,
    _ => false,
  };

  static bool _historyEnabled(TrackerId id) => switch (id) {
    TrackerId.simkl => AppSettings.simklHistory.value,
    TrackerId.trakt => AppSettings.traktHistory.value,
    _ => false,
  };

  /// The services that follow playback live.
  static const _scrobblers = [TrackerId.simkl, TrackerId.trakt];
  static List<TrackerId> get _scrobbling => [for (final id in _scrobblers) if (_live(id) && _enabled(id)) id];

  static void _queue(TrackerId id, String kind, String key, Map<String, dynamic> data, {DateTime? at}) {
    Outbox.put(OutboxItem(service: id, kind: kind, key: key, data: data, nextAt: at, waitingAuth: states.value[id]?.reconnect ?? false));
  }

  // ── what the player tells us ──

  /// The player watched [episode] of [anime] to the end (VyseTV's own "finished" point). Queued
  /// for AniList when it's connected, at most once per episode per session.
  static void animeEpisodeFinished(Anime anime, int episode) {
    if (episode <= 0 || !_finished.add('${anime.id}:$episode')) return;
    if (!_live(TrackerId.anilist) || !_enabled(TrackerId.anilist)) return;
    _queue(TrackerId.anilist, 'anime', '${anime.id}', {'a': anime.id, 'e': episode, 't': anime.title});
    _counts();
    unawaited(_pump());
  }

  /// Where a player is, as it plays (on play / pause, and every few seconds). [owner] is the
  /// player; a new episode in it ends the last one's session first.
  ///
  /// Simkl and Trakt hear start (after 2 s of playing, or 60 s when it opened past 80%: a peek
  /// at the end isn't a watch), pause (after 5 s paused) and stop. A jump of 30 s or more tells
  /// Trakt the new spot (Simkl works that out itself). Anything shorter than 5 minutes is left
  /// out (trailers, clips).
  static void playback(Object owner, MediaRef? ref, {required bool playing, required Duration position, required Duration duration}) {
    final services = _scrobbling;
    if (services.isEmpty) return;
    if (ref == null || duration < const Duration(minutes: 5)) return;
    final pct = (position.inMilliseconds / duration.inMilliseconds * 100).clamp(0.0, 100.0);
    var s = _sessions[owner];
    if (s != null && s.ref.itemKey != ref.itemKey) {
      playerClosed(owner);
      s = null;
    }
    s ??= _sessions[owner] = _Session(ref, pct);
    final now = DateTime.now();
    var seeked = false;
    final at = s.lastAt;
    if (at != null && s.lastPlaying && playing) {
      final expected = s.lastPos + now.difference(at);
      seeked = (position - expected).abs() >= const Duration(seconds: 30);
    }
    s
      ..lastPos = position
      ..lastAt = now
      ..lastPlaying = playing
      ..pct = pct
      ..furthest = max(s.furthest, pct);
    // crossed the finished point in this session: write it down first, so a crash or a
    // failed stop still gets it there (sent only if the live stop doesn't go through)
    if (!s.finishedQueued && s.startPct < _finishedPct && s.furthest >= _finishedPct) {
      s.finishedQueued = true;
      for (final id in services) {
        _queue(
          id,
          'watched',
          ref.itemKey,
          {'ref': ref.toJson(), 'at': _minute(now).toIso8601String()},
          at: now.add(_writeAheadDelay),
        );
      }
      _counts();
    }
    final session = s;
    if (playing && !session.playingThere) {
      if (session.timer?.isActive ?? false) return; // a start is already on its way
      final wait = !session.told && session.startPct >= 80 ? const Duration(seconds: 60) : const Duration(seconds: 2);
      session.timer = Timer(wait, () {
        session.playingThere = true;
        session.told = true;
        _scrobble('start', session);
      });
    } else if (!playing && session.playingThere) {
      if (session.timer?.isActive ?? false) return;
      session.timer = Timer(const Duration(seconds: 5), () {
        session.playingThere = false;
        _scrobble('pause', session);
      });
    } else if (playing && session.playingThere && seeked) {
      session.timer?.cancel();
      session.timer = Timer(const Duration(seconds: 2), () => _scrobble('start', session, only: TrackerId.trakt));
    } else if (!(playing && session.playingThere)) {
      session.timer?.cancel(); // a quick pause-and-play (or play-and-pause) needs nothing
    }
  }

  /// The player closed, or moved on to another episode.
  static void playerClosed(Object owner) {
    final s = _sessions.remove(owner);
    if (s == null) return;
    s.timer?.cancel();
    if (!s.told) return; // the services never heard about it
    final finished = s.finishedQueued || (s.startPct < _finishedPct && s.furthest >= _finishedPct);
    if (finished) {
      s.pct = max(s.pct, _finishedPct);
      _scrobble('stop', s, finished: true);
    } else if (s.playingThere && s.pct >= 1) {
      _scrobble('stop', s); // unfinished: kept as a resume point
    }
  }

  static void _scrobble(String action, _Session s, {bool finished = false, TrackerId? only}) {
    for (final id in _scrobbling) {
      if (only == null || id == only) unawaited(_scrobbleOne(id, action, s, finished));
    }
  }

  static Future<void> _scrobbleOne(TrackerId id, String action, _Session s, bool finished) async {
    var pct = s.pct;
    // Trakt counts anything stopped (or paused) at 80% or more as watched; VyseTV's point is
    // 95%, so short of finished it hears 79.9 at most
    if (id == TrackerId.trakt && !finished && pct >= 80) pct = 79.9;
    if (action != 'start' && pct < 1) return; // under 1% Trakt refuses it, and it means nothing
    try {
      if (id == TrackerId.trakt) {
        final play = await TraktTracker.scrobble(action, s.ref, pct);
        if (play != null) unawaited(TraktTracker.rememberPlay(s.ref.key, play));
      } else {
        await SimklTracker.scrobble(action, s.ref, pct);
      }
      if (finished) {
        final w = Outbox.find(id, 'watched', s.ref.itemKey);
        if (w != null) Outbox.remove(w);
        _set(id, (st) => st.copyWith(lastSync: DateTime.now(), clearNote: true));
        _counts();
      }
    } on TrackerAuthException {
      Outbox.holdForAuth(id);
      _set(id, (st) => st.copyWith(reconnect: true));
    } on TrackerSkipException {
      // not matched there: a finished one needn't go through history either
      if (!finished) return;
      final w = Outbox.find(id, 'watched', s.ref.itemKey);
      if (w != null) Outbox.remove(w);
      _set(id, (st) => st.copyWith(unmatched: st.unmatched + 1));
      _counts();
    } catch (_) {
      // live calls aren't retried; a finished one goes through history instead, right away
      if (!finished) return;
      final w = Outbox.find(id, 'watched', s.ref.itemKey);
      if (w != null) {
        Outbox.now(w);
        unawaited(_pump());
      }
    }
  }

  static DateTime _minute(DateTime t) => DateTime.utc(t.toUtc().year, t.toUtc().month, t.toUtc().day, t.toUtc().hour, t.toUtc().minute);

  // ── what you change here ──

  /// My List's + / ✓ buttons: toggles it, and tells Simkl / Trakt.
  static void myListToggle(Media m) {
    MyList.toggle(m);
    _listChanged(m, MyList.has(m));
  }

  /// Taking titles off My List here.
  static void myListRemove(Set<String> keys) {
    final gone = [for (final s in MyList.items.value) if (keys.contains(s.media.key)) s.media];
    MyList.removeAll(keys);
    for (final m in gone) {
      _listChanged(m, false);
    }
  }

  static void _listChanged(Media m, bool added) {
    var queued = false;
    for (final id in _scrobblers) {
      if (!_live(id) || !_listEnabled(id)) continue;
      _queue(id, added ? 'listAdd' : 'listRemove', m.key, {'ref': MediaRef.whole(m).toJson()});
      queued = true;
    }
    if (!queued) return;
    _counts();
    unawaited(_pump());
  }

  /// A title removed from History here (call after removing it). Only with that switch on.
  static void historyRemoved(Media m) {
    var queued = false;
    for (final id in _scrobblers) {
      if (!_live(id) || !_historyEnabled(id)) continue;
      _queue(id, 'historyRemove', m.key, {'ref': MediaRef.whole(m).toJson()});
      queued = true;
    }
    if (!queued) return;
    _counts();
    unawaited(_pump());
  }

  // ── sending ──

  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final now = DateTime.now();
        final due = Outbox.items.where((i) => !i.waitingAuth && !i.nextAt.isAfter(now)).toList()
          ..sort((a, b) => a.nextAt.compareTo(b.nextAt));
        if (due.isEmpty) break;
        await _deliver(due.first);
      }
    } finally {
      _pumping = false;
      _counts();
      _schedule();
    }
  }

  static void _schedule() {
    _timer?.cancel();
    final waiting = Outbox.items.where((i) => !i.waitingAuth).map((i) => i.nextAt).toList()..sort();
    if (waiting.isEmpty) return;
    var d = waiting.first.difference(DateTime.now());
    if (d < Duration.zero) d = Duration.zero;
    _timer = Timer(d, () => unawaited(_pump()));
  }

  static Future<void> _deliver(OutboxItem item) async {
    final id = item.service;
    try {
      final ref = MediaRef.fromJson(item.data['ref']);
      switch ((id, item.kind)) {
        case (TrackerId.anilist, 'anime'):
          final t = await TokenStore.read(id);
          if (t == null || (t.refresh == null && t.expiresWithin(Duration.zero))) throw const TrackerAuthException();
          await AniListTracker.applyEpisode(t, mediaId: _int(item.data['a']), episode: _int(item.data['e']), countRewatches: AppSettings.trackRewatches.value);
        case (TrackerId.simkl, 'watched') when ref != null:
          await SimklTracker.addHistory(ref, DateTime.tryParse('${item.data['at']}') ?? item.created);
        case (TrackerId.simkl, 'listAdd') when ref != null:
          await SimklTracker.listAdd(ref);
        case (TrackerId.simkl, 'listRemove') when ref != null:
          await SimklTracker.listRemove(ref);
        case (TrackerId.simkl, 'historyRemove') when ref != null:
          await SimklTracker.historyRemove(ref);
        case (TrackerId.trakt, 'watched') when ref != null:
          await TraktTracker.addHistory(ref, DateTime.tryParse('${item.data['at']}') ?? item.created);
        case (TrackerId.trakt, 'listAdd') when ref != null:
          await TraktTracker.watchlist(ref, add: true);
        case (TrackerId.trakt, 'listRemove') when ref != null:
          await TraktTracker.watchlist(ref, add: false);
        case (TrackerId.trakt, 'historyRemove'):
          await TraktTracker.removePlays(item.key);
        case _:
          break; // nothing this build knows how to send
      }
      Outbox.remove(item);
      _set(id, (s) => s.copyWith(lastSync: DateTime.now(), reconnect: false, clearNote: true));
    } on TrackerAuthException {
      Outbox.holdForAuth(id);
      _set(id, (s) => s.copyWith(reconnect: true, clearNote: true));
    } on TrackerRetryException catch (e) {
      Outbox.later(item, after: e.after);
      _set(id, (s) => s.copyWith(note: e.message));
    } on TrackerSkipException catch (e) {
      Outbox.remove(item);
      if (e.unmatched) _set(id, (s) => s.copyWith(unmatched: s.unmatched + 1));
      if (e is TraktLimitException) _set(id, (s) => s.copyWith(note: e.message));
    } catch (_) {
      // offline, or the connection dropped
      Outbox.later(item);
      _set(id, (s) => s.copyWith(note: 'Offline'));
    }
  }

  static int _int(Object? v) => (v as num).toInt();

  static void _counts() {
    final all = {...states.value};
    for (final id in TrackerId.values) {
      all[id] = (all[id] ?? const TrackerState()).copyWith(pending: Outbox.count(id));
    }
    states.value = all;
  }

  // ── connecting ──

  static Future<void> _open(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw const LoopbackException("Couldn't open your browser");
    }
  }

  /// Opens a page in the browser (the Simkl / Trakt code page).
  static Future<void> openPage(Uri url) => _open(url);

  /// Signs in to AniList in the browser; it comes back to the app by itself. Returns the name.
  static Future<String> connectAniList() async {
    final cid = TrackerKeys.anilistClientId;
    final q = await LoopbackAuth.start('anilist', fragment: true, openBrowser: () => _open(AniListTracker.authorizeUrl(cid)));
    final token = q['access_token'];
    if (token == null || token.isEmpty) throw const LoopbackException("AniList didn't send a sign-in back");
    return _connected(TrackerId.anilist, await AniListTracker.finishSignIn(token, cid));
  }

  /// The page where AniList shows a token to copy (for [connectAniListToken]).
  static Future<void> openAniListTokenPage() => _open(AniListTracker.authorizeUrl(TrackerKeys.anilistPinClientId));

  /// Signs in to AniList with a token copied from its page.
  static Future<String> connectAniListToken(String token) async =>
      _connected(TrackerId.anilist, await AniListTracker.finishSignIn(token, TrackerKeys.anilistPinClientId));


  /// Simkl: a code to enter at simkl.com/pin ([onCode]), then waits for it to be approved.
  static Future<String> connectSimkl({required void Function(DeviceCode code) onCode, required bool Function() cancelled}) async {
    final code = await SimklTracker.deviceCode();
    onCode(code);
    final t = await SimklTracker.waitForApproval(code, cancelled: cancelled);
    return _connected(TrackerId.simkl, t);
  }

  /// Trakt: a code to enter on Trakt's activation page ([onCode]), then waits for approval.
  static Future<String> connectTrakt({required void Function(DeviceCode code) onCode, required bool Function() cancelled}) async {
    final code = await TraktTracker.deviceCode();
    onCode(code);
    final t = await TraktTracker.waitForApproval(code, cancelled: cancelled);
    return _connected(TrackerId.trakt, t);
  }

  static Future<String> _connected(TrackerId id, TrackerToken t) async {
    await TokenStore.write(id, t);
    Outbox.releaseAuth(id);
    _set(
      id,
      (s) => s.copyWith(
        connected: true,
        userName: t.userName,
        reconnect: false,
        clearNote: true,
        expiresSoon: id == TrackerId.anilist && t.expiresWithin(const Duration(days: 14)),
      ),
    );
    unawaited(_pump());
    return t.userName;
  }

  /// Stops a browser sign-in that's waiting.
  static void cancelSignIn() => LoopbackAuth.cancel();

  /// Forgets the sign-in on this device and drops its waiting updates. Simkl's and Trakt's are
  /// ended on their side too; AniList has no way to do that from an app (it
  /// can be removed on their site).
  static Future<void> disconnect(TrackerId id) async {
    final t = await TokenStore.read(id);
    if (id == TrackerId.simkl && t != null) unawaited(SimklTracker.revoke(t));
    if (id == TrackerId.trakt && t != null) unawaited(TraktTracker.revoke(t));
    await TokenStore.delete(id);
    await LibraryImport.forget(id);
    Outbox.removeService(id);
    if (_scrobblers.contains(id) && _scrobbling.where((x) => x != id).isEmpty) {
      for (final s in _sessions.values) {
        s.timer?.cancel();
      }
      _sessions.clear();
    }
    _set(id, (s) => TrackerState(configured: s.configured));
  }
}
