import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import '../net.dart';

/// Shared pieces of the film/TV scrapers ported from the Vyla SDK (`src/utils/helpers.js`).
/// Each scraper keeps its JS logic; these are the helpers they lean on.

const uaList = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
  'Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0',
];
final _rng = Random();
String getUA() => uaList[_rng.nextInt(uaList.length)];
const sdkUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Lorewatch's own TMDB key (as in tmdb.dart and subtitles.dart), not the SDK's.
const tmdbKey = String.fromEnvironment('TMDB_API_KEY', defaultValue: 'b3556f3b206e16f82df4d1f6fd4545e6');

/// What to look up: a film, or one episode of a show, by TMDB id.
class FilmQuery {
  const FilmQuery({required this.tmdbId, required this.isTv, this.season, this.episode});
  final int tmdbId;
  final bool isTv;
  final int? season;
  final int? episode;
  String get id => '$tmdbId';

  /// The SDK's `s && e` test: an episode was asked for.
  bool get hasEpisode => isTv && season != null && episode != null;
}

/// One stream a scraper found (the SDK's `allUrls` entries).
class FoundStream {
  // ignore: prefer_initializing_formals
  const FoundStream({required this.url, this.server = 'Server', this.quality = 'Auto', String? type, this.headers = const {}, this.label, this.audio}) : _type = type;
  final String url;

  /// The language this link's sound is in, in the source's own words ('Hindi', 'English sub'),
  /// when the source says. Null when it doesn't: usually the original, or one stream with
  /// several languages inside it (those show up as audio tracks once it plays).
  final String? audio;
  final String server;
  final String? label;
  final String quality;
  final String? _type;
  final Map<String, String> headers;

  /// 'hls', 'dash' or 'mp4', as formatStreamResult guesses it when the scraper doesn't say.
  /// Scrapers also hand back the API's own words for it ('m3u8', 'mkv'…): those fold into these three.
  String get type {
    final t = (_type ?? '').toLowerCase();
    if (t == 'hls' || t == 'm3u8') return 'hls';
    if (t == 'dash' || t == 'mpd') return 'dash';
    if (t.isNotEmpty) return 'mp4';
    return url.contains('.m3u8') ? 'hls' : (url.contains('.mpd') ? 'dash' : 'mp4');
  }

  @override
  String toString() => '[$type] $server ($quality) $url ${headers.isEmpty ? '' : headers}';
}

/// A source's word for a link's language, tidied. Null when it says nothing useful.
String? audioOf(dynamic v) {
  if (v is! String) return null;
  final s = v.trim();
  return switch (s.toLowerCase()) {
    '' || 'null' || 'unknown' || 'default' || 'auto' || 'shared' || 'multi' => null,
    _ => s,
  };
}

/// Whether an HLS master playlist keeps its sound in playlists of their own (one per language).
/// A quality's playlist from such a master is a silent picture.
bool hlsAudioIsSeparate(String master) => RegExp(r'#EXT-X-MEDIA:[^\n]*TYPE=AUDIO[^\n]*URI=').hasMatch(master);

