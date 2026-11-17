import 'package:flutter/material.dart';

import '../../core/accent.dart';
import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/music/music_library.dart';
import '../../data/music/yt_music.dart';
import '../../data/music_player.dart';
import '../../models/music/music_track.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/section_chrome.dart';
import 'music_ui.dart';

// ───────────────────────── opening pages ─────────────────────────

Future<void> openYtArtist(BuildContext context, String id, {String? name, String? art}) =>
    Navigator.of(context).push(ShellRoute(child: YtArtistPage(id: id, name: name, art: art)));

Future<void> openYtAlbum(BuildContext context, String id, {String? title, String? art}) =>
    Navigator.of(context).push(ShellRoute(child: YtAlbumPage(id: id, title: title, art: art)));

Future<void> openYtPlaylist(BuildContext context, String id, {String? title, String? art}) =>
    Navigator.of(context).push(ShellRoute(child: YtPlaylistPage(id: id, title: title, art: art)));

Future<void> openMyPlaylist(BuildContext context, String id) => Navigator.of(context).push(ShellRoute(child: MyPlaylistPage(id: id)));

/// Someone else's playlist (from their Party profile): play it, or keep a copy.
Future<void> openOthersPlaylist(BuildContext context, MyPlaylist p) => Navigator.of(context).push(ShellRoute(child: MyPlaylistPage(id: p.id, other: p)));

Future<void> openLikedSongs(BuildContext context, {List<LikedSong>? of, String? owner}) =>
    Navigator.of(context).push(ShellRoute(child: LikedSongsPage(others: of, owner: owner)));

Future<void> openMusicLibrary(BuildContext context) => Navigator.of(context).push(ShellRoute(child: const MusicLibraryPage()));
Future<void> openMusicBrowse(BuildContext context, {int tab = 0}) => Navigator.of(context).push(ShellRoute(child: MusicBrowsePage(tab: tab)));
Future<void> openMusicHistory(BuildContext context) => Navigator.of(context).push(ShellRoute(child: const MusicHistoryPage()));
Future<void> openMood(BuildContext context, YtMood m) => Navigator.of(context).push(ShellRoute(child: MoodPage(mood: m)));

// ───────────────────────── artist ─────────────────────────

class YtArtistPage extends StatefulWidget {
  const YtArtistPage({super.key, required this.id, this.name, this.art});
  final String id;
  final String? name;
  final String? art;

  @override
  State<YtArtistPage> createState() => _YtArtistPageState();
}

class _YtArtistPageState extends State<YtArtistPage> {
  late Future<YtArtist> _future = YtMusic.instance.artist(widget.id);
  bool _allSongs = false;
  bool _about = false;
  String _releases = 'all';

