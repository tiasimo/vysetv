import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A playable stream. [referrer] and [userAgent] go to mpv's own options; [headers] go to
/// mpv's http-header-fields.
class StreamSource {
  const StreamSource({
    required this.url,
    required this.server,
    required this.quality,
    required this.referrer,
    required this.userAgent,
    this.headers = const {},
    this.hls = true,
    this.audio,
    this.qualities = const [],
  });

  /// The master playlist when the server has one (its qualities are read from it), otherwise
  /// the best single stream.
  final String url;

  /// Separate streams per quality, for servers without a master playlist. Best first.
  final List<({String label, String url})> qualities;

  /// The source's or server's own name, as the menus show it.
  final String server;

  /// Set when the server carries dubbed audio.
  final String? audio;
  final String quality;
  final String referrer;
  final String userAgent;
  final Map<String, String> headers;
  final bool hls;
}

// ──────────────────── Movy (vidy.st) ────────────────────

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const _headers = {
  'User-Agent': _ua,
  'Referer': 'https://www.vidy.st/',
  'Origin': 'https://www.vidy.st',
  'Accept': 'application/json, text/plain, */*',
};

const _m32 = 0xFFFFFFFF;
const _slots = 61;
const _ms = 2654435769;
const _accXor = 2779096485;
const _magic = [109, 118, 109, 49]; // mvm1

int _rotl(int v, int n) {
  n &= 31;
  return ((v << n) | (v >>> (32 - n))) & _m32;
}

int _mix(int l) {
  l = (l ^ (l >>> 16)) & _m32;
  l = (l * 2246822507) & _m32;
  l = (l ^ (l >>> 13)) & _m32;
  l = (l * 3266489909) & _m32;
  return (l ^ (l >>> 16)) & _m32;
}

int _fnv(String s) {
  var o = 2166136261;
  for (final c in s.codeUnits) {
    o = ((o ^ c) * 16777619) & _m32;
  }
  return _mix(o);
}

class _Cipher {
  _Cipher(String seed, int tmdbId) {
    var i = _mix(_fnv(seed) ^ _mix((tmdbId ^ _ms) & _m32));
    for (var r = 0; r < 8; r++) {
      final n = i % _slots;
      i = _rotl((i + _ms) & _m32, 7 + (r & 7));
      _s[n] = (i ^ _mix(i)) & _m32;
      _present[n] = true;
      i = _mix((i + n) & _m32);
    }
    _acc = _mix(i ^ _accXor);
  }

  final _s = List<int>.filled(_slots, 0);
  final _present = List<bool>.filled(_slots, false);
  int _acc = 0;

  int next(int offset) {
    final r = _acc % _slots;
    final neg = _present[r] ? _m32 : 0;
    final x = (_s[r] ^ ((_ms * (offset + 1)) & _m32)) & _m32;
    var g = ((_acc ^ x) | (_acc & x & neg)) & _m32;
    g = (_rotl((g + _acc) & _m32, r & 31) ^ _rotl(_acc, (r * 7) & 31)) & _m32;
    _acc = _mix((g + _ms) & _m32);
    _s[r] = _acc;
    _present[r] = true;
    return _acc;
  }
}

String _decrypt(String enc, String seed, int tmdbId) {
  var b64 = enc.replaceAll('-', '+').replaceAll('_', '/');
  if (b64.length % 4 != 0) b64 += '=' * (4 - b64.length % 4);
  final raw = Uint8List.fromList(base64Decode(b64));
  final st = _Cipher(seed, tmdbId);
  var cursor = 0, offset = 0;
  while (cursor < raw.length) {
    final d = st.next(offset++);
    for (var k = 0; k < 4 && cursor < raw.length; k++) {
      raw[cursor++] ^= (d >>> (8 * k)) & 0xFF;
    }
  }
  for (var i = 0; i < 4; i++) {
    if (raw[i] != _magic[i]) throw const FormatException('movy: magic mismatch');
  }
  return utf8.decode(raw.sublist(4), allowMalformed: true);
}

