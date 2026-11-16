import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../net.dart';
import '../sources.dart';
import '../stream_proxy.dart';
import 'common.dart';
import 'scrapers.dart';

/// Where films and shows play from (Settings → Sources): Movy, and the sources ported from the
/// Vyla SDK that passed VyseTV's checks (a real title found, played through the relay, and a
/// seek far into it). They're asked in the order Settings gives; the first to answer plays.
///
/// Each goes by the site's own name.
class FilmSource {
  const FilmSource({required this.id, required this.name, required this.note, this.scraper, this.filmsOnly = false, this.showsOnly = false});

  /// Stable key, kept in the saved order ('movy', or the SDK's key for the source).
  final String id;
  final String name;

  /// One line about it for Settings.
  final String note;

  /// Null for Movy, which has servers of its own.
  final Scraper? scraper;

  /// Only asked for films: it has nothing for episodes, or failed the checks with them.
  final bool filmsOnly;

  /// Only asked for episodes, the same way round.
  final bool showsOnly;
}

const movySource = FilmSource(id: 'movy', name: 'Movy', note: '17 servers, some in other languages');

/// Every source, in the default order: Movy first.
final List<FilmSource> filmSources = [movySource, ...portedSources];

enum FilmState { untried, trying, ready, dead }

/// One way to play the title: one of Movy's servers (asked when it's tried), or one of the
/// streams a ported source found.
class FilmLink {
  // ignore: prefer_initializing_formals
  FilmLink._(this.source, this.name, {this.audio, MovyServer? movy, FoundStream? found}) : _movy = movy, _found = found;
  final FilmSource source;

  /// Movy: the server ('Miami'). The others: 'Link 2'.
  final String name;

  /// The language of its sound, when the server or source says: a Movy server dubbed into it,
  /// or another source's link in it ('Hindi', 'English sub').
  final String? audio;
  final MovyServer? _movy;
  final FoundStream? _found;

  FilmState state = FilmState.untried;

  /// What plays, once it answered.
  StreamSource? stream;

  /// What a party shares: Movy's server, or the source (its links differ from device to device).
  String get partyKey => _movy != null ? 'movy/${_movy.key}' : source.id;

  /// '4K', '1080p'… when it's known; empty when the stream decides.
  String get quality => switch (stream?.quality) {
    final q? when q.isNotEmpty => q,
    _ => _found == null ? '' : _label(_found.quality),
  };

  /// 'HLS', 'MP4', 'MKV'… once it's known.
  String? get format {
    final f = _found;
    if (f == null) return stream == null ? null : (stream!.hls ? 'HLS' : null);
    if (f.type == 'hls') return 'HLS';
    if (f.type == 'dash') return 'DASH';
    final ext = RegExp(r'\.(mkv|mp4|webm|avi|mov|m4v)$', caseSensitive: false).firstMatch(Uri.tryParse(f.url)?.path ?? '')?[1];
    return (ext ?? 'mp4').toUpperCase();
  }
}

/// What one source has for this title.
class FilmSourceState {
  FilmSourceState._(this.source);
  final FilmSource source;

  /// Its own lookup. Movy's servers are known from the start, so it's ready at once.
  FilmState state = FilmState.untried;
  List<FilmLink> links = const [];

  bool get isMovy => source.scraper == null;
}

/// One title's lookups, source by source. Movy's details and seed are fetched once and shared.
class FilmSession {
  FilmSession({required int tmdbId, required bool isTv, int? season, int? episode, required List<FilmSource> order, this.onChange})
    : movy = MovySession(tmdbId: tmdbId, isTv: isTv, season: season, episode: episode),
      _query = FilmQuery(tmdbId: tmdbId, isTv: isTv, season: isTv ? (season ?? 1) : null, episode: isTv ? (episode ?? 1) : null),
      sources = [
        for (final s in order)
          if (!(isTv && s.filmsOnly) && !(!isTv && s.showsOnly)) FilmSourceState._(s),
      ] {
    for (final s in sources.where((s) => s.isMovy)) {
      s.links = [for (final m in movyServers) FilmLink._(s.source, m.name, audio: m.audio, movy: m)];
      s.state = FilmState.ready;
    }
  }

  final MovySession movy;
  final FilmQuery _query;

  /// In the order they're asked: yours, or the party host's.
  final List<FilmSourceState> sources;

  /// Something's state changed: a lookup started or ended.
  final void Function()? onChange;

  final _scraping = <FilmSourceState, Future<void>>{};
  final _opening = <FilmLink, Future<StreamSource?>>{};

  Iterable<FilmLink> get links => sources.expand((s) => s.links);

  void warmUp() => movy.warmUp();

  /// Looks up what [s] has: once, or again after it found nothing.
  Future<void> scrape(FilmSourceState s) {
    final scraper = s.source.scraper;
    if (scraper == null || s.state == FilmState.ready) return Future.value();
    return _scraping[s] ??= () async {
      s.state = FilmState.trying;
      _changed();
      try {
        final found = await scraper(_query).timeout(const Duration(seconds: 30));
        final seen = <String>{};
        final unique = [for (final f in found) if (f.url.startsWith('http') && seen.add(f.url)) f];
        s.links = [for (var i = 0; i < unique.length; i++) FilmLink._(s.source, 'Link ${i + 1}', audio: unique[i].audio, found: unique[i])];
      } catch (_) {
        s.links = const [];
      }
      s.state = s.links.isEmpty ? FilmState.dead : FilmState.ready;
      _scraping.remove(s);
      _changed();
    }();
  }

