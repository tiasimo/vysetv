import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/music/music_track.dart';
import '../music_player.dart';
import '../tmdb.dart' show Media;
import 'watch_party.dart';

/// Listening together in your room, on the watch party's channel: the host's music player reports
/// what it's doing, and everyone listening follows it with their own copy of the song, on their
/// own device. Audio never goes through VyseTV.
///
/// Nobody's music starts by surprise: you follow once you open the room ([join]). Pausing without
/// control just steps you out, and [join] brings you back in sync.
class PartyMusic {
  /// You're hearing the room's music.
  static final listening = ValueNotifier<bool>(false);

  static MusicPlayer get _p => MusicPlayer.instance; // made only once a room has music
  static Timer? _tick;
  static StreamSubscription<WatchCommand>? _commands;
  static bool _attached = false;
  static bool _host = false;
  static bool _autoPaused = false;
  static String? _opened; // the song open here, following the host
  static String _sent = ''; // what the room last heard from us
  static double _rate = 1;
  static int _ticks = 0;

  static void start() {
    WatchParty.state.addListener(_changed);
    _changed();
  }

  static void _changed() {
    final s = WatchParty.state.value;
    if (s == null || !s.isMusic) {
      // something else plays in the room now (not just the party ending): the song stops for
      // the host too
      if (_attached) _detach(movedOn: s != null);
      return;
    }
    if (!_attached) _attach();
    _host = s.mine;
    if (s.mine) {
      _p.partyGate = null;
      listening.value = true;
      // back after a restart: pick up the song the room is still on
      if (_p.current == null && _opened == null) _open(s);
    } else {
      _p.partyGate = _gate;
      if (listening.value) _follow();
    }
  }

