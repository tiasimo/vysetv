import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/iptv/iptv_models.dart';
import '../services/iptv/iptv_network.dart' show IptvClient;
import 'live_tv.dart';

/// "17:05", the way the Live TV player writes times.
String guideTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// What a channel row needs from the guide: the programme on now and the one after it.
class NowNext {
  const NowNext(this.now, this.next);
  final EpgEntry? now;
  final EpgEntry? next;

  static const none = NowNext(null, null);

  /// Picks them out of a guide sorted by start time.
  factory NowNext.of(List<EpgEntry> guide, DateTime t) {
    EpgEntry? now, next;
    for (final e in guide) {
      if (!e.start.isAfter(t) && e.stop.isAfter(t)) {
        now ??= e;
      } else if (e.start.isAfter(t)) {
        next ??= e;
      }
    }
    return now == null && next == null ? none : NowNext(now, next);
  }

  /// How far through [now] the clock is, 0 to 1.
  double progress(DateTime t) {
    final e = now;
    if (e == null) return 0;
    final span = e.stop.difference(e.start).inSeconds;
    return span <= 0 ? 0 : (t.difference(e.start).inSeconds / span).clamp(0.0, 1.0);
  }
}

/// How one request is made; swapped out in tests.
typedef GuideFetch = Future<List<EpgEntry>> Function(VerifiedPortal portal, IptvStream stream, {required bool first, required int limit});

class _Slot {
  _Slot(this.portal, this.stream);
  final VerifiedPortal portal;
  final IptvStream stream;

  /// null until the first answer; empty when the portal has no guide for the channel.
  final data = ValueNotifier<List<EpgEntry>?>(null);
  DateTime? fetchedAt;
  DateTime? scheduleAt;
  int wanted = 0;
  bool queued = false;
  bool loading = false;
  bool scheduleLoading = false;
}

/// The guide for the channels on screen. Rows say when they appear and leave; this loads a few
/// at a time, newest first, drops requests for rows that scrolled away before their turn, and
/// keeps every answer for the rest of the session. A portal with a thousand channels only ever
/// costs as many requests as rows you actually stopped on.
class GuideLoader {
  GuideLoader({GuideFetch? fetch, this.maxActive = 3, this.settle = const Duration(milliseconds: 220)}) : _fetch = fetch ?? _portalFetch;

  final GuideFetch _fetch;

  /// Requests in flight at once: portals are quick to throttle.
  final int maxActive;

  /// A row has to stay on screen this long before its request starts.
  final Duration settle;

  static const _timeout = Duration(seconds: 14);
  static const _emptyRetry = Duration(minutes: 15); // nothing came back: ask again much later
  static const _staleRetry = Duration(minutes: 5); // everything it knew has aired
  static const _nextRetry = Duration(minutes: 10); // knows what's on, not what's next
  static const _scheduleKeep = Duration(minutes: 10);

  final _slots = <String, _Slot>{};
  final _queue = <_Slot>[];
  int _active = 0;
  Timer? _kick;

  /// Moves about twice a minute while a page is watching, so rows redraw their progress from
  /// what they already hold. Nothing is fetched on a tick unless a row's guide has run out.
  /// It is only a signal: rows read the time themselves when they draw.
  final clock = ValueNotifier<DateTime>(DateTime.now());
  Timer? _tick;
  int _watchers = 0;

  int get active => _active;
  int get waiting => _queue.length;

  static String keyOf(VerifiedPortal p, IptvStream s) => '${p.key}|${s.streamId}';

  static Future<List<EpgEntry>> _portalFetch(VerifiedPortal p, IptvStream s, {required bool first, required int limit}) {
    // The first look goes through the controller, so the player finds it already loaded.
    if (first && limit <= 2 && iptv.activePortal?.key == p.key) return iptv.epgFor(s);
    return IptvClient.shortEpg(p.portal, s.streamId, limit: limit);
  }

  _Slot _slot(VerifiedPortal p, IptvStream s) => _slots.putIfAbsent(keyOf(p, s), () => _Slot(p, s));