/// One of Movy's servers. [name] is Movy's own name for it (its servers are named after cities).
/// [key] is what the devices in a watch party call it between them: it stays as it was before
/// the servers went by their real names, so a room with an older Lorewatch in it still agrees.
typedef _Shard = ({String shard, String name, String key, String? audio, Map<String, String> extra, bool altTitle, bool germanTitle});

const List<_Shard> _shards = [
  (shard: 'miami', name: 'Miami', key: 'Aurora', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'boise', name: 'Boise', key: 'Borealis', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'nashville', name: 'Nashville', key: 'Comet', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'chicago', name: 'Chicago', key: 'Drift', audio: null, extra: {}, altTitle: true, germanTitle: false),
  (shard: 'vegas', name: 'Vegas', key: 'Ember', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'reno', name: 'Reno', key: 'Flux', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'oakland', name: 'Oakland', key: 'Glacier', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'seattle', name: 'Seattle', key: 'Halo', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'phoenix', name: 'Phoenix', key: 'Ion', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'atlanta', name: 'Atlanta', key: 'Juniper', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'portland', name: 'Portland', key: 'Kestrel', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'austin', name: 'Austin', key: 'Lumen', audio: null, extra: {}, altTitle: false, germanTitle: false),
  (shard: 'munich', name: 'Munich', key: 'Meridian', audio: 'German', extra: {'language': 'german'}, altTitle: false, germanTitle: false),
  (shard: 'berlin', name: 'Berlin', key: 'Nova', audio: 'German', extra: {}, altTitle: false, germanTitle: true),
  (shard: 'paris', name: 'Paris', key: 'Orbit', audio: 'French', extra: {}, altTitle: false, germanTitle: false),
  (shard: 'delhi', name: 'Delhi', key: 'Prism', audio: 'Hindi', extra: {}, altTitle: false, germanTitle: false),
  (shard: 'cancun', name: 'Cancun', key: 'Quasar', audio: 'Spanish', extra: {}, altTitle: false, germanTitle: false),
];

Future<String> _get(String url, Duration timeout) async {
  final r = await http.get(Uri.parse(url), headers: _headers).timeout(timeout);
  if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}', Uri.parse(url));
  return r.body;
}

String _quality(String raw, String url) {
  if (raw.contains('4K') || raw.contains('2160') || url.contains('2160p')) return '4K';
  for (final q in ['1080', '720', '480', '360']) {
    if (raw.contains(q)) return '${q}p';
  }
  return ''; // the API doesn't say ("Auto", "Vidmoly"); the player reads it from the stream
}

int _rank(String q) => switch (q) { '4K' => 5, '1080p' => 4, '720p' => 3, '480p' => 2, '360p' => 1, _ => 0 };

