// Choosing a torrent's file by hand.
//
// Normally the file is found for you: an addon names it, or its name says which episode it is
// (torrent_file_pick.dart). A magnet link pasted into Search comes with nothing to go by, so its
// files are listed and you pick. The same question is put whether the torrent plays peer to peer
// or through a debrid service.

/// One file of a torrent, for a list to choose from.
typedef TorrentFileChoice = ({String name, int size});

/// Shown a torrent's files; answers the place in the list of the one to play, or null to call
/// it off.
typedef AskTorrentFile = Future<int?> Function(List<TorrentFileChoice> files);

/// The list was closed without a file being picked.
class TorrentFileNotChosen implements Exception {
  const TorrentFileNotChosen();
  @override
  String toString() => 'No file was picked';
}

const _video = ['.mkv', '.mp4', '.m4v', '.avi', '.webm', '.mov', '.ts', '.m2ts', '.wmv', '.flv', '.mpg', '.mpeg'];
const _audio = ['.mp3', '.flac', '.m4a', '.m4b', '.ogg', '.opus', '.wav', '.aac'];

bool _ends(String path, List<String> exts) {
  final p = path.toLowerCase();
  return exts.any(p.endsWith);
}

/// The files of a torrent worth offering, in the order to list them: its videos by name (so
/// episodes run in order), else its audio, else everything. A small file called "sample" goes
/// last.
List<T> offeredTorrentFiles<T>(List<T> files, {required String Function(T) pathOf, required int Function(T) sizeOf}) {
  var list = [for (final f in files) if (_ends(pathOf(f), _video)) f];
  if (list.isEmpty) list = [for (final f in files) if (_ends(pathOf(f), _audio)) f];
  if (list.isEmpty) list = [...files];
  bool sample(T f) => RegExp(r'(^|[^a-z])sample([^a-z]|$)', caseSensitive: false).hasMatch(pathOf(f)) && sizeOf(f) < 150 << 20;
  list.sort((a, b) {
    final sa = sample(a), sb = sample(b);
    if (sa != sb) return sa ? 1 : -1;
    return _natural(pathOf(a).toLowerCase(), pathOf(b).toLowerCase());
  });
  return list;
}

/// Names compared so that "Episode 2" comes before "Episode 10".
int _natural(String a, String b) {
  final pa = RegExp(r'\d+|\D+').allMatches(a).map((m) => m[0]!).toList();
  final pb = RegExp(r'\d+|\D+').allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// Puts [files] to [ask] and gives back the one picked. Throws [TorrentFileNotChosen] when the
/// list is closed.
Future<T> chooseTorrentFile<T>(
  List<T> files, {
  required String Function(T) pathOf,
  required int Function(T) sizeOf,
  required AskTorrentFile ask,
}) async {
  if (files.isEmpty) throw StateError('The torrent has no files');
  final list = offeredTorrentFiles(files, pathOf: pathOf, sizeOf: sizeOf);
  final i = await ask([for (final f in list) (name: pathOf(f), size: sizeOf(f))]);
  if (i == null || i < 0 || i >= list.length) throw const TorrentFileNotChosen();
  return list[i];
}

/// What a magnet link says about itself.
class MagnetLink {
  const MagnetLink({required this.uri, required this.hash, this.name, this.trackers = const []});

  /// The link as it was given.
  final String uri;

  /// The torrent's info hash, 40 hex characters, lower case.
  final String hash;
  final String? name;
  final List<String> trackers;

  /// Reads a magnet link (or a bare info hash). Null when [text] is neither.
  static MagnetLink? parse(String text) {
    final t = text.trim();
    if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(t)) {
      return MagnetLink(uri: 'magnet:?xt=urn:btih:${t.toLowerCase()}', hash: t.toLowerCase());
    }
    if (!t.toLowerCase().startsWith('magnet:?')) return null;
    final Uri uri;
    try {
      uri = Uri.parse(t);
    } catch (_) {
      return null;
    }
    final all = uri.queryParametersAll;
    String? hash;
    for (final xt in all['xt'] ?? const <String>[]) {
      final m = RegExp(r'^urn:btih:([0-9a-zA-Z]+)$').firstMatch(xt.trim());
      if (m == null) continue;
      final h = m[1]!;
      if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(h)) {
        hash = h.toLowerCase();
      } else if (RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(h)) {
        hash = _base32ToHex(h);
      }
      if (hash != null) break;
    }
    if (hash == null) return null;
    final name = (all['dn'] ?? const <String>[]).where((s) => s.trim().isNotEmpty).firstOrNull;
    return MagnetLink(
      uri: t,
      hash: hash,
      name: name?.trim(),
      trackers: [for (final tr in all['tr'] ?? const <String>[]) if (tr.trim().isNotEmpty) tr.trim()],
    );
  }

  /// Older magnet links write the hash in base 32.
  static String? _base32ToHex(String s) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final c in s.toUpperCase().split('')) {
      final v = alphabet.indexOf(c);
      if (v < 0) return null;
      value = (value << 5) | v;
      bits += 5;
      while (bits >= 4) {
        bits -= 4;
        out.write(((value >> bits) & 0xF).toRadixString(16));
      }
      value &= (1 << bits) - 1;
    }
    final hex = out.toString();
    return hex.length >= 40 ? hex.substring(0, 40) : null;
  }
}
