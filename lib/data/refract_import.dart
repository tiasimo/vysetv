import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'tmdb.dart';
import 'watch_progress.dart';

/// One title from a Refract backup (data/library.jsonl).
class RefractTitle {
  RefractTitle({
    required this.tv,
    required this.tmdb,
    required this.title,
    required this.status,
    required this.added,
    required this.lastWatched,
    required this.episodes,
    this.season,
    this.episode,
  });

  final bool tv;
  final int tmdb;
  final String title;
  final WatchStatus status;
  final DateTime added;
  final DateTime? lastWatched;

  /// Episodes watched, as History keeps them ("S1E2").
  final List<String> episodes;
  final int? season;
  final int? episode;

  String get key => '${tv ? 'tv' : 'movie'}/$tmdb';
  bool get watchedSomething => (!tv && status == WatchStatus.completed) || episodes.isNotEmpty;
}

/// Lorewatch: brings a Refract backup into My List (each title on the matching list) and into
/// History (the films and episodes already watched). Refract has no API, so this reads the
/// backup Refract exports: the .zip as it is, or the data/library.jsonl file from inside it.
class RefractImport {
  /// Reads a Refract backup. Throws a [FormatException] when it isn't one.
  static List<RefractTitle> read(Uint8List bytes, {String name = ''}) {
    String? jsonl;
    final zip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B; // "PK"
    if (zip) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive.files) {
        if (f.isFile && (f.name == 'data/library.jsonl' || f.name.endsWith('/data/library.jsonl'))) {
          jsonl = utf8.decode(f.content as List<int>);
          break;
        }
      }
      if (jsonl == null) throw const FormatException('Nel file .zip non c\'è data/library.jsonl: è un backup di Refract?');
    } else {
      jsonl = utf8.decode(bytes, allowMalformed: true);
    }
    final out = <RefractTitle>[];
    for (final line in const LineSplitter().convert(jsonl)) {
      if (line.trim().isEmpty) continue;
      try {
        final j = json.decode(line) as Map<String, dynamic>;
        final item = j['item'] as Map<String, dynamic>;
        final tmdb = (item['tmdbId'] as num?)?.toInt();
        final type = item['mediaType'];
        if (tmdb == null || (type != 'movie' && type != 'tv')) continue;
        final eps = [for (final e in (j['watchedEpisodes'] as List? ?? const [])) '$e'];
        final ps = (j['progressSeason'] as num?)?.toInt(), pe = (j['progressEpisode'] as num?)?.toInt();
        out.add(RefractTitle(
          tv: type == 'tv',
          tmdb: tmdb,
          title: '${item['displayTitle'] ?? item['title'] ?? ''}',
          status: switch (j['status']) {
            'planned' => WatchStatus.planning,
            'completed' => WatchStatus.completed,
            'dropped' => WatchStatus.dropped,
            _ => WatchStatus.watching, // in_progress, up_to_date
          },
          added: DateTime.tryParse('${j['createdAt'] ?? ''}') ?? DateTime.now(),
          lastWatched: DateTime.tryParse('${j['lastWatchedAt'] ?? ''}'),
          episodes: eps,
          season: ps != null && ps > 0 ? ps : null,
          episode: pe != null && pe > 0 ? pe : null,
        ));
      } catch (_) {
        // a line this version doesn't understand: skipped
      }
    }
    if (out.isEmpty) throw const FormatException('Nessun titolo trovato: è il file di backup di Refract?');
    return out;
  }

  /// Puts [titles] in My List and History. [onProgress] gets how many of them are done.
  /// Returns how many titles came in.
  static Future<int> apply(List<RefractTitle> titles, {void Function(int done, int total)? onProgress}) async {
    final media = <String, ({Media media, int? runtime})>{};
    var done = 0;
    final queue = [...titles];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final t = queue.removeLast();
        try {
          final j = await Tmdb.get('/${t.tv ? 'tv' : 'movie'}/${t.tmdb}');
          final genres = [for (final g in ((j['genres'] as List?) ?? const []).whereType<Map>()) if (g['id'] is int) g['id'] as int];
          final runtime = t.tv
              ? ((j['episode_run_time'] as List?) ?? const []).whereType<num>().firstOrNull?.toInt()
              : (j['runtime'] as num?)?.toInt();
          final m = Media.fromJson({...j, 'genre_ids': genres}, tv: t.tv);
          // anime come from AniList: Refract's TMDB copies of them stay out
          if (!m.tmdbAnime) media[t.key] = (media: m, runtime: runtime);
        } catch (_) {
          // gone from TMDB, or a hiccup: that one's left out
        }
        done++;
        onProgress?.call(done, titles.length);
      }
    }

    await Future.wait([for (var i = 0; i < 8; i++) worker()]);

    // My List: every title, on its list
    MyList.addAll([
      for (final t in titles)
        if (media[t.key] case final m?) SavedTitle(m.media, t.added, t.status),
    ], updateStatus: true);

    // History: what was already watched, newest first
    final entries = <WatchEntry>[];
    for (final t in titles.where((t) => t.watchedSomething)) {
      final m = media[t.key];
      if (m == null) continue;
      final d = Duration(minutes: (m.runtime ?? 0) > 0 ? m.runtime! : (t.tv ? 45 : 110));
      // a very long series' every episode would weigh History down: keep just the latest then
      final eps = t.episodes.length > 300 ? <String>{} : {...t.episodes};
      if (t.tv && t.season != null && t.episode != null) eps.add('S${t.season}E${t.episode}');
      entries.add(WatchEntry(
        media: m.media,
        season: t.tv ? t.season : null,
        episode: t.tv ? t.episode : null,
        position: d,
        duration: d,
        updated: t.lastWatched ?? t.added,
        episodes: {for (final k in eps) k: 1.0},
      ));
    }
    WatchProgress.merge(entries);
    return media.length;
  }
}