/// ffmpeg opens every stream in a DASH manifest, one after another, before it plays anything, and
/// these servers can take seconds for each. So each quality gets a small manifest of its own, saved
/// on the device: that one video stream and the main audio. Best first. Empty if it isn't laid out
/// the way this expects: the full manifest still plays then, just slower to open.
Future<List<({String label, String url})>> _dashFiles(String url, String name) async {
  final mpd = await _get(url, const Duration(seconds: 6));
  final sets = RegExp(r'[ \t]*<AdaptationSet\b.*?</AdaptationSet>\s*', dotAll: true).allMatches(mpd).toList();
  final video = [for (final m in sets) if (m[0]!.contains('contentType="video"')) m[0]!];
  final audio = [for (final m in sets) if (m[0]!.contains('contentType="audio"')) m[0]!];
  if (video.length != 1 || audio.isEmpty) return const [];

  final rep = RegExp(r'[ \t]*<Representation\b.*?</Representation>\s*', dotAll: true);
  int rate(String r) => int.tryParse(RegExp(r'bandwidth="(\d+)"').firstMatch(r)?[1] ?? '') ?? 0;
  String only(String set, String keep) => set.replaceAllMapped(rep, (m) => m[0] == keep ? keep : '');
  final mainAudio = audio.firstWhere((a) => a.contains('value="main"'), orElse: () => audio.first);
  final sound = [for (final m in rep.allMatches(mainAudio)) m[0]!]..sort((a, b) => rate(b) - rate(a));
  if (sound.isEmpty) return const [];

  // the file isn't on their server, so its links need the full address
  final base = RegExp(r'<BaseURL>([^<]*)</BaseURL>').firstMatch(mpd)?[1] ?? '.';
  final where = Uri.parse(url).resolve(base.replaceAll('&amp;', '&')).toString().replaceAll('&', '&amp;');
  final head = mpd
      .substring(0, sets.first.start)
      .replaceAll(RegExp(r'\s*<BaseURL>[^<]*</BaseURL>'), '')
      .replaceFirstMapped(RegExp(r'<MPD\b[^>]*>'), (m) => '${m[0]}\n  <BaseURL>$where</BaseURL>');
  final tail = mpd.substring(sets.last.end);

  final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_dash');
  await dir.create(recursive: true);
  final files = <({int height, String label, String url})>[];
  for (final m in rep.allMatches(video.first)) {
    final height = int.tryParse(RegExp(r'\bheight="(\d+)"').firstMatch(m[0]!)?[1] ?? '') ?? 0;
    if (height == 0) continue;
    final file = File('${dir.path}${Platform.pathSeparator}${name}_$height.mpd');
    await file.writeAsString('$head${only(video.first, m[0]!)}${only(mainAudio, sound.first)}$tail');
    files.add((height: height, label: height >= 2160 ? '4K' : '${height}p', url: file.path));
  }
  files.sort((a, b) => b.height - a.height);
  return [for (final f in files) (label: f.label, url: f.url)];
}

/// A Movy server as shown in the Sources list, before anything is fetched from it.
class MovyServer {
  const MovyServer._(this._shard);
  final _Shard _shard;
  String get name => _shard.name;

  /// What a watch party's devices call this server between them.
  String get key => _shard.key;
  String? get audio => _shard.audio;
}

/// Every server, in the order they're tried: Miami first.
final movyServers = [for (final s in _shards) MovyServer._(s)];

/// One title's Movy lookups. Details and the seed are fetched once and shared; each server is
/// asked only when it's needed (direct calls, no proxies or relays).
class MovySession {
  MovySession({required this.tmdbId, required this.isTv, this.season, this.episode});
  final int tmdbId;
  final bool isTv;
  final int? season;
  final int? episode;

  String get _type => isTv ? 'tv' : 'movie';

  late final Future<({String title, String year, String imdbId, String totalSeasons, String titleGerman})> _meta = () async {
    try {
      final append = isTv ? 'external_ids,translations' : 'credits,external_ids,translations';
      final d = json.decode(await _get('https://db.wecollege.net/3/$_type/$tmdbId?append_to_response=$append&language=en', const Duration(milliseconds: 4500)))
          as Map<String, dynamic>;
      final title = ((isTv ? d['name'] : d['title']) ?? '') as String;
      final trans = ((d['translations'] as Map?)?['translations'] as List?) ?? const [];
      final de = trans.cast<Map>().where((t) => t['iso_639_1'] == 'de').firstOrNull?['data'] as Map?;
      final german = (de?['title'] ?? de?['name'] ?? '') as String;
      return (
        title: title,
        year: (((isTv ? d['first_air_date'] : d['release_date']) ?? '') as String).split('-').first,
        imdbId: ((d['external_ids'] as Map?)?['imdb_id'] ?? d['imdb_id'] ?? '') as String,
        totalSeasons: isTv ? '${d['number_of_seasons'] ?? 1}' : '1',
        titleGerman: german.isEmpty ? title : german,
      );
    } catch (_) {
      return (title: '', year: '', imdbId: '', totalSeasons: '1', titleGerman: '');
    }
  }();

