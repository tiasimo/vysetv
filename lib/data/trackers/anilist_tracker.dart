import 'dart:async';
import 'dart:convert';

import '../net.dart';
import '../tmdb.dart' show Media;
import 'anime_rules.dart';
import 'media_ref.dart';
import 'rate_gate.dart';
import 'remote_library.dart';
import 'token_store.dart';
import 'tracker.dart';

/// AniList (anilist.co): your anime list, kept up as you watch. Signing in uses the implicit
/// grant (no secret in the app); the token lasts a year and can't be refreshed, so near the end
/// it asks you to sign in again. Every call shares the app-wide AniList pace ([aniListGate]).
class AniListTracker {
  static const _url = 'https://graphql.anilist.co';

  /// Where to send the browser. The token comes back to the app's registered Redirect URL.
  static Uri authorizeUrl(String clientId) =>
      Uri.parse('https://anilist.co/api/v2/oauth/authorize?client_id=${Uri.encodeQueryComponent(clientId)}&response_type=token');

  /// Checks a token AniList gave us and turns it into a stored sign-in.
  static Future<TrackerToken> finishSignIn(String accessToken, String clientId) async {
    final token = accessToken.trim();
    final d = await _gql(token, 'query { Viewer { id name } }');
    final v = d['Viewer'];
    if (v is! Map) throw const TrackerAuthException("AniList didn't accept that sign-in");
    return TrackerToken(
      access: token,
      userId: '${v['id']}',
      userName: '${v['name'] ?? ''}',
      clientId: clientId,
      createdAt: DateTime.now(),
      expiresAt: _expiry(token),
    );
  }

  /// Records that episode [episode] of AniList anime [mediaId] was watched to the end.
  static Future<void> applyEpisode(TrackerToken t, {required int mediaId, required int episode, bool countRewatches = false}) async {
    final d = await _gql(
      t.access,
      r'query ($id: Int) { Media(id: $id, type: ANIME) { id episodes '
      r'mediaListEntry { id status progress repeat startedAt { year } } } }',
      {'id': mediaId},
    );
    final media = d['Media'];
    if (media is! Map) throw const TrackerSkipException('Not on AniList', unmatched: true);
    final e = media['mediaListEntry'];
    final remote = e is Map
        ? RemoteEntry(
            status: _status(e['status'] as String?),
            progress: (e['progress'] as num?)?.toInt() ?? 0,
            repeat: (e['repeat'] as num?)?.toInt() ?? 0,
            started: (e['startedAt'] as Map?)?['year'] != null,
          )
        : null;
    for (final w in planUpdate(remote, episode, (media['episodes'] as num?)?.toInt(), countRewatches: countRewatches)) {
      await _gql(
        t.access,
        r'mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $repeat: Int, '
        r'$startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) { '
        r'SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, repeat: $repeat, '
        r'startedAt: $startedAt, completedAt: $completedAt) { id status progress } }',
        {
          'mediaId': mediaId,
          if (w.status != null) 'status': _statusName(w.status!),
          'progress': ?w.progress,
          'repeat': ?w.repeat,
          if (w.setStarted) 'startedAt': _today(),
          if (w.setCompleted) 'completedAt': _today(),
        },
      );
    }
  }

  /// Lorewatch: your AniList manga list (every entry, with its list), as titles for My List.
  static Future<List<({Media media, String status, DateTime added})>> mangaList() async {
    final t = await TokenStore.read(TrackerId.anilist);
    final user = int.tryParse(t?.userId ?? '');
    if (t == null || user == null) return const [];
    final out = <({Media media, String status, DateTime added})>[];
    for (var chunk = 1; chunk <= 20; chunk++) {
      final d = await _gql(
        t.access,
        r'query ($user: Int, $chunk: Int) { MediaListCollection(userId: $user, type: MANGA, chunk: $chunk, perChunk: 500) {'
        ' hasNextChunk lists { entries { status createdAt media { id title { userPreferred english romaji } '
        'coverImage { extraLarge large } bannerImage description(asHtml: false) averageScore popularity startDate { year } } } } } }',
        {'user': user, 'chunk': chunk},
      );
      final c = d['MediaListCollection'];
      if (c is! Map) break;
      for (final l in (c['lists'] as List? ?? const []).whereType<Map>()) {
        for (final e in (l['entries'] as List? ?? const []).whereType<Map>()) {
          final m = e['media'];
          if (m is! Map || m['id'] is! int) continue;
          final title = m['title'] is Map ? m['title'] as Map : const {};
          final cover = m['coverImage'] is Map ? m['coverImage'] as Map : const {};
          final year = (m['startDate'] is Map ? (m['startDate'] as Map)['year'] : null) as int?;
          out.add((
            media: Media(
              id: m['id'] as int,
              title: '${title['english'] ?? title['userPreferred'] ?? title['romaji'] ?? '?'}',
              isTv: false,
              manga: true,
              overview: '${m['description'] ?? ''}'.replaceAll(RegExp(r'<[^>]+>'), ''),
              posterPath: (cover['extraLarge'] ?? cover['large']) as String?,
              backdropPath: m['bannerImage'] as String?,
              rating: ((m['averageScore'] as num?) ?? 0) / 10,
              year: year?.toString(),
              popularity: ((m['popularity'] as num?) ?? 0).toDouble(),
            ),
            status: '${e['status'] ?? 'PLANNING'}',
            added: DateTime.fromMillisecondsSinceEpoch(((e['createdAt'] as num?) ?? 0).toInt() * 1000),
          ));
        }
      }
      if (c['hasNextChunk'] != true) break;
    }
    return out;
  }

