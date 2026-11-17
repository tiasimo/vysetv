import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/manga_library.dart';
import '../models/manga/manga.dart';
import '../models/manga/manga_chapter.dart';
import '../widgets/common.dart';
import '../widgets/section_chrome.dart';
import 'shell.dart' show WindowBar;

enum ReaderMode { scroll, paged }

/// Opens the reader full screen, over the rail.
Future<void> openReader(
  BuildContext context, {
  required Manga manga,
  required List<MangaChapter> chapters,
  required int index,
  int startPage = 0,
}) =>
    Navigator.of(context, rootNavigator: true).push(ShellRoute(
      child: MangaReaderPage(manga: manga, chapters: chapters, index: index, startPage: startPage),
    ));

/// Continue reading: straight into the saved chapter, at the saved page.
Future<void> resumeReading(BuildContext context, MangaProgress p) async {
  showToast(context, Text('Opening ${p.chapterLabel ?? 'Chapter ${p.chapterIndex + 1}'}…'), icon: Icons.auto_stories_rounded);
  try {
    final order = readingOrder(await mangaService.getChapters(p.manga.id));
    if (!context.mounted || order.isEmpty) return;
    await openReader(context, manga: p.manga, chapters: order, index: p.chapterIndex.clamp(0, order.length - 1), startPage: p.page);
  } catch (_) {
    if (context.mounted) showToast(context, const Text("Impossibile caricare questa serie"), icon: Icons.error_outline_rounded);
  }
}

/// Full-screen reader with two modes: one long vertical strip, or one page at a time that you
/// flip. Tap to show / hide the bar (in page mode the left and right thirds flip).
/// Keys: ← → page (page mode) or chapter (scroll mode), Space next, M switches mode, Esc closes.
class MangaReaderPage extends StatefulWidget {
  const MangaReaderPage({super.key, required this.manga, required this.chapters, required this.index, this.startPage = 0});
  final Manga manga;

  /// In reading order, oldest first.
  final List<MangaChapter> chapters;
  final int index;
  final int startPage;

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage> {
  static const _modeKey = 'manga.readerMode';
  static ReaderMode _lastMode = ReaderMode.scroll;

  final _scroll = ScrollController();
  final _focus = FocusNode();
  PageController? _pager;
  var _keys = <GlobalKey>[];

  late ReaderMode _mode = _lastMode;
  late int _index = widget.index;
  late int _start = widget.startPage;
  late Future<List<String>> _pages = _load();
  int _count = 0;
  int _page = 0;
  bool _chrome = true;
  double _scrollFraction = 0;

  /// Scroll mode: the page we're holding on screen while the images above it load.
  int? _pin;
  DateTime _pinUntil = DateTime(0);
  Timer? _saveTimer;

  MangaChapter get _chapter => widget.chapters[_index];
  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.chapters.length - 1;

  @override
  void initState() {
    super.initState();
    _restoreMode();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _save();
    _scroll.dispose();
    _pager?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _restoreMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = ReaderMode.values.asNameMap()[prefs.getString(_modeKey)];
      if (saved != null && saved != _mode && mounted) _switchMode(saved, persist: false);
    } catch (_) {}
  }

  Future<List<String>> _load() async {
    final pages = await mangaService.getChapterImages(_chapter.id);
    _count = pages.length;
    _page = _start.clamp(0, math.max(0, pages.length - 1));
    _keys = List.generate(pages.length, (_) => GlobalKey());
    _pager?.dispose();
    _pager = PageController(initialPage: _page);
    _pin = _page > 0 ? _page : null;
    _pinUntil = DateTime.now().add(const Duration(seconds: 10));
    if (_pin != null) WidgetsBinding.instance.addPostFrameCallback((_) => _repin());
    _save();
    return pages;
  }

  // ───────── progress ─────────

