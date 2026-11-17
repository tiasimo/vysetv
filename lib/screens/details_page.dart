import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'anime_page.dart';
import 'player_page.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/anilist.dart';
import '../data/watch_progress.dart';
import '../data/app_settings.dart';
import '../data/discover.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/episode_explorer.dart';
import '../widgets/hero_carousel.dart' show screenDecodeWidth;
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../data/trackers/tracker_hub.dart';

part 'anime_details_page.dart';

/// Title details: dimmed backdrop, info up top (a big centred poster on phones), then tabs for
/// seasons, cast, trailers, more like this and details. Renders instantly from the [Media] we already have.
class DetailsPage extends StatefulWidget {
  const DetailsPage({super.key, required this.media, this.heroTag});
  final Media media;
  final String? heroTag;

  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  final _scroll = ScrollController();
  late Future<MediaDetails> _details = HomeFeed.instance.details(widget.media);

  /// Which section tab is open below the header (null = the first one).
  String? _section;

  /// Height of header + tabs + open section, measured after layout. On wide screens the gap above
  /// is sized so that block sits on the bottom edge of the first screen.
  double? _blockH;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _back() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = phone ? 16.0 : 40.0;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        // Mouse "back" side button.
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) _back();
        },
        child: ColoredBox(
          color: VyseColors.bg,
          child: Stack(
            children: [
              Positioned.fill(
                child: _Backdrop(media: widget.media, scroll: _scroll),
              ),
              PageScrollbar(
                controller: _scroll,
                child: FutureBuilder<MediaDetails>(
                  future: _details,
                  builder: (context, snap) {
                    final d = snap.data;
                    final top = Layout.topChrome(context) + (phone ? 10 : 22);
                    final bottom = phone ? 100 + MediaQuery.paddingOf(context).bottom : 32.0;
                    final block = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(left: inset, right: right),
                          child: _Header(media: d?.media ?? widget.media, details: d, heroTag: widget.heroTag),
                        ),
                        SizedBox(height: phone ? 28 : 34),
                        if (snap.hasError)
                          _LoadError(onRetry: () => setState(() => _details = HomeFeed.instance.details(widget.media)))
                        else if (d == null)
                          const _CastSkeleton()
                        else
                          ..._sections(context, d),
                      ],
                    );
                    // Room left on the first screen once the back link and the block are placed.
                    final free = MediaQuery.sizeOf(context).height - top - bottom - 48 - (_blockH ?? 0);
                    return ListView(
                      controller: _scroll,
                      padding: EdgeInsets.only(top: top, bottom: bottom),
                      children: [
                        Padding(
                          padding: EdgeInsets.only(left: inset - 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _BackButton(onTap: _back),
                          ),
                        ),
                        if (phone) ...[
                          const SizedBox(height: 8),
                          block,
                        ] else ...[
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeOutCubic,
                            height: _blockH == null ? MediaQuery.sizeOf(context).height * .2 : free.clamp(24.0, double.infinity),
                          ),
                          _MeasureSize(
                            onChange: (size) {
                              if (mounted && size.height != _blockH) setState(() => _blockH = size.height);
                            },
                            child: block,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context, MediaDetails d) {
    final ff = Layout.of(context);
    final posterW = switch (ff) {
      FormFactor.phone => 108.0,
      FormFactor.tablet => 128.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .1).clamp(136.0, 180.0),
    };
    final videoW = ff == FormFactor.phone ? 240.0 : 300.0;

    final inset = Layout.inset(context);
    final right = ff == FormFactor.phone ? 16.0 : 40.0;
    String count(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

    final tabs = <(String, Widget)>[
      if (d.seasons.any((s) => s.episodes > 0))
        (
          'Episodes',
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 6, right, 34),
            child: EpisodeExplorer(show: d.media, seasons: [for (final s in d.seasons) if (s.episodes > 0) s]),
          ),
        ),
      if (d.cast.isNotEmpty)
        (
          'Cast',
          Shelf<CastMember>(
            title: 'Starring',
            load: () async => d.cast,
            maxItems: 16,
            itemWidth: 116,
            itemHeight: 212,
            spacing: 14,
            itemBuilder: (_, c, _) => _CastTile(member: c, heroTag: 'cast/${d.media.key}/${c.id}'),
          ),
        ),
      if (d.videos.isNotEmpty)
        (
          'Trailers',
          Shelf<Video>(
            title: count(d.videos.length, 'video'),
            load: () async => d.videos,
            itemWidth: videoW,
            itemHeight: videoW * 9 / 16,
            spacing: 14,
            itemBuilder: (_, v, _) => _VideoCard(video: v),
          ),
        ),
      if (d.recommendations.isNotEmpty)
        (
          'More like this',
          Shelf<Media>(
            title: 'Picked from what fans of this also watch',
            load: () async => d.recommendations,
            itemWidth: posterW,
            itemHeight: posterW * 1.5,
            spacing: 14,
            itemBuilder: (_, m, _) => PosterCard(media: m, heroTag: 'more/${d.media.key}/${m.key}'),
          ),
        ),
      (
        'Details',
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 4, right, 30),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: _FactsPanel(media: d.media, details: d),
          ),
        ),
      ),
    ];
    final sel = tabs.indexWhere((t) => t.$1 == _section).clamp(0, tabs.length - 1);

    return [
      Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: .08)))),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, t) in tabs.indexed)
                _SectionTab(label: t.$1, selected: i == sel, onTap: () => setState(() => _section = t.$1)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 22),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(tabs[sel].$1), child: tabs[sel].$2),
      ),
    ];
  }
}