  Future<void> _shuffle(YtArtist a) async {
    final id = a.allSongsId;
    if (id != null) {
      final p = await YtMusic.instance.playlist(id, limit: 200);
      await MusicPlayer.instance.playQueue(ytTracks(p.tracks), shuffled: true);
    } else {
      await MusicPlayer.instance.playQueue(ytTracks(a.songs), shuffled: true);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<YtArtist>(
    future: _future,
    builder: (context, snap) {
      final a = snap.data;
      final art = sizedArt(a?.thumb ?? widget.art, 600);
      return MusicPageFrame(
        art: art,
        slivers: (context, _) => [
          SliverToBoxAdapter(
            child: MusicHero(
              round: true,
              art: Artwork(url: art, circle: true),
              kind: 'Artista',
              title: a?.name ?? widget.name ?? '',
              lines: [
                if (a != null) MetaLine(parts: [(a.subscribers ?? '', null), (a.listeners ?? '', null)]),
              ],
              actions: a == null
                  ? const []
                  : [
                      PillButton(accent: accentOf(context), primary: true, icon: Icons.play_arrow_rounded, label: 'Riproduci', onTap: () => MusicPlayer.instance.playQueue(ytTracks(a.songs))),
                      PillButton(icon: Icons.shuffle_rounded, label: 'Casuale', onTap: () => _shuffle(a)),
                      if (a.songs.isNotEmpty) PillButton(icon: Icons.sensors_rounded, label: 'Radio', onTap: () => MusicPlayer.instance.startRadio(ytTrack(a.songs.first))),
                      ListenableBuilder(
                        listenable: MusicLibrary.changes,
                        builder: (context, _) {
                          final on = MusicLibrary.follows(a.id);
                          return PillButton(
                            icon: on ? Icons.how_to_reg_rounded : Icons.person_add_alt_1_rounded,
                            label: on ? 'Segui già' : 'Segui',
                            onTap: () => MusicLibrary.toggleArtist(a.id, a.name, subtitle: a.subscribers ?? '', thumb: a.thumb),
                          );
                        },
                      ),
                    ],
            ),
          ),
          if (snap.hasError)
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile caricare questo artista",
                body: 'Controlla la connessione e riprova.',
                action: ('Riprova', () => setState(() => _future = YtMusic.instance.artist(widget.id))),
              ),
            )
          else if (a == null)
            const SliverToBoxAdapter(child: RowsSkeleton(rows: 6))
          else ...[
            if (a.songs.isNotEmpty) ...[
              const SliverToBoxAdapter(child: ShelfHeader(title: 'Popolari')),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 0),
                sliver: SliverList.builder(
                  itemCount: _allSongs ? a.songs.length : a.songs.length.clamp(0, 5),
                  itemBuilder: (context, i) => _NumberedSong(item: a.songs[i], queue: a.songs, index: i),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 6, pageRight(context), 24),
                  child: Wrap(spacing: 10, children: [
                    if (a.songs.length > 5)
                      _TextLink(label: _allSongs ? 'Mostra meno' : 'Mostra altro', onTap: () => setState(() => _allSongs = !_allSongs)),
                    if (a.allSongsId != null) _TextLink(label: 'Tutti i brani', onTap: () => openYtPlaylist(context, a.allSongsId!, title: '${a.name}: tutti i brani', art: a.thumb)),
                  ]),
                ),
              ),
            ],
            ..._releasesSlivers(a),
            for (final s in a.shelves.where((s) => !_isRelease(s.title))) SliverToBoxAdapter(child: YtShelfView(shelf: s)),
            if (a.description.isNotEmpty) ...[
              const SliverToBoxAdapter(child: ShelfHeader(title: 'Informazioni')),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 20),
                  child: Pressable(
                    onTap: () => setState(() => _about = !_about),
                    builder: (context, hovered, _) => Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: VyseColors.ink.withValues(alpha: hovered ? .07 : .045),
                        border: Border.all(color: VyseColors.stroke),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (a.listeners != null) Text(a.listeners!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                        if (a.listeners != null) const SizedBox(height: 8),
                        Text(a.description, maxLines: _about ? null : 4, overflow: _about ? null : TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.5, color: Color(0xFFC3C7D4))),
                        const SizedBox(height: 6),
                        Text(_about ? 'Mostra meno' : 'Leggi di più', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: accentOf(context))),
                      ]),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      );
    },
  );

  static bool _isRelease(String t) => t == 'Albums' || t.startsWith('Singles');

  List<Widget> _releasesSlivers(YtArtist a) {
    final albums = a.shelves.where((s) => s.title == 'Albums').expand((s) => s.items).toList();
    final singles = a.shelves.where((s) => s.title.startsWith('Singles')).expand((s) => s.items).toList();
    if (albums.isEmpty && singles.isEmpty) return const [];
    final shown = switch (_releases) {
      'albums' => albums,
      'singles' => singles,
      _ => [...albums, ...singles],
    };
    final w = musicTileW(context);
    return [
      SliverToBoxAdapter(
        child: ShelfHeader(
          title: 'Uscite',
          titleWidget: Row(children: [
            const Text('Uscite', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.4)),
            const SizedBox(width: 18),
            MusicChips<String>(
              value: _releases,
              options: [('all', 'Tutti'), if (albums.isNotEmpty) ('albums', 'Albums'), if (singles.isNotEmpty) ('singles', 'Singoli ed EP')],
              onChanged: (v) => setState(() => _releases = v),
            ),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Shelf<YtItem>(
          key: ValueKey('rel/$_releases'),
          title: '',
          titleWidget: const SizedBox.shrink(),
          load: () async => shown,
          maxItems: 40,
          itemWidth: w,
          itemHeight: w + 46,
          itemBuilder: (context, i, _) => YtCard(item: i),
        ),
      ),
    ];
  }
}

class _TextLink extends StatelessWidget {
  const _TextLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: hovered ? accentOf(context) : VyseColors.textDim)),
    ),
  );
}

/// A top song: its rank, cover, title, plays and a heart.
class _NumberedSong extends StatelessWidget {
  const _NumberedSong({required this.item, required this.queue, required this.index});
  final YtItem item;
  final List<YtItem> queue;
  final int index;

  @override
  Widget build(BuildContext context) {
    final tracks = ytTracks(queue);
    final t = ytTrack(item);
    return Row(children: [
      SizedBox(width: 30, child: Text('${index + 1}', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: VyseColors.textFaint, fontWeight: FontWeight.w700))),
      Expanded(child: TrackRow(track: t, queue: tracks, index: index)),
      if (item.plays != null && !Layout.isPhone(context))
        SizedBox(
          width: 110,
          child: Text(item.plays!.replaceAll(' plays', ''), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
        ),
    ]);
  }
}

// ───────────────────────── album ─────────────────────────

class YtAlbumPage extends StatefulWidget {
  const YtAlbumPage({super.key, required this.id, this.title, this.art});
  final String id;
  final String? title;
  final String? art;

  @override
  State<YtAlbumPage> createState() => _YtAlbumPageState();
}

