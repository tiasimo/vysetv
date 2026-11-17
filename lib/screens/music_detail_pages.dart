import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/music_player.dart';
import '../models/music/music_track.dart';
import '../services/music/music_service.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/music_widgets.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'music/music_pages.dart';
import 'music_player_page.dart';

// Music is YouTube Music now: albums, playlists and artists open its pages.
Future<void> openAlbum(BuildContext context, String id, {String? title, String? cover}) => openYtAlbum(context, id, title: title, art: cover);

Future<void> openPlaylist(BuildContext context, String id, {String? title, String? cover}) => openYtPlaylist(context, id, title: title, art: cover);

Future<void> openGenre(BuildContext context, MusicGenre g) => Navigator.of(context).push(ShellRoute(
      child: MusicCollectionPage(
        kind: 'Genre',
        title: g.name,
        cover: g.pictureUrl,
        load: () async => MusicCollection(
          title: g.name,
          subtitle: 'Popolari ora',
          cover: g.pictureUrl,
          tracks: await MusicService.instance.fetchGenreTracks(g.id),
        ),
      ),
    ));

Future<void> openArtist(BuildContext context, String id, String name) => openYtArtist(context, id, name: name);

/// The full player goes over everything, rail included.
Future<void> openMusicPlayer(BuildContext context) => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 480),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, _, _) => const MusicPlayerPage(),
      transitionsBuilder: (_, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: t,
          child: SlideTransition(position: Tween(begin: const Offset(0, .08), end: Offset.zero).animate(t), child: child),
        );
      },
    ));

class MusicCollection {
  const MusicCollection({required this.title, required this.subtitle, required this.cover, required this.tracks, this.artist});
  final String title;
  final String subtitle;
  final String? cover;
  final List<MusicTrack> tracks;
  final (String, String)? artist;
}

/// Album / playlist / genre: big cover, title, Play + Shuffle, track list.
class MusicCollectionPage extends StatefulWidget {
  const MusicCollectionPage({super.key, required this.kind, required this.load, this.title, this.cover});
  final String kind;
  final Future<MusicCollection> Function() load;
  final String? title;
  final String? cover;

  @override
  State<MusicCollectionPage> createState() => _MusicCollectionPageState();
}

