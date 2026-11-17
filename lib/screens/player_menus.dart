import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/anime_sources.dart' show animeServers;
import '../data/app_settings.dart';
import '../data/subtitle_style.dart';
import '../data/subtitles.dart' as sub;
import '../widgets/common.dart';

/// The player's settings panel: a pane of frosted glass above the dock, over the video, with its
/// tabs and what's in them. It's plain Flutter, with no player in it.

abstract final class MenuInk {
  static const title = Color(0xFFF8F8FB);
  static const body = Color(0xE0FFFFFF);
  static const dim = Color(0xA3FFFFFF);
  static const faint = Color(0x66FFFFFF);
  static const hair = Color(0x14FFFFFF);
  static const hover = Color(0x12FFFFFF);

  /// Quick to arrive, slow to settle.
  static const ease = Cubic(.22, 1, .36, 1);
}

enum MenuTab {
  sources('Sorgenti'),
  quality('Qualità'),
  audio('Audio'),
  subtitles('Sottotitoli'),
  speed('Velocità'),
  more('Altro');

  const MenuTab(this.label);
  final String label;
}

/// A phone on its side, or a short window: every pixel of height counts.
bool shortMenus(BuildContext context) => MediaQuery.sizeOf(context).height < 520;

/// Rows sit closer on a phone, or in a small window.
bool tightMenus(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.width < 640 || s.height < 520;
}

// ───────────────────────── The panel ─────────────────────────

/// Where the panel goes in a box of a given size.
@immutable
class PanelFit {
  const PanelFit({required this.right, required this.bottom, required this.maxBody, required this.narrow, this.left, this.width});
  final double? left;
  final double right;
  final double? width;
  final double bottom;
  final double maxBody;
  final bool narrow; // no room for two columns

  static const _tabs = 60.0; // the tabs and the space round them
  static const _shortTabs = 48.0;

  factory PanelFit.of(Size box, {required double side, required double top, required double dockH, required EdgeInsets safe}) {
    final w = box.width, h = box.height;
    // a phone on its side, a small window: at the right, using the whole height
    if (h < 520) {
      final bottom = 8 + safe.bottom;
      final room = w - safe.horizontal - 20;
      return PanelFit(
        right: 10 + safe.right,
        width: math.min(room, (w * .52).clamp(340.0, 480.0)),
        bottom: bottom,
        maxBody: math.max(110, h - top - bottom - 8 - _shortTabs),
        narrow: true,
      );
    }
    // a phone held upright: edge to edge
    if (w < 640) {
      return PanelFit(
        left: 10 + safe.left,
        right: 10 + safe.right,
        bottom: dockH + 6,
        maxBody: (h - dockH - top - 96 - _tabs).clamp(180.0, 480.0),
        narrow: true,
      );
    }
    final width = math.min(w - side * 2, w >= 1400 ? 640.0 : 580.0);
    return PanelFit(
      right: side,
      width: width,
      bottom: dockH + 6,
      maxBody: (h - dockH - top - 84 - _tabs).clamp(170.0, 460.0),
      narrow: width < 520,
    );
  }
}

class PlayerPanel extends StatefulWidget {
  const PlayerPanel({super.key, required this.open, required this.tab, required this.onTab, required this.side, required this.top, required this.dockH, required this.body});
  final bool open;
  final MenuTab tab;
  final ValueChanged<MenuTab> onTab;
  final double side;
  final double top;
  final double dockH;
  final Widget Function(PanelFit fit) body;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> with SingleTickerProviderStateMixin {
  late final _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 170),
    value: widget.open ? 1 : 0,
  );
  late final _v = CurvedAnimation(parent: _t, curve: MenuInk.ease, reverseCurve: Curves.easeInCubic);

  @override
  void didUpdateWidget(PlayerPanel old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) widget.open ? _t.forward() : _t.reverse();
  }

  @override
  void dispose() {
    _v.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final fit = PanelFit.of(box.biggest, side: widget.side, top: widget.top, dockH: widget.dockH, safe: MediaQuery.paddingOf(context));
      final tight = tightMenus(context);
      final short = shortMenus(context);
      // nothing is built, and nothing is blurred, while it's shut
      final content = !widget.open && _t.isDismissed
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(short ? 8 : 10, short ? 8 : 10, short ? 8 : 10, short ? 0 : 2),
                  child: MenuSegments<MenuTab>(
                    value: widget.tab,
                    height: short ? 34 : (tight ? 36 : 40),
                    fontSize: tight ? 12 : 13,
                    options: [for (final t in MenuTab.values) (t, t.label)],
                    onChanged: widget.onTab,
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 340),
                  curve: MenuInk.ease,
                  alignment: Alignment.topCenter,
                  child: MenuSlide(
                    index: widget.tab.index,
                    child: ConstrainedBox(constraints: BoxConstraints(maxHeight: fit.maxBody), child: widget.body(fit)),
                  ),
                ),
              ],
            );
      return AnimatedBuilder(
        animation: _v,
        child: content,
        builder: (context, child) {
          if (child == null || _t.isDismissed) return const SizedBox.shrink();
          final v = _v.value.clamp(0.0, 1.0);
          final r = BorderRadius.circular(22);
          // Plezy's player draws the video on a native surface behind Flutter, where a
          // BackdropFilter can't see it, so the pane always takes the solid look (the blur
          // used to sit here, behind !lightEffects).
          final Widget pane = DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              // lit from above, like glass under a lamp
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF1B1D2A).withValues(alpha: .98 * v),
                  const Color(0xFF0B0C13).withValues(alpha: .98 * v),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: .12 * v)),
            ),
            child: Opacity(opacity: const Interval(.1, 1).transform(v), child: child),
          );
          return Stack(
            children: [
              Positioned(
                left: fit.left,
                right: fit.right,
                width: fit.width,
                bottom: fit.bottom,
                child: IgnorePointer(
                  ignoring: !widget.open,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // keep taps inside the panel from closing it
                    child: Transform.translate(
                      offset: Offset(0, 16 * (1 - v)),
                      child: Transform.scale(
                        scale: .965 + .035 * v,
                        alignment: Alignment.bottomRight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: r,
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5 * v), blurRadius: 46, offset: const Offset(0, 18))],
                          ),
                          child: ClipRRect(borderRadius: r, child: pane),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Changes what it shows by sliding the way you moved, and only the new one sets the height.
class MenuSlide extends StatefulWidget {
  const MenuSlide({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<MenuSlide> createState() => _MenuSlideState();
}

class _MenuSlideState extends State<MenuSlide> {
  double _way = 1;

  @override
  void didUpdateWidget(MenuSlide old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _way = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 280),
    switchInCurve: MenuInk.ease,
    switchOutCurve: Curves.easeOut,
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.hardEdge,
      children: [
        for (final p in previous) Positioned(top: 0, left: 0, right: 0, child: p),
        ?current,
      ],
    ),
    transitionBuilder: (child, a) {
      final arriving = child.key == ValueKey(widget.index);
      return FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: Offset(.06 * _way * (arriving ? 1 : -1), 0), end: Offset.zero).animate(a), child: child),
      );
    },
    child: KeyedSubtree(key: ValueKey(widget.index), child: widget.child),
  );
}

