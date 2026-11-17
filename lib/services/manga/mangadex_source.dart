import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';

/// Lorewatch: MangaDex (api.mangadex.org), a second manga library next to WeebCentral, with
/// chapters in many languages (Italian among them). Its series ids are kept as
/// `md:<language>:<uuid>` and its chapter ids as `md:<uuid>`, so the rest of the app can tell
/// them apart from WeebCentral's and knows which language to list chapters in.
class MangaDexSource {
  static const _api = 'https://api.mangadex.org';
  static const _covers = 'https://uploads.mangadex.org/covers';
  static const _pageSize = 32;
  static const _ratings = ['safe', 'suggestive'];
  static const _allRatings = ['safe', 'suggestive', 'erotica', 'pornographic'];

  final http.Client _client = http.Client();
  Map<String, String>? _tagIds; // English tag name (lower case) -> MangaDex tag id

  static bool owns(String id) => id.startsWith('md:');

  /// The language a `md:<language>:<uuid>` series id lists its chapters in.
  static String languageOf(String id) {
    final parts = id.split(':');
    return parts.length >= 3 ? parts[1] : 'en';
  }

  static String _uuid(String id) => id.split(':').last;

  Future<Map<String, dynamic>> _get(String path, Map<String, Object> query) async {
    final params = <String>[];
    query.forEach((k, v) {
      if (v is List) {
        for (final x in v) {
          params.add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent('$x')}');
        }
      } else {
        params.add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent('$v')}');
      }
    });
    final url = Uri.parse('$_api$path${params.isEmpty ? '' : '?${params.join('&')}'}');
    final r = await _client
        .get(url, headers: const {'User-Agent': 'Lorewatch/1.0 (manga reader)', 'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('MangaDex: HTTP ${r.statusCode}');
    return json.decode(r.body) as Map<String, dynamic>;
  }

  Future<String?> _tagId(String name) async {
    if (_tagIds == null) {
      final d = await _get('/manga/tag', const {});
      _tagIds = {
        for (final t in (d['data'] as List? ?? const []).whereType<Map>())
          '${((t['attributes'] as Map?)?['name'] as Map?)?['en'] ?? ''}'.toLowerCase(): '${t['id']}',
      };
    }
    return _tagIds![name.toLowerCase()];
  }

  /// Popular series with chapters in [lang] (optionally only those tagged [tag]).
  Future<List<Manga>> browse(String lang, {int page = 1, String? tag, bool allowAdult = false}) async {
    final q = <String, Object>{
      'limit': _pageSize,
      'offset': (page - 1) * _pageSize,
      'includes[]': ['cover_art', 'author'],
      'availableTranslatedLanguage[]': [lang],
      'hasAvailableChapters': 'true',
      'contentRating[]': allowAdult ? _allRatings : _ratings,
      'order[followedCount]': 'desc',
    };
    if (tag != null) {
      final id = await _tagId(tag);
      if (id == null) return const []; // a genre MangaDex doesn't have
      q['includedTags[]'] = [id];
    }
    return _list(await _get('/manga', q), lang);
  }

  /// Series whose title matches [text], with chapters in [lang].
  Future<List<Manga>> search(String lang, String text, {int page = 1, bool allowAdult = false}) async {
    final d = await _get('/manga', {
      'title': text,
      'limit': _pageSize,
      'offset': (page - 1) * _pageSize,
      'includes[]': ['cover_art', 'author'],
      'availableTranslatedLanguage[]': [lang],
      'hasAvailableChapters': 'true',
      'contentRating[]': allowAdult ? _allRatings : _ratings,
      'order[relevance]': 'desc',
    });
    return _list(d, lang);
  }

  List<Manga> _list(Map<String, dynamic> d, String lang) => [
    for (final m in (d['data'] as List? ?? const []).whereType<Map>()) ?_manga(m, lang),
  ];

  Manga? _manga(Map m, String lang) {
    final id = '${m['id'] ?? ''}';
    final a = m['attributes'];
    if (id.isEmpty || a is! Map) return null;
    String pick(Object? names) {
      if (names is! Map || names.isEmpty) return '';
      return '${names[lang] ?? names['en'] ?? names['ja-ro'] ?? names.values.first}';
    }

    var title = '';
    for (final alt in (a['altTitles'] as List? ?? const []).whereType<Map>()) {
      if (alt[lang] != null) {
        title = '${alt[lang]}';
        break;
      }
    }
    if (title.isEmpty) title = pick(a['title']);
    String? cover, author;
    for (final r in (m['relationships'] as List? ?? const []).whereType<Map>()) {
      final ra = r['attributes'];
      if (ra is! Map) continue;
      if (r['type'] == 'cover_art' && ra['fileName'] != null) cover = '$_covers/$id/${ra['fileName']}';
      if (r['type'] == 'author' && ra['name'] != null) author = author == null ? '${ra['name']}' : '$author, ${ra['name']}';
    }
    final tags = [
      for (final t in (a['tags'] as List? ?? const []).whereType<Map>())
        if (((t['attributes'] as Map?)?['name'] as Map?)?['en'] != null) '${((t['attributes'] as Map)['name'] as Map)['en']}',
    ];
    final status = '${a['status'] ?? ''}';
    final synopsis = pick(a['description']).trim();
    return Manga(
      id: 'md:$lang:$id',
      title: title.isEmpty ? '?' : title,
      coverSmall: cover == null ? null : '$cover.256.jpg',
      coverNormal: cover == null ? null : '$cover.512.jpg',
      type: a['publicationDemographic'] == null ? 'Manga' : '${a['publicationDemographic']}'.replaceFirstMapped(RegExp('^.'), (x) => x[0]!.toUpperCase()),
      status: status.isEmpty ? null : status.replaceFirstMapped(RegExp('^.'), (x) => x[0]!.toUpperCase()),
      year: a['year'] == null ? null : '${a['year']}',
      author: author,
      tags: tags,
      synopsis: synopsis.isEmpty ? null : synopsis,
      url: 'https://mangadex.org/title/$id',
    );
  }

  /// Every chapter of series [seriesId] in its language, oldest first, one per chapter number
  /// (the first group's when several translated the same one). Chapters hosted elsewhere
  /// (official sites MangaDex only links to) are left out: they have no pages here.
  Future<List<MangaChapter>> chapters(String seriesId) async {
    final lang = languageOf(seriesId), uuid = _uuid(seriesId);
    final out = <MangaChapter>[];
    final seen = <String>{};
    for (var offset = 0; offset < 10000; offset += 500) {
      final d = await _get('/manga/$uuid/feed', {
        'translatedLanguage[]': [lang],
        'limit': 500,
        'offset': offset,
        'order[volume]': 'asc',
        'order[chapter]': 'asc',
        'includeExternalUrl': '0',
        'includeEmptyPages': '0',
        'includeFuturePublishAt': '0',
        'contentRating[]': _allRatings,
      });
      final data = (d['data'] as List? ?? const []).whereType<Map>().toList();
      for (final c in data) {
        final a = c['attributes'];
        if (a is! Map) continue;
        final num = '${a['chapter'] ?? ''}';
        final key = num.isEmpty ? 'id:${c['id']}' : num;
        if (!seen.add(key)) continue;
        final title = '${a['title'] ?? ''}'.trim();
        final raw = [
          num.isEmpty ? 'Oneshot' : 'Capitolo $num',
          if (title.isNotEmpty) title,
        ].join(' - ');
        out.add(MangaChapter(
          id: 'md:${c['id']}',
          number: double.tryParse(num),
          name: title.isEmpty ? null : title,
          url: 'https://mangadex.org/chapter/${c['id']}',
          rawName: raw,
        ));
      }
      final total = (d['total'] as num?)?.toInt() ?? 0;
      if (data.length < 500 || offset + 500 >= total) break;
    }
    return out;
  }

  /// The page images of chapter [chapterId], in order, from MangaDex's image servers.
  Future<List<String>> pages(String chapterId) async {
    try {
      final d = await _get('/at-home/server/${_uuid(chapterId)}', const {});
      final base = '${d['baseUrl'] ?? ''}';
      final ch = d['chapter'];
      if (base.isEmpty || ch is! Map) return const [];
      final hash = '${ch['hash']}';
      return [for (final f in (ch['data'] as List? ?? const [])) '$base/data/$hash/$f'];
    } catch (e) {
      debugPrint('[MangaDex] pages: $e');
      return const [];
    }
  }
}