class _YtAlbumPageState extends State<YtAlbumPage> {
  late Future<YtAlbum> _future = YtMusic.instance.album(widget.id);

  @override
  Widget build(BuildContext context) => FutureBuilder<YtAlbum>(
    future: _future,
    builder: (context, snap) {
      final a = snap.data;
      final art = sizedArt(a?.thumb ?? widget.art, 600);
      final tracks = a == null ? const <MusicTrack>[] : ytTracks(a.tracks);
      return MusicPageFrame(
        art: art,
        slivers: (context, _) => [
          SliverToBoxAdapter(
            child: MusicHero(
              art: NetImage(url: art, fallback: Icons.album_rounded),
              kind: a?.type ?? 'Album',
              title: a?.title ?? widget.title ?? '',
              lines: [
                if (a != null)
                  MetaLine(parts: [
                    for (final r in a.artists) (r.name, r.id.isEmpty ? null : () => openYtArtist(context, r.id, name: r.name)),
                    (a.year ?? '', null),
                    (a.info.replaceAll(' • ', ' · '), null),
                  ]),
              ],
              actions: a == null
                  ? const []
                  : [
                      PillButton(accent: accentOf(context), primary: true, icon: Icons.play_arrow_rounded, label: 'Riproduci', onTap: () => MusicPlayer.instance.playQueue(tracks)),
                      PillButton(icon: Icons.shuffle_rounded, label: 'Casuale', onTap: () => MusicPlayer.instance.playQueue(tracks, shuffled: true)),
                      ListenableBuilder(
                        listenable: MusicLibrary.changes,
                        builder: (context, _) {
                          final on = MusicLibrary.hasAlbum(a.id);
                          return RoundAction(
                            icon: on ? Icons.library_add_check_rounded : Icons.library_add_rounded,
                            tooltip: on ? 'Rimuovi dalla tua libreria' : 'Salva nella tua libreria',
                            on: on,
                            onTap: () => MusicLibrary.toggleAlbum(a.id, a.title, subtitle: [a.type, a.artists.map((r) => r.name).join(', '), ?a.year].join(' · '), thumb: a.thumb),
                          );
                        },
                      ),
                      RoundAction(icon: Icons.playlist_add_rounded, tooltip: 'Aggiungi tutto a una playlist', onTap: () => showAddToPlaylist(context, tracks)),
                    ],
            ),
          ),
          if (snap.hasError)
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile caricare questo album",
                body: 'Controlla la connessione e riprova.',
                action: ('Riprova', () => setState(() => _future = YtMusic.instance.album(widget.id))),
              ),
            )
          else if (a == null)
            const SliverToBoxAdapter(child: RowsSkeleton())
          else ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 20),
              sliver: SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) => TrackRow(track: tracks[i], queue: tracks, index: i, showNumber: true, showArt: false),
              ),
            ),
            if (a.description.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 20),
                  child: Text(a.description, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.5, color: VyseColors.textDim)),
                ),
              ),
            for (final s in a.more) SliverToBoxAdapter(child: YtShelfView(shelf: s)),
          ],
        ],
      );
    },
  );
}

// ───────────────────────── YouTube Music playlist ─────────────────────────

class YtPlaylistPage extends StatefulWidget {
  const YtPlaylistPage({super.key, required this.id, this.title, this.art});
  final String id;
  final String? title;
  final String? art;

  @override
  State<YtPlaylistPage> createState() => _YtPlaylistPageState();
}

class _YtPlaylistPageState extends State<YtPlaylistPage> {
  late Future<YtPlaylist> _future = _load();
  final _filter = TextEditingController();