  // The seed lives ~30s; renew it before then so a server picked minutes later still works.
  Future<String?>? _seed;
  DateTime _seedAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String?> _currentSeed() {
    if (_seed == null || DateTime.now().difference(_seedAt) > const Duration(seconds: 22)) {
      _seedAt = DateTime.now();
      _seed = _get('https://api.wecollege.net/seed?mediaId=$tmdbId', const Duration(seconds: 6))
          .then((b) => (json.decode(b) as Map<String, dynamic>)['seed']?.toString())
          .catchError((Object _) => null);
    }
    return _seed!;
  }

  /// Starts the details and seed lookups together, so the first server is asked sooner.
  void warmUp() {
    _meta;
    _currentSeed();
  }

  /// The stream from [server], or null when it has nothing.
  Future<StreamSource?> fetch(MovyServer server) async {
    final c = server._shard;
    final (meta, seed) = await (_meta, _currentSeed()).wait;
    if (seed == null || seed.isEmpty) return null;
    final p = <String, String>{
      'title': Uri.encodeComponent(meta.title),
      'mediaType': _type,
      'year': meta.year,
      'tmdbId': '$tmdbId',
      'enc': '2',
      'seed': seed,
      if (meta.imdbId.isNotEmpty) 'imdbId': meta.imdbId,
      if (isTv) ...{'seasonId': '${season ?? 1}', 'episodeId': '${episode ?? 1}', 'totalSeasons': meta.totalSeasons},
      if (c.altTitle && meta.title.isNotEmpty) 'altTitle': meta.title,
      if (c.germanTitle && meta.titleGerman.isNotEmpty) 'altTitle': meta.titleGerman,
      ...c.extra,
    };
    final Map<String, dynamic> data;
    try {
      final uri = Uri.parse('https://api.wecollege.net/${c.shard}/sources').replace(queryParameters: p);
      final enc = (await _get(uri.toString(), const Duration(milliseconds: 6500))).trim();
      if (enc.isEmpty) return null;
      data = json.decode(_decrypt(enc, seed, tmdbId)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    // Its qualities either sit in a master playlist (`playlist`) or come as separate `sources`
    // entries; either way they belong in the Quality menu, not in Sources.
    final seen = <String>{};
    final streams = <({String label, String url})>[];
    for (final s in (data['sources'] as List?) ?? const []) {
      if (s is! Map) continue;
      final url = s['url'] ?? s['file'];
      if (url is! String || url.isEmpty || !seen.add(url)) continue;
      streams.add((label: _quality('${s['quality'] ?? s['label'] ?? ''}', url), url: url));
    }
    if (streams.isEmpty) return null;
    streams.sort((a, b) => _rank(b.label) - _rank(a.label));
    final master = data['playlist'];
    final hasMaster = master is String && master.startsWith('http');
    final url = hasMaster ? master : streams.first.url;
    // DASH: the local relay only reads HLS, so mpv opens it itself and needs every header
    final dash = Uri.parse(url).path.endsWith('.mpd');
    const none = <({String label, String url})>[];
    final files = dash ? await _dashFiles(url, '${tmdbId}_${season ?? 0}_${episode ?? 0}').catchError((Object _) => none) : none;
    return StreamSource(
      url: files.isEmpty ? url : files.first.url,
      server: c.name,
      audio: c.audio,
      quality: files.isEmpty ? streams.first.label : files.first.label,
      referrer: 'https://www.vidy.st/',
      userAgent: _ua,
      headers: {'Origin': 'https://www.vidy.st', if (dash) ...{'Referer': 'https://www.vidy.st/', 'User-Agent': _ua}},
      hls: !dash && !(url.contains('/mp4/') || (url.contains('.mp4') && !url.contains('.m3u8'))),
      qualities: files.isNotEmpty ? files : (hasMaster || streams.length < 2 ? const [] : streams),
    );
  }
}
