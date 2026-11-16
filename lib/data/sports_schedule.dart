import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/iptv/hardcoded_channels.dart';
import 'channel_catalog.dart';

/// Fixtures, scores and broadcasters from ESPN's public scoreboard API (no key needed).
/// ESPN lists mostly US broadcasters, so each league also carries its main international
/// rights holders, as Live TV channel ids.

enum SportKind {
  football('Football', Icons.sports_soccer_rounded),
  basketball('Basketball', Icons.sports_basketball_rounded),
  americanFootball('NFL', Icons.sports_football_rounded),
  hockey('Hockey', Icons.sports_hockey_rounded),
  mma('MMA', Icons.sports_mma_rounded),
  motorsport('Motorsport', Icons.sports_motorsports_rounded);

  const SportKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class League {
  const League(this.path, this.name, this.sport, this.channels, {this.eventMode = false});

  /// ESPN path, e.g. soccer/esp.1
  final String path;
  final String name;
  final SportKind sport;

  /// International broadcasters, as Live TV channel ids.
  final List<String> channels;

  /// Races and fight cards: one event, not two teams.
  final bool eventMode;
}

const leagues = [
  League('soccer/uefa.champions', 'Champions League', SportKind.football, ['bein_sports', 'tnt_sports', 'cbs_sports', 'canal_plus_sport']),
  League('soccer/eng.1', 'Premier League', SportKind.football, ['sky_sports', 'tnt_sports', 'bein_sports', 'nbc_sports']),
  League('soccer/esp.1', 'LaLiga', SportKind.football, ['bein_sports', 'movistar_laliga', 'la_liga', 'espn_deportes']),
  League('soccer/ita.1', 'Serie A', SportKind.football, ['sky_sport_italia', 'dazn', 'serie_a']),
  League('soccer/ger.1', 'Bundesliga', SportKind.football, ['sky_sport_de', 'dazn', 'bundesliga']),
  League('soccer/fra.1', 'Ligue 1', SportKind.football, ['bein_sports', 'ligue_1', 'canal_plus_sport']),
  League('soccer/uefa.europa', 'Europa League', SportKind.football, ['bein_sports', 'tnt_sports']),
  League('soccer/ksa.1', 'Saudi Pro League', SportKind.football, ['ssc_sports', 'tnt_sports']),
  League('soccer/usa.1', 'MLS', SportKind.football, ['mls']),
  League('basketball/nba', 'NBA', SportKind.basketball, ['nba', 'nba_league_pass', 'espn']),
  League('football/nfl', 'NFL', SportKind.americanFootball, ['nfl', 'nfl_redzone', 'dazn']),
  League('football/college-football', 'College Football', SportKind.americanFootball, ['espn', 'sec_network', 'big_ten_network']),
  League('hockey/nhl', 'NHL', SportKind.hockey, ['nhl', 'espn', 'tnt_sports']),
  League('mma/ufc', 'UFC', SportKind.mma, ['ufc', 'tnt_sports'], eventMode: true),
  League('racing/f1', 'Formula 1', SportKind.motorsport, ['f1', 'sky_sports'], eventMode: true),
];

class Team {
  const Team({required this.name, required this.short, this.logo, this.score});
  final String name;
  final String short;
  final String? logo;
  final String? score;
}

enum MatchState { upcoming, live, finished }

class Match {
  const Match({
    required this.id,
    required this.league,
    required this.leagueLogo,
    required this.name,
    required this.start,
    required this.state,
    required this.status,
    required this.home,
    required this.away,
    required this.broadcasts,
    this.venue,
  });

  final String id;
  final League league;
  final String? leagueLogo;
  final String name;
  final DateTime start;
  final MatchState state;

  /// "67'", "Half Time", "FT", "Q3 4:12"…
  final String status;
  final Team? home;
  final Team? away;

  /// Broadcaster names as ESPN lists them.
  final List<String> broadcasts;
  final String? venue;

  bool get hasTeams => home != null && away != null;

