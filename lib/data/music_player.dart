import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import '../core/music_log.dart';
import '../mpv/mpv.dart';

import '../models/music/music_track.dart';
import '../services/music/music_service.dart';
import 'app_settings.dart';
import 'audio_focus.dart';
import 'music/music_library.dart';
import 'music/yt_music.dart';

enum LoopMode { off, all, one }

/// The app-wide music queue and player. Listen for queue / play state; [position] ticks separately
/// so the whole UI doesn't rebuild several times a second.
class MusicPlayer extends ChangeNotifier {
  MusicPlayer._() {
    _player.streams.playing.listen((v) {
      playing = v;
      notifyListeners();
    });
    _player.streams.buffering.listen((v) {
      buffering = v;
      notifyListeners();
    });
    _player.streams.position.listen((p) {
      position.value = p;
      if (MusicLog.enabled && !_logSound && p > const Duration(milliseconds: 400)) {
        _logSound = true;
        MusicLog.line('  sound   after ${_logClock.elapsedMilliseconds}ms');
      }
    });
    _player.streams.duration.listen((d) {
      if (d > Duration.zero) duration.value = d;
    });
    _player.streams.completed.listen((done) {
      if (!done) return;
      final at = position.value, len = duration.value;
      MusicLog.line('  ended   at ${fmtClock(at)} of ${fmtClock(len)}');
      // "over" with a good part of the song unplayed: the connection was cut, not the song
      if (_started && len > const Duration(seconds: 30) && len - at > const Duration(seconds: 12) && at < len * .9) {
        _trouble('it stopped at ${fmtClock(at)} of ${fmtClock(len)}', ended: true);
      } else {
        _onCompleted();
      }
    });
    // mpv gave up on the address: refused, expired, or the connection changed under it
    _player.streams.error.listen((e) => _trouble('mpv: ${e.message}${e.cause == null ? '' : ' (${e.cause})'}'));
    // the address answered: this song is fine, and so is the connection
    _player.streams.fileLoaded.listen((_) {
      MusicLog.line('  loaded  after ${_logClock.elapsedMilliseconds}ms');
      _started = true;
      _failStreak = 0;
    });
    if (MusicLog.enabled) {
      MusicLog.line('──────── Lorewatch started, music log on ────────');
      // what mpv and ffmpeg say about the address: refusals (403), unknown formats, dead links
      _player.streams.log.listen((l) {
        if (l.level.index <= PlayerLogLevel.warn.index || l.prefix == 'ffmpeg' || l.prefix == 'cplayer' || l.prefix.startsWith('stream')) {
          MusicLog.line('  mpv     ${l.level.name} [${l.prefix}] ${MusicLog.clip(l.text)}');
        }
      });
      _player.streams.fileLoadFailed.listen((_) => MusicLog.line('  ERROR   mpv could not load the address'));
    }
  }

  // The trouble log (core/music_log.dart): a clock from the moment a song is asked for, and
  // whether its sound has been noted yet.
  final _logClock = Stopwatch();
  bool _logSound = true;
  bool _logLevelSet = false;

  // ── keeping a song going (see [_trouble] and [_giveUp]) ──

  /// Whether the song on now got as far as its address answering.
  bool _started = false;

  /// Fresh addresses asked for the song on now after it broke.
  int _retries = 0;

  /// Songs in a row that would not start. At three the queue stops, rather than asking for
  /// every song left in it: a burst of look-ups is what makes YouTube refuse a device.
  int _failStreak = 0;

  /// You paused it (or something that took the sound did): a break is then mended when play is
  /// pressed, not behind your back.
  bool _userPaused = false;

  /// The address on now is known dead, or past [_expires]: play asks for a fresh one.
  bool _stale = false;

  /// When the address on now stops being served (YouTube's last about six hours).
  DateTime? _expires;
  DateTime _lastAsk = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _addressDead => _stale || (_expires != null && DateTime.now().isAfter(_expires!.subtract(const Duration(minutes: 1))));

  static DateTime? _expiryOf(String url) {
    final s = int.tryParse(Uri.tryParse(url)?.queryParameters['expire'] ?? '');
    return s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
  }

  static final instance = MusicPlayer._();

  final _player = Player.audio();
  final position = ValueNotifier(Duration.zero);
  final duration = ValueNotifier(Duration.zero);

  List<MusicTrack> queue = [];
  List<MusicTrack> _original = [];
  int index = -1;
  bool playing = false;
  bool buffering = false;
  bool resolving = false;
  bool shuffle = false;
  LoopMode repeat = LoopMode.off;
  double volume = 100;
  String? error;
  int _generation = 0;
  final _lyrics = <String, Future<LyricsData>>{};

  /// Songs that joined the queue on their own (autoplay, radio), not picked by you.
  final autoIds = <String>{};
  bool _extending = false;