  /// A page showing guide rows is open (or closed again).
  void addWatcher() {
    if (_watchers++ == 0) _tick = Timer.periodic(const Duration(seconds: 30), (_) => clock.value = DateTime.now());
  }

  void removeWatcher() {
    if (_watchers > 0 && --_watchers == 0) {
      _tick?.cancel();
      _tick = null;
    }
  }

  /// The guide held for a channel, for a row to listen to.
  ValueListenable<List<EpgEntry>?> guideOf(VerifiedPortal p, IptvStream s) => _slot(p, s).data;

  /// A row for this channel came on screen.
  void want(VerifiedPortal p, IptvStream s) {
    final slot = _slot(p, s);
    slot.wanted++;
    _enqueue(slot);
  }

  /// The row left: a request that hasn't started is dropped.
  void unwant(VerifiedPortal p, IptvStream s) {
    final slot = _slots[keyOf(p, s)];
    if (slot == null) return;
    if (slot.wanted > 0) slot.wanted--;
    if (slot.wanted == 0 && slot.queued) {
      slot.queued = false;
      _queue.remove(slot);
    }
  }

  /// A row that is still on screen checks whether its guide has run out (on the clock's tick).
  void refresh(VerifiedPortal p, IptvStream s) {
    final slot = _slots[keyOf(p, s)];
    if (slot != null && slot.wanted > 0) _enqueue(slot);
  }

  /// The longer schedule for one channel, for its details. One request, kept ten minutes.
  void wantSchedule(VerifiedPortal p, IptvStream s) {
    final slot = _slot(p, s);
    final at = slot.scheduleAt;
    if (slot.scheduleLoading || (at != null && DateTime.now().difference(at) < _scheduleKeep)) return;
    slot.scheduleLoading = true;
    unawaited(_load(slot, limit: 8).whenComplete(() {
      slot.scheduleLoading = false;
      slot.scheduleAt = DateTime.now();
    }));
  }

  bool _needs(_Slot s, DateTime now) {
    final at = s.fetchedAt;
    if (at == null) return true;
    final list = s.data.value ?? const <EpgEntry>[];
    final age = now.difference(at);
    if (list.isEmpty) return age > _emptyRetry;
    if (!list.any((e) => e.stop.isAfter(now))) return age > _staleRetry;
    if (!list.any((e) => e.start.isAfter(now))) return age > _nextRetry;
    return false;
  }

  void _enqueue(_Slot slot) {
    if (slot.queued || slot.loading || slot.scheduleLoading || !_needs(slot, DateTime.now())) return;
    slot.queued = true;
    _queue.add(slot);
    _kick ??= Timer(settle, () {
      _kick = null;
      _pump();
    });
  }

  void _pump() {
    while (_active < maxActive && _queue.isNotEmpty) {
      final slot = _queue.removeLast(); // newest first: those rows are the ones on screen
      slot.queued = false;
      _active++;
      slot.loading = true;
      unawaited(_load(slot, limit: slot.fetchedAt == null ? 2 : 4).whenComplete(() {
        slot.loading = false;
        _active--;
        _pump();
      }));
    }
  }

  /// Never throws: a failed request leaves the row as it was, with no guide.
  Future<void> _load(_Slot slot, {required int limit}) async {
    var list = const <EpgEntry>[];
    try {
      list = await _fetch(slot.portal, slot.stream, first: slot.fetchedAt == null, limit: limit).timeout(_timeout);
    } catch (_) {}
    slot.fetchedAt = DateTime.now();
    final sorted = [...list]..sort((a, b) => a.start.compareTo(b.start));
    // A refresh that came back empty keeps what it had.
    if (sorted.isNotEmpty || slot.data.value == null) slot.data.value = sorted;
  }
}

GuideLoader _liveGuide = GuideLoader();

/// One loader for the whole app run, so the guide survives leaving and reopening a portal.
GuideLoader get liveGuide => _liveGuide;

@visibleForTesting
set liveGuide(GuideLoader value) => _liveGuide = value;