/// Each row arrives just after the one above it.
class Rise extends StatelessWidget {
  const Rise({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = math.min(index, 8) * 22.0;
    final total = 320 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total.round()),
      curve: Interval(delay / total, 1, curve: MenuInk.ease),
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - v) * 10), child: child),
      ),
      child: child,
    );
  }
}

/// A list that fades out at its ends rather than being cut off.
class MenuScroll extends StatelessWidget {
  const MenuScroll({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(8, 6, 8, 12)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (r) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [Color(0x00FFFFFF), Colors.white, Colors.white, Color(0x00FFFFFF)],
      stops: [0, math.min(.2, 8 / r.height), math.max(.8, 1 - 20 / r.height), 1],
    ).createShader(r),
    child: SingleChildScrollView(
      padding: padding,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

/// A row of choices with one lit thumb that glides between them.
class MenuSegments<T> extends StatelessWidget {
  const MenuSegments({super.key, required this.value, required this.options, required this.onChanged, this.height = 40, this.fontSize = 13});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final at = options.indexWhere((o) => o.$1 == value);
    final radius = height * .34;
    final base = DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, c) {
        final each = c.maxWidth / options.length;
        return Container(
          height: height,
          decoration: BoxDecoration(color: const Color(0x12FFFFFF), borderRadius: BorderRadius.circular(radius)),
          child: Stack(
            children: [
              if (at >= 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 360),
                  curve: MenuInk.ease,
                  left: at * each + 3,
                  width: each - 6,
                  top: 3,
                  bottom: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius - 3),
                      color: const Color(0x30FFFFFF),
                      border: Border.all(color: const Color(0x14FFFFFF)),
                      boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 10, offset: Offset(0, 3))],
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final (v, label) in options)
                    Expanded(
                      child: Pressable(
                        onTap: () => onChanged(v),
                        builder: (context, hovered, _) => Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: base.merge(
                              TextStyle(
                                fontSize: fontSize,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -.1,
                                color: v == value ? Colors.white : (hovered ? MenuInk.body : MenuInk.dim),
                              ),
                            ),
                            child: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class MenuCaption extends StatelessWidget {
  const MenuCaption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
    child: Text(text, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: MenuInk.faint)),
  );
}

class MenuTag extends StatelessWidget {
  const MenuTag(this.text, {super.key, this.strong = false});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2),
    decoration: BoxDecoration(
      color: strong ? VyseColors.accent.withValues(alpha: .17) : const Color(0x17FFFFFF),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10.5, height: 1.35, fontWeight: FontWeight.w700, letterSpacing: .1, color: strong ? VyseColors.accent : MenuInk.dim),
    ),
  );
}

