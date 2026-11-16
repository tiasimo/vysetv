import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'anilist.dart';
import 'intro_db.dart' show Segment, SegmentKind;
import 'net.dart';
import 'sources.dart' show StreamSource;
import 'stream_proxy.dart';
import 'subtitles.dart' show SubtitleTrack, subtitleTrack;

/// Where anime plays from. Ported from PlayTorrio's anime extractors: of its thirteen, these are
/// the ones still answering with video (checked 4 Nov 2026). Each goes by the site's own name:
///
/// * ReCloud: cdn.4animo.xyz, by AniList id. Subtitles and intro/outro times.
/// * ReCloud Dub: the same, English dub.
/// * 123Anime / 123Anime Dub: 123animehub.cc, by title (the dub has its own "-dub" page); plays
///   from EchoVideo.
/// * Hentaini: hentaini.com, by title; adult titles only.
/// * WatchHentai: watchhentai.net, by title; adult titles only. MP4 in 720p to 1440p.
/// * AnimeHeaven: animeheaven.me, by title (from the Anivault scraper); MP4.
/// * DesiDubAnime: desidubanime.me through VidMoly, by title (from the Anivault scraper); Hindi dub.
/// * MegaPlay / MegaPlay Dub: megaplay.buzz, by AniList id. AES-encrypted stream URL, subtitles,
///   and intro/outro markers.
///
/// Gone, or now only letting their own pages in (left that way):
/// TryEmbed and VidNest (signed requests and one-time nonces), AniDB (its site
/// was replaced), AniNeko and Dulo (down), Luna, AniHQ and ani.pm (Cloudflare's browser check).
class AnimeServer {
  const AnimeServer(this.name, this._fetch, {required this.note, this.audio, this.adult = false, this.subtitles = false});
  final String name;

  /// What you get, for the Sources list: "Japanese audio · subtitles", "English dub".
  final String note;

  /// Set when the server carries dubbed audio.
  final String? audio;
  final bool adult; // only for adult titles

  /// Comes with subtitle files. The player asks every one of these in the background, whichever
  /// server plays, so the subtitles menu always has all of them.
  final bool subtitles;
  final Future<AnimeStream?> Function(Anime a, int episode) _fetch;

  /// The stream for episode [episode] of [a]; null when this server doesn't have it.
  Future<AnimeStream?> fetch(Anime a, int episode) async {
    try {
      final s = await _fetch(a, episode).timeout(const Duration(seconds: 25));
      // the relay sends each host the headers it insists on
      if (s != null) StreamProxy.instance.useHeaders(s.source.url, s.source.headers);
      return s;
    } catch (_) {
      return null;
    }
  }
}

/// The servers worth asking for [a]: the adult-only one only for adult titles, and only those
/// for them (the others don't carry them).
List<AnimeServer> animeServersFor(Anime a) => [for (final s in animeServers) if (s.adult == a.isAdult) s];

const animeServers = [
  // MegaPlay first: fast, subtitles in 9 languages, intro/outro skip
  AnimeServer('MegaPlay', _ryuuSub, note: 'Japanese audio · subtitles', subtitles: true),
  AnimeServer('MegaPlay Dub', _ryuuDub, note: 'English dub · subtitles', audio: 'English', subtitles: true),
  AnimeServer('123Anime', _tanukiSub, note: 'Japanese audio'),
  AnimeServer('123Anime Dub', _tanukiDub, note: 'English dub', audio: 'English'),
  AnimeServer('AnimeHeaven', _sora, note: 'Japanese audio'),
  AnimeServer('DesiDubAnime', _tora, note: 'Hindi dub', audio: 'Hindi'),
  // ReCloud last: its CDN is slow and its separate audio rendition often stalls
  AnimeServer('ReCloud', _kitsuneSub, note: 'Japanese audio · subtitles', subtitles: true),
  AnimeServer('ReCloud Dub', _kitsuneDub, note: 'English dub', audio: 'English', subtitles: true),
  AnimeServer('Hentaini', _hotaru, note: 'Japanese audio', adult: true),
  AnimeServer('WatchHentai', _hoshi, note: 'Japanese audio · English subtitles', adult: true, subtitles: true),
];

/// An anime in the player: the title, how many episodes are out (for "next") and their names.
class AnimeTarget {
  const AnimeTarget(this.anime, {this.episodes, this.names = const {}});
  final Anime anime;
  final int? episodes;
  final Map<int, String> names;
}

