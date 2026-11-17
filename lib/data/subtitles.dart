import 'playback_prefs.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_settings.dart';
import 'codepages.dart';
import 'net.dart';
import 'tmdb.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const _tmdbKey = String.fromEnvironment('TMDB_API_KEY', defaultValue: 'b3556f3b206e16f82df4d1f6fd4545e6');

class SubtitleTrack {
  const SubtitleTrack({
    required this.id,
    required this.provider,
    required this.lang,
    required this.language,
    required this.release,
    required this.url,
    this.format = 'srt',
    this.translated = false,
  });
  final String id;
  final String provider;
  final String lang;
  final String language;

  /// The file's release name, when the provider gives one.
  final String release;
  final String url;
  final String format;

  /// Machine translated on demand (SubtitleCat), not a real file in this language.
  final bool translated;

  bool get hearingImpaired => RegExp(r'\b(sdh|hi|cc|hearing)\b', caseSensitive: false).hasMatch(release);
}

/// The subtitle language picked in Settings for what is playing (films, TV series and anime each
/// have their own, see [PlaybackPrefs]), as a code ("en", "es"…).
String preferredLang() => exactLanguage(PlaybackPrefs.subtitles(PlaybackPrefs.current).value) ?? 'it';

/// [tracks] in [lang], exact matches first ("pt" also takes "pt-br").
List<SubtitleTrack> inLanguage(Iterable<SubtitleTrack> tracks, String lang) {
  final base = lang.split('-').first;
  return [
    ...tracks.where((t) => t.lang == lang),
    ...tracks.where((t) => t.lang != lang && t.lang.split('-').first == base),
  ];
}

/// Every provider at once, deduplicated, the Settings language first, then by language.
Future<List<SubtitleTrack>> fetchSubtitles(Media media, {int? season, int? episode}) async {
  final q = _Query(media.id, media.isTv, season, episode);
  final batches = await Future.wait([
    _vdrk(q),
    _openSubtitles(q),
    _movy(q),
    _subtitleCat(q),
    _cinejoy(q),
  ].map((f) => f.catchError((Object _) => <SubtitleTrack>[])));
  final seen = <String>{};
  final all = [
    for (final b in batches)
      for (final t in b)
        if (seen.add(t.url)) t,
  ];
  final mine = preferredLang().split('-').first;
  bool ours(SubtitleTrack t) => t.lang.split('-').first == mine;
  all.sort((a, b) {
    if (ours(a) != ours(b)) return ours(a) ? -1 : 1;
    final c = a.language.compareTo(b.language);
    if (c != 0) return c;
    if (a.translated != b.translated) return a.translated ? 1 : -1;
    return 0;
  });
  return all;
}

/// The subtitle text, translated first when the track is a machine translation.
Future<String> fetchSubtitleContent(SubtitleTrack track) async {
  final mark = track.url.indexOf('#tl=');
  final url = mark < 0 ? track.url : track.url.substring(0, mark);
  final r = await netClient.get(Uri.parse(url), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}', Uri.parse(url));
  final text = _decode(r.bodyBytes, track.lang);
  if (mark < 0) return text;
  return _translateSrt(text, Uri.decodeComponent(track.url.substring(mark + 4)));
}

/// UTF-8 when it is; otherwise the Windows code page old SRTs in that language were saved in.
String _decode(List<int> bytes, String lang) {
  try {
    return utf8.decode(bytes).replaceFirst('﻿', '');
  } on FormatException {
    final cp = switch (lang.split('-').first) {
      'ar' || 'fa' || 'ur' => 1256,
      'ru' || 'uk' || 'bg' || 'sr' || 'mk' || 'be' => 1251,
      'el' => 1253,
      'tr' || 'az' => 1254,
      'he' || 'yi' => 1255,
      'cs' || 'sk' || 'pl' || 'hu' || 'hr' || 'ro' || 'sl' || 'bs' || 'sq' => 1250,
      'lt' || 'lv' || 'et' => 1257,
      'th' => 874,
      _ => 1252,
    };
    return decodeWindows(bytes, cp);
  }
}

// ──────────────────── Shared lookups ────────────────────

class _Query {
  _Query(this.id, this.isTv, this.season, this.episode);
  final int id;
  final bool isTv;
  final int? season;
  final int? episode;
  bool get isEpisode => isTv && season != null && episode != null;

