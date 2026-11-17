import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/manga_library.dart';
import '../models/manga/manga.dart';
import '../services/manga/manga_service.dart';
import '../widgets/common.dart';
import '../widgets/manga_widgets.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'manga_details_page.dart';
import 'manga_reader_page.dart';

Future<void> openManga(BuildContext context, Manga m, {String? heroTag}) =>
    Navigator.of(context).push(ShellRoute(child: MangaDetailsPage(manga: m, heroTag: heroTag)));

/// Manga tab: search, tag filters, Continue reading + Favorites shelves, then an endless cover grid.
class MangaPage extends StatefulWidget {
  const MangaPage({super.key, this.initialTag});

  /// Opens pre-filtered (tapping a tag on a details page).
  final String? initialTag;

  @override
  State<MangaPage> createState() => _MangaPageState();
}

class _MangaPageState extends State<MangaPage> {
  final _scroll = ScrollController();
  final _text = TextEditingController();
  Timer? _debounce;

  late String? _tag = widget.initialTag;
  String _query = '';
  final _items = <Manga>[];
  final _ids = <String>{};
  int _page = 1;
  int _generation = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    MangaFavorites.load();
    _text.addListener(_onTyped);
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) _loadMore();
    });
    _loadMore();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onTyped() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 420), () => _search(_text.text));
  }

  void _search(String q) {
    q = q.trim();
    if (q == _query) return;
    _query = q;
    _restart();
  }

  void _pickTag(String? tag) {
    if (tag == _tag) return;
    _tag = tag;
    if (_query.isNotEmpty) _text.clear();
    _query = '';
    _restart();
  }

  void _restart() {
    _generation++;
    setState(() {
      _items.clear();
      _ids.clear();
      _page = 1;
      _done = false;
      _error = null;
      _loading = false;
    });
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    final gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batch = _query.isNotEmpty
          ? await mangaService.searchManga(_query, page: _page)
          : await mangaService.getManga(page: _page, tag: _tag);
      if (!mounted || gen != _generation) return;
      setState(() {
        final fresh = batch.where((m) => _ids.add(m.id)).toList();
        _items.addAll(fresh);
        _page++;
        _done = fresh.isEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ff = Layout.of(context);
    final phone = ff == FormFactor.phone;
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);
    final coverW = switch (ff) {
      FormFactor.phone => 112.0,
      FormFactor.tablet => 140.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .1).clamp(150.0, 190.0),
    };
    final browsing = _query.isEmpty;
    final tags = MangaService.availableTags;

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, top, right, 18),
              sliver: SliverToBoxAdapter(
                child: SectionHeader(
                  title: _tag ?? 'Manga',
                  subtitle: _tag == null ? 'Read series, one chapter at a time' : 'Manga tagged $_tag',
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: FadeSlideIn(
                      delay: const Duration(milliseconds: 90),
                      offset: 10,
                      child: VyseSearchField(
                        controller: _text,
                        hint: 'Search manga',
                        busy: _loading && !browsing && _items.isEmpty,
                        onSubmit: _search,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Lorewatch: which library to browse (MangaDex in Italian, English…, or WeebCentral)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  height: 34,
                  child: ValueListenableBuilder(
                    valueListenable: AppSettings.mangaLibrary,
                    builder: (context, _, _) => ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.only(left: inset, right: right),
                      itemCount: MangaLibraryChoice.all.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final c = MangaLibraryChoice.all[i];
                        return FilterChipPill(
                          label: c.label,
                          selected: MangaLibraryChoice.current.id == c.id,
                          onTap: () {
                            if (MangaLibraryChoice.current.id == c.id) return;
                            AppSettings.mangaLibrary.set(c.id);
                            _tag = null;
                            _restart();
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (tags.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 34,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.only(left: inset, right: right),
                    itemCount: tags.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => i == 0
                        ? FilterChipPill(label: 'All', selected: _tag == null && browsing, onTap: () => _pickTag(null))
                        : FilterChipPill(
                            label: tags[i - 1],
                            selected: browsing && _tag == tags[i - 1],
                            onTap: () => _pickTag(tags[i - 1]),
                          ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 26)),
            if (browsing && _tag == null) ...[
              SliverToBoxAdapter(child: _ContinueShelf(coverW: coverW)),
              SliverToBoxAdapter(child: _FavoritesShelf(coverW: coverW)),
              SliverToBoxAdapter(child: ShelfHeader(title: 'Browse')),
            ] else
              SliverToBoxAdapter(child: ShelfHeader(title: browsing ? 'Browse' : 'Results for "$_query"')),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 4, right, 0),
              sliver: _grid(coverW),
            ),
            SliverToBoxAdapter(child: _footer()),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }

  Widget _grid(double coverW) {
    if (_items.isEmpty && _loading) {
      return captionedGrid(
        maxWidth: coverW,
        aspect: 1.5,
        caption: 40,
        itemCount: 18,
        itemBuilder: (_, _) => Shimmer(child: SkeletonBox(width: coverW, height: coverW * 1.5 + 40, radius: 7)),
      );
    }
    return captionedGrid(
      maxWidth: coverW,
      aspect: 1.5,
      caption: 40,
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final m = _items[i];
        final tag = 'manga/grid/${m.id}';
        return FadeSlideIn(
          key: ValueKey(m.id),
          delay: Duration(milliseconds: 25 * (i % 12)),
          offset: 10,
          child: MangaCard(manga: m, heroTag: tag, onTap: () => openManga(context, m, heroTag: tag)),
        );
      },
    );
  }

  Widget _footer() {
    if (_error != null) {
      return EmptyState(
        icon: Icons.wifi_off_rounded,
        title: "Couldn't load manga",
        body: 'Check your connection and try again.',
        action: ('Retry', _loadMore),
      );
    }
    if (_done && _items.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: _query.isEmpty ? 'Nothing here yet' : 'No results for "$_query"',
        body: 'Try a different title or tag.',
      );
    }
    if (_loading && _items.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent))),
      );
    }
    return const SizedBox(height: 12);
  }
}