class _MusicCollectionPageState extends State<MusicCollectionPage> {
  final _scroll = ScrollController();
  late Future<MusicCollection> _future = widget.load();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);

    return FutureBuilder<MusicCollection>(
      future: _future,
      builder: (context, snap) {
        final c = snap.data;
        final cover = c?.cover ?? widget.cover;
        final total = c?.tracks.fold<int>(0, (s, t) => s + t.durationSeconds) ?? 0;
        return Material(
          color: VyseColors.bg,
          child: Stack(children: [
            Positioned.fill(child: _BlurredBackdrop(url: cover, scroll: _scroll)),
            PageScrollbar(
              controller: _scroll,
              child: CustomScrollView(controller: _scroll, slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset - 8, top, right, 12),
                  sliver: SliverToBoxAdapter(
                    child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 28),
                  sliver: SliverToBoxAdapter(
                    child: Flex(
                      direction: phone ? Axis.vertical : Axis.horizontal,
                      crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.end,
                      children: [
                        FadeSlideIn(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
                            ),
                            child: Artwork(url: cover, size: phone ? 200 : 232, radius: 12),
                          ),
                        ),
                        SizedBox(width: 28, height: phone ? 20 : 0),
                        Flexible(
                          fit: phone ? FlexFit.loose : FlexFit.tight,
                          child: FadeSlideIn(
                            delay: const Duration(milliseconds: 60),
                            offset: 12,
                            child: Column(
                              crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                              children: [
                                Text(widget.kind.toUpperCase(),
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.accent)),
                                const SizedBox(height: 8),
                                Text(c?.title ?? widget.title ?? '',
                                    textAlign: phone ? TextAlign.center : TextAlign.start,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: phone ? 26 : 40, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.05)),
                                if (c != null) ...[
                                  const SizedBox(height: 10),
                                  Pressable(
                                    onTap: c.artist == null ? null : () => openArtist(context, c.artist!.$1, c.artist!.$2),
                                    builder: (context, hovered, _) => Text(
                                      [
                                        if (c.subtitle.isNotEmpty) c.subtitle,
                                        '${c.tracks.length} brani',
                                        if (total > 0) fmtRuntime((total / 60).round()),
                                      ].join('  ·  '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: phone ? TextAlign.center : TextAlign.start,
                                      style: TextStyle(fontSize: 13, color: hovered ? VyseColors.text : const Color(0xFFC3C7D4)),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  Wrap(spacing: 10, runSpacing: 10, children: [
                                    PillButton(
                                      primary: true,
                                      icon: Icons.play_arrow_rounded,
                                      label: 'Riproduci',
                                      onTap: () => MusicPlayer.instance.playQueue(c.tracks),
                                    ),
                                    PillButton(
                                      icon: Icons.shuffle_rounded,
                                      label: 'Casuale',
                                      onTap: () => MusicPlayer.instance.playQueue(c.tracks, shuffled: true),
                                    ),
                                  ]),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (snap.hasError)
                  SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: "Impossibile caricare questo ${widget.kind.toLowerCase()}",
                      body: 'Controlla la connessione e riprova.',
                      action: ('Riprova', () => setState(() { _future = widget.load(); })),
                    ),
                  )
                else if (c == null)
                  SliverPadding(padding: EdgeInsets.fromLTRB(inset, 0, right, 0), sliver: const SliverToBoxAdapter(child: _TrackSkeleton()))
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset - 10, 0, right - 10, 0),
                    sliver: SliverList.builder(
                      itemCount: c.tracks.length,
                      itemBuilder: (_, i) => TrackRow(
                        track: c.tracks[i],
                        queue: c.tracks,
                        index: i,
                        showNumber: widget.kind == 'Album',
                        showArt: widget.kind != 'Album',
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// Artist: round portrait, top tracks, albums, related artists.
class MusicArtistPage extends StatefulWidget {
  const MusicArtistPage({super.key, required this.id, required this.name});
  final String id;
  final String name;

  @override
  State<MusicArtistPage> createState() => _MusicArtistPageState();
}

class _MusicArtistPageState extends State<MusicArtistPage> {
  final _scroll = ScrollController();
  late Future<MusicArtistDetails?> _future = MusicService.instance.fetchArtistDetails(widget.id);
  bool _allTracks = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);
    final tileW = phone ? 140.0 : 170.0;

    return FutureBuilder<MusicArtistDetails?>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        final a = d?.artist;
        final tracks = d?.topTracks ?? const <MusicTrack>[];
        return Material(
          color: VyseColors.bg,
          child: Stack(children: [
            Positioned.fill(child: _BlurredBackdrop(url: a?.pictureUrl, scroll: _scroll)),
            PageScrollbar(
              controller: _scroll,
              child: CustomScrollView(controller: _scroll, slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset - 8, top, right, 12),
                  sliver: SliverToBoxAdapter(
                    child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 26),
                  sliver: SliverToBoxAdapter(
                    child: Row(children: [
                      FadeSlideIn(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 30, offset: const Offset(0, 12))],
                          ),
                          child: Artwork(url: a?.pictureUrl, size: phone ? 110 : 190, circle: true),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: FadeSlideIn(
                          delay: const Duration(milliseconds: 60),
                          offset: 12,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('ARTIST',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.accent)),
                            const SizedBox(height: 6),
                            Text(a?.name ?? widget.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: phone ? 28 : 46, fontWeight: FontWeight.w800, letterSpacing: -1.4, height: 1.02)),
                            if (a != null && a.fanCount > 0) ...[
                              const SizedBox(height: 8),
                              Text('${fmtThousands(a.fanCount)} fan', style: const TextStyle(fontSize: 13, color: Color(0xFFC3C7D4))),
                            ],
                            if (tracks.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Wrap(spacing: 10, runSpacing: 10, children: [
                                PillButton(
                                  primary: true,
                                  icon: Icons.play_arrow_rounded,
                                  label: 'Riproduci',
                                  onTap: () => MusicPlayer.instance.playQueue(tracks),
                                ),
                                PillButton(
                                  icon: Icons.shuffle_rounded,
                                  label: 'Casuale',
                                  onTap: () => MusicPlayer.instance.playQueue(tracks, shuffled: true),
                                ),
                              ]),
                            ],
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
                if (snap.hasError || (snap.connectionState == ConnectionState.done && d == null))
                  SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: "Impossibile caricare questo artista",
                      body: 'Controlla la connessione e riprova.',
                      action: ('Riprova', () => setState(() { _future = MusicService.instance.fetchArtistDetails(widget.id); })),
                    ),
                  )
                else if (d == null)
                  SliverPadding(padding: EdgeInsets.fromLTRB(inset, 0, right, 0), sliver: const SliverToBoxAdapter(child: _TrackSkeleton()))
                else ...[
                  if (tracks.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: ShelfHeader(title: 'Popolari')),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset - 10, 0, right - 10, 0),
                      sliver: SliverList.builder(
                        itemCount: _allTracks ? tracks.length : tracks.length.clamp(0, 5),
                        itemBuilder: (_, i) => TrackRow(track: tracks[i], queue: tracks, index: i, showNumber: true),
                      ),
                    ),
                    if (tracks.length > 5)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(inset, 6, right, 0),
                        sliver: SliverToBoxAdapter(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => setState(() => _allTracks = !_allTracks),
                              child: Text(_allTracks ? 'Mostra meno' : 'Mostra tutti i ${tracks.length}'),
                            ),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 22)),
                  ],
                  if (d.albums.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Shelf<MusicAlbum>(
                        title: 'Discografia',
                        load: () async => d.albums,
                        itemWidth: tileW,
                        itemHeight: tileW + 44,
                        maxItems: 50,
                        itemBuilder: (context, al, _) => albumTile(context, al, artist: a?.name ?? widget.name),
                      ),
                    ),
                  if (d.relatedArtists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Shelf<MusicArtist>(
                        title: 'Ai fan piacciono anche',
                        load: () async => d.relatedArtists,
                        itemWidth: phone ? 110 : 140,
                        itemHeight: (phone ? 110 : 140) + 44,
                        itemBuilder: (_, ar, _) => ArtistTile(artist: ar),
                      ),
                    ),
                ],
                SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// [artist] stands in when the album doesn't carry one (Deezer often says "Unknown Artist").
Widget albumTile(BuildContext context, MusicAlbum a, {String? artist}) => CoverTile(
      title: a.title,
      subtitle: [
        if (artist != null && (a.artistName.isEmpty || a.artistName == 'Unknown Artist')) artist else a.artistName,
        if (a.releaseDate.length >= 4) a.releaseDate.substring(0, 4),
      ].join(' · '),
      cover: a.coverUrl,
      onTap: () => openAlbum(context, a.id, title: a.title, cover: a.coverUrl),
      onPlay: () async {
        final d = await MusicService.instance.fetchAlbumDetails(a.id);
        if (d != null) MusicPlayer.instance.playQueue(d.tracks);
      },
    );

Widget playlistTile(BuildContext context, MusicPlaylist p) => CoverTile(
      title: p.title,
      subtitle: [if (p.creatorName.isNotEmpty) p.creatorName, '${p.trackCount} tracks'].join(' · '),
      cover: p.coverUrl,
      onTap: () => openPlaylist(context, p.id, title: p.title, cover: p.coverUrl),
      onPlay: () async {
        final d = await MusicService.instance.fetchPlaylistDetails(p.id);
        if (d != null) MusicPlayer.instance.playQueue(d.tracks);
      },
    );

/// Same recipe as the details pages: the artwork blurred and muted under the whole page, fading
/// to the background at the bottom and darkening further as you scroll.
class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({required this.url, required this.scroll});
  final String? url;
  final ScrollController scroll;

  // Takes the edge off loud covers (all-yellow, all-red) so the page stays dark.
  static const _mute = ColorFilter.matrix([
    .62, .31, .07, 0, 0, //
    .16, .77, .07, 0, 0, //
    .16, .31, .53, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    const bg = VyseColors.bg;
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        if (url != null)
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.clamp),
              child: ColorFiltered(colorFilter: _mute, child: Transform.scale(scale: 1.2, child: NetImage(url: url))),
            ),
          ),
        ColoredBox(color: bg.withValues(alpha: .7)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [bg.withValues(alpha: .75), bg.withValues(alpha: .2), bg.withValues(alpha: 0)],
              stops: const [0, .45, .8],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [bg, bg.withValues(alpha: .6), bg.withValues(alpha: 0)],
              stops: const [0, .35, .7],
            ),
          ),
        ),
        ListenableBuilder(
          listenable: scroll,
          builder: (context, _) {
            final t = scroll.hasClients ? (scroll.offset / 500).clamp(0.0, 1.0) : 0.0;
            return ColoredBox(color: bg.withValues(alpha: .55 * t));
          },
        ),
      ]),
    );
  }
}

class _TrackSkeleton extends StatelessWidget {
  const _TrackSkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: Column(children: [
          for (var i = 0; i < 8; i++)
            const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(width: double.infinity, height: 50, radius: 10)),
        ]),
      );
}
