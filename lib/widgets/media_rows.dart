import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/discover.dart';
import '../data/tmdb.dart';
import 'common.dart';

const _cardRadius = 7.0;

/// Titled horizontal shelf: small header, arrow paging on desktop, skeletons, staggered entrance.
class Shelf<T> extends StatefulWidget {
  const Shelf({
    super.key,
    required this.title,
    required this.load,
    required this.itemWidth,
    required this.itemHeight,
    required this.itemBuilder,
    this.spacing = 10,
    this.maxItems = 20,
    this.titleWidget,
  });

  final String title;

  /// Shown instead of [title] when set.
  final Widget? titleWidget;
  final Future<List<T>> Function() load;
  final double itemWidth;
  final double itemHeight;
  final double spacing;
  final int maxItems;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  @override
  State<Shelf<T>> createState() => _ShelfState<T>();
}

class _ShelfState<T> extends State<Shelf<T>> {
  final _scroll = ScrollController();
  late Future<List<T>> _future = widget.load();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = (p.pixels + dir * p.viewportDimension * .8).clamp(0.0, p.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 600), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final phone = Layout.isPhone(context);

    return Padding(
      padding: EdgeInsets.only(bottom: phone ? 22 : 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShelfHeader(title: widget.title, titleWidget: widget.titleWidget, onPrev: phone ? null : () => _page(-1), onNext: phone ? null : () => _page(1)),
          SizedBox(
            // vertical room so the hover outline isn't clipped
            height: widget.itemHeight + 8,
            child: FutureBuilder<List<T>>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) {
                  return _RowError(
                    onRetry: () => setState(() {
                      _future = widget.load();
                    }),
                  );
                }
                final data = snap.data;
                final count = data == null ? 10 : math.min(data.length, widget.maxItems);
                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus},
                  ),
                  child: ListView.separated(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.fromLTRB(inset, 4, phone ? 16 : 40, 4),
                    itemCount: count,
                    separatorBuilder: (_, _) => SizedBox(width: widget.spacing),
                    itemBuilder: (context, i) => SizedBox(
                      width: widget.itemWidth,
                      child: data == null
                          ? Shimmer(
                              child: SkeletonBox(width: widget.itemWidth, height: widget.itemHeight, radius: _cardRadius),
                            )
                          : FadeSlideIn(
                              delay: Duration(milliseconds: 35 * math.min(i, 10)),
                              offset: 10,
                              child: widget.itemBuilder(context, data[i], i),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ShelfHeader extends StatelessWidget {
  const ShelfHeader({super.key, required this.title, this.titleWidget, this.onPrev, this.onNext});
  final String title;
  final Widget? titleWidget;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return Padding(
      padding: EdgeInsets.only(left: Layout.inset(context), right: phone ? 16 : 40, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            margin: const EdgeInsets.only(right: 9),
            decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: phone ? 15 : 16, fontWeight: FontWeight.w700, letterSpacing: -.2),
              child: titleWidget ?? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          if (onPrev != null) _Chevron(icon: Icons.chevron_left_rounded, onTap: onPrev!),
          if (onNext != null) ...[const SizedBox(width: 4), _Chevron(icon: Icons.chevron_right_rounded, onTap: onNext!)],
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: hovered ? Colors.white.withValues(alpha: .1) : Colors.transparent,
      ),
      child: Icon(icon, size: 18, color: hovered ? VyseColors.text : const Color(0xFF8B90A3)),
    ),
  );
}

class _RowError extends StatelessWidget {
  const _RowError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: Layout.inset(context)),
    child: Row(
      children: [
        const Icon(Icons.wifi_off_rounded, size: 18, color: VyseColors.textFaint),
        const SizedBox(width: 10),
        const Text("Impossibile caricare questa riga.", style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
        const SizedBox(width: 8),
        TextButton(onPressed: onRetry, child: const Text('Riprova')),
      ],
    ),
  );
}

// ───────────────────────── Card shell ─────────────────────────

/// Crisp white outline on hover, image brightens a touch. No zoom, no glow.
class OutlineCard extends StatelessWidget {
  const OutlineCard({super.key, required this.label, required this.builder, this.radius = _cardRadius, this.onTap});
  final String label;
  final double radius;
  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap ?? () => comingSoon(context, label),
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .98 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: hovered ? Colors.white : Colors.white.withValues(alpha: .05), width: hovered ? 2 : 1),
        ),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), color: VyseColors.surface),
        clipBehavior: Clip.antiAlias,
        child: builder(hovered),
      ),
    ),
  );
}

Widget _image(String? url, {Alignment alignment = Alignment.center}) => url == null
    ? const ColoredBox(
        color: VyseColors.surface,
        child: Center(child: Icon(Icons.image_not_supported_outlined, color: VyseColors.textFaint, size: 20)),
      )
    : CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        alignment: alignment,
        fadeInDuration: const Duration(milliseconds: 300),
        placeholder: (_, _) => const ColoredBox(color: VyseColors.surface),
        errorWidget: (_, _, _) => const ColoredBox(color: VyseColors.surface),
      );

