import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

import '../net.dart';
import 'common.dart';
import 'film_sources.dart' show FilmSource;
/// The film and TV scrapers ported from the Vyla SDK (`src/sources/*.js`) that passed Lorewatch's
/// checks: each found a stream for a real title, played it through the relay (or straight, for
/// files) and kept playing after a seek far into it. Each keeps its JS logic: requests, headers,
/// decoding and extraction. Which failed, and why, is in SOURCES_REPORT.md at the project root.

typedef Scraper = Future<List<FoundStream>> Function(FilmQuery q);

/// Every ported source that passed, in the default order (after Movy), each under the
/// site's own name. The first four are the user's own order: CNO, VidUp, 111477, VidLink.
const portedSources = [
  FilmSource(id: 'cno', name: 'CNO', note: 'Films and shows, up to 4K', scraper: cno), // cno.js
  FilmSource(id: 'vidup', name: 'VidUp', note: 'Films and shows, up to 4K', scraper: vidup), // vidup.js
  FilmSource(id: '111477', name: '111477', note: 'Films and shows, as very large files (often 4K remuxes)', scraper: s111477), // 111477.js
  FilmSource(id: 'vidlink', name: 'VidLink', note: 'Films and shows, as video files up to 1080p', scraper: vidlink), // vidlink.js
  FilmSource(id: 'vidbolt', name: 'VidBolt', note: 'Films and shows', scraper: vidbolt), // vidbolt.js
  FilmSource(id: 'rivestream', name: 'RiveStream', note: 'Films and shows, with many mirrors', scraper: rivestream), // rivestream.js
  FilmSource(id: '3eyedraven', name: '3EyedRaven', note: 'Films and shows, 1080p', scraper: threeEyedRaven), // 3eyedraven.js
  FilmSource(id: 'vidlux', name: 'VidLux', note: 'Films and shows', scraper: vidlux), // vidlux.js
  FilmSource(id: 'vidly', name: 'Vidly', note: 'Films and shows', scraper: vidly), // vidly.js
  FilmSource(id: 'purstream', name: 'PurStream', note: 'Films and shows', scraper: purstream), // purstream.js
  FilmSource(id: 'fsonline', name: 'FSOnline', note: 'Films and shows', scraper: fsonline), // fsonline.js
  FilmSource(id: 'castle', name: 'Castle', note: 'Films and shows, 1080p', scraper: castle), // castle.js
  FilmSource(id: 'netplayz', name: 'NetPlayz', note: 'Films and shows, 720p', scraper: netplayz), // netplayz.js
  FilmSource(id: 'meowtv', name: 'MeowTV', note: 'Films and shows', scraper: meowtv), // meowtv.js
  FilmSource(id: 'cinemaarmy', name: 'CinemaArmy', note: 'Films and shows, 1080p', scraper: cinemaarmy), // cinemaarmy.js
  FilmSource(id: 'vidzee', name: 'VidZee', note: 'Films and shows', scraper: vidzee), // vidzee.js
  FilmSource(id: 'yastream', name: 'YaStream', note: 'Films and shows', scraper: yastream), // yastream.js
  FilmSource(id: 'lookmovie', name: 'LookMovie', note: 'Films and shows, 480p', scraper: lookmovie), // lookmovie.js
  FilmSource(id: 'vidcore', name: 'VidCore', note: 'Films and shows, up to 4K', scraper: vidcore), // vidcore.js
  FilmSource(id: 'cinebros', name: 'CineBros', note: 'Films and shows, up to 4K', scraper: cinebros), // cinebros.js
  FilmSource(id: 'thugtv', name: 'ThugTV', note: 'Films and shows, 720p', scraper: thugtv), // thugtv.js
  FilmSource(id: 'framextv', name: 'FrameXTV', note: 'Films and shows, English audio', scraper: framextv), // framextv.js
  FilmSource(id: 'lmscript', name: 'LMScript', note: 'Films, up to 1080p', scraper: lmscript, filmsOnly: true), // lmscript.js
  FilmSource(id: 'vidqueen', name: 'VidQueen', note: 'Films, as video files', scraper: vidqueen, filmsOnly: true), // vidqueen.js
  FilmSource(id: 'watchout', name: 'WatchOut', note: 'Shows, 720p', scraper: watchout, showsOnly: true), // watchout.js
  FilmSource(id: 'vidspark', name: 'VidSpark', note: 'Shows, 1080p', scraper: vidspark, showsOnly: true), // vidspark.js
  FilmSource(id: 'willow', name: 'Willow', note: 'Films and shows, as video files', scraper: willow), // willow.js
  FilmSource(id: 'trendimovies', name: 'TrendiMovies', note: 'Films and shows, as 1080p video files', scraper: trendimovies), // trendimovies.js
  FilmSource(id: 'vidvault', name: 'VidVault', note: 'Films and shows, as 1080p video files', scraper: vidvault), // vidvault.js
  FilmSource(id: 'torrentio', name: 'Torrentio', note: 'Films and shows, as video files (streamed, not peer-to-peer)', scraper: torrentio), // torrentio.js
  FilmSource(id: 'braflix', name: 'BraFlix', note: 'Films and shows, as video files', scraper: braflix), // braflix.js
  FilmSource(id: 'moviebox', name: 'MovieBox', note: 'Films and shows, as video files (often 360p first)', scraper: moviebox), // moviebox.js
  FilmSource(id: 'vixsrc', name: 'VixSrc', note: 'Films and shows, Italian audio first', scraper: vixsrc), // vixsrc.js
  FilmSource(id: 'anizone', name: 'AniZone', note: 'Anime only: titles TMDB lists as Japanese animation', scraper: anizone), // anizone.js
  FilmSource(id: 'anv', name: 'ANV', note: 'Anime only: titles TMDB lists as Japanese animation', scraper: anv), // anv.js
  FilmSource(id: '123anime', name: '123Anime', note: 'Anime only: titles TMDB lists as Japanese animation', scraper: anime123), // 123anime.js
  FilmSource(id: 'hexa', name: 'Hexa', note: 'Films and shows', scraper: hexa), // hexa.js
  FilmSource(id: 'cinesrc', name: 'CineSrc', note: 'Films and shows', scraper: cinesrc), // cinesrc.js
  FilmSource(id: 'mapple', name: 'Mapple', note: 'Films and shows, from 6 servers', scraper: mapple), // mapple.js
];

