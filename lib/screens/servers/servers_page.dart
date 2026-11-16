import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/nav.dart' show ShellRoute;
import '../../core/theme.dart';
import '../../media_servers/media_servers.dart';
import '../../media_servers/server_playback.dart';
import '../../plezy/media/media_hub.dart';
import '../../plezy/media/media_item.dart';
import '../../plezy/media/media_kind.dart';
import '../../plezy/media/media_library.dart';
import '../../plezy/media/media_server_client.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart' show Shelf;
import '../../widgets/page_scrollbar.dart';
import '../../widgets/section_chrome.dart';
import 'server_item_page.dart';
import 'server_library_page.dart';
import 'server_sign_in.dart';
import 'server_widgets.dart';

/// Kinds of library and item the section shows: films and series (music and photos stay out).
bool isVideoKind(MediaKind k) => const {MediaKind.movie, MediaKind.show, MediaKind.season, MediaKind.episode, MediaKind.clip}.contains(k);

/// Opens a title's page: films and shows as they are, seasons and episodes on their show's page.
Future<void> openServerItem(BuildContext context, MediaServer server, MediaItem item) =>
    Navigator.of(context).push(ShellRoute(child: ServerItemPage(server: server, item: item)));

/// The Servers section: your Plex, Jellyfin and Emby libraries, or a welcome when you have none.
class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  final _servers = MediaServers.instance;

  @override
  void initState() {
    super.initState();
    _servers.load();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: VyseColors.bg,
    child: ListenableBuilder(
      listenable: _servers,
      builder: (context, _) {
        final selected = _servers.selected;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          child: !_servers.loaded
              ? const SizedBox.expand(key: ValueKey('loading'))
              : selected == null
              ? const _Welcome(key: ValueKey('welcome'))
              : _ServerHome(key: ValueKey(selected.key), server: selected),
        );
      },
    ),
  );
}

// ───────────────────────── Welcome ─────────────────────────

class _Welcome extends StatefulWidget {
  const _Welcome({super.key});

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  final _scroll = ScrollController();
  late final _nearby = JellyfinSignIn.discover();

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
    final top = Layout.topChrome(context) + (phone ? 12 : 34);
    return Stack(children: [
      const Positioned(top: -220, right: -160, child: PageGlow()),
      PageScrollbar(
        controller: _scroll,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, top, right, 26),
            sliver: const SliverToBoxAdapter(
              child: SectionHeader(title: 'Your servers', subtitle: 'Plex, Jellyfin and Emby, right inside Lorewatch'),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
            sliver: SliverToBoxAdapter(
              child: FadeSlideIn(offset: 12, child: _Pitch(phone: phone)),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 22, right, 0),
            sliver: SliverToBoxAdapter(
              child: LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth > 900 ? 3 : (c.maxWidth > 560 ? 2 : 1);
                const all = [MediaBackend.plex, MediaBackend.jellyfin, MediaBackend.emby];
                Widget card(int i) => FadeSlideIn(
                  delay: Duration(milliseconds: 90 + 70 * i),
                  offset: 14,
                  child: _ProviderCard(backend: all[i], onTap: () => showServerSignIn(context, backend: all[i])),
                );
                // rows of equal-height cards, however long each one's text runs
                return Column(children: [
                  for (var r = 0; r < all.length; r += cols) ...[
                    if (r > 0) const SizedBox(height: 14),
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (var i = r; i < r + cols; i++) ...[
                          if (i > r) const SizedBox(width: 14),
                          Expanded(child: i < all.length ? card(i) : const SizedBox.shrink()),
                        ],
                      ]),
                    ),
                  ],
                ]);
              }),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 26, right, 0),
            sliver: SliverToBoxAdapter(
              child: FutureBuilder<List<DiscoveredJellyfinServer>>(
                future: _nearby,
                builder: (context, snap) {
                  final list = snap.data ?? const [];
                  if (snap.connectionState == ConnectionState.done && list.isEmpty) return const SizedBox.shrink();
                  return FadeSlideIn(
                    delay: const Duration(milliseconds: 300),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(Icons.wifi_tethering_rounded, size: 16, color: VyseColors.textDim),
                        const SizedBox(width: 8),
                        Text(
                          list.isEmpty ? 'Looking for servers on your network…' : 'Found on your network',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: VyseColors.textDim),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        for (final s in list)
                          _NearbyChip(server: s, onTap: () => showServerSignIn(context, found: s)),
                        if (list.isEmpty) const Shimmer(child: SkeletonBox(width: 220, height: 52, radius: 14)),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 30, right, pageBottom(context)),
            sliver: const SliverToBoxAdapter(
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, size: 14, color: VyseColors.textFaint),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your sign-ins stay on this device, in its secure keychain. What you watch is saved on your server, '
                    'so it picks up anywhere you use Plex, Jellyfin or Emby.',
                    style: TextStyle(fontSize: 12, height: 1.45, color: VyseColors.textFaint),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// The big welcome panel: what this is, in one breath.
class _Pitch extends StatelessWidget {
  const _Pitch({required this.phone});
  final bool phone;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(phone ? 20 : 30),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [VyseColors.accent.withValues(alpha: .16), VyseColors.violet.withValues(alpha: .12), Colors.white.withValues(alpha: .02)],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Bring your own library',
            style: TextStyle(fontSize: phone ? 24 : 32, height: 1.1, fontWeight: FontWeight.w900, letterSpacing: -.5),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: const Text(
              'Sign in once and your server lives here: Continue watching, every library, every season. '
              'It all plays on Lorewatch\'s player, and your progress goes back to your server.',
              style: TextStyle(fontSize: 14, height: 1.5, color: VyseColors.textDim),
            ),
          ),
          const SizedBox(height: 18),
          const Wrap(spacing: 18, runSpacing: 8, children: [
            _Perk(icon: Icons.bolt_rounded, text: 'Direct play, no transcoding'),
            _Perk(icon: Icons.subtitles_outlined, text: 'Your subtitle styles'),
            _Perk(icon: Icons.sync_rounded, text: 'Progress synced back'),
          ]),
        ]),
      ),
      if (!phone) ...[
        const SizedBox(width: 24),
        const _Stack(),
      ],
    ]),
  );
}