/// The variants of an HLS master playlist [text] fetched from [master] (anizone.js / vidly.js
/// resolveHlsVariants). Null when it isn't a master.
///
/// Not in the JS: when the sound is in playlists of its own, the master is handed back whole,
/// as one stream, under its best quality. The JS returns each quality's playlist, which plays
/// with no sound at all; whole, the player still picks the quality from it and every language
/// in it shows up as an audio track.
List<({String url, String quality})>? hlsVariantsOf(String text, String master, {bool bandwidth = false, bool Function(String)? skip}) {
  if (!text.contains('#EXTM3U') || !text.contains('#EXT-X-STREAM-INF')) return null;
  final cut = master.split('?').first.lastIndexOf('/');
  final baseUrl = master.substring(0, cut + 1);
  final lines = text.split('\n').map((l) => l.trim()).toList();
  final out = <({String url, String quality})>[];
  var best = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    var quality = 'Auto';
    final m = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false).firstMatch(line);
    if (m != null) {
      quality = '${m[1]}p';
      final h = int.parse(m[1]!);
      if (h > best) best = h;
    } else if (bandwidth) {
      final b = RegExp(r'BANDWIDTH=(\d+)', caseSensitive: false).firstMatch(line);
      if (b != null) {
        final bw = int.parse(b[1]!);
        quality = bw > 3000000 ? '1080p' : (bw > 1800000 ? '960p' : (bw > 1200000 ? '720p' : (bw > 800000 ? '640p' : '480p')));
      }
    }
    final next = i + 1 < lines.length ? lines[i + 1] : '';
    if (next.isNotEmpty && !next.startsWith('#')) {
      if (skip != null && skip(next)) continue;
      out.add((url: next.startsWith('http') ? next : '$baseUrl$next', quality: quality));
    }
  }
  if (out.isEmpty) return null;
  if (hlsAudioIsSeparate(text)) return [(url: master, quality: best > 0 ? '${best}p' : 'Auto')];
  return out;
}

class HttpError implements Exception {
  HttpError(this.status, this.url);
  final int status;
  final String url;
  @override
  String toString() => 'HTTP $status';
}

const _defaultTimeout = Duration(seconds: 15);

/// fetch(): any status, any method.
Future<http.Response> fetchRaw(
  String url, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
  Duration timeout = _defaultTimeout,
  bool followRedirects = true,
}) async {
  final rq = http.Request(method, Uri.parse(url))
    ..followRedirects = followRedirects
    ..headers.addAll(headers);
  if (body is String) {
    rq.body = body;
  } else if (body is List<int>) {
    rq.bodyBytes = body;
  }
  final res = await netClient.send(rq).timeout(timeout);
  return http.Response.fromStream(res).timeout(timeout);
}

/// helpers.js fetchText: throws on a non-2xx status.
Future<String> fetchText(String url, {String method = 'GET', Map<String, String> headers = const {}, Object? body, Duration timeout = _defaultTimeout}) async {
  final r = await fetchRaw(url, method: method, headers: headers, body: body, timeout: timeout);
  if (r.statusCode < 200 || r.statusCode >= 300) throw HttpError(r.statusCode, url);
  return utf8.decode(r.bodyBytes, allowMalformed: true);
}

/// helpers.js fetchJson: throws on a non-2xx status.
Future<dynamic> fetchJson(String url, {String method = 'GET', Map<String, String> headers = const {}, Object? body, Duration timeout = _defaultTimeout}) async =>
    json.decode(await fetchText(url, method: method, headers: headers, body: body, timeout: timeout));

/// A field of decoded JSON, or null when the shape isn't what was expected (JS's `a?.b?.c`).
dynamic dig(dynamic v, List<Object> path) {
  for (final k in path) {
    if (k is String && v is Map) {
      v = v[k];
    } else if (k is int && v is List && k >= 0 && k < v.length) {
      v = v[k];
    } else {
      return null;
    }
  }
  return v;
}

/// JS truthiness for decoded JSON values.
bool truthy(dynamic v) => !(v == null || v == false || v == 0 || v == '' || (v is double && v.isNaN));

/// `a || b || c` over JSON values.
dynamic firstTruthy(Iterable<dynamic> vs) {
  for (final v in vs) {
    if (truthy(v)) return v;
  }
  return null;
}

String? str(dynamic v) => v == null ? null : (v is String ? v : '$v');

class TmdbMeta {
  const TmdbMeta({
    this.title = '',
    this.originalTitle = '',
    this.titles = const [],
    this.year,
    this.releaseDate = '',
    this.imdbId,
    this.isAnime = false,
    this.runtime = 0,
    this.seasons = const [],
  });
  final String title, originalTitle, releaseDate;
  final List<String> titles;
  final int? year;
  final String? imdbId;
  final bool isAnime;
  final int runtime;
  final List<dynamic> seasons;
}