/// One choice. What's chosen is lit softly from the left.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.title,
    this.detail,
    this.tags = const [],
    this.selected = false,
    this.live = false,
    this.quiet = false,
    this.chevron = false,
    this.value,
    this.leading,
    this.onTap,
    this.titleLines = 1,
  });
  final String title;
  final String? detail;
  final List<Widget> tags;
  final bool selected;
  final bool live; // playing right now: moving bars, not a tick
  final bool quiet; // something's wrong with it
  final bool chevron; // goes somewhere
  final String? value;
  final Widget? leading;
  final VoidCallback? onTap;
  final int titleLines;

  @override
  Widget build(BuildContext context) {
    final tight = tightMenus(context);
    final short = shortMenus(context);
    final inline = short && detail != null && detail!.isNotEmpty; // title and detail share the line
    final base = DefaultTextStyle.of(context).style;
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .985 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: MenuInk.ease,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: EdgeInsets.fromLTRB(hovered && !selected ? 16 : 13, short ? 10 : (tight ? 9 : 11), 12, short ? 10 : (tight ? 9 : 11)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: selected ? null : (hovered ? MenuInk.hover : const Color(0x00FFFFFF)),
            gradient: selected
                ? LinearGradient(
                    colors: [VyseColors.accent.withValues(alpha: .24), VyseColors.accent.withValues(alpha: .09), VyseColors.accent.withValues(alpha: .02)],
                    stops: const [0, .6, 1],
                  )
                : null,
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 11)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 180),
                      style: base.merge(
                        TextStyle(
                          fontSize: tight ? 14 : 14.5,
                          height: 1.28,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                          letterSpacing: -.15,
                          color: quiet ? MenuInk.dim : (selected || hovered ? Colors.white : MenuInk.body),
                        ),
                      ),
                      child: inline
                          ? Text.rich(
                              TextSpan(
                                text: title,
                                children: [
                                  TextSpan(
                                    text: '    $detail',
                                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400, letterSpacing: 0, color: selected ? MenuInk.body : MenuInk.dim),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Text(title, maxLines: short ? 1 : titleLines, overflow: TextOverflow.ellipsis),
                    ),
                    if (!inline && detail != null && detail!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: tight ? 11.5 : 12, height: 1.3, color: selected ? MenuInk.body : MenuInk.dim),
                        ),
                      ),
                    if (tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Wrap(spacing: 5, runSpacing: 4, children: tags),
                      ),
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: tight ? 11.5 : 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? MenuInk.title : MenuInk.dim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
              if (selected || chevron)
                SizedBox(
                  width: 32,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: chevron
                        ? Icon(Icons.chevron_right_rounded, size: 21, color: selected ? VyseColors.accent : MenuInk.faint)
                        : (live ? const LiveBars() : const Icon(Icons.check_rounded, size: 19, color: VyseColors.accent)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three bars that move: this one is playing.
class LiveBars extends StatefulWidget {
  const LiveBars({super.key, this.color = VyseColors.accent, this.height = 14});
  final Color color;
  final double height;

  @override
  State<LiveBars> createState() => _LiveBarsState();
}

class _LiveBarsState extends State<LiveBars> with SingleTickerProviderStateMixin {
  late final _t = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(size: Size(widget.height * 1.1, widget.height), painter: _Bars(_t, widget.color)),
  );
}

class _Bars extends CustomPainter {
  _Bars(this.t, this.color) : super(repaint: t);
  final Animation<double> t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width / 4.6;
    final paint = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final a = t.value * math.pi * 2;
      final v = .5 + .28 * math.sin(a * 2 + i * 2.1) + .22 * math.sin(a * 3 + i * 1.3);
      final h = size.height * (.26 + .74 * v.clamp(0.0, 1.0));
      final x = i * w * 1.8;
      canvas.drawRRect(RRect.fromLTRBR(x, size.height - h, x + w, size.height, Radius.circular(w / 2)), paint);
    }
  }

  @override
  bool shouldRepaint(_Bars old) => old.color != color;
}

/// A step to somewhere else: sync subtitles, another source.
class _Onward extends StatelessWidget {
  const _Onward({required this.title, required this.detail, required this.onTap});
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .985 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: EdgeInsets.symmetric(vertical: shortMenus(context) ? 2 : 3),
        padding: shortMenus(context) ? const EdgeInsets.fromLTRB(13, 9, 12, 9) : const EdgeInsets.fromLTRB(13, 11, 12, 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: Colors.white.withValues(alpha: hovered ? .13 : .07),
          border: Border.all(color: MenuInk.hair),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.28, fontWeight: FontWeight.w700, letterSpacing: -.15, color: MenuInk.title)),
                  if (!shortMenus(context)) ...[
                    const SizedBox(height: 2),
                    Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, height: 1.3, color: MenuInk.dim)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnimatedSlide(
              offset: Offset(hovered ? .16 : 0, 0),
              duration: const Duration(milliseconds: 220),
              curve: MenuInk.ease,
              child: const Icon(Icons.arrow_forward_rounded, size: 19, color: VyseColors.accent),
            ),
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────── Sources ─────────────────────────

enum SourceState { loading, ready, dead }

class MenuSource {
  const MenuSource({required this.name, this.note, this.quality, this.state = SourceState.ready, this.current = false, this.onTap});
  final String name;
  final String? note;
  final String? quality;
  final SourceState state;
  final bool current;
  final VoidCallback? onTap;
}

class SourcesPane extends StatelessWidget {
  const SourcesPane({super.key, required this.sources, this.now, this.onMore});
  final List<MenuSource> sources;
  final Widget? now; // what's playing, when it came from an addon
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    var i = 0;
    return MenuScroll(
      children: [
        if (now != null) Rise(index: i++, child: now!),
        for (final s in sources)
          Rise(
            index: i++,
            child: MenuRow(
              title: s.name,
              detail: switch (s.state) {
                SourceState.dead => 'Non funziona per questo · tocca per riprovare',
                SourceState.loading => 'Controllo…',
                SourceState.ready => s.note,
              },
              value: s.quality,
              quiet: s.state == SourceState.dead,
              selected: s.current,
              live: true,
              leading: switch (s.state) {
                SourceState.dead => const _Dot(color: Color(0xFFFF5A5F)),
                SourceState.loading => const SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: MenuInk.body)),
                SourceState.ready => null,
              },
              onTap: s.onTap,
            ),
          ),
        if (onMore != null)
          Rise(
            index: i++,
            child: _Onward(title: 'Scegli un\'altra sorgente', detail: 'La lista dei tuoi addon, sopra il video', onTap: onMore!),
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: .55), blurRadius: 7)],
    ),
  );
}

/// One way to play from a film source: a Movy server, or one of a source's links.
class MenuLink {
  const MenuLink({required this.name, this.quality, this.format, this.audio, this.state, this.current = false, this.onTap});
  final String name;
  final String? quality; // '1080p', '4K'… when it's known
  final String? format; // 'HLS', 'MP4', 'MKV'…
  final String? audio; // dubbed into this language
  final SourceState? state; // null: not tried yet
  final bool current;
  final VoidCallback? onTap;
}

