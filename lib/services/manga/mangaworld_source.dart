import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';

/// Lorewatch: MangaWorld (mangaworld.mx), Italian scanlations. Read from its web pages, the way
/// the Mihon extension does it (keiyoushi/extensions-source, multisrc/mangaworld). Series ids
/// are kept as `mw:<path>` and chapter ids as `mw:<path of the reader page>`.
class MangaWorldSource {
  /// The site moves to a new domain from time to time; this is the one in use.
  static const base = 'https://www.mangaworld.mx';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
  static final _cookieRe = RegExp(r'document\.cookie="(MWCookie[^"]+)"');

  final http.Client _client = http.Client();
  String? _cookie; // the MWCookie the site asks for before showing its pages

  static bool owns(String id) => id.startsWith('mw:');
  static String _path(String id) => id.substring(3);

  /// The genre chips on the Manga page are in English; these are MangaWorld's names for them.
  static const _genres = {
    'action': 'azione',
    'adventure': 'avventura',
    'comedy': 'commedia',
    'drama': 'drammatico',
    'ecchi': 'ecchi',
    'fantasy': 'fantasy',
    'gender bender': 'gender-bender',
    'harem': 'harem',
    'historical': 'storico',
    'horror': 'horror',
    'josei': 'josei',
    'martial arts': 'arti-marziali',
    'mature': 'maturo',
    'mecha': 'mecha',
    'mystery': 'mistero',
    'psychological': 'psicologico',
    'romance': 'romantico',
    'school life': 'scolastico',
    'sci-fi': 'sci-fi',
    'seinen': 'seinen',
    'shoujo': 'shoujo',
    'shoujo ai': 'shoujo-ai',
    'shounen': 'shounen',
    'shounen ai': 'shounen-ai',
    'slice of life': 'slice-of-life',
    'smut': 'smut',
    'sports': 'sport',
    'supernatural': 'soprannaturale',
    'tragedy': 'tragico',
    'yaoi': 'yaoi',
    'yuri': 'yuri',
    'doujinshi': 'doujinshi',
  };

  /// Gets a page. When the site answers with its cookie check instead, sets the cookie it asks
  /// for and asks again.
  Future<String> _get(String url) async {
    Future<http.Response> fetch() => _client
        .get(Uri.parse(url), headers: {
          'User-Agent': _ua,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'it-IT,it;q=0.9',
          if (_cookie != null) 'Cookie': _cookie!,
        })
        .timeout(const Duration(seconds: 20));
    var r = await fetch();
    final m = _cookieRe.firstMatch(r.body);
    if (m != null) {
      _cookie = m.group(1)!.split(';').first.trim();
      r = await fetch();
    }
    if (r.statusCode != 200) throw Exception('MangaWorld: HTTP ${r.statusCode}');
    return r.body;
  }

  String _abs(String href) {
    if (href.startsWith('http')) return href;
    if (href.startsWith('//')) return 'https:$href';
    return '$base${href.startsWith('/') ? '' : '/'}$href';
  }

  String _pathOf(String href) {
    final u = Uri.parse(_abs(href));
    return '${u.path}${u.hasQuery ? '?${u.query}' : ''}';
  }

  /// The most read series (or those in genre [tag]), 16 a page.
  Future<List<Manga>> browse({int page = 1, String? tag}) async {
    final q = <String>['sort=most_read', 'page=$page'];
    if (tag != null) {
      final g = _genres[tag.toLowerCase()];
      if (g == null) return const []; // a genre MangaWorld doesn't have
      q.add('genre=$g');
    }
    return _grid(await _get('$base/archive?${q.join('&')}'));
  }

  Future<List<Manga>> search(String text, {int page = 1}) async =>
      _grid(await _get('$base/archive?keyword=${Uri.encodeQueryComponent(text)}&page=$page'));

  List<Manga> _grid(String html) {
    final doc = html_parser.parse(html);
    final out = <Manga>[];
    for (final e in doc.querySelectorAll('div.comics-grid .entry')) {
      final a = e.querySelector('a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      var path = _pathOf(href);
      if (path.endsWith('/')) path = path.substring(0, path.length - 1);
      final img = e.querySelector('a.thumb img')?.attributes['src'];
      final title = (a.attributes['title'] ?? e.querySelector('.name')?.text ?? '').trim();
      out.add(Manga(
        id: 'mw:$path',
        title: title.isEmpty ? '?' : title,
        coverSmall: img == null ? null : _abs(img),
        coverNormal: img == null ? null : _abs(img),
        type: 'Manga',
        url: '$base$path',
      ));
    }
    return out;
  }

  /// The chapters of series [seriesId], as its page lists them.
  Future<List<MangaChapter>> chapters(String seriesId) async {
    final doc = html_parser.parse(await _get('$base${_path(seriesId)}'));
    final out = <MangaChapter>[];
    for (final c in doc.querySelectorAll('.chapters-wrapper .chapter')) {
      final a = c.querySelector('a.chap');
      final href = a?.attributes['href'];
      if (href == null || href.isEmpty) continue;
      var path = _pathOf(href);
      // the reader's "list" style shows every page of the chapter at once
      if (path.contains('style=pages')) {
        path = path.replaceAll('style=pages', 'style=list');
      } else if (!path.contains('style=list')) {
        path += path.contains('?') ? '&style=list' : '?style=list';
      }
      final name = (c.querySelector('span.d-inline-block')?.text ?? a!.text).trim();
      final n = RegExp(r'capitolo\s([0-9]+(?:\.[0-9]+)?)', caseSensitive: false).firstMatch(name);
      out.add(MangaChapter(
        id: 'mw:$path',
        number: n == null ? null : double.tryParse(n.group(1)!),
        name: null,
        url: '$base$path',
        rawName: name,
      ));
    }
    return out;
  }

  /// The page images of chapter [chapterId], in order.
  Future<List<String>> pages(String chapterId) async {
    try {
      final doc = html_parser.parse(await _get('$base${_path(chapterId)}'));
      return [
        for (final img in doc.querySelectorAll('div#page img.page-image'))
          if ((img.attributes['src'] ?? '').isNotEmpty) _abs(img.attributes['src']!),
      ];
    } catch (e) {
      debugPrint('[MangaWorld] pages: $e');
      return const [];
    }
  }
}
