import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'tracker.dart';

/// One update waiting to reach a service. It holds the state we want there, not a log of
/// calls: a later episode replaces an earlier one, and removing a title from My List cancels
/// a waiting add.
///
/// Kinds: `anime` (furthest finished episode: `a` AniList id, `m` MAL id, `e` episode,
/// `t` title), `watched` (an episode or film watched to the end: `ref`, `at`), `listAdd` /
/// `listRemove` (My List: `ref`), `historyRemove` (removed from History: `ref`).
class OutboxItem {
  OutboxItem({
    required this.service,
    required this.kind,
    required this.key,
    required this.data,
    DateTime? created,
    DateTime? nextAt,
    this.attempts = 0,
    this.waitingAuth = false,
  }) : created = created ?? DateTime.now(),
       nextAt = nextAt ?? DateTime.now();

  final TrackerId service;
  final String kind;
  final String key;
  final Map<String, dynamic> data;
  final DateTime created;
  DateTime nextAt;
  int attempts;
  bool waitingAuth; // held until the service is signed in again

  String get id => '${service.name}:$kind:$key';

  Map<String, dynamic> toJson() => {
    's': service.name,
    'k': kind,
    'key': key,
    'd': data,
    'c': created.millisecondsSinceEpoch,
    'n': nextAt.millisecondsSinceEpoch,
    'r': attempts,
    if (waitingAuth) 'w': true,
  };

  static OutboxItem? fromJson(Map<String, dynamic> j) {
    try {
      return OutboxItem(
        service: TrackerId.values.byName(j['s'] as String),
        kind: j['k'] as String,
        key: j['key'] as String,
        data: Map<String, dynamic>.from(j['d'] as Map),
        created: DateTime.fromMillisecondsSinceEpoch((j['c'] as num).toInt()),
        nextAt: DateTime.fromMillisecondsSinceEpoch((j['n'] as num).toInt()),
        attempts: (j['r'] as num?)?.toInt() ?? 0,
        waitingAuth: j['w'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Updates waiting to be sent, kept in a file so going offline or closing the app loses
/// nothing. Written atomically (a temp file, then a rename). Anything older than 30 days goes.
class Outbox {
  static const _keep = Duration(days: 30);
  static final _items = <String, OutboxItem>{};
  static File? _file;

  static Iterable<OutboxItem> get items => _items.values;
  static int count(TrackerId s) => _items.values.where((i) => i.service == s).length;
  static OutboxItem? find(TrackerId s, String kind, String key) => _items['${s.name}:$kind:$key'];

  static Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = _file = File('${dir.path}${Platform.pathSeparator}tracker_outbox.json');
      if (!await f.exists()) return;
      final list = json.decode(await f.readAsString()) as List;
      final cutoff = DateTime.now().subtract(_keep);
      for (final j in list.whereType<Map<String, dynamic>>()) {
        final i = OutboxItem.fromJson(j);
        if (i != null && i.created.isAfter(cutoff)) _items[i.id] = i;
      }
    } catch (_) {}
  }

  /// Adds [item]. An anime update only moves the waiting one on to a later episode; a My List
  /// add and remove of the same title cancel each other out.
  static void put(OutboxItem item) {
    final had = _items[item.id];
    if (item.kind == 'anime' && had != null && ((had.data['e'] as num?) ?? 0) >= ((item.data['e'] as num?) ?? 0)) return;
    if (item.kind == 'listAdd' || item.kind == 'listRemove') {
      final opposite = find(item.service, item.kind == 'listAdd' ? 'listRemove' : 'listAdd', item.key);
      if (opposite != null) {
        _items.remove(opposite.id);
        _save();
        return; // the two cancel out: nothing needs sending
      }
    }
    _items[item.id] = item;
    _save();
  }

  static void remove(OutboxItem item) {
    if (_items.remove(item.id) != null) _save();
  }

  static void removeService(TrackerId s) {
    _items.removeWhere((_, i) => i.service == s);
    _save();
  }

  /// Send it now (a write-ahead record whose live call failed).
  static void now(OutboxItem item) {
    item.nextAt = DateTime.now();
    _save();
  }

  /// Try again later: 30 s, 1, 2, 4… minutes up to an hour, with a little jitter (or when the
  /// service said).
  static void later(OutboxItem item, {Duration? after}) {
    item.attempts++;
    final backoff = Duration(seconds: min(3600, 30 * pow(2, min(item.attempts - 1, 7)).toInt()));
    final jitter = Duration(milliseconds: Random().nextInt(5000));
    item.nextAt = DateTime.now().add((after ?? backoff) + jitter);
    _save();
  }

  static void holdForAuth(TrackerId s) {
    for (final i in _items.values.where((i) => i.service == s)) {
      i.waitingAuth = true;
    }
    _save();
  }

  static void releaseAuth(TrackerId s) {
    for (final i in _items.values.where((i) => i.service == s)) {
      i.waitingAuth = false;
      if (i.nextAt.isAfter(DateTime.now()) && i.kind != 'watched') i.nextAt = DateTime.now();
    }
    _save();
  }

  static Future<void> _writing = Future<void>.value();

  static void _save() {
    final f = _file;
    if (f == null) return;
    final text = json.encode([for (final i in _items.values) i.toJson()]);
    _writing = _writing.then((_) async {
      try {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}
