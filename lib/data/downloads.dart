// Downloads: what you saved from the player, to watch later without the internet.
//
// Three kinds, each fetched the way it streams:
//  * a file (an MP4 or MKV link, a debrid link): read over HTTP with the headers its host wants,
//    carrying on from where it stopped when the host allows;
//  * an HLS stream: its playlists and every piece, fetched through the relay exactly as the
//    player's requests are (stream_proxy.dart), and kept as a folder the player opens like a
//    stream;
//  * a torrent: the same file the player was reading, read in full from the torrent engine,
//    which fetches it peer to peer as it's read.
//
// Everything lands in one folder (Downloads/VyseTV on a computer, the app's own folder on a
// phone). The list of them is a small JSON file next to the app's other data.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'net.dart';
import 'stream_proxy.dart';
import 'subtitles.dart' show exactLanguage;
import 'torrents.dart';

enum DownloadKind { file, hls, torrent }

enum DownloadState { queued, running, paused, done, failed }

/// What the player hands over to start a download.
class DownloadRequest {
  const DownloadRequest({
    required this.title,
    required this.kind,
    required this.url,
    this.detail = '',
    this.poster,
    this.headers = const {},
    this.exactHeaders = false,
    this.torrentHash,
    this.torrentFile,
    this.trackers = const [],
    this.torrentTitle,
    this.audioLanguage,
    this.subtitleLanguage,
    this.extension,
  });

  final String title;

  /// A second line: "S01E02 · The name", or the year.
  final String detail;
  final String? poster;
  final DownloadKind kind;

  /// The address that was playing: a file, or the playlist of the quality on screen.
  final String url;
  final Map<String, String> headers;

  /// The relay sends this host only [headers] (a link you pasted), nothing of its own.
  final bool exactHeaders;

  final String? torrentHash;

  /// The engine's own number for the file.
  final int? torrentFile;
  final List<String> trackers;
  final String? torrentTitle;

  /// HLS with its languages in playlists of their own: which sound to take along with the
  /// stream's default ("eng", "English"), and which subtitles. Null: the default only.
  final String? audioLanguage;
  final String? subtitleLanguage;

  /// The file's ending when the address doesn't say ("mkv").
  final String? extension;
}