  Future<YtPlaylist> _load() async {
    // radio mixes (RD…) only open as a queue
    if (widget.id.startsWith('RD')) {
      final items = await YtMusic.instance.watchPlaylist(widget.id);
      return YtPlaylist(id: widget.id, title: widget.title ?? 'Mix', thumb: widget.art, info: songCount(items.length), tracks: items);
    }
    return YtMusic.instance.playlist(widget.id);
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<YtPlaylist>(
    future: _future,
    builder: (context, snap) {
      final p = snap.data;
      final art = sizedArt(p?.thumb ?? widget.art, 600);
      final tracks = p == null ? const <MusicTrack>[] : ytTracks(p.tracks);
      return MusicPageFrame(
        art: art,
        slivers: (context, _) => [
          SliverToBoxAdapter(
            child: MusicHero(
              art: NetImage(url: art, fallback: Icons.queue_music_rounded),
              kind: 'Playlist',
              title: p?.title ?? widget.title ?? '',
              lines: [
                if (p != null) MetaLine(parts: [(p.author, null), (p.info.replaceAll(' • ', ' · '), null)]),
                if (p != null && p.description.isNotEmpty)
                  Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ],
              actions: p == null
                  ? const []
                  : [
                      PillButton(accent: accentOf(context), primary: true, icon: Icons.play_arrow_rounded, label: 'Riproduci', onTap: () => MusicPlayer.instance.playQueue(tracks)),
                      PillButton(icon: Icons.shuffle_rounded, label: 'Casuale', onTap: () => MusicPlayer.instance.playQueue(tracks, shuffled: true)),
                      if (!widget.id.startsWith('RD'))
                        ListenableBuilder(
                          listenable: MusicLibrary.changes,
                          builder: (context, _) {
                            final on = MusicLibrary.hasSavedPlaylist(p.id);
                            return RoundAction(
                              icon: on ? Icons.library_add_check_rounded : Icons.library_add_rounded,
                              tooltip: on ? 'Rimuovi dalla tua libreria' : 'Salva nella tua libreria',
                              on: on,
                              onTap: () => MusicLibrary.toggleSavedPlaylist(p.id, p.title, subtitle: p.author.isNotEmpty ? p.author : songCount(tracks.length), thumb: p.thumb),
                            );
                          },
                        ),
                      RoundAction(
                        icon: Icons.copy_all_rounded,
                        tooltip: 'Copia in una tua playlist',
                        onTap: () async {
                          final id = MusicLibrary.createPlaylist(p.title, description: p.description, tracks: tracks);
                          showToast(context, Text('Copiata nelle tue playlist: ${p.title}', maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icons.playlist_add_check_rounded);
                          await openMyPlaylist(context, id);
                        },
                      ),
                    ],
            ),
          ),
          if (snap.hasError)
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile caricare questa playlist",
                body: 'Controlla la connessione e riprova.',
                action: ('Riprova', () => setState(() => _future = _load())),
              ),
            )
          else if (p == null)
            const SliverToBoxAdapter(child: RowsSkeleton())
          else
            ..._trackSlivers(context, tracks, _filter, () => setState(() {})),
        ],
      );
    },
  );
}

/// A filter box (for long lists), then the songs.
List<Widget> _trackSlivers(BuildContext context, List<MusicTrack> tracks, TextEditingController filter, VoidCallback changed) {
  final q = filter.text.trim().toLowerCase();
  final shown = q.isEmpty ? tracks : [for (final t in tracks) if ('${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)) t];
  return [
    if (tracks.length > 12)
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 12),
          child: Align(alignment: Alignment.centerLeft, child: _FilterBox(controller: filter, onChanged: changed)),
        ),
      ),
    SliverPadding(
      padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 0),
      sliver: SliverList.builder(itemCount: shown.length, itemBuilder: (context, i) => TrackRow(track: shown[i], queue: shown, index: i)),
    ),
  ];
}

class _FilterBox extends StatelessWidget {
  const _FilterBox({required this.controller, required this.onChanged, this.hint = 'Filtra'});
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 260,
    height: 38,
    child: TextField(
      controller: controller,
      onChanged: (_) => onChanged(),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: VyseColors.textFaint),
        prefixIcon: Icon(Icons.search_rounded, size: 18, color: VyseColors.textFaint),
        filled: true,
        fillColor: VyseColors.ink.withValues(alpha: .06),
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: BorderSide.none),
      ),
    ),
  );
}

// ───────────────────────── your playlists ─────────────────────────

class MyPlaylistPage extends StatefulWidget {
  const MyPlaylistPage({super.key, required this.id, this.other});
  final String id;

  /// Someone else's, read only.
  final MyPlaylist? other;

  @override
  State<MyPlaylistPage> createState() => _MyPlaylistPageState();
}