/// Underlined text tab for the sections under the header.
class _SectionTab extends StatelessWidget {
  const _SectionTab({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Padding(
      padding: const EdgeInsets.only(right: 28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color: selected || hovered ? VyseColors.text : VyseColors.textDim,
            ),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: 2,
          width: selected ? 28 : 0,
          decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(1)),
        ),
      ]),
    ),
  );
}

/// Reports its child's size after each layout that changes it.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});
  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final s = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(s));
  }
}

// ───────────────────────── Backdrop ─────────────────────────

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.media, required this.scroll});
  final Media media;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    const bg = VyseColors.bg;
    final url = media.backdrop(Layout.isPhone(context) ? 'w780' : 'original');
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.06, end: 1.0),
            duration: const Duration(milliseconds: 1600),
            curve: Curves.easeOutCubic,
            builder: (_, s, child) => Transform.scale(scale: s, child: child),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              alignment: const Alignment(.4, -.3),
              memCacheWidth: screenDecodeWidth(context),
              filterQuality: FilterQuality.low,
              fadeInDuration: const Duration(milliseconds: 500),
              // The home hero already cached the w1280 copy: show it while the big one loads.
              placeholder: (_, _) => media.backdrop() == null
                  ? const ColoredBox(color: bg)
                  : Image(image: CachedNetworkImageProvider(media.backdrop()!), fit: BoxFit.cover),
              errorWidget: (_, _, _) => const ColoredBox(color: bg),
            ),
          ),
        // Even dim, then a heavier left side behind the text and a melt into the page at the bottom.
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
        // Darken further as the page scrolls so rows stay legible.
        IgnorePointer(
          child: ListenableBuilder(
            listenable: scroll,
            builder: (context, _) {
              final t = scroll.hasClients ? (scroll.offset / 500).clamp(0.0, 1.0) : 0.0;
              return ColoredBox(color: bg.withValues(alpha: .55 * t));
            },
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Header ─────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.media, required this.details, required this.heroTag});
  final Media media;
  final MediaDetails? details;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final ff = Layout.of(context);
    final info = _InfoColumn(media: media, details: details);

    switch (ff) {
      case FormFactor.desktop:
      case FormFactor.tablet:
        // The backdrop is the art here: leave it room and keep the text in one calm column.
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: info),
        );
      case FormFactor.phone:
        final w = MediaQuery.sizeOf(context).width;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: _Poster(media: media, heroTag: heroTag, width: (w * .56).clamp(170.0, 250.0)),
            ),
            const SizedBox(height: 22),
            _TitleBlock(media: media, details: details, compact: true, centered: true),
            const SizedBox(height: 16),
            _Body(media: media, details: details, compact: true, centered: true),
          ],
        );
    }
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.media, required this.heroTag, required this.width});
  final Media media;
  final String? heroTag;
  final double width;

  @override
  Widget build(BuildContext context) {
    final small = media.poster();
    final poster = Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        color: VyseColors.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
      ),
      clipBehavior: Clip.antiAlias,
      child: media.poster('w500') == null
          ? const Icon(Icons.movie_outlined, color: VyseColors.textFaint)
          : CachedNetworkImage(
              imageUrl: media.poster('w500')!,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              // The card's w342 copy is already cached: no blank frame during the flight.
              placeholder: (_, _) => small == null ? const SizedBox() : Image(image: CachedNetworkImageProvider(small), fit: BoxFit.cover),
            ),
    );
    if (heroTag == null) return FadeSlideIn(offset: 14, child: poster);
    return Hero(tag: heroTag!, child: poster);
  }
}

