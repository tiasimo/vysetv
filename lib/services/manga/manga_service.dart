import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/manga/manga.dart';
import '../../models/manga/manga_chapter.dart';
import '../../data/app_settings.dart';
import 'mangadex_source.dart';
import 'mangaworld_source.dart';
import 'mangaread_source.dart';

const String _baseUrl = 'https://weebcentral.com';
const String _coverCdn = 'https://temp.compsci88.com/cover';

/// Lorewatch: the manga libraries to choose from on the Manga page. 'weebcentral' is the
/// original one (English); 'mangadex:<language>' is MangaDex with chapters in that language.
class MangaLibraryChoice {
  const MangaLibraryChoice(this.id, this.label);
  final String id;
  final String label;

  static const all = [
    MangaLibraryChoice('mangaworld', 'MangaWorld · Italiano'),
    MangaLibraryChoice('weebcentral', 'WeebCentral · Inglese'),
    MangaLibraryChoice('mangaread', 'MangaRead · Inglese'),
  ];

  static MangaLibraryChoice get current =>
      all.firstWhere((c) => c.id == AppSettings.mangaLibrary.value, orElse: () => all.first);
}

class MangaService {
  final MangaDexSource _dex = MangaDexSource();
  final MangaWorldSource _world = MangaWorldSource();
  final MangaReadSource _read = MangaReadSource();

  static bool get _readPicked => MangaLibraryChoice.current.id == 'mangaread';

  static bool get _worldPicked => MangaLibraryChoice.current.id == 'mangaworld';

  /// The language of the MangaDex library picked, or null for WeebCentral.
  static String? get _dexLang {
    final id = MangaLibraryChoice.current.id;
    return id.startsWith('mangadex:') ? id.substring(9) : null;
  }

  static const String _likedKey = 'liked_manga';
  static const String _historyKey = 'manga_reading_history';
  static const int _pageSize = 32;
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  final http.Client _client = http.Client();

  static final ValueNotifier<int> readingHistoryRevision = ValueNotifier<int>(0);

  Map<String, String> get _headers => {
        'User-Agent': _userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      };