class _MyPlaylistPageState extends State<MyPlaylistPage> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _delete(MyPlaylist p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101118),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Eliminare ${p.name}?', style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Text("Viene rimossa da tutti i dispositivi in cui hai effettuato l'accesso.", style: TextStyle(color: VyseColors.textDim, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Annulla', style: TextStyle(color: VyseColors.text))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    MusicLibrary.deletePlaylist(p.id);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MusicLibrary.playlistsListenable,
    builder: (context, _, _) {
      final other = widget.other;
      final p = other ?? MusicLibrary.playlist(widget.id);
      if (p == null) {
        return const MusicPageFrame(art: null, slivers: _gone);
      }
      final mine = other == null;
      final art = p.cover ?? p.covers.firstOrNull;
      final q = _filter.text.trim().toLowerCase();
      final shown = q.isEmpty ? p.tracks : [for (final t in p.tracks) if ('${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)) t];
      return MusicPageFrame(
        art: art,
        slivers: (context, _) => [
          SliverToBoxAdapter(
            child: MusicHero(
              art: PlaylistArt(covers: p.covers, cover: p.cover, radius: 0),
              kind: mine ? (p.public ? 'Playlist pubblica' : 'Playlist privata') : 'Playlist',
              title: p.name,
              lines: [
                MetaLine(parts: [
                  if (!mine && p.owner != null) (p.owner!, null),
                  (songCount(p.tracks.length), null),
                  if (p.seconds > 0) (totalTime(p.seconds), null),
                ]),
                if (p.description.isNotEmpty)
                  Text(p.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ],
              actions: [
                PillButton(accent: accentOf(context), primary: true, icon: Icons.play_arrow_rounded, label: 'Riproduci', onTap: p.tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(p.tracks)),
                PillButton(icon: Icons.shuffle_rounded, label: 'Casuale', onTap: p.tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(p.tracks, shuffled: true)),
                if (mine) ...[
                  RoundAction(icon: Icons.edit_rounded, tooltip: 'Modifica', onTap: () => showPlaylistEditor(context, existing: p)),
                  RoundAction(icon: Icons.delete_outline_rounded, tooltip: 'Elimina', onTap: () => _delete(p)),
                ] else
                  RoundAction(
                    icon: Icons.copy_all_rounded,
                    tooltip: 'Tieni una copia',
                    onTap: () {
                      final id = MusicLibrary.createPlaylist(p.name, description: p.description, tracks: p.tracks);
                      showToast(context, Text('Copiata nelle tue playlist: ${p.name}', maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icons.playlist_add_check_rounded);
                      openMyPlaylist(context, id);
                    },
                  ),
              ],
            ),
          ),
          if (p.tracks.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.playlist_add_rounded,
                title: 'Ancora niente qui',
                body: 'Aggiungi brani dal menu di qualsiasi brano, o da un album o una playlist.',
              ),
            )
          else ...[
            if (p.tracks.length > 12)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 12),
                  child: Align(alignment: Alignment.centerLeft, child: _FilterBox(controller: _filter, onChanged: () => setState(() {}))),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 0),
              sliver: SliverList.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => Row(children: [
                  Expanded(
                    child: TrackRow(
                      track: shown[i],
                      queue: shown,
                      index: i,
                      onRemove: mine && q.isEmpty ? () => MusicLibrary.removeFromPlaylist(p.id, i) : null,
                    ),
                  ),
                  if (mine && q.isEmpty && !Layout.isPhone(context)) ...[
                    _MoveButton(icon: Icons.keyboard_arrow_up_rounded, onTap: i == 0 ? null : () => MusicLibrary.reorderPlaylist(p.id, i, i - 1)),
                    _MoveButton(icon: Icons.keyboard_arrow_down_rounded, onTap: i == shown.length - 1 ? null : () => MusicLibrary.reorderPlaylist(p.id, i, i + 1)),
                  ],
                ]),
              ),
            ),
          ],
        ],
      );
    },
  );

  static List<Widget> _gone(BuildContext context, ScrollController _) => const [
    SliverToBoxAdapter(child: EmptyState(icon: Icons.playlist_remove_rounded, title: 'Questa playlist non esiste più', body: 'È stata eliminata, forse su un altro dispositivo.')),
  ];
}

class _MoveButton extends StatelessWidget {
  const _MoveButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    iconSize: 18,
    visualDensity: VisualDensity.compact,
    color: VyseColors.textFaint,
    disabledColor: VyseColors.ink.withValues(alpha: .12),
    onPressed: onTap,
    icon: Icon(icon),
  );
}

// ───────────────────────── liked songs ─────────────────────────

class LikedSongsPage extends StatefulWidget {
  const LikedSongsPage({super.key, this.others, this.owner});

  /// Someone else's liked songs (their profile), read only.
  final List<LikedSong>? others;
  final String? owner;

  @override
  State<LikedSongsPage> createState() => _LikedSongsPageState();
}

class _LikedSongsPageState extends State<LikedSongsPage> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MusicLibrary.likesListenable,
    builder: (context, _, _) {
      final likes = widget.others ?? MusicLibrary.likes;
      final tracks = [for (final l in likes) l.track];
      final secs = tracks.fold(0, (s, t) => s + t.durationSeconds);
      return MusicPageFrame(
        art: tracks.firstOrNull?.coverUrl,
        slivers: (context, _) => [
          SliverToBoxAdapter(
            child: MusicHero(
              art: const LikedArt(radius: 0),
              kind: 'Playlist',
              title: widget.owner == null ? 'Brani preferiti' : 'I brani preferiti di ${widget.owner}',
              lines: [
                MetaLine(parts: [(songCount(tracks.length), null), if (secs > 0) (totalTime(secs), null)]),
              ],
              actions: [
                PillButton(accent: accentOf(context), primary: true, icon: Icons.play_arrow_rounded, label: 'Riproduci', onTap: tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(tracks)),
                PillButton(icon: Icons.shuffle_rounded, label: 'Casuale', onTap: tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(tracks, shuffled: true)),
                if (widget.others != null)
                  RoundAction(
                    icon: Icons.copy_all_rounded,
                    tooltip: 'Tienili come playlist',
                    onTap: () {
                      final id = MusicLibrary.createPlaylist('${widget.owner ?? 'Their'}’s likes', tracks: tracks);
                      openMyPlaylist(context, id);
                    },
                  ),
              ],
            ),
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(icon: Icons.favorite_border_rounded, title: 'Ancora nessun brano preferito', body: 'Tocca il cuore su qualsiasi brano e finisce qui, su tutti i dispositivi.'),
            )
          else
            ..._trackSlivers(context, tracks, _filter, () => setState(() {})),
        ],
      );
    },
  );
}