class MenuFilmSource {
  const MenuFilmSource({
    required this.id,
    required this.name,
    required this.note,
    this.servers = false,
    this.state,
    this.links = const [],
    this.onOpen,
  });
  final String id;
  final String name;
  final String note;
  final bool servers; // its links are servers, each asked when it's tried (Movy)
  final SourceState? state; // its own lookup; null: not looked up yet
  final List<MenuLink> links;
  final VoidCallback? onOpen; // look it up (again)
}

/// Film and TV sources in the order they're asked. Each opens to its links, with their quality
/// and format, the way a subtitle language opens to its files. Nothing is looked up until it's
/// reached in the search, or opened here.
class FilmSourcesPane extends StatefulWidget {
  const FilmSourcesPane({super.key, required this.sources, this.hostOrder = false});
  final List<MenuFilmSource> sources;
  final bool hostOrder; // a party guest: the host's list and order
  @override
  State<FilmSourcesPane> createState() => _FilmSourcesPaneState();
}

class _FilmSourcesPaneState extends State<FilmSourcesPane> {
  String? _open; // the source being browsed

  @override
  Widget build(BuildContext context) {
    final open = widget.sources.where((s) => s.id == _open).firstOrNull;
    return MenuSlide(index: open == null ? 0 : 1, child: open == null ? _sources() : _links(open));
  }

  void _openSource(MenuFilmSource s) {
    setState(() => _open = s.id);
    if (s.state == null || s.state == SourceState.dead) s.onOpen?.call();
  }

  Widget _sources() {
    var i = 0;
    return MenuScroll(
      children: [
        MenuCaption(widget.hostOrder ? "NELL'ORDINE DELL'HOST" : 'NEL TUO ORDINE'),
        for (var n = 0; n < widget.sources.length; n++) Rise(index: i++, child: _source(n + 1, widget.sources[n])),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Text(
            widget.hostOrder ? 'La lista segue Impostazioni → Sorgenti dell\'host' : 'Cambia l\'ordine in Impostazioni → Sorgenti',
            style: const TextStyle(fontSize: 11.5, color: MenuInk.faint),
          ),
        ),
      ],
    );
  }

  Widget _source(int rank, MenuFilmSource s) {
    final now = s.links.where((l) => l.current).firstOrNull;
    final trying = s.links.where((l) => l.state == SourceState.loading).firstOrNull;
    final looking = s.state == SourceState.loading || trying != null;
    final dead = s.state == SourceState.dead;
    final failed = s.links.where((l) => l.state == SourceState.dead && !l.current).length;
    final unit = s.servers ? 'server' : 'link';
    final best = _best(s.links);
    final detail = now != null
        ? 'In riproduzione: ${now.name}'
        : s.state == SourceState.loading
        ? 'Ricerca dei link…'
        : trying != null
        ? 'Provo ${trying.name}…'
        : dead
        ? 'Niente per questo · tocca per cercare di nuovo'
        : s.state == null || (s.servers && failed == 0)
        ? s.note
        : [
            '${s.links.length} ${s.links.length == 1 ? unit : '${unit}s'}',
            if (best != null && !s.servers) 'fino a $best',
            if (failed > 0) '$failed non partiti',
          ].join(' · ');
    return MenuRow(
      title: s.name,
      detail: detail,
      value: now?.quality,
      selected: now != null,
      quiet: dead,
      chevron: true,
      leading: SizedBox(
        width: 18,
        child: Center(
          child: looking
              ? const SizedBox.square(dimension: 11, child: CircularProgressIndicator(strokeWidth: 1.5, color: MenuInk.body))
              : dead
              ? const _Dot(color: Color(0xFFFF5A5F))
              : Text(
                  '$rank',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: now != null ? VyseColors.accent : MenuInk.faint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
      ),
      onTap: () => _openSource(s),
    );
  }

  static const _ranks = ['4K', '2160p', '1440p', '1080p', '720p', '480p', '360p'];

  /// The best quality a source's links say they have.
  static String? _best(List<MenuLink> links) {
    String? best;
    for (final l in links) {
      final r = _ranks.indexOf(l.quality ?? '');
      if (r >= 0 && (best == null || r < _ranks.indexOf(best))) best = l.quality;
    }
    return best;
  }

  Widget _links(MenuFilmSource s) {
    final looking = s.state == SourceState.loading || (s.state == null && !s.servers);
    final unit = s.servers ? 'servers' : 'links';
    return MenuScroll(
      children: [
        Pressable(
          onTap: () => setState(() => _open = null),
          builder: (context, hovered, _) => Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 12, 6),
            child: Row(
              children: [
                Icon(Icons.chevron_left_rounded, size: 23, color: hovered ? Colors.white : MenuInk.dim),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, letterSpacing: -.15, color: MenuInk.title)),
                ),
                const SizedBox(width: 8),
                if (s.links.isNotEmpty) Text('${s.links.length} $unit', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: MenuInk.faint)),
              ],
            ),
          ),
        ),
        if (looking && s.links.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            child: Row(
              children: [
                const SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white)),
                const SizedBox(width: 12),
                Expanded(child: Text('Ricerca dei link su ${s.name}…', style: const TextStyle(fontSize: 13, color: MenuInk.body))),
              ],
            ),
          )
        else if (s.state == SourceState.dead) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
            child: Text('${s.name} non ha niente per questo', style: const TextStyle(fontSize: 13, color: MenuInk.dim)),
          ),
          if (s.onOpen != null) _Onward(title: 'Cerca di nuovo', detail: 'Chiede di nuovo a ${s.name}', onTap: s.onOpen!),
        ] else
          for (var i = 0; i < s.links.length; i++) Rise(index: i, child: _link(s.links[i])),
      ],
    );
  }

  Widget _link(MenuLink l) {
    final dead = !l.current && l.state == SourceState.dead;
    final trying = l.state == SourceState.loading;
    return MenuRow(
      title: l.name,
      detail: l.current
          ? 'In riproduzione ora'
          : trying
          ? 'Controllo che parta…'
          : dead
          ? 'Non è partito · tocca per riprovare'
          : null,
      value: l.quality ?? (l.format == 'HLS' ? 'Auto' : null),
      tags: [
        if (l.audio != null) MenuTag(audioTag(l.audio!), strong: true),
        if (l.format != null) MenuTag(l.format!),
      ],
      selected: l.current,
      live: true,
      quiet: dead,
      leading: trying
          ? const SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: MenuInk.body))
          : dead
          ? const _Dot(color: Color(0xFFFF5A5F))
          : null,
      onTap: l.current || trying ? null : l.onTap,
    );
  }
}