  /// Lorewatch: puts AniList anime [mediaId] on list [status] (PLANNING, CURRENT, COMPLETED,
  /// DROPPED), as chosen in My List.
  static Future<void> setListStatus(TrackerToken t, int mediaId, String status) => _gql(
        t.access,
        r'mutation ($mediaId: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, status: $status) { id status } }',
        {'mediaId': mediaId, 'status': status},
      );

  static Future<Map<String, dynamic>> _gql(String token, String query, [Map<String, dynamic> variables = const {}]) =>
      aniListGate.run(() async {
        final r = await netClient
            .post(
              Uri.parse(_url),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: json.encode({'query': query, 'variables': variables}),
            )
            .timeout(const Duration(seconds: 20), onTimeout: () => throw const TrackerRetryException('AniList timed out'));
        observeAniListHeaders(r.headers);
        if (r.statusCode == 429) {
          final wait = retryAfter(r.headers);
          aniListGate.blockFor(wait);
          throw TrackerRetryException('AniList asked to slow down', after: wait);
        }
        if (r.statusCode >= 500) throw const TrackerRetryException('AniList is having trouble');
        Object? body;
        try {
          body = json.decode(r.body);
        } catch (_) {}
        final errors = body is Map ? body['errors'] : null;
        final message = errors is List && errors.isNotEmpty && errors.first is Map ? '${(errors.first as Map)['message']}' : '';
        if (r.statusCode == 401 || message.contains('Invalid token') || message.contains('Unauthorized')) {
          throw const TrackerAuthException('AniList sign-in expired');
        }
        if (r.statusCode == 403) {
          // the whole API switched off for a while (AniList does this under heavy load)
          aniListGate.blockFor(const Duration(minutes: 30));
          throw const TrackerRetryException('AniList is unavailable', after: Duration(minutes: 30));
        }
        if (r.statusCode != 200 || message.isNotEmpty || body is! Map || body['data'] is! Map) {
          throw TrackerSkipException(message.isEmpty ? 'AniList refused it (HTTP ${r.statusCode})' : message);
        }
        return body['data'] as Map<String, dynamic>;
      });

  /// Your whole anime list, 500 entries a request: Planning as the watchlist, anything with
  /// episodes watched (or a finished film) as history.
  static Future<RemoteLibrary> library() async {
    final t = await TokenStore.read(TrackerId.anilist);
    final user = int.tryParse(t?.userId ?? '');
    if (t == null || user == null) throw const TrackerAuthException('Not signed in to AniList');
    final watchlist = <RemoteTitle>[], history = <RemoteTitle>[], listed = <RemoteTitle>[];
    DateTime time(Object? s) => DateTime.fromMillisecondsSinceEpoch((asInt(s) ?? 0) * 1000);
    for (var chunk = 1; chunk <= 40; chunk++) {
      final d = await _gql(
        t.access,
        r'query ($user: Int, $chunk: Int) { MediaListCollection(userId: $user, type: ANIME, chunk: $chunk, perChunk: 500) {'
        ' hasNextChunk lists { entries { status progress createdAt updatedAt media { id idMal format } } } } }',
        {'user': user, 'chunk': chunk},
      );
      final c = d['MediaListCollection'];
      if (c is! Map) break;
      for (final l in ((c['lists'] as List?) ?? const []).whereType<Map>()) {
        for (final e in ((l['entries'] as List?) ?? const []).whereType<Map>()) {
          final m = e['media'];
          final id = m is Map ? asInt(m['id']) : null;
          if (id == null) continue;
          final film = (m as Map)['format'] == 'MOVIE';
          final progress = asInt(e['progress']) ?? 0;
          final created = asInt(e['createdAt']) ?? 0;
          final entry = RemoteTitle(
            kind: MediaKind.anime,
            at: time(e['status'] == 'PLANNING' && created > 0 ? created : e['updatedAt']),
            anilist: id,
            mal: asInt(m['idMal']),
            season: film ? null : 0,
            episode: film ? null : progress,
            episodes: film ? const {} : animeEpisodes(progress),
            listStatus: e['status'] as String?,
          );
          listed.add(entry);
          if (e['status'] == 'PLANNING') {
            watchlist.add(entry);
          } else if (progress > 0 || (film && e['status'] == 'COMPLETED')) {
            history.add(entry);
          }
        }
      }
      if (c['hasNextChunk'] != true) break;
    }
    return RemoteLibrary(watchlist: watchlist, history: history, listed: listed);
  }

  static ListStatus _status(String? s) => switch (s) {
    'PLANNING' => ListStatus.planning,
    'COMPLETED' => ListStatus.completed,
    'DROPPED' => ListStatus.dropped,
    'PAUSED' => ListStatus.paused,
    'REPEATING' => ListStatus.repeating,
    _ => ListStatus.current,
  };

  static String _statusName(ListStatus s) => switch (s) {
    ListStatus.current => 'CURRENT',
    ListStatus.planning => 'PLANNING',
    ListStatus.completed => 'COMPLETED',
    ListStatus.dropped => 'DROPPED',
    ListStatus.paused => 'PAUSED',
    ListStatus.repeating => 'REPEATING',
  };

  static Map<String, int> _today() {
    final n = DateTime.now();
    return {'year': n.year, 'month': n.month, 'day': n.day};
  }

  /// AniList tokens are JWTs: the expiry is in the middle part.
  static DateTime? _expiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = json.decode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      final exp = (payload['exp'] as num?)?.toInt();
      return exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (_) {
      return null;
    }
  }
}