// ───────────────────────── library ─────────────────────────

enum _Lib { songs, albums, artists, playlists }

class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  _Lib _tab = _Lib.playlists;
  bool _az = false;
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _match(String s) {
    final q = _filter.text.trim().toLowerCase();
    return q.isEmpty || s.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicLibrary.changes,
    builder: (context, _) {
      final likes = MusicLibrary.likes;
      final albums = MusicLibrary.albums;
      final artists = MusicLibrary.artists;
      final mine = MusicLibrary.playlists;
      final saved = MusicLibrary.savedPlaylists;
      final inset = Layout.inset(context);
      final right = pageRight(context);
      final w = musicTileW(context);
      return MusicPageFrame(
        art: null,
        slivers: (context, _) => [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 16),
            sliver: SliverToBoxAdapter(
              child: MusicTitle(
                title: 'Libreria',
                subtitle: 'Quello che ti piace, salvi, crei e segui. Sincronizzato con il tuo account.',
                trailing: PillButton(icon: Icons.add_rounded, label: 'Nuova playlist', onTap: () async {
                  final id = await showPlaylistEditor(context);
                  if (id != null && context.mounted) openMyPlaylist(context, id);
                }),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 18),
            sliver: SliverToBoxAdapter(
              child: Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                MusicChips<_Lib>(
                  value: _tab,
                  options: [
                    (_Lib.playlists, 'Playlist ${mine.length + saved.length + 1}'),
                    (_Lib.songs, 'Brani ${likes.length}'),
                    (_Lib.albums, 'Album ${albums.length}'),
                    (_Lib.artists, 'Artisti ${artists.length}'),
                  ],
                  onChanged: (v) => setState(() => _tab = v),
                ),
                _FilterBox(controller: _filter, onChanged: () => setState(() {}), hint: 'Filtra la libreria'),
                MusicChips<bool>(value: _az, options: const [(false, 'Aggiunti di recente'), (true, 'A–Z')], onChanged: (v) => setState(() => _az = v)),
              ]),
            ),
          ),
          ...switch (_tab) {
            _Lib.songs => () {
              var list = [for (final l in likes) if (_match('${l.track.title} ${l.track.artist} ${l.track.album}')) l.track];
              if (_az) list = [...list]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
              if (list.isEmpty) {
                return [const SliverToBoxAdapter(child: EmptyState(icon: Icons.favorite_border_rounded, title: 'Nessun brano preferito', body: 'Tocca il cuore su un brano per tenerlo qui.'))];
              }
              return [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset - 10, 0, right - 10, 0),
                  sliver: SliverList.builder(itemCount: list.length, itemBuilder: (context, i) => TrackRow(track: list[i], queue: list, index: i, showNumber: true)),
                ),
              ];
            }(),
            _Lib.albums => _grid(
              [for (final a in _sorted(albums)) if (_match('${a.title} ${a.subtitle}')) a],
              w,
              (a) => CoverTile(
                title: a.title,
                subtitle: a.subtitle,
                cover: sizedArt(a.thumb, 400),
                onTap: () => openYtAlbum(context, a.id, title: a.title, art: a.thumb),
                onPlay: () => playYtItem(context, YtItem(kind: YtKind.album, id: a.id, title: a.title)),
              ),
              'Nessun album salvato',
              'Apri un album e tocca il pulsante Salva.',
            ),
            _Lib.artists => _grid(
              [for (final a in _sorted(artists)) if (_match(a.title)) a],
              Layout.isPhone(context) ? 120 : 150,
              (a) => YtArtistCard(item: YtItem(kind: YtKind.artist, id: a.id, title: a.title, thumb: a.thumb, subtitle: a.subtitle)),
              'Non segui ancora nessuno',
              'Segui gli artisti dalla loro pagina e compariranno qui.',
            ),
            _Lib.playlists => _grid(
              [
                null,
                for (final p in _az ? ([...mine]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))) : mine)
                  if (_match('${p.name} ${p.description}')) p,
                for (final s in _sorted(saved)) if (_match('${s.title} ${s.subtitle}')) s,
              ],
              w,
              (x) => switch (x) {
                MyPlaylist p => _MyPlaylistTile(p: p),
                SavedRef s => CoverTile(
                  title: s.title,
                  subtitle: s.subtitle,
                  cover: sizedArt(s.thumb, 400),
                  onTap: () => openYtPlaylist(context, s.id, title: s.title, art: s.thumb),
                  onPlay: () => playYtItem(context, YtItem(kind: YtKind.playlist, id: s.id, title: s.title)),
                ),
                _ => _LikedTile(count: likes.length),
              },
              '',
              '',
            ),
          },
        ],
      );
    },
  );

  List<SavedRef> _sorted(List<SavedRef> l) => _az ? ([...l]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()))) : l;

  List<Widget> _grid<T>(List<T> items, double w, Widget Function(T) tile, String empty, String body) {
    if (items.isEmpty) return [SliverToBoxAdapter(child: EmptyState(icon: Icons.library_music_outlined, title: empty, body: body))];
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 0),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: w + 20, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: (w + 20) / (w + 66)),
          itemCount: items.length,
          itemBuilder: (context, i) => FadeSlideIn(delay: Duration(milliseconds: 15 * (i % 20)), offset: 8, child: tile(items[i])),
        ),
      ),
    ];
  }
}

