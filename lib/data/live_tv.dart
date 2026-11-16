import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/iptv/iptv_models.dart';
import '../models/iptv/m3u_models.dart';
import '../services/iptv/iptv_controller.dart';

IptvController get iptv => IptvController.instance;

bool _iptvStarted = false;

/// Starts the IPTV controller once per app run.
void ensureIptvStarted() {
  if (_iptvStarted) return;
  _iptvStarted = true;
  iptv.init();
}

/// Anything the Live TV player can play: a portal channel, a movie, an episode, an M3U entry.
class LiveItem {
  const LiveItem({
    required this.title,
    required this.url,
    this.subtitle,
    this.logo,
    this.live = true,
    this.epg,
  });

  final String title;
  final String url;
  final String? subtitle;
  final String? logo;

  /// Live streams get a LIVE badge and EPG; VOD gets a seek bar.
  final bool live;
  final Future<List<EpgEntry>> Function()? epg;

  factory LiveItem.hit(ChannelHit h, {String? channelName}) => LiveItem(
        title: channelName ?? h.stream.name,
        subtitle: [h.portal.name, if (channelName != null) h.stream.name].join('  ·  '),
        logo: h.stream.icon,
        url: h.streamUrl,
        epg: () => iptv.epgForHit(h),
      );

  factory LiveItem.m3u(M3uChannel c, {String? playlist}) => LiveItem(
        title: c.name,
        subtitle: [?playlist, if (c.group.isNotEmpty) c.group].join('  ·  '),
        logo: c.logo,
        url: c.url,
      );

  factory LiveItem.stream(VerifiedPortal p, IptvStream s, IptvSection section) => LiveItem(
        title: s.name,
        subtitle: p.name,
        logo: s.icon,
        url: xtreamUrl(p, s, section),
        live: section == IptvSection.live,
        epg: section == IptvSection.live ? () => iptv.epgFor(s) : null,
      );

  factory LiveItem.episode(VerifiedPortal p, IptvStream series, IptvEpisode e) => LiveItem(
        title: e.title.isNotEmpty ? e.title : 'Episode ${e.episode}',
        subtitle: '${series.name}  ·  S${e.season} E${e.episode}',
        logo: e.image.isNotEmpty ? e.image : series.icon,
        url: '${_base(p)}/series/${p.portal.username}/${p.portal.password}/${e.id}.${e.containerExt.isEmpty ? 'mp4' : e.containerExt}',
        live: false,
      );
}

String _base(VerifiedPortal p) {
  final u = iptv.normalizeUrl(p.portal.url);
  return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
}

/// Standard Xtream Codes stream paths.
String xtreamUrl(VerifiedPortal p, IptvStream s, IptvSection section) {
  final user = p.portal.username, pass = p.portal.password;
  return switch (section) {
    IptvSection.live => '${_base(p)}/live/$user/$pass/${s.streamId}.${s.containerExt.isEmpty ? 'ts' : s.containerExt}',
    IptvSection.vod => '${_base(p)}/movie/$user/$pass/${s.streamId}.${s.containerExt.isEmpty ? 'mp4' : s.containerExt}',
    IptvSection.series => '${_base(p)}/series/$user/$pass/${s.streamId}.${s.containerExt.isEmpty ? 'mp4' : s.containerExt}',
  };
}

/// Episodes for a series stream, straight from the portal's player API.
Future<List<IptvEpisode>> fetchSeriesEpisodes(VerifiedPortal p, IptvStream series) async {
  final uri = Uri.parse('${_base(p)}/player_api.php').replace(queryParameters: {
    'username': p.portal.username,
    'password': p.portal.password,
    'action': 'get_series_info',
    'series_id': series.streamId,
  });
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}', uri);
  final body = jsonDecode(res.body);
  final seasons = body is Map ? body['episodes'] : null;
  final out = <IptvEpisode>[];
  void add(Object? raw, int fallbackSeason) {
    if (raw is! Map) return;
    final info = raw['info'] is Map ? raw['info'] as Map : const {};
    out.add(IptvEpisode(
      id: '${raw['id']}',
      episode: int.tryParse('${raw['episode_num']}') ?? 0,
      season: int.tryParse('${raw['season']}') ?? fallbackSeason,
      title: '${raw['title'] ?? ''}',
      containerExt: '${raw['container_extension'] ?? 'mp4'}',
      image: '${info['movie_image'] ?? ''}',
      plot: '${info['plot'] ?? ''}',
    ));
  }

  if (seasons is Map) {
    seasons.forEach((k, v) {
      if (v is List) {
        for (final e in v) {
          add(e, int.tryParse('$k') ?? 1);
        }
      }
    });
  } else if (seasons is List) {
    for (final s in seasons) {
      if (s is List) {
        for (final e in s) {
          add(e, 1);
        }
      }
    }
  }
  out.sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
  return out;
}

/// Checks which streams answer, a handful at a time. Only ever given the channels on screen
/// (one category), never the whole portal.
class AliveChecker extends ChangeNotifier {
  final results = <String, bool>{};
  int done = 0;
  int total = 0;
  bool running = false;
  int _generation = 0;
  bool _disposed = false;

  int get working => results.values.where((v) => v).length;

  Future<void> check(List<(String id, String url)> items) async {
    final gen = ++_generation;
    running = true;
    done = 0;
    total = items.length;
    _notify();
    var next = 0;
    Future<void> worker() async {
      while (gen == _generation && next < items.length) {
        final (id, url) = items[next++];
        final ok = await _probe(url);
        if (gen != _generation) return;
        results[id] = ok;
        done++;
        _notify();
      }
    }

    await Future.wait(List.generate(8, (_) => worker()));
    if (gen == _generation) {
      running = false;
      _notify();
    }
  }

  void stop() {
    _generation++;
    running = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _disposed = true;
    super.dispose();
  }

  /// A stream "works" if the server starts answering it with a 2xx/3xx within a few seconds.
  static Future<bool> _probe(String url) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}

/// What a portal stream's name says about it: "AR: beIN SPORTS 1 HD" → 1 / AR / HD.
class HitTags {
  const HitTags(this.number, this.lang, this.quality);
  final String? number;
  final String? lang;
  final String? quality;

  static const _langs = {
    'AR', 'EN', 'FR', 'TR', 'ES', 'DE', 'IT', 'PT', 'NL', 'PL', 'RU', 'UK', 'US', 'CA', 'MENA', 'FA', 'UR', 'HI', 'IN',
    'BR', 'MX', 'GR', 'RO', 'AL', 'SE', 'NO', 'DK', 'FI', 'KU', 'HE', 'ID', 'MY', 'PH', 'AF', 'BE', 'CH', 'AT', 'KR', 'JP',
  };

  factory HitTags.of(String name) {
    final tokens = name.toUpperCase().split(RegExp(r'[^A-Z0-9+]+')).where((t) => t.isNotEmpty).toList();
    final number = tokens.where((t) => RegExp(r'^\d{1,2}$').hasMatch(t)).firstOrNull;
    final lang = tokens.where(_langs.contains).firstOrNull;
    String? quality;
    if (tokens.any((t) => t == '4K' || t == 'UHD')) {
      quality = '4K';
    } else if (tokens.any((t) => t == 'FHD' || t == '1080' || t == '1080P')) {
      quality = 'FHD';
    } else if (tokens.contains('HD')) {
      quality = 'HD';
    } else if (tokens.contains('SD')) {
      quality = 'SD';
    }
    return HitTags(number, lang, quality);
  }
}
