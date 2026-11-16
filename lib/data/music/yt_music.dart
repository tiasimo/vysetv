import 'dart:async';
import 'dart:convert';

import '../net.dart';

/// YouTube Music's own web API (the one music.youtube.com uses), for everything you browse:
/// search, home, artists, albums, playlists, charts, moods and radio. Read only, signed out.
/// Playing a song still goes through the app's audio lookup (MusicPlayer).
///
/// The response shapes follow ytmusicapi and Zuno (Apache-2.0), which read the same pages.
class YtMusic {
  YtMusic._();
  static final instance = YtMusic._();

  static const _base = 'https://music.youtube.com/youtubei/v1';
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';

  String? _visitor;
  final _cache = <String, (DateTime, Object)>{};

  /// The web client's version is the build date; a recent one is accepted.
  static String get _version {
    final d = DateTime.now().toUtc().subtract(const Duration(days: 2));
    String two(int n) => n.toString().padLeft(2, '0');
    return '1.${d.year}${two(d.month)}${two(d.day)}.01.00';
  }

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body, {String query = ''}) async {
    final res = await netClient
        .post(
          Uri.parse('$_base/$endpoint?prettyPrint=false$query'),
          headers: {
            'Content-Type': 'application/json',
            'Origin': 'https://music.youtube.com',
            'Referer': 'https://music.youtube.com/',
            'User-Agent': _ua,
            'X-Youtube-Client-Name': '67',
            'X-Youtube-Client-Version': _version,
            'X-Goog-Visitor-Id': ?_visitor,
          },
          body: json.encode({
            ...body,
            'context': {
              'client': {'clientName': 'WEB_REMIX', 'clientVersion': _version, 'hl': 'en', 'gl': 'US', 'visitorData': ?_visitor},
              'user': <String, dynamic>{},
            },
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw YtMusicError('YouTube Music answered ${res.statusCode}');
    final j = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    _visitor ??= _s(_dig(j, ['responseContext', 'visitorData']));
    return j;
  }

  /// The same answer for a few minutes, so going back is instant.
  Future<T> _cached<T extends Object>(String key, Future<T> Function() load, {Duration keep = const Duration(minutes: 10)}) async {
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < keep) return hit.$2 as T;
    final v = await load();
    _cache[key] = (DateTime.now(), v);
    if (_cache.length > 120) _cache.remove(_cache.keys.first);
    return v;
  }

  // ───────────────────────── search ─────────────────────────

  /// Everything for [query]: the top result and a shelf per kind.
  Future<YtSearch> search(String query) => _cached('s/$query', () async {
    final j = await _post('search', {'query': query});
    final sections = _dig(j, ['contents', 'tabbedSearchResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
    YtItem? top;
    final shelves = <YtShelf>[];
    for (final s in _list(sections)) {
      final card = s['musicCardShelfRenderer'];
      if (card is Map) {
        top = _cardShelf(card);
        final t = top;
        final more = [
          for (final c in _list(card['contents']))
            if (_responsive(_dig(c, ['musicResponsiveListItemRenderer'])) case final i?)
              // the top artist's own songs leave the artist out
              t != null && t.kind == YtKind.artist && i.artistNames.isEmpty ? i.withArtists([YtRef(t.id, t.title)]) : i,
        ];
        if (more.isNotEmpty) shelves.add(YtShelf(title: 'Top result', items: more));
        continue;
      }
      final shelf = s['musicShelfRenderer'];
      if (shelf is Map) {
        final title = _text(shelf['title']) ?? '';
        final items = [for (final c in _list(shelf['contents'])) ?_responsive(_dig(c, ['musicResponsiveListItemRenderer']))];
        if (items.isNotEmpty) shelves.add(YtShelf(title: title, items: items));
      }
    }
    return YtSearch(top: top, shelves: shelves);
  });

  static const _filters = {
    YtKind.song: 'EgWKAQIIAWoMEA4QChADEAQQCRAF',
    YtKind.video: 'EgWKAQIQAWoMEA4QChADEAQQCRAF',
    YtKind.album: 'EgWKAQIYAWoMEA4QChADEAQQCRAF',
    YtKind.artist: 'EgWKAQIgAWoMEA4QChADEAQQCRAF',
    YtKind.playlist: 'EgeKAQQoAEABagwQDhAKEAMQBBAJEAU%3D',
  };

  /// Just one kind (songs, albums, artists, playlists), up to about 20.
  Future<List<YtItem>> searchOnly(String query, YtKind kind) => _cached('s/${kind.name}/$query', () async {
    final j = await _post('search', {'query': query, 'params': Uri.decodeComponent(_filters[kind]!)});
    final sections = _dig(j, ['contents', 'tabbedSearchResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
    final out = <YtItem>[];
    for (final s in _list(sections)) {
      for (final c in _list(_dig(s, ['musicShelfRenderer', 'contents']))) {
        final i = _responsive(_dig(c, ['musicResponsiveListItemRenderer']));
        if (i != null) out.add(i.kind == YtKind.unknown ? i.copyAs(kind) : i);
      }
    }
    return out;
  });

  /// What people type that starts like [input].
  Future<List<String>> suggestions(String input) async {
    if (input.trim().isEmpty) return const [];
    try {
      final j = await _post('music/get_search_suggestions', {'input': input});
      final out = <String>[];
      for (final sec in _list(j['contents'])) {
        for (final c in _list(_dig(sec, ['searchSuggestionsSectionRenderer', 'contents']))) {
          final t = _text(_dig(c, ['searchSuggestionRenderer', 'suggestion']));
          if (t != null && t.isNotEmpty) out.add(t);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ───────────────────────── browse pages ─────────────────────────

  Future<Map<String, dynamic>> _browse(String browseId, {String? params}) => _post('browse', {'browseId': browseId, 'params': ?params});

  /// The home feed: Quick picks, Listen again, mixes, new releases… (a few pages of it).
  Future<YtHome> home() => _cached('home', () async {
    final j = await _browse('FEmusic_home');
    final list = _dig(j, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer']);
    final shelves = _shelves(_dig(list, ['contents']));
    final moods = <YtMood>[];
    for (final c in _list(_dig(list, ['header', 'chipCloudRenderer', 'chips']))) {
      final chip = c['chipCloudChipRenderer'];
      final title = _text(_dig(chip, ['text']));
      final ep = _dig(chip, ['navigationEndpoint', 'browseEndpoint']);
      if (title != null && ep is Map && ep['params'] != null) moods.add(YtMood(title: title, browseId: _s(ep['browseId']) ?? 'FEmusic_home', params: _s(ep['params'])));
    }
    var token = _s(_dig(list, ['continuations', 0, 'nextContinuationData', 'continuation']));
    for (var page = 0; page < 3 && token != null; page++) {
      try {
        final more = await _post('browse', {}, query: '&ctoken=$token&continuation=$token&type=next');
        final c = _dig(more, ['continuationContents', 'sectionListContinuation']);
        shelves.addAll(_shelves(_dig(c, ['contents'])));
        token = _s(_dig(c, ['continuations', 0, 'nextContinuationData', 'continuation']));
      } catch (_) {
        break;
      }
    }
    return YtHome(shelves: shelves, moods: moods);
  }, keep: const Duration(minutes: 30));

  /// A page made of shelves: a mood or genre, charts, new releases, a home chip.
  Future<List<YtShelf>> shelvesPage(String browseId, {String? params}) => _cached('p/$browseId/$params', () async {
    final j = await _browse(browseId, params: params);
    final tabs = _dig(j, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
    final out = _shelves(tabs);
    // grids (new releases, a genre's playlists)
    for (final s in _list(tabs)) {
      final grid = _dig(s, ['gridRenderer']);
      if (grid is Map) {
        final items = [for (final c in _list(grid['items'])) ?_twoRow(_dig(c, ['musicTwoRowItemRenderer']))];
        if (items.isNotEmpty) out.add(YtShelf(title: _text(_dig(grid, ['header', 'gridHeaderRenderer', 'title'])) ?? '', items: items, grid: true));
      }
    }
    return out;
  });

  /// Moods & genres: the buttons, by group ("Moods & moments", "Genres").
  Future<List<(String, List<YtMood>)>> moods() => _cached('moods', () async {
    final j = await _browse('FEmusic_moods_and_genres');
    final sections = _dig(j, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
    final out = <(String, List<YtMood>)>[];
    for (final s in _list(sections)) {
      final grid = _dig(s, ['gridRenderer']);
      if (grid is! Map) continue;
      final title = _text(_dig(grid, ['header', 'gridHeaderRenderer', 'title'])) ?? '';
      final items = <YtMood>[];
      for (final c in _list(grid['items'])) {
        final b = _dig(c, ['musicNavigationButtonRenderer']);
        final name = _text(_dig(b, ['buttonText']));
        final ep = _dig(b, ['clickCommand', 'browseEndpoint']);
        if (name == null || ep is! Map) continue;
        final color = (_dig(b, ['solid', 'leftStripeColor']) as num?)?.toInt();
        items.add(YtMood(title: name, browseId: _s(ep['browseId']) ?? '', params: _s(ep['params']), color: color));
      }
      if (items.isNotEmpty) out.add((title, items));
    }
    return out;
  }, keep: const Duration(hours: 6));

  Future<List<YtShelf>> charts() => shelvesPage('FEmusic_charts');
  Future<List<YtShelf>> newReleases() => shelvesPage('FEmusic_new_releases');

  /// An artist: their header, top songs, albums, singles, videos and who fans also like.
  Future<YtArtist> artist(String id) => _cached('a/$id', () async {
    final j = await _browse(id);
    final header = _firstOf(j['header'], ['musicImmersiveHeaderRenderer', 'musicVisualHeaderRenderer', 'musicHeaderRenderer']);
    final name = _text(_dig(header, ['title'])) ?? '';
    final thumb = _thumb(_dig(header, ['thumbnail'])) ?? _thumb(_dig(header, ['foregroundThumbnail']));
    final subs = _text(_dig(header, ['subscriptionButton', 'subscribeButtonRenderer', 'subscriberCountText'])) ??
        _text(_dig(header, ['subscriptionButton', 'subscribeButtonRenderer', 'shortSubscriberCountText']));
    final monthly = _text(_dig(header, ['monthlyListenerCount']));
    var description = _text(_dig(header, ['description'])) ?? '';
    final radio = _s(_dig(header, ['startRadioButton', 'buttonRenderer', 'navigationEndpoint', 'watchPlaylistEndpoint', 'playlistId']));
    final shuffle = _s(_dig(header, ['playButton', 'buttonRenderer', 'navigationEndpoint', 'watchPlaylistEndpoint', 'playlistId']));
    final sections = _dig(j, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
    var songs = <YtItem>[];
    String? allSongs;
    final shelves = <YtShelf>[];
    for (final s in _list(sections)) {
      final shelf = s['musicShelfRenderer'];
      if (shelf is Map) {
        songs = [for (final c in _list(shelf['contents'])) ?_responsive(_dig(c, ['musicResponsiveListItemRenderer']))];
        allSongs = _s(_dig(shelf, ['title', 'runs', 0, 'navigationEndpoint', 'browseEndpoint', 'browseId'])) ??
            _s(_dig(shelf, ['bottomEndpoint', 'browseEndpoint', 'browseId']));
        continue;
      }
      final about = s['musicDescriptionShelfRenderer'];
      if (about is Map && description.isEmpty) description = _text(about['description']) ?? '';
      final c = s['musicCarouselShelfRenderer'];
      if (c is Map) {
        final sh = _carousel(c);
        if (sh != null) shelves.add(sh);
      }
    }
    return YtArtist(
      id: id,
      name: name,
      thumb: thumb,
      subscribers: subs,
      listeners: monthly,
      description: description,
      songs: songs,
      allSongsId: allSongs,
      shelves: shelves,
      radioId: radio,
      shuffleId: shuffle,
    );
  });

  /// An album (or single, or EP) and its songs.
  Future<YtAlbum> album(String browseId) => _cached('al/$browseId', () async {
    final j = await _browse(browseId);
    final tab = _dig(j, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents', 0]);
    final h = _firstOf(tab, ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer']) ?? _firstOf(j['header'], ['musicDetailHeaderRenderer']);
    final title = _text(_dig(h, ['title'])) ?? '';
    final sub = _runs(_dig(h, ['subtitle']));
    final type = sub.isNotEmpty ? sub.first.text : 'Album';
    final year = sub.map((r) => r.text).where((t) => RegExp(r'^\d{4}$').hasMatch(t)).firstOrNull;
    var artists = [for (final r in _runs(_dig(h, ['straplineTextOne']))) if (r.artistId != null) YtRef(r.artistId!, r.text)];
    if (artists.isEmpty) artists = [for (final r in sub) if (r.artistId != null) YtRef(r.artistId!, r.text)];
    final thumb = _thumb(_dig(h, ['thumbnail']));
    final second = _text(_dig(h, ['secondSubtitle'])) ?? '';
    final description = _text(_dig(h, ['description', 'musicDescriptionShelfRenderer', 'description'])) ?? '';
    final shelf = _dig(j, ['contents', 'twoColumnBrowseResultsRenderer', 'secondaryContents', 'sectionListRenderer', 'contents', 0, 'musicShelfRenderer']);
    final playlistId = _s(_dig(shelf, ['contents', 0, 'musicResponsiveListItemRenderer', 'overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'playlistId'])) ??
        RegExp(r'list=([\w-]+)').firstMatch(_s(_dig(j, ['microformat', 'microformatDataRenderer', 'urlCanonical'])) ?? '')?[1];
    final tracks = <YtItem>[];
    for (final c in _list(_dig(shelf, ['contents']))) {
      final i = _responsive(_dig(c, ['musicResponsiveListItemRenderer']));
      if (i == null || i.videoId == null) continue;
      tracks.add(i.withAlbum(YtRef(browseId, title), thumb ?? '', artists));
    }
    final others = <YtShelf>[];
    for (final s in _list(_dig(j, ['contents', 'twoColumnBrowseResultsRenderer', 'secondaryContents', 'sectionListRenderer', 'contents']))) {
      final c = s['musicCarouselShelfRenderer'];
      if (c is Map) {
        final sh = _carousel(c);
        if (sh != null) others.add(sh);
      }
    }
    return YtAlbum(
      id: browseId,
      playlistId: playlistId,
      title: title,
      type: type,
      year: year,
      artists: artists,
      thumb: thumb,
      info: second,
      description: description,
      tracks: tracks,
      more: others,
    );
  });

  /// A playlist and its songs (all of them, page by page, up to [limit]).
  Future<YtPlaylist> playlist(String id, {int limit = 600}) => _cached('pl/$id', () async {
    final browseId = id.startsWith('VL') ? id : 'VL$id';
    final j = await _browse(browseId);
    final tab = _dig(j, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents', 0]);
    final h = _firstOf(tab, ['musicResponsiveHeaderRenderer', 'musicEditablePlaylistDetailHeaderRenderer']) ?? _firstOf(j['header'], ['musicDetailHeaderRenderer']);
    final head = h is Map && h['header'] is Map ? _firstOf(h['header'], ['musicResponsiveHeaderRenderer', 'musicDetailHeaderRenderer']) : h;
    final title = _text(_dig(head, ['title'])) ?? '';
    final author = _runs(_dig(head, ['straplineTextOne'])).map((r) => r.text).join().isNotEmpty
        ? _runs(_dig(head, ['straplineTextOne'])).map((r) => r.text).join()
        : (_s(_dig(head, ['facepile', 'avatarStackViewModel', 'text', 'content'])) ?? '');
    final sub = _text(_dig(head, ['subtitle'])) ?? '';
    final info = _text(_dig(head, ['secondSubtitle'])) ?? '';
    final description = _text(_dig(head, ['description', 'musicDescriptionShelfRenderer', 'description'])) ?? '';
    final thumb = _thumb(_dig(head, ['thumbnail']));
    final shelf = _firstOf(_dig(j, ['contents', 'twoColumnBrowseResultsRenderer', 'secondaryContents', 'sectionListRenderer', 'contents', 0]), ['musicPlaylistShelfRenderer', 'musicShelfRenderer']);
    final tracks = <YtItem>[];
    String? token;
    void take(Object? contents) {
      token = null;
      for (final c in _list(contents)) {
        final i = _responsive(_dig(c, ['musicResponsiveListItemRenderer']));
        if (i != null && i.videoId != null) tracks.add(i);
        final t = _s(_dig(c, ['continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token']));
        if (t != null) token = t;
      }
    }

    take(_dig(shelf, ['contents']));
    token ??= _s(_dig(shelf, ['continuations', 0, 'nextContinuationData', 'continuation']));
    while (token != null && tracks.length < limit) {
      try {
        final more = await _post('browse', {'continuation': token});
        final items = _dig(more, ['onResponseReceivedActions', 0, 'appendContinuationItemsAction', 'continuationItems']) ??
            _dig(more, ['continuationContents', 'musicPlaylistShelfContinuation', 'contents']);
        final before = tracks.length;
        take(items);
        if (tracks.length == before) break;
      } catch (_) {
        break;
      }
    }
    return YtPlaylist(
      id: browseId.substring(2),
      title: title,
      author: author,
      thumb: thumb,
      info: info.isNotEmpty ? info : sub,
      description: description,
      tracks: tracks,
    );
  });

  /// What plays after [videoId]: a radio of songs like it (YouTube Music's own "up next").
  Future<List<YtItem>> radio(String videoId, {String? playlistId}) => _cached('r/$videoId/$playlistId', () async {
    final j = await _post('next', {
      'videoId': videoId,
      'playlistId': playlistId ?? 'RDAMVM$videoId',
      'isAudioOnly': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      'enablePersistentPlaylistPanel': true,
    });
    final panel = _dig(j, [
      'contents', 'singleColumnMusicWatchNextResultsRenderer', 'tabbedRenderer', 'watchNextTabbedResultsRenderer', 'tabs', 0, //
      'tabRenderer', 'content', 'musicQueueRenderer', 'content', 'playlistPanelRenderer', 'contents',
    ]);
    final out = <YtItem>[];
    for (final c in _list(panel)) {
      final v = _dig(c, ['playlistPanelVideoRenderer']) ?? _dig(c, ['playlistPanelVideoWrapperRenderer', 'primaryRenderer', 'playlistPanelVideoRenderer']);
      final i = _panelVideo(v);
      if (i != null) out.add(i);
    }
    return out;
  });

  /// Plays a whole playlist the way "Shuffle" or "Radio" on an artist does.
  Future<List<YtItem>> watchPlaylist(String playlistId) => _cached('w/$playlistId', () async {
    final j = await _post('next', {'playlistId': playlistId, 'isAudioOnly': true, 'enablePersistentPlaylistPanel': true});
    final panel = _dig(j, [
      'contents', 'singleColumnMusicWatchNextResultsRenderer', 'tabbedRenderer', 'watchNextTabbedResultsRenderer', 'tabs', 0, //
      'tabRenderer', 'content', 'musicQueueRenderer', 'content', 'playlistPanelRenderer', 'contents',
    ]);
    return [for (final c in _list(panel)) ?_panelVideo(_dig(c, ['playlistPanelVideoRenderer']) ?? _dig(c, ['playlistPanelVideoWrapperRenderer', 'primaryRenderer', 'playlistPanelVideoRenderer']))];
  });

  // ───────────────────────── parsing ─────────────────────────

  List<YtShelf> _shelves(Object? contents) {
    final out = <YtShelf>[];
    for (final s in _list(contents)) {
      final c = s['musicCarouselShelfRenderer'];
      if (c is Map) {
        final sh = _carousel(c);
        if (sh != null) out.add(sh);
        continue;
      }
      final shelf = s['musicShelfRenderer'];
      if (shelf is Map) {
        final items = [for (final x in _list(shelf['contents'])) ?_responsive(_dig(x, ['musicResponsiveListItemRenderer']))];
        if (items.isNotEmpty) out.add(YtShelf(title: _text(shelf['title']) ?? '', items: items));
      }
    }
    return out;
  }

  YtShelf? _carousel(Map c) {
    final head = _dig(c, ['header', 'musicCarouselShelfBasicHeaderRenderer']);
    final title = _text(_dig(head, ['title'])) ?? '';
    final strap = _text(_dig(head, ['strapline']));
    final more = _dig(head, ['moreContentButton', 'buttonRenderer', 'navigationEndpoint', 'browseEndpoint']) ?? _dig(head, ['title', 'runs', 0, 'navigationEndpoint', 'browseEndpoint']);
    final items = <YtItem>[];
    for (final x in _list(c['contents'])) {
      final i = _twoRow(_dig(x, ['musicTwoRowItemRenderer'])) ?? _responsive(_dig(x, ['musicResponsiveListItemRenderer']));
      if (i != null) items.add(i);
    }
    if (items.isEmpty) return null;
    return YtShelf(
      title: title,
      strapline: strap,
      items: items,
      moreId: more is Map ? _s(more['browseId']) : null,
      moreParams: more is Map ? _s(more['params']) : null,
    );
  }

  YtItem? _cardShelf(Map card) {
    final title = _text(card['title']);
    if (title == null) return null;
    final ep = _dig(card, ['title', 'runs', 0, 'navigationEndpoint']);
    final sub = _runs(card['subtitle']);
    final thumb = _thumb(_dig(card, ['thumbnail']));
    final base = _fromEndpoint(ep, title, sub, thumb);
    return base;
  }

  /// A card in a carousel: an album, playlist, artist, song or video.
  YtItem? _twoRow(Object? r) {
    if (r is! Map) return null;
    final title = _text(r['title']);
    if (title == null) return null;
    final sub = _runs(r['subtitle']);
    final thumb = _thumb(_dig(r, ['thumbnailRenderer']));
    final explicit = _list(r['subtitleBadges']).any((b) => _dig(b, ['musicInlineBadgeRenderer', 'icon', 'iconType']) == 'MUSIC_EXPLICIT_BADGE');
    final i = _fromEndpoint(r['navigationEndpoint'], title, sub, thumb, explicit: explicit);
    if (i == null) return null;
    // a song card's play button knows its video
    return i;
  }

  YtItem? _fromEndpoint(Object? ep, String title, List<_Run> sub, String? thumb, {bool explicit = false}) {
    if (ep is! Map) return null;
    final watch = ep['watchEndpoint'];
    final artists = [for (final r in sub) if (r.artistId != null) YtRef(r.artistId!, r.text)];
    final album = sub.where((r) => r.albumId != null).map((r) => YtRef(r.albumId!, r.text)).firstOrNull;
    final words = sub.map((r) => r.text).where((t) => t.trim().isNotEmpty && t != ' • ').toList();
    if (watch is Map && watch['videoId'] != null) {
      final type = _s(_dig(watch, ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']));
      return YtItem(
        kind: type == 'MUSIC_VIDEO_TYPE_ATV' ? YtKind.song : (words.firstOrNull == 'Song' ? YtKind.song : YtKind.video),
        id: _s(watch['videoId'])!,
        videoId: _s(watch['videoId']),
        playlistId: _s(watch['playlistId']),
        title: title,
        artists: artists.isNotEmpty ? artists : [if (words.isNotEmpty) YtRef('', words.where((w) => w != 'Song' && w != 'Video').firstOrNull ?? '')],
        album: album,
        thumb: thumb,
        subtitle: words.join(' · '),
        explicit: explicit,
      );
    }
    final watchList = ep['watchPlaylistEndpoint'];
    if (watchList is Map && watchList['playlistId'] != null) {
      return YtItem(kind: YtKind.playlist, id: _s(watchList['playlistId'])!, title: title, thumb: thumb, subtitle: words.join(' · '), artists: artists);
    }
    final browse = ep['browseEndpoint'];
    if (browse is! Map) return null;
    final id = _s(browse['browseId']);
    if (id == null) return null;
    final page = _s(_dig(browse, ['browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']));
    final kind = switch (page) {
      'MUSIC_PAGE_TYPE_ARTIST' || 'MUSIC_PAGE_TYPE_USER_CHANNEL' || 'MUSIC_PAGE_TYPE_LIBRARY_ARTIST' => YtKind.artist,
      'MUSIC_PAGE_TYPE_ALBUM' || 'MUSIC_PAGE_TYPE_AUDIOBOOK' => YtKind.album,
      'MUSIC_PAGE_TYPE_PLAYLIST' => YtKind.playlist,
      _ => id.startsWith('UC') ? YtKind.artist : (id.startsWith('MPRE') ? YtKind.album : (id.startsWith('VL') ? YtKind.playlist : YtKind.unknown)),
    };
    final year = words.where((w) => RegExp(r'^\d{4}$').hasMatch(w)).firstOrNull;
    return YtItem(
      kind: kind,
      id: kind == YtKind.playlist && id.startsWith('VL') ? id.substring(2) : id,
      title: title,
      thumb: thumb,
      subtitle: words.join(' · '),
      artists: artists,
      year: year,
      albumType: kind == YtKind.album ? words.where((w) => w == 'Album' || w == 'Single' || w == 'EP').firstOrNull ?? 'Album' : null,
      explicit: explicit,
    );
  }

  /// A row in a list: a song (search, album, playlist, top songs) or an album, artist, playlist.
  YtItem? _responsive(Object? r) {
    if (r is! Map) return null;
    final cols = [for (final c in _list(r['flexColumns'])) _runs(_dig(c, ['musicResponsiveListItemFlexColumnRenderer', 'text']))];
    if (cols.isEmpty || cols.first.isEmpty) return null;
    final title = cols.first.map((x) => x.text).join();
    final rest = [for (final c in cols.skip(1)) ...c];
    final thumb = _thumb(_dig(r, ['thumbnail']));
    final explicit = _list(r['badges']).any((b) => _dig(b, ['musicInlineBadgeRenderer', 'icon', 'iconType']) == 'MUSIC_EXPLICIT_BADGE');
    final fixed = _text(_dig(r, ['fixedColumns', 0, 'musicResponsiveListItemFixedColumnRenderer', 'text']));
    final videoId = _s(_dig(r, ['playlistItemData', 'videoId'])) ??
        _s(_dig(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'videoId'])) ??
        _s(_dig(r, ['flexColumns', 0, 'musicResponsiveListItemFlexColumnRenderer', 'text', 'runs', 0, 'navigationEndpoint', 'watchEndpoint', 'videoId']));
    final rowBrowse = _dig(r, ['navigationEndpoint', 'browseEndpoint']);
    if (rowBrowse is Map && videoId == null) {
      return _fromEndpoint({'browseEndpoint': rowBrowse}, title, rest, thumb, explicit: explicit);
    }
    if (videoId == null) return null;
    final words = rest.map((x) => x.text).where((t) => t.trim().isNotEmpty && t != ' • ' && t != ' & ' && t != ', ').toList();
    final duration = [fixed, ...words].whereType<String>().where((t) => RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(t)).firstOrNull;
    final artists = [for (final x in rest) if (x.artistId != null) YtRef(x.artistId!, x.text)];
    final album = rest.where((x) => x.albumId != null).map((x) => YtRef(x.albumId!, x.text)).firstOrNull;
    final type = _s(_dig(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']));
    final first = words.firstOrNull;
    final kind = first == 'Video' || type == 'MUSIC_VIDEO_TYPE_UGC' || type == 'MUSIC_VIDEO_TYPE_OMV' ? YtKind.video : YtKind.song;
    // unlinked artist names (no channel), when nothing else names them
    final plain = artists.isNotEmpty
        ? artists
        : [
            for (final w in words)
              if (w != 'Song' && w != 'Video' && w != duration && !RegExp(r'(plays|views)$').hasMatch(w) && w != album?.name) YtRef('', w),
          ].take(1).toList();
    return YtItem(
      kind: kind,
      id: videoId,
      videoId: videoId,
      title: title,
      artists: plain,
      album: album,
      thumb: thumb,
      duration: duration,
      plays: words.where((w) => RegExp(r'(plays|views)$').hasMatch(w)).firstOrNull,
      subtitle: words.join(' · '),
      explicit: explicit,
    );
  }

  YtItem? _panelVideo(Object? v) {
    if (v is! Map || v['videoId'] == null) return null;
    final by = _runs(v['longBylineText']);
    final artists = [for (final r in by) if (r.artistId != null) YtRef(r.artistId!, r.text)];
    final album = by.where((r) => r.albumId != null).map((r) => YtRef(r.albumId!, r.text)).firstOrNull;
    final words = by.map((r) => r.text).where((t) => t.trim().isNotEmpty && t != ' • ').toList();
    final type = _s(_dig(v, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']));
    return YtItem(
      kind: type == 'MUSIC_VIDEO_TYPE_ATV' ? YtKind.song : YtKind.video,
      id: _s(v['videoId'])!,
      videoId: _s(v['videoId']),
      title: _text(v['title']) ?? '',
      artists: artists.isNotEmpty ? artists : [if (words.isNotEmpty) YtRef('', words.first)],
      album: album,
      thumb: _thumbList(_dig(v, ['thumbnail', 'thumbnails'])),
      duration: _text(v['lengthText']),
      explicit: _list(v['badges']).any((b) => _dig(b, ['musicInlineBadgeRenderer', 'icon', 'iconType']) == 'MUSIC_EXPLICIT_BADGE'),
    );
  }
}

class YtMusicError implements Exception {
  YtMusicError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ───────────────────────── what pages hold ─────────────────────────

enum YtKind { song, video, album, artist, playlist, unknown }

class YtRef {
  const YtRef(this.id, this.name);
  final String id;
  final String name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  static YtRef fromJson(Object? j) => YtRef('${(j as Map?)?['id'] ?? ''}', '${j?['name'] ?? ''}');
}

/// One thing on a page: a song or video (by [videoId]), or an album, artist or playlist (by [id]).
class YtItem {
  const YtItem({
    required this.kind,
    required this.id,
    required this.title,
    this.videoId,
    this.playlistId,
    this.artists = const [],
    this.album,
    this.thumb,
    this.duration,
    this.plays,
    this.subtitle = '',
    this.year,
    this.albumType,
    this.explicit = false,
  });

  final YtKind kind;
  final String id;
  final String title;
  final String? videoId;
  final String? playlistId;
  final List<YtRef> artists;
  final YtRef? album;
  final String? thumb;
  final String? duration; // '3:45'
  final String? plays; // '1.2M plays'
  final String subtitle;
  final String? year;
  final String? albumType; // Album, Single, EP
  final bool explicit;

  bool get playable => videoId != null;
  String get artistNames => artists.map((a) => a.name).where((n) => n.isNotEmpty).join(', ');

  int get seconds {
    final d = duration;
    if (d == null) return 0;
    return d.split(':').fold(0, (s, p) => s * 60 + (int.tryParse(p) ?? 0));
  }

  YtItem copyAs(YtKind k) => YtItem(
    kind: k,
    id: id,
    title: title,
    videoId: videoId,
    playlistId: playlistId,
    artists: artists,
    album: album,
    thumb: thumb,
    duration: duration,
    plays: plays,
    subtitle: subtitle,
    year: year,
    albumType: albumType,
    explicit: explicit,
  );

  YtItem withArtists(List<YtRef> a) => YtItem(
    kind: kind,
    id: id,
    title: title,
    videoId: videoId,
    playlistId: playlistId,
    artists: a,
    album: album,
    thumb: thumb,
    duration: duration,
    plays: plays,
    subtitle: subtitle,
    year: year,
    albumType: albumType,
    explicit: explicit,
  );

  /// An album's song: the album's own cover and artists when the row leaves them out.
  YtItem withAlbum(YtRef a, String cover, List<YtRef> albumArtists) => YtItem(
    kind: YtKind.song,
    id: id,
    title: title,
    videoId: videoId,
    artists: artists.any((x) => x.id.isNotEmpty) ? artists : albumArtists,
    album: a,
    thumb: thumb ?? cover,
    duration: duration,
    plays: plays,
    explicit: explicit,
  );
}

class YtShelf {
  const YtShelf({required this.title, required this.items, this.strapline, this.moreId, this.moreParams, this.grid = false});
  final String title;
  final String? strapline;
  final List<YtItem> items;
  final String? moreId;
  final String? moreParams;
  final bool grid;
}

class YtSearch {
  const YtSearch({this.top, this.shelves = const []});
  final YtItem? top;
  final List<YtShelf> shelves;
}

class YtHome {
  const YtHome({this.shelves = const [], this.moods = const []});
  final List<YtShelf> shelves;
  final List<YtMood> moods;
}

class YtMood {
  const YtMood({required this.title, required this.browseId, this.params, this.color});
  final String title;
  final String browseId;
  final String? params;
  final int? color;
}

class YtArtist {
  const YtArtist({
    required this.id,
    required this.name,
    this.thumb,
    this.subscribers,
    this.listeners,
    this.description = '',
    this.songs = const [],
    this.allSongsId,
    this.shelves = const [],
    this.radioId,
    this.shuffleId,
  });
  final String id;
  final String name;
  final String? thumb;
  final String? subscribers;
  final String? listeners;
  final String description;
  final List<YtItem> songs;
  final String? allSongsId;
  final List<YtShelf> shelves;
  final String? radioId;
  final String? shuffleId;
}

class YtAlbum {
  const YtAlbum({
    required this.id,
    required this.title,
    this.playlistId,
    this.type = 'Album',
    this.year,
    this.artists = const [],
    this.thumb,
    this.info = '',
    this.description = '',
    this.tracks = const [],
    this.more = const [],
  });
  final String id;
  final String? playlistId;
  final String title;
  final String type;
  final String? year;
  final List<YtRef> artists;
  final String? thumb;
  final String info; // '12 songs • 45 minutes'
  final String description;
  final List<YtItem> tracks;
  final List<YtShelf> more;
}

class YtPlaylist {
  const YtPlaylist({required this.id, required this.title, this.author = '', this.thumb, this.info = '', this.description = '', this.tracks = const []});
  final String id;
  final String title;
  final String author;
  final String? thumb;
  final String info;
  final String description;
  final List<YtItem> tracks;
}

// ───────────────────────── JSON helpers ─────────────────────────

dynamic _dig(Object? v, List<Object> path) {
  for (final k in path) {
    if (k is String && v is Map) {
      v = v[k];
    } else if (k is int && v is List && k >= 0 && k < v.length) {
      v = v[k];
    } else {
      return null;
    }
  }
  return v;
}

List<dynamic> _list(Object? v) => v is List ? v : const [];
String? _s(Object? v) => v is String ? v : null;

Map? _firstOf(Object? v, List<String> keys) {
  if (v is! Map) return null;
  for (final k in keys) {
    final x = v[k];
    if (x is Map) return x;
  }
  return null;
}

String? _text(Object? v) {
  if (v is! Map) return null;
  if (v['simpleText'] is String) return v['simpleText'] as String;
  final runs = v['runs'];
  if (runs is List) return runs.map((r) => r is Map ? '${r['text'] ?? ''}' : '').join();
  return null;
}

class _Run {
  const _Run(this.text, {this.artistId, this.albumId});
  final String text;
  final String? artistId;
  final String? albumId;
}

List<_Run> _runs(Object? v) {
  final out = <_Run>[];
  for (final r in _list(_dig(v, ['runs']))) {
    if (r is! Map) continue;
    final text = '${r['text'] ?? ''}';
    final b = _dig(r, ['navigationEndpoint', 'browseEndpoint']);
    String? artist, album;
    if (b is Map) {
      final id = _s(b['browseId']);
      final page = _s(_dig(b, ['browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']));
      if (page == 'MUSIC_PAGE_TYPE_ALBUM' || (page == null && (id?.startsWith('MPRE') ?? false))) {
        album = id;
      } else if (page == 'MUSIC_PAGE_TYPE_ARTIST' || page == 'MUSIC_PAGE_TYPE_USER_CHANNEL' || (page == null && (id?.startsWith('UC') ?? false))) {
        artist = id;
      }
    }
    out.add(_Run(text, artistId: artist, albumId: album));
  }
  return out;
}

/// The largest picture in a thumbnail renderer.
String? _thumb(Object? v) {
  final list = _dig(v, ['musicThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
      _dig(v, ['croppedSquareThumbnailRenderer', 'thumbnail', 'thumbnails']) ??
      _dig(v, ['thumbnails']) ??
      _dig(v, ['thumbnail', 'thumbnails']);
  return _thumbList(list);
}

String? _thumbList(Object? list) {
  final l = _list(list);
  if (l.isEmpty) return null;
  final url = _s(_dig(l.last, ['url']));
  if (url == null) return null;
  return url.startsWith('//') ? 'https:$url' : url;
}

/// The same Google picture at [size] px (they're resized on request).
String sizedArt(String? url, int size) {
  if (url == null || url.isEmpty) return '';
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    final out = url.replaceAll(RegExp(r'=w\d+-h\d+'), '=w$size-h$size').replaceAll(RegExp(r'=s\d+'), '=s$size');
    return out.contains('=w$size') || out.contains('=s$size') ? out : '$url=w$size-h$size-l90-rj';
  }
  return url;
}