class DownloadItem {
  DownloadItem._({
    required this.id,
    required this.title,
    required this.detail,
    required this.poster,
    required this.kind,
    required this.url,
    required this.headers,
    required this.exactHeaders,
    required this.torrentHash,
    required this.torrentFile,
    required this.trackers,
    required this.torrentTitle,
    required this.audioLanguage,
    required this.subtitleLanguage,
    required this.path,
    required this.added,
    this.state = DownloadState.queued,
    this.received = 0,
    this.total = 0,
    this.parts = 0,
    this.partsDone = 0,
    this.error,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  final String id;
  final String title;
  final String detail;
  final String? poster;
  final DownloadKind kind;
  final String url;
  final Map<String, String> headers;
  final bool exactHeaders;
  final String? torrentHash;
  final int? torrentFile;
  final List<String> trackers;
  final String? torrentTitle;
  final String? audioLanguage;
  final String? subtitleLanguage;

  /// The finished file, or for an HLS stream its folder.
  final String path;
  final DateTime added;

  DownloadState state;

  /// Bytes on disk so far, and the size when it's known (0: not yet).
  int received;
  int total;

  /// An HLS stream's pieces.
  int parts;
  int partsDone;
  String? error;

  /// Where you stopped watching it.
  int positionMs;
  int durationMs;

  /// Bytes a second, while it runs (not saved).
  double speed = 0;

  bool get isFolder => kind == DownloadKind.hls;

  /// 0 to 1, or null while there's nothing to measure against.
  double? get progress {
    if (state == DownloadState.done) return 1;
    if (kind == DownloadKind.hls) return parts > 0 ? partsDone / parts : null;
    return total > 0 ? (received / total).clamp(0, 1) : null;
  }

  /// The size it will be: known for a file, guessed from the pieces so far for a stream.
  int get expected {
    if (kind != DownloadKind.hls) return total;
    return partsDone > 0 && parts > 0 ? (received / partsDone * parts).round() : 0;
  }

  /// Seconds left at this speed, when that can be told.
  int? get secondsLeft {
    final left = expected - received;
    if (state != DownloadState.running || speed < 1024 || left <= 0) return null;
    return (left / speed).round();
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'detail': detail,
    'poster': ?poster,
    'kind': kind.name,
    'url': url,
    'headers': headers,
    'exact': exactHeaders,
    'hash': ?torrentHash,
    'file': ?torrentFile,
    'trackers': trackers,
    'torrentTitle': ?torrentTitle,
    'audio': ?audioLanguage,
    'subs': ?subtitleLanguage,
    'path': path,
    'added': added.toIso8601String(),
    'state': state.name,
    'received': received,
    'total': total,
    'parts': parts,
    'partsDone': partsDone,
    'error': ?error,
    'pos': positionMs,
    'dur': durationMs,
  };

  static DownloadItem? fromJson(Map<String, dynamic> j) {
    try {
      final kind = DownloadKind.values.byName(j['kind'] as String);
      var state = DownloadState.values.byName(j['state'] as String);
      // nothing runs across a restart: what was running or waiting is yours to carry on
      if (state == DownloadState.running || state == DownloadState.queued) state = DownloadState.paused;
      return DownloadItem._(
        id: j['id'] as String,
        title: j['title'] as String,
        detail: (j['detail'] ?? '') as String,
        poster: j['poster'] as String?,
        kind: kind,
        url: j['url'] as String,
        headers: {for (final e in ((j['headers'] ?? const {}) as Map).entries) '${e.key}': '${e.value}'},
        exactHeaders: j['exact'] == true,
        torrentHash: j['hash'] as String?,
        torrentFile: (j['file'] as num?)?.toInt(),
        trackers: [for (final t in (j['trackers'] ?? const []) as List) '$t'],
        torrentTitle: j['torrentTitle'] as String?,
        audioLanguage: j['audio'] as String?,
        subtitleLanguage: j['subs'] as String?,
        path: j['path'] as String,
        added: DateTime.tryParse('${j['added']}') ?? DateTime.now(),
        state: state,
        received: (j['received'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        parts: (j['parts'] as num?)?.toInt() ?? 0,
        partsDone: (j['partsDone'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
        positionMs: (j['pos'] as num?)?.toInt() ?? 0,
        durationMs: (j['dur'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Why a download can't be made, in words for the person.
class DownloadRefused implements Exception {
  const DownloadRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Job {
  bool stopped = false;
  HttpClient? client;
  void stop() {
    stopped = true;
    try {
      client?.close(force: true);
    } catch (_) {}
  }
}

/// The downloads and what's being fetched. Listeners hear every change (progress included, a
/// couple of times a second).
class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  /// How many run at once; the rest wait their turn.
  static const _atOnce = 2;

  final List<DownloadItem> _items = [];
  final _jobs = <String, _Job>{};
  Directory? _root;
  File? _index;
  bool _loaded = false;
  Timer? _tick;
  DateTime _saved = DateTime.fromMillisecondsSinceEpoch(0);

  /// Newest first.
  List<DownloadItem> get items => List.unmodifiable(_items);

  int get running => _items.where((d) => d.state == DownloadState.running || d.state == DownloadState.queued).length;

  /// The folder downloads are kept in.
  Future<Directory> root() async => _root ??= await _findRoot();

  static Future<Directory> _findRoot() async {
    Future<Directory?> make(Future<Directory?> Function() base, {String? sub}) async {
      try {
        final b = await base();
        if (b == null) return null;
        final d = Directory(sub == null ? b.path : '${b.path}${Platform.pathSeparator}$sub');
        await d.create(recursive: true);
        // can it be written to? (a sandboxed Mac without the entitlement can't)
        final probe = File('${d.path}${Platform.pathSeparator}.vyse-write-test');
        await probe.writeAsString('ok');
        await probe.delete();
        return d;
      } catch (_) {
        return null;
      }
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final d = await make(getDownloadsDirectory, sub: 'VyseTV');
      if (d != null) return d;
    }
    if (Platform.isAndroid) {
      final d = await make(getExternalStorageDirectory, sub: 'Downloads');
      if (d != null) return d;
    }
    return await make(getApplicationDocumentsDirectory, sub: 'Downloads') ?? await make(getApplicationSupportDirectory, sub: 'Downloads') ?? Directory.systemTemp;
  }

  /// For tests: everything is kept in [dir], and nothing is asked of the system.
  @visibleForTesting
  void useFolder(Directory dir) {
    _root = dir;
    _index = File('${dir.path}${Platform.pathSeparator}downloads.json');
    _loaded = true;
  }

  /// Reads the saved list. Safe to call more than once.
  Future<void> initialize() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _index = File('${dir.path}${Platform.pathSeparator}downloads.json');
      if (await _index!.exists()) {
        final list = json.decode(await _index!.readAsString()) as List;
        for (final j in list) {
          final d = DownloadItem.fromJson((j as Map).cast<String, dynamic>());
          if (d != null) _items.add(d);
        }
      }
    } catch (_) {}
    // a finished one whose file was deleted outside the app is no longer there to play
    for (final d in _items.where((d) => d.state == DownloadState.done).toList()) {
      final there = d.isFolder ? await File('${d.path}${Platform.pathSeparator}index.m3u8').exists() : await File(d.path).exists();
      if (!there) _items.remove(d);
    }
    notifyListeners();
  }

  Future<void> _save({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_saved) < const Duration(seconds: 5)) return;
    _saved = now;
    final f = _index;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(json.encode([for (final d in _items) d.toJson()]));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  void _changed({bool save = false}) {
    notifyListeners();
    if (save) unawaited(_save(force: true));
  }

  // ── starting, pausing, removing ──

  /// Queues a download and starts it when there's room. Throws [DownloadRefused] with the
  /// reason when it can't be downloaded.
  Future<DownloadItem> add(DownloadRequest r) async {
    await initialize();
    final uri = Uri.tryParse(r.url.split('#').first);
    if (r.kind != DownloadKind.torrent && (uri == null || (uri.scheme != 'http' && uri.scheme != 'https'))) {
      throw const DownloadRefused("This source can't be downloaded. Pick another one from Sources and try again.");
    }
    if (r.kind == DownloadKind.file && RegExp(r'\.mpd($|\?)', caseSensitive: false).hasMatch(r.url)) {
      throw const DownloadRefused("This source can't be downloaded. Pick another one from Sources and try again.");
    }
    if (r.kind == DownloadKind.torrent && (r.torrentHash == null || r.torrentFile == null)) {
      throw const DownloadRefused("This torrent can't be downloaded from here.");
    }
    final same = _items.where((d) => d.title == r.title && d.detail == r.detail && d.state != DownloadState.failed).firstOrNull;
    if (same != null) {
      throw DownloadRefused(same.state == DownloadState.done ? "It's already in Downloads." : "It's already downloading.");
    }
    final dir = await root();
    final name = _safeName([r.title, if (r.detail.isNotEmpty) r.detail.split(' · ').first].join(' '));
    final String path;
    if (r.kind == DownloadKind.hls) {
      path = await _free(dir, name, null);
    } else {
      final ext = (r.extension ?? RegExp(r'\.([A-Za-z0-9]{2,4})$').firstMatch(uri?.path ?? '')?[1] ?? 'mp4').toLowerCase();
      path = await _free(dir, name, const {'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'ts', 'wmv', 'flv', 'mp3', 'm4a', 'flac'}.contains(ext) ? ext : 'mp4');
    }
    final d = DownloadItem._(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: r.title,
      detail: r.detail,
      poster: r.poster,
      kind: r.kind,
      url: r.url,
      headers: r.headers,
      exactHeaders: r.exactHeaders,
      torrentHash: r.torrentHash?.toLowerCase(),
      torrentFile: r.torrentFile,
      trackers: r.trackers,
      torrentTitle: r.torrentTitle,
      audioLanguage: r.audioLanguage,
      subtitleLanguage: r.subtitleLanguage,
      path: path,
      added: DateTime.now(),
    );
    _items.insert(0, d);
    _changed(save: true);
    _pump();
    return d;
  }

  static String _safeName(String s) {
    var n = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    n = n.replaceAll(RegExp(r'[. ]+$'), '');
    if (n.length > 90) n = n.substring(0, 90).trim();
    return n.isEmpty ? 'Download' : n;
  }

  /// A name in [dir] nothing else has: "Name.mkv", "Name (2).mkv"… ([ext] null: a folder).
  Future<String> _free(Directory dir, String name, String? ext) async {
    for (var i = 1; ; i++) {
      final base = i == 1 ? name : '$name ($i)';
      final p = '${dir.path}${Platform.pathSeparator}$base${ext == null ? '' : '.$ext'}';
      final taken = _items.any((d) => d.path == p) || await FileSystemEntity.type(p) != FileSystemEntityType.notFound || (ext != null && await File('$p.part').exists());
      if (!taken) return p;
    }
  }

  void pause(DownloadItem d) {
    if (d.state != DownloadState.running && d.state != DownloadState.queued) return;
    _jobs.remove(d.id)?.stop();
    d
      ..state = DownloadState.paused
      ..speed = 0;
    _release(d);
    _changed(save: true);
    _pump();
  }

  void resume(DownloadItem d) {
    if (d.state != DownloadState.paused && d.state != DownloadState.failed) return;
    d
      ..state = DownloadState.queued
      ..error = null;
    _changed(save: true);
    _pump();
  }

  /// Takes it off the list and deletes what was fetched.
  Future<void> remove(DownloadItem d) async {
    _jobs.remove(d.id)?.stop();
    _items.remove(d);
    _release(d);
    _changed(save: true);
    _pump();
    // the writer may still be letting go of the file
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      if (d.isFolder) {
        final dir = Directory(d.path);
        if (await dir.exists()) await dir.delete(recursive: true);
      } else {
        for (final p in [d.path, '${d.path}.part']) {
          final f = File(p);
          if (await f.exists()) await f.delete();
        }
      }
    } catch (_) {}
  }

  /// Where you stopped watching a finished one.
  void remember(DownloadItem d, Duration position, Duration duration) {
    d
      ..positionMs = position.inMilliseconds
      ..durationMs = duration.inMilliseconds;
    unawaited(_save());
  }

  void _release(DownloadItem d) {
    final h = d.torrentHash;
    if (h != null && !_items.any((o) => !identical(o, d) && o.torrentHash == h && o.state == DownloadState.running)) {
      unawaited(Torrents.downloadDone(h));
    }
  }

  void _pump() {
    var room = _atOnce - _jobs.length;
    // oldest first among the ones waiting
    for (final d in _items.reversed.where((d) => d.state == DownloadState.queued).toList()) {
      if (room <= 0) break;
      room--;
      unawaited(_start(d));
    }
    if (_jobs.isEmpty) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(milliseconds: 600), (_) => _measure());
    }
  }

  final _last = <String, int>{};

  void _measure() {
    for (final d in _items.where((d) => d.state == DownloadState.running)) {
      final before = _last[d.id] ?? d.received;
      final now = (d.received - before) / .6;
      d.speed = d.speed == 0 ? now : d.speed * .7 + now * .3; // smoothed
      _last[d.id] = d.received;
    }
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _start(DownloadItem d) async {
    final job = _Job();
    _jobs[d.id] = job;
    d
      ..state = DownloadState.running
      ..error = null
      ..speed = 0;
    _last[d.id] = d.received;
    _changed(save: true);
    try {
      for (var attempt = 1; ; attempt++) {
        try {
          if (d.kind == DownloadKind.hls) {
            await _hls(d, job);
          } else {
            await _file(d, job);
          }
          break;
        } on DownloadRefused {
          rethrow;
        } catch (e) {
          // a dropped connection carries on from where it stopped, a few times
          if (job.stopped || attempt >= 5) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          if (job.stopped) rethrow;
        }
      }
      if (job.stopped) return;
      d
        ..state = DownloadState.done
        ..speed = 0;
    } catch (e) {
      if (job.stopped) return; // paused or removed: already dealt with
      d
        ..state = DownloadState.failed
        ..speed = 0
        ..error = _reason(e);
    } finally {
      if (identical(_jobs[d.id], job)) _jobs.remove(d.id);
      _last.remove(d.id);
      if (!job.stopped) {
        _release(d);
        _changed(save: true);
        _pump();
      }
    }
  }

  static String _reason(Object e) => switch (e) {
    DownloadRefused(:final message) => message,
    FileSystemException(:final osError) when osError?.errorCode == 28 || osError?.errorCode == 112 => "There's no room left on this device.",
    FileSystemException() => "Couldn't write the file to this device.",
    TimeoutException() => 'It stopped answering. Try again.',
    SocketException() || HandshakeException() || HttpException() => "Couldn't reach it. The link may have run out: download it again from the player.",
    StateError(:final message) => message,
    _ => "It couldn't be downloaded. Try again, or pick another source.",
  };

  // ── a file, or a torrent's file read through the engine ──

  Future<void> _file(DownloadItem d, _Job job) async {
    final torrent = d.kind == DownloadKind.torrent;
    final url = torrent ? await Torrents.holdForDownload(d.torrentHash!, d.torrentFile!, trackers: d.trackers, title: d.torrentTitle) : d.url;
    if (job.stopped) return;
    final part = File('${d.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    // the engine is on this device; everything else goes out the way the app's other requests do
    final client = torrent ? HttpClient() : resilientHttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    job.client = client;
    try {
      final rq = await client.getUrl(Uri.parse(url));
      d.headers.forEach(rq.headers.set);
      if (!torrent && !d.headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        rq.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
      }
      rq.headers.removeAll(HttpHeaders.acceptEncodingHeader); // the bytes as they are, so they can be counted
      if (have > 0) rq.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      var res = await rq.close().timeout(Duration(seconds: torrent ? 120 : 30));
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
        // what's on disk is no use to this host: start over
        await res.drain<void>();
        await part.delete();
        have = 0;
        final again = await client.getUrl(Uri.parse(url));
        d.headers.forEach(again.headers.set);
        again.headers.removeAll(HttpHeaders.acceptEncodingHeader);
        res = await again.close().timeout(Duration(seconds: torrent ? 120 : 30));
      }
      if (res.statusCode == HttpStatus.ok) {
        have = 0; // the whole file is coming, whatever was asked for
      } else if (res.statusCode != HttpStatus.partialContent) {
        await res.drain<void>().catchError((Object _) {});
        throw HttpException('HTTP ${res.statusCode}');
      }
      final type = (res.headers.contentType?.mimeType ?? '').toLowerCase();
      if (type.contains('mpegurl') || type == 'text/html') {
        await res.drain<void>().catchError((Object _) {});
        throw const DownloadRefused("This link isn't a video file. Pick another source and try again.");
      }
      final whole = RegExp(r'/(\d+)$').firstMatch(res.headers.value(HttpHeaders.contentRangeHeader) ?? '')?[1];
      d
        ..received = have
        ..total = whole != null ? int.parse(whole) : (res.contentLength >= 0 ? have + res.contentLength : 0);
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var unflushed = 0;
      try {
        // a slow swarm can leave a torrent's file waiting on pieces for a long while
        await for (final chunk in res.timeout(Duration(minutes: torrent ? 10 : 2))) {
          if (job.stopped) break;
          sink.add(chunk);
          d.received += chunk.length;
          unflushed += chunk.length;
          if (unflushed >= 4 << 20) {
            await sink.flush(); // the disk keeps up before more is taken
            unflushed = 0;
          }
        }
      } finally {
        await sink.flush().catchError((Object _) {});
        await sink.close().catchError((Object _) {});
      }
      if (job.stopped) return;
      if (d.total > 0 && d.received < d.total) throw const HttpException('ended early');
      await part.rename(d.path);
      if (d.total == 0) d.total = d.received;
    } finally {
      client.close(force: true);
      job.client = null;
    }
  }

  // ── an HLS stream ──

  Future<void> _hls(DownloadItem d, _Job job) async {
    final proxy = StreamProxy.instance;
    final source = d.url.split('#').first;
    if (d.exactHeaders || d.headers.isNotEmpty) proxy.useHeaders(source, d.headers, exact: d.exactHeaders);
    final dir = Directory(d.path);
    await dir.create(recursive: true);
    final planFile = File('${dir.path}${Platform.pathSeparator}plan.json');
    List<List<String>> plan;
    if (await planFile.exists()) {
      plan = [for (final p in json.decode(await planFile.readAsString()) as List) [for (final s in p as List) '$s']];
    } else {
      final b = _HlsPlan(proxy, dir, audio: d.audioLanguage, subtitles: d.subtitleLanguage);
      await b.build(d.url);
      plan = b.pieces;
      await planFile.writeAsString(json.encode(plan));
    }
    if (job.stopped) return;
    d
      ..parts = plan.length
      ..partsDone = 0
      ..received = 0;
    final waiting = <List<String>>[];
    for (final p in plan) {
      final f = File('${dir.path}${Platform.pathSeparator}${p[1].replaceAll('/', Platform.pathSeparator)}');
      if (await f.exists()) {
        d
          ..partsDone += 1
          ..received += await f.length();
      } else {
        waiting.add(p);
      }
    }
    notifyListeners();
    var next = 0;
    Object? failure;
    Future<void> worker() async {
      while (!job.stopped && failure == null) {
        if (next >= waiting.length) return;
        final p = waiting[next++];
        try {
          await _piece(proxy, dir, p[0], p[1], d, job);
          d.partsDone += 1;
        } catch (e) {
          failure ??= e;
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    if (job.stopped) return;
    if (failure != null) throw failure!;
    d.total = d.received;
  }

  Future<void> _piece(StreamProxy proxy, Directory dir, String url, String rel, DownloadItem d, _Job job) async {
    final file = File('${dir.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
    final part = File('${file.path}.part');
    for (var attempt = 1; ; attempt++) {
      var got = 0;
      try {
        final res = await proxy.fetch(url);
        if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
          await res.drain<void>().catchError((Object _) {});
          throw HttpException('HTTP ${res.statusCode}');
        }
        final gz = (res.headers.value(HttpHeaders.contentEncodingHeader) ?? '').contains('gzip');
        final sink = part.openWrite();
        try {
          await for (final chunk in (gz ? res.cast<List<int>>().transform(gzip.decoder) : res).timeout(const Duration(seconds: 45))) {
            if (job.stopped) break;
            sink.add(chunk);
            got += chunk.length;
            d.received += chunk.length;
          }
        } finally {
          await sink.flush().catchError((Object _) {});
          await sink.close().catchError((Object _) {});
        }
        if (job.stopped) {
          d.received -= got;
          await part.delete().catchError((Object _) => part);
          return;
        }
        await part.rename(file.path);
        return;
      } catch (e) {
        d.received -= got;
        await part.delete().catchError((Object _) => part);
        if (job.stopped || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
    }
  }
}

/// Works out an HLS stream's files: which playlists and pieces to fetch, and the playlists as
/// they'll sit on disk (the same ones, pointing at the saved pieces by name).
class _HlsPlan {
  _HlsPlan(this._proxy, this._dir, {String? audio, String? subtitles}) : _audio = _lang(audio), _subs = _lang(subtitles);
  final StreamProxy _proxy;
  final Directory _dir;
  final String? _audio;
  final String? _subs;

  /// [address, the file it becomes] for every piece.
  final pieces = <List<String>>[];

  static String? _lang(String? s) => s == null || s.trim().isEmpty ? null : (exactLanguage(s.trim()) ?? s.trim().toLowerCase());

  static final _uri = RegExp(r'''URI=["']([^"']+)["']''');
  static String? _attr(String line, String name) => RegExp('$name=(?:"([^"]*)"|([^,]*))').firstMatch(line)?.let((m) => m[1] ?? m[2]);

  Future<void> build(String url) async {
    final only = url.contains('#only=') ? Uri.decodeComponent(url.substring(url.indexOf('#only=') + 6)) : null;
    final source = url.split('#').first;
    final text = await _proxy.fetchText(source);
    if (!text.contains('#EXTM3U')) throw const DownloadRefused("This source can't be downloaded. Pick another one from Sources and try again.");
    if (!text.contains('#EXT-X-STREAM-INF')) {
      await _media(source, text, '', 'index.m3u8');
      return;
    }
    final base = Uri.parse(source);
    final lines = const LineSplitter().convert(text).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    // the quality that was on screen, or the best there is
    ({String inf, String url, int height, int rate})? pick;
    for (var i = 0; i < lines.length - 1; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final next = lines.skip(i + 1).firstWhere((l) => !l.startsWith('#'), orElse: () => '');
      if (next.isEmpty) continue;
      final v = (
        inf: lines[i],
        url: base.resolve(next).toString(),
        height: int.tryParse(RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(lines[i])?[1] ?? '') ?? 0,
        rate: int.tryParse(RegExp(r'[^-]BANDWIDTH=(\d+)').firstMatch(lines[i])?[1] ?? '') ?? 0,
      );
      if (only != null) {
        if (v.url == only) pick = v;
      } else if (pick == null || v.height > pick.height || (v.height == pick.height && v.rate > pick.rate)) {
        pick = v;
      }
    }
    if (pick == null) throw const DownloadRefused("This source can't be downloaded. Pick another one from Sources and try again.");
    final audioGroup = _attr(pick.inf, 'AUDIO'), subGroup = _attr(pick.inf, 'SUBTITLES');
    final media = [for (final l in lines) if (l.startsWith('#EXT-X-MEDIA:')) l];
    List<String> ofGroup(String type, String? group) =>
        [for (final l in media) if (_attr(l, 'TYPE') == type && (group == null || _attr(l, 'GROUP-ID') == group)) l];
    bool speaks(String line, String? want) {
      if (want == null) return false;
      final lang = _attr(line, 'LANGUAGE'), name = (_attr(line, 'NAME') ?? '').replaceFirst(RegExp(r'^\d+\.\s*'), '');
      return (lang != null && (exactLanguage(lang) ?? lang.toLowerCase()) == want) || (exactLanguage(name) ?? name.toLowerCase()) == want;
    }

    // sound: the stream's default, and the language you were listening to
    final sounds = ofGroup('AUDIO', audioGroup);
    final keepSound = <String>{
      ...sounds.where((l) => _attr(l, 'DEFAULT') == 'YES').take(1),
      ...sounds.where((l) => speaks(l, _audio)).take(1),
    };
    if (keepSound.isEmpty && sounds.isNotEmpty) keepSound.add(sounds.first);
    // subtitles: your language only (each one is hundreds of small files)
    final keepSubs = ofGroup('SUBTITLES', subGroup).where((l) => speaks(l, _subs)).take(1).toSet();

    final out = StringBuffer('#EXTM3U\n');
    for (final l in lines) {
      if (l.startsWith('#EXT-X-VERSION') || l.startsWith('#EXT-X-INDEPENDENT-SEGMENTS')) out.writeln(l);
    }
    var a = 0, s = 0;
    for (final l in media) {
      final audio = keepSound.contains(l), subs = keepSubs.contains(l);
      if (!audio && !subs) continue;
      final u = _uri.firstMatch(l)?[1];
      if (u == null) {
        out.writeln(l); // sound that's inside the video's own pieces
        continue;
      }
      final folder = audio ? 'a${a++}' : 's${s++}';
      final remote = base.resolve(u).toString();
      await _media(remote, await _proxy.fetchText(remote), '$folder/', '$folder/index.m3u8');
      // one of them has to be the one that plays by itself
      var line = l.replaceFirst(_uri, 'URI="$folder/index.m3u8"');
      if (audio && keepSound.length == 1 && !line.contains('DEFAULT=YES')) {
        line = line.contains('DEFAULT=') ? line.replaceFirst(RegExp('DEFAULT=(NO|"NO")'), 'DEFAULT=YES') : '$line,DEFAULT=YES';
      }
      out.writeln(line);
    }
    var inf = pick.inf;
    if (keepSubs.isEmpty) inf = inf.replaceFirst(RegExp(r',?SUBTITLES="[^"]*"'), '');
    out
      ..writeln(inf)
      ..writeln('v/index.m3u8');
    await _media(pick.url, await _proxy.fetchText(pick.url), 'v/', 'v/index.m3u8');
    await File('${_dir.path}${Platform.pathSeparator}index.m3u8').writeAsString(out.toString());
  }

  /// One quality's (or one language's) playlist: its pieces go on the list, and it's written
  /// to [file] with each piece named as it will be on disk, beside it in [folder].
  Future<void> _media(String url, String text, String folder, String file) async {
    if (!text.contains('#EXTM3U')) throw const DownloadRefused("This source can't be downloaded. Pick another one from Sources and try again.");
    if (!text.contains('#EXT-X-ENDLIST')) throw const DownloadRefused("Live streams can't be downloaded.");
    final base = Uri.parse(url);
    final fragmented = text.contains('#EXT-X-MAP');
    final names = <String, String>{}; // address → name on disk, so a piece listed twice is fetched once
    var seg = 0, init = 0, key = 0;
    String local(String u, String Function() make) {
      final remote = base.resolve(u).toString();
      return names.putIfAbsent(remote, () {
        final name = make();
        pieces.add([remote, '$folder$name']);
        return name;
      });
    }

    String ending(String u) {
      final e = RegExp(r'\.([A-Za-z0-9]{2,5})$').firstMatch(Uri.tryParse(u)?.path ?? '')?[1]?.toLowerCase();
      return const {'ts', 'm4s', 'mp4', 'm4a', 'm4v', 'aac', 'mp3', 'ac3', 'ec3', 'vtt', 'webvtt'}.contains(e) ? e! : (fragmented ? 'm4s' : 'ts');
    }

    final out = StringBuffer();
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MAP:')) {
        final u = _uri.firstMatch(line)?[1];
        out.writeln(u == null ? line : line.replaceFirst(_uri, 'URI="${local(u, () => 'init${init++}.mp4')}"'));
      } else if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-SESSION-KEY:')) {
        final u = _uri.firstMatch(line)?[1];
        out.writeln(u == null || u.startsWith('data:') ? line : line.replaceFirst(_uri, 'URI="${local(u, () => 'key${key++}.key')}"'));
      } else if (line.startsWith('#')) {
        out.writeln(line);
      } else {
        out.writeln(local(line, () => 'seg${(seg++).toString().padLeft(5, '0')}.${ending(line)}'));
      }
    }
    final f = File('${_dir.path}${Platform.pathSeparator}${file.replaceAll('/', Platform.pathSeparator)}');
    await f.parent.create(recursive: true);
    await f.writeAsString(out.toString());
  }
}

extension _Let<T extends Object> on T {
  R let<R>(R Function(T) f) => f(this);
}
