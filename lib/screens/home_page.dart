import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/perf.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/hero_carousel.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../data/watch_progress.dart';
import '../widgets/continue_watching.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _idleToSpotlight = Duration(seconds: 10);

  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _heroKey = GlobalKey<HeroCarouselState>();
  final _feed = HomeFeed.instance;
  late Future<List<Media>> _hero = _feed.hero();

  bool _immersive = false;
  Timer? _idle;
  DateTime _lastExit = DateTime(0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _armIdle();
  }

  @override
  void dispose() {
    _idle?.cancel();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _atTop => !_scroll.hasClients || _scroll.offset <= 1;

  /// Leaving spotlight briefly blocks re-entry so a trackpad's momentum can't bounce us back in.
  bool get _cooledDown =>
      DateTime.now().difference(_lastExit) > const Duration(milliseconds: 600);

  /// Scrolling back up to the top (wheel, trackpad, scrollbar drag or touch) opens the spotlight.
  void _onScroll() {
    if (_immersive || !_atTop || !_cooledDown) return;
    if (_scroll.position.userScrollDirection == ScrollDirection.forward) {
      _setImmersive(true);
    }
  }

  void _exitFromGesture() {
    if (_immersive) _setImmersive(false);
  }

  /// Sitting still at the top of Home for a while drifts into spotlight mode.
  void _armIdle() {
    _idle?.cancel();
    if (_immersive) return;
    _idle = Timer(_idleToSpotlight, () {
      if (mounted && _atTop) _setImmersive(true);
    });
  }

  void _setImmersive(bool value) {
    // phones never enter the spotlight, but must always be able to leave it (e.g. after rotating
    // from landscape, where they count as wide, back to portrait)
    if (value == _immersive || (value && Layout.isPhone(context))) return;
    if (value && !_atTop) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    }
    perfMark(value ? 'enter spotlight' : 'esci dal primo piano');
    setState(() => _immersive = value);
    if (!value) {
      _lastExit = DateTime.now();
      _armIdle();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hero = _heroKey.currentState;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        hero?.next();
      case LogicalKeyboardKey.arrowLeft:
        hero?.prev();
      case LogicalKeyboardKey.arrowUp when _atTop:
        _setImmersive(true);
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.escape
          when _immersive:
        _setImmersive(false);
      default:
        return KeyEventResult.ignored;
    }
    _armIdle();
    return KeyEventResult.handled;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    _armIdle();
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy;
    if (_immersive && dy > 0) {
      _exitFromGesture();
    } else if (!_immersive && dy < 0 && _atTop && _cooledDown) {
      // Wheel up while already at the top (the list can't move, so _onScroll won't fire).
      _setImmersive(true);
    }
  }

  /// Trackpads on desktop send pan gestures rather than wheel ticks.
  void _onPanZoom(PointerPanZoomUpdateEvent e) {
    final dy = e.panDelta.dy;
    if (_immersive && dy < -4) {
      _exitFromGesture();
    } else if (!_immersive && dy > 4 && _atTop && _cooledDown) {
      _setImmersive(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final ff = Layout.of(context);
    final phone = ff == FormFactor.phone;
    final w = size.width;
    // rotated to portrait while in the spotlight: back to the normal page
    if (phone && _immersive) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _setImmersive(false) : null);

    final heroH = phone
        ? (size.height * .74).clamp(460.0, 700.0)
        : (size.height * .9).clamp(500.0, 1200.0);

    final posterW = switch (ff) {
      FormFactor.phone => 108.0,
      FormFactor.tablet => 128.0,
      FormFactor.desktop => (w * .106).clamp(140.0, 200.0),
    };
    final landW = switch (ff) {
      FormFactor.phone => 230.0,
      FormFactor.tablet => 250.0,
      FormFactor.desktop => (w * .2).clamp(250.0, 380.0),
    };
    final topW = switch (ff) {
      FormFactor.phone => 200.0,
      FormFactor.tablet => 210.0,
      FormFactor.desktop => (w * .14).clamp(200.0, 270.0),
    };

    Widget posters(String title, Future<List<Media>> Function() load) =>
        Shelf<Media>(
          title: title,
          load: load,
          itemWidth: posterW,
          itemHeight: posterW * 1.5,
          itemBuilder: (_, m, _) =>
              PosterCard(media: m, heroTag: 'home/$title/${m.key}'),
        );
    Widget landscape(String title, Future<List<Media>> Function() load) =>
        Shelf<Media>(
          title: title,
          load: load,
          itemWidth: landW,
          itemHeight: landW * 9 / 16,
          itemBuilder: (_, m, _) => LandscapeCard(media: m),
        );
    Widget top10(String title, Future<List<Media>> Function() load) =>
        Shelf<Media>(
          title: title,
          load: load,
          maxItems: 10,
          itemWidth: topW,
          itemHeight: topW * 9 / 16,
          itemBuilder: (_, m, i) => Top10Card(media: m, rank: i + 1),
        );

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerHover: (_) => _armIdle(),
        onPointerDown: (_) {
          _armIdle();
          _focus.requestFocus();
        },
        onPointerSignal: _onPointerSignal,
        onPointerPanZoomUpdate: _onPanZoom,
        child: PageScrollbar(
          controller: _scroll,
          hidden: _immersive,
          // Touch: in spotlight the list is locked, so a swipe up is what brings the rows back.
          child: GestureDetector(
            onVerticalDragUpdate: _immersive
                ? (d) {
                    if (d.delta.dy < -6) _exitFromGesture();
                  }
                : null,
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.only(
                bottom: phone ? 90 + MediaQuery.paddingOf(context).bottom : 40,
              ),
              physics: _immersive ? const NeverScrollableScrollPhysics() : null,
              children: [
                FutureBuilder<List<Media>>(
                  future: _hero,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return _HeroError(
                        onRetry: () => setState(() => _hero = _feed.hero()),
                      );
                    }
                    final items = (snap.data ?? const <Media>[])
                        .where((m) => m.backdropPath != null)
                        .take(8)
                        .toList();
                    if (items.isEmpty) {
                      return SizedBox(
                        height: heroH,
                        child: const Shimmer(
                          child: ColoredBox(
                            color: VyseColors.surface,
                            child: SizedBox.expand(),
                          ),
                        ),
                      );
                    }
                    return HeroCarousel(
                      key: _heroKey,
                      items: items,
                      scroll: _scroll,
                      immersive: _immersive,
                      height: _immersive ? size.height : heroH,
                    );
                  },
                ),
                IgnorePointer(
                  ignoring: _immersive,
                  child: _FadeAway(
                    hidden: _immersive,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: phone ? 8 : 4),
                        const ContinueWatchingRow(),
                        landscape('Di tendenza ora', _feed.hero),
                        _BecauseRow(hero: _hero, feed: _feed, posterWidth: posterW),
                        top10("I 10 film più visti oggi", _feed.topMoviesToday),
                        posters('Le serie che guardano tutti', _feed.popularTv),
                        Shelf<WatchProvider>(
                          title: 'Servizi di streaming',
                          load: _feed.providers,
                          itemWidth: phone ? 120 : 172,
                          itemHeight: phone ? 92 : 118,
                          maxItems: 40,
                          itemBuilder: (_, p, _) => PlatformTile(provider: p),
                        ),
                        landscape('Ora al cinema', _feed.nowPlaying),
                        posters('Anime consigliati', _feed.anime),
                        top10("Le 10 serie più viste oggi", _feed.topTvToday),
                        const GenreGrid(),
                        posters('I grandi di sempre', _feed.topRated),
                        landscape('In arrivo', _feed.upcoming),
                        const _Footer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades the rows out under a background-coloured overlay instead of with Opacity (which
/// composites every poster through an off-screen buffer each frame). The rows keep painting
/// underneath (they're off-screen in the spotlight anyway) so their layers and textures survive
/// the round trip instead of being rebuilt and re-uploaded on the way back.
class _FadeAway extends StatelessWidget {
  const _FadeAway({required this.hidden, required this.child});
  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: hidden ? 1 : 0),
    duration: const Duration(milliseconds: 380),
    curve: Curves.easeOut,
    child: child,
    builder: (context, t, child) => Stack(
      children: [
        child!,
        if (t > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: VyseColors.bg.withValues(alpha: t)),
            ),
          ),
      ],
    ),
  );
}

class _HeroError extends StatelessWidget {
  const _HeroError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 420,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 36,
            color: VyseColors.textFaint,
          ),
          const SizedBox(height: 12),
          const Text(
            "Impossibile raggiungere TMDB. Controlla la connessione.",
            style: TextStyle(color: VyseColors.textDim),
          ),
          const SizedBox(height: 14),
          TextButton(onPressed: onRetry, child: const Text('Riprova')),
        ],
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(Layout.inset(context), 18, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: VyseColors.stroke),
        const SizedBox(height: 22),
        const Row(
          children: [
            VyseMark(size: 24),
            SizedBox(width: 8),
            VyseWordmark(fontSize: 15),
          ],
        ),
        const SizedBox(height: 14),
        const Text(
          'Questo prodotto usa le API di TMDB ma non è approvato né certificato da TMDB.',
          style: TextStyle(fontSize: 11, color: VyseColors.textFaint),
        ),
      ],
    ),
  );
}