final _metaCache = <String, Future<TmdbMeta>>{};

/// helpers.js getTmdbMetadata.
Future<TmdbMeta> getTmdbMetadata(String id, bool isTv) => _metaCache.putIfAbsent('$id-$isTv', () async {
      final type = isTv ? 'tv' : 'movie';
      try {
        final r = await fetchRaw('https://api.themoviedb.org/3/$type/$id?api_key=$tmdbKey&append_to_response=external_ids,alternative_titles',
            timeout: const Duration(seconds: 6));
        if (r.statusCode != 200) return const TmdbMeta();
        final data = json.decode(r.body) as Map<String, dynamic>;
        final title = (firstTruthy([data['name'], data['title']]) ?? '') as String;
        final originalTitle = (firstTruthy([data['original_name'], data['original_title']]) ?? '') as String;
        final releaseDate = (firstTruthy([data['first_air_date'], data['release_date']]) ?? '') as String;
        final year = releaseDate.length >= 4 ? int.tryParse(releaseDate.substring(0, 4)) : null;
        final imdbId = (firstTruthy([data['imdb_id'], dig(data, ['external_ids', 'imdb_id'])])) as String?;
        final runtime = isTv ? ((dig(data, ['episode_run_time', 0]) as num?)?.toInt() ?? 24) : ((data['runtime'] as num?)?.toInt() ?? 90);
        final titles = <String>[];
        if (title.isNotEmpty) titles.add(title);
        if (originalTitle.isNotEmpty && !titles.contains(originalTitle)) titles.add(originalTitle);
        final alts = (firstTruthy([dig(data, ['alternative_titles', 'titles']), dig(data, ['alternative_titles', 'results'])]) as List?) ?? const [];
        for (final alt in alts) {
          final t = firstTruthy([dig(alt, ['title']), dig(alt, ['name'])]);
          if (t is String && !titles.contains(t)) titles.add(t);
        }
        final genres = (data['genres'] as List?) ?? const [];
        final isAnime = genres.any((g) => dig(g, ['id']) == 16) &&
            (((data['origin_country'] as List?) ?? const []).contains('JP') || data['original_language'] == 'ja');
        return TmdbMeta(
          title: title,
          originalTitle: originalTitle,
          titles: titles,
          year: year,
          releaseDate: releaseDate,
          imdbId: imdbId,
          isAnime: isAnime,
          runtime: runtime,
          seasons: (data['seasons'] as List?) ?? const [],
        );
      } catch (_) {
        return const TmdbMeta();
      }
    });

/// helpers.js resolveImdbId.
Future<String> resolveImdbId(String id, bool isTv) async {
  if (id.startsWith('tt')) return id;
  final meta = await getTmdbMetadata(id, isTv);
  return meta.imdbId ?? 'tt$id';
}

/// helpers.js slugify.
String slugify(String? text) {
  if (text == null || text.isEmpty) return '';
  return _stripAccents(text.toLowerCase()).replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
}

/// helpers.js cleanTitle.
String cleanTitle(String? text) {
  if (text == null || text.isEmpty) return '';
  return text.toLowerCase().replaceAll(RegExp(r'\(\d{4}\)'), '').replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
}

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ù': 'u',
  'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y',
};
String _stripAccents(String s) => s.split('').map((c) => _accents[c] ?? c).join();

/// The SDK's `isTv = Boolean(s && e)` paths: `tv/{id}/{s}/{e}` or `movie/{id}`.
String sePath(FilmQuery q, String tvPrefix, String moviePrefix) =>
    q.hasEpisode ? '$tvPrefix/${q.id}/${q.season}/${q.episode}' : '$moviePrefix/${q.id}';

