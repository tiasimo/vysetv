import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/perf.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../screens/player_page.dart';

import '../data/trackers/tracker_hub.dart';
import 'common.dart';

const _ease = Curves.easeInOutCubic;
const _morph = Duration(milliseconds: 720);

/// Home spotlight. Normal mode: poster + left-aligned info. Spotlight mode ([immersive]): the hero
/// fills the window, the poster folds away, info glides to centre and the title becomes the logo art.
class HeroCarousel extends StatefulWidget {
  const HeroCarousel({
    super.key,
    required this.items,
    required this.scroll,
    required this.immersive,
    required this.height,
  });

  final List<Media> items;
  final ScrollController scroll;
  final bool immersive;
  final double height;

  @override
  State<HeroCarousel> createState() => HeroCarouselState();
}

class HeroCarouselState extends State<HeroCarousel> {
  static const _slide = Duration(seconds: 9);
  int _index = 0;
  Timer? _auto;

  @override
  void initState() {
    super.initState();
    for (final m in widget.items) {
      HomeFeed.instance.logo(m).ignore();
    }
    _schedule();
  }

  bool _phoneArtWarmed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Phones show portrait art: look it up for every slide up front so nothing pops in late.
    if (!_phoneArtWarmed && Layout.isPhone(context)) {
      _phoneArtWarmed = true;
      for (final m in widget.items) {
        HomeFeed.instance.phoneArt(m).ignore();
      }
    }
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  void _schedule() {
    _auto?.cancel();
    _auto = Timer(_slide, next);
  }

  void next() => go(_index + 1);
  void prev() => go(_index - 1);

