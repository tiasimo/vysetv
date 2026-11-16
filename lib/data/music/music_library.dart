import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/music/music_track.dart';
import '../account_sync.dart';
import 'yt_music.dart';

/// A YouTube Music song as the app's track (what the player, party and lists use).
MusicTrack ytTrack(YtItem i) => MusicTrack.fromJson({
  'id': i.videoId ?? i.id,
  'title': i.title,
  'artist': i.artistNames.isEmpty ? 'Unknown artist' : i.artistNames,
  'artistId': i.artists.where((a) => a.id.isNotEmpty).firstOrNull?.id ?? '',
  'album': i.album?.name ?? '',
  'albumId': i.album?.id ?? '',
  'coverUrl': sizedArt(i.thumb, 544),
  'durationSeconds': i.seconds,
  'explicit': i.explicit,
});

List<MusicTrack> ytTracks(Iterable<YtItem> items) => [for (final i in items) if (i.playable) ytTrack(i)];

/// A saved song back from JSON (null when it isn't one).
MusicTrack? trackFromJson(Object? j) => _track(j);

MusicTrack? _track(Object? j) {
  if (j is! Map) return null;
  try {
    final t = MusicTrack.fromJson(Map<String, dynamic>.from(j));
    return t.id.isEmpty ? null : t;
  } catch (_) {
    return null;
  }
}

/// A song you liked, and when.
class LikedSong {
  const LikedSong(this.track, this.added);
  final MusicTrack track;
  final DateTime added;
}

/// An album, artist or YouTube Music playlist you saved: what's needed to show it.
class SavedRef {
  const SavedRef({required this.id, required this.title, this.subtitle = '', this.thumb, required this.added});
  final String id;
  final String title;
  final String subtitle;
  final String? thumb;
  final DateTime added;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'sub': subtitle, 'thumb': thumb, 'a': added.millisecondsSinceEpoch, 'u': added.millisecondsSinceEpoch};
  static SavedRef? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return SavedRef(
      id: id,
      title: '${j['title'] ?? ''}',
      subtitle: '${j['sub'] ?? ''}',
      thumb: j['thumb'] as String?,
      added: DateTime.fromMillisecondsSinceEpoch((j['a'] as num?)?.toInt() ?? 0),
    );
  }
}

/// A playlist you made. Public ones show on your profile in Party.
class MyPlaylist {
  const MyPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.public = true,
    this.tracks = const [],
    this.cover,
    required this.created,
    required this.updated,
    this.owner,
  });
  final String id;
  final String name;
  final String description;
  final bool public;
  final List<MusicTrack> tracks;
  final String? cover; // a picture link; null: a mosaic of the first songs
  final DateTime created;
  final DateTime updated;

  /// Someone else's (seen on their profile), by name.
  final String? owner;

  int get seconds => tracks.fold(0, (s, t) => s + t.durationSeconds);

  /// Up to four distinct covers for the mosaic.
  List<String> get covers {
    final seen = <String>{};
    return [for (final t in tracks) if (t.coverUrl.isNotEmpty && seen.add(t.coverUrl)) t.coverUrl].take(4).toList();
  }

  MyPlaylist copyWith({String? name, String? description, bool? public, List<MusicTrack>? tracks, String? cover, bool clearCover = false}) => MyPlaylist(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    public: public ?? this.public,
    tracks: tracks ?? this.tracks,
    cover: clearCover ? null : (cover ?? this.cover),
    created: created,
    updated: DateTime.now(),
    owner: owner,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'desc': description,
    'public': public,
    'cover': cover,
    'tracks': [for (final t in tracks) t.toJson()],
    'c': created.millisecondsSinceEpoch,
    'u': updated.millisecondsSinceEpoch,
  };

  static MyPlaylist? fromJson(Map<String, dynamic> j, {String? owner}) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return MyPlaylist(
      id: id,
      name: '${j['name'] ?? 'Playlist'}',
      description: '${j['desc'] ?? ''}',
      public: j['public'] != false,
      cover: j['cover'] as String?,
      tracks: [for (final t in (j['tracks'] as List?) ?? const []) ?_track(t)],
      created: DateTime.fromMillisecondsSinceEpoch((j['c'] as num?)?.toInt() ?? 0),
      updated: DateTime.fromMillisecondsSinceEpoch((j['u'] as num?)?.toInt() ?? 0),
      owner: owner,
    );
  }
}

