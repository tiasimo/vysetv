import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../mpv/mpv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audiobook/audiobook_model.dart';
import '../services/audiobook/audiobook_scraper_service.dart';
import 'audio_focus.dart';

/// Where a listener left off in a book.
class BookProgress {
  const BookProgress(this.book, this.chapter, this.position, this.chapterTitle);
  final Audiobook book;
  final int chapter;
  final Duration position;
  final String? chapterTitle;
}

/// Plays one audiobook at a time, remembers your place in every book, and keeps a recents list.
class AudiobookPlayer extends ChangeNotifier {
  AudiobookPlayer._() {
    _created = this;
    _player.streams.playing.listen((v) {
      playing = v;
      notifyListeners();
    });
    _player.streams.buffering.listen((v) {
      buffering = v;
      notifyListeners();
    });
    _player.streams.position.listen((p) {
      position.value = p;
      // Save every ~10 s of listening.
      if ((p - _lastSaved).abs() > const Duration(seconds: 10)) _saveProgress();
    });
    _player.streams.duration.listen((d) => duration.value = d);
    _player.streams.completed.listen((done) {
      if (done && !loading) _onChapterEnd();
    });
    _player.streams.error.listen((e) {
      error = e.message;
      notifyListeners();
    });
    _loadRecents();
  }

  static final instance = AudiobookPlayer._();
  static const _recentsKey = 'audiobooks.recents';

  /// Bumped after every save of the recents list (the account sync listens to this).
  static final syncRevision = ValueNotifier(0);
  static AudiobookPlayer? _created;

  final _player = Player.audio(secondary: true);
  final position = ValueNotifier(Duration.zero);
  final duration = ValueNotifier(Duration.zero);
  final recents = ValueNotifier<List<BookProgress>>(const []);

  Audiobook? book;
  List<AudiobookChapter> chapters = const [];
  int chapter = 0;
  bool playing = false;
  bool buffering = false;
  bool loading = false;
  double speed = 1;
  String? error;

  /// Sleep timer: a fixed time, or the end of the current chapter.
  DateTime? sleepAt;
  bool sleepAtChapterEnd = false;
  Timer? _sleepTimer;

  Duration _lastSaved = Duration.zero;
  int _generation = 0;

  AudiobookChapter? get currentChapter => chapter >= 0 && chapter < chapters.length ? chapters[chapter] : null;
  bool get hasNext => chapter < chapters.length - 1;
  bool get hasPrev => chapter > 0;
  bool get sleeping => sleepAt != null || sleepAtChapterEnd;

  BookProgress? progressFor(Audiobook b) {
    for (final r in recents.value) {
      if (r.book.uuid == b.uuid) return r;
    }
    return null;
  }

  /// Starts [b] at [chapterIndex], or wherever the listener left off.
  Future<void> play(Audiobook b, List<AudiobookChapter> chaps, {int? chapterIndex, Duration? at}) async {
    if (chaps.isEmpty) return;
    final saved = progressFor(b);
    book = b;
    chapters = chaps;
    chapter = (chapterIndex ?? saved?.chapter ?? 0).clamp(0, chaps.length - 1);
    final start = at ?? (chapterIndex == null || chapterIndex == saved?.chapter ? saved?.position : null);
    await _openChapter(start: start);
  }

  Future<void> jumpToChapter(int i) async {
    if (i < 0 || i >= chapters.length) return;
    chapter = i;
    await _openChapter();
  }

  Future<void> nextChapter() => jumpToChapter(chapter + 1);

  Future<void> previousChapter() async {
    if (position.value > const Duration(seconds: 5) || !hasPrev) {
      await _player.seek(Duration.zero);
    } else {
      await jumpToChapter(chapter - 1);
    }
  }

  Future<void> toggle() async {
    if (book == null) return;
    if (!playing) AudioFocus.claim(this, pause);
    await _player.playOrPause();
    _saveProgress();
  }

  void pause() {
    _player.pause();
    _saveProgress();
  }

  Future<void> seek(Duration d) async {
    final max = duration.value;
    await _player.seek(d < Duration.zero ? Duration.zero : (max > Duration.zero && d > max ? max : d));
  }

  Future<void> skip(int seconds) => seek(position.value + Duration(seconds: seconds));

  Future<void> setSpeed(double s) async {
    speed = s;
    notifyListeners();
    await _player.setRate(s);
  }

