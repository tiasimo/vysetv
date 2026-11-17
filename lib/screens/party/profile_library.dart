import 'package:flutter/material.dart';

import '../../core/accent.dart';
import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/music/music_library.dart';
import '../../data/music/yt_music.dart';
import '../../data/party/party.dart';
import '../../data/party/party_library.dart';
import '../../data/tmdb.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/section_chrome.dart';
import '../music/music_pages.dart';
import '../music/music_ui.dart';
import 'party_widgets.dart';

void openProfileLibrary(NavigatorState nav, PartyProfile p) => nav.push(
  ShellRoute(settings: RouteSettings(name: 'library/${p.id}'), child: ProfileLibraryPage(profile: p)),
);

enum _Part { watch, music }

enum _Kind { all, movies, shows, anime }

/// Someone's library from their profile: what's on their list to watch, and their music.
class ProfileLibraryPage extends StatefulWidget {
  const ProfileLibraryPage({super.key, required this.profile});
  final PartyProfile profile;

  @override
  State<ProfileLibraryPage> createState() => _ProfileLibraryPageState();
}

class _ProfileLibraryPageState extends State<ProfileLibraryPage> {
  late Future<ProfileLibrary> _future = _load();
  _Part _part = _Part.watch;
  _Kind _kind = _Kind.all;