/// What's playing from an addon: its logo, its line, its badges.
class MenuNow extends StatelessWidget {
  const MenuNow({super.key, required this.title, required this.leading, this.badges});
  final String title;
  final Widget leading;
  final Widget? badges;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(13, 8, 13, 10),
    child: Row(
      children: [
        leading,
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: -.1, color: MenuInk.title)),
              if (badges != null) Padding(padding: const EdgeInsets.only(top: 5), child: badges),
            ],
          ),
        ),
        const SizedBox(width: 10),
        const LiveBars(),
      ],
    ),
  );
}

// ───────────────────────── Quality ─────────────────────────

class MenuQuality {
  const MenuQuality({required this.label, this.detail, this.selected = false, this.onTap});
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;
}

class QualityPane extends StatelessWidget {
  const QualityPane({super.key, required this.items, this.auto, this.only});
  final List<MenuQuality> items;
  final MenuQuality? auto;
  final MenuQuality? only; // the server has one quality

  @override
  Widget build(BuildContext context) {
    var i = 0;
    return MenuScroll(
      children: [
        if (only != null) Rise(index: i++, child: MenuRow(title: only!.label, detail: only!.detail, selected: true, onTap: () {})),
        if (auto != null) Rise(index: i++, child: MenuRow(title: auto!.label, detail: auto!.detail, selected: auto!.selected, onTap: auto!.onTap)),
        for (final q in items)
          Rise(
            index: i++,
            child: MenuRow(title: q.label, value: q.detail, selected: q.selected, onTap: q.onTap),
          ),
      ],
    );
  }
}

// ───────────────────────── Audio ─────────────────────────

class MenuAudio {
  const MenuAudio({required this.title, this.detail, this.current = false, this.onTap});
  final String title;
  final String? detail;
  final bool current;
  final VoidCallback? onTap;
}

/// A link's or server's language as its source words it, for a menu: 'Hindi', and 'English
/// subtitles' for the sources' 'English sub' (the sound stays as it is, the subtitles are in).
String audioLabel(String audio) {
  final a = audio.trim();
  final m = RegExp(r'^(.*\S)\s+subs?$', caseSensitive: false).firstMatch(a);
  return m == null ? a : 'Sottotitoli ${m[1]}';
}

/// The same as a tag on a link: 'Hindi audio', 'English subtitles'.
String audioTag(String audio) {
  final label = audioLabel(audio);
  return label.endsWith(' subtitles') ? label : 'Audio $label';
}

class AudioPane extends StatelessWidget {
  const AudioPane({super.key, required this.tracks, this.links = const [], this.linksCaption = 'SU UN ALTRO LINK', this.elsewhere = const [], this.sound = const []});
  final List<MenuAudio> tracks;
  final List<MenuAudio> links; // languages on the playing source's other links
  final String linksCaption;
  final List<MenuAudio> elsewhere; // languages on other servers
  final List<Widget> sound; // sync, passthrough, channels, levelling

  @override
  Widget build(BuildContext context) {
    var i = 0;
    return MenuScroll(
      children: [
        if (tracks.isEmpty) Rise(index: i++, child: const MenuRow(title: 'Caricamento…')),
        for (final t in tracks)
          Rise(
            index: i++,
            child: MenuRow(title: t.title, detail: t.detail, selected: t.current, live: true, onTap: t.onTap),
          ),
        if (links.isNotEmpty) ...[
          MenuCaption(linksCaption),
          for (final t in links)
            Rise(
              index: i++,
              child: MenuRow(title: t.title, detail: t.detail, chevron: true, onTap: t.onTap),
            ),
        ],
        if (elsewhere.isNotEmpty) ...[
          const MenuCaption('SU UN ALTRO SERVER'),
          for (final t in elsewhere)
            Rise(
              index: i++,
              child: MenuRow(title: t.title, detail: t.detail, chevron: true, onTap: t.onTap),
            ),
        ],
        if (sound.isNotEmpty) ...[
          const MenuCaption('SOUND'),
          for (final w in sound) Rise(index: i++, child: w),
        ],
      ],
    );
  }
}

// ───────────────────────── Speed ─────────────────────────

class SpeedPane extends StatelessWidget {
  const SpeedPane({super.key, required this.speeds, this.more = const [], required this.value, required this.onChanged, required this.position, required this.duration});
  final List<(double, String)> speeds;
  final List<(double, String)> more; // a second row: slow motion and fast forward
  final double value;
  final ValueChanged<double> onChanged;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;

