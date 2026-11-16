import 'dart:io';

/// Music trouble log, for chasing songs that won't play: `%TEMP%/vyse_music/music-log.txt`.
/// One block per song asked for: what was asked, what the stream lookup gave back and how long
/// it took, what mpv said, and whether sound started. Each run appends; it's cut back when it
/// grows past 3 MB. Off unless built with --dart-define=VYSE_MUSICLOG=true.
class MusicLog {
  static const enabled = bool.fromEnvironment('VYSE_MUSICLOG');

  static File? _file;
  static bool _failed = false;

  static File? get _f {
    if (_file != null || _failed) return _file;
    try {
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_music')..createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}music-log.txt');
      if (f.existsSync() && f.lengthSync() > 3 * 1024 * 1024) f.writeAsStringSync('');
      return _file = f;
    } catch (_) {
      _failed = true;
      return null;
    }
  }

  static void line(String text) {
    if (!enabled) return;
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
    try {
      _f?.writeAsStringSync('$stamp  $text\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// A stream address without its signature: the host and the parts that say what it is.
  static String url(String? u) {
    if (u == null || u.isEmpty) return 'none';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return clip(u, 120);
    final q = uri.queryParameters;
    const keep = ['itag', 'mime', 'clen', 'dur', 'expire', 'c', 'source', 'ratebypass', 'gir'];
    final parts = [for (final k in keep) if (q[k] != null) '$k=${q[k]}'];
    final signed = q.containsKey('sig') || q.containsKey('signature') || q.containsKey('lsig');
    return '${uri.scheme}://${uri.host}${clip(uri.path, 40)}  ${parts.join(' ')}  n=${q.containsKey('n')} signed=$signed  (${u.length} chars)';
  }

  /// [s] on one line, cut to [max] characters.
  static String clip(String? s, [int max = 200]) {
    if (s == null) return '';
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > max ? '${one.substring(0, max)}…' : one;
  }
}