class _Perk extends StatelessWidget {
  const _Perk({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 16, color: VyseColors.accent),
    const SizedBox(width: 6),
    Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.text)),
  ]);
}

/// Three brand marks fanned out, gently floating.
class _Stack extends StatefulWidget {
  const _Stack();

  @override
  State<_Stack> createState() => _StackState();
}

class _StackState extends State<_Stack> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 170,
    height: 120,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Stack(alignment: Alignment.center, children: [
        for (final (i, b) in const [MediaBackend.emby, MediaBackend.jellyfin, MediaBackend.plex].indexed)
          Transform.translate(
            offset: Offset((i - 1) * 46.0, math.sin((_c.value + i / 3) * 2 * math.pi) * 6),
            child: Transform.rotate(angle: (i - 1) * .14, child: BrandMark(b, size: i == 2 ? 70 : 58)),
          ),
      ]),
    ),
  );
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.backend, required this.onTap});
  final MediaBackend backend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = brandColors(backend);
    final (blurb, how) = switch (backend) {
      MediaBackend.plex => ('Every server on your Plex account, with Plex Home profiles.', 'Sign in on plex.tv'),
      MediaBackend.emby => ('Your Emby server and everything on it.', 'Address and login'),
      _ => ('Your Jellyfin server, with Quick Connect.', 'Address, login or Quick Connect'),
    };
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .98 : 1,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          // hover lifts the card a touch instead of growing it, so the three stay the same size
          transform: Matrix4.translationValues(0, hovered ? -3 : 0, 0),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: VyseColors.surface,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.first.withValues(alpha: hovered ? .2 : .1), VyseColors.surface],
            ),
            border: Border.all(color: hovered ? c.first.withValues(alpha: .55) : Colors.white.withValues(alpha: .07)),
            boxShadow: [if (hovered) BoxShadow(color: c.last.withValues(alpha: .22), blurRadius: 30, offset: const Offset(0, 10))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              BrandMark(backend, size: 46),
              const Spacer(),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 36,
                height: 36,
                decoration: BoxDecoration(shape: BoxShape.circle, color: hovered ? Colors.white : Colors.white.withValues(alpha: .08)),
                child: Icon(Icons.arrow_forward_rounded, size: 19, color: hovered ? Colors.black : VyseColors.textDim),
              ),
            ]),
            const SizedBox(height: 18),
            Text(brandName(backend), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
            const SizedBox(height: 5),
            Text(blurb, style: const TextStyle(fontSize: 13, height: 1.45, color: VyseColors.textDim)),
            const SizedBox(height: 14),
            const Spacer(), // the "how" line sits on the bottom edge of every card
            Text(how, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c.first)),
          ]),
        ),
      ),
    );
  }
}