  @override
  Widget build(BuildContext context) {
    final tight = tightMenus(context);
    final shown = value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
    return MenuScroll(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      children: [
        Rise(
          index: 0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: shown),
                    TextSpan(text: '×', style: TextStyle(fontSize: tight ? 22 : 28, fontWeight: FontWeight.w500, letterSpacing: 0, color: MenuInk.dim)),
                  ],
                ),
                style: TextStyle(fontSize: tight ? 38 : 50, height: 1, fontWeight: FontWeight.w800, letterSpacing: tight ? -1.4 : -2, color: MenuInk.title, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: AnimatedBuilder(
                  animation: Listenable.merge([position, duration]),
                  builder: (context, _) {
                    final left = duration.value - position.value;
                    final real = left * (1 / value);
                    final ends = duration.value > Duration.zero ? TimeOfDay.fromDateTime(DateTime.now().add(real)).format(context) : null;
                    final saved = (left - real).inMinutes;
                    return Text(
                      [
                        if (ends != null) 'Finisce alle $ends',
                        if (saved > 0) '$saved min prima',
                        if (saved < 0) '${-saved} min dopo',
                      ].join('\n'),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: tight ? 12 : 13, height: 1.35, color: MenuInk.dim),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: tight ? 12 : 16),
        Rise(
          index: 1,
          child: MenuSegments<double>(value: value, height: tight ? 38 : 42, fontSize: tight ? 12 : 13, options: speeds, onChanged: onChanged),
        ),
        if (more.isNotEmpty) ...[
          const SizedBox(height: 8),
          Rise(
            index: 2,
            child: MenuSegments<double>(value: value, height: tight ? 34 : 38, fontSize: tight ? 12 : 12.5, options: more, onChanged: onChanged),
          ),
        ],
      ],
    );
  }
}

// ───────────────────────── Subtitles ─────────────────────────

/// Tracks and how they look: side by side when there's room, otherwise a tab each.
class SubtitlesPane extends StatefulWidget {
  const SubtitlesPane({super.key, required this.fit, required this.offset, required this.tracks, required this.loading, required this.active, required this.onTrack, required this.onSync, this.art});
  final PanelFit fit;
  final double offset;
  final List<sub.SubtitleTrack> tracks;
  final bool loading;
  final sub.SubtitleTrack? active;
  final ValueChanged<sub.SubtitleTrack?> onTrack;
  final VoidCallback onSync;
  final String? art;

  @override
  State<SubtitlesPane> createState() => _SubtitlesPaneState();
}

class _SubtitlesPaneState extends State<SubtitlesPane> {
  bool _style = false;
  String? _open; // the language being browsed

  @override
  Widget build(BuildContext context) {
    final list = MenuSlide(index: _open == null ? 0 : 1, child: _open == null ? _languages() : _files(_open!));
    if (!widget.fit.narrow) {
      return SizedBox(
        height: widget.fit.maxBody,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: list),
            Container(width: 1, margin: const EdgeInsets.symmetric(vertical: 12), color: MenuInk.hair),
            SizedBox(width: 244, child: _SubtitleStyle(art: widget.art)),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(10, shortMenus(context) ? 6 : 8, 10, 0),
          child: MenuSegments<bool>(
            value: _style,
            height: shortMenus(context) ? 30 : 32,
            fontSize: 12,
            options: const [(false, 'Tracce'), (true, 'Aspetto')],
            onChanged: (v) => setState(() => _style = v),
          ),
        ),
        Flexible(
          child: MenuSlide(index: _style ? 1 : 0, child: _style ? _SubtitleStyle(art: widget.art) : list),
        ),
      ],
    );
  }

  Map<String, List<sub.SubtitleTrack>> get _groups {
    final groups = <String, List<sub.SubtitleTrack>>{};
    for (final t in widget.tracks) {
      (groups[t.language] ??= []).add(t);
    }
    return groups;
  }

  Widget _languages() {
    final groups = _groups;
    final real = groups.entries.where((e) => e.value.any((t) => !t.translated)).toList();
    final made = groups.entries.where((e) => e.value.every((t) => t.translated)).toList();
    var i = 0;
    return MenuScroll(
      children: [
        Rise(
          index: i++,
          child: _Onward(
            title: 'Sincronizza sottotitoli',
            detail: widget.offset == 0 ? 'Allineali ai dialoghi' : 'Offset ${widget.offset > 0 ? '+' : ''}${widget.offset}s',
            onTap: widget.onSync,
          ),
        ),
        Rise(
          index: i++,
          child: MenuRow(title: 'Off', selected: widget.active == null, onTap: () => widget.onTrack(null)),
        ),
        if (widget.loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
          )
        else if (groups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('Nessun sottotitolo trovato per questo', style: TextStyle(fontSize: 12.5, color: MenuInk.dim)),
          )
        else ...[
          for (final e in real) Rise(index: i++, child: _language(e.key, e.value)),
          if (made.isNotEmpty) ...[
            const MenuCaption('AUTO-TRANSLATED'),
            for (final e in made) Rise(index: i++, child: _language(e.key, e.value)),
          ],
        ],
      ],
    );
  }

  Widget _language(String lang, List<sub.SubtitleTrack> list) {
    final real = list.where((t) => !t.translated).length;
    final on = widget.active?.language == lang;
    return MenuRow(
      title: lang,
      detail: [
        if (real > 0) '$real ${real == 1 ? 'file' : 'files'}' else 'Translated on demand',
        if (on) _name(widget.active!, list),
      ].join(' · '),
      chevron: true,
      selected: on,
      onTap: () => setState(() => _open = lang),
    );
  }

  /// Timed to a camera copy in a cinema: off against a Blu-ray or web release.
  static bool _cam(sub.SubtitleTrack t) => RegExp(r'(^|[^a-z0-9])(hd-?cam|cam(rip)?|hd-?ts|telesync|ts|tc|telecine|hdtc)([^a-z0-9]|$)', caseSensitive: false).hasMatch(t.release);

  /// For extras rather than the film: a making-of, trailer, featurette.
  static bool _extra(sub.SubtitleTrack t) =>
      RegExp(r'making[ ._-]?of|behind[ ._-]?the[ ._-]?scenes|featurette|trailer|teaser|bonus|extras|the[ ._-]?asylums?[ ._-]', caseSensitive: false).hasMatch(t.release);

  Widget _files(String lang) {
    // ones likely to be off (camera copies, extras) go last; the rest keep their order
    final all = _groups[lang] ?? const <sub.SubtitleTrack>[];
    final list = [...all.where((t) => !_cam(t) && !_extra(t)), ...all.where((t) => _cam(t) && !_extra(t)), ...all.where(_extra)];
    return MenuScroll(
      children: [
        Pressable(
          onTap: () => setState(() => _open = null),
          builder: (context, hovered, _) => Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 12, 6),
            child: Row(
              children: [
                Icon(Icons.chevron_left_rounded, size: 23, color: hovered ? Colors.white : MenuInk.dim),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(lang, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, letterSpacing: -.15, color: MenuInk.title)),
                ),
                const SizedBox(width: 8),
                Text('${list.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: MenuInk.faint)),
              ],
            ),
          ),
        ),
        for (var i = 0; i < list.length; i++)
          Rise(
            index: i,
            child: MenuRow(
              title: _name(list[i], list),
              titleLines: 2,
              selected: list[i].id == widget.active?.id,
              tags: [
                // inside the video, or a file in the torrent
                if (list[i].provider == 'Built in') const MenuTag('Built in', strong: true),
                // anime: which of our servers it came from (they're all in the menu at once)
                if (animeServers.any((s) => s.name == list[i].provider)) MenuTag('Da ${list[i].provider}'),
                if (list[i].translated) const MenuTag('Tradotti automaticamente'),
                if (list[i].hearingImpaired) const MenuTag('SDH'),
                if (_extra(list[i])) const MenuTag('Forse non di questo film')
                else if (_cam(list[i])) const MenuTag('Tempi di una copia CAM'),
                MenuTag(list[i].format.toUpperCase()),
              ],
              onTap: () => widget.onTrack(list[i]),
            ),
          ),
      ],
    );
  }

  /// The release name when there is one, otherwise "English 3".
  static String _name(sub.SubtitleTrack t, List<sub.SubtitleTrack> list) {
    final r = t.release.replaceAll(RegExp(r'\.(srt|vtt|ass|ssa|sub)$', caseSensitive: false), '').trim();
    if (r.isNotEmpty && r.toLowerCase() != t.language.toLowerCase()) return r;
    return '${t.language} ${list.indexOf(t) + 1}';
  }
}