/// One kind of saved thing, by key, kept on the device and in step with the account.
class _Store {
  _Store(this.kind);
  final String kind;
  final items = ValueNotifier<Map<String, Map<String, dynamic>>>(const {});
  SharedPreferences? _prefs;

  String get _key => 'music.$kind';

  void load(SharedPreferences p) {
    _prefs = p;
    try {
      final raw = p.getString(_key);
      if (raw == null) return;
      items.value = {for (final e in (json.decode(raw) as Map).entries) '${e.key}': Map<String, dynamic>.from(e.value as Map)};
    } catch (_) {}
  }

  void put(String key, Map<String, dynamic> data) => _set({...items.value, key: data});
  void remove(String key) => _set({...items.value}..remove(key));

  void _set(Map<String, Map<String, dynamic>> v) {
    items.value = v;
    _prefs?.setString(_key, json.encode(v));
  }

  SyncSource get source => SyncSource(
    kind: kind,
    snapshot: () async => items.value,
    apply: (key, data) async => data == null ? remove(key) : put(key, data),
    changes: items,
    timeOf: (d) => (d['u'] as num?)?.toInt(),
  );
}

/// Your music: liked songs, playlists you made, albums and playlists you saved, artists you
/// follow, and what you played. Synced with your account; public playlists and your likes show
/// on your Party profile unless you hide your library.
class MusicLibrary {
  static final _likes = _Store('music_like');
  static final _playlists = _Store('music_pl');
  static final _albums = _Store('music_album');
  static final _artists = _Store('music_artist');
  static final _saved = _Store('music_savedpl');

  /// Fires on any change, for screens that show several kinds.
  static final Listenable changes = Listenable.merge([_likes.items, _playlists.items, _albums.items, _artists.items, _saved.items, history]);