  /// In someone else's listening party, your controls go here first (true: dealt with), so the
  /// mini player and the full player act for the room instead of drifting away from it.
  bool Function(String action, Duration? at)? partyGate;
  bool _gated(String action, [Duration? at]) => partyGate?.call(action, at) ?? false;

  MusicTrack? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get hasNext => index < queue.length - 1 || repeat == LoopMode.all;
  List<MusicTrack> get upNext => index < 0 ? const [] : queue.sublist(index + 1);

  Future<LyricsData> lyricsFor(MusicTrack t) => _lyrics.putIfAbsent(t.id, () => MusicService.instance.fetchLyrics(t));

  /// Replaces the queue with [tracks] and starts at [start].
  Future<void> playQueue(List<MusicTrack> tracks, {int start = 0, bool shuffled = false}) async {
    if (tracks.isEmpty) return;
    _gated('own');
    _failStreak = 0;
    autoIds.clear();
    _original = [...tracks];
    queue = [...tracks];
    index = start.clamp(0, tracks.length - 1);
    shuffle = shuffled;
    if (shuffled) _shuffleRest(fromStart: true);
    await _playCurrent();
  }

  /// Plays [t] now, keeping the rest of the queue after it.
  Future<void> playNow(MusicTrack t) async {
    if (queue.isEmpty) return playQueue([t]);
    queue.insert(index + 1, t);
    _original.add(t);
    index++;
    _failStreak = 0;
    await _playCurrent();
  }

  void addNext(MusicTrack t) {
    if (queue.isEmpty) {
      playQueue([t]);
      return;
    }
    queue.insert(index + 1, t);
    _original.add(t);
    notifyListeners();
  }

