import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../media_servers/media_servers.dart';
import '../../media_servers/server_playback.dart';
import '../../plezy/media/library_query.dart';
import '../../plezy/media/media_item.dart';
import '../../plezy/media/media_kind.dart';
import '../../plezy/media/media_library.dart';
import '../../plezy/media/media_server_client.dart';
import '../../widgets/common.dart';
import '../../widgets/page_scrollbar.dart';
import '../../widgets/section_chrome.dart';
import 'servers_page.dart' show openServerItem;
import 'server_widgets.dart';

typedef _Sort = ({String label, String field, LibrarySortDirection dir});

const _sorts = <_Sort>[
  (label: 'Aggiunti di recente', field: 'addedAt', dir: LibrarySortDirection.descending),
  (label: 'Dalla A alla Z', field: 'title', dir: LibrarySortDirection.ascending),
  (label: 'Più recenti', field: 'originallyAvailableAt', dir: LibrarySortDirection.descending),
  (label: 'Più votati', field: 'rating', dir: LibrarySortDirection.descending),
];

/// Everything in one library, a page at a time as you scroll, in the order you pick.
class ServerLibraryPage extends StatefulWidget {
  const ServerLibraryPage({super.key, required this.server, required this.library});
  final MediaServer server;
  final MediaLibrary library;

  @override
  State<ServerLibraryPage> createState() => _ServerLibraryPageState();
}

class _ServerLibraryPageState extends State<ServerLibraryPage> {
  static const _page = 60;
  final _scroll = ScrollController();
  MediaServerClient? _client;
  final _items = <MediaItem>[];
  int? _total;
  bool _loading = false;
  String? _error;
  int _sort = 0;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final p = _scroll.position;
      if (p.pixels > p.maxScrollExtent - 900) _more();
    });
    ServerPlayback.ended.addListener(_afterWatching);
    _more();
  }

  @override
  void dispose() {
    ServerPlayback.ended.removeListener(_afterWatching);
    _scroll.dispose();
    super.dispose();
  }

  /// A player that was playing from a server has closed: the posters on the page get their
  /// ticks and progress again. The first few pages are enough; the rest are as they were.
  Future<void> _afterWatching() async {
    final c = _client;
    if (c == null || _items.isEmpty || !mounted) return;
    final gen = _gen;
    try {
      final s = _sorts[_sort];
      final kind = widget.library.kind;
      final page = await c.fetchLibraryPagedContent(
        widget.library.id,
        query: LibraryQuery(
          kind: kind == MediaKind.unknown ? null : kind,
          offset: 0,
          limit: math.min(_items.length, _page * 4),
          sort: LibrarySort(field: s.field, direction: s.dir),
        ),
        libraryKind: kind,
      );
      if (!mounted || gen != _gen) return;
      // by id, not by place: the order may have moved, and nothing may appear twice
      final fresh = {for (final m in page.items) m.id: m};
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          final m = fresh[_items[i].id];
          if (m != null) _items[i] = m;
        }
      });
    } catch (_) {}
  }

  bool get _done => _total != null && _items.length >= _total!;

  Future<void> _more() async {
    if (_loading || _done || _error != null) return;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final c = _client ??= await MediaServers.instance.client(widget.server);
      final s = _sorts[_sort];
      final kind = widget.library.kind;
      final page = await c.fetchLibraryPagedContent(
        widget.library.id,
        query: LibraryQuery(
          kind: kind == MediaKind.unknown ? null : kind,
          offset: _items.length,
          limit: _page,
          sort: LibrarySort(field: s.field, direction: s.dir),
        ),
        libraryKind: kind,
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.items.isEmpty ? _items.length : page.totalCount;
        _loading = false;
      });
      // a short first page on a tall window: keep going until it scrolls
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _scroll.position.maxScrollExtent < 200) _more();
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _error = serverError(e);
      });
    }
  }

  void _setSort(int i) {
    if (i == _sort) return;
    _gen++;
    setState(() {
      _sort = i;
      _items.clear();
      _total = null;
      _loading = false;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _more();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);
    final count = _total;
    final kindWord = widget.library.kind == MediaKind.show ? 'shows' : (widget.library.kind == MediaKind.movie ? 'films' : 'titles');
    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, top, right, 16),
              sliver: SliverToBoxAdapter(
                child: SectionHeader(
                  title: widget.library.title,
                  subtitle: [widget.server.name, if (count != null && _done) '$count $kindWord'].join(' · '),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
              sliver: SliverToBoxAdapter(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (i, s) in _sorts.indexed) FilterChipPill(label: s.label, selected: i == _sort, onTap: () => _setSort(i)),
                ]),
              ),
            ),
            if (_items.isEmpty && _error != null)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: "Impossibile caricare ${widget.library.title}",
                  body: _error!,
                  action: (
                    'Riprova',
                    () {
                      setState(() => _error = null);
                      _more();
                    },
                  ),
                ),
              )
            else if (_items.isEmpty && _done)
              const SliverToBoxAdapter(
                child: EmptyState(icon: Icons.video_library_outlined, title: 'Vuota per ora', body: 'Ancora niente in questa libreria.'),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
                sliver: _items.isEmpty
                    ? captionedGrid(
                        maxWidth: phone ? 120 : 170,
                        aspect: 1.5,
                        caption: 46,
                        itemCount: 18,
                        itemBuilder: (_, _) => const Shimmer(child: SkeletonBox(width: double.infinity, height: double.infinity, radius: cardRadius)),
                      )
                    : captionedGrid(
                        maxWidth: phone ? 120 : 170,
                        aspect: 1.5,
                        caption: 46,
                        itemCount: _items.length,
                        itemBuilder: (context, i) => FadeSlideIn(
                          delay: Duration(milliseconds: 18 * math.min(i % _page, 18)),
                          offset: 8,
                          child: CaptionedPoster(
                            client: _client!,
                            item: _items[i],
                            onTap: () => openServerItem(context, widget.server, _items[i]),
                          ),
                        ),
                      ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 80,
                child: Center(
                  child: _loading && _items.isNotEmpty
                      ? SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent))
                      : (_error != null && _items.isNotEmpty
                          ? PillButton(
                              label: 'Carica altro',
                              icon: Icons.refresh_rounded,
                              onTap: () {
                                setState(() => _error = null);
                                _more();
                              },
                            )
                          : null),
                ),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }
}