/// "If you like …": recommendations seeded by what you're watching (the newest Continue
/// watching title), or today's top trending title when that's empty. The title is a picker.
class _BecauseRow extends StatefulWidget {
  const _BecauseRow({required this.hero, required this.feed, required this.posterWidth});
  final Future<List<Media>> hero;
  final HomeFeed feed;
  final double posterWidth;

  @override
  State<_BecauseRow> createState() => _BecauseRowState();
}

class _BecauseRowState extends State<_BecauseRow> {
  String? _pickedKey; // chosen in the menu; otherwise the default seed

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<WatchEntry>>(
    valueListenable: WatchProgress.entries,
    builder: (context, entries, _) => FutureBuilder<List<Media>>(
      future: widget.hero,
      builder: (context, snap) {
        final watching = [for (final e in entries) if (e.inContinue && !e.media.anime) e.media];
        final keys = {for (final m in watching) m.key};
        final trending = [for (final m in snap.data ?? const <Media>[]) if (!keys.contains(m.key)) m].take(8).toList();
        final all = [...watching, ...trending];
        if (all.isEmpty) return const SizedBox.shrink();
        final seed = all.where((m) => m.key == _pickedKey).firstOrNull ?? all.first;
        final w = widget.posterWidth;
        return Shelf<Media>(
          key: ValueKey('because/${seed.key}'),
          title: 'Se ti è piaciuto ${seed.title}',
          titleWidget: _SeedPicker(
            seed: seed,
            watching: watching,
            trending: trending,
            onPick: (m) => setState(() => _pickedKey = m.key),
          ),
          load: () => widget.feed.because(seed),
          itemWidth: w,
          itemHeight: w * 1.5,
          itemBuilder: (_, m, _) => PosterCard(media: m, heroTag: 'home/because/${seed.key}/${m.key}'),
        );
      },
    ),
  );
}

