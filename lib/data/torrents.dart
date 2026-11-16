import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path_provider/path_provider.dart';
import 'package:torrserver_flutter/torrserver_flutter.dart';

import 'app_settings.dart';
import 'torrent_file_ask.dart';
import 'torrent_file_pick.dart';

export 'torrent_file_pick.dart' show EpisodeNotInTorrent;

/// Torrents played on this device: our own TorrServer engine (packages/torrserver_flutter) runs
/// next to the app, fetches the pieces from peers in the order the player reads them, and hands
/// the player a local address (127.0.0.1) to stream from, with seeking. Nothing goes through a
/// server of ours. Started the first time a torrent plays.
///
/// It never outlives VyseTV and keeps nothing: on Windows the engine is tied to VyseTV's process
/// (a job object Windows kills with it, however VyseTV ends: closed, crashed or ended in Task
/// Manager); on Android the system takes an app's helper processes with it. What it downloads
/// lives only in its memory; a torrent is removed when its player closes, and the engine's
/// folder is wiped when it stops and again before it starts (after a crash).
class Torrents {
  static Future<TorrServerController>? _starting;
  static const _channel = MethodChannel('torrserver_flutter');
  static final _playing = <String>{}; // info hashes open in a player

  /// The engine only ever starts once you've turned on P2P streaming (or allowed it when asked).
  static bool get allowed => AppSettings.p2pStreaming.value;