  static final history = ValueNotifier<List<LikedSong>>(const []);
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final p = _prefs = await SharedPreferences.getInstance();
    for (final s in [_likes, _playlists, _albums, _artists, _saved]) {
      s.load(p);
    }
    try {
      final raw = p.getString('music.history');
      if (raw != null) {
        history.value = [
          for (final j in (json.decode(raw) as List).cast<Map<String, dynamic>>())
            if (_track(j['t']) case final t?) LikedSong(t, DateTime.fromMillisecondsSinceEpoch((j['a'] as num).toInt())),
        ];
      }
    } catch (_) {}
  }

  static List<SyncSource> get syncSources => [_likes.source, _playlists.source, _albums.source, _artists.source, _saved.source];

  // ── liked songs ──

  static ValueListenable<Map<String, Map<String, dynamic>>> get likesListenable => _likes.items;

  static bool isLiked(String id) => _likes.items.value.containsKey(id);

  static List<LikedSong> get likes {
    final out = [
      for (final d in _likes.items.value.values)
        if (_track(d['t']) case final t?) LikedSong(t, DateTime.fromMillisecondsSinceEpoch((d['a'] as num?)?.toInt() ?? 0)),
    ];
    out.sort((a, b) => b.added.compareTo(a.added));
    return out;
  }

  static void setLiked(MusicTrack t, bool on) {
    if (on) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _likes.put(t.id, {'t': t.toJson(), 'a': now, 'u': now});
    } else {
      _likes.remove(t.id);
    }
  }

  static bool toggleLike(MusicTrack t) {
    final on = !isLiked(t.id);
    setLiked(t, on);
    return on;
  }

  // ── your playlists ──

  static ValueListenable<Map<String, Map<String, dynamic>>> get playlistsListenable => _playlists.items;

  static List<MyPlaylist> get playlists {
    final out = [for (final d in _playlists.items.value.values) ?MyPlaylist.fromJson(d)];
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  static MyPlaylist? playlist(String id) {
    final d = _playlists.items.value[id];
    return d == null ? null : MyPlaylist.fromJson(d);
  }

  static String createPlaylist(String name, {String description = '', bool public = true, List<MusicTrack> tracks = const []}) {
    final now = DateTime.now();
    final id = 'p${now.millisecondsSinceEpoch.toRadixString(36)}${math.Random().nextInt(1 << 20).toRadixString(36)}';
    final p = MyPlaylist(id: id, name: name.trim().isEmpty ? 'New playlist' : name.trim(), description: description, public: public, tracks: _unique(tracks), created: now, updated: now);
    _playlists.put(id, p.toJson());
    return id;
  }

  static void savePlaylist(MyPlaylist p) => _playlists.put(p.id, p.toJson());

  static void deletePlaylist(String id) => _playlists.remove(id);

  /// Adds the songs that aren't in it yet; how many were added.
  static int addToPlaylist(String id, List<MusicTrack> tracks) {
    final p = playlist(id);
    if (p == null) return 0;
    final have = {for (final t in p.tracks) t.id};
    final add = [for (final t in _unique(tracks)) if (!have.contains(t.id)) t];
    if (add.isNotEmpty) savePlaylist(p.copyWith(tracks: [...p.tracks, ...add]));
    return add.length;
  }

  static void removeFromPlaylist(String id, int index) {
    final p = playlist(id);
    if (p == null || index < 0 || index >= p.tracks.length) return;
    savePlaylist(p.copyWith(tracks: [...p.tracks]..removeAt(index)));
  }

  static void reorderPlaylist(String id, int from, int to) {
    final p = playlist(id);
    if (p == null) return;
    final list = [...p.tracks];
    if (from < 0 || from >= list.length) return;
    final t = list.removeAt(from);
    list.insert(to.clamp(0, list.length), t);
    savePlaylist(p.copyWith(tracks: list));
  }

  static List<MusicTrack> _unique(Iterable<MusicTrack> t) {
    final seen = <String>{};
    return [for (final x in t) if (seen.add(x.id)) x];
  }

  // ── albums, artists and playlists you saved ──

  static List<SavedRef> _refs(_Store s) {
    final out = [for (final d in s.items.value.values) ?SavedRef.fromJson(d)];
    out.sort((a, b) => b.added.compareTo(a.added));
    return out;
  }

  static List<SavedRef> get albums => _refs(_albums);
  static List<SavedRef> get artists => _refs(_artists);
  static List<SavedRef> get savedPlaylists => _refs(_saved);

  static bool hasAlbum(String id) => _albums.items.value.containsKey(id);
  static bool follows(String id) => _artists.items.value.containsKey(id);
  static bool hasSavedPlaylist(String id) => _saved.items.value.containsKey(id);

  static bool toggleAlbum(String id, String title, {String subtitle = '', String? thumb}) => _toggle(_albums, id, title, subtitle, thumb);
  static bool toggleArtist(String id, String name, {String subtitle = '', String? thumb}) => _toggle(_artists, id, name, subtitle, thumb);
  static bool toggleSavedPlaylist(String id, String title, {String subtitle = '', String? thumb}) => _toggle(_saved, id, title, subtitle, thumb);

  static bool _toggle(_Store s, String id, String title, String subtitle, String? thumb) {
    if (s.items.value.containsKey(id)) {
      s.remove(id);
      return false;
    }
    s.put(id, SavedRef(id: id, title: title, subtitle: subtitle, thumb: thumb, added: DateTime.now()).toJson());
    return true;
  }

  // ── what you played (this device) ──

  static void recordPlay(MusicTrack t) {
    final now = DateTime.now();
    final list = [LikedSong(t, now), ...history.value.where((h) => h.track.id != t.id)].take(300).toList();
    history.value = list;
    _prefs?.setString('music.history', json.encode([for (final h in list) {'t': h.track.toJson(), 'a': h.added.millisecondsSinceEpoch}]));
    _plays++;
    _prefs?.setInt('music.plays', (_prefs?.getInt('music.plays') ?? 0) + 1);
  }

  static int _plays = 0;

  /// Songs started on this device, ever.
  static int get plays => (_prefs?.getInt('music.plays') ?? 0) + (_prefs == null ? _plays : 0);

  static void clearHistory() {
    history.value = const [];
    _prefs?.remove('music.history');
  }
}
