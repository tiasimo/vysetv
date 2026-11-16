import 'package:flutter/foundation.dart';

import '../models/iptv/iptv_models.dart';
import '../services/iptv/hardcoded_channels.dart';
import 'live_tv.dart';
import 'sports_schedule.dart';

/// Works out which exact feed (beIN Sports 2 AR, Sky Sports Main Event…) is showing a fixture by
/// reading each feed's TV guide around kick-off and looking for the teams.
///
/// Feeds are grouped by number + language, so "beIN SPORTS 2 AR" on ten portals costs one guide
/// lookup (a couple more if the first portal has no guide).
class MatchFinder extends ChangeNotifier {
  MatchFinder(this.match, this.channel);
  final Match match;
  final HardcodedChannel channel;

  /// Every exact feed spotted so far, per match and channel: matchId → channelId → labels.
  /// The match page and cards read this to say "beIN Sports 2 · AR" instead of just "beIN Sports".
  static final found = ValueNotifier<Map<String, Map<String, List<String>>>>(const {});

  static String keyOf(HitTags t) => '${t.number ?? ''}|${t.lang ?? ''}';

  final _groups = <String, List<ChannelHit>>{};
  final _results = <String, EpgEntry?>{};
  final _tries = <String, int>{};
  final _queue = <String>[];
  int _active = 0;
  bool _disposed = false;

  bool get busy => _active > 0 || _queue.isNotEmpty;
  int get checked => _results.length;
  int get total => _groups.length;

  /// Guide entry showing the match on this feed, if one was found.
  EpgEntry? entryFor(ChannelHit h) => _results[keyOf(HitTags.of(h.stream.name))];

  /// Groups that show the match, best first, as (key, label, entry).
  List<(String, String, EpgEntry)> get hits => [
        for (final e in _results.entries)
          if (e.value != null) (e.key, labelFor(e.key), e.value!),
      ]..sort((a, b) => a.$1.compareTo(b.$1));

  String labelFor(String key) {
    final [n, lang] = key.split('|');
    return [channel.name, if (n.isNotEmpty) ' $n', if (lang.isNotEmpty) '  ·  $lang'].join();
  }

  /// Feed in the latest results. Never notifies synchronously, so it's safe from a listener.
  void update(List<ChannelHit> all) {
    for (final h in all) {
      final k = keyOf(HitTags.of(h.stream.name));
      final g = _groups.putIfAbsent(k, () => []);
      if (!g.any((x) => x.streamUrl == h.streamUrl)) g.add(h);
      if (!_results.containsKey(k) && !_queue.contains(k) && (_tries[k] ?? 0) == 0) _queue.add(k);
    }
    _pump();
  }

  void _pump() {
    while (_active < 5 && _queue.isNotEmpty) {
      final k = _queue.removeAt(0);
      final i = _tries[k] ?? 0;
      final g = _groups[k]!;
      if (i >= g.length || i >= 3) {
        _results[k] = null;
        continue;
      }
      _tries[k] = i + 1;
      _active++;
      iptv.epgForHit(g[i]).timeout(const Duration(seconds: 15)).then((list) {
        if (list.isEmpty) {
          _queue.add(k); // no guide on this portal: try the same feed elsewhere
        } else {
          _results[k] = _best(list);
          if (_results[k] != null) _publish();
        }
      }, onError: (_) => _queue.add(k)).whenComplete(() {
        _active--;
        if (_disposed) return;
        notifyListeners();
        _pump();
      });
    }
  }

  void _publish() {
    final all = {...found.value};
    final forMatch = {...?all[match.id]};
    forMatch[channel.id] = [for (final h in hits) h.$2];
    all[match.id] = forMatch;
    found.value = all;
  }

  // ── matching ──

  static const _generic = {
    'united', 'city', 'real', 'club', 'sporting', 'athletic', 'atletico', 'inter', 'state', 'university', 'town',
    'county', 'rovers', 'wanderers', 'olympique', 'racing', 'deportivo', 'sport', 'sports', 'team', 'new', 'saint',
  };

  static String _fold(String s) {
    const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ', to = 'aaaaaaceeeeiiiinooooouuuuyy';
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      final c = String.fromCharCode(r);
      final i = from.indexOf(c);
      b.write(i < 0 ? c : to[i]);
    }
    return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  }

  static List<String> _tokens(String s) =>
      _fold(s).split(' ').where((t) => t.length >= 4 && !_generic.contains(t)).toList();

  static bool _mentions(String text, List<String> tokens) =>
      tokens.any((t) => t.length >= 6 ? text.contains(t) : text.contains(' $t '));

  EpgEntry? _best(List<EpgEntry> list) {
    final from = match.start.subtract(const Duration(minutes: 30));
    final to = match.start.add(const Duration(hours: 2, minutes: 30));
    final sides = match.hasTeams
        ? [
            {..._tokens(match.home!.name), ..._tokens(match.home!.short)}.toList(),
            {..._tokens(match.away!.name), ..._tokens(match.away!.short)}.toList(),
          ]
        : [_tokens(match.name), _tokens(match.league.name)];
    EpgEntry? best;
    var bestScore = 0;
    for (final e in list) {
      if (!e.start.isBefore(to) || !e.stop.isAfter(from)) continue;
      final text = ' ${_fold('${e.title} ${e.description}')} ';
      final score = sides.where((s) => s.isNotEmpty && _mentions(text, s)).length;
      if (score > bestScore) (best, bestScore) = (e, score);
    }
    return best;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