  /// Gets [l] ready to play: asks Movy's server, or checks the stream really serves video
  /// (its playlist and first piece, or a file's first bytes). Null when it doesn't.
  Future<StreamSource?> open(FilmLink l) {
    if (l.stream != null) return Future.value(l.stream);
    return _opening[l] ??= () async {
      l.state = FilmState.trying;
      _changed();
      StreamSource? got;
      try {
        final m = l._movy, f = l._found;
        if (m != null) {
          got = await movy.fetch(m);
        } else if (f != null) {
          final h = _withAgent(f.headers);
          if (f.type == 'hls' ? await _hlsAnswers(f.url, h) : await _answers(f.url, h)) got = _toSource(f, l.source.name);
        }
      } catch (_) {}
      l.stream = got;
      l.state = got == null ? FilmState.dead : FilmState.ready;
      _opening.remove(l);
      _changed();
      return got;
    }();
  }

  /// It was picked for you and never got going.
  void giveUp(FilmLink l) {
    l.state = FilmState.dead;
    _changed();
  }

  /// The first link that plays, one source at a time in order: a source is only looked up when
  /// it's reached, and at most three of its links are tried. Stops at the first that answers.
  /// [first] (a party host's [FilmLink.partyKey]) is tried before the rest; [after] carries on
  /// from a link that didn't work out. Movy's dubbed servers wait until they're picked; another
  /// source's links are tried in its own order, whatever language each says it's in.
  Future<FilmLink?> firstHit({String? first, FilmLink? after, required bool Function() stop}) async {
    if (first != null && after == null) {
      final hit = await _tryKey(first, stop);
      if (hit != null || stop()) return hit;
    }
    var started = after == null;
    for (final s in sources) {
      if (!started && s.source != after!.source) continue;
      if (s.state == FilmState.dead && started) continue;
      await scrape(s);
      if (stop()) return null;
      var tried = 0;
      for (final l in s.links) {
        if (!started) {
          started = l == after;
          continue;
        }
        if ((s.isMovy && l.audio != null) || l.state == FilmState.dead) continue;
        if (!s.isMovy && tried++ >= 3) break;
        final got = await open(l);
        if (stop()) return null;
        if (got != null) return l;
      }
      started = true;
    }
    return null;
  }

  Future<FilmLink?> _tryKey(String key, bool Function() stop) async {
    final movyName = key.startsWith('movy/') ? key.substring(5) : null;
    final s = sources.where((s) => movyName != null ? s.isMovy : s.source.id == key).firstOrNull;
    if (s == null) return null;
    await scrape(s);
    if (stop()) return null;
    var tried = 0;
    for (final l in s.links) {
      if (movyName != null ? l._movy?.key != movyName : tried++ >= 3) continue;
      final got = await open(l);
      if (stop()) return null;
      if (got != null) return l;
    }
    return null;
  }

  void _changed() => onChange?.call();
}

const _probeTimeout = Duration(seconds: 8);

String? _firstUri(String playlist) =>
    const LineSplitter().convert(playlist).map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).firstOrNull;

Future<bool> _hlsAnswers(String url, Map<String, String> h) async {
  var base = Uri.parse(url);
  var r = await fetchRaw(url, headers: h, timeout: _probeTimeout);
  if (r.statusCode >= 300 || !r.body.contains('#EXTM3U')) return false;
  if (r.body.contains('#EXT-X-STREAM-INF')) {
    final variant = _firstUri(r.body);
    if (variant == null) return false;
    base = base.resolve(variant);
    r = await fetchRaw('$base', headers: h, timeout: _probeTimeout);
    if (r.statusCode >= 300 || !r.body.contains('#EXTM3U')) return false;
  }
  final piece = _firstUri(r.body);
  return piece != null && await _answers('${base.resolve(piece)}', h);
}

/// The first bytes of [url] come back (only the status is read; the rest is dropped).
Future<bool> _answers(String url, Map<String, String> h) async {
  final rq = http.Request('GET', Uri.parse(url))..headers.addAll({...h, 'Range': 'bytes=0-1023'});
  final res = await netClient.send(rq).timeout(_probeTimeout);
  unawaited(res.stream.listen(null).cancel());
  return res.statusCode == 200 || res.statusCode == 206;
}

Map<String, String> _withAgent(Map<String, String> h) =>
    h.keys.any((k) => k.toLowerCase() == 'user-agent') ? h : {...h, 'User-Agent': sdkUA};

String _label(String q) {
  final s = q.toLowerCase();
  if (s.contains('4k') || s.contains('2160')) return '4K';
  for (final n in ['1440', '1080', '720', '480', '360']) {
    if (s.contains(n)) return '${n}p';
  }
  return ''; // the player reads it from the stream
}

StreamSource _toSource(FoundStream f, String name) {
  final headers = _withAgent(f.headers);
  String? pick(String key) => headers.entries.where((e) => e.key.toLowerCase() == key).firstOrNull?.value;
  final hls = f.type == 'hls';
  // the relay sends each host the headers its source gives (as tested); files go to mpv with
  // them, plus a browser's User-Agent when the source names none
  if (hls) StreamProxy.instance.useHeaders(f.url, f.headers);
  return StreamSource(
    url: f.url,
    server: name,
    quality: _label(f.quality),
    referrer: pick('referer') ?? '',
    userAgent: pick('user-agent') ?? sdkUA,
    headers: headers,
    hls: hls,
  );
}