/// One episode's stream from one server, with the subtitles and skip times that came with it.
class AnimeStream {
  const AnimeStream(this.source, {this.subtitles = const [], this.segments = const []});
  final StreamSource source;
  final List<SubtitleTrack> subtitles;
  final List<Segment> segments; // intro, credits
}

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';

Future<String> _get(String url, {String? referer, Map<String, String> headers = const {}}) async {
  final r = await netClient
      .get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept-Language': 'en-US,en;q=0.9', 'Referer': ?referer, ...headers})
      .timeout(const Duration(seconds: 12));
  if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode} for $url');
  return utf8.decode(r.bodyBytes, allowMalformed: true);
}

StreamSource _source(String server, String url, String referer, String origin, {String? audio, List<({String label, String url})> qualities = const []}) =>
    StreamSource(
      url: url,
      server: server,
      quality: '',
      referrer: referer,
      userAgent: _ua,
      headers: {'Referer': referer, 'Origin': origin, 'User-Agent': _ua},
      hls: !url.contains('.mp4'),
      audio: audio,
      qualities: qualities,
    );

/// "English (full subtitles [9volt])", "French - Track 10 (FRE)", "Portuguese (Brazilian)": the
/// language is the first word; the rest says which file it is (full, signs & songs, a fansub
/// group, a region), tidied into the release name the subtitles menu shows.
SubtitleTrack _subtitle(String id, String server, String label, String url) {
  final lang = label.split(RegExp(r'[\s(\[,-]')).first;
  return subtitleTrack(id, server, lang.isEmpty ? 'English' : lang, url, release: _kind(label.substring(lang.length)), format: 'vtt');
}