  static void _attach() {
    _attached = true;
    _p.addListener(_playerChanged);
    _commands = WatchParty.commands.listen(_command);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _second());
  }

  static void _detach({bool movedOn = false}) {
    _attached = false;
    final wasHost = _host;
    _tick?.cancel();
    _commands?.cancel();
    _p.removeListener(_playerChanged);
    _p.partyGate = null;
    _setRate(1);
    final followed = !_host && listening.value;
    listening.value = false;
    _opened = null;
    _sent = '';
    _autoPaused = false;
    WatchParty.wait(false);
    // it was the room's song; the host keeps their own unless the room moved on to something else
    if (followed || (movedOn && wasHost)) unawaited(_p.partyStop());
  }

  /// Start hearing the room's music, in sync.
  static void join() {
    final s = WatchParty.state.value;
    if (s == null || !s.isMusic || s.mine) return;
    listening.value = true;
    _follow();
  }

  static void _stepOut() {
    listening.value = false;
    _p.partyPause();
    WatchParty.wait(false);
  }

  /// Shares what's playing with your room. Throws when the server refuses.
  static Future<void> host() async {
    final t = _p.current;
    if (t == null) return;
    final s = _snapshot(t);
    _sent = _signature(s);
    await WatchParty.hostState(s);
  }

  /// Plays [t] for the room, starting the party if it hasn't started.
  static Future<void> play(MusicTrack t) async {
    await _p.playNow(t);
    if (WatchParty.state.value?.isMusic != true) await host();
  }

  static Future<void> _send(String action, {double? position}) async {
    try {
      await WatchParty.command(action, position: position);
    } catch (_) {}
  }

  /// Your controls while someone else hosts. True means it's been dealt with here.
  static bool _gate(String action, Duration? at) {
    final s = WatchParty.state.value;
    if (s == null) return false;
    switch (action) {
      case 'toggle':
        if (!listening.value) {
          join();
        } else if (WatchParty.canCommand) {
          unawaited(_send(s.playing ? 'pause' : 'play'));
        } else {
          _stepOut();
        }
        return true;
      case 'seek':
        if (WatchParty.canCommand && at != null) unawaited(_send('seek', position: at.inMilliseconds / 1000));
        return true;
      case 'skip':
        return true; // the host's queue
      case 'stop':
        _stepOut();
        _opened = null;
        unawaited(_p.partyStop());
        return true;
      case 'own': // you picked your own song
        listening.value = false;
        _opened = null;
        WatchParty.wait(false);
        return false;
    }
    return false;
  }

  static void _command(WatchCommand c) {
    if (!_host) return;
    switch (c.action) {
      case 'play':
        _p.partyPlay();
      case 'pause':
        _p.partyPause();
      case 'seek':
        if (c.position != null) _p.partySeek(Duration(milliseconds: (c.position! * 1000).round()));
    }
  }

  static void _second() {
    _ticks++;
    final s = WatchParty.state.value;
    if (s == null || !s.isMusic) return;
    if (!s.mine) {
      if (listening.value) _follow();
      return;
    }
    // the room waits for anyone still loading
    final waiting = WatchParty.blocking().isNotEmpty;
    if (waiting && _p.playing && !_autoPaused) {
      _autoPaused = true;
      _p.partyPause();
    } else if (!waiting && _autoPaused) {
      _autoPaused = false;
      _p.partyPlay();
    }
    // a seek here shows up as the clock jumping; a heartbeat every 4 s keeps late joiners close
    final jumped = (s.now - _p.position.value.inMilliseconds / 1000).abs() > 1.2;
    if (jumped || _ticks % 4 == 0) _report();
  }

  static void _playerChanged() {
    if (!_host) return;
    final t = _p.current;
    if (t == null) {
      unawaited(WatchParty.stop()); // the host closed the player
      return;
    }
    final s = _snapshot(t);
    if (_signature(s) != _sent) _report();
  }

  /// The song, whether it's playing, and what's next: what's worth telling the room at once.
  static String _signature(WatchState s) => '${s.song?.id}|${s.playing}|${s.upNext.map((x) => x.id).join(',')}';

  static void _report() {
    final t = _p.current;
    if (t == null) return;
    final s = _snapshot(t);
    _sent = _signature(s);
    unawaited(WatchParty.report(s));
  }

  static WatchState _snapshot(MusicTrack t) {
    PartySong song(MusicTrack x) => PartySong(id: x.id, title: x.title, artist: x.artist, album: x.album, cover: x.coverUrl, seconds: x.durationSeconds);
    var next = _p.upNext.take(5).map(song).toList();
    WatchState make() => WatchState(
      media: Media(id: _number(t.id), title: t.title, isTv: false, posterPath: t.coverUrl, backdropPath: t.coverUrl),
      song: song(t),
      track: t.toJson(),
      upNext: next,
      position: _p.position.value.inMilliseconds / 1000,
      playing: _p.playing && !_p.buffering && !_p.resolving,
      by: WatchParty.me,
    );
    var s = make();
    if (jsonEncode(s.toJson()).length > 7000) {
      next = const []; // the server takes 8000 at most
      s = make();
    }
    return s;
  }

  /// A song's id as the number the party's title slot wants (FNV-1a, never zero).
  static int _number(String id) {
    var h = 2166136261;
    for (final c in id.codeUnits) {
      h = ((h ^ c) * 16777619) & 0x7fffffff;
    }
    return h == 0 ? 1 : h;
  }

  static Future<void> _open(WatchState s) async {
    final raw = s.track;
    if (raw == null) return;
    _opened = s.song?.id;
    try {
      await _p.partyOpen(MusicTrack.fromJson(raw));
    } catch (_) {
      _opened = null;
    }
  }

  static void _setRate(double r) {
    if (r == _rate) return;
    _rate = r;
    _p.partyRate(r);
  }

  /// Follows the host: the song, play/pause, then the position. Music is less forgiving than a
  /// film, so small gaps close by playing 4% faster or slower and anything over 1.5 s jumps.
  static void _follow() {
    final s = WatchParty.state.value;
    if (s == null || !s.isMusic || s.mine) return;
    if (s.song?.id != _opened) {
      WatchParty.wait(true);
      unawaited(_open(s));
      return;
    }
    final loading = _p.resolving || _p.buffering;
    WatchParty.wait(loading);
    if (loading || _p.current == null) return;
    if (s.playing != _p.playing) s.playing ? _p.partyPlay() : _p.partyPause();
    final diff = s.now + .05 - _p.position.value.inMilliseconds / 1000; // > 0: behind the host
    if (s.playing ? diff.abs() > 1.5 : diff.abs() > .5) {
      _setRate(1);
      _p.partySeek(Duration(milliseconds: ((s.now + .05) * 1000).round()));
    } else if (s.playing && diff.abs() > .12) {
      _setRate(diff > 0 ? 1.04 : .96);
    } else {
      _setRate(1);
    }
  }
}
