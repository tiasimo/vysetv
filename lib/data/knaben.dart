// Lorewatch's built-in torrent source: Knaben (knaben.org), a search engine over the public
// torrent sites. Ported from PlayTorrio (GPL-3.0), lib/services/scraper/sites/knaben.dart:
// the search, and its rule for what counts as the right title, season and episode.
//
// Two things differ from the original. Knaben's own JSON API is asked first (exact sizes, no
// page layout to break on); the original's reading of the search page is kept as the fallback.
// And an episode is searched for twice, once as "s01e03" and once as "s01", so both single
// episodes and season packs come back: a show's season page is mostly other episodes.
//
// A result is only a torrent's name and info hash. Which file in it to play is decided when
// it is opened (lib/data/torrent_file_pick.dart).

import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;

import 'debrid/utils/parse_torrent_title.dart';
import 'net.dart';

/// One torrent Knaben found.
class KnabenHit {
  const KnabenHit({required this.name, required this.infoHash, this.bytes, this.seeders = 0, this.trackers = const [], this.pack = false});
  final String name;
  final String infoHash; // 40 hex characters, lower case
  final int? bytes;
  final int seeders;
  final List<String> trackers;

  /// A whole season (or more) in one torrent: the episode's file is found by name when it plays.
  final bool pack;

  KnabenHit asPack(bool pack) => KnabenHit(name: name, infoHash: infoHash, bytes: bytes, seeders: seeders, trackers: trackers, pack: pack);
}

class Knaben {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36';
  static const _api = 'https://api.knaben.org/v1';
  static const _timeout = Duration(seconds: 20);

  /// Torrents for a film ([series] false; [year] narrows it) or one episode of a show, most
  /// seeded first. Throws when Knaben can't be reached at all.
  static Future<List<KnabenHit>> search({required String title, required bool series, int? year, int? season, int? episode}) async {
    final clean = title.trim();
    if (clean.isEmpty) return const [];
    String two(int n) => n.toString().padLeft(2, '0');
    final queries = <String>[
      if (!series) (year != null ? '$clean $year' : clean),
      if (series && season != null) '$clean s${two(season)}',
      if (series && season != null && episode != null) '$clean s${two(season)}e${two(episode)}',
      if (series && season == null) clean,
    ];
    final lists = await Future.wait([for (final q in queries) _query(q)]);
    final seen = <String>{};
    final all = [
      for (final l in lists)
        for (final h in l)
          if (seen.add(h.infoHash)) h,
    ];
    return filter(all, title: clean, series: series, year: year, season: season, episode: episode);
  }