  /// Where the engine runs: Windows, Android, macOS and Linux, and on iPhone and iPad when the
  /// build carries it (there it is a framework inside the app, and a build can be made without
  /// it: [initialize] asks).
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isAndroid || Platform.isMacOS || Platform.isLinux || (Platform.isIOS && _iosEngine));

  static bool _iosEngine = false;

  /// iPhone and iPad: asks once, as the app starts, whether this build has the engine in it.
  /// Without it torrents stay hidden, as they were before iOS had one. Nothing to do elsewhere.
  static Future<void> initialize() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      _iosEngine = await _channel.invokeMethod<bool>('hasEngine') ?? false;
    } catch (_) {
      _iosEngine = false;
    }
  }

  /// Phones and tablets get a smaller cache and fewer connections than desktops. On iOS the
  /// engine shares the app's own memory, and iOS ends an app that takes too much.
  static bool get _phone => Platform.isAndroid || Platform.isIOS;

  static Future<TorrServerController> _ready() => _starting ??= () async {
    final c = createTorrServerController();
    final dir = await _dataDir();
    await _wipe(dir, keepPid: true); // whatever a crashed run left (the old process's id stays, so it's killed)
    try {
      await c.start(dataDir: dir);
    } catch (_) {
      _starting = null; // try again next time
      rethrow;
    }
    _controller = c;
    // dies with VyseTV, however VyseTV ends
    if (Platform.isWindows && c is TorrServerControllerSubprocess && c.pid != null) {
      try {
        await const MethodChannel('vyse/process').invokeMethod<bool>('adopt', c.pid);
      } catch (_) {}
      // and a hidden watcher, for the rare launcher whose own job keeps the one above from
      // taking: when VyseTV's process is gone, it ends the engine and empties its folder
      try {
        final dirPath = dir.path.replaceAll("'", "''");
        final w = await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-Command',
            'Wait-Process -Id $pid -ErrorAction SilentlyContinue; '
                'Stop-Process -Id ${c.pid} -Force -ErrorAction SilentlyContinue; '
                'Start-Sleep -Milliseconds 500; '
                "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue '$dirPath\\*'",
          ],
        );
        // (a detached PowerShell quits at once; a normal child outlives VyseTV all the same)
        unawaited(w.stdout.drain<void>());
        unawaited(w.stderr.drain<void>());
      } catch (_) {}
    }
    try {
      _exit ??= AppLifecycleListener(
        onDetach: () => unawaited(shutdown()),
        onExitRequested: () async {
          await shutdown();
          return AppExitResponse.exit;
        },
      );
    } catch (_) {
      // no Flutter app around (a test): the job object and the next start's wipe still apply
    }
    if (Platform.isIOS) {
      try {
        _resume ??= AppLifecycleListener(onResume: () => unawaited(_checkAlive()));
      } catch (_) {}
    }
    try {
      final s = await c.getSettings();
      await c.setSettings(TorrServerSettings.fromJson({...s.toJson(), ..._fast}));
    } catch (_) {}
    unawaited(_loadTrackers());
    return c;
  }();

  /// TorrServer tuned for streaming as fast as it can:
  /// * a big read-ahead window (most of a large cache), so many pieces ahead of the playhead are
  ///   asked for at once, from many peers;
  /// * playback starts after a small preload (2% of the cache), not half of it;
  /// * up to 300 connections per torrent (150 on phones), DHT, PEX, local peer discovery, uTP
  ///   and UPnP all on, no encryption requirement (it turns peers away);
  /// * extra public trackers on every torrent, uploading on (peers give more to those who give);
  /// * a torrent stays connected two minutes after the player lets go (a pause, a seek back).
  static Map<String, Object> get _fast => {
    // pieces live in memory only, and go when a torrent is dropped
    'UseDisk': false,
    'RemoveCacheOnDrop': true,
    'CacheSize': (_phone ? 256 : 1024) << 20,
    'ReaderReadAHead': 95,
    'PreloadCache': 2,
    'ConnectionsLimit': _phone ? 150 : 300,
    // IPv6 off (TorrServer's default): on networks without working IPv6 the engine spends its
    // slots on peers it can't reach and stalls at a few peers and 0 KB/s. Measured on a large
    // public torrent: with it on, 1.3-2.4 MB/s, nothing for the first 10-16 s, and a stall;
    // off, 4.1-4.8 MB/s and data within ~8 s every time.
    'EnableIPv6': false,
    'RetrackersMode': 1,
    'ResponsiveMode': true,
    'ForceEncrypt': false,
    'DisableTCP': false,
    'DisableUTP': false,
    // iOS: asking the router for a port and looking for peers on the local network both need
    // a permission (and an entitlement a sideloaded app can't have), so neither is tried there
    'DisableUPNP': Platform.isIOS,
    'DisableDHT': false,
    'DisablePEX': false,
    'DisableUpload': false,
    'DownloadRateLimit': 0,
    'UploadRateLimit': 0,
    'EnableLPD': !Platform.isIOS,
    'TorrentDisconnectTimeout': 120,
    'EnableDLNA': false,
    'EnableBonjour': false,
  };

  /// The best-performing public trackers (ngosang/trackerslist, refreshed each start), added to
  /// every torrent; a fixed list when that can't be fetched.
  static List<String> _trackers = const [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker.qu.ax:6969/announce',
    'udp://tracker.dler.org:6969/announce',
    'udp://tracker.theoks.net:6969/announce',
    'udp://opentracker.io:6969/announce',
    'udp://tracker-udp.gbitt.info:80/announce',
    'udp://p4p.arenabg.com:1337/announce',
    'udp://open.tracker.cl:1337/announce',
    'http://tracker.opentrackr.org:1337/announce',
    'udp://tracker.tiny-vps.com:6969/announce',
    'udp://tracker.cyberia.is:6969/announce',
  ];

  static Future<void> _loadTrackers() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final rq = await c.getUrl(Uri.parse('https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt'));
      final r = await rq.close().timeout(const Duration(seconds: 8));
      final text = await r.transform(const SystemEncoding().decoder).join();
      final list = [
        for (final l in const LineSplitter().convert(text))
          if (l.trim().contains('://')) l.trim(),
      ];
      if (list.length >= 5) _trackers = list;
      c.close();
    } catch (_) {}
  }

  /// Starts the engine ahead of time (the sources screen does, once it has torrents), so peers
  /// and the DHT are already warm when one is picked.
  static void warmUp() {
    if (supported && allowed) unawaited(_ready().then((_) {}, onError: (Object _) {}));
  }

  static final _prepared = <String>{};

  // ── downloads ──

  static final _downloading = <String>{}; // torrents a download is reading

  /// A download wants file [fileIndex] (the engine's own number) of [infoHash]. The torrent is
  /// kept in the engine until [downloadDone], whether or not the player lets go of it, and the
  /// local address to read the file from is answered.
  static Future<String> holdForDownload(String infoHash, int fileIndex, {List<String> trackers = const [], String? title}) async {
    if (!allowed) throw StateError('P2P streaming is off');
    final hash = infoHash.toLowerCase();
    final first = _downloading.add(hash) && _playing.isEmpty && _downloading.length == 1;
    final c = await _ready();
    await c.addTorrent(magnet: _magnet(hash, trackers, title), title: title);
    if (first && Platform.isAndroid) {
      unawaited(_channel.invokeMethod<void>('startForegroundService').catchError((Object _) {}));
    }
    return c.streamUrl(hash, fileIndex: fileIndex).toString();
  }

  /// The download of [infoHash] is over: finished, paused or removed.
  static Future<void> downloadDone(String infoHash) async {
    final hash = infoHash.toLowerCase();
    if (!_downloading.remove(hash)) return;
    if (_playing.contains(hash)) return; // the player still has it
    _prepared.remove(hash);
    await _remove(hash);
    if (_playing.isEmpty && _downloading.isEmpty && Platform.isAndroid) {
      unawaited(_channel.invokeMethod<void>('stopForegroundService').catchError((Object _) {}));
    }
  }

  /// The path and size of file [fileIndex] of a torrent the engine has, for naming a download.
  static Future<({String path, int length})?> fileOf(String infoHash, int fileIndex) async {
    final c = await _starting;
    if (c == null) return null;
    try {
      final f = (await c.getTorrent(infoHash.toLowerCase())).fileStats.where((f) => f.id == fileIndex).firstOrNull;
      return f == null ? null : (path: f.path, length: f.length);
    } catch (_) {
      return null;
    }
  }

  /// Starts fetching a torrent's file list before it's picked (hovering or pressing its row).
  static void prepare(String infoHash, {List<String> trackers = const [], String? title}) {
    final hash = infoHash.toLowerCase();
    if (!supported || !allowed || !_prepared.add(hash)) return;
    unawaited(() async {
      try {
        final c = await _ready();
        await c.addTorrent(magnet: _magnet(hash, trackers, title), title: title);
      } catch (_) {
        _prepared.remove(hash);
      }
    }());
  }

  /// A magnet link for [hash], with the addon's trackers and our usual ones, to copy elsewhere.
  static String magnet(String hash, {List<String> trackers = const [], String? title}) => _magnet(hash, trackers, title);

  static String _magnet(String hash, List<String> trackers, String? title) {
    final m = StringBuffer('magnet:?xt=urn:btih:$hash');
    if (title != null) m.write('&dn=${Uri.encodeQueryComponent(title)}');
    for (final t in {...trackers, ..._trackers}) {
      m.write('&tr=${Uri.encodeQueryComponent(t)}');
    }
    return m.toString();
  }

  /// The local address to play [infoHash] from. Which file: the one the addon named
  /// ([filename], else Stremio's 0-based [fileIdx]); with none named and an episode asked for
  /// ([season], [episode], and its [episodeTitle] when known), the file whose name says so;
  /// otherwise the torrent's biggest video (see torrent_file_pick.dart). Waits for the torrent's
  /// file list from peers (up to [timeout]). Throws [EpisodeNotInTorrent] when the torrent has
  /// several videos and none is that episode. With [ask], the torrent's files are listed and
  /// the one picked plays ([TorrentFileNotChosen] when the list is closed).
  static Future<String> open(
    String infoHash, {
    int? fileIdx,
    String? filename,
    List<String> trackers = const [],
    String? title,
    int? season,
    int? episode,
    String? episodeTitle,
    AskTorrentFile? ask,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!allowed) throw StateError('P2P streaming is off');
    final hash = infoHash.toLowerCase();
    // claimed at once, before anything waits: the sources list closing (and letting go of the
    // torrents it only prepared) mustn't take this one
    final first = _playing.add(hash) && _playing.length == 1;
    final c = await _ready();
    // re-added if it was let go meanwhile (adding one already there just returns it)
    await c.addTorrent(magnet: _magnet(hash, trackers, title), title: title);
    if (first && Platform.isAndroid) {
      // keeps the download going while the screen is off or the app is in the background
      unawaited(_channel.invokeMethod<void>('startForegroundService').catchError((Object _) {}));
    }
    // the file list comes once peers have sent the torrent's metadata
    final until = DateTime.now().add(timeout);
    var files = const <TorrentFileStat>[];
    while (files.isEmpty) {
      if (DateTime.now().isAfter(until)) throw TimeoutException('No peers answered');
      try {
        files = (await c.getTorrent(hash)).fileStats;
      } catch (_) {}
      if (files.isEmpty) await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // a magnet link with nothing to say which file: its files are listed and you pick ([ask])
    final pick = ask != null
        ? await chooseTorrentFile<TorrentFileStat>(files, pathOf: (f) => f.path, sizeOf: (f) => f.length, ask: ask)
        : pickTorrentFile<TorrentFileStat>(
            files,
            pathOf: (f) => f.path,
            sizeOf: (f) => f.length,
            idOf: (f) => f.id,
            filename: filename,
            fileIdx: fileIdx,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            torrentName: title,
          );
    final url = c.streamUrl(hash, fileIndex: pick.id).toString();
    await _warm(url, pick.length);
    return url;
  }

  static const _head = 4 << 20, _tail = 6 << 20;

  /// Fetches the first 4 MB and last 6 MB of the file before the player opens it: a player reads the
  /// start, then jumps to the end (an MKV's index, an MP4's moov) before playing. Straight after
  /// a torrent is added those parts may not be there yet, and a player left waiting on them long
  /// enough gives up on the stream, leaving the engine with nothing to download. Up to 90 s;
  /// the player is told to be patient beyond that.
  static Future<void> _warm(String url, int length) async {
    final client = HttpClient();
    Future<void> read(int from, int to) async {
      final rq = await client.getUrl(Uri.parse(url));
      rq.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      await (await rq.close()).drain<void>();
    }

    try {
      await Future.wait([
        read(0, (length < _head ? length : _head) - 1),
        if (length > _head + _tail) read(length - _tail, length - 1),
      ]).timeout(const Duration(seconds: 90));
    } catch (_) {
      // slow swarm: the player opens anyway, and waits
    } finally {
      client.close(force: true);
    }
  }

  /// The subtitle files that came in the torrent (.srt, .ass, .ssa, .vtt), each with the local
  /// address the engine serves it from.
  static Future<List<({String path, String url})>> subtitleFiles(String infoHash) async {
    final c = await _starting;
    if (c == null) return const [];
    final hash = infoHash.toLowerCase();
    try {
      final files = (await c.getTorrent(hash)).fileStats;
      return [
        for (final f in files)
          if (RegExp(r'\.(srt|ass|ssa|vtt)$', caseSensitive: false).hasMatch(f.path)) (path: f.path, url: c.streamUrl(hash, fileIndex: f.id).toString()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// How the torrent is doing (peers, speed), for the player while it buffers.
  static Future<TorrentInfo?> stats(String infoHash) async {
    final c = await _starting;
    if (c == null) return null;
    try {
      return await c.getTorrent(infoHash.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  /// The player is done with [infoHash]: stop downloading it and free its cache.
  static Future<void> release(String infoHash) async {
    final hash = infoHash.toLowerCase();
    _prepared.remove(hash);
    _playing.remove(hash);
    if (_downloading.contains(hash)) return; // a download is still reading it
    await _remove(hash);
    if (_playing.isEmpty && Platform.isAndroid) {
      unawaited(_channel.invokeMethod<void>('stopForegroundService').catchError((Object _) {}));
    }
  }

  /// Torrents started on the sources screen (hovered, pressed) but never played go too.
  static Future<void> forgetPrepared() async {
    final left = _prepared.where((h) => !_playing.contains(h) && !_downloading.contains(h)).toList();
    _prepared.removeAll(left);
    for (final h in left) {
      await _remove(h);
    }
  }

  /// Stops downloading [hash] and throws away everything it fetched.
  static Future<void> _remove(String hash) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.removeTorrent(hash);
    } catch (_) {}
  }

  static TorrServerController? _controller;
  static AppLifecycleListener? _exit;
  static AppLifecycleListener? _resume;

  /// iPhone and iPad: the engine lives inside the app, and iOS freezes the app in the
  /// background and can take its network sockets while it sleeps. Back in front, an engine
  /// that no longer answers is let go, so the next torrent starts a fresh one (without this it
  /// would stay dead until the app was closed and opened again).
  static Future<void> _checkAlive() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.echo().timeout(const Duration(seconds: 3));
    } catch (_) {
      if (!identical(_controller, c)) return; // shut down or replaced meanwhile
      _controller = null;
      _starting = null;
      _playing.clear();
      _prepared.clear();
      _downloading.clear();
      try {
        await c.stop();
      } catch (_) {}
    }
  }

  /// Stops the engine and wipes its folder (VyseTV closing).
  static Future<void> shutdown() async {
    final c = _controller;
    _controller = null;
    _starting = null;
    _playing.clear();
    _prepared.clear();
    _downloading.clear();
    if (c != null) {
      try {
        await c.stop();
      } catch (_) {}
    }
    try {
      await _wipe(await _dataDir(), keepPid: false);
    } catch (_) {}
  }

  static Future<Directory> _dataDir() async {
    try {
      return Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}torrserver_data');
    } catch (_) {
      return Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_torrserver');
    }
  }

  /// Deletes everything in the engine's folder (its database, settings, any cache).
  static Future<void> _wipe(Directory dir, {required bool keepPid}) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (keepPid && e.path.endsWith('torrserver.pid')) continue;
      try {
        await e.delete(recursive: true);
      } catch (_) {
        // still held by a process on its way out
      }
    }
  }
}