  void setSleep(Duration? after, {bool endOfChapter = false}) {
    _sleepTimer?.cancel();
    sleepAt = after == null ? null : DateTime.now().add(after);
    sleepAtChapterEnd = endOfChapter;
    if (after != null) {
      _sleepTimer = Timer(after, () {
        pause();
        sleepAt = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _saveProgress();
    _generation++;
    _sleepTimer?.cancel();
    sleepAt = null;
    sleepAtChapterEnd = false;
    await _player.stop();
    book = null;
    chapters = const [];
    AudioFocus.release(this);
    notifyListeners();
  }

  Future<void> forget(Audiobook b) async {
    recents.value = recents.value.where((r) => r.book.uuid != b.uuid).toList();
    await _persist();
  }

  void _onChapterEnd() {
    if (sleepAtChapterEnd) {
      sleepAtChapterEnd = false;
      notifyListeners();
      return;
    }
    if (hasNext) nextChapter();
  }

  Future<void> _openChapter({Duration? start}) async {
    final c = currentChapter;
    final b = book;
    if (c == null || b == null) return;
    final gen = ++_generation;
    AudioFocus.claim(this, pause);
    loading = true;
    error = null;
    position.value = start ?? Duration.zero;
    duration.value = Duration.zero;
    notifyListeners();
    try {
      await _player.open(Media(c.url, headers: c.httpHeaders, start: start), play: true);
      if (gen != _generation) return;
      await _player.setRate(speed);
      _lastSaved = start ?? Duration.zero;
      _saveProgress();
    } catch (e) {
      if (gen == _generation) error = "Couldn't play ${c.title}";
    } finally {
      if (gen == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  // ───────── persistence ─────────

  static Map<String, dynamic> _bookJson(Audiobook b) => {
        'audioBookId': b.audioBookId,
        'author': b.author,
        'coverImage': b.coverImage,
        'dynamicSlugId': b.dynamicSlugId,
        'pageUrl': b.pageUrl,
        'source': b.source,
        'title': b.title,
        'uuid': b.uuid,
      };

  static Audiobook _bookFrom(Map<String, dynamic> j) => Audiobook(
        audioBookId: j['audioBookId'] as String,
        author: j['author'] as String?,
        coverImage: j['coverImage'] as String,
        dynamicSlugId: j['dynamicSlugId'] as String,
        pageUrl: j['pageUrl'] as String,
        source: j['source'] as String,
        title: j['title'] as String,
        uuid: j['uuid'] as String,
      );

  void _saveProgress() {
    final b = book;
    if (b == null || loading) return;
    _lastSaved = position.value;
    final entry = BookProgress(b, chapter, position.value, currentChapter?.title);
    recents.value = [entry, ...recents.value.where((r) => r.book.uuid != b.uuid)].take(30).toList();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recentsKey,
      jsonEncode([
        for (final r in recents.value)
          {'book': _bookJson(r.book), 'chapter': r.chapter, 'ms': r.position.inMilliseconds, 'chapterTitle': r.chapterTitle},
      ]),
    );
    syncRevision.value++;
  }

  // ── account sync ──

  static Future<List<Map<String, dynamic>>> _stored() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_recentsKey);
      return raw == null ? [] : [for (final j in (jsonDecode(raw) as List)) Map<String, dynamic>.from(j as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<Map<String, Map<String, dynamic>>> syncSnapshot() async => {
    for (final j in await _stored())
      if ((j['book'] as Map?)?['uuid'] case final String uuid) uuid: j,
  };

  static Future<void> syncApply(String uuid, Map<String, dynamic>? data) async {
    final player = _created;
    if (player != null) {
      final rest = player.recents.value.where((r) => r.book.uuid != uuid).toList();
      if (data != null) {
        try {
          rest.insert(
            0,
            BookProgress(
              _bookFrom(Map<String, dynamic>.from(data['book'] as Map)),
              (data['chapter'] as num).toInt(),
              Duration(milliseconds: (data['ms'] as num).toInt()),
              data['chapterTitle'] as String?,
            ),
          );
        } catch (_) {}
      }
      player.recents.value = rest.take(30).toList();
      await player._persist();
      return;
    }
    // player not started: edit the saved list
    final list = (await _stored()).where((j) => (j['book'] as Map?)?['uuid'] != uuid).toList();
    if (data != null) list.insert(0, data);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recentsKey, jsonEncode(list.take(30).toList()));
    syncRevision.value++;
  }

  Future<void> _loadRecents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_recentsKey);
      if (raw == null) return;
      recents.value = [
        for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          BookProgress(
            _bookFrom(Map<String, dynamic>.from(j['book'] as Map)),
            j['chapter'] as int,
            Duration(milliseconds: j['ms'] as int),
            j['chapterTitle'] as String?,
          ),
      ];
    } catch (_) {
      // Corrupt recents shouldn't break the tab.
    }
  }
}

/// One scraper for the whole app.
AudiobookScraperService get audiobookService => AudiobookScraperService.instance;