class _NearbyChip extends StatelessWidget {
  const _NearbyChip({required this.server, required this.onTap});
  final DiscoveredJellyfinServer server;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.fromLTRB(10, 9, 16, 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: hovered ? .08 : .04),
        border: Border.all(color: Colors.white.withValues(alpha: hovered ? .16 : .07)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        BrandMark(server.dialect.backend, size: 30),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(server.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
          Text(server.address, style: const TextStyle(fontSize: 11, color: VyseColors.textFaint)),
        ]),
        const SizedBox(width: 14),
        Icon(Icons.add_circle_outline_rounded, size: 18, color: hovered ? VyseColors.accent : VyseColors.textDim),
      ]),
    ),
  );
}

// ───────────────────────── A server's home ─────────────────────────

class _HomeData {
  const _HomeData(this.resume, this.libraries, this.hubs);
  final List<MediaItem> resume;
  final List<MediaLibrary> libraries;
  final List<MediaHub> hubs;
}

class _ServerHome extends StatefulWidget {
  const _ServerHome({super.key, required this.server});
  final MediaServer server;

  @override
  State<_ServerHome> createState() => _ServerHomeState();
}

class _ServerHomeState extends State<_ServerHome> {
  final _scroll = ScrollController();
  final _query = TextEditingController();
  late Future<MediaServerClient> _client = MediaServers.instance.client(widget.server);
  late Future<_HomeData> _data = _load();
  Future<List<MediaItem>>? _results;
  String _searched = '';

  MediaServer get server => widget.server;

  Future<_HomeData> _load() async {
    final c = await _client;
    final r = await Future.wait<Object>([
      c.fetchContinueWatching(count: 24).catchError((Object _) => <MediaItem>[]),
      c.fetchLibraries(),
      c.fetchGlobalHubs(includePlaybackHubs: false).catchError((Object _) => <MediaHub>[]),
    ]);
    final resume = (r[0] as List<MediaItem>).where((m) => isVideoKind(m.kind)).toList();
    final libraries = (r[1] as List<MediaLibrary>)
        .where((l) => !l.hidden && (l.kind == MediaKind.movie || l.kind == MediaKind.show || l.kind == MediaKind.unknown))
        .toList();
    final hubs = [
      for (final h in r[2] as List<MediaHub>)
        if (h.items.where((m) => isVideoKind(m.kind)).length >= 2) h,
    ];
    return _HomeData(resume, libraries, hubs);
  }

  void _refresh({bool reconnect = false}) {
    if (reconnect) {
      MediaServers.instance.reconnect(server);
      _client = MediaServers.instance.client(server);
    }
    setState(() => _data = _load());
  }

  /// A player that was playing from a server has closed: Continue watching and the ticks are
  /// fetched again. The page stays as it is while they are, and if the server doesn't answer.
  Future<void> _afterWatching() async {
    final client = _client;
    try {
      final fresh = await _load();
      if (!mounted || !identical(client, _client)) return;
      setState(() => _data = Future.value(fresh));
    } catch (_) {}
  }

