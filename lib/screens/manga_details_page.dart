import 'dart:ui';

import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/manga_library.dart';
import '../models/manga/manga.dart';
import '../models/manga/manga_chapter.dart';
import '../widgets/common.dart';
import '../widgets/manga_widgets.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'manga_page.dart';
import 'manga_reader_page.dart';

/// A series, built like the movie Details page: the cover blown up and blurred as a full-screen
/// backdrop, cover + facts + actions over it, then every chapter as a grid of flat tiles.
class MangaDetailsPage extends StatefulWidget {
  const MangaDetailsPage({super.key, required this.manga, this.heroTag});
  final Manga manga;
  final String? heroTag;

  @override
  State<MangaDetailsPage> createState() => _MangaDetailsPageState();
}

class _MangaDetailsPageState extends State<MangaDetailsPage> {
  final _scroll = ScrollController();
  late Future<List<MangaChapter>> _chapters = mangaService.getChapters(widget.manga.id);
  late Future<MangaProgress?> _progress = MangaHistory.forManga(widget.manga);
  bool _newestFirst = true;
  bool _synopsisOpen = false;

  Manga get m => widget.manga;

  @override
  void initState() {
    super.initState();
    MangaHistory.revision.addListener(_refreshProgress);
  }

  @override
  void dispose() {
    MangaHistory.revision.removeListener(_refreshProgress);
    _scroll.dispose();
    super.dispose();
  }

  void _refreshProgress() => setState(() {
        _progress = MangaHistory.forManga(m);
      });

  void _back() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _read(List<MangaChapter> chapters, int index, {int page = 0}) =>
      openReader(context, manga: m, chapters: chapters, index: index, startPage: page);

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) _back();
        },
        child: ColoredBox(
          color: VyseColors.bg,
          child: Stack(children: [
            Positioned.fill(child: _Backdrop(url: m.cover, scroll: _scroll)),
            PageScrollbar(
              controller: _scroll,
              child: CustomScrollView(controller: _scroll, slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset - 8, Layout.topChrome(context) + (phone ? 10 : 22), right, phone ? 8 : 14),
                  sliver: SliverToBoxAdapter(child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: _back))),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, phone ? 28 : 44),
                  sliver: SliverToBoxAdapter(child: phone ? _phoneHero() : _wideHero()),
                ),
                _chapterSlivers(inset, right),
                SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cover(double w) => Container(
        width: w,
        height: w * 1.5,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 30, offset: const Offset(0, 14))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Hero(
          tag: widget.heroTag ?? 'manga/details/${m.id}',
          child: NetImage(url: m.cover, fallback: Icons.menu_book_rounded),
        ),
      );

  Widget _wideHero() => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        _cover((MediaQuery.sizeOf(context).width * .14).clamp(200.0, 280.0)),
        const SizedBox(width: 36),
        Expanded(child: _info()),
      ]);

  Widget _phoneHero() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: _cover(180)),
        const SizedBox(height: 22),
        _info(),
      ]);

  Widget _info() {
    final phone = Layout.isPhone(context);
    final meta = [m.type, m.year, m.status].nonNulls.where((s) => s.isNotEmpty).toList();
    final synopsis = m.synopsis?.trim() ?? '';
    return FadeSlideIn(
      offset: 14,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m.title, style: TextStyle(fontSize: phone ? 28 : 44, fontWeight: FontWeight.w800, letterSpacing: -1.3, height: 1.04)),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(children: [
            if (m.author != null && m.author!.isNotEmpty)
              TextSpan(text: m.author, style: TextStyle(color: VyseColors.text, fontWeight: FontWeight.w600)),
            for (final (i, x) in meta.indexed) TextSpan(text: i == 0 && (m.author ?? '').isEmpty ? x : '  ·  $x'),
          ]),
          style: const TextStyle(color: Color(0xFFC3C7D4), fontSize: 14),
        ),
        if (synopsis.isNotEmpty) ...[
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Pressable(
              onTap: () => setState(() => _synopsisOpen = !_synopsisOpen),
              builder: (context, _, _) => AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topLeft,
                child: Text(synopsis,
                    maxLines: _synopsisOpen ? null : 4,
                    overflow: _synopsisOpen ? null : TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFFC3C7D4), fontSize: 14, height: 1.6)),
              ),
            ),
          ),
        ],
        if (m.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in m.tags.take(12))
              TagPill(t, onTap: () => Navigator.of(context).push(ShellRoute(child: MangaPage(initialTag: t)))),
          ]),
        ],
        const SizedBox(height: 24),
        _actions(),
      ]),
    );
  }

  Widget _actions() => FutureBuilder<List<MangaChapter>>(
        future: _chapters,
        builder: (context, chaps) => FutureBuilder<MangaProgress?>(
          future: _progress,
          builder: (context, prog) {
            final order = readingOrder(chaps.data ?? const []);
            final p = prog.data;
            final resume = p != null && p.chapterIndex < order.length;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              PillButton(
                primary: true,
                icon: Icons.auto_stories_rounded,
                label: order.isEmpty
                    ? (chaps.connectionState == ConnectionState.waiting ? 'Caricamento…' : 'Nessun capitolo')
                    : resume
                        ? 'Continue ${order[p.chapterIndex].label}${p.page > 0 ? ' · p. ${p.page + 1}' : ''}'
                        : 'Inizia a leggere',
                onTap: order.isEmpty ? () {} : () => resume ? _read(order, p.chapterIndex, page: p.page) : _read(order, 0),
              ),
              ValueListenableBuilder<List<Manga>>(
                valueListenable: MangaFavorites.items,
                builder: (context, _, _) {
                  final on = MangaFavorites.has(m);
                  return PillButton(
                    icon: on ? Icons.check_rounded : Icons.add_rounded,
                    label: on ? 'Nei preferiti' : 'Preferito',
                    onTap: () => MangaFavorites.toggle(m),
                  );
                },
              ),
            ]);
          },
        ),
      );

  Widget _chapterSlivers(double inset, double right) => FutureBuilder<List<MangaChapter>>(
        future: _chapters,
        builder: (context, snap) {
          if (snap.hasError) {
            return SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile caricare i capitoli",
                body: 'Controlla la connessione e riprova.',
                action: ('Riprova', () => setState(() {
                      _chapters = mangaService.getChapters(m.id);
                    })),
              ),
            );
          }
          if (!snap.hasData) {
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
              sliver: SliverGrid.builder(
                gridDelegate: _grid,
                itemCount: 24,
                itemBuilder: (_, _) => const Shimmer(child: SkeletonBox(width: double.infinity, height: 60, radius: 10)),
              ),
            );
          }
          final order = readingOrder(snap.data!);
          if (order.isEmpty) {
            return const SliverToBoxAdapter(
              child: EmptyState(icon: Icons.menu_book_outlined, title: 'Ancora nessun capitolo', body: 'Ricontrolla più tardi.'),
            );
          }
          return FutureBuilder<MangaProgress?>(
            future: _progress,
            builder: (context, prog) {
              final current = prog.data?.chapterIndex;
              int indexAt(int i) => _newestFirst ? order.length - 1 - i : i;
              return SliverMainAxisGroup(slivers: [
                SliverToBoxAdapter(child: ShelfHeader(title: '${order.length} capitoli')),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 14),
                  sliver: SliverToBoxAdapter(
                    child: Wrap(spacing: 4, children: [
                      FilterChipPill(label: 'Dal più recente', selected: _newestFirst, onTap: () => setState(() => _newestFirst = true)),
                      FilterChipPill(label: 'Dal più vecchio', selected: !_newestFirst, onTap: () => setState(() => _newestFirst = false)),
                    ]),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
                  sliver: SliverGrid.builder(
                    gridDelegate: _grid,
                    itemCount: order.length,
                    itemBuilder: (context, i) {
                      final index = indexAt(i);
                      return _ChapterTile(
                        chapter: order[index],
                        current: index == current,
                        read: current != null && index < current,
                        onTap: () => index == current ? _read(order, index, page: prog.data!.page) : _read(order, index),
                      );
                    },
                  ),
                ),
              ]);
            },
          );
        },
      );

  static const _grid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 240,
    mainAxisExtent: 60,
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
  );
}

