import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../net.dart';
import 'media_ref.dart';
import 'rate_gate.dart';
import 'remote_library.dart';
import 'token_store.dart';
import 'tracker.dart';
import 'tracker_keys.dart';

/// Simkl (simkl.com): what you watch, scrobbled live, and My List as its "plan to watch".
///
/// AUTH V2: the device flow (no secret, no redirect), 7-day access tokens and 180-day refresh
/// tokens that stay the same. Every request carries client_id, app-name and app-version in the
/// URL, as Simkl requires. Each user has a daily allowance (500 on a free account) shared by all
/// their Simkl apps, and an app that keeps going over it is cut off for everyone, so VyseTV only
/// calls Simkl when you do something, plus one "anything new?" check at app start (at most
/// every six hours) once you've imported: never on a timer.
class SimklTracker {
  static const _api = 'https://api.simkl.com';
  static String get _ua => 'VyseTV/${TrackerKeys.appVersion} (${Platform.operatingSystem})';

  /// What's left of the user's daily allowance, from the last response (null: not known yet).
  static int? remaining;

  static Uri _u(String path, [Map<String, String> query = const {}]) => Uri.parse('$_api$path').replace(
    queryParameters: {
      ...query,
      'client_id': TrackerKeys.simklClientId,
      'app-name': TrackerKeys.appName,
      'app-version': TrackerKeys.appVersion,
    },
  );

  // ── signing in ──