/// "If you like [Title ▾]": the title opens a menu of what you're watching and what's trending.
class _SeedPicker extends StatelessWidget {
  const _SeedPicker({required this.seed, required this.watching, required this.trending, required this.onPick});
  final Media seed;
  final List<Media> watching;
  final List<Media> trending;
  final ValueChanged<Media> onPick;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return Row(children: [
      const Text('Se ti è piaciuto '),
      Flexible(
        child: MenuAnchor(
          alignmentOffset: const Offset(0, 6),
          style: MenuStyle(
            backgroundColor: const WidgetStatePropertyAll(Color(0xF7101118)),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(18),
            shadowColor: const WidgetStatePropertyAll(Color(0xCC000000)),
            padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
            maximumSize: WidgetStatePropertyAll(Size(phone ? 300 : 340, 440)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withValues(alpha: .08))),
            ),
          ),
          menuChildren: [
            if (watching.isNotEmpty) ...[
              const _MenuLabel('CONTINUA A GUARDARE'),
              for (final m in watching) _SeedItem(media: m, selected: m.key == seed.key, onTap: () => onPick(m)),
            ],
            if (trending.isNotEmpty) ...[
              if (watching.isNotEmpty) Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), color: Colors.white.withValues(alpha: .07)),
              const _MenuLabel('TRENDING'),
              for (final m in trending) _SeedItem(media: m, selected: m.key == seed.key, onTap: () => onPick(m)),
            ],
          ],
          builder: (context, controller, _) => Pressable(
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: VyseColors.accent.withValues(alpha: hovered || controller.isOpen ? .16 : .08),
                border: Border.all(color: VyseColors.accent.withValues(alpha: hovered || controller.isOpen ? .45 : .2)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(seed.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                AnimatedRotation(
                  turns: controller.isOpen ? .5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: VyseColors.accent),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Text(text, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.textFaint)),
  );
}

class _SeedItem extends StatelessWidget {
  const _SeedItem({required this.media, required this.selected, required this.onTap});
  final Media media;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    onPressed: onTap,
    style: ButtonStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
      overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: .06)),
      minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
    ),
    child: Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          width: 30,
          height: 45,
          child: media.poster() == null
              ? const ColoredBox(color: VyseColors.surface)
              : CachedNetworkImage(imageUrl: media.poster()!, fit: BoxFit.cover, errorWidget: (_, _, _) => const ColoredBox(color: VyseColors.surface)),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(
            media.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: selected ? Colors.white : const Color(0xFFD5D7E2)),
          ),
          const SizedBox(height: 2),
          Text(
            [media.kind, media.year ?? ''].where((s) => s.isNotEmpty).join('  ·  '),
            style: const TextStyle(fontSize: 11, color: VyseColors.textFaint),
          ),
        ]),
      ),
      if (selected) ...[
        const SizedBox(width: 8),
        const Icon(Icons.check_rounded, size: 18, color: VyseColors.accent),
      ],
    ]),
  );
}

