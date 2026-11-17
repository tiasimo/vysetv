import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';

/// Lorewatch: MangaRead.org (English), a WordPress "Madara" site. Read the way the Mihon
/// extension does it (keiyoushi/extensions-source, multisrc/madara + en/mangareadorg): the
/// archive and search through admin-ajax.php, chapters through `<manga>/ajax/chapters/`, pages
/// from the chapter page. Series ids are `mr:<path>` and chapter ids `mr:<path>`.
class MangaReadSource {
  static const base = 'https://www.mangaread.org';
  static const _pageSize = 25;
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

  final http.Client _client = http.Client();

  static bool owns(String id) => id.startsWith('mr:');
  static String _path(String id) => id.substring(3);

  Map<String, String> get _headers => const {'User-Agent': _ua, 'Referer': '$base/'};

  /// The most viewed series (or those in genre [tag]).
  Future<List<Manga>> browse({int page = 1, String? tag}) => _archive(page, {
        'vars[orderby]': 'meta_value_num',
        'vars[meta_key]': '_wp_manga_views',
        'vars[order]': 'DESC',
        if (tag != null) ...{
          'vars[tax_query][0][taxonomy]': 'wp-manga-genre',
          'vars[tax_query][0][field]': 'slug',
          'vars[tax_query][0][terms][0]': tag.toLowerCase().replaceAll(' ', '-'),
        },
      });

  Future<List<Manga>> search(String text, {int page = 1}) => _archive(page, {'vars[s]': text});

  Future<List<Manga>> _archive(int page, Map<String, String> extra) async {
    final body = {
      'action': 'madara_load_more',
      'page': '${page - 1}',
      'template': 'madara-core/content/content-archive',
      'vars[paged]': '1',
      'vars[template]': 'archive',
      'vars[posts_per_page]': '$_pageSize',
      'vars[post_type]': 'wp-manga',
      'vars[post_status]': 'publish',
      'vars[manga_archives_item_layout]': 'big_thumbnail',
      ...extra,
    };
    final r = await _client
        .post(Uri.parse('$base/wp-admin/admin-ajax.php'), headers: {..._headers, 'X-Requested-With': 'XMLHttpRequest'}, body: body)
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('MangaRead: HTTP ${r.statusCode}');
    final doc = html_parser.parse(r.body);
    final out = <Manga>[];
    for (final e in doc.querySelectorAll('div.page-item-detail, .manga__item, .c-tabs-item__content')) {
      final a = e.querySelector('.post-title a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final path = Uri.parse(href).path;
      final img = e.querySelector('img');
      final cover = img == null ? null : _image(img);
      out.add(Manga(
        id: 'mr:$path',
        title: a.text.trim(),
        coverSmall: cover,
        coverNormal: cover,
        type: 'Manga',
        url: '$base$path',
      ));
    }
    return out;
  }

  /// The chapters of series [seriesId].
  Future<List<MangaChapter>> chapters(String seriesId) async {
    final path = _path(seriesId);
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final r = await _client
        .post(Uri.parse('$base$trimmed/ajax/chapters/'), headers: {..._headers, 'X-Requested-With': 'XMLHttpRequest', 'Referer': '$base$path'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('MangaRead: HTTP ${r.statusCode}');
    final doc = html_parser.parse(r.body);
    final out = <MangaChapter>[];
    for (final li in doc.querySelectorAll('li.wp-manga-chapter')) {
      final a = li.querySelector('a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final name = a.text.trim();
      final n = RegExp(r'chapter\s*([0-9]+(?:\.[0-9]+)?)', caseSensitive: false).firstMatch(name);
      final cpath = Uri.parse(href).path;
      out.add(MangaChapter(
        id: 'mr:$cpath',
        number: n == null ? null : double.tryParse(n.group(1)!),
        name: null,
        url: '$base$cpath',
        rawName: name,
      ));
    }
    return out;
  }

  /// The page images of chapter [chapterId], in order.
  Future<List<String>> pages(String chapterId) async {
    try {
      final url = '$base${_path(chapterId)}';
      var doc = html_parser.parse((await _client.get(Uri.parse(url), headers: _headers).timeout(const Duration(seconds: 20))).body);
      if (doc.querySelector('#single-pager') != null) {
        final list = '$url${url.contains('?') ? '&' : '?'}style=list';
        doc = html_parser.parse((await _client.get(Uri.parse(list), headers: _headers).timeout(const Duration(seconds: 20))).body);
      }
      return [
        for (final e in doc.querySelectorAll('div.page-break, li.blocks-gallery-item, .reading-content .text-left'))
          if (e.querySelector('img') case final img?)
            if (_image(img) case final src?) src,
      ];
    } catch (e) {
      debugPrint('[MangaRead] pages: $e');
      return const [];
    }
  }

  static String? _image(dom.Element img) {
    String? pick(String a) {
      final v = img.attributes[a]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    var src = pick('data-src') ?? pick('data-lazy-src') ?? pick('data-lzl-src') ?? pick('data-cfsrc');
    if (src == null) {
      final set = pick('srcset');
      if (set != null) src = set.split(',').last.trim().split(' ').first;
    }
    src ??= pick('src');
    if (src == null) return null;
    if (src.startsWith('//')) return 'https:$src';
    if (src.startsWith('/')) return '$base$src';
    return src;
  }
}