  void _search(String q) {
    final text = q.trim();
    setState(() {
      _searched = text;
      _results = text.isEmpty ? null : _client.then((c) => c.searchItems(text, limit: 80)).then((l) => l.where((m) => isVideoKind(m.kind)).toList());
    });
  }

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      if (_query.text.isEmpty && _results != null) _search('');
    });
    ServerPlayback.ended.addListener(_afterWatching);
  }

  @override
  void didUpdateWidget(_ServerHome old) {
    super.didUpdateWidget(old);
    // same server, new sign-in (another Plex Home profile): everything comes from the new one
    if (!identical(old.server.account, widget.server.account)) {
      _client = MediaServers.instance.client(widget.server);
      _data = _load();
      _results = null;
      _query.clear();
    }
  }

  @override
  void dispose() {
    ServerPlayback.ended.removeListener(_afterWatching);
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);
    return Stack(children: [
      Positioned(top: -220, right: -160, child: _BrandGlow(server.backend)),
      PageScrollbar(
        controller: _scroll,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, top, right, 14),
            sliver: SliverToBoxAdapter(
              child: FadeSlideIn(offset: 8, child: _Header(server: server, onRefresh: () => _refresh(reconnect: true))),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
            sliver: SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: FutureBuilder<List<MediaItem>>(
                    future: _results,
                    builder: (context, snap) => VyseSearchField(
                      controller: _query,
                      hint: 'Search ${server.name}',
                      busy: _results != null && snap.connectionState == ConnectionState.waiting,
                      onSubmit: _search,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_results != null) ..._searchSlivers(inset, right) else _homeSliver(),
          SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
        ]),
      ),
    ]);
  }

  List<Widget> _searchSlivers(double inset, double right) => [
    SliverPadding(
      padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
      sliver: FutureBuilder<List<MediaItem>>(
        future: _results,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SliverToBoxAdapter(child: SizedBox(height: 200, child: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: VyseColors.accent))));
          }
          final list = snap.data ?? const [];
          if (list.isEmpty) {
            return SliverToBoxAdapter(
              child: EmptyState(icon: Icons.search_off_rounded, title: 'Nothing for "$_searched"', body: 'Try another title, or check the spelling.'),
            );
          }
          return FutureBuilder<MediaServerClient>(
            future: _client,
            builder: (context, c) => c.data == null
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : captionedGrid(
                    maxWidth: 170,
                    aspect: 1.5,
                    caption: 46,
                    itemCount: list.length,
                    itemBuilder: (context, i) => FadeSlideIn(
                      delay: Duration(milliseconds: 20 * math.min(i, 16)),
                      offset: 8,
                      child: CaptionedPoster(client: c.data!, item: list[i], onTap: () => openServerItem(context, server, list[i])),
                    ),
                  ),
          );
        },
      ),
    ),
  ];

  Widget _homeSliver() => FutureBuilder<_HomeData>(
    future: _data,
    builder: (context, snap) {
      if (snap.hasError) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 30),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: "Can't reach ${server.name}",
              body: '${serverError(snap.error!)}. Check that the server is on and this device can reach it.',
              action: ('Try again', () => _refresh(reconnect: true)),
            ),
          ),
        );
      }
      final data = snap.data;
      if (data == null) return const SliverToBoxAdapter(child: _Skeleton());
      return FutureBuilder<MediaServerClient>(
        future: _client,
        builder: (context, c) {
          final client = c.data;
          if (client == null) return const SliverToBoxAdapter(child: _Skeleton());
          return SliverList.list(children: _shelves(client, data));
        },
      );
    },
  );

  List<Widget> _shelves(MediaServerClient client, _HomeData d) {
    final sizes = shelfSizes(context);
    final spotlight = d.resume.firstOrNull ?? d.hubs.expand((h) => h.items).where((m) => m.kind == MediaKind.movie || m.kind == MediaKind.show).firstOrNull;
    if (spotlight == null && d.libraries.isEmpty) {
      return [
        EmptyState(
          icon: Icons.video_library_outlined,
          title: 'Nothing here yet',
          body: '${server.name} has no films or shows you can see. Add some on the server and they show up here.',
        ),
      ];
    }
    return [
      if (spotlight != null)
        Padding(
          padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 30),
          child: FadeSlideIn(
            offset: 14,
            child: _Spotlight(server: server, client: client, item: spotlight, resuming: d.resume.isNotEmpty),
          ),
        ),
      if (d.resume.isNotEmpty)
        Shelf<MediaItem>(
          title: 'Continue watching',
          load: () => Future.value(d.resume),
          itemWidth: sizes.wide,
          itemHeight: sizes.wide * 9 / 16,
          itemBuilder: (context, m, _) => ServerWideCard(
            client: client,
            item: m,
            onTap: () => playFromServer(context, server, m),
            onLongPress: () => openServerItem(context, server, m),
          ),
        ),
      if (d.libraries.isNotEmpty)
        Shelf<MediaLibrary>(
          title: 'Libraries',
          load: () => Future.value(d.libraries),
          itemWidth: Layout.isPhone(context) ? 150 : 210,
          itemHeight: Layout.isPhone(context) ? 92 : 118,
          itemBuilder: (context, l, i) => LibraryTile(
            library: l,
            index: i,
            onTap: () => Navigator.of(context).push(ShellRoute(child: ServerLibraryPage(server: server, library: l))),
          ),
        ),
      for (final h in d.hubs)
        Shelf<MediaItem>(
          title: h.title,
          load: () => Future.value(h.items.where((m) => isVideoKind(m.kind)).toList()),
          itemWidth: sizes.poster,
          itemHeight: sizes.poster * 1.5,
          maxItems: 30,
          itemBuilder: (context, m, i) => ServerPoster(
            client: client,
            item: m,
            heroTag: 'srv-${h.id}-${m.id}',
            onTap: () => openServerItem(context, server, m),
          ),
        ),
    ];
  }
}

