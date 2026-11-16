import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../models/music/music_track.dart';

class DeezerApiClient {
  static final DeezerApiClient instance = DeezerApiClient._internal();
  DeezerApiClient._internal();

  static const String _defaultBaseUrl = 'https://api.deezer.com';

  static const Map<String, String> _headers = {
    'Accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
  };

  Future<dynamic> _get(String path, [Map<String, dynamic>? queryParams]) async {
    String fullUrl = '$_defaultBaseUrl$path';
    if (queryParams != null && queryParams.isNotEmpty) {
      final queryString = queryParams.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}')
          .join('&');
      fullUrl += (fullUrl.contains('?') ? '&' : '?') + queryString;
    }

    try {
      final res = await http.get(Uri.parse(fullUrl), headers: _headers).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        return jsonDecode(res.body);
      }
    } catch (e) {
      debugPrint('Deezer API GET error: $e');
    }
    return null;
  }

  Future<List<MusicTrack>> getChartTracks({int limit = 50}) async {
    final data = await _get('/chart/0/tracks', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicTrack.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicAlbum>> getChartAlbums({int limit = 50}) async {
    final data = await _get('/chart/0/albums', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicAlbum.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicArtist>> getChartArtists({int limit = 50}) async {
    final data = await _get('/chart/0/artists', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicArtist.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicPlaylist>> getChartPlaylists({int limit = 50}) async {
    final data = await _get('/chart/0/playlists', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicPlaylist.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicAlbum>> getNewReleases({int limit = 50}) async {
    final data = await _get('/editorial/0/releases', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicAlbum.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicPlaylist>> getEditorialSelection({int limit = 50}) async {
    final data = await _get('/editorial/0/selection', {'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicPlaylist.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicTrack>> searchTracks(String query, {int limit = 30}) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search', {'q': query.trim(), 'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicTrack.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicArtist>> searchArtists(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search/artist', {'q': query.trim(), 'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicArtist.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicAlbum>> searchAlbums(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search/album', {'q': query.trim(), 'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicAlbum.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<List<MusicPlaylist>> searchPlaylists(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final data = await _get('/search/playlist', {'q': query.trim(), 'limit': limit});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicPlaylist.fromJson(json))
          .toList();
    }
    return [];
  }

  Future<MusicArtistDetails?> getArtistDetails(String artistId) async {
    try {
      final artistData = await _get('/artist/$artistId');
      if (artistData is! Map<String, dynamic> || artistData['id'] == null) {
        return null;
      }
      final artist = MusicArtist.fromJson(artistData);

      final topTracksFuture = _get('/artist/$artistId/top', {'limit': 50});
      final albumsFuture = _get('/artist/$artistId/albums', {'limit': 50});
      final relatedFuture = _get('/artist/$artistId/related', {'limit': 20});

      final results = await Future.wait([topTracksFuture, albumsFuture, relatedFuture]);

      List<MusicTrack> topTracks = [];
      if (results[0] is Map && results[0]['data'] is List) {
        topTracks = (results[0]['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map((json) => MusicTrack.fromJson(json))
            .toList();
      }

      List<MusicAlbum> albums = [];
      if (results[1] is Map && results[1]['data'] is List) {
        albums = (results[1]['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map((json) => MusicAlbum.fromJson(json))
            .toList();
      }

      List<MusicArtist> related = [];
      if (results[2] is Map && results[2]['data'] is List) {
        related = (results[2]['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map((json) => MusicArtist.fromJson(json))
            .toList();
      }

      return MusicArtistDetails(
        artist: artist,
        topTracks: topTracks,
        albums: albums,
        relatedArtists: related,
      );
    } catch (e) {
      debugPrint('getArtistDetails error: $e');
      return null;
    }
  }

  Future<MusicAlbumDetails?> getAlbumDetails(String albumId) async {
    try {
      final data = await _get('/album/$albumId');
      if (data is! Map<String, dynamic> || data['id'] == null) return null;

      final album = MusicAlbum.fromJson(data);
      List<MusicTrack> tracks = [];

      if (data['tracks'] is Map && data['tracks']['data'] is List) {
        tracks = (data['tracks']['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map((json) {
              final trackMap = Map<String, dynamic>.from(json);
              if (trackMap['album'] == null) {
                trackMap['album'] = {'id': album.id, 'title': album.title, 'cover_big': album.coverUrl};
              }
              return MusicTrack.fromJson(trackMap);
            })
            .toList();
      } else {
        final tracksData = await _get('/album/$albumId/tracks', {'limit': 100});
        if (tracksData is Map && tracksData['data'] is List) {
          tracks = (tracksData['data'] as List)
              .whereType<Map<String, dynamic>>()
              .map((json) {
                final trackMap = Map<String, dynamic>.from(json);
                if (trackMap['album'] == null) {
                  trackMap['album'] = {'id': album.id, 'title': album.title, 'cover_big': album.coverUrl};
                }
                return MusicTrack.fromJson(trackMap);
              })
              .toList();
        }
      }

      return MusicAlbumDetails(album: album, tracks: tracks);
    } catch (e) {
      debugPrint('getAlbumDetails error: $e');
      return null;
    }
  }

  Future<MusicPlaylistDetails?> getPlaylistDetails(String playlistId) async {
    try {
      final data = await _get('/playlist/$playlistId');
      if (data is! Map<String, dynamic> || data['id'] == null) return null;

      final playlist = MusicPlaylist.fromJson(data);
      List<MusicTrack> tracks = [];

      if (data['tracks'] is Map && data['tracks']['data'] is List) {
        tracks = (data['tracks']['data'] as List)
            .whereType<Map<String, dynamic>>()
            .map((json) => MusicTrack.fromJson(json))
            .toList();
      } else {
        final tracksData = await _get('/playlist/$playlistId/tracks', {'limit': 100});
        if (tracksData is Map && tracksData['data'] is List) {
          tracks = (tracksData['data'] as List)
              .whereType<Map<String, dynamic>>()
              .map((json) => MusicTrack.fromJson(json))
              .toList();
        }
      }

      return MusicPlaylistDetails(playlist: playlist, tracks: tracks);
    } catch (e) {
      debugPrint('getPlaylistDetails error: $e');
      return null;
    }
  }

  Future<List<MusicGenre>> getGenres() async {
    final data = await _get('/genre');
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicGenre.fromJson(json))
          .where((g) => g.id != '0')
          .toList();
    }
    return [];
  }

  Future<List<MusicArtist>> getGenreArtists(String genreId) async {
    final data = await _get('/genre/$genreId/artists', {'limit': 30});
    if (data is Map && data['data'] is List) {
      return (data['data'] as List)
          .whereType<Map<String, dynamic>>()
          .map((json) => MusicArtist.fromJson(json))
          .toList();
    }
    return [];
  }
}