  late final Future<({String title, String year, String imdb})?> details = () async {
    try {
      final type = isTv ? 'tv' : 'movie';
      final r = await http
          .get(Uri.parse('https://api.themoviedb.org/3/$type/$id?api_key=$_tmdbKey&append_to_response=external_ids'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      final d = json.decode(r.body) as Map<String, dynamic>;
      return (
        title: ((d['title'] ?? d['name']) ?? '') as String,
        year: ((d['release_date'] ?? d['first_air_date'] ?? '') as String).split('-').first,
        imdb: ((d['imdb_id'] ?? (d['external_ids'] as Map?)?['imdb_id']) ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }();
}

Future<dynamic> _json(String url, {Map<String, String>? headers, int seconds = 6}) async {
  final r = await netClient.get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept': 'application/json', ...?headers}).timeout(Duration(seconds: seconds));
  if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}', Uri.parse(url));
  return json.decode(r.body);
}

// ──────────────────── Providers ────────────────────

const _osMirrors = ['https://opensubtitles-v3.strem.io', 'https://opensubtitles.stremio.homes', 'https://opensubtitles.strem.io'];

Future<List<SubtitleTrack>> _openSubtitles(_Query q) async {
  final imdb = (await q.details)?.imdb ?? '';
  if (imdb.isEmpty) return [];
  final clean = imdb.startsWith('tt') ? imdb : 'tt$imdb';
  final target = q.isEpisode ? '$clean:${q.season}:${q.episode}' : clean;
  final type = q.isTv ? 'series' : 'movie';
  for (final base in _osMirrors) {
    try {
      final list = ((await _json('$base/subtitles/$type/$target.json')) as Map)['subtitles'] as List? ?? const [];
      if (list.isEmpty) continue;
      return [
        for (final (i, item) in list.cast<Map>().indexed)
          if (item['url'] is String)
            _track('os-${item['id'] ?? i}', 'OpenSubtitles', item['lang'] as String? ?? 'en', item['url'] as String,
                release: (item['movieReleaseName'] ?? item['subtitleFileName'] ?? '') as String, format: '${item['SubFormat'] ?? 'srt'}'),
      ];
    } catch (_) {}
  }
  return [];
}

const _vdrkBases = ['https://sub.vdrk.site/v1', 'https://sub.vdrk.site/v2'];

Future<List<SubtitleTrack>> _vdrk(_Query q) async {
  final path = q.isEpisode ? '/tv/${q.id}/${q.season}/${q.episode}' : '/movie/${q.id}';
  final lists = await Future.wait(_vdrkBases.map((b) => _json('$b$path', seconds: 5).then((v) => v as List, onError: (Object _) => const [])));
  return [
    for (final (v, list) in lists.indexed)
      for (final (i, item) in list.cast<Map>().indexed)
        if ((item['file'] ?? item['url']) is String)
          () {
            final raw = '${item['label'] ?? 'Unknown'}'.trim();
            var lang = raw.replaceAll(RegExp(r'\s*-\s*.*$'), '').replaceAll(RegExp(r'\s*\d+$'), '').replaceAll(RegExp(r'\s*Hi\d*$', caseSensitive: false), '').trim();
            if (lang.contains('(')) lang = lang.split('(').first.trim();
            return _track('vdrk-v${v + 1}-${i + 1}', 'Vdrk', lang, (item['file'] ?? item['url']) as String, release: raw, format: 'vtt');
          }(),
  ];
}

Future<List<SubtitleTrack>> _movy(_Query q) async {
  final url = 'https://subtitles.vidy.st/search?id=${q.id}${q.isEpisode ? '&season=${q.season}&episode=${q.episode}' : ''}';
  final list = await _json(url) as List;
  return [
    for (final (i, item) in list.cast<Map>().indexed)
      if (item['url'] is String)
        _track('movy-${item['id'] ?? i}', 'Movy', (item['language'] ?? item['display'] ?? 'en') as String, item['url'] as String,
            release: (item['release'] ?? item['fileName'] ?? '') as String, format: '${item['format'] ?? 'srt'}'),
  ];
}

Future<List<SubtitleTrack>> _cinejoy(_Query q) async {
  final uri = Uri.parse('https://subs.wing.st/subtitles').replace(queryParameters: {
    'type': q.isTv ? 'tv' : 'movie',
    'tmdb': '${q.id}',
    if (q.isTv && q.season != null) 'season': '${q.season}',
    if (q.isTv && q.episode != null) 'episode': '${q.episode}',
  });
  final data = await _json(uri.toString(), headers: {'Origin': 'https://cinejoy.pk', 'Referer': 'https://cinejoy.pk/watch'});
  final list = data is List ? data : ((data as Map)['subtitles'] as List? ?? const []);
  return [
    for (final (i, item) in list.cast<Map>().indexed)
      if (item['url'] is String)
        _track('cinejoy-${i + 1}', 'Cinejoy', (item['language'] ?? 'en') as String, item['url'] as String,
            release: (item['display'] ?? item['name'] ?? '') as String, format: '${item['type'] ?? 'srt'}'),
  ];
}

/// A subtitle file that came with a stream (anime sources), its language read from [rawLang]
/// ("English", "en", "Portuguese - Brazil"…).
SubtitleTrack subtitleTrack(String id, String provider, String rawLang, String url, {String release = '', String format = 'srt'}) =>
    _track(id, provider, rawLang, url, release: release, format: format);

SubtitleTrack _track(String id, String provider, String rawLang, String url, {String release = '', String format = 'srt', bool translated = false}) {
  final l = _normLang(rawLang);
  return SubtitleTrack(
    id: id,
    provider: provider,
    lang: l.code,
    language: l.name,
    release: release.trim(),
    url: url,
    format: format.toLowerCase(),
    translated: translated,
  );
}

// ──────────────────── SubtitleCat ────────────────────

const _catBase = 'https://www.subtitlecat.com';
const _stop = {'the', 'a', 'an', 'of', 'in', 'on', 'at', 'to', 'for', 'and', 'or'};

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp("['’`]"), '')
    .replaceAll(RegExp(r'[^a-z0-9À-ɏЀ-ӿ一-鿿]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _matchesTitle(String candidate, String title) {
  final c = _norm(candidate), t = _norm(title);
  if (c.isEmpty || t.isEmpty) return false;
  if (c.contains(t)) return true;
  final words = t.split(' ').where((w) => w.length > 1 && !_stop.contains(w)).toList();
  if (words.isEmpty) return c.split(' ').contains(t);
  final cw = c.split(' ').toSet();
  return words.every((w) => cw.contains(w) || c.contains(w));
}

bool _matchesEpisode(String candidate, int season, int episode) {
  final text = candidate.replaceAll(RegExp('%[0-9A-Fa-f]{2}'), ' ');
  RegExpMatch? m(String p) => RegExp(p, caseSensitive: false).firstMatch(text);
  final b = r'(?:^|[\s._\-\[(])', a = r'(?:$|[\s._\-\])])';
  if (m('${b}s0*(\\d{1,2})[\\s._-]*e(?:p|pisode)?0*(\\d{1,4})$a') case final x?) {
    return int.parse(x[1]!) == season && int.parse(x[2]!) == episode;
  }
  if (m('${b}0*(\\d{1,2})x0*(\\d{1,4})$a') case final x?) return int.parse(x[1]!) == season && int.parse(x[2]!) == episode;
  if (m(r'\bseason[\s._-]*0*(\d{1,2})[\s._-]*episode[\s._-]*0*(\d{1,4})\b') case final x?) {
    return int.parse(x[1]!) == season && int.parse(x[2]!) == episode;
  }
  final s = m(r'\b(?:season[\s._-]*0*(\d{1,2})|s0*(\d{1,2}))\b');
  if ((s == null ? 1 : int.parse(s[1] ?? s[2]!)) != season) return false;
  for (final p in [r'\bepisode[\s._-]*0*(\d{1,4})\b', '${b}ep\\.?[\\s._-]*0*(\\d{1,4})$a', '${b}e0*(\\d{1,4})$a']) {
    if (m(p) case final x?) return int.parse(x[1]!) == episode;
  }
  return false;
}

String _encPath(String p) => p.split('/').map((s) {
  if (s.isEmpty) return '';
  try {
    return Uri.encodeComponent(Uri.decodeComponent(s));
  } catch (_) {
    return Uri.encodeComponent(s);
  }
}).join('/');

Future<String?> _html(String url, {int seconds = 7}) async {
  try {
    final r = await netClient.get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept': 'text/html,*/*;q=0.8'}).timeout(Duration(seconds: seconds));
    return r.statusCode == 200 ? r.body : null;
  } catch (_) {
    return null;
  }
}

Future<List<SubtitleTrack>> _subtitleCat(_Query q) async {
  final d = await q.details;
  final title = (d?.title ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (title.isEmpty) return [];
  final queries = q.isEpisode
      ? [title, '$title S${'${q.season}'.padLeft(2, '0')}E${'${q.episode}'.padLeft(2, '0')}', '$title Episode ${q.episode}']
      : [if ((d?.year ?? '').isNotEmpty) '$title ${d!.year}', title];

  final hits = <({String rel, String title})>[];
  final seen = <String>{};
  final hitRe = RegExp(r'<a\s+href="(subs/\d+/[^"]+\.html)"[^>]*>([^<]*)</a>', caseSensitive: false);
  for (final query in queries) {
    final html = await _html('$_catBase/index.php?search=${Uri.encodeComponent(query)}&show=1000');
    for (final h in hitRe.allMatches(html ?? '')) {
      final rel = h[1]!, name = h[2]!.trim();
      if (seen.contains(rel)) continue;
      String label;
      try {
        label = '$name ${Uri.decodeComponent(rel)}';
      } catch (_) {
        label = '$name $rel';
      }
      if (!_matchesTitle(label, title)) continue;
      if (q.isEpisode) {
        if (!_matchesEpisode(label, q.season!, q.episode!)) continue;
      } else if (!q.isTv && RegExp(r'\b(?:s\d{1,2}e\d{1,3}|episode\s+\d{1,3})\b', caseSensitive: false).hasMatch(label)) {
        continue;
      }
      seen.add(rel);
      hits.add((rel: rel, title: name));
      if (hits.length >= 5) break;
    }
    if (hits.length >= 3) break;
  }
  if (hits.isEmpty) return [];

  final pages = await Future.wait(hits.map((h) => _html('$_catBase/${_encPath(h.rel)}', seconds: 6)));
  final dlRe = RegExp(r'<a\s+id="download_([A-Za-z0-9-]+)"[^>]*href="(/subs/\d+/[^"]+\.srt)"', caseSensitive: false);
  final trFolderRe = RegExp(r"translate_from_server_folder\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*\)", caseSensitive: false);
  final trServerRe = RegExp(r"translate_from_server\(\s*'([^']+)'\s*,\s*'([^']+)'\s*\)", caseSensitive: false);

  final out = <SubtitleTrack>[];
  final urls = <String>{};
  final have = <String>{};
  // Real files first.
  for (final (i, html) in pages.indexed) {
    for (final m in dlRe.allMatches(html ?? '')) {
      final url = '$_catBase${_encPath(m[2]!)}';
      if (!urls.add(url)) continue;
      final t = _track('subcat-${out.length + 1}', 'SubtitleCat', m[1]!, url, release: hits[i].title);
      have.add(t.lang);
      out.add(t);
    }
  }
  // Then machine translations, only for languages no real file covers.
  for (final (i, html) in pages.indexed) {
    if (html == null) continue;
    String? orig;
    final codes = <String>[];
    for (final m in trFolderRe.allMatches(html)) {
      final folder = m[3]!.endsWith('/') ? m[3]! : '${m[3]}/';
      orig ??= '$_catBase${_encPath('$folder${m[2]}')}';
      codes.add(m[1]!);
    }
    if (orig == null) {
      for (final m in trServerRe.allMatches(html)) {
        orig ??= '$_catBase${_encPath(m[2]!.startsWith('/') ? m[2]! : '/${m[2]}')}';
        codes.add(m[1]!);
      }
    }
    if (orig == null || codes.isEmpty) continue;
    for (final raw in codes) {
      if (!_langMap.containsKey(raw.toLowerCase().trim())) continue;
      final t = _track('subcat-${out.length + 1}', 'SubtitleCat', raw, '$orig#tl=${Uri.encodeComponent(raw)}', release: hits[i].title, translated: true);
      if (!have.add(t.lang) || !urls.add(t.url)) continue;
      out.add(t);
    }
    break;
  }
  return out;
}

// ──────────────────── On-demand translation ────────────────────

final _translated = <String, Future<String>>{};

Future<String> _translateSrt(String srt, String target) => _translated['${srt.hashCode}|$target'] ??= () async {
  final lines = srt.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = List<String>.of(lines);
  final timing = RegExp(r'^(\d{1,2}:\d{2}:\d{2}|\d{2}:\d{2})[,.]\d{1,3}\s*-->');
  final batches = <List<int>>[];
  var batch = <int>[];
  var chars = 0;
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.isEmpty || RegExp(r'^\d+$').hasMatch(t) || timing.hasMatch(t) || t.startsWith('WEBVTT')) continue;
    lines[i] = lines[i].replaceAll(RegExp('</?font[^>]*>', caseSensitive: false), '');
    if (chars + lines[i].length + 1 > 1500 && batch.isNotEmpty) {
      batches.add(batch);
      batch = [];
      chars = 0;
    }
    batch.add(i);
    chars += lines[i].length + 1;
  }
  if (batch.isNotEmpty) batches.add(batch);

  Future<void> run(List<int> b) async {
    try {
      final parts = (await _google(b.map((i) => lines[i]).join('\n'), target)).split('\n');
      if (parts.length == b.length) {
        for (var k = 0; k < b.length; k++) {
          out[b[k]] = parts[k];
        }
        return;
      }
      // line counts drifted: do this batch one line at a time so timings stay put
      await Future.wait([
        for (final i in b) _google(lines[i], target).then((s) => out[i] = s.replaceAll(RegExp(r'\n+'), ' '), onError: (Object _) => out[i] = lines[i]),
      ]);
    } catch (_) {}
  }

  for (var i = 0; i < batches.length; i += 8) {
    await Future.wait(batches.skip(i).take(8).map(run));
  }
  return out.join('\n');
}();

Future<String> _google(String text, String target) async {
  final uri = Uri.parse('https://translate.googleapis.com/translate_a/single').replace(queryParameters: {'client': 'gtx', 'sl': 'auto', 'tl': target, 'dt': 't', 'q': text});
  final r = await netClient.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 8));
  if (r.statusCode != 200) throw http.ClientException('translate ${r.statusCode}', uri);
  final data = json.decode(r.body) as List;
  return [for (final p in (data.first as List? ?? const [])) if (p is List && p.first is String) p.first as String].join();
}

// ──────────────────── Languages ────────────────────

typedef _Lang = ({String name, String code});

const Map<String, _Lang> _langMap = {
  'aa': (name: 'Afar', code: 'aa'),
  'ab': (name: 'Abkhazian', code: 'ab'),
  'af': (name: 'Afrikaans', code: 'af'),
  'ak': (name: 'Akan', code: 'ak'),
  'am': (name: 'Amharic', code: 'am'),
  'an': (name: 'Aragonese', code: 'an'),
  'ar': (name: 'Arabic', code: 'ar'),
  'as': (name: 'Assamese', code: 'as'),
  'av': (name: 'Avaric', code: 'av'),
  'ay': (name: 'Aymara', code: 'ay'),
  'az': (name: 'Azerbaijani', code: 'az'),
  'ba': (name: 'Bashkir', code: 'ba'),
  'be': (name: 'Belarusian', code: 'be'),
  'bg': (name: 'Bulgarian', code: 'bg'),
  'bh': (name: 'Bihari', code: 'bh'),
  'bi': (name: 'Bislama', code: 'bi'),
  'bm': (name: 'Bambara', code: 'bm'),
  'bn': (name: 'Bengali', code: 'bn'),
  'bo': (name: 'Tibetan', code: 'bo'),
  'br': (name: 'Breton', code: 'br'),
  'bs': (name: 'Bosnian', code: 'bs'),
  'ca': (name: 'Catalan', code: 'ca'),
  'ce': (name: 'Chechen', code: 'ce'),
  'co': (name: 'Corsican', code: 'co'),
  'cs': (name: 'Czech', code: 'cs'),
  'cy': (name: 'Welsh', code: 'cy'),
  'da': (name: 'Danish', code: 'da'),
  'de': (name: 'German', code: 'de'),
  'dv': (name: 'Dhivehi', code: 'dv'),
  'dz': (name: 'Dzongkha', code: 'dz'),
  'ee': (name: 'Ewe', code: 'ee'),
  'el': (name: 'Greek', code: 'el'),
  'en': (name: 'English', code: 'en'),
  'eo': (name: 'Esperanto', code: 'eo'),
  'es': (name: 'Spanish', code: 'es'),
  'et': (name: 'Estonian', code: 'et'),
  'eu': (name: 'Basque', code: 'eu'),
  'fa': (name: 'Persian', code: 'fa'),
  'ff': (name: 'Fulah', code: 'ff'),
  'fi': (name: 'Finnish', code: 'fi'),
  'fj': (name: 'Fijian', code: 'fj'),
  'fo': (name: 'Faroese', code: 'fo'),
  'fr': (name: 'French', code: 'fr'),
  'fy': (name: 'Frisian', code: 'fy'),
  'ga': (name: 'Irish', code: 'ga'),
  'gd': (name: 'Scottish Gaelic', code: 'gd'),
  'gl': (name: 'Galician', code: 'gl'),
  'gn': (name: 'Guarani', code: 'gn'),
  'gu': (name: 'Gujarati', code: 'gu'),
  'gv': (name: 'Manx', code: 'gv'),
  'ha': (name: 'Hausa', code: 'ha'),
  'he': (name: 'Hebrew', code: 'he'),
  'hi': (name: 'Hindi', code: 'hi'),
  'hr': (name: 'Croatian', code: 'hr'),
  'ht': (name: 'Haitian Creole', code: 'ht'),
  'hu': (name: 'Hungarian', code: 'hu'),
  'hy': (name: 'Armenian', code: 'hy'),
  'ia': (name: 'Interlingua', code: 'ia'),
  'id': (name: 'Indonesian', code: 'id'),
  'ig': (name: 'Igbo', code: 'ig'),
  'is': (name: 'Icelandic', code: 'is'),
  'it': (name: 'Italian', code: 'it'),
  'iu': (name: 'Inuktitut', code: 'iu'),
  'ja': (name: 'Japanese', code: 'ja'),
  'jv': (name: 'Javanese', code: 'jv'),
  'ka': (name: 'Georgian', code: 'ka'),
  'kk': (name: 'Kazakh', code: 'kk'),
  'kl': (name: 'Greenlandic', code: 'kl'),
  'km': (name: 'Khmer', code: 'km'),
  'kn': (name: 'Kannada', code: 'kn'),
  'ko': (name: 'Korean', code: 'ko'),
  'ks': (name: 'Kashmiri', code: 'ks'),
  'ku': (name: 'Kurdish', code: 'ku'),
  'ky': (name: 'Kyrgyz', code: 'ky'),
  'la': (name: 'Latin', code: 'la'),
  'lb': (name: 'Luxembourgish', code: 'lb'),
  'lg': (name: 'Ganda', code: 'lg'),
  'ln': (name: 'Lingala', code: 'ln'),
  'lo': (name: 'Lao', code: 'lo'),
  'lt': (name: 'Lithuanian', code: 'lt'),
  'lv': (name: 'Latvian', code: 'lv'),
  'mg': (name: 'Malagasy', code: 'mg'),
  'mi': (name: 'Maori', code: 'mi'),
  'mk': (name: 'Macedonian', code: 'mk'),
  'ml': (name: 'Malayalam', code: 'ml'),
  'mn': (name: 'Mongolian', code: 'mn'),
  'mr': (name: 'Marathi', code: 'mr'),
  'ms': (name: 'Malay', code: 'ms'),
  'mt': (name: 'Maltese', code: 'mt'),
  'my': (name: 'Burmese', code: 'my'),
  'nb': (name: 'Norwegian', code: 'nb'),
  'ne': (name: 'Nepali', code: 'ne'),
  'nl': (name: 'Dutch', code: 'nl'),
  'nn': (name: 'Norwegian', code: 'nn'),
  'no': (name: 'Norwegian', code: 'no'),
  'ny': (name: 'Chichewa', code: 'ny'),
  'oc': (name: 'Occitan', code: 'oc'),
  'om': (name: 'Oromo', code: 'om'),
  'or': (name: 'Odia', code: 'or'),
  'pa': (name: 'Punjabi', code: 'pa'),
  'pl': (name: 'Polish', code: 'pl'),
  'ps': (name: 'Pashto', code: 'ps'),
  'pt': (name: 'Portuguese', code: 'pt'),
  'qu': (name: 'Quechua', code: 'qu'),
  'rm': (name: 'Romansh', code: 'rm'),
  'rn': (name: 'Kirundi', code: 'rn'),
  'ro': (name: 'Romanian', code: 'ro'),
  'ru': (name: 'Russian', code: 'ru'),
  'rw': (name: 'Kinyarwanda', code: 'rw'),
  'sa': (name: 'Sanskrit', code: 'sa'),
  'sd': (name: 'Sindhi', code: 'sd'),
  'se': (name: 'Northern Sami', code: 'se'),
  'si': (name: 'Sinhala', code: 'si'),
  'sk': (name: 'Slovak', code: 'sk'),
  'sl': (name: 'Slovenian', code: 'sl'),
  'sm': (name: 'Samoan', code: 'sm'),
  'sn': (name: 'Shona', code: 'sn'),
  'so': (name: 'Somali', code: 'so'),
  'sq': (name: 'Albanian', code: 'sq'),
  'sr': (name: 'Serbian', code: 'sr'),
  'st': (name: 'Sesotho', code: 'st'),
  'su': (name: 'Sundanese', code: 'su'),
  'sv': (name: 'Swedish', code: 'sv'),
  'sw': (name: 'Swahili', code: 'sw'),
  'ta': (name: 'Tamil', code: 'ta'),
  'te': (name: 'Telugu', code: 'te'),
  'tg': (name: 'Tajik', code: 'tg'),
  'th': (name: 'Thai', code: 'th'),
  'ti': (name: 'Tigrinya', code: 'ti'),
  'tk': (name: 'Turkmen', code: 'tk'),
  'tl': (name: 'Filipino', code: 'tl'),
  'tn': (name: 'Tswana', code: 'tn'),
  'tr': (name: 'Turkish', code: 'tr'),
  'ts': (name: 'Tsonga', code: 'ts'),
  'tt': (name: 'Tatar', code: 'tt'),
  'ug': (name: 'Uyghur', code: 'ug'),
  'uk': (name: 'Ukrainian', code: 'uk'),
  'ur': (name: 'Urdu', code: 'ur'),
  'uz': (name: 'Uzbek', code: 'uz'),
  'vi': (name: 'Vietnamese', code: 'vi'),
  'wo': (name: 'Wolof', code: 'wo'),
  'xh': (name: 'Xhosa', code: 'xh'),
  'yi': (name: 'Yiddish', code: 'yi'),
  'yo': (name: 'Yoruba', code: 'yo'),
  'zh': (name: 'Chinese', code: 'zh'),
  'zu': (name: 'Zulu', code: 'zu'),
  'eng': (name: 'English', code: 'en'),
  'spa': (name: 'Spanish', code: 'es'),
  'ara': (name: 'Arabic', code: 'ar'),
  'fra': (name: 'French', code: 'fr'),
  'fre': (name: 'French', code: 'fr'),
  'deu': (name: 'German', code: 'de'),
  'ger': (name: 'German', code: 'de'),
  'ita': (name: 'Italian', code: 'it'),
  'por': (name: 'Portuguese', code: 'pt'),
  'rus': (name: 'Russian', code: 'ru'),
  'jpn': (name: 'Japanese', code: 'ja'),
  'kor': (name: 'Korean', code: 'ko'),
  'chi': (name: 'Chinese', code: 'zh'),
  'zho': (name: 'Chinese', code: 'zh'),
  'hin': (name: 'Hindi', code: 'hi'),
  'tur': (name: 'Turkish', code: 'tr'),
  'pol': (name: 'Polish', code: 'pl'),
  'nld': (name: 'Dutch', code: 'nl'),
  'dut': (name: 'Dutch', code: 'nl'),
  'swe': (name: 'Swedish', code: 'sv'),
  'nor': (name: 'Norwegian', code: 'no'),
  'nob': (name: 'Norwegian', code: 'no'),
  'dan': (name: 'Danish', code: 'da'),
  'fin': (name: 'Finnish', code: 'fi'),
  'ell': (name: 'Greek', code: 'el'),
  'gre': (name: 'Greek', code: 'el'),
  'heb': (name: 'Hebrew', code: 'he'),
  'ces': (name: 'Czech', code: 'cs'),
  'cze': (name: 'Czech', code: 'cs'),
  'hun': (name: 'Hungarian', code: 'hu'),
  'ron': (name: 'Romanian', code: 'ro'),
  'rum': (name: 'Romanian', code: 'ro'),
  'ukr': (name: 'Ukrainian', code: 'uk'),
  'vie': (name: 'Vietnamese', code: 'vi'),
  'ind': (name: 'Indonesian', code: 'id'),
  'tha': (name: 'Thai', code: 'th'),
  'per': (name: 'Persian', code: 'fa'),
  'fas': (name: 'Persian', code: 'fa'),
  'bul': (name: 'Bulgarian', code: 'bg'),
  'sqi': (name: 'Albanian', code: 'sq'),
  'alb': (name: 'Albanian', code: 'sq'),
  'hrv': (name: 'Croatian', code: 'hr'),
  'srp': (name: 'Serbian', code: 'sr'),
  'scc': (name: 'Serbian', code: 'sr'),
  'slk': (name: 'Slovak', code: 'sk'),
  'slo': (name: 'Slovak', code: 'sk'),
  'slv': (name: 'Slovenian', code: 'sl'),
  'msa': (name: 'Malay', code: 'ms'),
  'may': (name: 'Malay', code: 'ms'),
  'tgl': (name: 'Filipino', code: 'tl'),
  'fil': (name: 'Filipino', code: 'tl'),
  'ben': (name: 'Bengali', code: 'bn'),
  'bos': (name: 'Bosnian', code: 'bs'),
  'cat': (name: 'Catalan', code: 'ca'),
  'est': (name: 'Estonian', code: 'et'),
  'eus': (name: 'Basque', code: 'eu'),
  'baq': (name: 'Basque', code: 'eu'),
  'glg': (name: 'Galician', code: 'gl'),
  'isl': (name: 'Icelandic', code: 'is'),
  'ice': (name: 'Icelandic', code: 'is'),
  'kat': (name: 'Georgian', code: 'ka'),
  'geo': (name: 'Georgian', code: 'ka'),
  'lav': (name: 'Latvian', code: 'lv'),
  'lit': (name: 'Lithuanian', code: 'lt'),
  'mkd': (name: 'Macedonian', code: 'mk'),
  'mac': (name: 'Macedonian', code: 'mk'),
  'mal': (name: 'Malayalam', code: 'ml'),
  'mar': (name: 'Marathi', code: 'mr'),
  'mon': (name: 'Mongolian', code: 'mn'),
  'nep': (name: 'Nepali', code: 'ne'),
  'pan': (name: 'Punjabi', code: 'pa'),
  'sin': (name: 'Sinhala', code: 'si'),
  'som': (name: 'Somali', code: 'so'),
  'swa': (name: 'Swahili', code: 'sw'),
  'tam': (name: 'Tamil', code: 'ta'),
  'tel': (name: 'Telugu', code: 'te'),
  'urd': (name: 'Urdu', code: 'ur'),
  'uzb': (name: 'Uzbek', code: 'uz'),
  'kaz': (name: 'Kazakh', code: 'kk'),
  'khm': (name: 'Khmer', code: 'km'),
  'lao': (name: 'Lao', code: 'lo'),
  'mya': (name: 'Burmese', code: 'my'),
  'bur': (name: 'Burmese', code: 'my'),
  'amh': (name: 'Amharic', code: 'am'),
  'aze': (name: 'Azerbaijani', code: 'az'),
  'bel': (name: 'Belarusian', code: 'be'),
  'hye': (name: 'Armenian', code: 'hy'),
  'arm': (name: 'Armenian', code: 'hy'),
  'kur': (name: 'Kurdish', code: 'ku'),
  'afr': (name: 'Afrikaans', code: 'af'),
  'cym': (name: 'Welsh', code: 'cy'),
  'wel': (name: 'Welsh', code: 'cy'),
  'gle': (name: 'Irish', code: 'ga'),
  'kan': (name: 'Kannada', code: 'kn'),
  'guj': (name: 'Gujarati', code: 'gu'),
  'ori': (name: 'Odia', code: 'or'),
  'pus': (name: 'Pashto', code: 'ps'),
  'tat': (name: 'Tatar', code: 'tt'),
  'tgk': (name: 'Tajik', code: 'tg'),
  'tuk': (name: 'Turkmen', code: 'tk'),
  'yid': (name: 'Yiddish', code: 'yi'),
  'yor': (name: 'Yoruba', code: 'yo'),
  'zul': (name: 'Zulu', code: 'zu'),
  'xho': (name: 'Xhosa', code: 'xh'),
  'ibo': (name: 'Igbo', code: 'ig'),
  'hau': (name: 'Hausa', code: 'ha'),
  'es-la': (name: 'Spanish (Latin America)', code: 'es-la'),
  'es-419': (name: 'Spanish (Latin America)', code: 'es-la'),
  'es-mx': (name: 'Spanish (Latin America)', code: 'es-la'),
  'latino': (name: 'Spanish (Latin America)', code: 'es-la'),
  'es-es': (name: 'Spanish (Spain)', code: 'es-es'),
  'pob': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'pt-br': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'pb': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'brazilian': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'portuguese (brazil)': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'brazilian portuguese': (name: 'Portuguese (Brazil)', code: 'pt-br'),
  'zh-cn': (name: 'Chinese (Simplified)', code: 'zh-cn'),
  'zh-hans': (name: 'Chinese (Simplified)', code: 'zh-cn'),
  'chs': (name: 'Chinese (Simplified)', code: 'zh-cn'),
  'zh-tw': (name: 'Chinese (Traditional)', code: 'zh-tw'),
  'zh-hant': (name: 'Chinese (Traditional)', code: 'zh-tw'),
  'cht': (name: 'Chinese (Traditional)', code: 'zh-tw'),
  'zht': (name: 'Chinese (Traditional)', code: 'zh-tw'),
  'ze': (name: 'Chinese', code: 'zh'),
  'iw': (name: 'Hebrew', code: 'he'),
  'farsi': (name: 'Persian', code: 'fa'),
  'farsi/persian': (name: 'Persian', code: 'fa'),
};

_Lang _normLang(String input) {
  final clean = input.toLowerCase().trim();
  final hit = _langMap[clean];
  if (hit != null) return hit;
  for (final v in _langMap.values) {
    final n = v.name.toLowerCase();
    if (clean.isNotEmpty && (n == clean || n.startsWith(clean))) return v;
  }
  if (clean.isEmpty) return (name: 'Unknown', code: 'und');
  final head = clean.split(RegExp(r'[\s_(,-]')).first;
  if (head != clean && _langMap[head] != null) return _langMap[head]!;
  if (clean.length <= 3) return (name: 'Other (${clean.toUpperCase()})', code: clean);
  return (name: '${clean[0].toUpperCase()}${clean.substring(1)}', code: 'und');
}

/// Full name for a language code or name (`eng`, `es-419`, `Arabic`).
String languageName(String codeOrName) => _normLang(codeOrName).name;

/// The language a single word names exactly ("en", "eng", "English"), or null: for reading a
/// language out of a subtitle file's name.
String? exactLanguage(String word) {
  final c = word.toLowerCase().trim();
  if (c.length < 2) return null;
  final hit = _langMap[c];
  if (hit != null) return hit.code;
  for (final v in _langMap.values) {
    if (v.name.toLowerCase() == c) return v.code;
  }
  return null;
}
