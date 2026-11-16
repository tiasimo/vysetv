import 'dart:async';

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/audiobook_player.dart';
import '../models/audiobook/audiobook_model.dart';
import '../widgets/audiobook_widgets.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'audiobook_details_page.dart';

Future<void> openAudiobook(BuildContext context, Audiobook b) =>
    Navigator.of(context).push(ShellRoute(child: AudiobookDetailsPage(book: b)));

/// Audiobooks are search-driven: a big search bar, Continue listening, and a few ideas to start from.
class AudiobooksPage extends StatefulWidget {
  const AudiobooksPage({super.key});

  @override
  State<AudiobooksPage> createState() => _AudiobooksPageState();
}

class _AudiobooksPageState extends State<AudiobooksPage> {
  /// Shelves on the landing page, each filled by a search. Cached for the session so the tab
  /// opens instantly the second time.
  static const _shelves = [
    ('Popular right now', 'bestseller'),
    ('Fantasy', 'fantasy'),
    ('Mystery & thriller', 'mystery thriller'),
    ('Science fiction', 'science fiction'),
    ('Self-improvement', 'self help'),
    ('Biography & memoir', 'biography'),
    ('Classics', 'classic novel'),
  ];
  static final _shelfCache = <String, Future<List<Audiobook>>>{};

  static Future<List<Audiobook>> _shelf(String q) =>
      _shelfCache[q] ??= audiobookService.search(q).catchError((Object e) {
        _shelfCache.remove(q);
        throw e;
      });

  final _scroll = ScrollController();
  final _text = TextEditingController();
  Timer? _debounce;
  String _query = '';
  Future<List<Audiobook>>? _results;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), () => _search(_text.text));
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  void _search(String q) {
    q = q.trim();
    if (q == _query) return;
    setState(() {
      _query = q;
      _results = q.isEmpty ? null : audiobookService.search(q);
    });
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, top, right, 18),
              sliver: const SliverToBoxAdapter(
                child: SectionHeader(title: 'Audiobooks', subtitle: 'Thousands of books, read aloud'),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 26),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: FadeSlideIn(
                      delay: const Duration(milliseconds: 90),
                      offset: 10,
                      child: FutureBuilder<List<Audiobook>>(
                        future: _results,
                        builder: (context, snap) => VyseSearchField(
                          controller: _text,
                          hint: 'Titles and authors',
                          autofocus: true,
                          busy: _results != null && snap.connectionState == ConnectionState.waiting,
                          onSubmit: _search,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 340),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                  child: _query.isEmpty
                      ? _idle()
                      : Padding(
                          key: ValueKey('q/$_query'),
                          padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
                          child: _ResultList(query: _query, future: _results!),
                        ),
                ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }

  Widget _idle() {
    final w = Layout.isPhone(context) ? 128.0 : (MediaQuery.sizeOf(context).width * .1).clamp(150.0, 190.0);
    return Column(key: const ValueKey('idle'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      ValueListenableBuilder<List<BookProgress>>(
        valueListenable: AudiobookPlayer.instance.recents,
        builder: (context, recents, _) => recents.isEmpty
            ? const SizedBox(width: double.infinity)
            : Shelf<BookProgress>(
                key: ValueKey('recents/${recents.length}/${recents.first.book.uuid}'),
                title: 'Continue listening',
                load: () async => recents,
                itemWidth: w,
                itemHeight: w,
                itemBuilder: (context, r, _) => BookCard(
                  book: r.book,
                  progress: r,
                  onTap: () => openAudiobook(context, r.book),
                  onRemove: () => AudiobookPlayer.instance.forget(r.book),
                ),
              ),
      ),
      for (final (title, q) in _shelves)
        Shelf<Audiobook>(
          title: title,
          load: () => _shelf(q),
          itemWidth: w,
          itemHeight: w,
          itemBuilder: (context, b, _) => BookCard(book: b, onTap: () => openAudiobook(context, b)),
        ),
    ]);
  }
}

/// Covers in a grid sized like Discover's posters; columns follow the width.
class _BookGrid extends StatelessWidget {
  const _BookGrid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        const gap = 12.0;
        final maxW = Layout.isPhone(context) ? 128.0 : 190.0;
        final cols = ((c.maxWidth + gap) / (maxW + gap)).ceil().clamp(1, 99);
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: 14, children: [for (final ch in children) SizedBox(width: w, height: w, child: ch)]);
      });
}

class _ResultList extends StatelessWidget {
  const _ResultList({required this.query, required this.future});
  final String query;
  final Future<List<Audiobook>> future;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Audiobook>>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(icon: Icons.wifi_off_rounded, title: "Couldn't search right now", body: 'Check your connection and try again.');
          }
          final books = snap.data;
          if (books == null) {
            return Shimmer(
              child: _BookGrid(children: [for (var i = 0; i < 6; i++) const SkeletonBox(width: double.infinity, height: double.infinity, radius: 7)]),
            );
          }
          if (books.isEmpty) {
            return EmptyState(icon: Icons.search_off_rounded, title: 'No audiobooks for "$query"', body: 'Try the author, or fewer words.');
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ShelfHeaderText('${books.length} results'),
            _BookGrid(children: [
              for (final (i, b) in books.indexed)
                FadeSlideIn(
                  delay: Duration(milliseconds: 25 * (i % 14)),
                  offset: 8,
                  child: BookCard(book: b, progress: AudiobookPlayer.instance.progressFor(b), onTap: () => openAudiobook(context, b)),
                ),
            ]),
          ]);
        },
      );
}

class ShelfHeaderText extends StatelessWidget {
  const ShelfHeaderText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -.2)),
      );
}
