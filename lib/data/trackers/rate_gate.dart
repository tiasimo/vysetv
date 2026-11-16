import 'dart:async';

/// Paces requests to one service: at most [perMinute] in any minute, at least [spacing] apart,
/// one at a time when [serial], and nothing at all while the service has asked us to wait.
class RateGate {
  RateGate({this.perMinute, this.spacing = Duration.zero, this.serial = false});

  final int? perMinute;
  final Duration spacing;
  final bool serial;

  /// What the service's own headers say the limit is (replaces [perMinute] when lower or higher).
  int? limitFromServer;

  final _starts = <DateTime>[]; // request starts within the last minute
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future<void>.value();

  /// Runs [body] when the gate allows it.
  Future<T> run<T>(Future<T> Function() body) {
    if (!serial) return _acquire().then((_) => body());
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        await _acquire();
        done.complete(await body());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// The service said to stop for a while (429 with Retry-After, a block page).
  void blockFor(Duration d) {
    final until = DateTime.now().add(d);
    if (until.isAfter(_blockedUntil)) _blockedUntil = until;
  }

  bool get blocked => _blockedUntil.isAfter(DateTime.now());

  Future<void> _acquire() async {
    while (true) {
      final now = DateTime.now();
      var wait = Duration.zero;
      if (_blockedUntil.isAfter(now)) wait = _blockedUntil.difference(now);
      final gap = now.difference(_last);
      if (gap < spacing && spacing - gap > wait) wait = spacing - gap;
      final cap = limitFromServer ?? perMinute;
      if (cap != null) {
        _starts.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
        if (_starts.length >= cap) {
          final free = _starts.first.add(const Duration(minutes: 1)).difference(now);
          if (free > wait) wait = free;
        }
      }
      if (wait <= Duration.zero) {
        _last = now;
        _starts.add(now);
        return;
      }
      await Future<void>.delayed(wait + const Duration(milliseconds: 20));
    }
  }
}

/// AniList allows 30 requests a minute (its documented 90 has been "temporarily" 30 since 2024),
/// counted for the whole app: browsing and list updates share it. 25 keeps a little headroom.
final aniListGate = RateGate(perMinute: 25);

/// Simkl allows one write a second and locks a user for 20 s while one of their writes runs;
/// one request at a time, a second apart, never trips either.
final simklGate = RateGate(spacing: const Duration(seconds: 1), serial: true);

/// Trakt allows one write a second per user (and 500 reads per 5 minutes); a little over a
/// second apart, one at a time.
final traktGate = RateGate(spacing: const Duration(milliseconds: 1100), serial: true);

/// Reads AniList's rate-limit headers so the gate follows the real limit if it changes.
void observeAniListHeaders(Map<String, String> headers) {
  final limit = int.tryParse(headers['x-ratelimit-limit'] ?? '');
  if (limit != null && limit > 0) aniListGate.limitFromServer = (limit * 0.85).floor().clamp(1, limit);
  if (headers['x-ratelimit-remaining'] == '0') {
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(reset * 1000).difference(DateTime.now());
      if (until > Duration.zero && until < const Duration(minutes: 2)) aniListGate.blockFor(until);
    }
  }
}

/// How long a 429 says to wait (Retry-After, else AniList's X-RateLimit-Reset, else a minute).
Duration retryAfter(Map<String, String> headers, {Duration fallback = const Duration(minutes: 1)}) {
  final s = int.tryParse(headers['retry-after'] ?? '');
  if (s != null) return Duration(seconds: s.clamp(1, 3600));
  final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
  if (reset != null) {
    final d = DateTime.fromMillisecondsSinceEpoch(reset * 1000).difference(DateTime.now());
    if (d > Duration.zero) return d;
  }
  return fallback;
}