  /// One search: the API, or the search page when the API fails.
  static Future<List<KnabenHit>> _query(String query) async {
    try {
      final r = await netClient
          .post(
            Uri.parse(_api),
            headers: {'User-Agent': _ua, 'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: json.encode({
              'query': query,
              'search_field': 'title',
              'order_by': 'seeders',
              'order_direction': 'desc',
              'size': 60,
              'categories': _videoCategories,
              'hide_unsafe': true,
              'hide_xxx': true,
            }),
          )
          .timeout(_timeout);
      if (r.statusCode == 200) return parseApi(utf8.decode(r.bodyBytes, allowMalformed: true));
    } catch (_) {
      // the page below
    }
    final r = await netClient
        .get(Uri.parse('https://knaben.org/search/${Uri.encodeComponent(query)}/0/1/seeders'), headers: {'User-Agent': _ua})
        .timeout(_timeout);
    if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
    return parseHtml(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  // Knaben's category groups: TV, Movies, Anime.
  static const _videoCategories = [2000000, 3000000, 6000000];

  /// The API's answer (`{"hits": [{title, hash, magnetUrl, bytes, seeders, categoryId}, …]}`).
  static List<KnabenHit> parseApi(String body) {
    final j = json.decode(body);
    final hits = j is Map ? (j['hits'] as List?) ?? const [] : const [];
    final out = <KnabenHit>[];
    for (final h in hits.whereType<Map>()) {
      final name = '${h['title'] ?? ''}'.trim();
      final magnet = '${h['magnetUrl'] ?? ''}';
      final hash = infoHashOf('${h['hash'] ?? ''}') ?? infoHashOf(magnet);
      if (name.isEmpty || hash == null) continue; // some entries only have a .torrent file
      final cats = [for (final c in (h['categoryId'] as List?) ?? const []) if (c is num) c.toInt()];
      if (cats.isNotEmpty && !cats.any((c) => _videoCategories.contains(c - c % 1000000))) continue;
      out.add(KnabenHit(
        name: name,
        infoHash: hash,
        bytes: (h['bytes'] as num?)?.toInt(),
        seeders: (h['seeders'] as num?)?.toInt() ?? 0,
        trackers: trackersOf(magnet),
      ));
    }
    return out;
  }

  /// The search page, the way PlayTorrio reads it: one table row per torrent, with the name,
  /// the magnet link, the size (third cell) and the seeders (fifth).
  static List<KnabenHit> parseHtml(String body) {
    final out = <KnabenHit>[];
    for (final row in html.parse(body).querySelectorAll('table tbody tr')) {
      final cells = row.querySelectorAll('td');
      if (cells.length < 6) continue;
      final name = row.querySelector('.text-wrap.w-100 > a')?.text.trim() ?? '';
      final magnet = row.querySelector('a[href^="magnet:"]')?.attributes['href'] ?? '';
      final hash = infoHashOf(magnet);
      if (name.isEmpty || hash == null) continue;
      final category = cells[0].text.toLowerCase();
      if (!_videoWords.any(category.contains) && RegExp(r'[a-z]').hasMatch(category)) continue; // music, books, software…
      out.add(KnabenHit(
        name: name,
        infoHash: hash,
        bytes: bytesOf(cells[2].text),
        seeders: int.tryParse(cells[4].text.trim().replaceAll(',', '')) ?? 0,
        trackers: trackersOf(magnet),
      ));
    }
    return out;
  }

  static const _videoWords = ['movie', 'tv', 'anime', 'video'];

  static final _ptt = ParseTorrentTitle();
  static String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// PlayTorrio's rule: the torrent's name has to parse to exactly this title; for a show, a
  /// season in the name has to be this season, and an episode in the name this episode (none:
  /// a season pack, kept). Added here: a film's year in the name has to be the film's, give or
  /// take one, and an episode range (E01-E04) counts when the episode is inside it.
  /// Best seeded first.
  static List<KnabenHit> filter(List<KnabenHit> hits, {required String title, required bool series, int? year, int? season, int? episode}) {
    final want = _plain(title);
    final out = <KnabenHit>[];
    for (final h in hits) {
      final Map<String, dynamic> p;
      try {
        p = _ptt.parse(h.name);
      } catch (_) {
        continue;
      }
      if (_plain('${p['title'] ?? ''}') != want) continue;
      final pYear = p['year'] as int?;
      if (!series) {
        if (year != null && pYear != null && (pYear - year).abs() > 1) continue;
        out.add(h);
        continue;
      }
      final pSeason = p['season'] as int?;
      final pEpisode = p['episode'] as int?;
      final range = p['episodeRange'] as List<int>?;
      if (season != null && pSeason != null && pSeason != season) continue;
      final inRange = episode != null && range != null && episode >= range[0] && episode <= range[1];
      if (episode != null && pEpisode != null && pEpisode != episode && !inRange) continue;
      out.add(h.asPack(pEpisode == null || range != null));
    }
    out.sort((a, b) => b.seeders - a.seeders);
    return out;
  }

  /// The info hash in a magnet link (or a bare hash), as 40 lower-case hex characters. Magnets
  /// sometimes carry it in base32 (32 characters); those are converted. Null when there is none.
  static String? infoHashOf(String magnetOrHash) {
    final s = magnetOrHash.trim();
    final m = RegExp(r'urn:btih:([a-zA-Z0-9]+)').firstMatch(s);
    final raw = m?.group(1) ?? s;
    if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(raw)) return raw.toLowerCase();
    if (RegExp(r'^[a-zA-Z2-7]{32}$').hasMatch(raw)) {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      var bits = 0, value = 0;
      final hex = StringBuffer();
      for (final c in raw.toUpperCase().split('')) {
        value = (value << 5) | alphabet.indexOf(c);
        bits += 5;
        while (bits >= 4) {
          hex.write(((value >> (bits - 4)) & 0xF).toRadixString(16));
          bits -= 4;
        }
        value &= (1 << bits) - 1;
      }
      final out = hex.toString();
      return out.length == 40 ? out : null;
    }
    return null;
  }

  /// The trackers a magnet link names (`&tr=…`).
  static List<String> trackersOf(String magnet) {
    final out = <String>[];
    for (final m in RegExp(r'[?&]tr=([^&]+)').allMatches(magnet)) {
      try {
        final t = Uri.decodeComponent(m.group(1)!);
        if (t.contains('://') && !out.contains(t)) out.add(t);
      } catch (_) {}
    }
    return out;
  }

  /// "885.68 MB" → bytes.
  static int? bytesOf(String text) {
    final m = RegExp(r'(\d+(?:[.,]\d+)?)\s*(TB|TiB|GB|GiB|MB|MiB|KB|KiB)\b', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!.replaceAll(',', '.')) ?? 0;
    final u = m.group(2)!.toUpperCase();
    final mult = u.startsWith('T') ? 1e12 : (u.startsWith('G') ? 1e9 : (u.startsWith('M') ? 1e6 : 1e3));
    return (n * mult).round();
  }
}
