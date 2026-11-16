import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../anilist.dart' show AnimeExtras;
import '../net.dart';
import 'media_ref.dart';
import 'rate_gate.dart';
import 'remote_library.dart';
import 'token_store.dart';
import 'tracker.dart';
import 'tracker_keys.dart';

/// Trakt is full: the watchlist (or a list) hit the account's cap. Not retried.
class TraktLimitException extends TrackerSkipException {
  const TraktLimitException(super.message);
}

/// Trakt (trakt.tv): what you watch, scrobbled live, and My List as your Trakt watchlist.
///
/// Signing in is the device flow on auth.trakt.tv (no secret, no redirect). Access tokens are
/// short-lived and every refresh hands out a new refresh token and kills the old one, so only
/// one refresh ever runs and the new pair is saved before it's used. Trakt has no anime ids:
/// an anime episode goes by its TheTVDB episode id (from ani.zip), or else is skipped rather
/// than guessed.
class TraktTracker {
  static const _api = 'https://api.trakt.tv';
  static const _auth = 'https://auth.trakt.tv';
  static String get _ua => 'Lorewatch/${TrackerKeys.appVersion}';

  static Map<String, String> _headers([String? token]) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'trakt-api-key': TrackerKeys.traktClientId,
    'trakt-api-version': '2',
    'User-Agent': _ua,
    if (token != null) 'Authorization': 'Bearer $token',
  };

  // ── signing in ──

  static Future<DeviceCode> deviceCode() async {
    final r = await _post('$_auth/oauth/device/code', {'client_id': TrackerKeys.traktClientId});
    final j = _json(r);
    if (r.statusCode == 403) throw const TrackerAuthException("Trakt isn't accepting Lorewatch's app right now");
    if (r.statusCode != 200 || j is! Map || j['device_code'] is! String) throw TrackerRetryException("Trakt didn't give a code (HTTP ${r.statusCode})");
    return DeviceCode(
      deviceCode: j['device_code'] as String,
      userCode: '${j['user_code']}',
      url: Uri.parse('${j['verification_url'] ?? 'https://trakt.tv/activate'}'),
      expiresAt: DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 600)),
      interval: Duration(seconds: (j['interval'] as num?)?.toInt() ?? 5),
    );
  }

  static const _limitHint =
      'Free Trakt accounts can connect two apps. If Trakt said the limit is reached, disconnect one in your Trakt settings and try again.';

  /// Waits for the code to be approved (or declined, or expired, or [cancelled]).
  static Future<TrackerToken> waitForApproval(DeviceCode c, {required bool Function() cancelled}) async {
    var interval = c.interval;
    while (true) {
      await Future<void>.delayed(interval);
      if (cancelled()) throw const TrackerSkipException('cancelled');
      if (DateTime.now().isAfter(c.expiresAt)) throw const TrackerRetryException('The code expired. Try again.');
      final http.Response r;
      try {
        r = await _post('$_auth/oauth/device/token', {'code': c.deviceCode, 'client_id': TrackerKeys.traktClientId});
      } catch (_) {
        continue; // a blip: ask again next time round
      }
      switch (r.statusCode) {
        case 200:
          final j = _json(r);
          if (j is! Map || j['access_token'] is! String) throw const TrackerRetryException("Trakt's answer didn't make sense. Try again.");
          final t = _token(j, null);
          final name = await _userName(t).catchError((Object _) => '');
          final signedIn = TrackerToken(
            access: t.access,
            refresh: t.refresh,
            expiresAt: t.expiresAt,
            userId: '',
            userName: name,
            clientId: TrackerKeys.traktClientId,
            createdAt: t.createdAt,
          );
          await TokenStore.write(TrackerId.trakt, signedIn);
          return signedIn;
        case 400:
          continue; // waiting for you
        case 429:
          interval += const Duration(seconds: 1); // asking too often
          continue;
        case 404:
          throw const TrackerAuthException("That code isn't valid. Try again.");
        case 409:
          throw const TrackerAuthException('That code was already used. Try again.');
        case 410:
          throw const TrackerRetryException('The code expired. $_limitHint');
        case 418:
          throw const TrackerAuthException('Trakt says it was declined. $_limitHint');
        default:
          if (r.statusCode >= 500) continue;
          throw TrackerAuthException("Trakt didn't accept the sign-in (HTTP ${r.statusCode})");
      }
    }
  }

  static Future<String> _userName(TrackerToken t) async {
    final r = await _send('GET', '/users/settings', token: t);
    final j = _json(r);
    final user = j is Map ? j['user'] : null;
    if (user is! Map) return '';
    final name = '${user['name'] ?? ''}';
    return name.isNotEmpty ? name : '${user['username'] ?? ''}';
  }

  static Future<void> revoke(TrackerToken t) async {
    try {
      await _post('$_auth/oauth/revoke', {'token': t.access, 'client_id': t.clientId});
    } catch (_) {}
  }

  // ── what Lorewatch sends ──

  /// start / pause / stop. Returns the history id when Trakt recorded a watch (a stop at 80% or
  /// more); null otherwise, including a 409 (already recorded).
  static Future<int?> scrobble(String action, MediaRef ref, double progress) async {
    final target = await _target(ref, history: false);
    if (target == null) throw const TrackerSkipException('Not matched on Trakt', unmatched: true);
    final r = await _send('POST', '/scrobble/$action', body: {...target, 'progress': double.parse(progress.clamp(0, 100).toStringAsFixed(2))});
    if (r.statusCode == 409) return null;
    final j = _json(r);
    if (j is Map && j['action'] == 'scrobble') return (j['id'] as num?)?.toInt();
    return null;
  }

  /// Marks an episode or film watched at [at] (when the live stop didn't get through). The time
  /// is to the minute, which is how Trakt spots the same play sent twice.
  static Future<void> addHistory(MediaRef ref, DateTime at) async {
    final when = '${at.toUtc().toIso8601String().substring(0, 16)}:00.000Z';
    final target = await _target(ref, history: true);
    if (target == null) throw const TrackerSkipException('Not matched on Trakt', unmatched: true);
    final Map<String, dynamic> body;
    if (target['movie'] case final Map movie) {
      body = {
        'movies': [{...movie, 'watched_at': when}],
      };
    } else if (target['show'] case final Map show) {
      final ep = target['episode'] as Map;
      body = {
        'shows': [
          {
            ...show,
            'seasons': [
              {
                'number': ep['season'],
                'episodes': [{'number': ep['number'], 'watched_at': when}],
              },
            ],
          },
        ],
      };
    } else {
      body = {
        'episodes': [{...(target['episode'] as Map), 'watched_at': when}],
      };
    }
    final r = await _send('POST', '/sync/history', body: body);
    if (_onlyNotFound(_json(r), 'added')) throw const TrackerSkipException('Not on Trakt', unmatched: true);
  }

  /// My List ↔ the Trakt watchlist.
  static Future<void> watchlist(MediaRef ref, {required bool add}) async {
    final Map<String, dynamic> body;
    if (ref.kind == MediaKind.anime) {
      if (ref.film || ref.anilist == null) throw const TrackerSkipException('Not matched on Trakt', unmatched: true);
      final x = await AnimeExtras.of(ref.anilist!);
      if (x.tvdbId == null && x.tmdbId == null) throw const TrackerSkipException('Not matched on Trakt', unmatched: true);
      body = {
        'shows': [
          {
            'ids': {'tvdb': ?x.tvdbId, 'tmdb': ?x.tmdbId},
          },
        ],
      };
    } else {
      body = {
        ref.kind == MediaKind.movie ? 'movies' : 'shows': [_item(ref)],
      };
    }
    final r = await _send('POST', add ? '/sync/watchlist' : '/sync/watchlist/remove', body: body);
    if (add && _onlyNotFound(_json(r), 'added')) throw const TrackerSkipException('Not on Trakt', unmatched: true);
  }

  /// Removed from History here (with that switch on): only the plays Lorewatch itself recorded on
  /// Trakt go, never ones from other apps or the website.
  static Future<void> removePlays(String mediaKey) async {
    final ids = await _takePlays(mediaKey);
    if (ids.isEmpty) return;
    await _send('POST', '/sync/history/remove', body: {'ids': ids});
  }

  // ── plays Lorewatch recorded (so History removals can take off exactly those) ──

  static const _playsKey = 'trackers.trakt.plays';

  static Future<void> rememberPlay(String mediaKey, int historyId) async {
    final p = await SharedPreferences.getInstance();
    final all = _plays(p);
    (all[mediaKey] ??= []).add(historyId);
    // keep the newest few thousand
    while (all.values.fold<int>(0, (n, l) => n + l.length) > 3000 && all.isNotEmpty) {
      all.remove(all.keys.first);
    }
    await p.setString(_playsKey, json.encode(all));
  }

  static Future<List<int>> _takePlays(String mediaKey) async {
    final p = await SharedPreferences.getInstance();
    final all = _plays(p);
    final ids = all.remove(mediaKey) ?? const <int>[];
    await p.setString(_playsKey, json.encode(all));
    return ids;
  }

  static Map<String, List<int>> _plays(SharedPreferences p) {
    try {
      final j = json.decode(p.getString(_playsKey) ?? '{}') as Map<String, dynamic>;
      return {for (final e in j.entries) e.key: [for (final v in e.value as List) (v as num).toInt()]};
    } catch (_) {
      return {};
    }
  }

  // ── matching ──

  static Map<String, dynamic> _item(MediaRef ref) => {
    if (ref.title.isNotEmpty) 'title': ref.title,
    'year': ?ref.year,
    'ids': {'tmdb': ?ref.tmdb},
  };

  /// What to name the item as on Trakt: a film, a show's episode (TMDB numbering, which Trakt
  /// uses), or an anime episode by its TheTVDB id (by absolute number for live scrobbles when
  /// there's no id). Null: no safe match.
  static Future<Map<String, dynamic>?> _target(MediaRef ref, {required bool history}) async {
    switch (ref.kind) {
      case MediaKind.movie:
        return {'movie': _item(ref)};
      case MediaKind.show:
        return {
          'show': _item(ref),
          'episode': {'season': ref.season, 'number': ref.episode},
        };
      case MediaKind.anime:
        if (ref.film || ref.anilist == null) return null; // ani.zip doesn't say whether its TMDB id is a film's
        final x = await AnimeExtras.of(ref.anilist!);
        final e = x.episodes[ref.episode ?? 1];
        if (e?.tvdbId != null) {
          return {
            'episode': {
              'ids': {'tvdb': e!.tvdbId},
            },
          };
        }
        if (history || e?.absolute == null || (x.tvdbId == null && x.tmdbId == null)) return null;
        return {
          'show': {
            'ids': {'tvdb': ?x.tvdbId, 'tmdb': ?x.tmdbId},
          },
          'episode': {'number_abs': e!.absolute},
        };
    }
  }

  /// Nothing was added and something came back as not found.
  static bool _onlyNotFound(Object? j, String key) {
    if (j is! Map) return false;
    final added = j[key];
    final anyAdded = added is Map && added.values.any((v) => v is num && v > 0);
    final nf = j['not_found'];
    return !anyAdded && nf is Map && nf.values.any((v) => v is List && v.isNotEmpty);
  }

  // ── tokens ──

  static TrackerToken _token(Map j, TrackerToken? old) {
    final created = (j['created_at'] as num?)?.toInt();
    final issued = created != null ? DateTime.fromMillisecondsSinceEpoch(created * 1000) : DateTime.now();
    final secs = (j['expires_in'] as num?)?.toInt();
    return TrackerToken(
      access: j['access_token'] as String,
      refresh: j['refresh_token'] as String?,
      expiresAt: secs == null ? null : issued.add(Duration(seconds: secs)),
      userId: old?.userId ?? '',
      userName: old?.userName ?? '',
      clientId: old?.clientId ?? TrackerKeys.traktClientId,
      createdAt: issued, // when this access token was issued (for refreshing at 75% of its life)
    );
  }

  static Future<TrackerToken>? _refreshing;

  /// Single flight: Trakt's refresh tokens are single-use, and sending an old one again can end
  /// the whole sign-in. The new pair is saved before anything uses it.
  static Future<TrackerToken> _refresh(TrackerToken old) => _refreshing ??= () async {
    try {
      final rt = old.refresh;
      if (rt == null) throw const TrackerAuthException('Trakt sign-in expired');
      final r = await _post('$_auth/oauth/token', {
        'refresh_token': rt,
        'client_id': old.clientId,
        'redirect_uri': TrackerKeys.traktRedirectUri,
        'grant_type': 'refresh_token',
      });
      final j = _json(r);
      if (r.statusCode == 200 && j is Map && j['access_token'] is String) {
        final next = _token(j, old);
        await TokenStore.write(TrackerId.trakt, next);
        return next;
      }
      if (r.statusCode >= 500 || r.statusCode == 429) throw const TrackerRetryException('Trakt is unavailable');
      throw const TrackerAuthException('Trakt sign-in expired'); // 400 / 401 invalid_grant
    } finally {
      _refreshing = null;
    }
  }();

  static Future<TrackerToken> _current() async {
    final t = await TokenStore.read(TrackerId.trakt);
    if (t == null) throw const TrackerAuthException('Not signed in to Trakt');
    final end = t.expiresAt;
    if (t.refresh != null && end != null) {
      final life = end.difference(t.createdAt);
      final left = end.difference(DateTime.now());
      if (left < life * 0.25 || left < const Duration(minutes: 10)) return _refresh(t);
    }
    return t;
  }

  // ── reading your lists ──

  /// Your watchlist and, unless [watchlistOnly], your last 500 plays and your resume points.
  static Future<RemoteLibrary> library({bool watchlistOnly = false}) async {
    final watchlist = <RemoteTitle>[];
    for (var page = 1; page <= 20; page++) {
      final r = await _send('GET', '/sync/watchlist?page=$page&limit=250');
      for (final i in _rows(r)) {
        final kind = switch (i['type']) {
          'movie' => MediaKind.movie,
          'show' => MediaKind.show,
          _ => null,
        };
        if (kind != null && i[i['type']] is Map) watchlist.add(_title(kind, i[i['type']] as Map, at: asTime(i['listed_at'])));
      }
      if (page >= (asInt(r.headers['x-pagination-page-count']) ?? 1)) break;
    }
    if (watchlistOnly) return RemoteLibrary(watchlist: watchlist);

    // newest plays first, so the first one seen of each title is its latest
    final watched = <String, RemoteTitle>{};
    for (var page = 1; page <= 2; page++) {
      final r = await _send('GET', '/sync/history?page=$page&limit=250');
      for (final i in _rows(r)) {
        final at = asTime(i['watched_at']);
        if (at == null) continue;
        if (i['type'] == 'movie' && i['movie'] is Map) {
          final m = i['movie'] as Map;
          watched.putIfAbsent('m${_traktId(m)}', () => _title(MediaKind.movie, m, at: at));
        } else if (i['type'] == 'episode' && i['show'] is Map && i['episode'] is Map) {
          final show = i['show'] as Map, e = i['episode'] as Map;
          final s = asInt(e['season']), n = asInt(e['number']);
          if (s == null || n == null) continue;
          final t = watched.putIfAbsent('s${_traktId(show)}', () => _title(MediaKind.show, show, at: at, season: s, episode: n, episodes: <String>{}));
          t.episodes.add('S${s}E$n');
        }
      }
      if (page >= (asInt(r.headers['x-pagination-page-count']) ?? 1)) break;
    }

    final resume = <RemoteTitle>[];
    for (final i in _rows(await _send('GET', '/sync/playback?extended=full'))) {
      final at = asTime(i['paused_at']);
      final progress = (i['progress'] as num?)?.toDouble();
      if (at == null || progress == null) continue;
      if (i['type'] == 'movie' && i['movie'] is Map) {
        final m = i['movie'] as Map;
        resume.add(_title(MediaKind.movie, m, at: at, progress: progress, runtime: asInt(m['runtime'])));
      } else if (i['type'] == 'episode' && i['show'] is Map && i['episode'] is Map) {
        final e = i['episode'] as Map;
        resume.add(
          _title(MediaKind.show, i['show'] as Map, at: at, season: asInt(e['season']), episode: asInt(e['number']), progress: progress, runtime: asInt(e['runtime'])),
        );
      }
    }
    return RemoteLibrary(watchlist: watchlist, history: watched.values.toList(), resume: resume);
  }

  static Object? _traktId(Map m) => m['ids'] is Map ? (m['ids'] as Map)['trakt'] ?? m['title'] : m['title'];

  static RemoteTitle _title(
    MediaKind kind,
    Map m, {
    required DateTime? at,
    int? season,
    int? episode,
    double? progress,
    int? runtime,
    Set<String> episodes = const {},
  }) {
    final ids = m['ids'] is Map ? m['ids'] as Map : const {};
    return RemoteTitle(
      kind: kind,
      at: at ?? DateTime.fromMillisecondsSinceEpoch(0),
      tmdb: asInt(ids['tmdb']),
      imdb: ids['imdb']?.toString(),
      tvdb: asInt(ids['tvdb']),
      title: '${m['title'] ?? ''}',
      year: asInt(m['year']),
      season: season,
      episode: episode,
      progress: progress,
      runtime: runtime,
      episodes: episodes,
    );
  }

  static List<Map> _rows(http.Response r) {
    final j = _json(r);
    return j is List ? j.whereType<Map>().toList() : const [];
  }

  // ── requests ──

  static Object? _json(http.Response r) {
    try {
      return json.decode(r.body);
    } catch (_) {
      return null;
    }
  }

  /// The OAuth endpoints (JSON, no sign-in).
  static Future<http.Response> _post(String url, Map<String, String> body) => traktGate.run(
    () => netClient
        .post(Uri.parse(url), headers: _headers(), body: json.encode(body))
        .timeout(const Duration(seconds: 20), onTimeout: () => throw const TrackerRetryException('Trakt timed out')),
  );

  /// One signed API call, errors sorted into retry / sign in again / give up.
  static Future<http.Response> _send(String method, String path, {Object? body, TrackerToken? token, bool refreshed = false}) async {
    final t = token ?? await _current();
    final r = await traktGate.run(() {
      final req = http.Request(method, Uri.parse('$_api$path'))..headers.addAll(_headers(t.access));
      if (body != null) req.body = json.encode(body);
      return netClient
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20), onTimeout: () => throw const TrackerRetryException('Trakt timed out'));
    });
    final code = r.statusCode;
    if ((code >= 200 && code < 300) || code == 409) return r; // 409: already recorded, which is fine
    switch (code) {
      case 401:
        if (refreshed || t.refresh == null) throw const TrackerAuthException('Trakt sign-in expired');
        return _send(method, path, body: body, token: await _refresh(t), refreshed: true);
      case 403:
        // an unknown or unapproved app: nothing will work for a while
        traktGate.blockFor(const Duration(hours: 1));
        throw const TrackerRetryException("Trakt isn't accepting Lorewatch right now", after: Duration(hours: 1));
      case 404:
        throw const TrackerSkipException('Not on Trakt', unmatched: true);
      case 420:
        throw const TraktLimitException('Your Trakt watchlist is full');
      case 422:
        throw const TrackerSkipException('Trakt refused it');
      case 423:
        throw const TrackerAuthException('Your Trakt account is locked. Contact Trakt support.');
      case 426:
        throw const TrackerSkipException('That needs Trakt VIP');
      case 429:
        final wait = retryAfter(r.headers, fallback: const Duration(seconds: 30));
        traktGate.blockFor(wait);
        throw TrackerRetryException('Trakt asked to slow down', after: wait);
      default:
        if (code >= 500) throw const TrackerRetryException('Trakt is having trouble', after: Duration(seconds: 30));
        throw TrackerSkipException('Trakt refused it (HTTP $code)');
    }
  }
}