  Future<ProfileLibrary> _load() => ProfileLibrary.load(widget.profile.id, owner: widget.profile.name);

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final first = p.name.split(' ').first;
    return FutureBuilder<ProfileLibrary>(
      future: _future,
      builder: (context, snap) {
        final lib = snap.data;
        if (lib != null && _part == _Part.watch && lib.titles.isEmpty && lib.musicCount > 0) _part = _Part.music;
        return MusicPageFrame(
          art: p.bannerUrl.isNotEmpty ? p.bannerUrl : (p.avatarUrl.isNotEmpty ? p.avatarUrl : null),
          slivers: (context, _) => [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
              sliver: SliverToBoxAdapter(
                child: Row(children: [
                  PartyAvatar(url: p.avatarUrl, name: p.name, size: Layout.isPhone(context) ? 64 : 84),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.isMe ? 'YOUR LIBRARY' : 'LIBRARY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: accentOf(context))),
                      const SizedBox(height: 6),
                      Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Layout.isPhone(context) ? 26 : 36, fontWeight: FontWeight.w800, letterSpacing: -1)),
                      const SizedBox(height: 4),
                      Text(
                        lib == null
                            ? '@${p.username}'
                            : '@${p.username}  ·  ${lib.titles.length} to watch  ·  ${lib.likes.length} liked songs  ·  ${lib.playlists.length} playlists',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: VyseColors.textDim),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
            if (snap.hasError)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.lock_outline_rounded,
                  title: _why(snap.error!),
                  body: p.private ? 'Private profiles share their library with friends only.' : 'Try again in a bit.',
                  action: ('Retry', () => setState(() => _future = _load())),
                ),
              )
            else if (lib == null)
              const SliverToBoxAdapter(child: RowsSkeleton(rows: 6))
            else if (lib.isEmpty)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: p.isMe ? 'Your library is empty' : '$first hasn’t saved anything yet',
                  body: 'Titles on My List, liked songs and public playlists show up here.',
                ),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, right, 18),
                sliver: SliverToBoxAdapter(
                  child: MusicChips<_Part>(
                    value: _part,
                    options: [(_Part.watch, 'Watchlist ${lib.titles.length}'), (_Part.music, 'Music ${lib.musicCount}')],
                    onChanged: (v) => setState(() => _part = v),
                  ),
                ),
              ),
              ...(_part == _Part.watch ? _watch(lib) : _music(lib)),
            ],
          ],
        );
      },
    );
  }

  String _why(Object e) {
    final text = Account.describe(e);
    return text.isEmpty ? "Couldn't load this library" : text;
  }

  List<Widget> _watch(ProfileLibrary lib) {
    final all = lib.titles;
    bool isAnime(SavedTitle t) => t.media.anime;
    final movies = [for (final t in all) if (!t.media.isTv && !isAnime(t)) t];
    final shows = [for (final t in all) if (t.media.isTv && !isAnime(t)) t];
    final anime = [for (final t in all) if (isAnime(t)) t];
    final shown = switch (_kind) {
      _Kind.all => all,
      _Kind.movies => movies,
      _Kind.shows => shows,
      _Kind.anime => anime,
    };
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final w = Layout.isPhone(context) ? 110.0 : 150.0;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 18),
        sliver: SliverToBoxAdapter(
          child: MusicChips<_Kind>(
            value: _kind,
            options: [
              (_Kind.all, 'All ${all.length}'),
              if (movies.isNotEmpty) (_Kind.movies, 'Movies ${movies.length}'),
              if (shows.isNotEmpty) (_Kind.shows, 'Shows ${shows.length}'),
              if (anime.isNotEmpty) (_Kind.anime, 'Anime ${anime.length}'),
            ],
            onChanged: (v) => setState(() => _kind = v),
          ),
        ),
      ),
      if (shown.isEmpty)
        const SliverToBoxAdapter(child: EmptyState(icon: Icons.movie_outlined, title: 'Nothing here', body: 'Nothing of this kind on their list.'))
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: w + 16, mainAxisSpacing: 18, crossAxisSpacing: 12, childAspectRatio: (w + 16) / ((w + 16) * 1.5 + 44)),
            itemCount: shown.length,
            itemBuilder: (context, i) => FadeSlideIn(delay: Duration(milliseconds: 12 * (i % 24)), offset: 8, child: _Poster(title: shown[i])),
          ),
        ),
    ];
  }

  List<Widget> _music(ProfileLibrary lib) {
    final w = musicTileW(context);
    final aw = Layout.isPhone(context) ? 120.0 : 150.0;
    final lists = <Object>[if (lib.likes.isNotEmpty) lib.likes, ...lib.playlists];
    return [
      if (lists.isNotEmpty)
        SliverToBoxAdapter(
          child: Shelf<Object>(
            title: 'Playlists',
            load: () async => lists,
            maxItems: 60,
            itemWidth: w,
            itemHeight: w + 46,
            itemBuilder: (context, x, _) => x is MyPlaylist ? MyPlaylistCard(p: x, other: !widget.profile.isMe) : LikedSongsCard(likes: lib.likes, owner: widget.profile.isMe ? null : widget.profile.name),
          ),
        ),
      if (lib.likes.isNotEmpty) ...[
        const SliverToBoxAdapter(child: ShelfHeader(title: 'Recently liked')),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context) - 10, 24),
          sliver: SliverList.builder(
            itemCount: lib.likes.length.clamp(0, 8),
            itemBuilder: (context, i) => TrackRow(track: lib.likes[i].track, queue: [for (final l in lib.likes) l.track], index: i),
          ),
        ),
      ],
      if (lib.artists.isNotEmpty)
        SliverToBoxAdapter(
          child: Shelf<SavedRef>(
            title: 'Artists they follow',
            load: () async => lib.artists,
            maxItems: 60,
            itemWidth: aw,
            itemHeight: aw + 46,
            itemBuilder: (context, a, _) => YtArtistCard(item: YtItem(kind: YtKind.artist, id: a.id, title: a.title, thumb: a.thumb, subtitle: a.subtitle)),
          ),
        ),
      if (lib.albums.isNotEmpty)
        SliverToBoxAdapter(
          child: Shelf<SavedRef>(
            title: 'Saved albums',
            load: () async => lib.albums,
            maxItems: 60,
            itemWidth: w,
            itemHeight: w + 46,
            itemBuilder: (context, a, _) => YtCard(item: YtItem(kind: YtKind.album, id: a.id, title: a.title, thumb: a.thumb, subtitle: a.subtitle)),
          ),
        ),
      if (lib.savedPlaylists.isNotEmpty)
        SliverToBoxAdapter(
          child: Shelf<SavedRef>(
            title: 'Saved playlists',
            load: () async => lib.savedPlaylists,
            maxItems: 60,
            itemWidth: w,
            itemHeight: w + 46,
            itemBuilder: (context, a, _) => YtCard(item: YtItem(kind: YtKind.playlist, id: a.id, title: a.title, thumb: a.thumb, subtitle: a.subtitle)),
          ),
        ),
    ];
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.title});
  final SavedTitle title;

  @override
  Widget build(BuildContext context) {
    final m = title.media;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: OutlineCard(
          label: m.title,
          radius: 10,
          onTap: () => openDetails(context, m),
          builder: (hovered) => Stack(fit: StackFit.expand, children: [
            AnimatedScale(scale: hovered ? 1.05 : 1, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic, child: NetImage(url: m.poster(), fallback: Icons.movie_outlined)),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: Colors.black.withValues(alpha: .65)),
                child: Text(m.anime ? 'Anime' : (m.isTv ? 'Show' : 'Movie'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 7),
      Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
      Text(m.date.length >= 4 ? m.date.substring(0, 4) : '', style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
    ]);
  }
}