/// helpers.js scrapeVidcoreFamily (VidCore, VidFast, VidUp): stages through enc-dec.app.
Future<List<FoundStream>> scrapeVidcoreFamily(FilmQuery q, {required String baseUrl, required String apiName, required String serverLabel}) async {
  final targetUrl = q.hasEpisode ? '$baseUrl/tv/${q.id}/${q.season}/${q.episode}/' : '$baseUrl/movie/${q.id}';
  final ua = getUA();
  final baseHeaders = {'User-Agent': ua, 'Referer': '$baseUrl/', 'X-Requested-With': 'XMLHttpRequest'};
  try {
    final pageRes = await fetchRaw(targetUrl, headers: {'User-Agent': ua}, timeout: const Duration(seconds: 10));
    if (pageRes.statusCode >= 300) return const [];
    final match = RegExp(r'\\"(?:en|token)\\":\\"(.*?)\\"').firstMatch(pageRes.body);
    if (match == null || (match[1] ?? '').isEmpty) return const [];
    final enToken = match[1]!;

    final s1 = await fetchJson('https://enc-dec.app/api/enc-$apiName?text=${Uri.encodeComponent(enToken)}&stage=1', timeout: const Duration(seconds: 8));
    if (dig(s1, ['status']) != 200 || !truthy(dig(s1, ['result', 'stage1']))) return const [];
    final token1 = '${dig(s1, ['result', 'token'])}';
    final stage1Url = '${dig(s1, ['result', 'stage1'])}';

    final post1 = await fetchRaw(stage1Url, method: 'POST', headers: {...baseHeaders, 'X-CSRF-Token': token1}, timeout: const Duration(seconds: 10));
    if (post1.statusCode >= 300) return const [];

    final s2 = await fetchJson('https://enc-dec.app/api/enc-$apiName?text=${Uri.encodeComponent(post1.body)}&stage=2', timeout: const Duration(seconds: 8));
    if (dig(s2, ['status']) != 200 || !truthy(dig(s2, ['result', 'servers']))) return const [];
    final serversUrl = '${dig(s2, ['result', 'servers'])}';
    final streamBaseUrl = '${dig(s2, ['result', 'stream'])}';
    final currentHeaders = {...baseHeaders, 'X-CSRF-Token': '${dig(s2, ['result', 'token'])}'};

    final serversRes = await fetchRaw(serversUrl, method: 'POST', headers: currentHeaders, timeout: const Duration(seconds: 10));
    if (serversRes.statusCode >= 300) return const [];
    final dec = await fetchJson('https://enc-dec.app/api/dec-$apiName',
        method: 'POST', headers: {'Content-Type': 'application/json'}, body: json.encode({'text': serversRes.body}), timeout: const Duration(seconds: 8));
    if (dig(dec, ['status']) != 200 || dig(dec, ['result']) is! List) return const [];

    final all = <FoundStream>[];
    for (final server in dig(dec, ['result']) as List) {
      if (!truthy(dig(server, ['data']))) continue;
      try {
        final enc = await fetchRaw('$streamBaseUrl/${server['data']}', method: 'POST', headers: currentHeaders, timeout: const Duration(seconds: 8));
        if (enc.statusCode >= 300) continue;
        final d = await fetchJson('https://enc-dec.app/api/dec-$apiName',
            method: 'POST', headers: {'Content-Type': 'application/json'}, body: json.encode({'text': enc.body}), timeout: const Duration(seconds: 8));
        if (dig(d, ['status']) != 200 || !truthy(dig(d, ['result']))) continue;
        final r = d['result'];
        final url = r is String ? r : firstTruthy([dig(r, ['url']), dig(r, ['file'])]);
        if (url is String && url.startsWith('http')) {
          final name = firstTruthy([server['name'], server['title']]);
          all.add(FoundStream(
            url: url,
            server: '$serverLabel - ${name ?? 'Server'}',
            label: '${name ?? serverLabel}',
            type: url.contains('.m3u8') ? 'hls' : 'mp4',
            headers: {'User-Agent': ua, 'Referer': '$baseUrl/'},
          ));
        }
      } catch (_) {}
    }
    return all;
  } catch (_) {
    return const [];
  }
}