  void addToQueue(MusicTrack t) {
    if (queue.isEmpty) {
      playQueue([t]);
      return;
    }
    queue.add(t);
    _original.add(t);
    notifyListeners();
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= queue.length) return;
    final t = queue.removeAt(i);
    _original.remove(t);
    if (i < index) index--;
    notifyListeners();
  }

  /// [to] is the final position, already adjusted for the removal (ReorderableListView.onReorderItem).
  void reorder(int from, int to) {
    if (from <= index || to <= index || to >= queue.length) return;
    queue.insert(to, queue.removeAt(from));
    notifyListeners();
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= queue.length || _gated('skip')) return;
    index = i;
    _failStreak = 0;
    await _playCurrent();
  }

  /// [auto]: the player moving on by itself past a song that wouldn't play (it keeps count).
  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty || _gated('skip')) return;
    if (!auto) _failStreak = 0;
    if (index < queue.length - 1) {
      index++;
    } else if (repeat == LoopMode.all) {
      index = 0;
    } else {
      return;
    }
    await _playCurrent();
  }

  Future<void> previous() async {
    if (_gated('skip')) return;
    if (position.value > const Duration(seconds: 3) || index <= 0) {
      await _player.seek(Duration.zero);
      return;
    }
    index--;
    _failStreak = 0;
    await _playCurrent();
  }

  Future<void> toggle() async {
    if (_gated('toggle') || current == null) return;
    if (!playing) {
      AudioFocus.claim(this, pause);
      // paused past the life of its address, or it broke while paused: a fresh one, same second
      if (_addressDead && !resolving) {
        _retries = 0;
        return _playCurrent(resume: position.value, again: true);
      }
    }
    _userPaused = playing;
    await _player.playOrPause();
  }

  void pause() {
    _userPaused = true;
    _player.pause();
  }

  Future<void> seek(Duration d) async {
    if (!_gated('seek', d)) await _player.seek(d);
  }

  // The party itself, past the gate.

  /// Opens the room's song on its own.
  Future<void> partyOpen(MusicTrack t) async {
    _original = [t];
    queue = [t];
    index = 0;
    _failStreak = 0;
    await _playCurrent();
  }

  Future<void> partyPlay() async {
    AudioFocus.claim(this, pause);
    if (_addressDead && current != null && !resolving) {
      _retries = 0;
      return _playCurrent(resume: position.value, again: true);
    }
    _userPaused = false;
    await _player.play();
  }

  Future<void> partyPause() {
    _userPaused = true;
    return _player.pause();
  }
  Future<void> partySeek(Duration d) => _player.seek(d);
  Future<void> partyRate(double rate) => _player.setRate(rate);

  Future<void> setVolume(double v) async {
    volume = v.clamp(0, 100);
    notifyListeners();
    await _player.setVolume(volume);
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    if (shuffle) {
      _shuffleRest();
    } else {
      final t = current;
      queue = [..._original];
      index = t == null ? -1 : queue.indexOf(t);
    }
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = LoopMode.values[(repeat.index + 1) % LoopMode.values.length];
    notifyListeners();
  }

  /// Plays [t], then songs like it (YouTube Music's radio for it).
  Future<void> startRadio(MusicTrack t) async {
    await playQueue([t]);
    await _extend(force: true);
  }

  /// Plays a YouTube Music playlist's songs as a radio would (an artist's Shuffle or Radio).
  Future<void> playWatchPlaylist(String playlistId) async {
    try {
      final items = await YtMusic.instance.watchPlaylist(playlistId);
      final tracks = ytTracks(items);
      if (tracks.isNotEmpty) await playQueue(tracks);
    } catch (_) {}
  }

  /// Near the end of the queue, with Autoplay on: more songs like the last one.
  Future<void> _extend({bool force = false}) async {
    final last = queue.isEmpty ? null : queue.last;
    if (last == null || _extending || partyGate != null) return;
    if (!force && (!AppSettings.musicAutoplay.value || repeat != LoopMode.off || index < queue.length - 2)) return;
    _extending = true;
    try {
      final have = {for (final t in queue) t.id};
      final more = [for (final t in ytTracks(await YtMusic.instance.radio(last.id))) if (have.add(t.id)) t].take(25).toList();
      if (more.isEmpty || queue.isEmpty) return;
      queue.addAll(more);
      _original.addAll(more);
      autoIds.addAll(more.map((t) => t.id));
      notifyListeners();
    } catch (_) {
    } finally {
      _extending = false;
    }
  }

  /// Stops and clears everything (the mini player's close button).
  Future<void> stop() async {
    if (_gated('stop')) return;
    await partyStop();
  }

  Future<void> partyStop() async {
    _generation++;
    await _player.stop();
    queue = [];
    _original = [];
    autoIds.clear();
    index = -1;
    AudioFocus.release(this);
    notifyListeners();
  }

  void _shuffleRest({bool fromStart = false}) {
    final t = current;
    final rest = [...queue]..remove(t);
    rest.shuffle(math.Random());
    queue = [?t, ...rest];
    index = t == null ? -1 : 0;
  }

  void _onCompleted() {
    if (resolving) return;
    if (repeat == LoopMode.one) {
      _player.seek(Duration.zero).then((_) => _player.play());
    } else if (hasNext) {
      next();
    } else if (AppSettings.musicAutoplay.value && partyGate == null) {
      _extend(force: true).then((_) {
        if (index < queue.length - 1) next();
      });
    }
  }

  /// The stream lookup with anything it prints on the way copied into the trouble log.
  Future<MusicStreamResult?> _loggedLookup(MusicTrack t) => runZoned(
        () => MusicService.instance.getAudioStream(t),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, text) {
            MusicLog.line('  said    ${MusicLog.clip(text, 400)}');
            parent.print(zone, text);
          },
        ),
      );

  /// The stream for [t]. The lookup gets twenty seconds, and one more go a moment later if the
  /// network failed it. An answer of "nothing" isn't asked twice: the same question right away
  /// gets the same answer, and repeated look-ups are what make YouTube refuse a device.
  Future<MusicStreamResult?> _lookup(MusicTrack t, int gen) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await (MusicLog.enabled ? _loggedLookup(t) : MusicService.instance.getAudioStream(t)).timeout(const Duration(seconds: 20));
      } catch (e) {
        MusicLog.line('  lookup  try $attempt failed at ${_logClock.elapsedMilliseconds}ms: ${MusicLog.clip('$e', 300)}');
        if (attempt == 2 || gen != _generation) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (gen != _generation) rethrow;
      }
    }
  }

  /// The song on now broke: mpv gave up on its address (refused, expired after its six hours,
  /// or tied to a connection that has since changed), or it "ended" well short of its length.
  /// A fresh address is asked for and the song carries on from the same second: twice for a
  /// song that had started, once for one that never did. After that it's given up.
  void _trouble(String why, {bool ended = false}) {
    final t = current;
    if (t == null) return;
    if (resolving) {
      // the new address failed before its open even returned: dealt with once it has
      if (_openCalled) _pendingTrouble = why;
      return;
    }
    MusicLog.line('  BROKE   ${t.id}: $why  (started=$_started tries=$_retries paused=$_userPaused)');
    if (_userPaused) {
      _stale = true; // mended when play is pressed
      return;
    }
    if (_retries < (_started ? 2 : 1)) {
      _retries++;
      unawaited(_playCurrent(resume: _started ? position.value : null, again: true));
    } else if (ended) {
      _onCompleted(); // it really does end there
    } else {
      _giveUp(t, _generation);
    }
  }

  /// [t] won't play. On to the next song, unless the last few wouldn't either: then it isn't
  /// the songs (no connection, or YouTube refusing this device for now), and the queue stops
  /// there instead of running through everything left in it.
  void _giveUp(MusicTrack t, int gen) {
    _failStreak++;
    if (_failStreak >= 3) {
      error = "The last $_failStreak songs wouldn't play. Check your connection, or try again in a few minutes.";
    } else {
      error = "Couldn't play ${t.title}";
      if (index < queue.length - 1) {
        // a little longer each time
        unawaited(Future<void>.delayed(Duration(milliseconds: 800 * _failStreak), () {
          if (gen == _generation) next(auto: true);
        }));
      }
    }
    MusicLog.line('  GAVE UP ${t.id}  (in a row: $_failStreak${_failStreak >= 3 ? ', the queue stops here' : ''})');
    notifyListeners();
  }

  bool _openCalled = false;
  String? _pendingTrouble;

  /// Starts the song the queue is on. [again]: the same song once more after it broke (the
  /// count of tries is kept); with [resume], from that second instead of the top.
  Future<void> _playCurrent({Duration? resume, bool again = false}) async {
    final t = current;
    if (t == null) return;
    final gen = ++_generation;
    AudioFocus.claim(this, pause);
    error = null;
    resolving = true;
    _started = false;
    _stale = false;
    _userPaused = false;
    _openCalled = false;
    _pendingTrouble = null;
    if (!again) _retries = 0;
    if (resume == null) {
      position.value = Duration.zero;
      duration.value = Duration(seconds: t.durationSeconds);
    }
    notifyListeners();
    final sinceLast = DateTime.now().difference(_lastAsk);
    _lastAsk = DateTime.now();
    if (MusicLog.enabled) {
      _logClock
        ..reset()
        ..start();
      _logSound = true; // nothing to note until the new address is opened
      MusicLog.line('${again ? 'AGAIN ' : 'PLAY  '}  ${t.id}  "${t.title}" by ${t.artist}  ${t.durationSeconds}s  (${index + 1} of ${queue.length})${resume == null ? '' : '  from ${fmtClock(resume)}'}');
      if (!_logLevelSet) {
        _logLevelSet = true;
        unawaited(_player.setLogLevel('info').catchError((Object _) {}));
      }
    }
    try {
      await _player.pause();
      // skipping fast through a queue: only the song you stop on is looked up
      if (sinceLast < const Duration(milliseconds: 700)) {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (gen != _generation) return;
      }
      final stream = await _lookup(t, gen);
      if (gen != _generation) {
        MusicLog.line('  dropped ${t.id}: another song was picked while this one was looked up');
        return;
      }
      final url = stream?.url ?? t.previewUrl;
      if (MusicLog.enabled) {
        MusicLog.line('  lookup  ${_logClock.elapsedMilliseconds}ms  ${stream == null ? 'NOTHING came back' : MusicLog.url(stream.url)}');
        if (stream == null) MusicLog.line('  preview ${MusicLog.url(t.previewUrl)}');
        if (stream?.userAgent != null) MusicLog.line('  agent   ${MusicLog.clip(stream?.userAgent, 120)}');
      }
      if (url == null || url.isEmpty) throw StateError('No stream for ${t.title}');
      final ua = stream?.userAgent;
      _expires = _expiryOf(url);
      _openCalled = true;
      await _player.open(Media(url, headers: ua == null ? null : {'User-Agent': ua}, start: resume));
      if (MusicLog.enabled) {
        MusicLog.line('  opened  ${_logClock.elapsedMilliseconds}ms');
        _logSound = false;
        // no sound ten seconds on: say what the player is doing instead
        unawaited(Future.delayed(const Duration(seconds: 10), () {
          if (gen == _generation && !_logSound) {
            MusicLog.line('  SILENT  ${t.id} ten seconds after opening: playing=$playing buffering=$buffering at ${fmtClock(position.value)}');
          }
        }));
      }
      if (gen == _generation && !again) {
        MusicLibrary.recordPlay(t);
        unawaited(_extend());
      }
    } catch (e, st) {
      if (MusicLog.enabled) {
        MusicLog.line('  FAILED  ${t.id} after ${_logClock.elapsedMilliseconds}ms: ${MusicLog.clip('$e', 400)}');
        for (final l in '$st'.split('\n').take(8)) {
          if (l.trim().isNotEmpty) MusicLog.line('          $l');
        }
      }
      if (gen != _generation) return;
      _pendingTrouble = null;
      // Skip ahead rather than stalling the queue on one bad track (see [_giveUp] for when not).
      _giveUp(t, gen);
    } finally {
      if (gen == _generation) {
        resolving = false;
        notifyListeners();
        final broke = _pendingTrouble;
        _pendingTrouble = null;
        if (broke != null) _trouble(broke);
      }
    }
  }
}

String fmtClock(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