class _InfoColumn extends StatelessWidget {
  const _InfoColumn({required this.media, required this.details});
  final Media media;
  final MediaDetails? details;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _TitleBlock(media: media, details: details),
      const SizedBox(height: 18),
      _Body(media: media, details: details),
    ],
  );
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.media, required this.details, this.compact = false, this.centered = false});
  final Media media;
  final MediaDetails? details;
  final bool compact;
  final bool centered;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      FadeSlideIn(
        delay: const Duration(milliseconds: 60),
        offset: 12,
        child: Text(
          media.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontSize: compact ? 26 : 34,
            height: 1.08,
            fontWeight: FontWeight.w800,
            letterSpacing: compact ? -.6 : -1,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 20)],
          ),
        ),
      ),
      const SizedBox(height: 10),
      FadeSlideIn(
        delay: const Duration(milliseconds: 110),
        offset: 10,
        child: _MetaLine(media: media, details: details, centered: centered),
      ),
      const SizedBox(height: 12),
      // Genres arrive with the details call; let them ease in rather than pop.
      AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: centered ? Alignment.topCenter : Alignment.topLeft,
        child: details == null || details!.genres.isEmpty
            ? const SizedBox(width: double.infinity)
            : FadeSlideIn(
                offset: 6,
                child: Wrap(
                  alignment: centered ? WrapAlignment.center : WrapAlignment.start,
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final g in details!.genres) _GenreChip(label: g, isTv: media.isTv)],
                ),
              ),
      ),
    ],
  );
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.media, required this.details, this.centered = false});
  final Media media;
  final MediaDetails? details;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    const dim = TextStyle(color: Color(0xFFC3C7D4), fontSize: 13);
    final d = details;
    final parts = <Widget>[
      if (media.year != null) Text(media.year!, style: dim),
      Text(media.kind, style: dim),
      if (d?.runtime != null) Text(fmtRuntime(d!.runtime!, perEpisode: media.isTv), style: dim),
      if (d?.seasonCount != null) Text('${d!.seasonCount} season${d.seasonCount == 1 ? '' : 's'}', style: dim),
    ];
    return Wrap(
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const Text('·', style: TextStyle(color: VyseColors.textFaint, fontSize: 13)),
          parts[i],
        ],
        const SizedBox(width: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, color: VyseColors.star, size: 15),
            const SizedBox(width: 3),
            Text(
              media.rating.toStringAsFixed(1),
              style: const TextStyle(color: VyseColors.star, fontWeight: FontWeight.w700, fontSize: 13),
            ),
            if (d != null && d.voteCount > 0) ...[
              const SizedBox(width: 4),
              Text('(${fmtCompact(d.voteCount)})', style: const TextStyle(color: VyseColors.textFaint, fontSize: 12)),
            ],
          ],
        ),
        if (d?.certification != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withValues(alpha: .3)),
            ),
            child: Text(
              d!.certification!,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFFC3C7D4)),
            ),
          ),
      ],
    );
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.label, required this.isTv});
  final String label;
  final bool isTv;

  void _open(BuildContext context) {
    final g = DiscoverGenre.byName(label);
    if (g == null) return comingSoon(context, label);
    openDiscover(
      context,
      title: g.name,
      subtitle: isTv ? 'Series' : 'Movies',
      query: DiscoverQuery(genres: {g.name}, type: isTv ? MediaType.tv : MediaType.movie),
    );
  }

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => _open(context),
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Colors.white.withValues(alpha: hovered ? .16 : .08),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim),
      ),
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.media, required this.details, this.compact = false, this.centered = false});
  final Media media;
  final MediaDetails? details;
  final bool compact;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final tagline = details?.tagline;
    final align = centered ? TextAlign.center : TextAlign.start;
    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        if (tagline != null) ...[
          FadeSlideIn(
            offset: 8,
            child: Text(
              '"$tagline"',
              textAlign: align,
              style: const TextStyle(color: VyseColors.textDim, fontSize: 13.5, fontStyle: FontStyle.italic),
            ),
          ),
          const SizedBox(height: 10),
        ],
        FadeSlideIn(
          delay: const Duration(milliseconds: 170),
          offset: 10,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Text(
              media.overview.isEmpty ? 'No overview yet.' : media.overview,
              textAlign: align,
              style: TextStyle(color: const Color(0xFFC3C7D4), fontSize: compact ? 13.5 : 14, height: 1.65),
            ),
          ),
        ),
        const SizedBox(height: 22),
        FadeSlideIn(
          delay: const Duration(milliseconds: 230),
          offset: 10,
          child: _Actions(media: media, details: details, centered: centered),
        ),
      ],
    );
  }
}