class _MyPlaylistTile extends StatelessWidget {
  const _MyPlaylistTile({required this.p});
  final MyPlaylist p;

  @override
  Widget build(BuildContext context) => _ArtTile(
    art: PlaylistArt(covers: p.covers, cover: p.cover, radius: 0),
    title: p.name,
    subtitle: '${songCount(p.tracks.length)}${p.public ? '' : '  ·  Private'}',
    onTap: () => openMyPlaylist(context, p.id),
    onPlay: p.tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(p.tracks),
  );
}

class _LikedTile extends StatelessWidget {
  const _LikedTile({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => _ArtTile(
    art: const LikedArt(radius: 0),
    title: 'Brani preferiti',
    subtitle: songCount(count),
    onTap: () => openLikedSongs(context),
    onPlay: count == 0 ? null : () => MusicPlayer.instance.playQueue([for (final l in MusicLibrary.likes) l.track]),
  );
}

/// A cover tile whose art is a widget (mosaics, the Liked songs heart).
class _ArtTile extends StatelessWidget {
  const _ArtTile({required this.art, required this.title, required this.subtitle, required this.onTap, this.onPlay});
  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Flexible(
      child: AspectRatio(
        aspectRatio: 1,
        child: OutlineCard(
          label: title,
          radius: 10,
          onTap: onTap,
          builder: (hovered) => Stack(fit: StackFit.expand, children: [
            art,
            if (onPlay != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: AnimatedOpacity(opacity: hovered ? 1 : 0, duration: const Duration(milliseconds: 160), child: PlayBubble(onTap: onPlay!)),
              ),
          ]),
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    const SizedBox(height: 2),
    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
  ]);
}

/// Your playlists as cards (Home, a profile).
class MyPlaylistCard extends StatelessWidget {
  const MyPlaylistCard({super.key, required this.p, this.other = false});
  final MyPlaylist p;
  final bool other;

  @override
  Widget build(BuildContext context) => _ArtTile(
    art: PlaylistArt(covers: p.covers, cover: p.cover, radius: 0),
    title: p.name,
    subtitle: songCount(p.tracks.length),
    onTap: () => other ? openOthersPlaylist(context, p) : openMyPlaylist(context, p.id),
    onPlay: p.tracks.isEmpty ? null : () => MusicPlayer.instance.playQueue(p.tracks),
  );
}

class LikedSongsCard extends StatelessWidget {
  const LikedSongsCard({super.key, required this.likes, this.owner});
  final List<LikedSong> likes;
  final String? owner;

  @override
  Widget build(BuildContext context) => _ArtTile(
    art: const LikedArt(radius: 0),
    title: owner == null ? 'Brani preferiti' : 'I loro brani preferiti',
    subtitle: songCount(likes.length),
    onTap: () => openLikedSongs(context, of: owner == null ? null : likes, owner: owner),
    onPlay: likes.isEmpty ? null : () => MusicPlayer.instance.playQueue([for (final l in likes) l.track]),
  );
}

// ───────────────────────── browse ─────────────────────────

class MusicBrowsePage extends StatefulWidget {
  const MusicBrowsePage({super.key, this.tab = 0});
  final int tab;

  @override
  State<MusicBrowsePage> createState() => _MusicBrowsePageState();
}

class _MusicBrowsePageState extends State<MusicBrowsePage> {
  late int _tab = widget.tab;
  final _charts = YtMusic.instance.charts();
  final _moods = YtMusic.instance.moods();
  final _new = YtMusic.instance.newReleases();

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final right = pageRight(context);
    return MusicPageFrame(
      art: null,
      slivers: (context, _) => [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 16),
          sliver: const SliverToBoxAdapter(child: MusicTitle(title: 'Sfoglia', subtitle: 'Classifiche, generi e stati d\'animo, e le ultime uscite')),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 20),
          sliver: SliverToBoxAdapter(
            child: MusicChips<int>(value: _tab, options: const [(0, 'Generi e stati d\'animo'), (1, 'Classifiche'), (2, 'Nuove uscite')], onChanged: (v) => setState(() => _tab = v)),
          ),
        ),
        if (_tab == 0)
          SliverToBoxAdapter(
            child: FutureBuilder<List<(String, List<YtMood>)>>(
              future: _moods,
              builder: (context, snap) {
                if (snap.hasError) return const EmptyState(icon: Icons.wifi_off_rounded, title: "Impossibile caricare gli stati d'animo", body: 'Controlla la connessione e riprova.');
                final groups = snap.data;
                if (groups == null) return const RowsSkeleton(rows: 5);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final (title, moods) in groups) ...[
                    ShelfHeader(title: title),
                    Padding(
                      padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
                      child: Wrap(spacing: 10, runSpacing: 10, children: [for (final m in moods) MoodChip(mood: m)]),
                    ),
                  ],
                ]);
              },
            ),
          )
        else
          SliverToBoxAdapter(
            child: FutureBuilder<List<YtShelf>>(
              future: _tab == 1 ? _charts : _new,
              builder: (context, snap) {
                if (snap.hasError) return const EmptyState(icon: Icons.wifi_off_rounded, title: "Impossibile caricarlo", body: 'Controlla la connessione e riprova.');
                final shelves = snap.data;
                if (shelves == null) return const RowsSkeleton(rows: 5);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final s in shelves) YtShelfView(shelf: s)]);
              },
            ),
          ),
      ],
    );
  }
}