class _ContinueShelf extends StatelessWidget {
  const _ContinueShelf({required this.coverW});
  final double coverW;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: MangaHistory.revision,
        builder: (context, rev, _) => FutureBuilder<List<MangaProgress>>(
          key: ValueKey(rev),
          future: MangaHistory.load(),
          builder: (context, snap) {
            final rows = snap.data ?? const <MangaProgress>[];
            if (rows.isEmpty) return const SizedBox.shrink();
            return Shelf<MangaProgress>(
              key: ValueKey('continue/$rev'),
              title: 'Continue reading',
              load: () async => rows,
              itemWidth: coverW,
              itemHeight: coverW * 1.5 + 38,
              itemBuilder: (context, p, _) {
                final tag = 'manga/continue/${p.manga.id}';
                return MangaCard(
                  manga: p.manga,
                  heroTag: tag,
                  caption: p.chapterLabel ?? 'Chapter ${p.chapterIndex + 1}',
                  onTap: () => resumeReading(context, p),
                  onRemove: () => MangaHistory.remove(p.manga),
                );
              },
            );
          },
        ),
      );
}

class _FavoritesShelf extends StatelessWidget {
  const _FavoritesShelf({required this.coverW});
  final double coverW;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Manga>>(
        valueListenable: MangaFavorites.items,
        builder: (context, favs, _) {
          if (favs.isEmpty) return const SizedBox.shrink();
          return Shelf<Manga>(
            key: ValueKey('favs/${favs.length}/${favs.first.id}'),
            title: 'Favorites',
            load: () async => favs,
            itemWidth: coverW,
            itemHeight: coverW * 1.5 + 38,
            maxItems: 60,
            itemBuilder: (context, m, _) {
              final tag = 'manga/favs/${m.id}';
              return MangaCard(manga: m, heroTag: tag, onTap: () => openManga(context, m, heroTag: tag));
            },
          );
        },
      );
}