// ───────────────────────── Actions ─────────────────────────

class _Actions extends StatelessWidget {
  const _Actions({required this.media, required this.details, this.centered = false});
  final Media media;
  final MediaDetails? details;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      spacing: 8,
      runSpacing: 8,
      children: [
        _Pill(
          icon: Icons.play_arrow_rounded,
          label: 'Play',
          primary: true,
          onTap: () {
            // Shows start at episode 1 of the first real season (season 0 is usually specials).
            final first = details?.seasons.where((s) => s.number > 0 && s.episodes > 0).firstOrNull;
            openPlayer(
              context,
              media,
              episode: media.isTv ? PlayerEpisode(season: first?.number ?? 1, number: 1) : null,
              runtime: details?.runtime,
            );
          },
        ),
        _SaveButton(media: media),
        _RoundAction(icon: Icons.thumb_up_alt_outlined, tooltip: 'Rate', onTap: () => comingSoon(context, 'Ratings')),
      ],
    );
  }
}

Future<void> _open(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    showToast(context, const Text("Couldn't open the link", style: TextStyle(fontSize: 13)), icon: Icons.error_outline);
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .92 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hovered ? Colors.white : Colors.white.withValues(alpha: .06),
          border: Border.all(color: Colors.white.withValues(alpha: hovered ? 0 : .08)),
        ),
        child: Icon(icon, size: 17, color: hovered ? Colors.black : VyseColors.text),
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) {
      final fg = primary ? Colors.black : VyseColors.text;
      return AnimatedScale(
        scale: pressed ? .95 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 38,
          padding: EdgeInsets.symmetric(horizontal: primary ? 22 : 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: primary ? (hovered ? const Color(0xFFE6E7EE) : Colors.white) : Colors.white.withValues(alpha: hovered ? .14 : .06),
            border: primary ? null : Border.all(color: Colors.white.withValues(alpha: hovered ? .22 : .08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: primary ? 20 : 17, color: fg),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Heart that fills with a little pop when saved.
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.media});
  final Media media;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Set<String>>(
    valueListenable: MyList.saved,
    builder: (context, saved, _) {
      final on = saved.contains(media.key);
      return Pressable(
        onTap: () => TrackerHub.myListToggle(media),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .95 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: on ? VyseColors.accent.withValues(alpha: hovered ? .26 : .18) : Colors.white.withValues(alpha: hovered ? .14 : .06),
              border: Border.all(color: on ? VyseColors.accent.withValues(alpha: .5) : Colors.white.withValues(alpha: hovered ? .22 : .08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (c, a) => ScaleTransition(
                    scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                    child: c,
                  ),
                  child: Icon(
                    on ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
                    key: ValueKey(on),
                    size: 17,
                    color: on ? VyseColors.accent : VyseColors.text,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  on ? 'Saved' : 'Save',
                  style: const TextStyle(color: VyseColors.text, fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    tooltip: 'Back (Esc)',
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: hovered ? Colors.white.withValues(alpha: .1) : Colors.transparent,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSlide(
            offset: Offset(hovered ? -.15 : 0, 0),
            duration: const Duration(milliseconds: 180),
            child: Icon(Icons.chevron_left_rounded, size: 20, color: hovered ? VyseColors.text : VyseColors.textDim),
          ),
          Text(
            'Back',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim),
          ),
        ],
      ),
    ),
  );
}

// ───────────────────────── Facts panel ─────────────────────────

class _FactsPanel extends StatelessWidget {
  const _FactsPanel({required this.media, required this.details});
  final Media media;
  final MediaDetails? details;

  static const _value = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.35);

  List<(String, Widget)> _rows(MediaDetails d) {
    String? join(List<String> l) => l.isEmpty ? null : l.join(', ');
    final text = <(String, String?)>[
      ('Status', d.status),
      (media.isTv ? 'First aired' : 'Released', d.released == null ? null : fmtDate(d.released!)),
      ('Runtime', d.runtime == null ? null : fmtRuntime(d.runtime!, perEpisode: media.isTv)),
      if (media.isTv) ('Episodes', d.episodeCount?.toString()),
      (media.isTv ? 'Created by' : 'Director', join(d.directors)),
      if (!media.isTv) ('Writers', join(d.writers)),
    ];
    final studios = media.isTv ? d.networks : d.studios;
    final tail = <(String, String?)>[
      ('Country', join(d.countries)),
      ('Language', d.language),
      if (d.budget > 0) ('Budget', fmtMoney(d.budget)),
      if (d.revenue > 0) ('Box office', fmtMoney(d.revenue)),
    ];
    Widget plain(String v) => Text(v, maxLines: 2, overflow: TextOverflow.ellipsis, style: _value);
    return [
      for (final (k, v) in text)
        if (v != null && v.isNotEmpty) (k, plain(v)),
      // Studios / networks are links into their own pages.
      if (studios.isNotEmpty)
        (
          media.isTv ? 'Network' : 'Studio',
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [for (final (i, s) in studios.indexed) _StudioLink(studio: s, last: i == studios.length - 1)],
          ),
        ),
      for (final (k, v) in tail)
        if (v != null && v.isNotEmpty) (k, plain(v)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = details;
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth > 900 ? 4 : (c.maxWidth > 520 ? 3 : 2);
        final cellW = (c.maxWidth / cols).floorToDouble();
        Widget cell(String label, Widget value) => Container(
          width: cellW,
          padding: const EdgeInsets.fromLTRB(0, 13, 18, 13),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.white.withValues(alpha: .08))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
              const SizedBox(height: 4),
              value,
            ],
          ),
        );
        return AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: d == null
              ? Shimmer(
                  child: Wrap(
                    children: [for (var i = 0; i < cols * 2; i++) cell('', SkeletonBox(width: cellW * .6, height: 12, radius: 4))],
                  ),
                )
              : Wrap(
                  children: [
                    for (final (i, row) in _rows(d).indexed)
                      FadeSlideIn(
                        delay: Duration(milliseconds: 30 * i),
                        offset: 6,
                        child: cell(row.$1, row.$2),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _StudioLink extends StatelessWidget {
  const _StudioLink({required this.studio, required this.last});
  final Studio studio;
  final bool last;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => openStudio(context, studio),
    tooltip: 'Open ${studio.kind.toLowerCase()}',
    builder: (context, hovered, _) => Text(
      last ? studio.name : '${studio.name},',
      style: _FactsPanel._value.copyWith(
        color: hovered ? VyseColors.accent : VyseColors.text,
        decoration: hovered ? TextDecoration.underline : TextDecoration.none,
        decorationColor: VyseColors.accent,
      ),
    ),
  );
}

// ───────────────────────── Rows ─────────────────────────

class _CastTile extends StatelessWidget {
  const _CastTile({required this.member, required this.heroTag});
  final CastMember member;
  final String heroTag;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => openPerson(context, id: member.id, name: member.name, profilePath: member.profilePath, heroTag: heroTag),
    builder: (context, hovered, pressed) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedScale(
          scale: pressed ? .95 : (hovered ? 1.03 : 1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 104,
            height: 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: VyseColors.surfaceHi,
              border: Border.all(color: Colors.white.withValues(alpha: hovered ? .4 : .06)),
            ),
            clipBehavior: Clip.antiAlias,
            child: member.photo == null
                ? const Icon(Icons.person_rounded, color: VyseColors.textFaint, size: 32)
                : Hero(
                    tag: heroTag,
                    child: CachedNetworkImage(
                      imageUrl: member.photo!,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      fadeInDuration: const Duration(milliseconds: 250),
                      placeholder: (_, _) => const SizedBox(),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          member.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : const Color(0xFFDADCE6)),
        ),
        const SizedBox(height: 2),
        Text(
          member.character,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
          style: const TextStyle(fontSize: 10.5, color: VyseColors.textFaint),
        ),
      ],
    ),
  );
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video});
  final Video video;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => _open(context, video.url),
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .98 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: hovered ? Colors.white : Colors.white.withValues(alpha: .05), width: hovered ? 2 : 1),
        ),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(7), color: VyseColors.surface),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(imageUrl: video.thumbnail, fit: BoxFit.cover, placeholder: (_, _) => const SizedBox()),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.center,
                  colors: [Color(0xE6000000), Color(0x00000000)],
                ),
              ),
            ),
            Center(
              child: AnimatedScale(
                scale: hovered ? 1.12 : 1,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered ? Colors.white : Colors.black.withValues(alpha: .5),
                    border: Border.all(color: Colors.white.withValues(alpha: .6)),
                  ),
                  child: Icon(Icons.play_arrow_rounded, color: hovered ? Colors.black : Colors.white, size: 26),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    video.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  Text(video.type, style: const TextStyle(fontSize: 10.5, color: VyseColors.textDim)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CastSkeleton extends StatelessWidget {
  const _CastSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: Layout.inset(context)),
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBox(width: 60, height: 14, radius: 4),
          const SizedBox(height: 16),
          Row(
            children: [
              for (var i = 0; i < 8; i++) ...[
                Container(
                  width: 76,
                  height: 76,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: VyseColors.surface),
                ),
                const SizedBox(width: 24),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: Layout.inset(context)),
    child: Row(
      children: [
        const Icon(Icons.wifi_off_rounded, size: 18, color: VyseColors.textFaint),
        const SizedBox(width: 10),
        const Text("Couldn't load the full details.", style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
        const SizedBox(width: 8),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