/// vidlink.js — token from enc-dec.app, streams from vidlink.pro
Future<List<FoundStream>> vidlink(FilmQuery q) async {
  const base = 'https://vidlink.pro';
  const headers = {'User-Agent': sdkUA, 'Origin': base, 'Referer': '$base/'};
  try {
    final encData = await fetchJson('https://enc-dec.app/api/enc-vidlink?text=${q.id}', timeout: const Duration(seconds: 6));
    if (encData is! Map || encData['status'] != 200 || encData['result'] is! String) return const [];
    final token = encData['result'] as String;
    final basePath = q.hasEpisode ? '$base/api/b/tv/$token/${q.season}/${q.episode}' : '$base/api/b/movie/$token';

    final out = <FoundStream>[];
    final seen = <String>{};

    // One request, where the SDK sends two at once: both answer the same (checked on ten titles,
    // 14 Nov 2026), and the site shuts an address out for a while after about ten requests in a
    // few seconds (Cloudflare's 1015). The second is only asked when the first has nothing.
    for (final url in [basePath, '$basePath?multiLang=0']) {
      if (out.isNotEmpty) break;
      final http.Response res;
      try {
        res = await fetchRaw(url, headers: headers, timeout: const Duration(seconds: 10));
      } catch (_) {
        continue;
      }
      if (res.statusCode == 429) break; // shut out: asking again only makes it last longer
      if (res.statusCode < 200 || res.statusCode >= 300) continue;
      final data = (() { try { return json.decode(utf8.decode(res.bodyBytes, allowMalformed: true)); } catch (_) { return null; } })();
      final stream = dig(data, ['stream']);
      if (stream is! Map) continue;

      final playlist = stream['playlist'];
      if (playlist is String && playlist.isNotEmpty && seen.add(playlist)) {
        final isDash = stream['type'] == 'dash' || stream['deliveryType'] == 'dash' || playlist.contains('.mpd');
        final res0 = dig(stream, ['playbackMetadata', 'resolutions', 0]);
        final quality = res0 is int ? '${res0}p' : 'Auto';
        final hdrs = <String, String>{...headers};
        if (stream['playlistHeaders'] is Map) {
          for (final e in (stream['playlistHeaders'] as Map).entries) { hdrs['${e.key}'] = '${e.value}'; }
        }
        out.add(FoundStream(url: playlist, server: 'VidLink ${isDash ? 'DASH' : 'HLS'}', quality: quality, type: isDash ? 'dash' : 'hls', headers: hdrs));
      }

      final qualities = stream['qualities'];
      if (qualities is Map) {
        final seenQ = <String>{};
        for (final qKey in ['1080', '720', '480', '360', ...qualities.keys.map((k) => '$k')]) {
          if (!seenQ.add(qKey)) continue;
          final qData = qualities[qKey];
          if (qData is! Map) continue;
          final url = qData['url'];
          if (url is! String || url.isEmpty || !seen.add(url)) continue;
          // the CDN rejects browser User-Agents (428) and Referer (429); use a plain UA only
          final hdrs = <String, String>{'User-Agent': 'libmpv'};
          if (qData['headers'] is Map) {
            for (final e in (qData['headers'] as Map).entries) { hdrs['${e.key}'] = '${e.value}'; }
          }
          out.add(FoundStream(url: url, server: 'VidLink ${qKey}p', quality: '${qKey}p', type: (qData['type'] as String?) ?? 'mp4', headers: hdrs));
        }
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// vidbolt.js
Future<List<FoundStream>> vidbolt(FilmQuery q) async {
  const base = 'https://vidbolt.xyz';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
  const headers = {'User-Agent': ua, 'Referer': '$base/', 'Origin': base, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9'};
  const playback = {'User-Agent': ua, 'Referer': '$base/', 'Origin': base};
  final target = q.hasEpisode ? '$base/api/resolve?type=tv&id=${q.id}&season=${q.season}&episode=${q.episode}' : '$base/api/resolve?type=movie&id=${q.id}';
  String kind(dynamic k, String u) => (firstTruthy([k]) as String?) ?? (u.contains('.m3u8') ? 'hls' : (u.contains('.mpd') ? 'dash' : 'mp4'));
  try {
    final res = await fetchRaw(target, headers: headers, timeout: const Duration(seconds: 25));
    if (res.statusCode >= 300) return const [];
    final data = (() {
      try {
        return json.decode(res.body);
      } catch (_) {
        return null;
      }
    })();
    final stream = dig(data, ['stream']);
    if (!truthy(stream)) return const [];
    final sv = stream['server'];
    final name = sv is String && sv.isNotEmpty ? sv[0].toUpperCase() + sv.substring(1) : 'Direct';
    final out = <FoundStream>[];
    final seen = <String>{};
    if (stream['sources'] is List) {
      for (final item in stream['sources'] as List) {
        final u = dig(item, ['url']);
        if (u is! String || u.isEmpty || !seen.add(u)) continue;
        var quality = truthy(item['quality']) ? '${item['quality']}'.trim() : 'Auto';
        if (RegExp(r'^\d+$').hasMatch(quality)) quality = '${quality}p';
        out.add(FoundStream(url: u, server: 'VidBolt - $name', quality: quality, type: kind(item['kind'], u), headers: playback, audio: audioOf(item['language'])));
      }
    }
    final u = stream['url'];
    if (u is String && u.isNotEmpty && seen.add(u)) {
      out.add(FoundStream(
        url: u,
        server: 'VidBolt - $name',
        quality: '${firstTruthy([stream['quality']]) ?? 'Auto'}',
        type: kind(stream['kind'], u),
        headers: playback,
        audio: audioOf(stream['language']),
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

const _cArray = [
  '4Z7lUo', 'gwIVSMD', 'PLmz2elE2v', 'Z4OFV0', 'SZ6RZq6Zc', 'zhJEFYxrz8', 'FOm7b0', 'axHS3q4KDq', 'o9zuXQ', '4Aebt', //
  'wgjjWwKKx', 'rY4VIxqSN', 'kfjbnSo', '2DyrFA1M', 'YUixDM9B', 'JQvgEj0', 'mcuFx6JIek', 'eoTKe26gL', 'qaI9EVO1rB', '0xl33btZL',
  '1fszuAU', 'a7jnHzst6P', 'wQuJkX', 'cBNhTJlEOf', 'KNcFWhDvgT', 'XipDGjST', 'PCZJlbHoyt', '2AYnMZkqd', 'HIpJh', 'KH0C3iztrG',
  'W81hjts92', 'rJhAT', 'NON7LKoMQ', 'NMdY3nsKzI', 't4En5v', 'Qq5cOQ9H', 'Y9nwrp', 'VX5FYVfsf', 'cE5SJG', 'x1vj1',
  'HegbLe', 'zJ3nmt4OA', 'gt7rxW57dq', 'clIE9b', 'jyJ9g', 'B5jXjMCSx', 'cOzZBZTV', 'FTXGy', 'Dfh1q1', 'ny9jqZ2POI',
  'X2NnMn', 'MBtoyD', 'qz4Ilys7wB', '68lbOMye', '3YUJnmxp', '1fv5Imona', 'PlfvvXD7mA', 'ZarKfHCaPR', 'owORnX', 'dQP1YU',
  'dVdkx', 'qgiK0E', 'cx9wQ', '5F9bGa', '7UjkKrp', 'Yvhrj', 'wYXez5Dg3', 'pG4GMU', 'MwMAu', 'rFRD5wlM',
];

int _i32(int x) => ((x & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000;

int _u32(int x) => x & 0xFFFFFFFF;

int _shl(int a, int b) => _i32(_i32(a) << (b & 31));

int _ushr(int a, int b) => _u32(a) >> (b & 31);

/// Number.prototype.toString(16) of an int32, then padStart(8, '0') (a negative keeps its '-').
String _hex8(int v) => (v < 0 ? '-${(-v).toRadixString(16)}' : v.toRadixString(16)).padLeft(8, '0');

String _riveInner(String s) {
  var t = 0;
  for (var n = 0; n < s.length; n++) {
    final r = s.codeUnitAt(n);
    t = _u32(r + _shl(t, 6) + _shl(t, 16) - t);
    final i = _u32(_shl(t, n % 5) | _ushr(t, 32 - (n % 5)));
    t = _i32(t ^ _u32(i ^ (_shl(r, n % 7) | _ushr(r, 8 - (n % 7)))));
    t = _u32(t + _i32(_ushr(t, 11) ^ _shl(t, 3)));
  }
  t = _i32(t ^ _ushr(t, 15));
  t = _u32((65535 & t) * 49842 + _shl((_ushr(t, 16) * 49842) & 65535, 16));
  t = _i32(t ^ _ushr(t, 13));
  t = _u32((65535 & t) * 40503 + _shl((_ushr(t, 16) * 40503) & 65535, 16));
  t = _i32(t ^ _ushr(t, 16));
  return _hex8(t);
}

String _riveOuter(String s) {
  var n = _i32(3735928559 ^ s.length);
  for (var e = 0; e < s.length; e++) {
    final r = s.codeUnitAt(e);
    final rXor = (_i32(131 * e + 89) ^ _shl(r, e % 5)) & 255;
    final r2 = r ^ rXor;
    n = _i32(_u32(_shl(n, 7) | _ushr(n, 25)) ^ r2);
    final idx = (65535 & n) * 60205;
    final o2 = _shl(_ushr(n, 16) * 60205, 16);
    n = _u32(idx + o2);
    n = _i32(n ^ _ushr(n, 11));
  }
  n = _i32(n ^ _ushr(n, 15));
  n = _u32((65535 & n) * 49842 + _shl(_ushr(n, 16) * 49842, 16));
  n = _i32(n ^ _ushr(n, 13));
  n = _u32((65535 & n) * 40503 + _shl(_ushr(n, 16) * 40503, 16));
  n = _i32(n ^ _ushr(n, 16));
  n = _u32((65535 & n) * 10196 + _shl(_ushr(n, 16) * 10196, 16));
  return _hex8(_i32(n ^ _ushr(n, 15)));
}

/// rivestream.js generateRiveSecretKey
String riveSecretKey(String? e) {
  if (e == null) return 'rive';
  try {
    final r = e;
    final String t;
    final int n;
    final num_ = num.tryParse(r);
    if (num_ == null) {
      final sum = r.codeUnits.fold<int>(0, (a, c) => a + c);
      t = _cArray[sum % _cArray.length];
      n = (sum % r.length) ~/ 2;
    } else {
      final i = num_.toInt();
      t = _cArray[i % _cArray.length];
      n = (i % r.length) ~/ 2;
    }
    return base64.encode(utf8.encode(_riveOuter(_riveInner(r.substring(0, n) + t + r.substring(n)))));
  } catch (_) {
    return 'topSecret';
  }
}

Future<List<FoundStream>> rivestream(FilmQuery q) async {
  const defaults = ['apex', 'pulse', 'solstice', 'quasar', 'horizon', 'primevids', 'flowcast', 'asiacloud', 'citadel', 'hindicast', 'guru'];
  final movie = !q.hasEpisode;
  final key = riveSecretKey(q.id);
  final referer = movie
      ? 'https://www.rivestream.app/watch?type=movie&id=${q.id}'
      : 'https://www.rivestream.app/watch?type=tv&id=${q.id}&season=${q.season}&episode=${q.episode}';
  List<dynamic> services;
  try {
    final res = await fetchJson('https://www.rivestream.app/api/backendfetch?requestID=VideoProviderServices&secretKey=${Uri.encodeComponent(riveSecretKey(null))}',
        headers: const {'User-Agent': sdkUA, 'Referer': 'https://www.rivestream.app/', 'Accept': 'application/json, text/plain, */*'}, timeout: const Duration(seconds: 6));
    final d = dig(res, ['data']);
    services = d is List && d.isNotEmpty ? d : defaults;
  } catch (_) {
    services = defaults;
  }
  Future<List<FoundStream>> one(String service) async {
    try {
      final cb = service == 'primevids' || service == 'citadel' ? '&cb=${DateTime.now().millisecondsSinceEpoch ~/ 3000000}' : '';
      final params = movie
          ? 'requestID=movieVideoProvider&id=${q.id}&service=$service$cb&secretKey=${Uri.encodeComponent(key)}'
          : 'requestID=tvVideoProvider&id=${q.id}&season=${q.season}&episode=${q.episode}&service=$service$cb&secretKey=${Uri.encodeComponent(key)}';
      final res = await fetchJson('https://www.rivestream.app/api/backendfetch?$params',
          headers: {'User-Agent': sdkUA, 'Referer': referer, 'Accept': 'application/json, text/plain, */*'}, timeout: const Duration(seconds: 10));
      final sources = dig(res, ['data', 'sources']);
      if (sources is! List) return const [];
      return [
        for (final item in sources)
          if (truthy(dig(item, ['url'])))
            FoundStream(
              url: '${item['url']}',
              server: 'Rive (${firstTruthy([item['source']]) ?? service})',
              quality: '${firstTruthy([item['quality']]) ?? 'Auto'}',
              type: () {
                final f = '${item['format'] ?? ''}'.toLowerCase(), u = '${item['url']}'.toLowerCase();
                return f == 'hls' || f == 'm3u8' || u.contains('.m3u8') || u.contains('.txt') ? 'hls' : 'mp4';
              }(),
              headers: {'User-Agent': sdkUA, 'Referer': referer},
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  final all = await Future.wait(services.map((s) => one('$s')));
  return [for (final l in all) ...l];
}

/// 3eyedraven.js
Future<List<FoundStream>> threeEyedRaven(FilmQuery q) async {
  const base = 'https://3eyedraven.watch';
  const apiBase = 'https://3eyedraven.watch/api';
  String absolute(String url) {
    if (url.isEmpty) return '';
    if (RegExp(r'^https?://').hasMatch(url)) return url;
    return '$base${url.startsWith('/') ? '' : '/'}$url';
  }

  final meta = await getTmdbMetadata(q.id, q.hasEpisode);
  if (meta.title.isEmpty) return const [];
  final identifier = '${slugify(meta.title)}-${q.id}';
  final url = q.hasEpisode ? '$apiBase/stream/$identifier?season=${q.season}&episode=${q.episode}' : '$apiBase/stream/$identifier';
  final headers = {'User-Agent': getUA(), 'Accept': 'application/json', 'Referer': '$base/', 'Origin': base};
  try {
    final res = await fetchRaw(url, headers: headers, timeout: const Duration(seconds: 15));
    if (res.statusCode >= 300) return const [];
    final stream = dig(json.decode(res.body), ['stream']);
    final u = dig(stream, ['url']);
    if (u is! String || u.isEmpty) return const [];
    final streamUrl = absolute(u);
    if (!RegExp(r'^https?://').hasMatch(streamUrl)) return const [];
    return [FoundStream(url: streamUrl, headers: headers, server: '3eyedraven', quality: '1080p', type: stream['format'] == 'hls' ? 'hls' : 'mp4')];
  } catch (_) {
    return const [];
  }
}

/// vidlux.js (AES-256-GCM payloads, keyed by the SHA-256 of its fixed passphrase)
Future<List<FoundStream>> vidlux(FilmQuery q) async {
  const base = 'https://vidlux.xyz';
  const key = 'vidlux-stream-encryption-2026-secure-key';
  const playback = {'User-Agent': sdkUA, 'Referer': '$base/', 'Origin': base};
  const servers = [
    ('robot', 'Robot'), ('titan', 'Titan'), ('spider', 'Spider'), ('dragon', 'Dragon'), ('quasar', 'Quasar'), ('vidfast', 'Flux'), //
    ('rocket', 'Aether'), ('star', 'Star'), ('bolt', 'Bolt'), ('quilox', 'Quilox'), ('vidrock', 'Nova'), ('dubai', 'Dubai'),
    ('magic', 'Magic'), ('vixsrc', 'Aura'), ('astra', 'Astra'),
  ];
  dynamic decrypt(String b64) {
    try {
      final k = Uint8List.fromList(crypto.sha256.convert(utf8.encode(key)).bytes);
      final raw = base64.decode(b64);
      final iv = Uint8List.fromList(raw.sublist(0, 12));
      final data = Uint8List.fromList(raw.sublist(12)); // ciphertext followed by the 16-byte tag
      final gcm = pc.GCMBlockCipher(pc.AESEngine())..init(false, pc.AEADParameters(pc.KeyParameter(k), 128, iv, Uint8List(0)));
      return json.decode(utf8.decode(gcm.process(data)));
    } catch (_) {
      return null;
    }
  }

  final tv = q.hasEpisode;
  final embedUrl = tv ? '$base/embed/tv/${q.id}/${q.season}/${q.episode}' : '$base/embed/movie/${q.id}';
  String? token;
  try {
    final html = await fetchText(embedUrl, headers: const {'User-Agent': sdkUA, 'Referer': '$base/'}, timeout: const Duration(seconds: 8));
    token = (RegExp(r'(\d{13}\.[a-f0-9]{8}\.[a-f0-9]{64})', caseSensitive: false).firstMatch(html) ??
        RegExp(r'''requestToken["\\'\s:]+([a-zA-Z0-9._-]+)''', caseSensitive: false).firstMatch(html))?[1];
  } catch (_) {}
  if (token == null) return const [];
  final query = Uri(queryParameters: {'id': q.id, 'type': tv ? 'tv' : 'movie', '_t': token, if (tv) ...{'season': '${q.season}', 'episode': '${q.episode}'}}).query;
  final out = <FoundStream>[];
  final seen = <String>{};
  for (final (id, name) in servers) {
    try {
      final res = await fetchRaw('$base/api/extract/$id?$query',
          headers: {'Accept': '*/*', 'Accept-Language': 'en-US,en;q=0.9', 'User-Agent': sdkUA, 'Referer': embedUrl, 'Origin': base}, timeout: const Duration(seconds: 10));
      if (res.statusCode >= 300) continue;
      dynamic data;
      try {
        data = json.decode(res.body);
      } catch (_) {
        continue;
      }
      if (truthy(dig(data, ['encrypted'])) && truthy(dig(data, ['data']))) data = decrypt('${data['data']}');
      if (data == null) continue;
      final streams = dig(data, ['streams']) is List ? data['streams'] as List : (dig(data, ['sources']) is List ? data['sources'] as List : const []);
      for (final item in streams) {
        var u = firstTruthy([dig(item, ['file']), dig(item, ['url'])]);
        if (u is! String) continue;
        if (u.startsWith('/')) u = '$base$u';
        if (!u.startsWith('http') || !seen.add(u)) continue;
        var quality = '${firstTruthy([item['quality']]) ?? 'Auto'}';
        if (RegExp(r'^\d+$').hasMatch(quality.trim())) quality = '${quality}p';
        final type = (firstTruthy([item['type']]) as String?) ?? (u.contains('.mpd') ? 'dash' : (u.contains('.m3u8') ? 'hls' : 'mp4'));
        out.add(FoundStream(url: u, server: 'VidLux - $name', quality: quality, type: type, headers: playback));
      }
      if (out.isNotEmpty) break;
    } catch (_) {}
  }
  return out;
}

int _qn(String q) => int.tryParse(RegExp(r'\d+').stringMatch(q) ?? '') ?? 0;

/// The variants of an HLS master playlist (anizone.js / vidly.js resolveHlsVariants).
Future<List<({String url, String quality})>?> _variants(String master, Map<String, String> headers, Duration timeout, {bool bandwidth = false, bool Function(String)? skip}) async {
  try {
    return hlsVariantsOf(await fetchText(master, headers: headers, timeout: timeout), master, bandwidth: bandwidth, skip: skip);
  } catch (_) {
    return null;
  }
}

dynamic vidlyDecrypt(String sealed) {
  if (!sealed.startsWith('v1.')) return null;
  try {
    const secret = r'vY7#qL2!mZ9@wK4$';
    final bytes = base64.decode(base64.normalize(sealed.substring(3).replaceAll('-', '+').replaceAll('_', '/')));
    final salt = bytes.sublist(0, 12);
    final c = Uint8List.fromList(bytes.sublist(12));
    final keys = <int>[];
    for (var s = 0; s < 4; s++) {
      var n = _u32(0x811c9dc5 ^ (0x9e3779b9 * s));
      for (final ch in secret.codeUnits) {
        n = _u32((n ^ ch) * 0x1000193);
      }
      for (final b in salt) {
        n = _u32((n ^ b) * 0x1000193);
      }
      keys.add(n);
    }
    var sKey = keys[0], nKey = keys[1], lKey = keys[2], aKey = keys[3];
    var r = 0;
    for (var i = 0; i < c.length; i++) {
      if ((3 & i) == 0) {
        lKey = _u32(lKey);
        aKey = _u32(aKey);
        sKey = _u32(sKey);
        nKey = _u32(nKey);
        var e = _i32(sKey + nKey);
        sKey = _i32(nKey ^ (nKey >> 9));
        nKey = _i32(lKey + _i32(lKey << 3));
        aKey = _i32(aKey + 1);
        e = _i32(e + aKey);
        lKey = _i32(_i32(_i32(lKey << 21) | (lKey >> 11)) + e);
        r = _u32(e);
      }
      c[i] ^= (r >> ((3 & i) * 8)) & 255;
    }
    return json.decode(utf8.decode(c, allowMalformed: true));
  } catch (_) {
    return null;
  }
}

Future<List<FoundStream>> vidly(FilmQuery q) async {
  const base = 'https://vidly.pro';
  const headers = {
    'User-Agent': sdkUA,
    'Referer': '$base/',
    'Origin': base,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  const playback = {'User-Agent': sdkUA, 'Referer': '$base/', 'Origin': base};
  bool invalid(String? u) => u == null || u.isEmpty || RegExp(r'tiles|thumbs?|sprite', caseSensitive: false).hasMatch(u);
  final target = q.hasEpisode ? '$base/tv/${q.id}/${q.season}/${q.episode}?preview=1' : '$base/movie/${q.id}?preview=1';
  try {
    final html = await fetchText(target, headers: headers, timeout: const Duration(seconds: 10));
    final out = <FoundStream>[];
    final seen = <String>{};
    final sealed = RegExp(r'v1\.[a-zA-Z0-9_-]{100,}').firstMatch(html)?[0];
    if (sealed != null) {
      final data = vidlyDecrypt(sealed);
      if (dig(data, ['streams']) is List) {
        final label = '${firstTruthy([dig(data, ['provider', 'label'])]) ?? 'Vidly'}';
        for (final stream in data['streams'] as List) {
          final u = dig(stream, ['url']);
          if (u is! String || !u.startsWith('http') || invalid(u)) continue;
          if (u.contains('.m3u8')) {
            final vs = await _variants(u, playback, const Duration(seconds: 6), bandwidth: true, skip: invalid);
            if (vs != null && vs.isNotEmpty) {
              for (final v in vs) {
                if (invalid(v.url) || !seen.add(v.url)) continue;
                out.add(FoundStream(url: v.url, server: 'Vidly - $label (${v.quality})', quality: v.quality, type: 'hls', headers: playback, audio: audioOf(stream['language'])));
              }
              continue;
            }
          }
          if (!seen.add(u)) continue;
          var quality = truthy(stream['quality']) ? '${stream['quality']}'.trim() : 'Auto';
          if (RegExp(r'^\d+$').hasMatch(quality)) quality = '${quality}p';
          final type = (firstTruthy([stream['type']]) as String?) ?? (u.contains('.m3u8') ? 'hls' : (u.contains('.mpd') ? 'dash' : 'mp4'));
          out.add(FoundStream(
            url: u,
            server: 'Vidly - $label${truthy(stream['language']) ? ' (${stream['language']})' : ''}',
            quality: quality,
            type: type,
            headers: playback,
            audio: audioOf(stream['language']),
          ));
        }
      }
    }
    if (out.isEmpty) {
      final m = RegExp(r'''https?://[^"'\\<>\s]+/media/([a-zA-Z0-9_-]+)/thumbs''', caseSensitive: false).firstMatch(html);
      if (m != null) {
        final master = '${m[0]!.split('/media/').first}/media/${m[1]}/index.m3u8';
        final vs = await _variants(master, playback, const Duration(seconds: 6), bandwidth: true, skip: invalid);
        if (vs != null && vs.isNotEmpty) {
          for (final v in vs) {
            if (invalid(v.url) || !seen.add(v.url)) continue;
            out.add(FoundStream(url: v.url, server: 'Vidly - Direct (${v.quality})', quality: v.quality, type: 'hls', headers: playback));
          }
        } else if (!invalid(master) && seen.add(master)) {
          out.add(FoundStream(url: master, server: 'Vidly - Direct', type: 'hls', headers: playback));
        }
      }
    }
    out.sort((a, b) => _qn(b.quality) - _qn(a.quality));
    return out;
  } catch (_) {
    return const [];
  }
}

/// purstream.js
Future<List<FoundStream>> purstream(FilmQuery q) async {
  const domain = 'https://purstream.ad';
  const apiBase = 'https://api.purstream.ad/api/v1';
  const headers = {
    'User-Agent': sdkUA,
    'Accept': 'application/json, text/plain, */*',
    'Referer': '$domain/',
    'Origin': domain,
    'X-Requested-With': 'XMLHttpRequest',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': 'same-site',
  };
  final tv = q.hasEpisode;
  final type = tv ? 'tv' : 'movie';
  try {
    final meta = await getTmdbMetadata(q.id, tv);
    if (meta.titles.isEmpty) return const [];
    final title = meta.titles.first;
    final search = await fetchJson('$apiBase/search-bar/search/${Uri.encodeComponent(title)}', headers: headers, timeout: const Duration(seconds: 10));
    final items = (dig(search, ['data', 'items', 'movies', 'items']) as List?) ?? const [];
    final lower = title.toLowerCase();
    var match = items.cast<dynamic>().firstWhere(
          (i) =>
              dig(i, ['type']) == type &&
              (dig(i, ['title']) as String?)?.toLowerCase() == lower &&
              (meta.year == null || ((dig(i, ['release_date']) as String?)?.startsWith('${meta.year}') ?? false)),
          orElse: () => null,
        );
    match ??= items.cast<dynamic>().firstWhere((i) => dig(i, ['type']) == type, orElse: () => null);
    if (!truthy(dig(match, ['id']))) return const [];
    final url = tv ? '$apiBase/stream/${match['id']}/episode?season=${q.season}&episode=${q.episode}' : '$apiBase/stream/${match['id']}';
    final js = await fetchJson(url, headers: headers, timeout: const Duration(seconds: 10));
    final sources = dig(js, ['data', 'items', 'sources']);
    if (dig(js, ['type']) != 'success' || sources is! List || sources.isEmpty) return const [];
    final chosen = sources.firstWhere((s) => truthy(dig(s, ['stream_url'])), orElse: () => null);
    if (chosen == null) return const [];
    return [
      FoundStream(
        url: chosen['stream_url'] as String,
        headers: const {'User-Agent': sdkUA, 'Referer': '$domain/'},
        server: 'purstream',
        quality: '${firstTruthy([chosen['source_name']]) ?? 'Auto'}',
        type: (firstTruthy([chosen['format']]) as String?) ?? 'hls',
      ),
    ];
  } catch (_) {
    return const [];
  }
}

/// fsonline.js
Future<List<FoundStream>> fsonline(FilmQuery q) async {
  const origin = 'https://www3.fsonline.app';
  const ajax = '$origin/wp-admin/admin-ajax.php';
  const headers = {'User-Agent': sdkUA, 'Origin': origin, 'Referer': '$origin/'};
  final tv = q.hasEpisode;
  try {
    final meta = await getTmdbMetadata(q.id, tv);
    if (meta.titles.isEmpty) return const [];
    final query = meta.titles.first + (meta.year != null ? ' ${meta.year}' : '');
    final searchHtml = await fetchText('$origin/?s=${Uri.encodeComponent(query)}', headers: headers);
    final folder = tv ? 'seriale' : 'film';
    final link = RegExp('href=["\'](https?://www3\\.fsonline\\.app/$folder/([^"\'/]+)/)["\']', caseSensitive: false).firstMatch(searchHtml);
    if (link == null) return const [];
    final target = tv ? '$origin/episoade/${link[2]!.replaceAll(RegExp(r'-\d{4}$'), '')}-sezonul-${q.season}-episodul-${q.episode}/' : link[1]!;
    final pageHtml = await fetchText(target, headers: headers);
    final movieId = (RegExp(r'''movie-id=['"]([^'"]+)['"]''').firstMatch(pageHtml) ?? RegExp(r'movie-id=([^ >]+)').firstMatch(pageHtml))?[1];
    if (movieId == null) return const [];
    final ajaxHtml = await fetchText(ajax,
        method: 'POST',
        headers: {
          ...headers,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': target,
        },
        body: 'action=lazy_player&movieID=$movieId');
    final out = <FoundStream>[];
    var idx = 0;
    while ((idx = ajaxHtml.indexOf('data-vs="', idx)) != -1) {
      final embedStart = idx + 9;
      final embedEnd = ajaxHtml.indexOf('"', embedStart);
      final embedUrl = ajaxHtml.substring(embedStart, embedEnd);
      final spanStart = ajaxHtml.indexOf('<span>', embedEnd);
      final spanEnd = ajaxHtml.indexOf('</span>', spanStart);
      if (spanStart < 0 || spanEnd < 0) break;
      final label = ajaxHtml.substring(spanStart + 6, spanEnd).trim().toLowerCase();
      if (label.contains('filesun')) {
        try {
          final rHtml = await fetchText(embedUrl, headers: const {'Referer': origin, 'User-Agent': sdkUA});
          final m = RegExp(r'''file:\s*["'](https?://[^"']+\.m3u8[^"']*)["']''').firstMatch(rHtml) ??
              RegExp(r'''["']?file["']?:\s*["'](https?://[^"']+)["']''').firstMatch(rHtml);
          if (m != null) {
            out.add(FoundStream(
              url: m[1]!.replaceAll(r'\/', '/'),
              server: 'FSOnline - FileSuN',
              type: 'hls',
              headers: {'Referer': embedUrl, 'Origin': 'https://player.fsonline.app', 'User-Agent': sdkUA},
            ));
          }
        } catch (_) {}
      }
      idx = spanEnd;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// castle.js (the Castle app's API at api.hlowb.com; answers are AES-128-CBC with a key it hands out)
Future<List<FoundStream>> castle(FilmQuery q) async {
  const castleBase = 'https://api.hlowb.com';
  const pkg = 'com.external.castle';
  const channel = 'IndiaA';
  const client = '1';
  const lang = 'en-US';
  const suffix = 'T!BgJB';
  const apkSignKey = 'ED0955EB04E67A1D9F3305B95454FED485261475';
  const working = {'User-Agent': 'okhttp/4.9.3', 'Accept': 'application/json', 'Accept-Language': 'en-US,en;q=0.9', 'Connection': 'Keep-Alive', 'Referer': castleBase};
  const playback = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
    'Accept': 'video/webm,video/ogg,video/*;q=0.9,application/ogg;q=0.7,audio/*;q=0.6,*/*;q=0.5',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'identity',
    'Connection': 'keep-alive',
    'Sec-Fetch-Dest': 'video',
    'Sec-Fetch-Mode': 'no-cors',
    'Sec-Fetch-Site': 'cross-site',
    'DNT': '1',
  };
  const qualityMap = {1: '480p', 2: '720p', 3: '1080p'};

  Future<String> request(String url, {String method = 'GET', Map<String, String> headers = const {}, String? body}) async {
    final r = await fetchRaw(url, method: method, headers: {...working, ...headers}, body: body);
    if (r.statusCode < 200 || r.statusCode >= 300) throw HttpError(r.statusCode, url);
    return r.body;
  }

  Uint8List deriveKey(String b64) {
    final material = [...base64.decode(b64), ...ascii.encode(suffix)];
    if (material.length < 16) material.addAll(List.filled(16 - material.length, 0));
    return Uint8List.fromList(material.take(16).toList());
  }

  dynamic decrypted(String text, String securityKey) {
    var cipher = text.trim();
    if (cipher.isEmpty) throw const FormatException('Empty response');
    try {
      final j = json.decode(cipher);
      if (j is Map && j['data'] is String) cipher = (j['data'] as String).trim();
    } catch (_) {}
    final key = deriveKey(securityKey);
    final plain = utf8.decode(aesCbcDecrypt(key, key, base64.decode(cipher)));
    return json.decode(plain.replaceAllMapped(RegExp(r':(\s*)(-?\d{16,})(\s*[,}\]])'), (m) => ':${m[1]}"${m[2]}"${m[3]}'));
  }

  Map dataBlock(dynamic o) => o is Map && o['data'] is Map ? o['data'] as Map : (o is Map ? o : const {});

  int qualityValue(String? quality) {
    if (quality == null || quality.isEmpty) return 0;
    var s = quality.toLowerCase().replaceFirst(RegExp(r'^(sd|hd|fhd|uhd|4k)\s*'), '').replaceFirst(RegExp(r'p$'), '').trim();
    if (s == '4k' || s == '2160') return 2160;
    final n = int.tryParse(RegExp(r'^-?\d+').stringMatch(s) ?? '') ?? 0;
    return n > 0 ? n : 0;
  }

  final tv = q.season != null && q.season != 0 && q.episode != null && q.episode != 0;
  final season = q.season ?? 0, episode = q.episode ?? 0;
  try {
    final tmdb = json.decode(await request('https://api.themoviedb.org/3/${tv ? 'tv' : 'movie'}/${q.tmdbId}?api_key=$tmdbKey&append_to_response=external_ids'));
    final title = '${(tv ? tmdb['name'] : tmdb['title']) ?? ''}';
    final date = '${(tv ? tmdb['first_air_date'] : tmdb['release_date']) ?? ''}';
    final year = date.isNotEmpty ? int.tryParse(date.split('-').first) : null;

    final keyRes = json.decode(await request('$castleBase/v0.1/system/getSecurityKey/1?channel=$channel&clientType=$client&lang=$lang'));
    if (keyRes['code'] != 200 || !truthy(keyRes['data'])) return const [];
    final securityKey = '${keyRes['data']}';

    final term = year != null ? '$title $year' : title;
    final sp = {'channel': channel, 'clientType': client, 'keyword': term, 'lang': lang, 'mode': '1', 'packageName': pkg, 'page': '1', 'size': '30'};
    final search = decrypted(await request('$castleBase/film-api/v1.1.0/movie/searchByKeyword?${Uri(queryParameters: sp).query}'), securityKey);
    final rows = (dataBlock(search)['rows'] as List?) ?? const [];
    if (rows.isEmpty) return const [];
    final want = title.toLowerCase();
    String? movieId;
    for (final item in rows) {
      final it = '${firstTruthy([item['title'], item['name']]) ?? ''}'.toLowerCase();
      if (it.isNotEmpty && (it.contains(want) || want.contains(it))) {
        final id = firstTruthy([item['id'], item['redirectId'], item['redirectIdStr']]);
        if (id != null) {
          movieId = '$id';
          break;
        }
      }
    }
    movieId ??= '${firstTruthy([rows.first['id'], rows.first['redirectId'], rows.first['redirectIdStr']]) ?? ''}';
    if (movieId.isEmpty) return const [];

    Future<dynamic> details(String id) async =>
        decrypted(await request('$castleBase/film-api/v1.1/movie?channel=$channel&clientType=$client&lang=$lang&movieId=$id&packageName=$pkg'), securityKey);
    var det = await details(movieId);
    if (tv) {
      final seasons = (dataBlock(det)['seasons'] as List?) ?? const [];
      final s = seasons.firstWhere((x) => dig(x, ['number']) == season, orElse: () => null);
      if (s != null && truthy(s['movieId']) && '${s['movieId']}' != movieId) {
        movieId = '${s['movieId']}';
        det = await details(movieId);
      }
    }
    final episodes = (dataBlock(det)['episodes'] as List?) ?? const [];
    String? episodeId;
    if (tv) {
      final ep = episodes.firstWhere((x) => dig(x, ['number']) == episode, orElse: () => null);
      if (ep != null && truthy(ep['id'])) episodeId = '${ep['id']}';
    } else if (episodes.isNotEmpty) {
      episodeId = '${episodes.first['id']}';
    }
    if (episodeId == null) return const [];
    final epObj = episodes.firstWhere((x) => '${dig(x, ['id'])}' == episodeId, orElse: () => null);
    final tracks = (dig(epObj, ['tracks']) as List?) ?? const [];
    const resolution = 2;

    List<({String name, String url, String quality, String? audio})> process(dynamic videoData, String langInfo, [String? audio]) {
      final data = dataBlock(videoData);
      final videoUrl = data['videoUrl'];
      if (!truthy(videoUrl)) return const [];
      final quality = qualityMap[resolution] ?? '${resolution}p';
      if (data['videos'] is List) {
        return [
          for (final v in data['videos'] as List)
            () {
              final qq = '${firstTruthy([v['resolutionDescription'], v['resolution']]) ?? quality}'.replaceFirst(RegExp(r'^(SD|HD|FHD)\s+', caseSensitive: false), '');
              return (name: 'Castle $langInfo - $qq', url: '${firstTruthy([v['url']]) ?? videoUrl}', quality: qq, audio: audio);
            }(),
        ];
      }
      return [(name: 'Castle $langInfo - $quality', url: '$videoUrl', quality: quality, audio: audio)];
    }

    var all = <({String name, String url, String quality, String? audio})>[];
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      final langName = '${firstTruthy([t['languageName'], t['abbreviate']]) ?? 'Lang${i + 1}'}';
      if (truthy(t['existIndividualVideo']) && truthy(t['languageId'])) {
        try {
          final p = {
            'apkSignKey': apkSignKey, 'channel': channel, 'clientType': client, 'episodeId': episodeId, 'lang': lang, //
            'languageId': '${t['languageId']}', 'mode': '1', 'movieId': movieId, 'packageName': pkg, 'resolution': '$resolution',
          };
          all.addAll(process(decrypted(await request('$castleBase/film-api/v1.9.1/movie/getVideo?${Uri(queryParameters: p).query}'), securityKey), '[$langName]', truthy(t['languageName']) ? audioOf('${t['languageName']}') : null));
        } catch (_) {}
      }
    }
    if (all.isEmpty) {
      final body = json.encode({
        'mode': '1', 'appMarket': 'GuanWang', 'clientType': '1', 'woolUser': 'false', 'apkSignKey': apkSignKey, 'androidVersion': '13', //
        'movieId': movieId, 'episodeId': episodeId, 'isNewUser': 'true', 'resolution': '$resolution', 'packageName': pkg,
      });
      final r = await request('$castleBase/film-api/v2.0.1/movie/getVideo2?clientType=$client&packageName=$pkg&channel=$channel&lang=$lang',
          method: 'POST', headers: const {'Content-Type': 'application/json'}, body: body);
      all = process(decrypted(r, securityKey), '[Shared]');
    }
    all.sort((a, b) => qualityValue(b.quality) - qualityValue(a.quality));
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final s in all) {
      if (s.url.isEmpty || !seen.add(s.url)) continue;
      out.add(FoundStream(
        url: s.url,
        server: s.name,
        quality: s.quality,
        type: s.url.contains('.m3u8') ? 'hls' : (s.url.contains('.mpd') ? 'dash' : 'mp4'),
        headers: playback,
        audio: s.audio,
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// AES-CBC with PKCS7 padding.
Uint8List aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List data) {
  final c = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
    ..init(false, pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>, Null>(pc.ParametersWithIV(pc.KeyParameter(key), iv), null));
  return c.process(data);
}

/// netplayz.js (the Castle app's film API at api.hwnou.com)
Future<List<FoundStream>> netplayz(FilmQuery q) async {
  const apiBase = 'https://api.hwnou.com';
  final key = Uint8List.fromList(utf8.encode('fJATm*kgfJT!BgJB'));
  const okhttp = 'okhttp/3.2.0';
  const apkSignKey = 'ED0955EB04E67A1D9F3305B95454FED485261475';
  const streamHeaders = {'User-Agent': sdkUA, 'Referer': 'https://thugtv.online/', 'Origin': 'https://thugtv.online'};

  Future<dynamic> hwnou(String url, {String method = 'GET', String? body}) async {
    try {
      final res = await fetchRaw(url,
          method: method,
          body: body,
          headers: {'Accept': '*/*', 'Accept-Language': 'en-US,en;q=0.9', 'User-Agent': okhttp, if (body != null) 'Content-Type': 'application/json;charset=utf-8'});
      if (res.statusCode >= 300 || res.body.isEmpty) return null;
      final text = utf8.decode(aesCbcDecrypt(key, key, base64.decode(res.body.trim()))).trim();
      // long ids stay strings, as in the JS
      final quoted = text.replaceAllMapped(RegExp(r'(?<=[:\[,]\s*)(\d{16,})(?=\s*[,\]}])'), (m) => '"${m[1]}"');
      return json.decode(quoted);
    } catch (_) {
      return null;
    }
  }

  final tv = q.hasEpisode;
  final epNum = tv ? (q.episode ?? 1) : 1;
  final meta = await getTmdbMetadata(q.id, tv);
  final title = meta.title;
  if (title.isEmpty) return const [];
  try {
    final kw = Uri.encodeComponent(title.toLowerCase().replaceAll(' ', '+'));
    final search = await hwnou(
        '$apiBase/film-api/v2.1.2/movie/searchByKeyword?keyword=$kw&page=1&size=20&mode=1&secure=0&channel=IndiaA&appMarket=GuanWang&packageName=com.external.castle&clientType=1');
    final rows = (dig(search, ['data', 'rows']) as List?) ?? const [];
    final candidates = rows.where((r) => (dig(r, ['movieType']) == 2) == !tv).toList();
    if (candidates.isEmpty) return const [];
    final match = candidates.firstWhere((r) => '${dig(r, ['title']) ?? ''}'.toLowerCase() == title.toLowerCase(), orElse: () => candidates.first);
    final movieId = match['id'];
    if (movieId == null) return const [];
    final details = await hwnou('$apiBase/film-api/v2.1.2/movie?movieId=$movieId&packageName=com.external.castle&clientType=1');
    final episodes = (dig(details, ['data', 'episodes']) as List?) ?? const [];
    if (episodes.isEmpty) return const [];
    final ep = tv ? episodes.firstWhere((x) => num.tryParse('${dig(x, ['number'])}') == epNum, orElse: () => episodes.first) : episodes.first;
    final all = (dig(ep, ['videos']) as List?) ?? const [];
    final free = all.where((v) => v != null && v['premiumProPermission'] == false).toList()
      ..sort((a, b) => ((b['resolution'] as num?) ?? 0).compareTo((a['resolution'] as num?) ?? 0));
    final video = free.isNotEmpty ? free.first : (all.isNotEmpty ? all.first : null);
    if (video == null) return const [];
    final tracks = (dig(ep, ['tracks']) as List?) ?? const [];
    final pref = tracks.firstWhere((t) => dig(t, ['languageId']) == 1003, orElse: () => tracks.isNotEmpty ? tracks.first : null);
    final languageId = dig(pref, ['languageId']);
    final body = json.encode({
      'appMarket': 'GuanWang',
      'woolUser': 'false',
      'isp': 'Android',
      'useVipCdn': 'false',
      'movieId': movieId,
      'episodeId': ep['id'],
      'isNewUser': 'true',
      'resolution': video['resolution'],
      'mode': '1',
      'clientType': '1',
      'apkSignKey': apkSignKey,
      'androidVersion': '11',
      'networkType': 'NETWORK_WIFI',
      'packageName': 'com.external.castle',
      'languageId': languageId,
    });
    final stream = await hwnou('$apiBase/film-api/v2.0.7/movie/getVideo2?clientType=1&packageName=PKG&channel=CHANNEL&lang=en-US', method: 'POST', body: body);
    final videoUrl = dig(stream, ['data', 'videoUrl']);
    if (videoUrl is! String || videoUrl.isEmpty) return const [];
    final quality = '${firstTruthy([video['resolutionDescription']]) ?? (truthy(video['resolution']) ? '${video['resolution']}p' : 'Auto')}';
    final type = videoUrl.contains('.m3u8') ? 'hls' : (videoUrl.contains('.mpd') ? 'dash' : 'mp4');
    return [FoundStream(url: videoUrl, server: 'NetPlayz - $quality', quality: quality, type: type, headers: streamHeaders)];
  } catch (_) {
    return const [];
  }
}

/// meowtv.js (a stream ticket, then each server's answer decrypted by enc-dec.app)
Future<List<FoundStream>> meowtv(FilmQuery q) async {
  const base = 'https://api.meowtv.ru';
  const decApi = 'https://enc-dec.app/api';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
  const headers = {'User-Agent': ua, 'Origin': 'https://meowtv.ru', 'Referer': 'https://meowtv.ru/', 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9'};
  const servers = [('acme', 'Acme', false), ('dcloud', 'Dcloud', false), ('tik', 'TCloud', false), ('ipcloud', 'IPcloud', false), ('turkce', 'Türkçe', true), ('hindi', 'Hindi', false), ('english', 'English', false)];
  final tv = q.hasEpisode;
  final ticketRes = await fetchRaw('$base/streams/ticket', method: 'POST', headers: headers).then<dynamic>((r) => r.statusCode < 300 ? json.decode(r.body) : null, onError: (Object _) => null);
  final ticket = dig(ticketRes, ['ticket']);
  if (!truthy(ticket)) return const [];
  final rh = {...headers, 'X-Stream-Ticket': '$ticket'};

  List<({String url, String quality, String type})> extract(dynamic r) {
    final out = <({String url, String quality, String type})>[];
    String t(dynamic given, String u) => (firstTruthy([given]) as String?) ?? (u.contains('.m3u8') ? 'hls' : 'mp4');
    if (r is String && RegExp(r'^https?://').hasMatch(r)) {
      out.add((url: r, quality: 'Auto', type: t(null, r)));
    } else if (dig(r, ['url']) is String) {
      out.add((url: r['url'] as String, quality: '${firstTruthy([r['quality']]) ?? 'Auto'}', type: t(r['type'], r['url'] as String)));
    } else if (dig(r, ['sources']) is List) {
      for (final s in r['sources'] as List) {
        final u = dig(s, ['url']);
        if (u is String && u.isNotEmpty) out.add((url: u, quality: '${firstTruthy([s['quality']]) ?? 'Auto'}', type: t(s['type'], u)));
      }
    } else if (truthy(dig(r, ['stream']))) {
      final st = r['stream'];
      final u = st is String ? st : dig(st, ['url']);
      if (u is String && u.isNotEmpty) out.add((url: u, quality: '${firstTruthy([dig(st, ['quality'])]) ?? 'Auto'}', type: t(null, u)));
    }
    return out;
  }

  final responses = await Future.wait([
    for (final (id, label, movieOnly) in servers)
      if (!tv || !movieOnly)
        () async {
          try {
            final url = tv ? '$base/streams/tv/${q.id}/${q.season}/${q.episode}?s=$id' : '$base/streams/movie/${q.id}?s=$id';
            final res = await fetchRaw(url, headers: rh);
            if (res.statusCode >= 300) return null;
            final data = json.decode(res.body);
            final dec = await fetchRaw('$decApi/dec-meowtv', method: 'POST', headers: const {'Content-Type': 'application/json', 'User-Agent': ua}, body: json.encode({'data': data}));
            if (dec.statusCode >= 300) return null;
            final dj = json.decode(dec.body);
            return dig(dj, ['status']) == 200 ? (label, dj['result']) : null;
          } catch (_) {
            return null;
          }
        }(),
  ]);
  final out = <FoundStream>[];
  final seen = <String>{};
  for (final r in responses) {
    if (r == null || !truthy(r.$2)) continue;
    for (final item in extract(r.$2)) {
      if (!seen.add(item.url)) continue;
      out.add(FoundStream(
        url: item.url,
        server: 'MeowTV - ${r.$1}',
        quality: item.quality,
        type: item.type,
        headers: const {'Referer': 'https://meowtv.ru/', 'Origin': 'https://meowtv.ru', 'User-Agent': ua},
      ));
    }
  }
  return out;
}

/// cinemaarmy.js over plain HTTP. The JS goes through node-tls-client to pass as Chrome's TLS
/// handshake; that isn't carried over (Dart can't, and it's there to slip past bot checks).
Future<List<FoundStream>> cinemaarmy(FilmQuery q) async {
  const base = 'https://cinema.army';
  const apiBase = '$base/api';
  const hmacKey = 'a2cfc9eaa2a3690b5d4f6b5f958dbdeae52a097283d375bd253ee7c7062524f5';
  const xorKey = 'f16a6b92fcd6eed3e9476297f893f2505c32f79bc6efef9b6c95496aa5914548';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  const servers = [('cookiebakers', 'CookieBakers'), ('tcloud', 'TCloud'), ('ipcloud', 'IPCloud'), ('dcloud', 'DCloud'), ('tidb', 'TIDB')];
  final tv = q.hasEpisode;
  final minute = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 60;
  final token = crypto.Hmac(crypto.sha256, utf8.encode(hmacKey)).convert(utf8.encode('${q.id}:$minute')).toString();
  final headers = {
    'User-Agent': ua,
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    'Referer': tv ? '$base/watch?id=${q.id}&type=tv&season=${q.season}&episode=${q.episode}' : '$base/watch?id=${q.id}&type=movie',
    'Origin': base,
    'Sec-Ch-Ua': '"Chromium";v="131", "Not_A Brand";v="24"',
    'Sec-Ch-Ua-Mobile': '?0',
    'Sec-Ch-Ua-Platform': '"Windows"',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': 'same-origin',
    'Priority': 'u=1, i',
    'X-Stream-Token': token,
  };
  String decryptUrl(String enc) {
    if (enc.startsWith('http://') || enc.startsWith('https://')) return enc;
    try {
      final d = base64.decode(enc); // Buffer#toString('binary'): one char per byte
      return String.fromCharCodes([for (var i = 0; i < d.length; i++) d[i] ^ xorKey.codeUnitAt(i % xorKey.length)]);
    } catch (_) {
      return enc;
    }
  }

  final results = await Future.wait([
    for (final (key, label) in servers)
      () async {
        try {
          final path = tv ? '/$key/tv/${q.id}/${q.season}/${q.episode}' : '/$key/movie/${q.id}';
          final res = await fetchRaw('$apiBase$path', method: 'POST', headers: headers, body: '');
          if (res.statusCode != 200) return null;
          final enc = dig(json.decode(res.body), ['stream', 'url']);
          if (!truthy(enc)) return null;
          final u = decryptUrl('$enc');
          if (!RegExp(r'^https?://').hasMatch(u)) return null;
          return FoundStream(
            url: u,
            headers: const {'User-Agent': ua, 'Referer': '$base/', 'Origin': base},
            server: 'CinemaArmy ($label)',
            quality: '1080p',
            type: u.contains('.m3u8') ? 'hls' : 'mp4',
          );
        } catch (_) {
          return null;
        }
      }(),
  ]);
  return results.nonNulls.toList();
}

/// vidzee.js, without its encrypted fallback: that answer is decrypted by a WebAssembly module
/// the JS ships, and Dart has no WebAssembly runtime. The direct answer is ported as is.
Future<List<FoundStream>> vidzee(FilmQuery q) async {
  const base = 'https://core.vidzee.wtf';
  const player = 'https://player.vidzee.wtf';
  const services = ['dcloud', 'ipcloud', 'tik', 'v6:Hindi', '3AHindi'];
  const headers = {'User-Agent': sdkUA, 'Accept': 'application/json, text/plain, */*', 'Referer': '$player/', 'Origin': player};
  final movie = !q.hasEpisode;
  final results = await Future.wait(services.map((service) async {
    final url = movie ? '$base/streams/movie/${q.id}?s=$service' : '$base/streams/tv/${q.id}/${q.season}/${q.episode}?s=$service';
    final res = await fetchJson(url, headers: headers, timeout: const Duration(seconds: 6)).catchError((Object _) => null);
    final u = dig(res, ['url']);
    if (u is! String || u.isEmpty) return null;
    final h = res['headers'];
    return FoundStream(
      url: u,
      server: 'VidZee ($service)',
      quality: '${firstTruthy([res['language']]) ?? 'Auto'}',
      type: u.contains('.m3u8') ? 'hls' : 'mp4',
      headers: {'User-Agent': sdkUA, 'Referer': '$player/', 'Origin': player, if (h is Map) for (final e in h.entries) '${e.key}': '${e.value}'},
      audio: audioOf(res['language']) ?? (service.contains('Hindi') ? 'Hindi' : null),
    );
  }));
  return results.nonNulls.toList();
}

Map<String, String> _proxyHeaders(dynamic item) {
  final h = dig(item, ['behaviorHints', 'proxyHeaders', 'request']);
  return h is Map ? {for (final e in h.entries) '${e.key}': '${e.value}'} : const {};
}

String _type(String url) => url.contains('.m3u8') ? 'hls' : 'mp4';

/// yastream.js
Future<List<FoundStream>> yastream(FilmQuery q) async {
  const base = 'https://yastream.tamthai.de';
  final path = q.hasEpisode ? '/stream/series/tmdb:${q.id}:${q.season}:${q.episode}.json' : '/stream/movie/tmdb:${q.id}.json';
  final res = await fetchJson('$base$path').catchError((Object _) => null);
  final streams = dig(res, ['streams']);
  if (streams is! List || streams.isEmpty) return const [];
  return [
    for (final item in streams)
      if (truthy(dig(item, ['url'])))
        FoundStream(
          url: item['url'] as String,
          server: 'YaStream - ${truthy(item['name']) ? '${item['name']}'.replaceAll('\n', ' ') : 'Server'}',
          type: _type(item['url'] as String),
          headers: _proxyHeaders(item),
        ),
  ];
}

/// lookmovie.js (the SDK only runs it with your own TMDB key; Lorewatch has one)
Future<List<FoundStream>> lookmovie(FilmQuery q) async {
  const domains = ['https://www.lookmovie2.to', 'https://lookmovie2.to', 'https://lookmovie.foundation'];
  const headersBase = {'User-Agent': sdkUA, 'Accept-Language': 'en-US,en;q=0.9'};
  final storageRe = RegExp(r'''window\[['"](?:movie|show)_storage['"]\]\s*=\s*\{([^}]+)\}''', dotAll: true);
  final idMovieRe = RegExp(r'''['"]?(?:id_movie|movieId)['"]?\s*[:=]\s*['"]?(\d+)['"]?''', caseSensitive: false);
  final seasonsRe = RegExp(r'seasons\s*:\s*(\[[\s\S]+?\])\s*[,}]');
  final tv = q.hasEpisode;
  final typeStr = tv ? 'shows' : 'movies';
  final s = '${q.season}', e = '${q.episode}';

  String? episodeIdFast(String html) {
    final sm = storageRe.firstMatch(html);
    if (sm != null) {
      final ss = seasonsRe.firstMatch(sm[1]!);
      if (ss != null) {
        try {
          final seasons = json.decode(ss[1]!) as List;
          final season = seasons.firstWhere((x) => '${dig(x, ['season']) ?? dig(x, ['meta', 'season'])}' == s, orElse: () => null);
          if (season != null) {
            final eps = season['episodes'];
            dynamic ep;
            if (eps is List) {
              ep = eps.firstWhere((x) => '${dig(x, ['episode'])}' == e, orElse: () => null);
            } else if (eps is Map) {
              ep = eps[e] ?? eps.values.firstWhere((x) => '${dig(x, ['episode'])}' == e, orElse: () => null);
            }
            if (ep != null) return '${ep['id_episode'] ?? ep['id']}';
          }
        } catch (_) {}
      }
    }
    final splitRe = RegExp(r'''id_episode['"]?\s*[:=]\s*['"]?(\d+)['"]?''', caseSensitive: false);
    final ms = splitRe.allMatches(html).toList();
    for (var i = 0; i < ms.length; i++) {
      final before = html.substring(i == 0 ? 0 : ms[i - 1].end, ms[i].start);
      final after = html.substring(ms[i].end, i + 1 < ms.length ? ms[i + 1].start : html.length);
      final context = (before.length > 300 ? before.substring(before.length - 300) : before) + (after.length > 300 ? after.substring(0, 300) : after);
      if (RegExp('[\'"]?episode[\'"]?\\s*[:=]\\s*[\'"]?$e[\'"]?', caseSensitive: false).hasMatch(context) &&
          RegExp('[\'"]?season[\'"]?\\s*[:=]\\s*[\'"]?$s[\'"]?', caseSensitive: false).hasMatch(context)) {
        return ms[i][1];
      }
    }
    final am = RegExp('data-season=["\']$s["\'][^>]*?data-episode=["\']$e["\'][^>]*?data-id=["\'](\\d+)["\']', caseSensitive: false).firstMatch(html) ??
        RegExp('data-episode=["\']$e["\'][^>]*?data-season=["\']$s["\'][^>]*?data-id=["\'](\\d+)["\']', caseSensitive: false).firstMatch(html);
    return am?[1];
  }

  try {
    final tmdb = await fetchJson('https://api.themoviedb.org/3/${tv ? 'tv' : 'movie'}/${q.id}?api_key=$tmdbKey', timeout: const Duration(seconds: 3));
    final title = (firstTruthy([dig(tmdb, ['title']), dig(tmdb, ['name'])]) as String?) ?? '';
    final date = '${firstTruthy([dig(tmdb, ['first_air_date']), dig(tmdb, ['release_date'])]) ?? ''}';
    final year = date.length >= 4 ? date.substring(0, 4) : date;
    if (title.isEmpty) return const [];

    Map? match;
    String? base;
    for (final b in domains) {
      try {
        final h = {...headersBase, 'Accept': 'application/json', 'Referer': '$b/', 'X-Requested-With': 'XMLHttpRequest'};
        final data = await fetchJson('$b/api/v1/$typeStr/do-search/?q=${Uri.encodeComponent(title)}', headers: h, timeout: const Duration(seconds: 4));
        final results = dig(data, ['result']);
        if (results is List && results.isNotEmpty) {
          match = (results.firstWhere((r) => '${dig(r, ['year'])}' == year, orElse: () => null) ??
              results.firstWhere((r) => (dig(r, ['title']) as String?)?.toLowerCase() == title.toLowerCase(), orElse: () => null) ??
              results.first) as Map?;
          if (match != null) {
            base = b;
            break;
          }
        }
      } catch (_) {}
    }
    if (match == null || base == null || !truthy(match['slug'])) return const [];

    final headers = {...headersBase, 'Accept': 'text/html', 'Referer': '$base/'};
    final html = await fetchText('$base/$typeStr/play/${match['slug']}', headers: headers, timeout: const Duration(seconds: 8));
    final storage = storageRe.firstMatch(html);
    if (storage == null) return const [];
    final hash = RegExp(r'''hash\s*:\s*['"]([^'"]+)['"]''').firstMatch(storage[1]!);
    final expires = RegExp(r'expires\s*:\s*(\d+)').firstMatch(storage[1]!);
    if (hash == null || expires == null) return const [];
    final streamId = tv ? episodeIdFast(html) : (firstTruthy([match['id_movie'], match['id']]) ?? idMovieRe.firstMatch(html)?[1]);
    if (streamId == null) return const [];

    final access = {...headersBase, 'Accept': 'application/json', 'Referer': '$base/', 'X-Requested-With': 'XMLHttpRequest'};
    final kind = tv ? 'episode' : 'movie';
    final data = await fetchJson('$base/api/v1/security/$kind-access?id_$kind=$streamId&hash=${hash[1]}&expires=${expires[1]}', headers: access, timeout: const Duration(seconds: 8));
    final streams = dig(data, ['streams']) ?? dig(data, ['result', 'streams']) ?? dig(data, ['data', 'streams']) ?? data;
    if (streams is! Map) return const [];
    return [
      for (final en in streams.entries)
        if (en.value is String && (en.value as String).contains('.m3u8')) FoundStream(url: en.value as String, server: 'LookMovie - ${en.key}', quality: '${en.key}', type: 'hls', headers: access),
    ];
  } catch (_) {
    return const [];
  }
}

/// cno.js: asks its 50 numbered servers at once
Future<List<FoundStream>> cno(FilmQuery q) async {
  const base = 'https://cno.to';
  const headers = {
    'Accept': 'application/json, text/plain, */*',
    'Referer': '$base/',
    'Origin': base,
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
  };
  const play = {'Referer': '$base/', 'Origin': base};
  Future<FoundStream?> one(int n) async {
    final url = q.hasEpisode ? '$base/api/s/$n/tv/${q.id}/${q.season}/${q.episode}' : '$base/api/s/$n/movie/${q.id}?v=3';
    try {
      final raw = await fetchText(url, headers: headers);
      if (raw.isEmpty || raw.contains('"error":')) return null;
      if (raw.contains('#EXTM3U')) {
        final lines = raw.split('\n');
        String? streamUrl;
        var quality = 'Auto';
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('#EXT-X-STREAM-INF:')) {
            final m = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(line);
            if (m != null) quality = m[1]!;
            final next = i + 1 < lines.length ? lines[i + 1].trim() : '';
            if (next.isNotEmpty && !next.startsWith('#')) {
              streamUrl = next;
              break;
            }
          }
        }
        streamUrl ??= lines.map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).firstOrNull;
        if (streamUrl != null) {
          if (streamUrl.startsWith('/')) streamUrl = '$base$streamUrl';
          return FoundStream(url: streamUrl, server: 'Cno - Server $n ($quality)', quality: quality, type: 'hls', headers: play);
        }
      }
      try {
        final js = json.decode(raw);
        final u = js is Map ? firstTruthy([js['url'], js['file'], js['stream']]) : null;
        if (u is String && u.startsWith('http')) {
          final qy = '${firstTruthy([js['quality']]) ?? 'Auto'}';
          return FoundStream(url: u, server: 'Cno - Server $n ($qy)', quality: qy, type: u.contains('.m3u8') ? 'hls' : 'mp4', headers: play);
        }
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  final results = await Future.wait([for (var n = 1; n <= 50; n++) one(n)]);
  return results.nonNulls.toList();
}

/// vidcore.js / vidfast.js / vidup.js
Future<List<FoundStream>> vidcore(FilmQuery q) => scrapeVidcoreFamily(q, baseUrl: 'https://vidcore.io', apiName: 'vidcore', serverLabel: 'VidCore');

Future<List<FoundStream>> vidup(FilmQuery q) => scrapeVidcoreFamily(q, baseUrl: 'https://vidup.to', apiName: 'vidup', serverLabel: 'VidUp');

/// cinebros.js (a stream of JSON objects, split by brace depth)
Future<List<FoundStream>> cinebros(FilmQuery q) async {
  const base = 'https://cinebros.net';
  const headers = {'User-Agent': sdkUA, 'Accept': '*/*', 'Accept-Language': 'en-US,en;q=0.9', 'Origin': base, 'Referer': '$base/'};
  const playback = {'User-Agent': sdkUA, 'Referer': '$base/', 'Origin': base};
  List<dynamic> parse(String text) {
    final items = <dynamic>[];
    var depth = 0, start = -1;
    var inString = false, escape = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == r'\') {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0 && start != -1) {
          try {
            items.add(json.decode(text.substring(start, i + 1)));
          } catch (_) {}
          start = -1;
        }
      }
    }
    return items;
  }

  int score(FoundStream s) {
    var n = 0;
    final m = RegExp(r'\d+').firstMatch(s.quality);
    if (m != null) n += int.parse(m[0]!);
    if (s.url.contains('/stream/')) n += 10000;
    if (s.url.contains('blob=')) n -= 5000;
    return n;
  }

  final tv = q.hasEpisode;
  final meta = await getTmdbMetadata(q.id, tv);
  final runtime = meta.runtime != 0 ? '${meta.runtime}' : (tv ? '24' : '90');
  final params = {
    'tmdbId': q.id,
    'type': tv ? 'tv' : 'movie',
    'title': meta.title.isNotEmpty ? meta.title : q.id,
    if (tv) ...{'seasonId': '${q.season}', 'episodeId': '${q.episode}'},
    if (meta.year != null) 'year': '${meta.year}',
    'runtime': runtime,
  };
  final referer = tv ? '$base/watch/tv/${q.id}/${q.season}/${q.episode}' : '$base/watch/movie/${q.id}';
  try {
    final res = await fetchRaw('$base/api/streams?${Uri(queryParameters: params).query}', headers: {...headers, 'Referer': referer}, timeout: const Duration(seconds: 25));
    if (res.statusCode >= 300) return const [];
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final item in parse(utf8.decode(res.bodyBytes, allowMalformed: true))) {
      final u = dig(item, ['url']);
      if (u is! String || !u.startsWith('http') || !seen.add(u)) continue;
      var quality = 'Auto';
      if (truthy(item['quality'])) {
        final q2 = '${item['quality']}'.trim();
        quality = RegExp(r'^\d+$').hasMatch(q2) ? '${q2}p' : q2;
      }
      final label = truthy(item['name']) ? 'CineBros - ${item['name']}' : 'CineBros ($quality)';
      final type = (firstTruthy([item['type']]) as String?) ?? (u.contains('.m3u8') || u.contains('/stream/') ? 'hls' : (u.contains('.mpd') ? 'dash' : 'mp4'));
      out.add(FoundStream(url: u, server: label, quality: quality, type: type, headers: playback));
    }
    out.sort((a, b) => score(b) - score(a));
    return out;
  } catch (_) {
    return const [];
  }
}

/// thugtv.js
Future<List<FoundStream>> thugtv(FilmQuery q) async {
  const base = 'https://thugtv.online';
  const apiBase = 'https://api.thugtv.online/api';
  final path = q.hasEpisode ? '/stream/tv/${q.id}/${q.season}/${q.episode}' : '/stream/movie/${q.id}';
  const headers = {
    'Accept': 'application/json',
    'Referer': '$base/',
    'Origin': base,
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
  };
  const play = {'Referer': '$base/', 'Origin': base};
  final res = await fetchJson('$apiBase$path', headers: headers).catchError((Object _) => null);
  final sources = dig(res, ['sources']);
  if (sources is! List || sources.isEmpty) return const [];
  final out = <FoundStream>[];
  for (final src in sources) {
    if (src is! Map || src['type'] == 'embed') continue;
    final u = src['url'];
    if (u is String && u.startsWith('http')) {
      out.add(FoundStream(
        url: u,
        server: 'ThugTV - ${firstTruthy([src['name'], src['label']]) ?? 'Direct'} (${firstTruthy([src['quality']]) ?? 'Auto'})',
        quality: '${firstTruthy([src['quality']]) ?? 'Auto'}',
        type: u.contains('.m3u8') ? 'hls' : 'mp4',
        headers: play,
      ));
      continue;
    }
    final rp = src['resolvePath'];
    if (rp is String && rp.isNotEmpty) {
      final clean = rp.startsWith('/') ? rp : '/$rp';
      try {
        final resolved = await fetchJson('$base/api$clean', headers: headers);
        final direct = dig(resolved, ['source', 'url']);
        if (direct is String && direct.startsWith('http')) {
          final s = resolved['source'];
          out.add(FoundStream(
            url: direct,
            server: 'ThugTV - ${firstTruthy([s['name'], s['label'], src['name']]) ?? 'Direct'}',
            quality: '${firstTruthy([s['quality'], src['quality']]) ?? 'Auto'}',
            type: direct.contains('.m3u8') ? 'hls' : 'mp4',
            headers: play,
          ));
        }
      } catch (_) {}
    }
  }
  return out;
}

/// framextv.js (FrameX's API and the StreamOS relay)
Future<List<FoundStream>> framextv(FilmQuery q) async {
  const framexBase = 'https://api.framextv.cc';
  const streamOsBase = 'https://api.streamos.top';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
  const framexHeaders = {'User-Agent': ua, 'Referer': 'https://framextv.cc/', 'Origin': 'https://framextv.cc', 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9'};
  const streamOsHeaders = {'User-Agent': ua, 'Referer': 'https://streamos.top/', 'Origin': 'https://streamos.top'};
  const servers = ['auto', 'miami', 'boise', 'vegas', 'reno', 'oakland', 'seattle', 'phoenix']; // STREAMOS_SERVERS.slice(0, 8)
  final tv = q.hasEpisode;
  final fq = tv ? 'type=tv&id=${q.id}&season=${q.season}&episode=${q.episode}&codecs=hevc' : 'type=movie&id=${q.id}&codecs=hevc';
  final sq = tv ? 'id=${q.id}&season=${q.season}&episode=${q.episode}&kind=tv' : 'id=${q.id}&kind=movie';
  final framex = Future.wait([
    for (final u in ['$framexBase/api/stream?$fq', '$framexBase/api/stream?$fq&provider=sparky', '$framexBase/api/stream?$fq&provider=titan'])
      fetchRaw(u, headers: framexHeaders, timeout: const Duration(seconds: 25)).then<dynamic>((r) => r.statusCode < 300 ? json.decode(r.body) : null, onError: (Object _) => null),
  ]);
  final streamOs = Future.wait([
    for (final server in servers)
      () async {
        final url = '$streamOsBase/api/relay/hls?$sq${server == 'auto' ? '' : '&server=$server'}';
        try {
          final r = await fetchRaw(url, method: 'HEAD', headers: streamOsHeaders, timeout: const Duration(seconds: 25));
          if (r.statusCode < 300) return FoundStream(url: url, server: 'StreamOS - ${server.toUpperCase()}', quality: '1080p', type: 'hls', headers: streamOsHeaders);
        } catch (_) {}
        return null;
      }(),
  ]);
  final (fr, sr) = await (framex, streamOs).wait;
  final out = <FoundStream>[];
  final seen = <String>{};
  for (final data in fr) {
    if (!truthy(dig(data, ['success'])) || data['sources'] is! List) continue;
    for (final src in data['sources'] as List) {
      final u = dig(src, ['url']);
      if (u is! String || u.isEmpty || !seen.add(u)) continue;
      out.add(FoundStream(
        url: u,
        server: 'FrameX - ${firstTruthy([src['server'], data['provider']]) ?? 'Direct'}',
        quality: '${firstTruthy([src['quality']]) ?? 'Auto'}',
        type: (firstTruthy([src['type']]) as String?) ?? (u.contains('.m3u8') ? 'hls' : 'mp4'),
        headers: const {'User-Agent': ua, 'Referer': 'https://framextv.cc/', 'Origin': 'https://framextv.cc'},
      ));
    }
  }
  for (final s in sr) {
    if (s != null && seen.add(s.url)) out.add(s);
  }
  return out;
}

/// lmscript.js (films only)
Future<List<FoundStream>> lmscript(FilmQuery q) async {
  const base = 'https://lmscript.xyz';
  const referer = 'https://lookmovie2.to/';
  if (q.hasEpisode) return const [];
  try {
    final meta = await getTmdbMetadata(q.id, false);
    if (meta.titles.isEmpty) return const [];
    Map? movie;
    for (final title in meta.titles) {
      final data = await fetchJson('$base/v1/movies?filters[q]=${Uri.encodeComponent(title)}&expand=streams').catchError((Object _) => null);
      if (data == null) continue;
      final items = dig(data, ['items']);
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        if ('${item['tmdb_prefix']}' == q.id || '${item['tmdb_id']}' == q.id || (item['title'] is String && (item['title'] as String).toLowerCase() == title.toLowerCase())) {
          movie = item;
          break;
        }
      }
      if (movie != null) break;
    }
    if (movie == null) return const [];
    final streams = movie['streams'] is Map ? movie['streams'] as Map : const {};
    const order = ['1080p', '720p', '480p', '360p'];
    final keys = streams.keys.map((k) => '$k').toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        if (ia != -1 && ib != -1) return ia - ib;
        if (ia != -1) return -1;
        if (ib != -1) return 1;
        return 0;
      });
    return [
      for (final r in keys)
        FoundStream(
          url: '${streams[r]}',
          quality: r,
          server: 'LookMovie - $r',
          type: '${streams[r]}'.contains('.m3u8') ? 'hls' : 'mp4',
          headers: const {'Referer': referer, 'User-Agent': sdkUA},
        ),
    ];
  } catch (_) {
    return const [];
  }
}

String _normQ(dynamic v) {
  if (!truthy(v)) return '1080p';
  final s = '$v'.trim();
  return RegExp(r'^\d+$').hasMatch(s) ? '${s}p' : s;
}

/// vidqueen.js
Future<List<FoundStream>> vidqueen(FilmQuery q) async {
  const base = 'https://api.vidqueen.st';
  const origin = 'https://vidqueen.st';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36';
  const headers = {
    'User-Agent': ua,
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': origin,
    'Referer': '$origin/',
    'Sec-Fetch-Site': 'same-site',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Dest': 'empty',
    'sec-ch-ua': '"Not-A.Brand";v="99", "Google Chrome";v="157", "Chromium";v="157"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
  };
  const playback = {'User-Agent': ua, 'Origin': origin, 'Referer': '$origin/'};
  const servers = [
    ('Bloodstone', 'sources=s1&hevc=1'),
    ('Garnet', 'sources=s2&hevc=1&vh=1'),
    ('Ruby', 'sources=s3&hevc=1&vh=1'),
    ('Obsidian', 'sources=s4&sw=1'),
    ('Jet', 'sources=s5&hevc=1&vh=1'),
  ];
  final prefix = q.hasEpisode ? 'tv?id=${q.id}&season=${q.season}&episode=${q.episode}&mode=json' : 'movie?id=${q.id}&mode=json';
  final responses = await Future.wait([
    for (final s in servers)
      fetchRaw('$base/$prefix&${s.$2}', headers: headers, timeout: const Duration(seconds: 10)).then<(String, dynamic)?>((r) {
        if (r.statusCode >= 300) return null;
        final d = json.decode(r.body);
        return truthy(dig(d, ['source'])) ? (s.$1, d) : null;
      }, onError: (Object _) => null),
  ]);
  final out = <FoundStream>[];
  final seen = <String>{};
  for (final r in responses) {
    if (r == null) continue;
    final src = r.$2['source'];
    final label = '${firstTruthy([src['label']]) ?? r.$1}';
    final manifest = src['manifest'];
    if (manifest is String && manifest.isNotEmpty) {
      final lines = manifest.split('\n').map((l) => l.trim()).toList();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        final u = i + 1 < lines.length ? lines[i + 1] : '';
        if (u.startsWith('http') && seen.add(u)) {
          final m = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false).firstMatch(lines[i]);
          out.add(FoundStream(url: u, server: 'Vidqueen - $label', quality: m == null ? '1080p' : '${m[1]}p', type: 'hls', headers: playback));
        }
      }
    }
    final qs = src['qualities'];
    final hasMp4 = qs is List && qs.any((x) => dig(x, ['type']) == 'mp4');
    if (hasMp4) {
      for (final x in qs) {
        final u = dig(x, ['url']);
        if (u is! String || u.isEmpty || !seen.add(u)) continue;
        out.add(FoundStream(url: u, server: 'Vidqueen - $label', quality: _normQ(x['quality']), type: 'mp4', headers: playback));
      }
    }
    final u = src['url'];
    if (truthy(u) && !hasMp4 && !truthy(manifest) && seen.add('$u')) {
      var raw = '1080p';
      if (truthy(src['h'])) {
        raw = '${src['h']}p';
      } else if (truthy(dig(qs, [0, 'quality'])) && dig(qs, [0, 'quality']) != 'Auto') {
        raw = '${dig(qs, [0, 'quality'])}';
      }
      out.add(FoundStream(url: '$u', server: 'Vidqueen - $label', quality: _normQ(raw), type: '$u'.contains('.m3u8') ? 'hls' : 'mp4', headers: playback));
    }
  }
  return out;
}

/// watchout.js
Future<List<FoundStream>> watchout(FilmQuery q) async {
  const api = 'https://raw.githubusercontent.com/Watchout2025/api/refs/heads/main/hls/';
  const headers = {'Origin': 'https://vidout.pages.dev', 'Referer': 'https://vidout.pages.dev'};
  bool isHls(String u) => u.contains('.m3u8') || u.contains('.txt') || u.contains('master') || !u.contains('.mp4');
  String? streamUrl;
  if (!q.hasEpisode) {
    final data = await fetchText('${api}movie/${q.id}').catchError((Object _) => '');
    if (!data.contains('://')) return const [];
    streamUrl = data.trim();
  } else {
    var data = await fetchJson('${api}tv/${q.id}/S${q.season}.json').catchError((Object _) => null);
    data ??= await fetchJson('${api}tv/${q.id}/s${q.season}.json').catchError((Object _) => null);
    final v = dig(data, ['${q.episode}']);
    streamUrl = truthy(v) ? '$v' : null;
  }
  if (streamUrl == null) return const [];
  return [FoundStream(url: streamUrl, server: 'Watchout - Direct', type: isHls(streamUrl) ? 'hls' : 'mp4', headers: headers)];
}

int _qWeight(String q) {
  final s = q.toLowerCase();
  if (s.contains('4k') || s.contains('2160')) return 2160;
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? 0 : int.parse(m[0]!);
}

/// vidspark.js
Future<List<FoundStream>> vidspark(FilmQuery q) async {
  const base = 'https://vidspark.to';
  const playerKey = '3a67e8866ae1d2bb9e81fe7f73315a56eb3bdf5e3e755c7554c8be6910aa6b13';
  const playback = {'User-Agent': sdkUA, 'Referer': '$base/', 'Origin': base};
  final tv = q.hasEpisode;
  final target = tv ? '$base/api/vidora/v1/tv/${q.id}/${q.season}/${q.episode}' : '$base/api/vidora/v1/movie/${q.id}';
  final referer = tv ? '$base/tv/${q.id}/${q.season}/${q.episode}' : '$base/movie/${q.id}';
  final headers = {'User-Agent': sdkUA, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9', 'Referer': referer, 'Origin': base, 'x-player-key': playerKey};

  Future<List<({String url, String quality})>?> variants(String master) async {
    try {
      final text = await fetchText(master, headers: playback, timeout: const Duration(seconds: 5));
      if (!text.contains('#EXTM3U') || !text.contains('#EXT-X-STREAM-INF')) return null;
      final baseUrl = master.substring(0, master.lastIndexOf('/') + 1);
      final lines = text.split('\n').map((l) => l.trim()).toList();
      final out = <({String url, String quality})>[];
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
        final m = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false).firstMatch(lines[i]);
        final next = i + 1 < lines.length ? lines[i + 1] : '';
        if (next.isNotEmpty && !next.startsWith('#')) out.add((url: next.startsWith('http') ? next : '$baseUrl$next', quality: m == null ? 'Auto' : '${m[1]}p'));
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  try {
    final data = await fetchJson(target, headers: headers, timeout: const Duration(seconds: 25));
    final sources = dig(data, ['sources']);
    if (!truthy(dig(data, ['result'])) || sources is! List || sources.isEmpty) return const [];
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final item in sources) {
      final u = dig(item, ['url']);
      if (u is! String || !u.startsWith('http')) continue;
      final src = item['source'];
      final label = src is String && src.isNotEmpty ? src[0].toUpperCase() + src.substring(1) : 'Direct';
      if (u.contains('.m3u8')) {
        for (final v in await variants(u) ?? const <({String url, String quality})>[]) {
          if (seen.add(v.url)) out.add(FoundStream(url: v.url, server: 'VidSpark - $label (${v.quality})', quality: v.quality, type: 'hls', headers: playback));
        }
      }
      if (seen.add(u)) {
        out.add(FoundStream(url: u, server: 'VidSpark - $label', type: u.contains('.m3u8') ? 'hls' : (u.contains('.mpd') ? 'dash' : 'mp4'), headers: playback));
      }
    }
    out.sort((a, b) => _qWeight(b.quality) - _qWeight(a.quality));
    return out;
  } catch (_) {
    return const [];
  }
}

/// willow.js
Future<List<FoundStream>> willow(FilmQuery q) async {
  const base = 'https://willowmovies.com';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
  const headers = {'User-Agent': ua, 'Referer': '$base/', 'Origin': base, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9'};
  const playback = {'User-Agent': ua, 'Referer': '$base/', 'Origin': base};
  String kind(dynamic t, String u) =>
      (firstTruthy([t]) as String?) ?? (u.contains('.m3u8') ? 'hls' : (u.contains('.mpd') ? 'dash' : (u.contains('.mkv') ? 'mkv' : 'mp4')));
  List<FoundStream> extract(dynamic data, [String? fallback]) {
    final list = <FoundStream>[];
    if (data is! Map) return list;
    final name = '${firstTruthy([dig(data, ['source', 'name']), dig(data, ['source', 'id']), fallback]) ?? 'Default'}';
    if (data['qualities'] is List) {
      for (final item in data['qualities'] as List) {
        final u = dig(item, ['url']);
        if (u is! String || u.isEmpty) continue;
        var quality = truthy(item['quality']) ? '${item['quality']}'.trim() : 'Auto';
        if (quality == '0p') {
          quality = 'Auto';
        } else if (RegExp(r'^\d+$').hasMatch(quality)) {
          quality = '${quality}p';
        }
        list.add(FoundStream(url: u, server: 'Willow - $name', quality: quality, type: kind(item['type'], u), headers: playback));
      }
    }
    final src = data['src'];
    if (src is String && src.isNotEmpty) list.add(FoundStream(url: src, server: 'Willow - $name', type: kind(data['type'], src), headers: playback));
    return list;
  }

  final query = q.hasEpisode ? 'id=${q.id}&type=tv&s=${q.season}&e=${q.episode}' : 'id=${q.id}&type=movie';
  try {
    final res = await fetchRaw('$base/api/stream?$query', headers: headers, timeout: const Duration(seconds: 10));
    if (res.statusCode >= 300) return const [];
    final initial = (() {
      try {
        return json.decode(res.body);
      } catch (_) {
        return null;
      }
    })();
    if (initial == null) return const [];
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final s in extract(initial)) {
      if (seen.add(s.url)) out.add(s);
    }
    final current = dig(initial, ['source', 'id']);
    final extra = (dig(initial, ['sources']) is List ? initial['sources'] as List : const []).where((s) => truthy(dig(s, ['id'])) && s['id'] != current).toList();
    if (extra.isNotEmpty) {
      final results = await Future.wait(extra.map((src) async {
        try {
          final r = await fetchRaw('$base/api/stream?$query&source=${Uri.encodeComponent('${src['id']}')}', headers: headers, timeout: const Duration(seconds: 8));
          if (r.statusCode >= 300) return const <FoundStream>[];
          return extract(json.decode(r.body), '${firstTruthy([src['name'], src['id']])}');
        } catch (_) {
          return const <FoundStream>[];
        }
      }));
      for (final list in results) {
        for (final s in list) {
          if (seen.add(s.url)) out.add(s);
        }
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// trendimovies.js (download links from the page's Astro island props)
Future<List<FoundStream>> trendimovies(FilmQuery q) async {
  const base = 'https://trendimovies.com';
  const headers = {'User-Agent': sdkUA, 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8', 'Accept-Language': 'en-US,en;q=0.9', 'Referer': '$base/'};
  const playback = {'User-Agent': sdkUA, 'Referer': '$base/'};
  const timeout = Duration(seconds: 25);

  dynamic unwrap(dynamic v) {
    if (v is List) {
      if (v.length == 2 && (v[0] == 0 || v[0] == 1)) return unwrap(v[1]);
      return v.map(unwrap).toList();
    }
    if (v is Map) return {for (final e in v.entries) e.key: unwrap(e.value)};
    return v;
  }

  String fileType(String url, dynamic item) {
    final ext = firstTruthy([dig(item, ['format']), dig(item, ['extension']), dig(item, ['ext']), dig(item, ['type'])]);
    if (ext != null) return '$ext'.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final l = url.toLowerCase();
    if (l.contains('.m3u8')) return 'hls';
    if (l.contains('.mpd')) return 'dash';
    if (l.contains('.mp4')) return 'mp4';
    if (l.contains('.avi')) return 'avi';
    return 'mkv';
  }

  List<FoundStream> links(dynamic raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    final out = <FoundStream>[];
    for (final item in raw) {
      final url = dig(item, ['url']) ?? dig(item, ['file_url']) ?? dig(item, ['link']);
      if (url is! String || !url.startsWith('http') || !seen.add(url)) continue;
      var quality = '${item['quality'] ?? item['resolution'] ?? 'Auto'}';
      if (RegExp(r'^\d+$').hasMatch(quality.trim())) quality = '${quality}p';
      final size = item['file_size'] ?? item['size'];
      final lang = item['language'];
      var label = 'TrendiMovies - $quality';
      if (truthy(lang)) label += ' ($lang)';
      if (truthy(size)) label += ' [$size]';
      out.add(FoundStream(url: url, server: label, quality: quality, type: fileType(url, item), headers: playback, audio: audioOf(lang)));
    }
    return out;
  }

  List<dynamic> islands(String html) {
    final out = <dynamic>[];
    for (final m in RegExp(r'<astro-island[^>]*props="([^"]+)"').allMatches(html)) {
      try {
        final decoded = m[1]!.replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>');
        final u = unwrap(json.decode(decoded));
        if (u != null) out.add(u);
      } catch (_) {}
    }
    return out;
  }

  List<FoundStream> all = const [];
  if (!q.hasEpisode) {
    try {
      final html = await fetchText('$base/movie/${q.id}', headers: headers, timeout: timeout);
      for (final island in islands(html)) {
        final raw = dig(island, ['links']) ?? dig(island, ['movie', 'downloads']) ?? dig(island, ['downloads']) ?? dig(island, ['movie', 'links']);
        final s = links(raw);
        if (s.isNotEmpty) {
          all = s;
          break;
        }
      }
    } catch (_) {}
  } else {
    String? html;
    try {
      html = await fetchText('$base/tv/${q.id}', headers: headers, timeout: timeout);
    } catch (_) {}
    if (html == null) {
      try {
        html = await fetchText('$base/show/${q.id}', headers: headers, timeout: timeout);
      } catch (_) {}
    }
    if (html != null) {
      dynamic bySeason, byEpisode;
      for (final island in islands(html)) {
        bySeason = dig(island, ['episodesBySeason']) ?? dig(island, ['show', 'episodes']) ?? dig(island, ['episodes']) ?? bySeason;
        byEpisode = dig(island, ['downloadsByEpisode']) ?? dig(island, ['downloads']) ?? byEpisode;
        if (bySeason != null && byEpisode != null) break;
      }
      final eps = dig(bySeason, ['${q.season}']);
      if (eps is List && byEpisode != null) {
        final ep = eps.firstWhere((x) => '${dig(x, ['episode_number'])}' == '${q.episode}', orElse: () => null);
        if (ep != null && ep['id'] != null) all = links(dig(byEpisode, ['${ep['id']}']));
      }
    }
  }
  return [...all]..sort((a, b) => _qWeight(b.quality) - _qWeight(a.quality));
}

/// vidvault.js (download pages; starts a conversion job when a quality isn't ready)
Future<List<FoundStream>> vidvault(FilmQuery q) async {
  const base = 'https://vidvault.to';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  const headers = {
    'User-Agent': ua,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': '$base/',
  };
  const playback = {'User-Agent': ua, 'Referer': '$base/'};
  final tv = q.hasEpisode;
  final type = tv ? 'tv' : 'movie';
  String path(String kind, String quality) => tv ? '$base/$kind/$type/${q.id}/${q.season}/${q.episode}/$quality' : '$base/$kind/$type/${q.id}/$quality';
  int qn(String s) => int.tryParse(RegExp(r'^\d+').stringMatch(s) ?? '') ?? 0;

  Future<String?> download(String quality) async {
    try {
      final r = await fetchRaw(path('download-link', quality), headers: {...headers, 'Accept': 'application/json'}, timeout: const Duration(seconds: 4));
      if (r.statusCode >= 300) return null;
      final u = dig(json.decode(r.body), ['url']);
      if (!truthy(u)) return null;
      var clean = '$u'.split('?').first.split('#').first;
      if (!clean.endsWith('.mkv') && !clean.endsWith('.mp4')) clean += '.mkv';
      return clean;
    } catch (_) {
      return null;
    }
  }

  Future<bool> poll(String jobId) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 12000) {
      try {
        final r = await fetchRaw('$base/job/$jobId?t=${DateTime.now().millisecondsSinceEpoch}', headers: headers, timeout: const Duration(seconds: 3));
        if (r.statusCode < 300) {
          final st = dig(json.decode(r.body), ['status']);
          if (st == 'done') return true;
          if (st == 'error') return false;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return false;
  }

  try {
    final res = await fetchRaw(tv ? '$base/tv/${q.id}/${q.season}/${q.episode}' : '$base/movie/${q.id}', headers: headers, timeout: const Duration(seconds: 25));
    if (res.statusCode >= 300) return const [];
    final html = res.body;
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final m in RegExp(r'''<div[^>]*class=["'][^"']*quality-item[^"']*["'][^>]*>([\s\S]*?)</div>''', caseSensitive: false).allMatches(html)) {
      final block = m[1]!;
      final um = RegExp(r'''window\.location\.href\s*=\s*['"]([^'"]+)['"]''', caseSensitive: false).firstMatch(block);
      if (um == null) continue;
      final u = um[1]!.trim();
      if (!seen.add(u)) continue;
      final quality = RegExp(r'Download\s*([0-9a-zA-Z]+)', caseSensitive: false).firstMatch(block)?[1]!.trim() ?? 'Auto';
      final size = RegExp(r'<small>\(([^)]+)\)</small>', caseSensitive: false).firstMatch(block)?[1]!.trim() ?? '';
      out.add(FoundStream(url: u, server: 'VidVault - ${quality.toUpperCase()}${size.isEmpty ? '' : ' ($size)'}', quality: quality, type: 'mkv', headers: playback));
    }
    if (out.isNotEmpty) return out..sort((a, b) => qn(b.quality) - qn(a.quality));

    final found = RegExp(r'''id=["']item-([0-9a-zA-Z]+)["']''', caseSensitive: false).allMatches(html).map((m) => m[1]!).toList();
    final qualities = found.isNotEmpty ? found : const ['1080p', '720p', '360p'];
    await Future.wait(qualities.map((quality) async {
      var u = await download(quality);
      if (u == null) {
        try {
          final r = await fetchRaw(path('start-conversion', quality), method: 'POST', headers: headers, timeout: const Duration(seconds: 6));
          if (r.statusCode < 300) {
            final job = dig(json.decode(r.body), ['jobId']);
            if (job == 'existing') {
              u = await download(quality);
            } else if (truthy(job) && await poll('$job')) {
              u = await download(quality);
            }
          }
        } catch (_) {}
      }
      if (u != null && seen.add(u)) out.add(FoundStream(url: u, server: 'VidVault - ${quality.toUpperCase()}', quality: quality, type: 'mkv', headers: playback));
    }));
    return out..sort((a, b) => qn(b.quality) - qn(a.quality));
  } catch (_) {
    return const [];
  }
}

/// torrentio.js: reads s.torrentio.to's event stream and stops at the first batch of sources
Future<List<FoundStream>> torrentio(FilmQuery q) async {
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0';
  const playback = {'User-Agent': ua, 'Referer': 'https://stream.vidplay.to/', 'Origin': 'https://stream.vidplay.to'};
  final path = q.hasEpisode ? '/v1/sources/stream?type=tv&id=${q.id}&s=${q.season}&e=${q.episode}' : '/v1/sources/stream?type=movie&id=${q.id}';
  final rq = http.Request('GET', Uri.parse('https://s.torrentio.to$path'))
    ..headers.addAll(const {
      'Accept': 'text/event-stream',
      'Accept-Language': 'en-US,en;q=0.9',
      'Origin': 'https://stream.vidplay.to',
      'Referer': 'https://stream.vidplay.to/',
      'Sec-CH-UA': '"Not-A.Brand";v="99", "Microsoft Edge";v="157", "Chromium";v="157"',
      'Sec-CH-UA-Mobile': '?0',
      'Sec-CH-UA-Platform': '"Windows"',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'cross-site',
      'User-Agent': ua,
      'Connection': 'keep-alive',
    });
  final out = <FoundStream>[];
  final seen = <String>{};
  try {
    final res = await netClient.send(rq).timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) return const [];
    await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(const Duration(seconds: 25))) {
      final t = line.trim();
      if (!t.startsWith('data: ')) continue;
      try {
        final data = json.decode(t.substring(6));
        for (final src in (dig(data, ['sources']) as List?) ?? const []) {
          final u = dig(src, ['url']);
          if (u is! String || u.isEmpty || !seen.add(u)) continue;
          final prov = firstTruthy([dig(src, ['provider', 'name']), dig(data, ['provider', 'name'])]) ?? 'Server';
          final raw = truthy(src['quality']) ? '${src['quality']}'.trim() : 'Auto';
          out.add(FoundStream(
            url: u,
            server: 'Torrentio - $prov',
            quality: RegExp(r'^\d+$').hasMatch(raw) ? '${raw}p' : raw,
            type: (firstTruthy([src['type']]) as String?) ?? (u.contains('.m3u8') ? 'hls' : 'mp4'),
            headers: playback,
          ));
        }
      } catch (_) {}
      if (out.isNotEmpty) break;
    }
  } catch (_) {}
  return out;
}

dynamic _json(String body) {
  try {
    return json.decode(body);
  } catch (_) {
    return null;
  }
}

/// braflix.js
Future<List<FoundStream>> braflix(FilmQuery q) async {
  const base = 'https://braflix.dev';
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
  const headers = {'Origin': base, 'Referer': '$base/', 'User-Agent': ua, 'Accept': 'application/json, text/plain, */*'};
  const playback = {'Origin': base, 'Referer': '$base/'};
  final path = q.hasEpisode ? '/api/play/tv/${q.tmdbId}/${q.season}/${q.episode}' : '/api/play/movie/${q.tmdbId}';
  try {
    final res = await fetchRaw('$base$path', headers: headers, timeout: const Duration(seconds: 10));
    if (res.statusCode >= 300) return const [];
    final data = _json(res.body);
    final raw = dig(data, ['result', 'file', 'stream']);
    if (dig(data, ['status']) != 'ready' || raw is! String || raw.isEmpty) return const [];
    final full = raw.startsWith('http') ? raw : '$base$raw';
    final qualityRaw = '${firstTruthy([dig(data, ['result', 'source', 'quality'])]) ?? '1080,720,480'}';
    final parts = qualityRaw.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    final maxQ = parts.fold<int>(0, (acc, c) => (int.tryParse(RegExp(r'^\d+').stringMatch(c) ?? '') ?? 0) > acc ? int.parse(RegExp(r'^\d+').stringMatch(c)!) : acc);
    final summary = parts.isNotEmpty ? parts.map((x) => '${x}p').join('/') : 'DASH';
    final type = full.contains('.mpd') ? 'dash' : (full.contains('.m3u8') ? 'hls' : 'dash');
    return [FoundStream(url: full, server: 'Braflix - DASH ($summary)', quality: maxQ > 0 ? '${maxQ}p' : 'Auto', type: type, headers: playback)];
  } catch (_) {
    return const [];
  }
}

/// moviebox.js (the same net79.cc API as net79.js, played with an mzfi.me referer)
Future<List<FoundStream>> moviebox(FilmQuery q) async {
  const base = 'https://net79.cc';
  const headers = {'Accept': 'application/json', 'Referer': '$base/', 'Origin': base, 'User-Agent': sdkUA};
  const playback = {'Referer': 'https://mzfi.me/'};
  final url = q.hasEpisode ? '$base/api/embed-tmdb/${q.id}?type=tv&se=${q.season}&ep=${q.episode}' : '$base/api/embed-tmdb/${q.id}?type=movie';
  String size(dynamic b) {
    final n = b is num ? b : int.tryParse('$b');
    if (n == null || n == 0) return '';
    final gb = n / (1024 * 1024 * 1024);
    return gb >= 1 ? '${gb.toStringAsFixed(2)} GB' : '${(n / (1024 * 1024)).round()} MB';
  }

  try {
    final payload = await fetchJson(url, headers: headers, timeout: const Duration(seconds: 8));
    if (!truthy(dig(payload, ['ok'])) || truthy(payload['noSource'])) return const [];
    final list = payload['streams'] is List && (payload['streams'] as List).isNotEmpty
        ? payload['streams'] as List
        : (truthy(payload['mp4']) ? [{'url': payload['mp4'], 'resolution': firstTruthy([payload['resolution']]) ?? 720}] : const []);
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final item in list) {
      final u = dig(item, ['url']);
      if (u is! String || !u.startsWith('http') || !seen.add(u)) continue;
      final res = truthy(item['resolution']) ? '${item['resolution']}p' : '720p';
      final s = truthy(item['size']) ? size(item['size']) : '';
      out.add(FoundStream(url: u, server: 'MovieBox $res${s.isEmpty ? '' : ' [$s]'}', quality: res, type: u.contains('.m3u8') ? 'hls' : 'mp4', headers: playback));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// vixsrc.js (no SDK proxy in front, as with its default absoluteBase '/')
Future<List<FoundStream>> vixsrc(FilmQuery q) async {
  const base = 'https://vixsrc.to';
  const headers = {
    'User-Agent': sdkUA,
    'Accept': 'application/json, text/javascript, */*; q=0.01',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': '$base/',
    'Origin': base,
  };
  String? extract(RegExp re, String text) {
    final m = re.firstMatch(text);
    if (m == null) return null;
    return m[1]!.replaceAll(RegExp(r'\\u0026', caseSensitive: false), '&').replaceAll(r'\/', '/').replaceAll(r'\', '');
  }

  try {
    final apiUrl = q.hasEpisode ? '$base/api/tv/${q.id}/${q.season}/${q.episode}' : '$base/api/movie/${q.id}';
    final apiText = await fetchText(apiUrl, headers: headers).catchError((Object _) => '');
    final apiData = json.decode(apiText.isEmpty ? '{}' : apiText);
    final src = dig(apiData, ['src']);
    if (src is! String || src.isEmpty) return const [];
    final embedUrl = src.startsWith('http') ? src : '$base$src';
    final html = await fetchText(embedUrl, headers: headers).catchError((Object _) => '');
    if (html.isEmpty) return const [];
    final token = extract(RegExp(r'''token["']\s*:\s*["']([^"']+)'''), html);
    final expires = extract(RegExp(r'''expires["']\s*:\s*["']([^"']+)'''), html);
    var playlist = extract(RegExp(r'''url["']\s*:\s*["']([^"']+)'''), html);
    if (token == null || expires == null || playlist == null) return const [];
    if (playlist.startsWith('/')) playlist = '$base$playlist';
    final lang = extract(RegExp(r'''lang(?:uage)?["']\s*:\s*["']([a-z]{2,5})''', caseSensitive: false), html) ?? 'en';
    final sep = playlist.contains('?') ? '&' : '?';
    final master = '$playlist${sep}token=$token&expires=$expires&h=1&lang=$lang';
    final text = await fetchText(master, headers: {...headers, 'Referer': embedUrl}).catchError((Object _) => '');
    if (!text.contains('#EXTM3U')) return const [];
    final tracks = <({String name, String lang})>[];
    final seen = <String>{};
    for (final line in text.split('\n')) {
      if (line.startsWith('#EXT-X-MEDIA') && line.contains('TYPE=AUDIO')) {
        final name = RegExp(r'''NAME=["']([^"']+)["']''').firstMatch(line)?[1] ?? 'Default';
        final rendition = RegExp(r'rendition=([a-zA-Z0-9_-]+)').firstMatch(line)?[1] ?? RegExp(r'''LANGUAGE=["']([^"']+)["']''').firstMatch(line)?[1] ?? name;
        if (seen.add(rendition.toLowerCase())) tracks.add((name: name, lang: rendition));
      }
    }
    final play = {...headers, 'Referer': '$base/'};
    if (tracks.isEmpty) return [FoundStream(url: master, server: 'VixSrc', type: 'hls', headers: play)];
    return [
      for (final t in tracks)
        FoundStream(url: '$playlist${sep}token=$token&expires=$expires&h=1&lang=${t.lang}', server: 'VixSrc (${t.name})', type: 'hls', headers: play, audio: audioOf(t.name)),
    ];
  } catch (_) {
    return const [];
  }
}

/// 111477.js
Future<List<FoundStream>> s111477(FilmQuery q) async {
  const origin = 'https://st.111477.xyz';
  final tv = q.hasEpisode;
  final ua = getUA();
  final imdb = await resolveImdbId(q.id, tv);
  final targets = [if (imdb.startsWith('tt')) imdb, 'tmdb:${q.id}'];
  // the JS appends `::tmdb=<key>` when it has one; Lorewatch doesn't hand its key to the addon
  const config = 'https://a.111477.xyz/::sort=file-desc::limit=3';
  final b64 = base64.encode(utf8.encode(config)).replaceAll('+', '-').replaceAll('/', '_').replaceAll(RegExp(r'=+$'), '');
  final addonBase = '$origin/config/$b64';
  final headers = {'User-Agent': ua, 'Accept': 'application/json, text/plain, */*'};
  final out = <FoundStream>[];
  final seen = <String>{};
  for (final t in targets) {
    final endpoint = tv ? '$addonBase/stream/series/$t:${q.season}:${q.episode}.json' : '$addonBase/stream/movie/$t.json';
    try {
      final res = await fetchRaw(endpoint, headers: headers, timeout: const Duration(seconds: 12));
      if (res.statusCode >= 300) continue;
      final streams = dig(_json(res.body), ['streams']);
      if (streams is List && streams.isNotEmpty) {
        for (final item in streams) {
          if (item is! Map) continue;
          final u = '${item['url'] ?? ''}'.trim();
          if (u.isEmpty || !u.startsWith('http') || !seen.add(u)) continue;
          final title = item['title'] != null ? '${item['title']}'.trim() : '';
          final name = item['name'] != null ? '${item['name']}'.trim() : '111477';
          final label = title.isNotEmpty ? title : name;
          out.add(FoundStream(url: u, label: label, server: label, type: u.contains('.m3u8') ? 'hls' : 'mp4', headers: headers));
        }
        if (out.isNotEmpty) break;
      }
    } catch (_) {}
  }
  return out;
}

/// anizone.js (anime only)
Future<List<FoundStream>> anizone(FilmQuery q) async {
  const base = 'https://anizone.to';
  const headers = {'User-Agent': sdkUA, 'Referer': '$base/', 'Origin': base};
  const playback = {'Referer': '$base/', 'Origin': base};
  dynamic decodeArg(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    const marker = '\x01U\x01';
    var v = raw.replaceAllMapped(RegExp(r'\\\\u([0-9a-fA-F]{4})'), (m) => '$marker${m[1]}');
    v = v.replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
    v = v.replaceAllMapped(RegExp('\x01U\x01([0-9a-fA-F]{4})'), (m) => '\\u${m[1]}');
    try {
      return json.decode(v);
    } catch (_) {
      return null;
    }
  }

  String clean(String? t) => (t ?? '')
      .toLowerCase()
      .replaceAll(RegExp(r'\s*[-–—:]\s*\d+(?:st|nd|rd|th)?\s*(?:&|\+)?\s*\d*(?:st|nd|rd|th)?\s*(?:stage|cour|part|season).*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[-–—:]\s*part\s+[ivx\d]+.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*[-–—:]\s*season\s+\d+.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\(\d{4}\)$'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final tv = q.hasEpisode;
  final meta = await getTmdbMetadata(q.id, tv);
  if (!meta.isAnime) return const [];
  final target = tv ? (q.episode ?? 1) : 1;
  final titles = meta.titles.isNotEmpty ? meta.titles : [meta.title.isNotEmpty ? meta.title : q.id];
  try {
    final found = <dynamic>[];
    final slugs = <String>{};
    for (final title in titles.take(4)) {
      final html = await fetchText('$base/anime?search=${Uri.encodeComponent(title)}', headers: headers, timeout: const Duration(seconds: 8));
      final items = decodeArg(RegExp(r"items\s*:\s*JSON\.parse\('((?:[^'\\]|\\.)*)'\)", caseSensitive: false).firstMatch(html)?[1]);
      if (items is List) {
        for (final item in items) {
          final slug = dig(item, ['slug']);
          if (slug != null && slugs.add('$slug')) found.add(item);
        }
      }
      if (found.length >= 3) break;
    }
    if (found.isEmpty) return const [];
    final targets = titles.map(clean).where((t) => t.isNotEmpty).toList();
    dynamic matched;
    for (final item in found) {
      final list = item['title_list'];
      final itemTitles = [item['main_title'], if (list is Map) ...list.values].map((t) => clean(t == null ? null : '$t')).where((t) => t.isNotEmpty).toList();
      if (targets.any((ct) => itemTitles.contains(ct))) {
        matched = item;
        break;
      }
    }
    matched ??= found.first;
    final watchHtml = await fetchText('$base/anime/${matched['slug']}/$target', headers: headers, timeout: const Duration(seconds: 8));
    final player = decodeArg(RegExp(r"vidstackPlayer\s*\(\s*JSON\.parse\('((?:[^'\\]|\\.)*)'\)\s*\)", caseSensitive: false).firstMatch(watchHtml)?[1]);
    final src = dig(player, ['src']);
    final master = src == null ? null : '$src'.replaceAll(RegExp(r'\\+/'), '/');
    if (master == null || !master.startsWith('http')) return const [];
    final out = <FoundStream>[];
    final seen = <String>{};
    if (master.contains('.m3u8')) {
      for (final v in await _variants(master, playback, const Duration(seconds: 4)) ?? const <({String url, String quality})>[]) {
        if (seen.add(v.url)) out.add(FoundStream(url: v.url, server: 'AniZone (${v.quality})', quality: v.quality, type: 'hls', headers: playback));
      }
    }
    if (seen.add(master)) out.add(FoundStream(url: master, server: 'AniZone', type: master.contains('.m3u8') ? 'hls' : 'mp4', headers: playback));
    out.sort((a, b) => _qn(b.quality) - _qn(a.quality));
    return out;
  } catch (_) {
    return const [];
  }
}

String? _shiroCookie;

DateTime _shiroUntil = DateTime.fromMillisecondsSinceEpoch(0);

Future<String> _anvCookie() async {
  const base = 'https://anv.to';
  if (_shiroCookie != null && DateTime.now().isBefore(_shiroUntil)) return _shiroCookie!;
  try {
    var target = '$base/anime/aoki-denshou-welsh-shedar-626fd-episode-5';
    try {
      final xml = await fetchText('$base/recents.xml', timeout: const Duration(milliseconds: 3500));
      final m = RegExp(r'<link>(https://anv\.to/anime/[^<]+)</link>').firstMatch(xml);
      if (m != null) target = m[1]!;
    } catch (_) {}
    final res = await fetchRaw(target,
        headers: const {'User-Agent': sdkUA, 'Referer': '$base/', 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'},
        timeout: const Duration(seconds: 4));
    final m = RegExp(r'shiro_watch=([^;,]+)').firstMatch(res.headers['set-cookie'] ?? '');
    if (m != null) {
      _shiroCookie = 'shiro_watch=${m[1]!.trim()}';
      _shiroUntil = DateTime.now().add(const Duration(hours: 20));
    }
    return _shiroCookie ?? '';
  } catch (_) {
    return '';
  }
}

/// anv.js (anime only: AniList ids by title, then its episode API)
Future<List<FoundStream>> anv(FilmQuery q) async {
  const base = 'https://anv.to';
  final tv = q.hasEpisode;
  final meta = await getTmdbMetadata(q.id, tv);
  if (!meta.isAnime) return const [];
  final title = meta.title.isNotEmpty ? meta.title : (meta.titles.isNotEmpty ? meta.titles.first : null);
  if (title == null) return const [];
  dynamic anilistId, malId;
  try {
    final r = await fetchRaw('https://graphql.anilist.co',
        method: 'POST',
        headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
        body: json.encode({'query': r'query($search: String) { Media(search: $search, type: ANIME) { id idMal } }', 'variables': {'search': title}}),
        timeout: const Duration(seconds: 5));
    if (r.statusCode < 300) {
      final d = json.decode(r.body);
      anilistId = dig(d, ['data', 'Media', 'id']);
      malId = dig(d, ['data', 'Media', 'idMal']);
    }
  } catch (_) {}
  if (anilistId == null) return const [];
  final episode = tv ? (q.episode ?? 1) : 1;
  final cookie = await _anvCookie();
  try {
    final res = await fetchRaw('$base/api/episode',
        method: 'POST',
        headers: {'Content-Type': 'application/json', 'Origin': base, 'Referer': '$base/', 'User-Agent': sdkUA, if (cookie.isNotEmpty) 'Cookie': cookie, 'Accept': '*/*'},
        body: json.encode({'anilistId': anilistId, 'malId': malId, 'episode': episode}),
        timeout: const Duration(seconds: 5));
    if (res.statusCode >= 300) return const [];
    final data = json.decode(res.body);
    final variants = dig(data, ['variants']);
    if (dig(data, ['status']) != 'ready' || variants is! List || variants.isEmpty) return const [];
    final playback = {'Origin': base, 'Referer': '$base/', if (cookie.isNotEmpty) 'Cookie': cookie, 'User-Agent': sdkUA};
    final out = <FoundStream>[];
    final seen = <String>{};
    for (final v in variants) {
      final vType = '${firstTruthy([dig(v, ['id'])]) ?? 'sub'}'.toLowerCase();
      final vLabel = '${firstTruthy([dig(v, ['label'])]) ?? (vType == 'dub' ? 'Dub' : 'Sub')}';
      for (final src in (dig(v, ['sources']) as List?) ?? const []) {
        final u = dig(src, ['url']);
        if (u is! String || u.isEmpty) continue;
        final full = u.startsWith('http') ? u : '$base$u';
        if (!seen.add(full)) continue;
        out.add(FoundStream(
          url: full,
          server: 'ANV - ${'${firstTruthy([src['label']]) ?? 'Default'}'.trim()} ($vLabel)',
          type: full.contains('.m3u8') ? 'hls' : 'mp4',
          headers: playback,
        ));
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 123anime.js (anime only, by TMDB title)
Future<List<FoundStream>> anime123(FilmQuery q) async {
  const base = 'https://123animehub.cc';
  const cdnOrigin = 'https://play2.echovideo.ru';
  if (q.season == null) return const [];
  final meta = await getTmdbMetadata(q.id, q.hasEpisode);
  if (!meta.isAnime) return const [];

  final keywords = <String>[];
  for (final title in meta.titles) {
    final t = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!keywords.contains(t)) keywords.add(t);
    final words = title.split(RegExp(r'[\s:]+')).where((w) => w.length > 2).toList();
    if (words.length >= 2) {
      final short = words.take(3).join(' ').toLowerCase();
      if (!keywords.contains(short)) keywords.add(short);
    }
  }
  final slugs = <String>[];
  for (final k in keywords) {
    try {
      final data = await fetchJson('$base/ajax/film/search?keyword=${Uri.encodeComponent(k)}&_=${DateTime.now().millisecondsSinceEpoch}',
          headers: const {'X-Requested-With': 'XMLHttpRequest', 'Referer': '$base/', 'Accept': 'application/json', 'User-Agent': sdkUA},
          timeout: const Duration(seconds: 8));
      final html = '${dig(data, ['html']) ?? ''}';
      var idx = 0;
      while ((idx = html.indexOf('href="/anime/', idx)) != -1) {
        final start = idx + 13;
        final end = html.indexOf('"', start);
        final slug = html.substring(start, end);
        if (!slugs.contains(slug)) slugs.add(slug);
        idx = end;
      }
    } catch (_) {}
    if (slugs.isNotEmpty) break;
  }
  String? target;
  for (final slug in slugs) {
    try {
      final epr = q.season != null ? '$slug/${q.season}/${q.episode}' : '$slug/1';
      final data = await fetchJson('$base/ajax/episode/info?epr=${Uri.encodeComponent(epr)}&ts=1&_=${DateTime.now().millisecondsSinceEpoch}',
          headers: {'Referer': '$base/anime/$slug', 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json, text/javascript, */*; q=0.01', 'User-Agent': sdkUA},
          timeout: const Duration(seconds: 10));
      if (truthy(dig(data, ['target']))) {
        target = '${data['target']}';
        break;
      }
    } catch (_) {}
  }
  if (target == null) return const [];
  final embed = RegExp(r'/embed-[^/]+/([A-Za-z0-9+/=]+)$').firstMatch(target);
  if (embed == null) return const [];
  final origin = Uri.parse(target).origin;
  try {
    final embedRes = await fetchRaw(target, headers: const {'User-Agent': sdkUA}, timeout: const Duration(seconds: 10));
    if (embedRes.statusCode >= 300) return const [];
    final setCookie = embedRes.headers['set-cookie'];
    final data = await fetchJson('$origin/hs/getSources?id=${embed[1]}',
        headers: {'Referer': target, 'Accept': '*/*', 'User-Agent': sdkUA, if (setCookie != null) 'Cookie': setCookie.split(';').first.trim()},
        timeout: const Duration(seconds: 10));
    final srcs = dig(data, ['sources']);
    final url = srcs is String && srcs.isNotEmpty ? srcs : (srcs is List && srcs.isNotEmpty ? firstTruthy([dig(srcs, [0, 'file']), dig(srcs, [0, 'src']), dig(srcs, [0, 'url'])]) : null);
    if (url is! String) return const [];
    return [FoundStream(url: url, server: '123Anime', type: url.contains('.m3u8') ? 'hls' : 'mp4', headers: const {'Referer': '$cdnOrigin/', 'Origin': cdnOrigin})];
  } catch (_) {
    return const [];
  }
}

/// hexa.js — delegates challenge solving and decryption to enc-dec.app.
const _hexaBase = 'https://theemoviedb.hexa.su';
const _hexaCapUrl = 'https://cap.hexa.su/15d2cf0395';
const _hexaDecApi = 'https://enc-dec.app/api';
const _hexaUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

const _hexaChallengeHeaders = {
  'Content-Type': 'application/json',
  'Accept': 'application/json',
  'Accept-Language': 'en-US,en;q=0.9,ru;q=0.8,fr;q=0.7,bg;q=0.6,pl;q=0.5,id;q=0.4,zh-CN;q=0.3,zh;q=0.2,ja;q=0.1,es;q=0.1',
  'Origin': 'https://hexa.su',
  'Referer': 'https://hexa.su/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 OPR/129.0.0.0 (Edition std-2)',
};

const _hexaPlaybackHeaders = {
  'User-Agent': _hexaUA,
  'Referer': 'https://hexa.su/',
  'Origin': 'https://hexa.su',
};

String? _cachedCapToken;
int _tokenUseCount = 0;

Future<String?> _fetchCapToken() async {
  if (_cachedCapToken != null && _tokenUseCount < 18) {
    _tokenUseCount++;
    return _cachedCapToken;
  }
  try {
    final chalRes = await fetchJson('$_hexaCapUrl/challenge',
        method: 'POST', headers: _hexaChallengeHeaders, body: '{}', timeout: const Duration(seconds: 8));

    final encRes = await fetchJson('$_hexaDecApi/enc-hexa',
        method: 'POST',
        headers: {'Content-Type': 'application/json', 'User-Agent': _hexaUA},
        body: json.encode({'challenge_data': chalRes}),
        timeout: const Duration(seconds: 8));
    if (dig(encRes, ['status']) != 200 || !truthy(dig(encRes, ['result']))) return null;

    final redeemRes = await fetchJson('$_hexaCapUrl/redeem',
        method: 'POST',
        headers: _hexaChallengeHeaders,
        body: json.encode(encRes['result']),
        timeout: const Duration(seconds: 8));

    final token = dig(redeemRes, ['token']);
    if (token is String && token.isNotEmpty) {
      _cachedCapToken = token;
      _tokenUseCount = 1;
      return token;
    }
  } catch (_) {
    _cachedCapToken = null;
  }
  return null;
}

List<FoundStream> _extractHexaStreams(dynamic result) {
  if (result == null) return const [];
  dynamic data = result;
  if (data is String) {
    if (data.startsWith('{') || data.startsWith('[')) {
      try { data = json.decode(data); } catch (_) {}
    }
  }
  if (data is String && RegExp(r'^https?://').hasMatch(data)) {
    return [FoundStream(
      url: data,
      server: 'Hexa - Direct',
      quality: 'Auto',
      type: data.contains('.m3u8') ? 'hls' : (data.contains('.mpd') ? 'dash' : 'mp4'),
      headers: _hexaPlaybackHeaders,
    )];
  }
  final rawSources = data is List
      ? data
      : data is Map
          ? (data['sources'] is List ? data['sources'] : (data['streams'] is List ? data['streams'] : const []))
          : const [];

  final list = <FoundStream>[];
  for (final item in rawSources) {
    final streamUrl = (item is Map ? (item['url'] ?? item['file'] ?? item['src']) : (item is String ? item : null))?.toString();
    if (streamUrl == null || !streamUrl.startsWith('http')) continue;
    var quality = (item is Map ? (item['quality'] ?? item['label']) : null)?.toString() ?? 'Auto';
    if (RegExp(r'^\d+$').hasMatch(quality)) quality = '${quality}p';
    final t = (item is Map ? item['type'] : null)?.toString();
    list.add(FoundStream(
      url: streamUrl,
      server: 'Hexa - ${item is Map ? (item['server'] ?? item['name'] ?? 'Direct') : 'Direct'}',
      quality: quality,
      type: t ?? (streamUrl.contains('.m3u8') ? 'hls' : (streamUrl.contains('.mpd') ? 'dash' : 'mp4')),
      headers: _hexaPlaybackHeaders,
    ));
  }
  if (data is Map && data['url'] is String && (data['url'] as String).startsWith('http')) {
    final u = data['url'] as String;
    list.add(FoundStream(
      url: u,
      server: 'Hexa - ${data['server'] ?? 'Direct'}',
      quality: (data['quality'] ?? 'Auto').toString(),
      type: (data['type'] ?? (u.contains('.m3u8') ? 'hls' : (u.contains('.mpd') ? 'dash' : 'mp4'))).toString(),
      headers: _hexaPlaybackHeaders,
    ));
  }
  return list;
}

Future<List<FoundStream>> hexa(FilmQuery q) async {
  final path = q.hasEpisode
      ? '/api/tmdb/tv/${q.id}/season/${q.season}/episode/${q.episode}/images'
      : '/api/tmdb/movie/${q.id}/images';
  final capToken = await _fetchCapToken();
  if (capToken == null) return const [];
  final rng = Random.secure();
  final keyBytes = List.generate(32, (_) => rng.nextInt(256));
  final key = keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final headers = {
    'User-Agent': _hexaUA,
    'Referer': 'https://hexa.su/',
    'Origin': 'https://hexa.su',
    'Accept': 'text/plain',
    'X-Fingerprint-Lite': 'e9136c41504646444',
    'X-Cap-Token': capToken,
    'X-Api-Key': key,
  };
  try {
    final res = await fetchRaw('$_hexaBase$path', headers: headers, timeout: const Duration(seconds: 12));
    if (res.statusCode >= 300) {
      _cachedCapToken = null;
      return const [];
    }
    final encryptedText = res.body.trim();
    if (encryptedText.isEmpty) return const [];
    final decRes = await fetchJson('$_hexaDecApi/dec-hexa',
        method: 'POST',
        headers: {'Content-Type': 'application/json', 'User-Agent': _hexaUA},
        body: json.encode({'text': encryptedText, 'key': key}),
        timeout: const Duration(seconds: 10));
    if (dig(decRes, ['status']) != 200 || !truthy(dig(decRes, ['result']))) return const [];
    final streams = _extractHexaStreams(decRes['result']);
    final seen = <String>{};
    return [for (final s in streams) if (seen.add(s.url)) s];
  } catch (_) {
    return const [];
  }
}

/// cinesrc.js — two-stage proof-of-work challenge with enc-dec.app.
const _cinesrcApi = 'https://enc-dec.app/api';
const _cinesrcUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.37 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.37';

int _csU32(int x) => x & 0xFFFFFFFF;
int _csRotl(int x, int n) {
  final s = n & 31;
  return _csU32((x << s) | ((x & 0xFFFFFFFF) >>> (32 - s)));
}
int _csImul(int a, int b) {
  final ah = (a >>> 16) & 0xffff;
  final al = a & 0xffff;
  final bh = (b >>> 16) & 0xffff;
  final bl = b & 0xffff;
  return _csU32(((ah * bl + al * bh) << 16) + al * bl);
}

const _csK = [
  0x46C6C721, 0x4230C311, 0x18223A1D, 0x56389BA7,
  0xD4A87103, 0x07CB9E2F, 0x73085F9D, 0xD2396A1F,
  0x23AE5ADD, 0x4646C48F, 0x0F4E0903, 0x808F5F31,
  0x953D4E07, 0x7E238FFF, 0x634595DF, 0xCB5E4301,
];

const _csSchedules = [
  [0, 7, 6, 3, 2, 1, 5, 4, 0, 2, 4, 6, 5, 1, 7, 3],
  [5, 2, 1, 3, 0, 4, 6, 7, 4, 1, 0, 7, 3, 6, 5, 2],
  [4, 0, 2, 1, 5, 7, 6, 3, 2, 6, 0, 7, 4, 3, 5, 1],
  [5, 4, 7, 0, 2, 3, 1, 6, 5, 1, 4, 0, 7, 2, 3, 6],
  [4, 7, 0, 2, 1, 6, 5, 3, 6, 1, 3, 2, 0, 7, 4, 5],
  [0, 7, 2, 6, 3, 4, 5, 1, 6, 5, 0, 2, 7, 1, 4, 3],
  [0, 4, 5, 3, 1, 7, 2, 6, 3, 7, 5, 6, 1, 0, 2, 4],
  [7, 6, 0, 4, 2, 5, 1, 3, 7, 5, 3, 4, 2, 6, 0, 1],
];

const _csPerms = [
  [3, 5, 1, 0, 2, 4],
  [2, 0, 4, 5, 3, 1],
  [1, 4, 5, 3, 0, 2],
  [2, 0, 1, 5, 4, 3],
  [4, 2, 1, 0, 3, 5],
  [5, 0, 2, 1, 3, 4],
  [4, 5, 1, 0, 3, 2],
  [4, 0, 3, 5, 1, 2],
];

Uint8List _csB64dec(String s) {
  var fixed = s.replaceAll('-', '+').replaceAll('_', '/');
  while (fixed.length % 4 != 0) { fixed += '='; }
  return base64.decode(fixed);
}

/// Runs in its own isolate: this is seconds of hashing.
String _solveStage1(Map<String, dynamic> challenge1, String seed) {
  final c = _csB64dec(challenge1['w'] as String);
  final view = ByteData.sublistView(c);
  final mode = c[21];
  final diffVal = c[22];
  final varIdx = c[23];
  final rnd = c[24];
  final mB = c[25];
  final sI = c[26];
  final pI = c[27];

  final w0 = view.getUint32(0, Endian.little);
  final w1 = view.getUint32(4, Endian.little);
  final w2 = view.getUint32(8, Endian.little);
  final w3 = view.getUint32(12, Endian.little);
  final w = [w0, w1, w2, w3];

  final size = 1 << mB;
  final s = Uint32List(size);
  var x = _csU32(w[varIdx & 3] ^ _csK[sI] ^ _csImul(_csK[8 + sI], varIdx + 1));
  var y = _csU32(w[(varIdx + 1) & 3] ^ _csK[15 - sI]);

  for (var i = 0; i < size; i++) {
    x = _csU32(w[(i + sI) & 3] + x + _csImul(_csK[(i + varIdx) & 15], i + 1));
    x = _csU32(x ^ (x << 13));
    x = _csU32(x ^ (x >>> 17));
    x = _csU32(x ^ (x << 5));
    y = _csRotl(_csU32(_csImul(_csK[(i + 9) & 15], i + 3) ^ y ^ x), i + varIdx + sI);
    s[i] = _csU32(_csImul(_csK[(i + 5) & 15], i ^ varIdx) ^ _csRotl(w[(i + varIdx) & 3], i + sI) ^ x ^ y);
  }

  final seedBytes = Uint8List(seed.length ~/ 2);
  for (var i = 0; i < seedBytes.length; i++) {
    seedBytes[i] = int.parse(seed.substring(i * 2, i * 2 + 2), radix: 16);
  }

  final msg = Uint8List(88);
  msg.setRange(24, 24 + 16, c.sublist(0, 16));
  final cfg = mB ^ 0x6B29;
  msg[48] = 4;
  msg[49] = mode;
  msg[50] = varIdx;
  msg[51] = sI;
  msg[52] = pI;
  msg[53] = rnd;
  msg[54] = cfg & 0xff;
  msg[55] = cfg >> 8;
  msg.setRange(56, 56 + seedBytes.length, seedBytes);

  final mask = size - 1;
  final sch = _csSchedules[sI];
  final perm = _csPerms[pI];

  for (var n = 0; ; n++) {
    final lo = n & 0xFFFFFFFF;
    final hi = n >> 32;

    var ma = _csU32(w[0] ^ _csK[varIdx] ^ lo);
    var mb = _csU32(_csRotl(lo, varIdx + 7) ^ w[2]);
    var mc = _csU32(w[1] ^ _csK[8 + sI] ^ hi);
    var md = _csU32(_csRotl(lo ^ hi, sI + 11) ^ w[3]);
    var me = _csU32(_csK[sI + varIdx] ^ lo ^ hi);
    var mf = _csU32(_csK[15 - varIdx] ^ w[sI & 3]);

    for (var r = 0; r < rnd; r++) {
      final i1 = _csU32(_csRotl(mb, r + 1) ^ _csImul(_csK[r & 15], mf) ^ me ^ ma) & mask;
      final v1 = s[i1];
      final i2 = _csU32(_csRotl(me, varIdx + r + 3) ^ _csImul(_csK[(r + 7) & 15], md) ^ mc ^ v1) & mask;
      final op = sch[r];

      if (op == 0) {
        ma = _csRotl(_csU32(ma + md + v1), 5);
        mc = _csU32(_csImul(mc ^ mf ^ ma, 1187432225) + mb);
      } else if (op == 1) {
        mb = _csRotl(mc ^ me ^ mb ^ v1, 11);
        md = _csU32(_csImul(mb ^ ma, 1110491921) + md);
      } else if (op == 2) {
        mc = _csRotl(_csU32(mc + mb + v1), 17);
        ma = _csU32(_csImul(md ^ mf ^ mc, 404896285) ^ ma);
      } else if (op == 3) {
        md = _csRotl(ma ^ md ^ v1, 23);
        mb = _csU32(_csImul(mc ^ me ^ md, 1446550439) + mb);
      } else if (op == 4) {
        ma = _csU32(_csImul(ma ^ me ^ v1, 0xD4A87103) + _csRotl(mb, 7));
        md = _csU32(_csRotl(_csU32(mc + mf + ma), 13) ^ md);
      } else if (op == 5) {
        mc = _csU32(_csImul(_csU32(mc + mf + v1), 130784815) ^ _csRotl(md, 9));
        mb = _csU32(_csRotl(ma ^ me ^ mc, 19) + mb);
      } else if (op == 6) {
        mb = _csU32(_csImul(mb ^ mf ^ v1, 1929928605) + _csRotl(ma, 3));
        mc = _csU32(_csRotl(_csU32(md + me + mb), 15) ^ mc);
      } else {
        md = _csU32(_csImul(_csU32(md + me + v1), 0xD2396A1F) ^ _csRotl(mc, 21));
        ma = _csU32(_csRotl(mb ^ mf ^ md, 27) + ma);
      }

      final v2 = s[i2];
      if (((mf ^ r ^ v1) & 1) == 0) {
        mf = _csRotl(_csU32(v2 + mf + ma), r + 5);
        me = _csU32(_csImul(_csK[8 + op], v2 ^ me ^ mf) + md);
      } else {
        me = _csRotl(v2 ^ me ^ mb, r + 9);
        mf = _csU32(_csImul(_csK[(op + 11) & 15], _csU32(v2 + mf + me)) ^ mc);
      }
    }

    final mArr = [ma, mc, mb, md, mf, me];
    final v = [for (final idx in perm) mArr[idx]];

    final msgView = ByteData.sublistView(msg);
    msgView.setUint32(0, v[0], Endian.little);
    msgView.setUint32(4, v[1], Endian.little);
    msgView.setUint32(8, v[2], Endian.little);
    msgView.setUint32(12, v[3], Endian.little);
    msgView.setUint32(16, v[4], Endian.little);
    msgView.setUint32(20, v[5], Endian.little);
    msgView.setUint32(40, lo, Endian.little);
    msgView.setUint32(44, hi, Endian.little);

    final hashBytes = crypto.sha256.convert(msg).bytes;
    final b = diffVal ~/ 8;
    final rBits = diffVal % 8;
    var ok = true;
    for (var i = 0; i < b; i++) {
      if (hashBytes[i] != 0) { ok = false; break; }
    }
    if (ok && (rBits == 0 || (hashBytes[b] >> (8 - rBits)) == 0)) {
      return 'm4.${n.toRadixString(16)}';
    }
  }
}

/// Off the UI isolate; each closure holds only its own arguments.
Future<String> _offStage1(Map<String, dynamic> c, String seed) => Isolate.run(() => _solveStage1(c, seed));
Future<String> _offStage2(Map<String, dynamic> d) => Isolate.run(() => _solveStage2(d));

/// Runs in its own isolate, like stage 1.
String _solveStage2(Map<String, dynamic> data) {
  final pack = (data['pack'] as List).cast<String>();
  final target = pack[0].split('').reversed.join();
  final salt = pack[3].split('').reversed.join();
  final r = pack[4].split('').reversed.join();

  String b64decStr(String s) {
    var fixed = s.replaceAll('-', '+').replaceAll('_', '/');
    while (fixed.length % 4 != 0) { fixed += '='; }
    return utf8.decode(base64.decode(fixed));
  }

  final body = b64decStr(r.split('.')[1]);
  final payload = b64decStr(body.split('.')[1]);
  final difficulty = ((json.decode(payload) as Map<String, dynamic>)['d'] as num).toInt();
  final width = (difficulty + 3) ~/ 4;
  final limit = 1 << difficulty;

  for (var counter = 0; counter < limit; counter++) {
    final key = counter.toRadixString(16).padLeft(width, '0');
    final digest = crypto.sha256.convert(utf8.encode('$salt$key')).toString();
    if (digest == target) return key;
  }
  throw Exception('no solution found');
}

Future<List<FoundStream>> cinesrc(FilmQuery q) async {
  const api = _cinesrcApi;
  final isTv = q.hasEpisode;
  final type = isTv ? 'tv' : 'movie';
  final url = isTv
      ? 'https://cinesrc.st/embed/tv/${q.id}?s=${q.season}&e=${q.episode}'
      : 'https://cinesrc.st/embed/movie/${q.id}';

  final headers = {
    'Origin': 'https://cinesrc.st',
    'Referer': 'https://cinesrc.st/',
    'Content-Type': 'text/plain;charset=UTF-8',
    'User-Agent': _cinesrcUA,
  };

  final fields = [type, q.id, if (isTv) '${q.season}' else null, if (isTv) '${q.episode}' else null];
  final encoded = base64Url.encode(utf8.encode(json.encode(fields))).replaceAll('=', '');

  try {
    final bootstrap = await fetchJson('https://cinesrc.st/api/c/bootstrap',
        method: 'POST', headers: {...headers, 'x-cs-q': encoded}, body: '{}');

    final cookies = {
      'x-cs-b': '20261014-a',
      'x-cs-q': encoded,
      'x-cs-r': '${bootstrap['r']}',
      'x-cs-p': '${bootstrap['p']}',
    };

    final challenge1 = await fetchJson('https://cinesrc.st/api/c/issue',
        headers: {...headers, ...cookies}) as Map<String, dynamic>;

    final seedRes = await fetchJson('$api/enc-cinesrc',
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'data': {'url': url, 'user_agent': headers['User-Agent'], 'challenge_data': challenge1},
          'type': 'seed',
        }));
    final seedData = seedRes['result'] as Map<String, dynamic>;
    final solution1 = await _offStage1(challenge1, seedData['seed'] as String);

    final challenge2 = await fetchJson('https://cinesrc.st/api/c/stage2/issue',
        headers: {...headers, ...cookies}) as Map<String, dynamic>;
    final solution2 = await _offStage2(challenge2);

    final encryptRes = await fetchJson('$api/enc-cinesrc',
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'data': {
            'url': url,
            'user_agent': headers['User-Agent'],
            'challenge_data': {
              'stage1': {'challenge': challenge1, 'solution': solution1},
              'stage2': {'challenge': challenge2, 'solution': solution2},
            },
            'state': seedData['state'],
          },
          'type': 'encrypt',
        }));

    final encData = encryptRes['result'] as Map<String, dynamic>;
    final token = '${encData['token']}::c3::${cookies['x-cs-r']}';
    final nextActions = encData['headers'] as Map<String, dynamic>;

    final providersText = await fetchText(url,
        method: 'POST',
        headers: {...headers, ...cookies, 'Next-Action': '${nextActions['getProviderList']}'},
        body: json.encode([]));

    List<dynamic>? providers;
    for (final rawLine in providersText.split('\n')) {
      final ci = rawLine.indexOf(':');
      if (ci != -1) {
        final candidate = rawLine.substring(ci + 1).trim();
        if (candidate.startsWith('[') && candidate.endsWith(']')) {
          try { providers = json.decode(candidate) as List; break; } catch (_) {}
        }
      }
    }
    if (providers == null || providers.isEmpty) return const [];

    for (final providerObj in providers) {
      final provider = providerObj['id'];
      final streamPayload = [
        q.id,
        isTv ? 'show' : type,
        isTv ? '${q.season}' : r'$undefined',
        isTv ? '${q.episode}' : r'$undefined',
        token,
        provider,
      ];

      String streamRes;
      try {
        streamRes = await fetchText(url,
            method: 'POST',
            headers: {...headers, ...cookies, 'Next-Action': '${nextActions['getStream']}'},
            body: json.encode(streamPayload));
      } catch (_) { continue; }

      if (streamRes.contains('"status":500') || streamRes.contains('invalid_challenge') || streamRes.length < 10) continue;

      dynamic decryptRes;
      try {
        decryptRes = await fetchJson('$api/dec-cinesrc',
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'text': streamRes, 'state': encData['state']}));
      } catch (_) { continue; }

      if (dig(decryptRes, ['status']) != 200 || !truthy(dig(decryptRes, ['result']))) continue;

      var resultData = decryptRes['result'];
      if (resultData is String) {
        try { resultData = json.decode(resultData); } catch (_) {}
      }

      String? streamUrl;
      if (resultData is Map) {
        if (resultData['url'] is List) {
          streamUrl = dig(resultData, ['url', 0, 'url']) as String?;
        } else if (resultData['url'] is String) {
          streamUrl = resultData['url'] as String;
        } else if (resultData['file'] is String) {
          streamUrl = resultData['file'] as String;
        } else if (resultData['sources'] is List) {
          streamUrl = dig(resultData, ['sources', 0, 'url']) as String?;
        }
      }

      if (streamUrl != null) {
        if (streamUrl.startsWith('/')) streamUrl = 'https://cinesrc.st$streamUrl';
        final rHeaders = (resultData is Map && resultData['headers'] is Map)
            ? (resultData['headers'] as Map).map((k, v) => MapEntry('$k', '$v'))
            : const {'Referer': 'https://cinesrc.st/', 'Origin': 'https://cinesrc.st'};
        return [FoundStream(
          url: streamUrl,
          server: 'CineSrc - ${providerObj['name'] ?? provider}',
          quality: 'Auto',
          type: streamUrl.contains('.m3u8') ? 'hls' : 'mp4',
          headers: rHeaders,
        )];
      }
    }
    return const [];
  } catch (_) {
    return const [];
  }
}

/// mapple.js — proof-of-work with a hand-rolled SHA-256 and cookie-jar session.
const _mappleBase = 'https://mapple.fun';
const _mappleMobileUA = 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
const _mappleDsktpUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

const _mappleServers = [
  {'name': 'Zeus', 'source': 'mapple'},
  {'name': 'Poseidon', 'source': 's25'},
  {'name': 'Aphrodite', 'source': 's6'},
  {'name': 'Hephaestus', 'source': 's15'},
  {'name': 'Prometheus', 'source': 's10'},
  {'name': 'Atlas', 'source': 's1'},
];

const _mapplePlayback = {
  'User-Agent': _mappleDsktpUA,
  'Origin': _mappleBase,
  'Referer': '$_mappleBase/',
};

/// The JS hand-rolls SHA-256 for speed; it hashes `<challenge><nonce>` for nonces 0 to 19,999,999
/// and wants [difficulty] leading zero bits. Runs in its own isolate: up to seconds of hashing.
String? _mpSolvePoW(String challenge, int difficulty) {
  for (var nonce = 0; nonce < 20000000; nonce++) {
    final h = crypto.sha256.convert(utf8.encode('$challenge$nonce')).bytes;
    var bits = difficulty, i = 0;
    while (bits >= 8 && h[i] == 0) {
      bits -= 8;
      i++;
    }
    if (bits <= 0 || (bits < 8 && h[i] >> (8 - bits) == 0)) return '$nonce';
  }
  return null;
}

Future<String?> _mpOffPoW(String challenge, int difficulty) => Isolate.run(() => _mpSolvePoW(challenge, difficulty));

class _MpCookieJar {
  final _cookies = <String, String>{};
  void update(http.Response r) {
    final raw = r.headers['set-cookie'];
    if (raw == null) return;
    for (final cookie in raw.split(RegExp(r',(?=[^ ])'))) {
      final pair = cookie.split(';')[0].split('=');
      if (pair.length >= 2) _cookies[pair[0].trim()] = pair.sublist(1).join('=').trim();
    }
  }
  String serialize() => _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

Future<http.Response> _mpFetch(String url, {String method = 'GET', Map<String, String> headers = const {}, String? body}) async {
  final rq = http.Request(method, Uri.parse(url))
    ..followRedirects = true
    ..headers.addAll(headers);
  if (body != null) rq.body = body;
  final res = await netClient.send(rq).timeout(const Duration(seconds: 25));
  return http.Response.fromStream(res).timeout(const Duration(seconds: 25));
}

Future<Map<String, dynamic>?> _mpCreateSession(int tmdbId, String mediaType, String tvSlug, String referer) async {
  try {
    final jar = _MpCookieJar();
    final homeRes = await _mpFetch('$_mappleBase/', headers: {'User-Agent': _mappleMobileUA, 'Accept': 'text/html'});
    jar.update(homeRes);

    final tokenRes = await _mpFetch('$_mappleBase/api/ui/session',
        method: 'POST',
        headers: {
          'User-Agent': _mappleMobileUA, 'Accept': '*/*',
          'Origin': _mappleBase, 'Referer': referer,
          'Content-Type': 'application/json',
          'Cookie': jar.serialize(),
        },
        body: '');
    jar.update(tokenRes);

    final tokenData = (() { try { return json.decode(tokenRes.body) as Map<String, dynamic>; } catch (_) { return null; } })();
    final requestToken = tokenData?['token'] as String?;
    if (requestToken == null) return null;

    final payload = {'mediaId': tmdbId, 'mediaType': mediaType, 'tv_slug': tvSlug, 'requestToken': requestToken};

    Future<Map<String, dynamic>?> initPlayback(Map<String, dynamic> body) async {
      final res = await _mpFetch('$_mappleBase/api/playback-init',
          method: 'POST',
          headers: {
            'User-Agent': _mappleMobileUA, 'Accept': '*/*',
            'Origin': _mappleBase, 'Referer': referer,
            'Content-Type': 'application/json',
            'Cookie': jar.serialize(),
          },
          body: json.encode(body));
      jar.update(res);
      try { return json.decode(res.body) as Map<String, dynamic>; } catch (_) { return null; }
    }

    var result = await initPlayback(payload);
    if (result?['success'] == true && result?['token'] != null) {
      return {'requestToken': requestToken, 'playbackToken': result!['token'], 'jar': jar, 'referer': referer};
    }

    if (result?['requiresPow'] == true && result?['pow'] != null) {
      final powData = result!['pow'] as Map<String, dynamic>;
      final challenge = '${powData['challenge']}';
      final difficulty = (powData['difficulty'] as num?)?.toInt() ?? 18;
      final nonce = await _mpOffPoW(challenge, difficulty);
      if (nonce == null) return null;

      result = await initPlayback({
        ...payload,
        'pow': {'challengeId': powData['challengeId'], 'nonce': nonce},
      });

      if (result?['token'] != null) {
        return {'requestToken': requestToken, 'playbackToken': result!['token'], 'jar': jar, 'referer': referer};
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

String _mpResolvePlaylistUrl(String entry, String playlistUrl) {
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(entry)) return entry;
  final cleanUrl = playlistUrl.split('#')[0].split('?')[0];
  if (entry.startsWith('/')) {
    final origin = RegExp(r'^(https?://[^/]+)', caseSensitive: false).firstMatch(cleanUrl);
    return '${origin?[1] ?? ''}$entry';
  }
  return '${cleanUrl.substring(0, cleanUrl.lastIndexOf('/') + 1)}$entry';
}

Future<List<Map<String, String>>?> _mpParseMasterPlaylist(String playlistUrl, Map<String, String> headers) async {
  try {
    final res = await fetchRaw(playlistUrl, headers: headers, timeout: const Duration(seconds: 5));
    if (res.statusCode >= 300) return null;
    final text = res.body;
    if (!text.contains('#EXT-X-STREAM-INF')) return null;
    final lines = text.split('\n');
    final variants = <Map<String, String>>[];
    var currentQuality = '1080p';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final resMatch = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false).firstMatch(line);
        if (resMatch != null) currentQuality = '${resMatch[1]}p';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        variants.add({'url': _mpResolvePlaylistUrl(line, playlistUrl), 'quality': currentQuality});
        currentQuality = '1080p';
      }
    }
    return variants.isNotEmpty ? variants : null;
  } catch (_) {
    return null;
  }
}

Future<List<FoundStream>> _mpFetchServer(
    Map<String, String> server, int tmdbId, String mediaType, String tvSlug, Map<String, dynamic> session) async {
  final sourceKey = server['source']!;
  final jar = session['jar'] as _MpCookieJar;
  final referer = session['referer'] as String;
  final requestToken = session['requestToken'] as String;
  final playbackToken = session['playbackToken'] as String;
  try {
    final encryptRes = await _mpFetch('$_mappleBase/api/encrypt',
        method: 'POST',
        headers: {
          'User-Agent': _mappleMobileUA, 'Accept': '*/*',
          'Origin': _mappleBase, 'Referer': referer,
          'Content-Type': 'application/json',
          'Cookie': jar.serialize(),
        },
        body: json.encode({
          'data': {'mediaId': tmdbId, 'mediaType': mediaType, 'tv_slug': tvSlug, 'source': sourceKey},
          'endpoint': 'stream-encrypted',
          'requestToken': requestToken,
        }));
    jar.update(encryptRes);
    final encrypted = (() { try { return json.decode(encryptRes.body) as Map<String, dynamic>; } catch (_) { return null; } })();
    if (encrypted?['url'] == null) return const [];

    final streamEndpoint = '$_mappleBase${encrypted!['url']}&requestToken=${Uri.encodeComponent(requestToken)}&token=${Uri.encodeComponent(playbackToken)}';
    final streamRes = await _mpFetch(streamEndpoint,
        headers: {
          'User-Agent': _mappleMobileUA, 'Accept': '*/*',
          'Origin': _mappleBase, 'Referer': referer,
          'Cookie': jar.serialize(),
        });
    jar.update(streamRes);
    final streamData = (() { try { return json.decode(streamRes.body) as Map<String, dynamic>; } catch (_) { return null; } })();
    final streamUrl = dig(streamData, ['data', 'stream_url']) as String?;
    if (streamUrl == null || streamUrl.contains('playback-unavailable')) return const [];

    final variants = await _mpParseMasterPlaylist(streamUrl, _mapplePlayback);
    if (variants != null && variants.isNotEmpty) {
      return [for (final v in variants) FoundStream(
        url: v['url']!,
        quality: v['quality']!,
        server: 'Mapple - ${server['name']}',
        type: 'hls',
        headers: _mapplePlayback,
      )];
    }
    return [FoundStream(url: streamUrl, quality: 'Auto', server: 'Mapple - ${server['name']}', type: streamUrl.contains('.m3u8') ? 'hls' : 'mp4', headers: _mapplePlayback)];
  } catch (_) {
    return const [];
  }
}

Future<List<FoundStream>> mapple(FilmQuery q) async {
  final isTv = q.hasEpisode;
  final type = isTv ? 'tv' : 'movie';
  final tvSlug = isTv ? '${q.season}-${q.episode}' : '';
  final referer = isTv
      ? '$_mappleBase/tv/${q.id}/${q.season}/${q.episode}'
      : '$_mappleBase/movie/${q.id}';

  final session = await _mpCreateSession(q.tmdbId, type, tvSlug, referer);
  if (session == null) return const [];

  final results = await Future.wait([
    for (final server in _mappleServers)
      _mpFetchServer(server, q.tmdbId, type, tvSlug, session).catchError((_) => const <FoundStream>[]),
  ]);

  final seen = <String>{};
  return [for (final list in results) for (final s in list) if (seen.add(s.url)) s];
}
