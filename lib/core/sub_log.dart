import 'dart:io';

/// Subtitle trouble log, for chasing subtitles that don't show, vanish on a seek or drift:
/// `%TEMP%/vyse_subs/subtitle-log.txt`. Each player session appends; it's cut back when it
/// grows past 3 MB. Off unless built with --dart-define=VYSE_SUBLOG=true.
class SubLog {
  static const enabled = bool.fromEnvironment('VYSE_SUBLOG');

  static File? _file;
  static bool _failed = false;

  static File? get _f {
    if (_file != null || _failed) return _file;
    try {
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_subs')..createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}subtitle-log.txt');
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
    final stamp = '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${n.millisecond.toString().padLeft(3, '0')}';
    try {
      _f?.writeAsStringSync('$stamp  $text\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// [s] on one line, cut to [max] characters.
  static String clip(String? s, [int max = 70]) {
    if (s == null) return '';
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > max ? '${one.substring(0, max)}…' : one;
  }
}