  static Future<DeviceCode> deviceCode() async {
    final r = await _form('/oauth2/device', {'client_id': TrackerKeys.simklClientId, 'scope': 'media:read media:write'});
    final j = _json(r);
    if (r.statusCode != 200 || j is! Map || j['device_code'] is! String) throw TrackerRetryException(_error(j, "Simkl didn't give a code"));
    final code = '${j['user_code']}';
    final complete = '${j['verification_uri_complete'] ?? ''}';
    return DeviceCode(
      deviceCode: j['device_code'] as String,
      userCode: code,
      url: Uri.parse(complete.isNotEmpty ? complete : 'https://simkl.com/pin?user_code=${Uri.encodeQueryComponent(code)}'),
      expiresAt: DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 900)),
      interval: Duration(seconds: (j['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// Waits for the code to be approved. Simkl never says "denied" (it just stays pending), so
  /// this stops at the code's expiry, or when [cancelled] says so.
  static Future<TrackerToken> waitForApproval(DeviceCode c, {required bool Function() cancelled}) async {
    var interval = c.interval;
    while (true) {
      await Future<void>.delayed(interval);
      if (cancelled()) throw const TrackerSkipException('cancelled');
      if (DateTime.now().isAfter(c.expiresAt)) throw const TrackerRetryException('The code expired. Try again.');
      final http.Response r;
      try {
        r = await _form('/oauth2/token', {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': TrackerKeys.simklClientId,
          'device_code': c.deviceCode,
        });
      } catch (_) {
        continue; // a blip: ask again next time round
      }
      final j = _json(r);
      final error = j is Map ? '${j['error'] ?? ''}' : '';
      if (r.statusCode == 200 && j is Map && j['access_token'] is String) {
        // without media:write Simkl silently hands out a read-only token
        if (!'${j['scope'] ?? ''}'.split(' ').contains('media:write')) {
          throw const TrackerAuthException("Simkl only allowed reading. Connect again and allow VyseTV to update your lists.");
        }
        final t = _token(j);
        final name = await _userName(t).catchError((Object _) => '');
        final signedIn = TrackerToken(
          access: t.access,
          refresh: t.refresh,
          expiresAt: t.expiresAt,
          userId: '',
          userName: name,
          clientId: TrackerKeys.simklClientId,
          createdAt: DateTime.now(),
        );
        await TokenStore.write(TrackerId.simkl, signedIn);
        return signedIn;
      }
      switch (error) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'expired_token':
          throw const TrackerRetryException('The code expired. Try again.');
        default:
          if (r.statusCode >= 500) continue;
          throw TrackerAuthException(_error(j, "Simkl didn't accept the sign-in"));
      }
    }
  }

  static Future<String> _userName(TrackerToken t) async {
    final r = await _send('GET', '/users/settings', token: t);
    final j = _json(r);
    if (j is! Map) return '';
    final user = j['user'];
    return user is Map ? '${user['name'] ?? ''}' : '';
  }

  /// Ends this device's sign-in on Simkl too (always answers 200).
  static Future<void> revoke(TrackerToken t) async {
    try {
      await _form('/oauth2/revoke', {'client_id': t.clientId, 'token': t.refresh ?? t.access});
    } catch (_) {}
  }

  // ── what VyseTV sends ──

  /// start / pause / stop. A 409 (already recorded within the hour) counts as done.
  static Future<void> scrobble(String action, MediaRef ref, double progress) async {
    final body = {..._scrobbleBody(ref), 'progress': double.parse(progress.clamp(0, 100).toStringAsFixed(2))};
    // min_progress only works in the URL: VyseTV's own "finished" point decides, not Simkl's 80%
    await _send('POST', '/scrobble/$action', body: body, query: const {'min_progress': '95'});
  }

  /// Marks an episode or film watched at [at] (when the live stop didn't get through).
  static Future<void> addHistory(MediaRef ref, DateTime at) async {
    final when = '${at.toUtc().toIso8601String().split('.').first}Z';
    final Map<String, dynamic> body = switch (ref.kind) {
      MediaKind.movie => {
        'movies': [{..._item(ref), 'watched_at': when}],
      },
      MediaKind.show => {
        'shows': [
          {
            ..._item(ref),
            'seasons': [
              {
                'number': ref.season,
                'episodes': [{'number': ref.episode, 'watched_at': when}],
              },
            ],
          },
        ],
      },
      MediaKind.anime => {
        'anime': [
          {
            ..._item(ref),
            'episodes': [{'number': ref.episode ?? 1, 'watched_at': when}],
          },
        ],
      },
    };
    final r = await _send('POST', '/sync/history', body: body);
    if (_notFound(_json(r))) throw const TrackerSkipException('Not on Simkl', unmatched: true);
  }

  /// My List add: "plan to watch", but only when the title isn't in the Simkl library at all
  /// (adding would otherwise move a Watching or Completed title back to plan to watch).
  static Future<void> listAdd(MediaRef ref) async {
    final status = await _libraryStatus(ref);
    if (status == null || status.isNotEmpty) return; // unknown to Simkl, or already in the library
    final r = await _send('POST', '/sync/add-to-list', body: {
      _plural(ref.kind): [{..._item(ref), 'to': 'plantowatch'}],
    });
    if (_notFound(_json(r))) throw const TrackerSkipException('Not on Simkl', unmatched: true);
  }

  /// My List removal: taken off Simkl only while it's still just "plan to watch" there (the
  /// removal also clears its history and rating, so never for anything watched).
  static Future<void> listRemove(MediaRef ref) async {
    if (await _libraryStatus(ref) != 'plantowatch') return;
    await _send('POST', '/sync/history/remove', body: {
      _plural(ref.kind): [_item(ref)],
    });
  }

  /// Removed from History in VyseTV (only with that switch on): its watch history on Simkl goes
  /// too.
  static Future<void> historyRemove(MediaRef ref) async {
    final status = await _libraryStatus(ref);
    if (status == null || status.isEmpty) return; // nothing there
    await _send('POST', '/sync/history/remove', body: {
      _plural(ref.kind): [_item(ref)],
    });
  }

  /// The title's status in the user's Simkl library: '' when not in it, null when Simkl doesn't
  /// know the title.
  static Future<String?> _libraryStatus(MediaRef ref) async {
    // the user's other Simkl apps share the daily allowance: keep the last of it for scrobbles
    final left = remaining;
    if (left != null && left < 50) throw const TrackerRetryException('Simkl daily limit nearly used', after: Duration(hours: 3));
    final r = await _send('POST', '/sync/watched', body: [
      {..._ids(ref), 'type': ref.kind == MediaKind.show ? 'show' : ref.kind.name},
    ]);
    final j = _json(r);
    final first = j is List && j.isNotEmpty && j.first is Map ? j.first as Map : null;
    if (first == null || first['result'] == 'not_found') return null;
    final list = first['list'];
    return list is String ? list : '';
  }

  // ── bodies ──

  static Map<String, dynamic> _ids(MediaRef ref) => {
    'ids': {
      if (ref.kind == MediaKind.anime) ...{'anilist': ?ref.anilist, 'mal': ?ref.mal} else 'tmdb': ?ref.tmdb,
    },
  };

  static Map<String, dynamic> _item(MediaRef ref) => {
    if (ref.title.isNotEmpty) 'title': ref.title,
    'year': ?ref.year,
    ..._ids(ref),
  };

  static String _plural(MediaKind k) => switch (k) {
    MediaKind.movie => 'movies',
    MediaKind.show => 'shows',
    MediaKind.anime => 'anime',
  };

  /// One of movie / show + episode / anime + episode (anime: AniList and MAL ids with the
  /// episode counted straight through, no season — what Simkl recommends for anime apps).
  static Map<String, dynamic> _scrobbleBody(MediaRef ref) => switch (ref.kind) {
    MediaKind.movie => {'movie': _item(ref)},
    MediaKind.show => {
      'show': _item(ref),
      'episode': {'season': ref.season, 'number': ref.episode},
    },
    MediaKind.anime => {
      'anime': _item(ref),
      'episode': {'number': ref.episode ?? 1},
    },
  };

  static bool _notFound(Object? j) {
    if (j is! Map) return false;
    final nf = j['not_found'];
    if (nf is! Map) return false;
    final added = j['added'];
    final anyAdded = added is Map && added.values.any((v) => (v is num && v > 0) || (v is List && v.isNotEmpty));
    return !anyAdded && nf.values.any((v) => v is List && v.isNotEmpty);
  }

  // ── reading your lists ──

  /// Your whole library and your resume points: five calls. [RemoteLibrary.cursor] is Simkl's
  /// activity time from before the read, for asking later what changed since.
  static Future<RemoteLibrary> library() async {
    final cursor = await _activity();
    final watchlist = <RemoteTitle>[], history = <RemoteTitle>[], resume = <RemoteTitle>[];
    for (final type in const ['movies', 'shows', 'anime']) {
      // one type at a time, as Simkl asks
      final j = _json(await _send('GET', '/sync/all-items/$type'));
      for (final i in _items(j, type)) {
        final planned = i['status'] == 'plantowatch';
        final t = _entry(type, i);
        if (t != null) (planned ? watchlist : history).add(t);
      }
    }
    final p = _json(await _send('GET', '/sync/playback'));
    for (final i in (p is List ? p : const []).whereType<Map>()) {
      final at = asTime(i['paused_at']);
      final progress = (i['progress'] as num?)?.toDouble();
      final m = i['movie'] ?? i['show'];
      if (at == null || progress == null || m is! Map) continue;
      final ids = m['ids'] is Map ? m['ids'] as Map : const {};
      final e = i['episode'] is Map ? i['episode'] as Map : null;
      if (i['type'] == 'episode' && e == null) continue;
      resume.add(RemoteTitle(
        kind: i['type'] == 'movie' ? MediaKind.movie : MediaKind.show,
        at: at,
        tmdb: asInt(ids['tmdb']),
        imdb: ids['imdb']?.toString(),
        tvdb: asInt(ids['tvdb']),
        title: '${m['title'] ?? ''}',
        season: asInt(e?['season']),
        episode: asInt(e?['number']),
        progress: progress,
      ));
    }
    return RemoteLibrary(watchlist: watchlist, history: history, resume: resume, cursor: cursor);
  }

  /// What moved onto plan to watch since [since]: one call when nothing changed, two when
  /// something did. Also says which titles left it (moved to another list), and the new cursor.
  static Future<({String? cursor, List<RemoteTitle> planned, List<RemoteTitle> moved})> changes(String since) async {
    final now = await _activity();
    if (now == null || now == since) return (cursor: now ?? since, planned: <RemoteTitle>[], moved: <RemoteTitle>[]);
    final j = _json(await _send('GET', '/sync/all-items', query: {'date_from': since}));
    final planned = <RemoteTitle>[], moved = <RemoteTitle>[];
    for (final type in const ['movies', 'shows', 'anime']) {
      for (final i in _items(j, type)) {
        final t = _entry(type, i, listed: true);
        if (t != null) (i['status'] == 'plantowatch' ? planned : moved).add(t);
      }
    }
    return (cursor: now, planned: planned, moved: moved);
  }

  static Future<String?> _activity() async {
    final j = _json(await _send('GET', '/sync/activities'));
    return j is Map && j['all'] != null ? '${j['all']}' : null;
  }

  static Iterable<Map> _items(Object? j, String type) => j is Map && j[type] is List ? (j[type] as List).whereType<Map>() : const [];

  /// One library row. Watched ones are dated when last watched, planned ones when listed
  /// ([listed]: always when listed).
  static RemoteTitle? _entry(String type, Map i, {bool listed = false}) {
    final m = i['movie'] ?? i['show'] ?? i['anime'];
    if (m is! Map) return null;
    final ids = m['ids'] is Map ? m['ids'] as Map : const {};
    final planned = listed || i['status'] == 'plantowatch';
    final at = asTime(planned ? i['added_to_watchlist_at'] : i['last_watched_at']);
    if (at == null) return null;
    final kind = switch (type) {
      'movies' => MediaKind.movie,
      'shows' => MediaKind.show,
      _ => MediaKind.anime,
    };
    final film = kind == MediaKind.anime && '${i['anime_type'] ?? ''}' == 'movie';
    final last = parseEpisode(i['last_watched']);
    final count = asInt(i['watched_episodes_count']) ?? 0;
    final series = kind == MediaKind.anime && !film;
    if (!planned && series && count == 0) return null;
    return RemoteTitle(
      kind: kind,
      at: at,
      tmdb: asInt(ids['tmdb']),
      imdb: ids['imdb']?.toString(),
      tvdb: asInt(ids['tvdb']),
      anilist: asInt(ids['anilist']),
      mal: asInt(ids['mal']),
      title: '${m['title'] ?? ''}',
      year: asInt(m['year']),
      season: series ? 0 : last?.$1,
      episode: series ? count : last?.$2,
      episodes: series && !planned ? animeEpisodes(count) : const {},
    );
  }

  // ── requests ──

  static Object? _json(http.Response r) {
    try {
      return json.decode(r.body);
    } catch (_) {
      return null;
    }
  }

  static String _error(Object? j, String fallback) =>
      j is Map ? '${j['error_description'] ?? j['message'] ?? j['error'] ?? fallback}' : fallback;

  static TrackerToken _token(Map j) {
    final secs = (j['expires_in'] as num?)?.toInt();
    return TrackerToken(
      access: j['access_token'] as String,
      refresh: j['refresh_token'] as String?,
      expiresAt: secs == null ? null : DateTime.now().add(Duration(seconds: secs)),
      userId: '',
      userName: '',
      clientId: TrackerKeys.simklClientId,
      createdAt: DateTime.now(),
    );
  }

  /// The OAuth endpoints (form-encoded).
  static Future<http.Response> _form(String path, Map<String, String> form) => simklGate.run(
    () => netClient
        .post(_u(path), headers: {'User-Agent': _ua, 'Accept': 'application/json'}, body: form)
        .timeout(const Duration(seconds: 20), onTimeout: () => throw const TrackerRetryException('Simkl timed out')),
  );

  static Future<TrackerToken>? _refreshing;

  /// A new access token (single flight: a refresh cuts off the previous token, so two at once
  /// would sign each other out).
  static Future<TrackerToken> _refresh(TrackerToken old) => _refreshing ??= () async {
    try {
      final rt = old.refresh;
      if (rt == null) throw const TrackerAuthException('Simkl sign-in expired');
      final r = await _form('/oauth2/token', {'grant_type': 'refresh_token', 'client_id': old.clientId, 'refresh_token': rt});
      final j = _json(r);
      if (r.statusCode == 200 && j is Map && j['access_token'] is String) {
        final t = _token(j);
        final next = TrackerToken(
          access: t.access,
          refresh: t.refresh ?? rt, // Simkl keeps the same refresh token
          expiresAt: t.expiresAt,
          userId: old.userId,
          userName: old.userName,
          clientId: old.clientId,
          createdAt: old.createdAt,
        );
        await TokenStore.write(TrackerId.simkl, next); // saved before it's used
        return next;
      }
      if (r.statusCode >= 500 || j is! Map) throw const TrackerRetryException('Simkl is unavailable');
      throw const TrackerAuthException('Simkl sign-in expired');
    } finally {
      _refreshing = null;
    }
  }();

  static Future<TrackerToken> _current() async {
    final t = await TokenStore.read(TrackerId.simkl);
    if (t == null) throw const TrackerAuthException('Not signed in to Simkl');
    if (t.refresh != null && t.expiresWithin(const Duration(days: 1))) return _refresh(t);
    return t;
  }

  /// One signed API call, errors sorted into retry / sign in again / give up.
  static Future<http.Response> _send(String method, String path, {Object? body, Map<String, String> query = const {}, TrackerToken? token, bool refreshed = false}) async {
    final t = token ?? await _current();
    final r = await simklGate.run(() {
      final req = http.Request(method, _u(path, query))
        ..headers.addAll({
          'User-Agent': _ua,
          'Accept': 'application/json',
          'Authorization': 'Bearer ${t.access}',
          if (body != null) 'Content-Type': 'application/json',
        });
      if (body != null) req.body = json.encode(body);
      return netClient
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20), onTimeout: () => throw const TrackerRetryException('Simkl timed out'));
    });
    final left = int.tryParse(r.headers['x-ratelimit-remaining'] ?? '');
    if (left != null) remaining = left;
    final code = r.statusCode;
    if ((code >= 200 && code < 300) || code == 409) return r; // 409: already recorded, which is fine
    final j = _json(r);
    final error = j is Map ? '${j['error'] ?? ''}'.toLowerCase() : '';
    if (code == 401) {
      if (refreshed || t.refresh == null) throw const TrackerAuthException('Simkl sign-in expired');
      final fresh = await _refresh(t);
      return _send(method, path, body: body, query: query, token: fresh, refreshed: true);
    }
    if (code == 403 && error.contains('scope')) throw const TrackerAuthException('Simkl only allows reading. Connect again.');
    if (code == 400 && error.contains('rate_limit')) {
      // another write of this user's is still running on Simkl (a 20-second lock)
      throw const TrackerRetryException('Simkl is busy', after: Duration(seconds: 5));
    }
    if (code == 429) {
      if (error.contains('user_limit')) {
        final wait = retryAfter(r.headers, fallback: const Duration(hours: 1));
        simklGate.blockFor(wait);
        throw TrackerRetryException('Daily limit reached, resumes after midnight New York time', after: wait);
      }
      throw TrackerRetryException('Simkl asked to slow down', after: retryAfter(r.headers, fallback: const Duration(seconds: 2)));
    }
    if (code == 412) {
      // the app itself is being held back: stop for an hour
      simklGate.blockFor(const Duration(hours: 1));
      throw const TrackerRetryException('Simkl is refusing VyseTV for now', after: Duration(hours: 1));
    }
    if (code >= 500) throw const TrackerRetryException('Simkl is having trouble');
    if (code == 404) throw const TrackerSkipException('Not on Simkl', unmatched: true);
    throw TrackerSkipException(_error(j, 'Simkl refused it (HTTP $code)'));
  }
}
