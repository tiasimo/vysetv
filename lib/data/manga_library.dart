import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/manga/manga.dart';
import '../models/manga/manga_chapter.dart';
import '../services/manga/manga_service.dart';

/// One scraper for the whole app.
final mangaService = MangaService();

extension MangaArt on Manga {
  String? get cover => coverNormal ?? coverSmall;
  String? get thumb => coverSmall ?? coverNormal;
}

extension ChapterLabel on MangaChapter {
  String get shortNumber {
    final n = number;
    if (n == null) return '';
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  String get label => number == null ? (name ?? rawName) : 'Chapter $shortNumber';

  /// The chapter's own title, when it has one beyond the number.
  String? get subtitle {
    final t = name?.trim();
    if (t == null || t.isEmpty || t == label) return null;
    return t;
  }
}

/// Oldest chapter first, which is the order the reader walks.
List<MangaChapter> readingOrder(List<MangaChapter> chapters) {
  final l = [...chapters];
  if (l.length > 1 && l.every((c) => c.number != null)) {
    l.sort((a, b) => a.number!.compareTo(b.number!));
  } else if (l.length > 1 && (l.first.number ?? 0) > (l.last.number ?? 0)) {
    return l.reversed.toList();
  }
  return l;
}

/// Saved series, kept on this device.
class MangaFavorites {
  static const _key = 'manga.favorites';
  static final items = ValueNotifier<List<Manga>>(const []);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      items.value = (jsonDecode(raw) as List).map((j) => Manga.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    } catch (_) {
      // A corrupt list shouldn't break the tab.
    }
  }

  static bool has(Manga m) => items.value.any((f) => f.id == m.id);

  static Future<void> toggle(Manga m) async {
    items.value = has(m) ? items.value.where((f) => f.id != m.id).toList() : [m, ...items.value];
    await _persist();
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(items.value.map((m) => m.toJson()).toList()));
  }

  // ── account sync ──

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async {
    await load();
    return {for (final m in items.value) m.id: Map<String, dynamic>.from(m.toJson())};
  }

  static Future<void> syncApply(String id, Map<String, dynamic>? data) async {
    await load();
    final rest = items.value.where((f) => f.id != id).toList();
    if (data != null) {
      try {
        rest.insert(0, Manga.fromJson(data));
      } catch (_) {}
    }
    items.value = rest;
    await _persist();
  }
}

/// A reading-history row: which series, and where the reader left off.
class MangaProgress {
  const MangaProgress(this.manga, this.chapterIndex, this.page, this.chapterLabel);
  final Manga manga;
  final int chapterIndex;
  final int page;
  final String? chapterLabel;

  static int _int(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v is num) return v.toInt();
      if (v is String && int.tryParse(v) != null) return int.parse(v);
    }
    return 0;
  }

  static MangaProgress? tryParse(Map<String, dynamic> j) {
    try {
      final raw = j['manga'];
      final manga = Manga.fromJson(raw is Map ? Map<String, dynamic>.from(raw) : j);
      final label = j['chapterName'] ?? j['chapterTitle'] ?? j['lastChapter'];
      return MangaProgress(
        manga,
        _int(j, const ['chapterIndex', 'chapter', 'lastChapterIndex']),
        _int(j, const ['pageIndex', 'page', 'lastPage']),
        label is String ? label : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Reading history, newest first. Bumped whenever the reader saves progress so shelves refresh.
///
/// Alongside the scraper's own history it keeps a synced copy with "last read" times, so the
/// account can bring progress from other devices.
class MangaHistory {
  static final revision = ValueNotifier(0);
  static const _syncKey = 'manga.history.synced';
  static Map<String, Map<String, dynamic>>? _synced; // manga id -> row with 't'

  static Future<Map<String, Map<String, dynamic>>> _rows() async {
    if (_synced != null) return _synced!;
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_syncKey);
      _synced = raw == null
          ? {}
          : {for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries) e.key: Map<String, dynamic>.from(e.value as Map)};
    } catch (_) {
      _synced = {};
    }
    return _synced!;
  }

  static Future<void> _saveRows() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_syncKey, jsonEncode(_synced ?? const {}));
  }

  static Future<List<MangaProgress>> load() async {
    final synced = await _rows();
    final rows = await mangaService.getReadingHistory();
    final seen = <String>{};
    final newest = synced.entries.toList()..sort((a, b) => ((b.value['t'] as num?) ?? 0).compareTo((a.value['t'] as num?) ?? 0));
    return [
      for (final e in newest)
        if (MangaProgress.tryParse(e.value) case final p? when seen.add(p.manga.id)) p,
      for (final r in rows.map(MangaProgress.tryParse).nonNulls)
        if (seen.add(r.manga.id)) r,
    ];
  }

  // ── account sync ──

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async {
    final synced = await _rows();
    final out = <String, Map<String, dynamic>>{...synced};
    for (final p in await load()) {
      out.putIfAbsent(p.manga.id, () => {
        'manga': p.manga.toJson(),
        'chapterIndex': p.chapterIndex,
        'pageIndex': p.page,
        'chapterName': p.chapterLabel,
        't': 0,
      });
    }
    return out;
  }

  static Future<void> syncApply(String id, Map<String, dynamic>? data) async {
    final synced = await _rows();
    if (data == null) {
      synced.remove(id);
      try {
        await mangaService.removeHistory(id);
      } catch (_) {}
    } else {
      synced[id] = data;
    }
    await _saveRows();
    revision.value++;
  }

  static Future<MangaProgress?> forManga(Manga m) async {
    for (final p in await load()) {
      if (p.manga.id == m.id) return p;
    }
    return null;
  }

  static Future<void> save(Manga m, int chapterIndex, int page, List<MangaChapter> chapters) async {
    await mangaService.saveProgress(m, chapterIndex, page, chapters);
    (await _rows())[m.id] = {
      'manga': m.toJson(),
      'chapterIndex': chapterIndex,
      'pageIndex': page,
      'chapterName': chapterIndex >= 0 && chapterIndex < chapters.length ? chapters[chapterIndex].label : null,
      't': DateTime.now().millisecondsSinceEpoch,
    };
    await _saveRows();
    revision.value++;
  }

  static Future<void> remove(Manga m) async {
    await mangaService.removeHistory(m.id);
    (await _rows()).remove(m.id);
    await _saveRows();
    revision.value++;
  }
}
