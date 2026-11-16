import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frame-timing logger for chasing jank. Off unless built with --dart-define=VYSE_PERF=true.
/// Writes one summary line per second (plus markers) to `%TEMP%/vyse_perf.log`.
const perfEnabled = bool.fromEnvironment('VYSE_PERF');

File? _log;
final _frames = <FrameTiming>[];

void startPerfLog() {
  if (!perfEnabled || kIsWeb) return;
  _log = File('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_perf.log')..writeAsStringSync('');
  perfMark('start');
  SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
  Timer.periodic(const Duration(seconds: 1), (_) => _flush());
}

/// Drops a labelled line into the log (e.g. entering spotlight mode).
void perfMark(String label) {
  _log?.writeAsStringSync('${_stamp()}  -- $label\n', mode: FileMode.append);
}

String _stamp() => DateTime.now().toIso8601String().substring(11, 23);

void _flush() {
  if (_frames.isEmpty) return;
  double ms(Duration d) => d.inMicroseconds / 1000;
  final build = _frames.map((f) => ms(f.buildDuration)).toList()..sort();
  final raster = _frames.map((f) => ms(f.rasterDuration)).toList()..sort();
  final total = _frames.map((f) => ms(f.totalSpan)).toList()..sort();
  double p(List<double> l, double q) => l[((l.length - 1) * q).round()];
  double avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
  // Work the app actually did (build + raster). Total span also includes waiting for vsync,
  // which balloons on a 60 Hz monitor or when the window is in the background.
  final heavy = _frames.where((f) => ms(f.buildDuration) + ms(f.rasterDuration) > 8).length;

  _log?.writeAsStringSync(
    '${_stamp()}  frames=${_frames.length.toString().padLeft(3)}'
    '  build avg ${avg(build).toStringAsFixed(1)} p95 ${p(build, .95).toStringAsFixed(1)} max ${build.last.toStringAsFixed(1)}'
    '  raster avg ${avg(raster).toStringAsFixed(1)} p95 ${p(raster, .95).toStringAsFixed(1)} max ${raster.last.toStringAsFixed(1)}'
    '  total p95 ${p(total, .95).toStringAsFixed(1)} max ${total.last.toStringAsFixed(1)}  heavy>8ms: $heavy\n',
    mode: FileMode.append,
  );
  _frames.clear();
}