Widget _dimmer(bool hovered) => IgnorePointer(
  child: AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    color: Colors.black.withValues(alpha: hovered ? 0 : .08),
  ),
);

// ───────────────────────── Cards ─────────────────────────

class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.media, required this.heroTag});
  final Media media;

  /// Unique per row, so the poster can fly into the details page.
  final String heroTag;

  @override
  Widget build(BuildContext context) => OutlineCard(
    label: media.title,
    onTap: () => openDetails(context, media, heroTag: heroTag),
    builder: (hovered) => Stack(
      fit: StackFit.expand,
      children: [
        Hero(tag: heroTag, child: _image(media.poster())),
        _dimmer(hovered),
      ],
    ),
  );
}

/// Backdrop with the title's logo art; on hover the logo gives way to title + details.
class LandscapeCard extends StatefulWidget {
  const LandscapeCard({super.key, required this.media});
  final Media media;

  @override
  State<LandscapeCard> createState() => _LandscapeCardState();
}

class _LandscapeCardState extends State<LandscapeCard> {
  late final _logo = HomeFeed.instance.logo(widget.media);

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    return OutlineCard(
      label: m.title,
      onTap: () => openDetails(context, m),
      builder: (hovered) => Stack(
        fit: StackFit.expand,
        children: [
          _image(m.backdrop('w780')),
          _dimmer(hovered),
          AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0xE6000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
          // logo art (resting state)
          Positioned(
            left: 12,
            bottom: 10,
            child: AnimatedOpacity(
              opacity: hovered ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: FutureBuilder<String?>(
                future: _logo,
                builder: (context, snap) => snap.data == null
                    ? const SizedBox.shrink()
                    : LayoutBuilder(
                        builder: (context, _) {
                          return ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 130, maxHeight: 46),
                            child: CachedNetworkImage(
                              imageUrl: snap.data!,
                              fit: BoxFit.contain,
                              alignment: Alignment.bottomLeft,
                              fadeInDuration: const Duration(milliseconds: 300),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
          // title + details (hover state)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: AnimatedOpacity(
              opacity: hovered ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: AnimatedSlide(
                offset: Offset(0, hovered ? 0 : .3),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [m.year ?? '', m.kind, '★ ${m.rating.toStringAsFixed(1)}'].where((s) => s.isNotEmpty).join('  ·  '),
                      style: const TextStyle(fontSize: 10.5, color: VyseColors.textDim),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chart card: backdrop, TOP 10 tag, big outlined rank numeral and the title beside it.
class Top10Card extends StatelessWidget {
  const Top10Card({super.key, required this.media, required this.rank});
  final Media media;
  final int rank;

  @override
  Widget build(BuildContext context) => OutlineCard(
    label: media.title,
    onTap: () => openDetails(context, media),
    builder: (hovered) => Stack(
      fit: StackFit.expand,
      children: [
        _image(media.backdrop('w780')),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomLeft,
              end: Alignment.topRight,
              colors: [Color(0xF0000000), Color(0x55000000), Color(0x00000000)],
              stops: [0, .45, .8],
            ),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(3)),
            child: const Text(
              'TOP 10',
              style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: .3),
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 6,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$rank',
                style: TextStyle(
                  fontSize: 50,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 2
                    ..color = Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        media.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                      ),
                      Text(media.year ?? '', style: const TextStyle(fontSize: 10, color: VyseColors.textDim)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class PlatformTile extends StatelessWidget {
  const PlatformTile({super.key, required this.provider});
  final WatchProvider provider;

  @override
  Widget build(BuildContext context) => OutlineCard(
    label: provider.name,
    radius: 10,
    onTap: () => openDiscover(
      context,
      title: provider.name,
      subtitle: 'In streaming ora negli USA',
      query: DiscoverQuery(providers: {provider.id}),
    ),
    builder: (hovered) => ColoredBox(
      color: hovered ? VyseColors.surfaceHi : const Color(0xFF0D0F18),
      child: LayoutBuilder(
        builder: (context, c) {
          final logo = (c.maxHeight * .48).clamp(36.0, 58.0);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: hovered ? 1.08 : 1,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: provider.logo == null
                    ? SizedBox.square(
                        dimension: logo,
                        child: const Icon(Icons.live_tv_rounded, color: VyseColors.textFaint),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(logo * .24),
                        child: CachedNetworkImage(imageUrl: provider.logo!, width: logo, height: logo, fit: BoxFit.cover),
                      ),
              ),
              const SizedBox(height: 9),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  provider.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

// ───────────────────────── Genres ─────────────────────────

/// "Pick a genre" grid: each tile fans three posters that spread on hover.
class GenreGrid extends StatelessWidget {
  const GenreGrid({super.key});

  @override
  Widget build(BuildContext context) {
    final ff = Layout.of(context);
    final inset = Layout.inset(context);
    final cols = switch (ff) {
      FormFactor.phone => 2,
      FormFactor.tablet => 3,
      FormFactor.desktop => 4,
    };
    const gap = 12.0;
    final genres = homeGenres.take(cols * 2).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: ff == FormFactor.phone ? 22 : 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ShelfHeader(title: 'Esplora i generi'),
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 4, ff == FormFactor.phone ? 16 : 40, 0),
            child: LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < genres.length; i++)
                      SizedBox(
                        width: w,
                        height: (w * .52).clamp(110.0, 170.0),
                        child: FadeSlideIn(
                          delay: Duration(milliseconds: 40 * i),
                          offset: 10,
                          child: _GenreTile(genre: genres[i]),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GenreTile extends StatefulWidget {
  const _GenreTile({required this.genre});
  final Genre genre;

  @override
  State<_GenreTile> createState() => _GenreTileState();
}

class _GenreTileState extends State<_GenreTile> {
  late final _posters = HomeFeed.instance.genre(widget.genre.id);

  @override
  Widget build(BuildContext context) => OutlineCard(
    label: widget.genre.name,
    radius: 10,
    onTap: () => openDiscover(
      context,
      title: widget.genre.name,
      query: DiscoverQuery(genres: {DiscoverGenre.byName(widget.genre.name)?.name ?? widget.genre.name}),
    ),
    builder: (hovered) => ColoredBox(
      color: const Color(0xFF0D0F18),
      child: LayoutBuilder(
        builder: (context, c) {
          final ph = c.maxHeight * .62;
          final pw = ph / 1.5;
          return Stack(
            children: [
              Positioned.fill(
                child: FutureBuilder<List<Media>>(
                  future: _posters,
                  builder: (context, snap) {
                    final posters = (snap.data ?? const <Media>[]).where((m) => m.posterPath != null).take(3).toList();
                    return Align(
                      alignment: const Alignment(0, -.45),
                      child: SizedBox(
                        width: pw,
                        height: ph,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            for (var i = posters.length - 1; i >= 0; i--)
                              AnimatedSlide(
                                duration: const Duration(milliseconds: 340),
                                curve: Curves.easeOutBack,
                                offset: Offset((i - 1) * (hovered ? .62 : .42), 0),
                                child: AnimatedRotation(
                                  duration: const Duration(milliseconds: 340),
                                  curve: Curves.easeOutBack,
                                  turns: (i - 1) * (hovered ? .03 : .018),
                                  child: Container(
                                    width: pw,
                                    height: ph,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(5),
                                      boxShadow: [
                                        BoxShadow(color: Colors.black.withValues(alpha: .6), blurRadius: 10, offset: const Offset(0, 4)),
                                      ],
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: CachedNetworkImage(imageUrl: posters[i].poster('w185')!, fit: BoxFit.cover),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: Text(
                  widget.genre.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5, color: hovered ? VyseColors.text : VyseColors.textDim),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

// ───────────────────────── Studios & networks ─────────────────────────

/// TMDB studio/network logos are drawn for light backgrounds, so they sit on a soft light tile.
class StudioLogo extends StatelessWidget {
  const StudioLogo({super.key, required this.url, this.height = 56});
  final String url;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: EdgeInsets.symmetric(horizontal: height * .32, vertical: height * .2),
    decoration: BoxDecoration(
      color: const Color(0xFFEDEEF3),
      borderRadius: BorderRadius.circular(height * .22),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .35), blurRadius: 18, offset: const Offset(0, 8))],
    ),
    child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain, fadeInDuration: const Duration(milliseconds: 250)),
  );
}

class StudioTile extends StatelessWidget {
  const StudioTile({super.key, required this.studio});
  final Studio studio;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: OutlineCard(
          label: studio.name,
          radius: 12,
          onTap: () => openStudio(context, studio),
          builder: (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: studio.logo == null
                ? (hovered ? VyseColors.surfaceHi : const Color(0xFF0D0F18))
                : (hovered ? Colors.white : const Color(0xFFE6E8EF)),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            alignment: Alignment.center,
            child: studio.logo == null
                ? Text(
                    studio.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: VyseColors.textDim),
                  )
                : AnimatedScale(
                    scale: hovered ? 1.06 : 1,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: CachedNetworkImage(imageUrl: studio.logo!, fit: BoxFit.contain),
                  ),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(
        studio.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      Text([studio.kind, ?studio.country].join(' · '), maxLines: 1, style: const TextStyle(fontSize: 11, color: VyseColors.textFaint)),
    ],
  );
}