class _BrandGlow extends StatelessWidget {
  const _BrandGlow(this.backend);
  final MediaBackend backend;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: 620,
      height: 620,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [brandColors(backend).first.withValues(alpha: .13), Colors.transparent]),
      ),
    ),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final sizes = shelfSizes(context);
    return Shimmer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, pageRight(context), 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(width: double.infinity, height: Layout.isPhone(context) ? 220 : 360, radius: 20),
          const SizedBox(height: 34),
          const SkeletonBox(width: 180, height: 16, radius: 6),
          const SizedBox(height: 14),
          SizedBox(
            height: sizes.wide * 9 / 16,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 6,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, _) => SkeletonBox(width: sizes.wide, height: sizes.wide * 9 / 16, radius: cardRadius),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Server name, who's signed in, the other servers, and the account menu.
class _Header extends StatelessWidget {
  const _Header({required this.server, required this.onRefresh});
  final MediaServer server;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final all = MediaServers.instance.servers;
    final a = server.account;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (Navigator.of(context).canPop())
        Padding(padding: const EdgeInsets.only(bottom: 10), child: BackLink(onTap: () => Navigator.of(context).maybePop())),
      Row(children: [
        BrandMark(server.backend, size: phone ? 38 : 46),
        SizedBox(width: phone ? 12 : 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: phone ? 24 : 34, height: 1.05, fontWeight: FontWeight.w900, letterSpacing: -.6),
            ),
            const SizedBox(height: 4),
            Text(
              [server.product, if (server.shared) 'shared with you', 'watching as ${a.who}'].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        GlassIconButton(icon: Icons.refresh_rounded, label: 'Refresh', size: 40, onTap: onRefresh),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Accounts and profiles',
          child: Pressable(
            onTap: () => showServerAccounts(context),
            builder: (context, hovered, _) => AnimatedScale(
              scale: hovered ? 1.06 : 1,
              duration: const Duration(milliseconds: 160),
              child: ServerAvatar(name: a.who, url: a.avatar, size: 40, ring: hovered ? VyseColors.accent : Colors.white.withValues(alpha: .12)),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 18),
      SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          children: [
            for (final s in all)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _ServerPill(server: s, selected: s.key == server.key, onTap: () => MediaServers.instance.select(s)),
              ),
            _AddPill(onTap: () => showServerSignIn(context)),
          ],
        ),
      ),
    ]);
  }
}

class _ServerPill extends StatelessWidget {
  const _ServerPill({required this.server, required this.selected, required this.onTap});
  final MediaServer server;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.fromLTRB(7, 6, 14, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: selected ? Colors.white : Colors.white.withValues(alpha: hovered ? .1 : .05),
        border: Border.all(color: selected ? Colors.white : Colors.white.withValues(alpha: .08)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        BrandMark(server.backend, size: 22),
        const SizedBox(width: 8),
        Text(
          server.name,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: selected ? Colors.black : VyseColors.text),
        ),
      ]),
    ),
  );
}

class _AddPill extends StatelessWidget {
  const _AddPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: hovered ? VyseColors.accent.withValues(alpha: .7) : Colors.white.withValues(alpha: .14)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.add_rounded, size: 17, color: hovered ? VyseColors.accent : VyseColors.textDim),
        const SizedBox(width: 6),
        Text('Add server', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: hovered ? VyseColors.accent : VyseColors.textDim)),
      ]),
    ),
  );
}