  void _save() => MangaHistory.save(widget.manga, _index, _page, widget.chapters).catchError((Object _) {});

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
  }

  void _setPage(int p) {
    if (p == _page) return;
    setState(() => _page = p);
    _saveSoon();
  }

  // ───────── navigation ─────────

  void _go(int index) {
    if (index < 0 || index >= widget.chapters.length) return;
    _saveTimer?.cancel();
    _save();
    setState(() {
      _index = index;
      _start = 0;
      _page = 0;
      _count = 0;
      _scrollFraction = 0;
      _chrome = true;
      _pages = _load();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _switchMode(ReaderMode m, {bool persist = true}) {
    if (m == _mode) return;
    _lastMode = m;
    setState(() {
      _mode = m;
      if (m == ReaderMode.paged) {
        _pager?.dispose();
        _pager = PageController(initialPage: _page);
      } else {
        _pin = _page > 0 ? _page : null;
        _pinUntil = DateTime.now().add(const Duration(seconds: 10));
      }
    });
    if (m == ReaderMode.scroll) WidgetsBinding.instance.addPostFrameCallback((_) => _repin());
    if (persist) {
      SharedPreferences.getInstance().then((p) => p.setString(_modeKey, m.name)).catchError((Object _) => false);
      showToast(context, Text(m == ReaderMode.paged ? 'Modalità pagina' : 'Modalità scorrimento'),
          icon: m == ReaderMode.paged ? Icons.auto_stories_rounded : Icons.view_day_rounded);
    }
  }

  void _flip(int dir) {
    final pager = _pager;
    if (pager == null || !pager.hasClients) return;
    final target = (pager.page?.round() ?? _page) + dir;
    if (target < 0) {
      if (_hasPrev) _go(_index - 1);
      return;
    }
    if (target > _count) {
      if (_hasNext) _go(_index + 1);
      return;
    }
    pager.animateToPage(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  void _scrollBy(double f) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _pin = null;
    _scroll.animateTo((p.pixels + p.viewportDimension * f).clamp(0.0, p.maxScrollExtent),
        duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  void _close() => Navigator.of(context).maybePop();

  // ───────── scroll mode ─────────

  /// Keeps the saved page in view while earlier pages load and change height.
  void _repin() {
    final pin = _pin;
    if (pin == null || _mode != ReaderMode.scroll) return;
    if (DateTime.now().isAfter(_pinUntil)) {
      _pin = null;
      return;
    }
    if (pin >= _keys.length) return;
    final ctx = _keys[pin].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx);
  }

  void _repinSoon() {
    if (_pin != null) WidgetsBinding.instance.addPostFrameCallback((_) => _repin());
  }

  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification && n.direction != ScrollDirection.idle) _pin = null;
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      final m = n.metrics;
      final f = m.maxScrollExtent <= 0 ? 0.0 : (m.pixels / m.maxScrollExtent).clamp(0.0, 1.0);
      // Which page sits at the top third of the screen.
      final line = MediaQuery.sizeOf(context).height * .35;
      var current = 0;
      for (var i = 0; i < _keys.length; i++) {
        final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) continue;
        if (box.localToGlobal(Offset.zero).dy <= line) {
          current = i;
        } else {
          break;
        }
      }
      if ((f - _scrollFraction).abs() > .002) setState(() => _scrollFraction = f);
      if (_pin == null) _setPage(current);
      // Scrolling down tucks the bar away; scrolling up brings it back.
      if (n is ScrollUpdateNotification && n.dragDetails != null) {
        final down = (n.scrollDelta ?? 0) > 0;
        if (down && _chrome && m.pixels > 80) setState(() => _chrome = false);
        if (!down && !_chrome) setState(() => _chrome = true);
      }
    }
    return false;
  }

  // ───────── build ─────────

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final size = MediaQuery.sizeOf(context);
    final pageW = phone ? size.width : size.width.clamp(0.0, 900.0);
    final top = Layout.windowChrome(context);
    final paged = _mode == ReaderMode.paged;
    final progress = paged ? (_count == 0 ? 0.0 : (_page + 1) / _count) : _scrollFraction;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.keyM): () => _switchMode(paged ? ReaderMode.scroll : ReaderMode.paged),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => paged ? _flip(1) : _go(_index + 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => paged ? _flip(-1) : _go(_index - 1),
        const SingleActivator(LogicalKeyboardKey.space): () => paged ? _flip(1) : _scrollBy(.85),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => paged ? _flip(1) : _scrollBy(.85),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => paged ? _flip(-1) : _scrollBy(-.85),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            FutureBuilder<List<String>>(
              future: _pages,
              builder: (context, snap) {
                if (snap.hasError) {
                  return EmptyState(
                    icon: Icons.broken_image_outlined,
                    title: "Impossibile caricare questo capitolo",
                    body: 'Controlla la connessione e riprova.',
                    action: ('Riprova', () => setState(() {
                          _pages = _load();
                        })),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                    child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: VyseColors.accent)),
                  );
                }
                final pages = snap.data!;
                return paged ? _pagedView(pages, top) : _scrollView(pages, pageW, top);
              },
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              top: _chrome ? 0 : -(top + 80),
              left: 0,
              right: 0,
              child: _bar(top),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 3,
                  width: size.width * progress,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [VyseColors.accentHot, VyseColors.accent]),
                    boxShadow: [BoxShadow(color: Color(0x99FF8A1A), blurRadius: 8)],
                  ),
                ),
              ),
            ),
            if (isDesktopNative) const Positioned(top: 0, left: 0, right: 0, child: WindowBar()),
          ]),
        ),
      ),
    );
  }

  Widget _scrollView(List<String> pages, double pageW, double top) => GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: SingleChildScrollView(
            key: ValueKey('scroll/$_index'),
            controller: _scroll,
            padding: EdgeInsets.only(top: top + 64, bottom: 40),
            child: Center(
              child: SizedBox(
                width: pageW,
                child: Column(children: [
                  for (var i = 0; i < pages.length; i++)
                    KeyedSubtree(
                      key: _keys[i],
                      child: _StripPage(url: pages[i], width: pageW, number: i + 1, onLoaded: _repinSoon),
                    ),
                  _endCard(),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _pagedView(List<String> pages, double top) => LayoutBuilder(
        builder: (context, c) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final x = d.localPosition.dx / c.maxWidth;
            if (x < .3) {
              _flip(-1);
            } else if (x > .7) {
              _flip(1);
            } else {
              setState(() => _chrome = !_chrome);
            }
          },
          child: PageView.builder(
            key: ValueKey('paged/$_index'),
            controller: _pager,
            itemCount: pages.length + 1,
            onPageChanged: (i) {
              _setPage(math.min(i, _count - 1));
              // Warm the next couple of pages so flipping never waits.
              for (final j in [i + 1, i + 2]) {
                if (j < pages.length) precacheImage(CachedNetworkImageProvider(pages[j], headers: mangaImageHeaders(pages[j])), context).catchError((Object _) {});
              }
            },
            itemBuilder: (context, i) => i == pages.length
                ? Center(child: SizedBox(width: math.min(c.maxWidth, 520), child: _endCard()))
                : InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Padding(
                      padding: EdgeInsets.only(top: top + 8, bottom: 8),
                      child: CachedNetworkImage(
                        imageUrl: pages[i],
                        httpHeaders: mangaImageHeaders(pages[i]),
                        fit: BoxFit.contain,
                        fadeInDuration: const Duration(milliseconds: 150),
                        placeholder: (_, _) => Center(
                          child: Text('${i + 1}', style: const TextStyle(color: VyseColors.textFaint, fontSize: 28, fontWeight: FontWeight.w800)),
                        ),
                        errorWidget: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, color: VyseColors.textFaint, size: 32)),
                      ),
                    ),
                  ),
          ),
        ),
      );

  Widget _bar(double top) {
    final paged = _mode == ReaderMode.paged;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, top + 8, 12, 0),
      child: Glass(
        radius: 16,
        opacity: .7,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(children: [
          GlassIconButton(icon: Icons.arrow_back_rounded, label: 'Indietro (Esc)', size: 38, onTap: _close),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(widget.manga.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              Text(
                [_chapter.label, ?_chapter.subtitle, if (_count > 0) '${_page + 1} / $_count'].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim),
              ),
            ]),
          ),
          GlassIconButton(
            icon: paged ? Icons.view_day_rounded : Icons.auto_stories_rounded,
            label: paged ? 'Passa alla modalità scorrimento (M)' : 'Passa alla modalità pagina (M)',
            size: 38,
            onTap: () => _switchMode(paged ? ReaderMode.scroll : ReaderMode.paged),
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.skip_previous_rounded,
            label: 'Capitolo precedente',
            size: 38,
            onTap: _hasPrev ? () => _go(_index - 1) : () {},
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.skip_next_rounded,
            label: 'Capitolo successivo',
            size: 38,
            onTap: _hasNext ? () => _go(_index + 1) : () {},
          ),
        ]),
      ),
    );
  }

  Widget _endCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Fine di ${_chapter.label}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          if (_hasNext)
            PillButton(
              primary: true,
              icon: Icons.skip_next_rounded,
              label: 'Prossimo: ${widget.chapters[_index + 1].label}',
              onTap: () => _go(_index + 1),
            )
          else ...[
            const Text("Sei in pari.", style: TextStyle(color: VyseColors.textDim)),
            const SizedBox(height: 16),
            PillButton(icon: Icons.arrow_back_rounded, label: 'Torna alla serie', onTap: _close),
          ],
        ]),
      );
}