  Future<String> _fetchHtml(String url) async {
    final response = await _client.get(Uri.parse(url), headers: _headers);
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} for $url');
    }
    return response.body;
  }

  String? _extractSeriesId(String url) {
    final match = RegExp(r'/series/([A-Z0-9]{26})').firstMatch(url);
    return match?.group(1);
  }

  String? _extractChapterId(String url) {
    final match = RegExp(r'/chapters/([A-Z0-9]{26})').firstMatch(url);
    return match?.group(1);
  }

  Future<List<Manga>> getManga({int page = 1, String? tag, bool allowAdult = false}) async {
    if (_worldPicked) return _world.browse(page: page, tag: tag);
    if (_readPicked) return _read.browse(page: page, tag: tag);
    final lang = _dexLang;
    if (lang != null) return _dex.browse(lang, page: page, tag: tag, allowAdult: allowAdult);
    try {
      final offset = (page - 1) * _pageSize;
      final adult = allowAdult ? 'Any' : 'False';
      var url =
          '$_baseUrl/search/data?text=&display_mode=Full+Display&sort=Popularity&order=Descending&official=Any&adult=$adult&offset=$offset';
      if (tag != null) {
        url += '&included_tag=${Uri.encodeComponent(tag)}';
      }
      debugPrint('[MangaService] Fetching page $page: $url');
      final html = await _fetchHtml(url);
      return _parseSearchResults(html);
    } catch (e) {
      debugPrint('[MangaService] Error fetching manga: $e');
      return [];
    }
  }

  Future<List<Manga>> searchManga(String query, {int page = 1, bool allowAdult = false}) async {
    if (_worldPicked) return _world.search(query, page: page);
    if (_readPicked) return _read.search(query, page: page);
    final lang = _dexLang;
    if (lang != null) return _dex.search(lang, query, page: page, allowAdult: allowAdult);
    try {
      final offset = (page - 1) * _pageSize;
      final adult = allowAdult ? 'Any' : 'False';
      final encodedQuery = Uri.encodeComponent(query);
      final url =
          '$_baseUrl/search/data?text=$encodedQuery&display_mode=Full+Display&sort=Best+Match&order=Descending&official=Any&adult=$adult&offset=$offset';
      debugPrint('[MangaService] Searching page $page: $url');
      final html = await _fetchHtml(url);
      return _parseSearchResults(html);
    } catch (e) {
      debugPrint('[MangaService] Error searching manga: $e');
      return [];
    }
  }

  static const List<String> popularGenres = [
    'All',
    'Action',
    'Adventure',
    'Comedy',
    'Drama',
    'Ecchi',
    'Fantasy',
    'Harem',
    'Historical',
    'Horror',
    'Isekai',
    'Martial Arts',
    'Mature',
    'Mystery',
    'Psychological',
    'Romance',
    'School Life',
    'Sci-fi',
    'Seinen',
    'Shounen',
    'Slice of Life',
    'Sports',
    'Supernatural',
    'Tragedy',
  ];

  List<Manga> _parseSearchResults(String html) {
    final doc = html_parser.parse(html);
    final articles = doc.querySelectorAll('article');
    final results = <Manga>[];

    for (final article in articles) {
      final seriesLink = article.querySelector('a[href*="/series/"]');
      if (seriesLink == null) continue;

      final href = seriesLink.attributes['href'] ?? '';
      final seriesId = _extractSeriesId(href);
      if (seriesId == null) continue;

      String title = '';

      final titleLink = article.querySelector('a.line-clamp-1, a.link-hover');
      if (titleLink != null && titleLink.text.trim().isNotEmpty) {
        title = titleLink.text.trim();
      }

      if (title.isEmpty) {
        final img = article.querySelector('img');
        final alt = img?.attributes['alt'] ?? '';
        if (alt.toLowerCase().endsWith(' cover')) {
          title = alt.substring(0, alt.length - 6).trim();
        } else if (alt.isNotEmpty) {
          title = alt.trim();
        }
      }

      if (title.isEmpty) {
        title = seriesLink.text.trim().split('\n').first.trim();
      }

      title = title.replaceAll(RegExp(r'^Official\s+', caseSensitive: false), '').trim();

      String type = '';
      for (final el in article.querySelectorAll('[data-tip]')) {
        final tip = el.attributes['data-tip'] ?? '';
        if (['Manga', 'Manhwa', 'Manhua', 'OEL'].contains(tip)) {
          type = tip;
          break;
        }
      }

      String year = '';
      String status = '';
      String author = '';
      List<String> tags = [];

      for (final div in article.querySelectorAll('div, li')) {
        final strong = div.querySelector('strong, b, span.font-bold, span.font-semibold');
        if (strong == null) continue;
        final label = strong.text.trim().toLowerCase();

        if (label.contains('tag') || label.contains('genre')) {
          final spans = div.querySelectorAll('span');
          final extracted = <String>[];
          for (final sp in spans) {
            final text = sp.text.replaceAll(',', '').trim();
            if (text.isNotEmpty && !text.toLowerCase().contains('tag') && !text.toLowerCase().contains('genre')) {
              extracted.add(text);
            }
          }
          if (extracted.isNotEmpty) {
            tags = extracted;
          }
        } else if (label.contains('year') || label.contains('date')) {
          final span = div.querySelector('span');
          if (span != null) {
            year = span.text.trim();
          }
        } else if (label.contains('status')) {
          final span = div.querySelector('span');
          if (span != null) {
            status = span.text.trim();
          }
        } else if (label.contains('author')) {
          final links = div.querySelectorAll('a');
          if (links.isNotEmpty) {
            author = links.map((a) => a.text.trim()).where((t) => t.isNotEmpty).join(', ');
          } else {
            final span = div.querySelector('span');
            if (span != null) author = span.text.trim();
          }
        }
      }

      results.add(Manga(
        id: seriesId,
        title: title,
        coverSmall: '$_coverCdn/small/$seriesId.webp',
        coverNormal: '$_coverCdn/normal/$seriesId.webp',
        type: type,
        status: status,
        year: year,
        author: author,
        tags: tags,
        url: href,
      ));
    }

    return results;
  }

  Future<Manga> getSeriesDetail(String seriesId) async {
    final html = await _fetchHtml('$_baseUrl/series/$seriesId');
    final doc = html_parser.parse(html);

    String title = doc.querySelector('h1')?.text.trim() ?? '';
    title = title.replaceAll(RegExp(r'^Official\s+', caseSensitive: false), '').trim();
    if (title.isEmpty) {
      final ogTitle = doc.querySelector('meta[property="og:title"]')?.attributes['content'] ?? '';
      title = ogTitle.replaceAll(RegExp(r'\s*-\s*Weeb\s*Central.*$', caseSensitive: false), '').trim();
    }

    final sidebar = doc.querySelector('section.md\\:w-4\\/12') ?? doc.querySelector('section');
    final details = <String, List<String>>{};
    final items = sidebar != null
        ? sidebar.querySelectorAll('li, div.flex, div.grid')
        : doc.querySelectorAll('li');

    for (final element in items) {
      final strong = element.querySelector('strong, b, span.font-bold, span.font-semibold');
      if (strong == null) continue;
      final label = strong.text.trim().replaceAll(':', '').replaceAll('(s)', '').trim();
      if (label.isEmpty) continue;

      final links = element.querySelectorAll('a');
      List<String> values = [];
      if (links.isNotEmpty) {
        values = links
            .map((a) => a.text.trim())
            .where((t) => t.isNotEmpty && t != strong.text.trim() && !t.contains('RSS'))
            .toList();
      } else {
        String rawText = element.text.trim();
        if (rawText.startsWith(strong.text.trim())) {
          rawText = rawText.substring(strong.text.trim().length).trim();
        }
        rawText = rawText.replaceAll(RegExp(r'^\s*:\s*'), '').trim();
        if (rawText.isNotEmpty) {
          values = [rawText];
        }
      }

      if (values.isNotEmpty && !details.containsKey(label)) {
        details[label] = values;
      }
    }

    String year = '';
    final possibleYearKeys = ['Released', 'Release Year', 'Year', 'Published', 'Date', 'Release'];
    for (final key in possibleYearKeys) {
      if (details.containsKey(key) && details[key]!.isNotEmpty) {
        final rawVal = details[key]!.first;
        final yearMatch = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(rawVal);
        if (yearMatch != null) {
          year = yearMatch.group(1)!;
          break;
        } else if (rawVal.isNotEmpty) {
          year = rawVal;
          break;
        }
      }
    }

    if (year.isEmpty) {
      final yearMatch = RegExp(r'\b(19\d\d|20\d\d)\b').firstMatch(html);
      if (yearMatch != null) {
        year = yearMatch.group(1)!;
      }
    }

    String synopsis = doc.querySelector('p.whitespace-pre-wrap, .whitespace-pre-wrap')?.text.trim() ?? '';
    if (synopsis.isEmpty) {
      for (final p in doc.querySelectorAll('p')) {
        final text = p.text.trim();
        if (text.length > 30 &&
            !text.contains('Copyright') &&
            !text.contains('verified') &&
            !text.contains('Last Read') &&
            !text.contains('Chapter') &&
            !text.contains('emoji')) {
          synopsis = text;
          break;
        }
      }
    }

    List<String> tags = [];
    for (final entry in details.entries) {
      final k = entry.key.toLowerCase();
      if (k.contains('tag') || k.contains('genre')) {
        tags.addAll(entry.value);
      }
    }
    if (tags.isEmpty) {
      tags = details['Tag'] ?? details['Tags'] ?? details['Genres'] ?? [];
    }

    return Manga(
      id: seriesId,
      title: title,
      coverSmall: '$_coverCdn/small/$seriesId.webp',
      coverNormal: '$_coverCdn/normal/$seriesId.webp',
      type: (details['Type']?.isNotEmpty ?? false) ? details['Type']!.first : '',
      status: (details['Status']?.isNotEmpty ?? false) ? details['Status']!.first : '',
      year: year,
      author: (details['Author'] ?? details['Author(s)'] ?? []).join(', '),
      tags: tags,
      synopsis: synopsis,
      url: '/series/$seriesId',
    );
  }

  Future<List<MangaChapter>> getChapters(String seriesId) async {
    if (MangaDexSource.owns(seriesId)) return _dex.chapters(seriesId);
    if (MangaWorldSource.owns(seriesId)) return _world.chapters(seriesId);
    if (MangaReadSource.owns(seriesId)) return _read.chapters(seriesId);
    try {
      final html =
          await _fetchHtml('$_baseUrl/series/$seriesId/full-chapter-list');
      final doc = html_parser.parse(html);

      final chapters = <MangaChapter>[];
      final links = doc.querySelectorAll('a[href*="/chapters/"]');

      for (final a in links) {
        final href = a.attributes['href'] ?? '';
        final chapterId = _extractChapterId(href);
        if (chapterId == null) continue;

        final titleSpan = a.querySelector('.grow > span:first-child') ??
            a.querySelector('span:not([class*="link-info"]):not([class*="me-2"])');

        String chapterName = titleSpan?.text.trim() ?? '';

        if (chapterName.isEmpty) {
          String fullText = a.text.trim();
          fullText = fullText.replaceAll(RegExp(r'Last Read', caseSensitive: false), '').trim();
          chapterName = fullText;
        }

        if (chapterName.isNotEmpty) {
          chapters.add(MangaChapter.fromRaw(chapterId, chapterName, href));
        }
      }

      debugPrint('[MangaService] Found ${chapters.length} chapters');
      return chapters;
    } catch (e) {
      debugPrint('[MangaService] Error fetching chapters: $e');
      return [];
    }
  }

  Future<List<String>> getChapterImages(String chapterId) async {
    if (MangaDexSource.owns(chapterId)) return _dex.pages(chapterId);
    if (MangaWorldSource.owns(chapterId)) return _world.pages(chapterId);
    if (MangaReadSource.owns(chapterId)) return _read.pages(chapterId);
    try {
      final url =
          '$_baseUrl/chapters/$chapterId/images?is_prev=False&current_page=1&reading_style=long_strip';
      final html = await _fetchHtml(url);
      final doc = html_parser.parse(html);

      final images = <String>[];
      for (final img in doc.querySelectorAll('img')) {
        final src = img.attributes['src'] ?? '';
        if (src.isNotEmpty &&
            !src.contains('/static/') &&
            !src.contains('brand')) {
          images.add(src);
        }
      }

      debugPrint('[MangaService] Found ${images.length} chapter images');
      return images;
    } catch (e) {
      debugPrint('[MangaService] Error fetching chapter images: $e');
      return [];
    }
  }

  Future<void> saveProgress(Manga manga, int chapterIndex, int pageIndex, List<MangaChapter> chapters) async {
    final prefs = await SharedPreferences.getInstance();

    final progress = {
      'manga': manga.toJson(),
      'chapterIndex': chapterIndex,
      'pageIndex': pageIndex,
      'chapters': chapters.map((c) => c.toJson()).toList(),
      'timestamp': DateTime.now().toIso8601String(),
    };

    final historyJson = prefs.getStringList(_historyKey) ?? [];
    final history = historyJson.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

    history.removeWhere((h) => h['manga']['id'] == manga.id);
    history.insert(0, progress);

    if (history.length > 10) {
      history.removeRange(10, history.length);
    }

    await prefs.setStringList(_historyKey, history.map((e) => jsonEncode(e)).toList());
    readingHistoryRevision.value++;
  }

  Future<List<Map<String, dynamic>>> getReadingHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getStringList(_historyKey) ?? [];
    return historyJson.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  Future<void> removeHistory(String mangaId) async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getStringList(_historyKey) ?? [];
    final history = historyJson.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

    history.removeWhere((h) => h['manga']['id'] == mangaId);
    await prefs.setStringList(_historyKey, history.map((e) => jsonEncode(e)).toList());
    readingHistoryRevision.value++;
  }

  Future<void> toggleLike(Manga manga) async {
    final prefs = await SharedPreferences.getInstance();
    final likedJson = prefs.getStringList(_likedKey) ?? [];

    final index = likedJson.indexWhere((j) {
      final m = jsonDecode(j) as Map<String, dynamic>;
      return m['id'] == manga.id;
    });

    if (index != -1) {
      likedJson.removeAt(index);
    } else {
      likedJson.add(jsonEncode(manga.toJson()));
    }

    await prefs.setStringList(_likedKey, likedJson);
  }

  Future<bool> isLiked(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final likedJson = prefs.getStringList(_likedKey) ?? [];
    return likedJson.any((j) {
      final m = jsonDecode(j) as Map<String, dynamic>;
      return m['id'] == id;
    });
  }

  Future<List<Manga>> getLikedManga() async {
    final prefs = await SharedPreferences.getInstance();
    final likedJson = prefs.getStringList(_likedKey) ?? [];
    return likedJson.map((j) => Manga.fromJson(jsonDecode(j))).toList();
  }

  static const List<String> availableTags = [
    'Action', 'Adventure', 'Comedy', 'Cooking', 'Doujinshi', 'Drama',
    'Ecchi', 'Fantasy', 'Gender Bender', 'Harem', 'Historical',
    'Horror', 'Isekai', 'Josei', 'Lolicon', 'Martial Arts', 'Mature',
    'Mecha', 'Medical', 'Music', 'Mystery', 'One Shot', 'Psychological',
    'Romance', 'School Life', 'Sci-Fi', 'Seinen', 'Shotacon', 'Shoujo',
    'Shoujo Ai', 'Shounen', 'Shounen Ai', 'Slice of Life', 'Smut',
    'Sports', 'Supernatural', 'Tragedy', 'Yaoi', 'Yuri',
  ];
}