/// The big banner up top: what you were watching, or something new, ready to play.
class _Spotlight extends StatelessWidget {
  const _Spotlight({required this.server, required this.client, required this.item, required this.resuming});
  final MediaServer server;
  final MediaServerClient client;
  final MediaItem item;
  final bool resuming;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final w = MediaQuery.sizeOf(context).width;
    final h = phone ? 240.0 : (w * .3).clamp(300.0, 440.0);
    final p = progressOf(item);
    final code = episodeCode(item);
    final meta = [
      ?code,
      if (item.kind == MediaKind.episode) ?item.title,
      if (item.kind != MediaKind.episode) ?item.year?.toString(),
      ?item.contentRating,
      ?lengthNote(item),
    ].where((s) => s.isNotEmpty).join('  ·  ');
    final logo = item.kind == MediaKind.episode ? null : client.art(item.clearLogoPath, width: 700);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: h,
        child: Stack(fit: StackFit.expand, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.08, end: 1),
            duration: const Duration(milliseconds: 1600),
            curve: Curves.easeOutCubic,
            builder: (context, s, child) => Transform.scale(scale: s, child: child),
            child: serverImage(client.backdropOf(item), alignment: Alignment.topCenter),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xF2050609), Color(0x99050609), Color(0x00050609)], stops: [0, .45, .85]),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xB3000000)], stops: [.5, 1]),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(phone ? 18 : 34),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  resuming ? 'CONTINUE WATCHING' : 'NEW ON ${server.name.toUpperCase()}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.6, color: VyseColors.accent),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: phone ? 260 : 460, maxHeight: phone ? 70 : 110),
                  child: logo != null
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: serverImage(logo, fit: BoxFit.contain, alignment: Alignment.centerLeft),
                        )
                      : Text(
                          item.displayTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: phone ? 26 : 40, height: 1.05, fontWeight: FontWeight.w900, letterSpacing: -.8),
                        ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
                ],
                if (!phone && (item.summary ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(item.summary!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.45, color: VyseColors.textDim)),
                  ),
                ],
                const SizedBox(height: 18),
                Row(children: [
                  PillButton(
                    label: p != null ? 'Resume' : 'Play',
                    icon: Icons.play_arrow_rounded,
                    primary: true,
                    onTap: () => playFromServer(context, server, item),
                  ),
                  const SizedBox(width: 10),
                  PillButton(label: 'Details', icon: Icons.info_outline_rounded, onTap: () => openServerItem(context, server, item)),
                ]),
                if (p != null) ...[
                  const SizedBox(height: 16),
                  SizedBox(width: phone ? 200 : 280, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: ThinProgress(p))),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── Accounts sheet ─────────────────────────

/// Who's signed in where: switch Plex Home profiles, look for new servers, sign out, add more.
Future<void> showServerAccounts(BuildContext context) {
  const body = _Accounts();
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B0D16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => const SingleChildScrollView(child: body),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .65),
    builder: (context) => Dialog(
      backgroundColor: const Color(0xFF0B0D16),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: VyseColors.stroke)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: const SingleChildScrollView(child: body)),
    ),
  );
}

class _Accounts extends StatelessWidget {
  const _Accounts();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MediaServers.instance,
    builder: (context, _) {
      final accounts = MediaServers.instance.accounts;
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Accounts', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.3))),
            GlassIconButton(icon: Icons.close_rounded, label: 'Close', size: 34, onTap: () => Navigator.of(context).pop()),
          ]),
          const SizedBox(height: 4),
          const Text('Switch profiles, find new servers, or sign out.', style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
          const SizedBox(height: 18),
          for (final (i, a) in accounts.indexed)
            FadeSlideIn(delay: Duration(milliseconds: 50 * i), offset: 8, child: _AccountCard(account: a)),
          const SizedBox(height: 6),
          PillButton(
            label: 'Connect another server',
            icon: Icons.add_rounded,
            expand: true,
            onTap: () {
              Navigator.of(context).pop();
              showServerSignIn(context);
            },
          ),
        ]),
      );
    },
  );
}

class _AccountCard extends StatefulWidget {
  const _AccountCard({required this.account});
  final ServerAccount account;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  Future<List<PlexHomeUser>>? _profiles;
  bool _busy = false;

  ServerAccount get a => widget.account;