  void go(int i) {
    if (!mounted) return;
    final n = widget.items.length;
    perfMark('slide ${(i % n + n) % n}');
    setState(() => _index = (i % n + n) % n);
    _schedule();
    // Warm exactly the image the next slide will show (same URL and decode size), so the
    // crossfade never has to decode a big image mid-animation.
    final phone = Layout.isPhone(context);
    final nextMedia = widget.items[(_index + 1) % n];
    void warm(String? url) {
      if (url == null || !mounted) return;
      precacheImage(ResizeImage(CachedNetworkImageProvider(url), width: screenDecodeWidth(context)), context);
    }

    if (phone) {
      HomeFeed.instance.phoneArt(nextMedia).then((u) => warm(u ?? nextMedia.backdrop('w780')));
    } else {
      warm(nextMedia.backdrop('original'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final ff = Layout.of(context);
    final phone = ff == FormFactor.phone;
    final centered = phone || widget.immersive;
    final m = widget.items[_index];

    final inset = Layout.inset(context);
    final posterW = switch (ff) {
      FormFactor.phone => 0.0,
      FormFactor.tablet => 150.0,
      FormFactor.desktop => (size.width * .148).clamp(170.0, 250.0),
    };
    const posterGap = 32.0;
    final showPoster = !centered && posterW > 0;
    final available = size.width - (phone ? 32 : inset + 48);
    final blockW = math.min(
      available - (showPoster ? posterW + posterGap : 0),
      centered ? 660.0 : 560.0,
    );

    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() > 200) v < 0 ? next() : prev();
      },
      child: AnimatedContainer(
        duration: _morph,
        curve: _ease,
        height: widget.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Parallax: the backdrop layer only moves; the fade-out is a dark overlay painted on
            // top. (Opacity on a full-screen image forces an off-screen copy every frame, which
            // measured at 20-80 ms per frame on a 1440p / 179 Hz display.)
            ClipRect(
              child: ListenableBuilder(
                listenable: widget.scroll,
                builder: (context, child) {
                  final off = widget.scroll.hasClients
                      ? widget.scroll.offset.clamp(0.0, widget.height)
                      : 0.0;
                  final fade = (off / widget.height).clamp(0.0, 1.0) * .8;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform.translate(
                        offset: Offset(0, off * .5),
                        child: child,
                      ),
                      if (fade > 0)
                        ColoredBox(
                          color: VyseColors.bg.withValues(alpha: fade),
                        ),
                    ],
                  );
                },
                // Always laid out at full-window height and clipped to the hero, so growing into
                // the spotlight only moves the clip edge instead of re-rendering the image.
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: size.height,
                  maxHeight: size.height,
                  child: RepaintBoundary(
                    child: _Backdrop(media: m, phone: phone),
                  ),
                ),
              ),
            ),
            RepaintBoundary(child: _Scrims(centered: centered)),
            Positioned(
              left: phone ? 16 : inset,
              right: phone ? 16 : 48,
              bottom: phone ? 24 : math.max(40, widget.height * .07),
              child: AnimatedAlign(
                duration: _morph,
                curve: _ease,
                alignment: centered
                    ? Alignment.bottomCenter
                    : Alignment.bottomLeft,
                child: RepaintBoundary(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (posterW > 0)
                        _FoldingPoster(
                          media: m,
                          width: posterW,
                          gap: posterGap,
                          visible: showPoster,
                        ),
                      _InfoBlock(
                        media: m,
                        width: blockW,
                        centered: centered,
                        compact: phone,
                        index: _index,
                        count: widget.items.length,
                        onDot: go,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!phone)
              Positioned(
                right: 28,
                bottom: 22,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: widget.immersive ? 1 : 0,
                    duration: const Duration(milliseconds: 400),
                    child: const _KeyHints(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Backdrop + scrims ─────────────────────────

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.media, required this.phone});
  final Media media;
  final bool phone;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 1000),
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    // New slide fades in while settling from a slight zoom. (A full-screen blur here looked
    // nice but cost a whole extra render pass per frame, which stutters on high-refresh screens.)
    transitionBuilder: (child, a) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 1.04, end: 1.0).animate(a),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.expand, children: [...previous, ?current]),
    child: phone
        ? FutureBuilder<String?>(
            key: ValueKey(media.id),
            future: HomeFeed.instance.phoneArt(media),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return ColoredBox(color: VyseColors.bg);
              final art = snap.data;
              return art == null
                  ? _Drift(url: media.backdrop('w780'))
                  : _Drift(url: art, alignment: const Alignment(0, -.2));
            },
          )
        : _Drift(
            key: ValueKey(media.id),
            url: media.backdrop('original'),
          ),
  );
}

/// Decode width for full-screen images: the screen's physical width, not the file's
/// (TMDB originals can be 4K+, which is a lot of texture to push every frame).
int screenDecodeWidth(BuildContext context) {
  final mq = MediaQuery.of(context);
  return (mq.size.width * mq.devicePixelRatio).round().clamp(640, 3840);
}

/// Barely-there slow push-in so the frame never feels frozen.
class _Drift extends StatelessWidget {
  const _Drift({super.key, required this.url, this.alignment = const Alignment(.5, -.4)});
  final String? url;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (url == null) return ColoredBox(color: VyseColors.surface);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 1.05),
      duration: const Duration(seconds: 20),
      builder: (_, s, child) => Transform.scale(
        scale: s,
        alignment: const Alignment(.4, -.3),
        child: child,
      ),
      // The image is painted once into its own layer; the push-in just transforms that layer.
      child: RepaintBoundary(
        child: CachedNetworkImage(
          imageUrl: url!,
          fit: BoxFit.cover,
          alignment: alignment,
          memCacheWidth: screenDecodeWidth(context),
          filterQuality: FilterQuality.low,
          fadeInDuration: const Duration(milliseconds: 400),
          placeholder: (_, _) => ColoredBox(color: VyseColors.bg),
          errorWidget: (_, _, _) => ColoredBox(color: VyseColors.surface),
        ),
      ),
    );
  }
}