/// A mood or genre button, with its own colour stripe.
class MoodChip extends StatelessWidget {
  const MoodChip({super.key, required this.mood});
  final YtMood mood;

  @override
  Widget build(BuildContext context) {
    final c = mood.color == null ? accentOf(context) : Color(mood.color!).withValues(alpha: 1);
    return Pressable(
      onTap: () => openMood(context, mood),
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .96 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: Layout.isPhone(context) ? 150 : 180,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: VyseColors.ink.withValues(alpha: hovered ? .11 : .06),
            border: Border.all(color: VyseColors.stroke),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(children: [
            Container(width: 5, color: c),
            const SizedBox(width: 12),
            Expanded(child: Text(mood.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
          ]),
        ),
      ),
    );
  }
}

class MoodPage extends StatelessWidget {
  const MoodPage({super.key, required this.mood});
  final YtMood mood;

  @override
  Widget build(BuildContext context) => MusicPageFrame(
    art: null,
    slivers: (context, _) => [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 12),
        sliver: SliverToBoxAdapter(child: MusicTitle(title: mood.title, subtitle: 'Playlist e brani adatti')),
      ),
      SliverToBoxAdapter(
        child: FutureBuilder<List<YtShelf>>(
          future: YtMusic.instance.shelvesPage(mood.browseId, params: mood.params),
          builder: (context, snap) {
            if (snap.hasError) return const EmptyState(icon: Icons.wifi_off_rounded, title: "Impossibile caricarlo", body: 'Controlla la connessione e riprova.');
            final shelves = snap.data;
            if (shelves == null) return const RowsSkeleton(rows: 5);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final s in shelves) YtShelfView(shelf: s)]);
          },
        ),
      ),
    ],
  );
}

// ───────────────────────── history ─────────────────────────

class MusicHistoryPage extends StatelessWidget {
  const MusicHistoryPage({super.key});

  static String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final days = today.difference(that).inDays;
    if (days == 0) return 'Oggi';
    if (days == 1) return 'Ieri';
    if (days < 7) return 'Questa settimana';
    return 'Prima';
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MusicLibrary.history,
    builder: (context, list, _) {
      final tracks = [for (final h in list) h.track];
      final groups = <String, List<int>>{};
      for (var i = 0; i < list.length; i++) {
        (groups[_day(list[i].added)] ??= []).add(i);
      }
      return MusicPageFrame(
        art: null,
        slivers: (context, _) => [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 8),
            sliver: SliverToBoxAdapter(
              child: MusicTitle(
                title: 'Cronologia',
                subtitle: 'Quello che hai ascoltato su questo dispositivo',
                trailing: list.isEmpty ? null : PillButton(icon: Icons.delete_sweep_rounded, label: 'Cancella', onTap: MusicLibrary.clearHistory),
              ),
            ),
          ),
          if (list.isEmpty)
            const SliverToBoxAdapter(child: EmptyState(icon: Icons.history_rounded, title: 'Ancora niente ascoltato', body: 'I brani che ascolti compaiono qui.'))
          else
            for (final e in groups.entries) ...[
              SliverToBoxAdapter(child: ShelfHeader(title: e.key)),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 12),
                sliver: SliverList.builder(
                  itemCount: e.value.length,
                  itemBuilder: (context, i) => TrackRow(track: tracks[e.value[i]], queue: tracks, index: e.value[i]),
                ),
              ),
            ],
        ],
      );
    },
  );
}