/// Full-screen backdrop, same recipe as the movie Details page: even dim, a heavier left side
/// behind the text, a melt into the page at the bottom, and more dark as you scroll.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.scroll});
  final String? url;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final bg = VyseColors.bg;
    return Stack(fit: StackFit.expand, children: [
      if (url != null)
        ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36, tileMode: TileMode.clamp),
            child: Transform.scale(scale: 1.15, child: NetImage(url: url)),
          ),
        ),
      ColoredBox(color: bg.withValues(alpha: .58)),
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
            stops: const [0, .3, .65],
          ),
        ),
      ),
      IgnorePointer(
        child: ListenableBuilder(
          listenable: scroll,
          builder: (context, _) {
            final t = scroll.hasClients ? (scroll.offset / 500).clamp(0.0, 1.0) : 0.0;
            return ColoredBox(color: bg.withValues(alpha: .55 * t));
          },
        ),
      ),
    ]);
  }
}

/// One chapter: a flat tile with the white hover outline. Read chapters dim; the one you're on
/// carries an amber edge.
class _ChapterTile extends StatelessWidget {
  const _ChapterTile({required this.chapter, required this.current, required this.read, required this.onTap});
  final MangaChapter chapter;
  final bool current;
  final bool read;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlineCard(
        label: chapter.label,
        radius: 10,
        onTap: onTap,
        builder: (hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: hovered || current ? VyseColors.surfaceHi : const Color(0xFF0D0F18),
          child: Row(children: [
            AnimatedContainer(duration: const Duration(milliseconds: 200), width: 3, color: current ? VyseColors.accent : Colors.transparent),
            const SizedBox(width: 13),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chapter.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: read && !hovered ? VyseColors.textFaint : VyseColors.text,
                    )),
                if (chapter.subtitle != null || current) ...[
                  const SizedBox(height: 2),
                  Text(current ? 'In lettura' : chapter.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: current ? VyseColors.accent : VyseColors.textFaint)),
                ],
              ]),
            ),
            if (read)
              Padding(padding: EdgeInsets.only(right: 12), child: Icon(Icons.check_rounded, size: 16, color: VyseColors.textFaint)),
          ]),
        ),
      );
}