  /// Every place to watch: ESPN's listings first, then the league's international channels.
  List<HardcodedChannel> get channels {
    final seen = <String>{};
    return [
      for (final b in broadcasts) resolveBroadcast(b),
      for (final id in league.channels) ?channelById(id),
    ].where((c) => seen.add(c.id)).toList();
  }
}

class SportsSchedule {
  static final _cache = <String, (DateTime, Future<List<Match>>)>{};

  /// Every league's fixtures on [day] (local), soonest first. Cached for two minutes.
  static Future<List<Match>> day(DateTime day, {bool refresh = false}) {
    final key = _ymd(day);
    final hit = _cache[key];
    if (!refresh && hit != null && DateTime.now().difference(hit.$1) < const Duration(minutes: 2)) return hit.$2;
    final f = _load(day);
    _cache[key] = (DateTime.now(), f);
    f.catchError((Object _) {
      _cache.remove(key);
      return <Match>[];
    });
    return f;
  }

  static String _ymd(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static Future<List<Match>> _load(DateTime day) async {
    // ESPN days are US-centred; ask for the day either side and keep what falls on the local day.
    final days = [day.subtract(const Duration(days: 1)), day, day.add(const Duration(days: 1))].map(_ymd).toList();
    final results = await Future.wait([
      for (final l in leagues) _league(l, '${days[0]}-${days[2]}'),
    ]);
    final start = DateTime(day.year, day.month, day.day), end = start.add(const Duration(days: 1));
    final seen = <String>{};
    final all = [
      for (final r in results)
        for (final m in r)
          if (seen.add(m.id) && (m.league.eventMode ? _overlaps(m, start, end) : !m.start.isBefore(start) && m.start.isBefore(end))) m,
    ]..sort((a, b) => a.start.compareTo(b.start));
    return all;
  }

  /// A race weekend or fight card counts on any day it's within a few days of.
  static bool _overlaps(Match m, DateTime start, DateTime end) =>
      m.start.isBefore(end) && m.start.add(const Duration(days: 3)).isAfter(start);

  static Future<List<Match>> _league(League l, String dates) async {
    Future<Map<String, dynamic>?> get(String d) async {
      final uri = Uri.parse('https://site.api.espn.com/apis/site/v2/sports/${l.path}/scoreboard?dates=$d');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      return res.statusCode == 200 ? jsonDecode(res.body) as Map<String, dynamic> : null;
    }

    try {
      // Ranges work for most leagues; some only take single days, so fall back to three calls.
      var bodies = [await get(dates)];
      if (bodies.first == null) {
        final (a, b) = (dates.split('-').first, dates.split('-').last);
        final mid = _ymd(DateTime.parse('${a.substring(0, 4)}-${a.substring(4, 6)}-${a.substring(6)}').add(const Duration(days: 1)));
        bodies = await Future.wait([get(a), get(mid), get(b)]);
      }
      return [
        for (final body in bodies.nonNulls)
          for (final e in (body['events'] as List? ?? const []))
            ?_parse(l, e as Map<String, dynamic>, _leagueLogo(body)),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String? _leagueLogo(Map<String, dynamic> body) {
    final ls = body['leagues'] as List?;
    final logos = (ls == null || ls.isEmpty) ? null : (ls.first as Map)['logos'] as List?;
    return (logos == null || logos.isEmpty) ? null : (logos.first as Map)['href'] as String?;
  }

  static Match? _parse(League l, Map<String, dynamic> e, String? leagueLogo) {
    try {
      final comp = (e['competitions'] as List).first as Map<String, dynamic>;
      final status = (e['status'] ?? comp['status']) as Map<String, dynamic>;
      final type = status['type'] as Map<String, dynamic>;
      final state = switch (type['state']) { 'in' => MatchState.live, 'post' => MatchState.finished, _ => MatchState.upcoming };
      Team? team(Map<String, dynamic> c) {
        final t = (c['team'] ?? c['athlete']) as Map<String, dynamic>?;
        if (t == null) return null;
        return Team(
          name: (t['shortDisplayName'] ?? t['displayName'] ?? t['name'] ?? '') as String,
          short: (t['abbreviation'] ?? t['shortDisplayName'] ?? '') as String,
          logo: (t['logo'] ?? ((t['logos'] as List?)?.firstOrNull as Map?)?['href'] ?? (t['flag'] as Map?)?['href']) as String?,
          score: state == MatchState.upcoming ? null : c['score']?.toString(),
        );
      }

      final cs = (comp['competitors'] as List? ?? const []).cast<Map<String, dynamic>>();
      final home = l.eventMode ? null : cs.where((c) => c['homeAway'] == 'home').firstOrNull;
      final away = l.eventMode ? null : cs.where((c) => c['homeAway'] == 'away').firstOrNull;
      final broadcasts = <String>{
        for (final b in (comp['broadcasts'] as List? ?? const [])) ...((b as Map)['names'] as List? ?? const []).cast<String>(),
        for (final g in (comp['geoBroadcasts'] as List? ?? const []))
          if (((g as Map)['media'] as Map?)?['shortName'] is String) (g['media'] as Map)['shortName'] as String,
      }.toList();
      final venue = (comp['venue'] as Map?)?['fullName'] as String?;
      return Match(
        id: '${l.path}/${e['id']}',
        league: l,
        leagueLogo: leagueLogo,
        name: (e['name'] ?? e['shortName'] ?? '') as String,
        start: DateTime.parse(e['date'] as String).toLocal(),
        state: state,
        status: (type['shortDetail'] ?? type['detail'] ?? '') as String,
        home: home == null ? null : team(home),
        away: away == null ? null : team(away),
        broadcasts: broadcasts,
        venue: venue,
      );
    } catch (_) {
      return null;
    }
  }
}

// ───────── broadcaster name → Live TV channel ─────────

/// ESPN's short names that don't read like the channel they are.
const _aliases = {
  'nbcsn': 'nbc_sports', 'peacock': 'nbc_sports', 'nbc': 'nbc_sports', 'usa net': 'nbc_sports',
  'nhl net': 'nhl', 'nhl network': 'nhl', 'nfl net': 'nfl', 'nfl network': 'nfl', 'nba tv': 'nba',
  'espn+': 'espn_plus', 'espn plus': 'espn_plus', 'espn deportes': 'espn_deportes', 'espn2': 'espn2', 'espnu': 'espnu',
  'abc': 'espn', 'espn': 'espn', 'cbs': 'cbs_sports', 'cbssn': 'cbs_sports', 'paramount+': 'cbs_sports',
  'fox': 'fox_sports', 'fs1': 'fox_sports', 'fs2': 'fox_sports', 'fox deportes': 'fox_deportes',
  'tnt': 'tnt_sports', 'trutv': 'tnt_sports', 'tele': 'telemundo', 'telemundo': 'telemundo', 'univision': 'univision',
  'tudn': 'tudn', 'apple tv': 'mls', 'mls season pass': 'mls', 'nba league pass': 'nba_league_pass', 'dazn': 'dazn',
  'f1 tv': 'f1', 'ufc fight pass': 'ufc', 'sec network': 'sec_network', 'acc network': 'acc_network', 'btn': 'big_ten_network',
};

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9+ ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

HardcodedChannel? channelById(String id) {
  for (final c in liveChannels) {
    if (c.id == id) return c;
  }
  return null;
}

/// The Live TV channel for a broadcaster name. Unknown broadcasters become a one-off channel
/// that searches portals for that exact name, so tapping still finds a stream.
HardcodedChannel resolveBroadcast(String name) {
  final n = _norm(name);
  final alias = _aliases[n];
  if (alias != null) {
    final c = channelById(alias);
    if (c != null) return c;
  }
  HardcodedChannel? best;
  var bestLen = 0;
  for (final c in liveChannels) {
    if (_norm(c.name) == n || c.keywords.any((k) => _norm(k) == n)) return c;
    for (final k in c.keywords) {
      final nk = _norm(k);
      if (nk.length >= 4 && nk.length > bestLen && (n.contains(nk) || nk.contains(n))) {
        best = c;
        bestLen = nk.length;
      }
    }
  }
  return best ??
      HardcodedChannel(
        id: 'bc_$n',
        name: name,
        short: name.length <= 4 ? name : name.substring(0, 3).toUpperCase(),
        category: 'Broadcast',
        keywords: [n],
        gradient: const [Color(0xFF171A2E), Color(0xFF0D0F18)],
      );
}