class _Scrims extends StatelessWidget {
  const _Scrims({required this.centered});
  final bool centered;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: centered ? 1 : 0),
    duration: _morph,
    curve: _ease,
    builder: (context, t, _) {
      final bg = VyseColors.bg;
      return Stack(
        fit: StackFit.expand,
        children: [
          // left fade behind poster + text (normal mode only)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  bg.withValues(alpha: .88 * (1 - t)),
                  bg.withValues(alpha: .55 * (1 - t)),
                  bg.withValues(alpha: 0),
                ],
                stops: const [0, .38, .68],
              ),
            ),
          ),
          // bottom melt into the page
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  bg,
                  bg.withValues(alpha: .78 - .18 * t),
                  bg.withValues(alpha: 0),
                ],
                stops: [0, .22 + .06 * t, .6],
              ),
            ),
          ),
          // top shade so window controls and the rail logo stay readable
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bg.withValues(alpha: .45), bg.withValues(alpha: 0)],
                stops: const [0, .22],
              ),
            ),
          ),
          // a soft pool of shadow under centred text
          if (t > 0)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, .75),
                  radius: .9,
                  colors: [
                    bg.withValues(alpha: .55 * t),
                    bg.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

// ───────────────────────── Poster + info ─────────────────────────

class _FoldingPoster extends StatelessWidget {
  const _FoldingPoster({
    required this.media,
    required this.width,
    required this.gap,
    required this.visible,
  });
  final Media media;
  final double width;
  final double gap;
  final bool visible;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: _morph,
    curve: _ease,
    width: visible ? width + gap : 0,
    height: width * 1.5,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width + gap,
        maxWidth: width + gap,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: Duration(milliseconds: visible ? 600 : 300),
          child: Padding(
            padding: EdgeInsets.only(right: gap),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: Container(
                key: ValueKey(media.id),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .55),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: media.poster('w500') == null
                    ? ColoredBox(color: VyseColors.surface)
                    : CachedNetworkImage(
                        imageUrl: media.poster('w500')!,
                        fit: BoxFit.cover,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({
    required this.media,
    required this.width,
    required this.centered,
    required this.compact,
    required this.index,
    required this.count,
    required this.onDot,
  });

  final Media media;
  final double width;
  final bool centered;
  final bool compact;
  final int index;
  final int count;
  final ValueChanged<int> onDot;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: _morph,
    curve: _ease,
    width: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [...previous, ?current],
          ),
          child: _Details(
            key: ValueKey('${media.id}-$centered'),
            media: media,
            centered: centered,
            compact: compact,
          ),
        ),
        const SizedBox(height: 20),
        AnimatedAlign(
          duration: _morph,
          curve: _ease,
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          child: _Actions(media: media, expandPlay: compact),
        ),
        SizedBox(height: compact ? 22 : 30),
        _Dots(count: count, index: index, onTap: onDot),
      ],
    ),
  );
}

class _Details extends StatelessWidget {
  const _Details({
    super.key,
    required this.media,
    required this.centered,
    required this.compact,
  });
  final Media media;
  final bool centered;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final align = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final textAlign = centered ? TextAlign.center : TextAlign.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align,
      children: [
        _Title(media: media, centered: centered, compact: compact),
        const SizedBox(height: 14),
        _Meta(media: media),
        const SizedBox(height: 12),
        Text(
          media.overview,
          maxLines: centered ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: TextStyle(
            color: const Color(0xFFC3C7D4),
            fontSize: compact ? 13 : 14,
            height: 1.6,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
          ),
        ),
      ],
    );
  }
}

