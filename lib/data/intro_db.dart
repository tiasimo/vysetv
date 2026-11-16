import 'dart:convert';

import 'package:http/http.dart' as http;

/// The kinds of segment TheIntroDB knows.
enum SegmentKind {
  intro('Skip intro'),
  recap('Skip recap'),
  preview('Skip preview'),
  credits('Skip credits');

  const SegmentKind(this.action);
  final String action;
}

class Segment {
  const Segment(this.kind, this.start, this.end);
  final SegmentKind kind;
  final Duration start;

  /// Null when it runs to the end of the video.
  final Duration? end;

  bool covers(Duration t, Duration length) => t >= start && t < (end ?? length);
}

/// Community-verified intro, recap, credits and preview timestamps from TheIntroDB
/// (https://theintrodb.org). No key needed. Empty when the title isn't in the database.
Future<List<Segment>> fetchSegments({required int tmdbId, int? season, int? episode}) async {
  try {
    final uri = Uri.https('api.theintrodb.org', '/v4/media', {
      'tmdb_id': '$tmdbId',
      if (season != null) 'season': '$season',
      if (episode != null) 'episode': '$episode',
    });
    final r = await http.get(uri, headers: {'User-Agent': 'VyseTV', 'Accept': 'application/json'}).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return const [];
    final data = json.decode(r.body) as Map<String, dynamic>;
    final out = <Segment>[];
    for (final kind in SegmentKind.values) {
      for (final s in (data[kind.name] as List?) ?? const []) {
        if (s is! Map) continue;
        final start = (s['start_ms'] as num?)?.toInt() ?? 0;
        final end = (s['end_ms'] as num?)?.toInt();
        if (end != null && end <= start) continue;
        out.add(Segment(kind, Duration(milliseconds: start), end == null ? null : Duration(milliseconds: end)));
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  } catch (_) {
    return const [];
  }
}