/// How captions look, on the title's artwork: the same settings, with the same steps and
/// colours, as Settings > Subtitles (they're one set of settings, so a change here shows there).
/// The player used to offer S / M / L / XL and three colours of its own, which fought with a
/// size or colour picked in Settings.
class _SubtitleStyle extends StatelessWidget {
  const _SubtitleStyle({this.art});
  final String? art;

  static const _label = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: MenuInk.dim);

  static String _tenths(int v) => (v / 10).toStringAsFixed(v % 10 == 0 ? 0 : 1);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      AppSettings.subtitleSize,
      AppSettings.subtitleColor,
      AppSettings.subtitleBackground,
      AppSettings.subtitleBold,
      AppSettings.subtitleItalic,
      AppSettings.subtitleOutline,
      AppSettings.subtitleTop,
      AppSettings.subtitleLift,
    ]),
    builder: (context, _) {
      final size = AppSettings.subtitleSize.value;
      final color = AppSettings.subtitleColor.value;
      final back = AppSettings.subtitleBackground.value;
      final bold = AppSettings.subtitleBold.value;
      final italic = AppSettings.subtitleItalic.value;
      final outline = AppSettings.subtitleOutline.value;
      final lift = AppSettings.subtitleLift.value;
      // a box strength from the old Soft preset (40) lights the nearest of today's steps
      final box = captionBoxLevels.reduce((a, b) => (a - back).abs() <= (b - back).abs() ? a : b);
      return MenuScroll(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 92,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (art != null)
                      CachedNetworkImage(imageUrl: art!, fit: BoxFit.cover, memCacheWidth: 520, fadeInDuration: const Duration(milliseconds: 220))
                    else
                      const ColoredBox(color: Color(0xFF14151D)),
                    const ColoredBox(color: Color(0x40000000)),
                    Align(
                      alignment: const Alignment(0, .72),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: MenuInk.ease,
                        padding: EdgeInsets.symmetric(horizontal: size * .26, vertical: size * .05),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: back / 100), borderRadius: BorderRadius.circular(size * .14)),
                        child: Text(
                          'Anteprima sottotitoli',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: size * .52,
                            height: 1.25,
                            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                            color: Color(color),
                            shadows: back == 0 ? const [Shadow(blurRadius: 3, color: Colors.black), Shadow(offset: Offset(1, 1), blurRadius: 2, color: Colors.black)] : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          MenuStepper(
            title: 'Dimensione del testo',
            label: '${size}px',
            changed: size != AppSettings.subtitleSize.fallback,
            onMinus: () => size > captionSizeMin ? AppSettings.subtitleSize.set(size - captionSizeStep) : null,
            onPlus: () => size < captionSizeMax ? AppSettings.subtitleSize.set(size + captionSizeStep) : null,
            onReset: () => AppSettings.subtitleSize.set(AppSettings.subtitleSize.fallback),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Colore', style: _label),
                const SizedBox(height: 8),
                Wrap(
                  runSpacing: 8,
                  children: [
                    for (final c in captionColors) _Swatch(color: Color(c), selected: color == c, onTap: () => AppSettings.subtitleColor.set(c)),
                  ],
                ),
              ],
            ),
          ),
          MenuToggle(title: 'Grassetto', value: bold, onChanged: AppSettings.subtitleBold.set),
          MenuToggle(title: 'Corsivo', value: italic, onChanged: AppSettings.subtitleItalic.set),
          MenuChoice<int>(
            title: 'Riquadro',
            detail: 'Dietro al testo',
            value: box,
            options: [for (final v in captionBoxLevels) (v, v == 0 ? 'Nessuno' : '$v%')],
            onChanged: AppSettings.subtitleBackground.set,
          ),
          // the outline only shows without a box, as in Settings
          if (back == 0)
            MenuStepper(
              title: 'Contorno',
              label: outline == 0 ? 'Nessuno' : _tenths(outline),
              changed: outline != AppSettings.subtitleOutline.fallback,
              onMinus: () => outline > 0 ? AppSettings.subtitleOutline.set(outline - 5) : null,
              onPlus: () => outline < 80 ? AppSettings.subtitleOutline.set(outline + 5) : null,
              onReset: () => AppSettings.subtitleOutline.set(AppSettings.subtitleOutline.fallback),
            ),
          MenuChoice<bool>(
            title: 'Posizione',
            value: AppSettings.subtitleTop.value,
            options: const [(false, 'In basso'), (true, 'In alto')],
            onChanged: AppSettings.subtitleTop.set,
          ),
          MenuStepper(
            title: 'Dal bordo',
            label: lift == 0 ? 'Bordo' : '$lift%',
            changed: lift != AppSettings.subtitleLift.fallback,
            onMinus: () => lift > 0 ? AppSettings.subtitleLift.set(lift - 1) : null,
            onPlus: () => lift < 45 ? AppSettings.subtitleLift.set(lift + 1) : null,
            onReset: () => AppSettings.subtitleLift.set(AppSettings.subtitleLift.fallback),
          ),
        ],
      );
    },
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: MenuInk.ease,
        width: 30,
        height: 30,
        padding: EdgeInsets.all(selected ? 3.5 : 6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? VyseColors.accent : Colors.white.withValues(alpha: hovered ? .3 : .12), width: 1.5),
        ),
        child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      ),
    ),
  );
}