/// Text title in normal mode; the title's logo art when centred (falls back to text).
class _Title extends StatelessWidget {
  const _Title({
    required this.media,
    required this.centered,
    required this.compact,
  });
  final Media media;
  final bool centered;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      media.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: centered ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        fontSize: compact ? 32 : (centered ? 46 : 48),
        height: 1.04,
        fontWeight: FontWeight.w800,
        letterSpacing: compact ? -.9 : -1.4,
        shadows: const [Shadow(color: Colors.black45, blurRadius: 24)],
      ),
    );
    if (!centered) return text;

    return FutureBuilder<String?>(
      future: HomeFeed.instance.logo(media),
      builder: (context, snap) {
        final url = snap.data;
        if (url == null) return text;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: compact ? 96 : 150,
            maxWidth: compact ? 280 : 460,
          ),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            fadeInDuration: const Duration(milliseconds: 300),
            placeholder: (_, _) => text,
            errorWidget: (_, _, _) => text,
          ),
        );
      },
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.media});
  final Media media;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.star_rounded, color: VyseColors.star, size: 15),
      const SizedBox(width: 3),
      Text(
        media.rating.toStringAsFixed(1),
        style: const TextStyle(
          color: VyseColors.star,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
      if (media.year != null) ...[
        const SizedBox(width: 12),
        Text(
          media.year!,
          style: const TextStyle(color: Color(0xFFC3C7D4), fontSize: 13),
        ),
      ],
      const SizedBox(width: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white.withValues(alpha: .3)),
        ),
        child: Text(
          media.kind,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFFC3C7D4),
          ),
        ),
      ),
    ],
  );
}

// ───────────────────────── Buttons, dots, hints ─────────────────────────

class _Actions extends StatelessWidget {
  const _Actions({required this.media, required this.expandPlay});
  final Media media;
  final bool expandPlay;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _PlayButton(media: media, width: expandPlay ? 170 : 134),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<Set<String>>(
              valueListenable: MyList.saved,
              builder: (context, saved, _) {
                final on = saved.contains(media.key);
                return SquareIconButton(
                  icon: on ? Icons.check_rounded : Icons.add_rounded,
                  label: on ? 'Rimuovi da La mia lista' : 'Aggiungi a La mia lista',
                  onTap: () => TrackerHub.myListToggle(media),
                );
              },
            ),
            const SizedBox(width: 2),
            SquareIconButton(
              icon: Icons.info_outline_rounded,
              label: 'Dettagli',
              onTap: () => openDetails(context, media),
            ),
          ],
        ),
      ),
    ],
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.media, required this.width});
  final Media media;
  final double width;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => openPlayer(context, media, episode: media.isTv ? const PlayerEpisode(season: 1, number: 1) : null),
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .96 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: width,
        height: 42,
        decoration: BoxDecoration(
          color: hovered ? const Color(0xFFE6E7EE) : Colors.white,
          borderRadius: BorderRadius.circular(21),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_arrow_rounded, color: Colors.black, size: 20),
            SizedBox(width: 6),
            Text(
              'Riproduci',
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Small square icon button that flips to white on hover.
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.size = 34,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: label,
    onTap: onTap ?? () => comingSoon(context, label),
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: hovered ? Colors.white : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: size * .52,
          color: hovered ? Colors.black : VyseColors.text,
        ),
      ),
    ),
  );
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index, required this.onTap});
  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < count; i++)
        Pressable(
          onTap: () => onTap(i),
          builder: (context, hovered, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              width: i == index ? 20 : 4,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: Colors.white.withValues(
                  alpha: i == index ? 1 : (hovered ? .7 : .32),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _KeyHints extends StatelessWidget {
  const _KeyHints();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 11,
      color: VyseColors.textFaint,
      fontWeight: FontWeight.w500,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Key('←'),
        SizedBox(width: 3),
        _Key('→'),
        Text('  per sfogliare', style: style),
        SizedBox(width: 16),
        _Key('↓'),
        Text('  per tornare indietro', style: style),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.glyph);
  final String glyph;

  @override
  Widget build(BuildContext context) => Container(
    width: 17,
    height: 17,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: VyseColors.strokeHi),
    ),
    child: Text(
      glyph,
      style: TextStyle(
        fontSize: 9.5,
        color: VyseColors.textDim,
        height: 1,
      ),
    ),
  );
}