  @override
  void initState() {
    super.initState();
    final acc = a;
    if (acc is PlexAccount) _profiles = MediaServers.instance.plexProfiles(acc);
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    await tryServer(context, f);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _switch(PlexAccount acc, PlexHomeUser u) async {
    String? pin;
    if (u.protected) {
      pin = await _askPin(context, u.displayName);
      if (pin == null) return;
    }
    await _run(() async {
      await MediaServers.instance.switchPlexProfile(acc, u, pin: pin);
      if (mounted) {
        showToast(context, Text('Watching as ${u.displayName}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.person_rounded);
      }
    });
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0B0D16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
        title: Text('Sign out of ${a is PlexAccount ? 'Plex' : (a as JellyfinAccount).conn.serverName}?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        content: const Text('Your progress stays on the server. You can sign in again any time.', style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: VyseColors.textDim))),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sign out', style: TextStyle(color: Color(0xFFFF8A93), fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok == true) await MediaServers.instance.remove(a);
  }

  @override
  Widget build(BuildContext context) {
    final acc = a;
    final servers = MediaServers.instance.servers.where((s) => s.account.id == acc.id).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: .04),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          BrandMark(acc.backend, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(acc is PlexAccount ? acc.conn.accountLabel : (acc as JellyfinAccount).conn.serverName,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
              Text(
                acc is PlexAccount
                    ? '${servers.length == 1 ? '1 server' : '${servers.length} servers'} · watching as ${acc.who}'
                    : 'Signed in as ${acc.who}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: VyseColors.textDim),
              ),
            ]),
          ),
          if (_busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)),
        ]),
        if (acc is PlexAccount)
          FutureBuilder<List<PlexHomeUser>>(
            future: _profiles,
            builder: (context, snap) {
              final users = snap.data ?? const [];
              if (users.length < 2) return const SizedBox.shrink();
              final active = acc.conn.activeProfile?.uuid;
              return Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text("WHO'S WATCHING", style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: 1.4, color: VyseColors.textFaint)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 14, runSpacing: 12, children: [
                    for (final u in users)
                      Pressable(
                        onTap: _busy || u.uuid == active ? null : () => _switch(acc, u),
                        builder: (context, hovered, _) {
                          final on = u.uuid == active || (active == null && u.admin);
                          return SizedBox(
                            width: 64,
                            child: Column(children: [
                              Stack(clipBehavior: Clip.none, children: [
                                AnimatedScale(
                                  scale: hovered ? 1.07 : 1,
                                  duration: const Duration(milliseconds: 160),
                                  child: ServerAvatar(
                                    name: u.displayName,
                                    url: u.thumb,
                                    size: 54,
                                    ring: on ? VyseColors.accent : (hovered ? Colors.white54 : Colors.white.withValues(alpha: .1)),
                                  ),
                                ),
                                if (u.protected)
                                  const Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: CircleAvatar(radius: 9, backgroundColor: Color(0xFF0B0D16), child: Icon(Icons.lock_rounded, size: 11, color: VyseColors.textDim)),
                                  ),
                              ]),
                              const SizedBox(height: 6),
                              Text(
                                u.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim),
                              ),
                            ]),
                          );
                        },
                      ),
                  ]),
                ]),
              );
            },
          ),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (acc is PlexAccount)
            _SmallButton(icon: Icons.travel_explore_rounded, label: 'Look for new servers', onTap: _busy ? null : () => _run(() => MediaServers.instance.refreshPlex(acc))),
          _SmallButton(icon: Icons.logout_rounded, label: 'Sign out', danger: true, onTap: _busy ? null : _signOut),
        ]),
      ]),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) {
      final fg = danger ? const Color(0xFFFF8A93) : VyseColors.text;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: hovered ? fg.withValues(alpha: .12) : Colors.white.withValues(alpha: .05),
          border: Border.all(color: hovered ? fg.withValues(alpha: .3) : Colors.white.withValues(alpha: .07)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 7),
          Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: fg)),
        ]),
      );
    },
  );
}

/// The four-digit PIN of a protected Plex Home profile.
Future<String?> _askPin(BuildContext context, String name) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF0B0D16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: VyseColors.stroke)),
      title: Text("$name's PIN", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 4,
        textAlign: TextAlign.center,
        cursorColor: VyseColors.accent,
        style: const TextStyle(fontSize: 26, letterSpacing: 14, fontWeight: FontWeight.w900),
        decoration: const InputDecoration(counterText: '', hintText: '••••', hintStyle: TextStyle(color: VyseColors.textFaint)),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim().isEmpty ? null : v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel', style: TextStyle(color: VyseColors.textDim))),
        TextButton(
          onPressed: () => Navigator.of(context).pop(c.text.trim().isEmpty ? null : c.text.trim()),
          child: const Text('Switch', style: TextStyle(color: VyseColors.accent, fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
}