// ───────────────────────── More ─────────────────────────

/// The More tab: captioned groups of rows (picture, sleep, display, other players).
class MorePane extends StatelessWidget {
  const MorePane({super.key, required this.sections});
  final List<(String, List<Widget>)> sections;

  @override
  Widget build(BuildContext context) {
    var i = 0;
    return MenuScroll(
      children: [
        for (final (caption, rows) in sections)
          if (rows.isNotEmpty) ...[
            MenuCaption(caption),
            for (final r in rows) Rise(index: i++, child: r),
          ],
      ],
    );
  }
}

/// A setting that is on or off.
class MenuToggle extends StatelessWidget {
  const MenuToggle({super.key, required this.title, this.detail, required this.value, required this.onChanged});
  final String title;
  final String? detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) =>
      MenuRow(title: title, detail: detail, value: value ? 'On' : 'Off', selected: value, onTap: () => onChanged(!value));
}

/// Title on the left, − value + on the right. Tapping the value resets it.
class MenuStepper extends StatelessWidget {
  const MenuStepper({super.key, required this.title, this.detail, required this.label, required this.onMinus, required this.onPlus, this.onReset, this.changed = false});
  final String title;
  final String? detail;
  final String label;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback? onReset;
  final bool changed; // away from its default: lit

  @override
  Widget build(BuildContext context) {
    final tight = tightMenus(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(13, tight ? 6 : 8, 6, tight ? 6 : 8),
      child: Row(
        children: [
          Expanded(child: _MenuLabel(title: title, detail: detail)),
          _StepButton(icon: Icons.remove_rounded, onTap: onMinus),
          Pressable(
            onTap: onReset,
            builder: (context, hovered, _) => SizedBox(
              width: tight ? 76 : 86,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(
                  fontSize: tight ? 12.5 : 13.5,
                  fontWeight: FontWeight.w700,
                  color: changed ? VyseColors.accent : (hovered ? MenuInk.title : MenuInk.body),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _StepButton(icon: Icons.add_rounded, onTap: onPlus),
        ],
      ),
    );
  }
}

/// A titled row of choices.
class MenuChoice<T> extends StatelessWidget {
  const MenuChoice({super.key, required this.title, this.detail, required this.value, required this.options, required this.onChanged});
  final String title;
  final String? detail;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final tight = tightMenus(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(13, tight ? 6 : 8, 8, tight ? 8 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _MenuLabel(title: title, detail: detail),
          const SizedBox(height: 8),
          MenuSegments<T>(value: value, height: tight ? 32 : 34, fontSize: 12, options: options, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({required this.title, this.detail});
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final tight = tightMenus(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: tight ? 14 : 14.5, height: 1.28, fontWeight: FontWeight.w600, letterSpacing: -.15, color: MenuInk.body),
        ),
        if (detail != null && detail!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(detail!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: tight ? 11.5 : 12, height: 1.3, color: MenuInk.dim)),
          ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 34,
      height: 34,
      decoration: BoxDecoration(shape: BoxShape.circle, color: pressed ? const Color(0x30FFFFFF) : (hovered ? const Color(0x22FFFFFF) : const Color(0x12FFFFFF))),
      child: Icon(icon, size: 18, color: hovered ? Colors.white : MenuInk.body),
    ),
  );
}