/// "(full subtitles [9volt])" → "Full subtitles · 9volt"; "- Track 10 (FRE)" → "".
String _kind(String rest) {
  final parts = rest
      .replaceAll(RegExp(r'track\s*\d+', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\(\s*[A-Za-z]{3}\s*\)'), ' ') // (FRE), (ENG): the language again
      .split(RegExp(r'[\[\]()]+|\s+-\s+'))
      .map((p) => p.replaceAll(RegExp(r'^[\s,\-]+|[\s,\-]+$'), '').replaceAll(RegExp(r'\s+'), ' '))
      .where((p) => p.isNotEmpty)
      // short tags read as tags: AI, CC
      .map((p) => p.split(' ').map((w) => w.length <= 2 && RegExp(r'^[a-z]+$', caseSensitive: false).hasMatch(w) ? w.toUpperCase() : w).join(' '))
      .toList();
  if (parts.isEmpty) return '';
  final first = parts.first;
  parts[0] = first[0].toUpperCase() + first.substring(1);
  return parts.join(' · ');
}

/// {start, end} in seconds, when it's a real stretch.
Segment? _segment(Object? m, SegmentKind kind) {
  if (m is! Map) return null;
  final s = m['start'], e = m['end'];
  if (s is! num || e is! num || e <= s) return null;
  return Segment(kind, Duration(milliseconds: (s * 1000).round()), Duration(milliseconds: (e * 1000).round()));
}

// ── ReCloud / ReCloud Dub: cdn.4animo.xyz ──

const _recloud = 'https://cdn.4animo.xyz';

Future<AnimeStream?> _kitsuneSub(Anime a, int episode) => _recloudFetch('ReCloud', a, episode, dub: false);
Future<AnimeStream?> _kitsuneDub(Anime a, int episode) => _recloudFetch('ReCloud Dub', a, episode, dub: true);

Future<AnimeStream?> _recloudFetch(String server, Anime a, int episode, {required bool dub}) async {
  final embed = '$_recloud/embed/ani/${a.id}/$episode/${dub ? 'dub' : 'sub'}?k=1';
  final page = await _get(embed, referer: 'https://google.com/');
  final path = RegExp(r'''var\s+sourcesUrl\s*=\s*['"]([^'"]+)['"]''').firstMatch(page)?.group(1);
  if (path == null) return null;
  String abs(String p) => p.startsWith('http') ? p : '$_recloud$p';
  final data = json.decode(await _get(abs(path), referer: embed, headers: const {'Accept': 'application/json, text/plain, */*'}));
  if (data is! Map) return null;
  final file = ((data['sources'] as List?)?.firstOrNull as Map?)?['file'] as String?;
  if (file == null || file.isEmpty) return null;
  return AnimeStream(
    _source(server, abs(file), '$_recloud/', _recloud, audio: dub ? 'English' : null),
    subtitles: [
      for (final (i, t) in ((data['tracks'] as List?) ?? const []).whereType<Map>().indexed)
        if (t['kind'] != 'thumbnails' && '${t['file'] ?? ''}'.isNotEmpty)
          _subtitle('${server.toLowerCase()}-$i', server, '${t['label'] ?? 'English'}', abs('${t['file']}')),
    ],
    segments: [?_segment(data['intro'], SegmentKind.intro), ?_segment(data['outro'], SegmentKind.credits)],
  );
}

// ── 123Anime: 123animehub.cc ──

const _hub = 'https://123animehub.cc';

String _slugOf(String title) => title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

Future<AnimeStream?> _tanukiSub(Anime a, int episode) => _tanuki(a, episode, dub: false);
Future<AnimeStream?> _tanukiDub(Anime a, int episode) => _tanuki(a, episode, dub: true);

Future<AnimeStream?> _tanuki(Anime a, int episode, {required bool dub}) async {
  final titles = {a.english, a.romaji, ...a.synonyms}.where((t) => t.trim().isNotEmpty).take(4);
  final slugs = <String>[];
  for (final title in titles) {
    final keyword = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (keyword.isEmpty) continue;
    try {
      final uri = Uri.parse('$_hub/ajax/film/search').replace(queryParameters: {'keyword': keyword, '_': '${DateTime.now().millisecondsSinceEpoch}'});
      final data = json.decode(await _get(uri.toString(), referer: _hub, headers: const {'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json'}));
      final html = data is Map ? '${data['html'] ?? ''}' : '';
      for (final m in RegExp(r'href="/anime/([^"]+)"').allMatches(html)) {
        final s = m.group(1)!;
        if (!slugs.contains(s)) slugs.add(s);
      }
    } catch (_) {}
    if (slugs.isNotEmpty) break;
  }
  // the dub has a page of its own, "<slug>-dub"; the title's own page first (not a sequel or
  // film), then the rest in the site's order
  slugs.retainWhere((s) => s.endsWith('-dub') == dub);
  final wanted = {for (final t in titles) dub ? '${_slugOf(t)}-dub' : _slugOf(t)};
  slugs.sort((x, y) => (wanted.contains(x) ? 0 : 1).compareTo(wanted.contains(y) ? 0 : 1));

  String? target;
  for (final slug in slugs.take(4)) {
    try {
      final uri = Uri.parse('$_hub/ajax/episode/info').replace(queryParameters: {'epr': '$slug/$episode', 'ts': '1', '_': '${DateTime.now().millisecondsSinceEpoch}'});
      final data = json.decode(await _get(uri.toString(), referer: '$_hub/anime/$slug', headers: const {'X-Requested-With': 'XMLHttpRequest'}));
      if (data is Map && data['target'] is String) {
        target = data['target'] as String;
        break;
      }
    } catch (_) {}
  }
  if (target == null) return null;
  final id = RegExp(r'/embed-[^/]+/([A-Za-z0-9+/=]+)$').firstMatch(target)?.group(1);
  if (id == null) return null;

  final embed = await netClient.get(Uri.parse(target), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 10));
  if (embed.statusCode != 200) return null;
  final cookie = embed.headers['set-cookie']?.split(';').first.trim();
  final data = json.decode(await _get('${Uri.parse(target).origin}/hs/getSources?id=$id', referer: target, headers: {'Accept': '*/*', 'Cookie': ?cookie}));
  if (data is! Map) return null;
  final sources = data['sources'];
  final file = switch (sources) {
    final String s when s.isNotEmpty => s,
    final List l when l.isNotEmpty && l.first is Map => ((l.first as Map)['file'] ?? (l.first as Map)['src'] ?? (l.first as Map)['url']) as String?,
    _ => null,
  };
  if (file == null || file.isEmpty) return null;
  return AnimeStream(_source(dub ? '123Anime Dub' : '123Anime', file, 'https://play2.echovideo.ru/', 'https://play2.echovideo.ru', audio: dub ? 'English' : null));
}

// ── Hentaini: hentaini.com (adult) ──

const _hentaini = 'https://hentaini.com', _hentainiApi = 'https://admin.hentaini.com/api';

const _stopwords = {
  'a', 'an', 'the', 'of', 'and', 'or', 'to', 'in', 'on', 'at', 'for', 'with', 'by', 'from', 'is', 'it', //
  'no', 'wa', 'ga', 'ni', 'o', 'wo', 'de', 'mo', 'ka', 'ya', 'na', 'e', 'he', 'te', 'ne', //
  'animation', 'anime', 'motion', 'ova', 'ona', 'tv', 'special', 'version', 'edition', 'dubbed', 'subbed', 'sub', 'dub',
  'uncensored', 'censored', 'episode', 'ep', 'season', 'side', 'part', 'arc', 'chapter', 'vol', 'volume',
};

Set<String> _words(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').split(' ').where((t) => (t.length > 1 || RegExp(r'\d').hasMatch(t)) && !_stopwords.contains(t)).toSet();

/// A title and shorter forms of it to search a catalogue with ("X: Y" → "X", the first words).
Iterable<String> _searches(String t) => {
      t.trim(),
      for (final cut in [RegExp(r'\s*[:\-~–—].+$'), RegExp(r'\s*\(.+?\)\s*'), RegExp(r'\s*\[.+?\]\s*')]) t.replaceAll(cut, '').trim(),
      t.split(RegExp(r'\s+')).take(3).join(' '),
    }.where((v) => v.length >= 3);

/// The key of the name in [found] closest to one of [titles] by shared words, if at least [min]
/// alike.
K? _closest<K>(Map<K, String> found, List<String> titles, double min) {
  K? best;
  var score = min, length = 1 << 30;
  for (final MapEntry(:key, :value) in found.entries) {
    final words = _words(value);
    for (final t in titles) {
      final q = _words(t);
      final union = words.union(q).length;
      final j = union == 0 ? 0.0 : words.intersection(q).length / union;
      // equally close: the shorter name (the show itself, not a spin-off)
      if (j > score || (j == score && value.length < length)) {
        score = j;
        best = key;
        length = value.length;
      }
    }
  }
  return best;
}

List<String> _adultTitles(Anime a) => {a.romaji, a.english, ...a.synonyms}.where((t) => t.trim().isNotEmpty).toList();

Future<AnimeStream?> _hotaru(Anime a, int episode) async {
  final titles = _adultTitles(a);
  // search the site's catalogue by the title, then by shorter forms of it
  final hits = <int, String>{};
  for (final t in titles) {
    for (final q in _searches(t)) {
      try {
        final data = json.decode(await _get(
          '$_hentainiApi/series?filters[title][\$containsi]=${Uri.encodeQueryComponent(q)}&pagination[pageSize]=25',
          referer: '$_hentaini/',
          headers: const {'Accept': 'application/json'},
        ));
        for (final item in ((data as Map)['data'] as List? ?? const []).whereType<Map>()) {
          final id = (item['id'] as num?)?.toInt();
          final attr = (item['attributes'] as Map?) ?? item;
          if (id != null) hits.putIfAbsent(id, () => '${attr['title'] ?? ''} ${attr['title_english'] ?? ''}');
        }
      } catch (_) {}
      if (hits.isNotEmpty) break;
    }
    if (hits.isNotEmpty) break;
  }
  final best = _closest(hits, titles, .45);
  if (best == null) return null;

  final data = json.decode(await _get('$_hentainiApi/series/$best?populate=episodes', referer: '$_hentaini/', headers: const {'Accept': 'application/json'}));
  final series = ((data as Map)['data'] as Map?) ?? const {};
  final attr = (series['attributes'] as Map?) ?? series;
  final eps = attr['episodes'] is Map ? (attr['episodes'] as Map)['data'] : attr['episodes'];
  final list = [for (final e in (eps as List? ?? const []).whereType<Map>()) (e['attributes'] as Map?) ?? e];
  final ep = list.where((e) => int.tryParse('${e['episode_number']}') == episode).firstOrNull ?? (episode <= list.length ? list[episode - 1] : null);
  if (ep == null) return null;
  var players = ep['players'];
  if (players is String) players = json.decode(players);
  String? hls, mp4;
  for (final p in (players as List? ?? const []).whereType<Map>()) {
    final file = '${p['file'] ?? p['url'] ?? p['link'] ?? ''}';
    if (file.contains('.m3u8')) hls ??= file;
    if (file.contains('.mp4')) mp4 ??= file;
  }
  final file = hls ?? mp4;
  return file == null ? null : AnimeStream(_source('Hentaini', file, '$_hentaini/', _hentaini));
}

// ── WatchHentai: watchhentai.net (adult) ──

const _wh = 'https://watchhentai.net';

/// The player page keeps its video links encoded and decodes them itself (whDecodeMediaUrl):
/// base64, each byte XORed with 13 + its position mod 17, reversed, base64 again.
String _whDecode(String s) {
  var b = s.replaceAll('-', '+').replaceAll('_', '/');
  while (b.length % 4 != 0) {
    b += '=';
  }
  final x = base64.decode(b);
  final r = String.fromCharCodes([for (var i = 0; i < x.length; i++) x[i] ^ ((13 + i % 17) & 255)]);
  return latin1.decode(base64.decode(r.split('').reversed.join()));
}

Future<AnimeStream?> _hoshi(Anime a, int episode) async {
  final titles = _adultTitles(a);
  // 1. the site's search: each result's series link and name
  final hits = <String, String>{};
  for (final t in titles) {
    for (final q in _searches(t)) {
      try {
        final html = await _get('$_wh/?s=${Uri.encodeQueryComponent(q)}', referer: '$_wh/');
        final at = html.indexOf('archive-content');
        if (at >= 0) {
          for (final m in RegExp(r'<h3><a href="(https://watchhentai\.net/series/[^"]+)"[^>]*>([^<]+)</a>').allMatches(html.substring(at))) {
            hits.putIfAbsent(m[1]!, () => m[2]!);
          }
        }
      } catch (_) {}
      if (hits.isNotEmpty) break;
    }
    if (hits.isNotEmpty) break;
  }
  final series = _closest(hits, titles, .5);
  if (series == null) return null;

  // 2. the series page links its episodes: /videos/<name>-episode-N-…/
  final page = await _get(series, referer: '$_wh/');
  String? video;
  for (final m in RegExp(r'/videos/([a-z0-9-]+-episode-(\d+)[a-z0-9-]*)/?').allMatches(page)) {
    if (int.parse(m[2]!) == episode) {
      video = '$_wh/videos/${m[1]}/';
      break;
    }
  }
  if (video == null) return null;

  // 3. the episode page names its player; 4. the player lists each quality, encoded
  final player = RegExp(r'data-primary-player-url="([^"]+)"').firstMatch(await _get(video, referer: series))?.group(1)?.replaceAll('&amp;', '&');
  if (player == null) return null;
  final list = RegExp(r'whJwSources\s*=\s*(\[.*?\]);', dotAll: true).firstMatch(await _get(player, referer: video))?.group(1);
  if (list == null) return null;
  final qualities = [
    for (final q in (json.decode(list) as List).whereType<Map>())
      if (q['file'] is String) (label: '${q['label'] ?? ''}', url: _whDecode(q['file'] as String)),
  ]..sort((x, y) => (int.tryParse(y.label.replaceAll(RegExp(r'\D'), '')) ?? 0).compareTo(int.tryParse(x.label.replaceAll(RegExp(r'\D'), '')) ?? 0));
  if (qualities.isEmpty) return null;
  final start = qualities.where((q) => q.label == '1080p').firstOrNull ?? qualities.first;
  return AnimeStream(_source('WatchHentai', start.url, '$_wh/', _wh, qualities: qualities));
}

// ── MegaPlay / MegaPlay Dub: megaplay.buzz ──
//
// The site takes the AniList id directly and has a sub/dub toggle. The getSources endpoint
// returns an AES-256-CBC encrypted `enc` field (base64url) instead of a plain URL. The key
// and IV are shipped in its JS bundles; we fetch them at startup and cache.

const _mega = 'https://megaplay.buzz';
const _megaCookie = 'SITE_TOTAL_ID=ce655f0eea754f2888ea98ded373e3b5';

// AES key/IV, fetched once from the player's JS.
String? _megaKey, _megaIV;

Future<void> _megaLoadKeys() async {
  if (_megaKey != null && _megaIV != null) return;
  final js = await _get('$_mega/lib/app.main.js?v=2.01792598400', referer: '$_mega/');
  _megaKey = RegExp(r'DOMAINS_ENC_KEY="([^"]+)"').firstMatch(js)?.group(1);
  _megaIV = RegExp(r'DOMAINS_ENC_IV="([^"]+)"').firstMatch(js)?.group(1);
}

Uint8List _padBytes(String s, int len) {
  final b = utf8.encode(s);
  final out = Uint8List(len);
  out.setRange(0, b.length < len ? b.length : len, b);
  return out;
}

Map<String, dynamic>? _megaDecrypt(String enc) {
  if (_megaKey == null || _megaIV == null) return null;
  final ct = base64Url.decode(base64Url.normalize(enc));
  final cipher = pc.PaddedBlockCipher('AES/CBC/PKCS7')
    ..init(false, pc.PaddedBlockCipherParameters<pc.CipherParameters, Null>(
      pc.ParametersWithIV(pc.KeyParameter(_padBytes(_megaKey!, 32)), _padBytes(_megaIV!, 16)),
      null,
    ));
  final plain = utf8.decode(cipher.process(Uint8List.fromList(ct)));
  final j = json.decode(plain);
  return j is Map<String, dynamic> ? j : null;
}

Future<AnimeStream?> _ryuuSub(Anime a, int episode) => _megaFetch('MegaPlay', a, episode, 'sub');
Future<AnimeStream?> _ryuuDub(Anime a, int episode) => _megaFetch('MegaPlay Dub', a, episode, 'dub');

Future<AnimeStream?> _megaFetch(String server, Anime a, int episode, String cat) async {
  await _megaLoadKeys();
  final playerUrl = '$_mega/stream/ani/${a.id}/$episode/$cat';
  final html = await _get(playerUrl, referer: '$_mega/api', headers: const {'Cookie': _megaCookie});
  var dataId = RegExp(r'data-id="([^"]+)"').firstMatch(html)?.group(1);
  var domain = _mega;
  var referer = playerUrl;

  // sometimes the player embeds an iframe on another domain
  if (dataId == null || dataId.isEmpty) {
    final iframeSrc = RegExp(r'<iframe[^>]+src="([^"]+)"').firstMatch(html)?.group(1);
    if (iframeSrc == null) return null;
    final fullSrc = iframeSrc.startsWith('//') ? 'https:$iframeSrc' : (iframeSrc.startsWith('http') ? iframeSrc : '$_mega$iframeSrc');
    domain = Uri.parse(fullSrc).origin;
    referer = fullSrc;
    final iframeHtml = await _get(fullSrc, referer: playerUrl, headers: const {'Cookie': _megaCookie});
    dataId = RegExp(r'data-id="([^"]+)"').firstMatch(iframeHtml)?.group(1);
    if (dataId == null || dataId.isEmpty) return null;
  }

  final sourcesUrl = '$domain/stream/getSources?id=$dataId';
  final data = json.decode(await _get(sourcesUrl, referer: referer, headers: const {
    'Accept': 'application/json, text/javascript, */*; q=0.01',
    'X-Requested-With': 'XMLHttpRequest',
    'Cookie': _megaCookie,
  }));
  if (data is! Map) return null;

  // the stream URL is either in `enc` (AES-encrypted) or `sources.file` (plain, older API)
  String? file;
  if (data['enc'] is String) {
    file = _megaDecrypt(data['enc'] as String)?['file'] as String?;
  } else if (data['sources'] is Map) {
    file = (data['sources'] as Map)['file'] as String?;
  }
  if (file == null || file.isEmpty) return null;

  return AnimeStream(
    _source(server, file, '$domain/', domain, audio: cat == 'dub' ? 'English' : null),
    subtitles: [
      for (final (i, t) in ((data['tracks'] as List?) ?? const []).whereType<Map>().indexed)
        if (t['kind'] != 'thumbnails' && '${t['file'] ?? ''}'.isNotEmpty)
          _subtitle('${server.toLowerCase().replaceAll(' ', '-')}-$i', server, '${t['label'] ?? 'English'}', '${t['file']}'),
    ],
    segments: [?_segment(data['intro'], SegmentKind.intro), ?_segment(data['outro'], SegmentKind.credits)],
  );
}

// ── AnimeHeaven: animeheaven.me ──

const _heaven = 'https://animeheaven.me';

Future<AnimeStream?> _sora(Anime a, int episode) async {
  final titles = _adultTitles(a);
  final hits = <String, String>{}; // anime.php id → name
  for (final t in titles.take(3)) {
    for (final q in _searches(t)) {
      try {
        final html = await _get('$_heaven/fastsearch.php?xhr=1&s=${Uri.encodeQueryComponent(q)}', referer: '$_heaven/');
        for (final m in RegExp(r'''href=['"][^'"]*anime\.php\?([^'"]+)['"].*?class=['"]fastname['"][^>]*>([^<]+)''', dotAll: true).allMatches(html)) {
          hits.putIfAbsent(m[1]!, () => m[2]!.replaceAll('&#039;', "'").replaceAll('&amp;', '&'));
        }
      } catch (_) {}
      if (hits.isNotEmpty) break;
    }
    if (hits.isNotEmpty) break;
  }
  final id = _closest(hits, titles, .5);
  if (id == null) return null;
  final page = await _get('$_heaven/anime.php?$id', referer: '$_heaven/');
  String? key;
  for (final m in RegExp(r'''gatea\(\s*["']([^"']+)["']\).{0,400}?watch2[^>]*>\s*([0-9.]+)''', dotAll: true).allMatches(page)) {
    if (double.tryParse(m[2]!) == episode) {
      key = m[1];
      break;
    }
  }
  if (key == null) return null;
  // the gate lists the episode on a few mirrors (their links carry its key) plus a short
  // placeholder clip that doesn't
  final gate = await _get('$_heaven/gate.php', referer: '$_heaven/anime.php?$id', headers: {'Cookie': 'key=$key'});
  final files = [
    for (final m in RegExp(r'''<source[^>]+src=['"](https?://[^'"]+)['"]''').allMatches(gate))
      if (m[1]!.contains('?$key') && !m[1]!.contains('&error')) m[1]!,
  ];
  return files.isEmpty ? null : AnimeStream(_source('AnimeHeaven', files.first, '$_heaven/', _heaven));
}

// ── DesiDubAnime: desidubanime.me (Hindi dubs), played from VidMoly ──

const _desi = 'https://www.desidubanime.me';
String? _desiNonce; // WordPress's search nonce, printed on its homepage

Future<AnimeStream?> _tora(Anime a, int episode) async {
  _desiNonce ??= RegExp(r'"search_actions":\s*"([a-f0-9]+)"').firstMatch(await _get('$_desi/'))?.group(1);
  if (_desiNonce == null) return null;
  final titles = _adultTitles(a);
  final hits = <String, String>{}; // slug → name
  // the site rate-limits: two searches at most
  for (final q in titles.expand(_searches).take(2)) {
    try {
      final data = json.decode(await _get(
        '$_desi/wp-admin/admin-ajax.php?action=instant_search&query=${Uri.encodeQueryComponent(q)}&nonce=$_desiNonce',
        referer: '$_desi/',
        headers: const {'X-Requested-With': 'XMLHttpRequest'},
      ));
      final html = '${(data is Map ? ((data['data'] as Map?)?['html'] ?? data['html']) : null) ?? ''}';
      for (final m in RegExp(r'href="https://www\.desidubanime\.me/anime/([^"/]+)/"[^>]*title="([^"]*)"').allMatches(html)) {
        hits.putIfAbsent(m[1]!, () => m[2]!);
      }
    } catch (_) {}
    if (hits.isNotEmpty) break;
  }
  final slug = _closest(hits, titles, .5);
  if (slug == null) return null;
  String page;
  try {
    page = await _get('$_desi/watch/$slug-episode-$episode/', referer: '$_desi/anime/$slug/');
  } catch (_) {
    final show = await _get('$_desi/anime/$slug/', referer: '$_desi/');
    final link = RegExp('href="($_desi/watch/[^"]+-episode-$episode/)"').firstMatch(show)?.group(1);
    if (link == null) return null;
    page = await _get(link, referer: '$_desi/anime/$slug/');
  }
  // servers: data-embed-id="base64(name):base64(embed)"; VidMoly hands out a plain HLS link
  String b64(String v) => utf8.decode(base64.decode(base64.normalize(v)), allowMalformed: true);
  for (final m in RegExp(r'''data-embed-id=["']([^"':]+):([^"']+)["']''').allMatches(page)) {
    final embed = b64(m[2]!);
    final src = RegExp(r'''src=["']([^"']+)''').firstMatch(embed)?.group(1) ?? embed.trim();
    if (!src.contains('vidmoly.')) continue;
    final html = await _get(src, referer: '$_desi/');
    final m3u8 = RegExp(r'''(https?://[^\s"']+\.m3u8[^\s"']*)''').firstMatch(html)?.group(1);
    final origin = Uri.parse(src).origin;
    if (m3u8 != null) return AnimeStream(_source('DesiDubAnime', m3u8, '$origin/', origin, audio: 'Hindi'));
  }
  return null;
}
