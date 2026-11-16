// Which file of a torrent to play.
//
// A Stremio addon such as Torrentio says which (a file name, or an index). VyseTV's built-in
// source only knows the torrent, so for an episode the file is found by what the names say:
// the season and episode in the file's name or its folders ("Season 02/05 - Title.mkv"), an
// episode range ("E01-E04"), or the episode's own title. The scoring is the debrid port's
// (DebridMediaMatcher), the same one that picks the file when a debrid service plays it.

import 'debrid/utils/debrid_media_matcher.dart';
import 'debrid/utils/parse_torrent_title.dart';

/// The torrent has several videos and none of them is the episode asked for.
class EpisodeNotInTorrent implements Exception {
  const EpisodeNotInTorrent(this.season, this.episode);
  final int season;
  final int episode;

  @override
  String toString() => "This torrent doesn't have season $season episode $episode";
}

const _videoExtensions = ['.mkv', '.mp4', '.m4v', '.avi', '.webm', '.mov', '.ts', '.m2ts', '.wmv', '.flv'];

// A name that says this season and episode scores 1100 or more, the episode's title alone 600;
// size adds at most 100, and a sample, trailer or extra loses 5000.
const _sureScore = 500.0;
const _junkScore = -1000.0;

final _titles = ParseTorrentTitle();

/// The file of [files] to play. In order:
///  1. the file the addon named: [filename] (the end of its path), else [fileIdx] ([idOf] is
///     TorrServer's file number, which counts from 1 where Stremio counts from 0);
///  2. for an episode ([season] and [episode] both known) with no file named: the file whose
///     name says so. When no name does: the only real video there is, or the biggest when
///     [torrentName] says the torrent is that one episode; otherwise [EpisodeNotInTorrent],
///     because the biggest file of a season pack is just some other episode;
///  3. anything else (a film, or an anime without a season number): the biggest video.
T pickTorrentFile<T>(
  List<T> files, {
  required String Function(T) pathOf,
  required int Function(T) sizeOf,
  required int Function(T) idOf,
  String? filename,
  int? fileIdx,
  int? season,
  int? episode,
  String? episodeTitle,
  String? torrentName,
}) {
  if (files.isEmpty) throw StateError('The torrent has no files');
  if (filename != null && filename.isNotEmpty) {
    final name = filename.toLowerCase();
    for (final f in files) {
      if (pathOf(f).toLowerCase().endsWith(name)) return f;
    }
  }
  if (fileIdx != null) {
    for (final f in files) {
      if (idOf(f) == fileIdx + 1) return f;
    }
  }

  final videos = [for (final f in files) if (_videoExtensions.any(pathOf(f).toLowerCase().endsWith)) f];
  final pool = videos.isEmpty ? files : videos;
  T biggest(List<T> of) => of.reduce((a, b) => sizeOf(a) >= sizeOf(b) ? a : b);

  if (season != null && episode != null && pool.length > 1) {
    double score(T f) => DebridMediaMatcher.computeFileMatchScore(pathOf(f), sizeOf(f), season: season, episode: episode, episodeTitle: episodeTitle);
    final scored = [for (final f in pool) (f, score(f))]..sort((a, b) => b.$2.compareTo(a.$2));
    if (scored.first.$2 > _sureScore) return scored.first.$1;
    // nothing says so by name: fine when there is only one real video (the rest are samples
    // and extras), or when the torrent itself is that one episode
    final real = [for (final (f, s) in scored) if (s > _junkScore) f];
    if (real.length == 1) return real.first;
    if (real.isNotEmpty && _isThatEpisode(torrentName, season, episode)) return biggest(real);
    throw EpisodeNotInTorrent(season, episode);
  }
  return biggest(pool);
}

/// Whether a torrent's own name says it is exactly this episode (not a pack or a range).
bool _isThatEpisode(String? torrentName, int season, int episode) {
  if (torrentName == null || torrentName.trim().isEmpty) return false;
  try {
    final p = _titles.parse(torrentName);
    final s = p['season'] as int?;
    return p['episode'] == episode && p['episodeRange'] == null && (s == null || s == season);
  } catch (_) {
    return false;
  }
}