class _StripPage extends StatelessWidget {
  const _StripPage({required this.url, required this.width, required this.number, required this.onLoaded});
  final String url;
  final double width;
  final int number;

  /// Called whenever the image is (re)built loaded, so the reader can re-pin its saved page.
  final VoidCallback onLoaded;

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
        imageUrl: url,
        httpHeaders: mangaImageHeaders(url),
        width: width,
        fit: BoxFit.fitWidth,
        fadeInDuration: const Duration(milliseconds: 200),
        imageBuilder: (context, provider) {
          onLoaded();
          return Image(image: provider, width: width, fit: BoxFit.fitWidth);
        },
        placeholder: (_, _) => SizedBox(
          height: width * 1.45,
          child: Center(
            child: Text('$number', style: const TextStyle(color: VyseColors.textFaint, fontSize: 28, fontWeight: FontWeight.w800)),
          ),
        ),
        errorWidget: (_, _, _) => SizedBox(
          height: width * .6,
          child: const Center(child: Icon(Icons.broken_image_outlined, color: VyseColors.textFaint, size: 32)),
        ),
      );
}


/// Lorewatch: MangaWorld's image servers want a browser's User-Agent and the site as Referer.
Map<String, String>? mangaImageHeaders(String url) => url.contains('mangaworld')
    ? const {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36',
        'Referer': 'https://www.mangaworld.mx/',
      }
    : null;
