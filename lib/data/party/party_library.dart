import '../account.dart';
import '../music/music_library.dart';
import '../tmdb.dart';

/// Someone's library as their Party profile shows it: their My List (films, shows, anime) and
/// their music (liked songs, public playlists, saved albums and playlists, followed artists).
/// The server decides who may see it (see party_library.pb.js).
class ProfileLibrary {
  const ProfileLibrary({
    this.titles = const [],
    this.likes = const [],
    this.playlists = const [],
    this.albums = const [],
    this.artists = const [],
    this.savedPlaylists = const [],
  });

  final List<SavedTitle> titles;
  final List<LikedSong> likes;
  final List<MyPlaylist> playlists;
  final List<SavedRef> albums;
  final List<SavedRef> artists;
  final List<SavedRef> savedPlaylists;

  bool get isEmpty => titles.isEmpty && likes.isEmpty && playlists.isEmpty && albums.isEmpty && artists.isEmpty && savedPlaylists.isEmpty;
  int get musicCount => likes.length + playlists.length + albums.length + artists.length + savedPlaylists.length;

  static Future<ProfileLibrary> load(String userId, {String? owner}) async {
    final j = await Account.pb.send('/api/vyse/social/library/${Uri.encodeComponent(userId)}') as Map<String, dynamic>;
    List<Map<String, dynamic>> rows(String k) => [for (final x in (j[k] as List?) ?? const []) if (x is Map) Map<String, dynamic>.from(x)];

    final titles = [for (final r in rows('titles')) ?_title(r)]..sort((a, b) => b.added.compareTo(a.added));
    final likes = [
      for (final r in rows('likes'))
        if (trackFromJson(r['t']) case final t?) LikedSong(t, DateTime.fromMillisecondsSinceEpoch((r['a'] as num?)?.toInt() ?? 0)),
    ]..sort((a, b) => b.added.compareTo(a.added));
    final playlists = [for (final r in rows('playlists')) ?MyPlaylist.fromJson(r, owner: owner)]..sort((a, b) => b.updated.compareTo(a.updated));
    List<SavedRef> refs(String k) => [for (final r in rows(k)) ?SavedRef.fromJson(r)]..sort((a, b) => b.added.compareTo(a.added));
    return ProfileLibrary(
      titles: titles,
      likes: likes,
      playlists: playlists,
      albums: refs('albums'),
      artists: refs('artists'),
      savedPlaylists: refs('savedPlaylists'),
    );
  }

  /// My List keeps {'m': media, 'a': added}.
  static SavedTitle? _title(Map<String, dynamic> j) {
    try {
      final m = Map<String, dynamic>.from(j['m'] as Map);
      final tv = m['tv'] == true;
      final date = '${m['date'] ?? ''}';
      return SavedTitle(
        Media.fromJson({...m, tv ? 'first_air_date' : 'release_date': date}, tv: tv),
        DateTime.fromMillisecondsSinceEpoch((j['a'] as num?)?.toInt() ?? 0),
      );
    } catch (_) {
      return null;
    }
  }
}
