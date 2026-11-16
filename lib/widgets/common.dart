import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';

/// Hover + press state for any tappable surface, with a pointer cursor.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.builder, this.onTap, this.tooltip});

  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    Widget child = MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: widget.builder(context, _hovered, _pressed),
      ),
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return child;
  }
}

/// Every placeholder button lands here until the real screen exists.
/// VyseTV's Discord, opened in the browser (About in Settings, and the foot of Home).
const discordInvite = 'https://discord.gg/dUJTGnUhz2';

Future<void> openDiscord(BuildContext context) async {
  final ok = await launchUrl(Uri.parse(discordInvite), mode: LaunchMode.externalApplication).catchError((Object _) => false);
  if (!ok && context.mounted) {
    showToast(context, const Text("Couldn't open Discord. The invite is discord.gg/dUJTGnUhz2", style: TextStyle(fontSize: 13)), icon: Icons.error_outline);
  }
}

void comingSoon(BuildContext context, String what) => showToast(
      context,
      Text.rich(
        TextSpan(children: [
          TextSpan(text: what, style: const TextStyle(fontWeight: FontWeight.w700)),
          const TextSpan(text: '  is coming soon', style: TextStyle(color: VyseColors.textDim)),
        ]),
        style: const TextStyle(fontSize: 13, color: VyseColors.text),
      ),
    );

/// [onTap]: the toast can be pressed (a message opens its chat), and stays up longer for it.
void showToast(BuildContext context, Widget message, {IconData icon = Icons.auto_awesome_rounded, VoidCallback? onTap}) {
  // A snack bar is drawn by the page's Scaffold, and only the main pages have one: from the
  // player, a watch party or a dialog it would come up underneath, unseen. There the toast goes
  // on top of everything instead.
  final above = Scaffold.maybeOf(context) == null ? Overlay.maybeOf(context, rootOverlay: true) : null;
  if (above != null) {
    _toastAbove(above, message, icon: icon, onTap: onTap);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  // Solid, not see-through: toasts also pop up over bright video (watch party, live sports).
  final Widget panel = Glass(
    radius: 14,
    solid: true,
    borderColor: Colors.white.withValues(alpha: .14),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(children: [
      Icon(icon, size: 18, color: VyseColors.accent),
      const SizedBox(width: 10),
      // The SnackBar's own text style is dark (made for a light bar); ours is a dark panel.
      Expanded(
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
          child: message,
        ),
      ),
      if (onTap != null) const Icon(Icons.chevron_right_rounded, size: 18, color: VyseColors.textDim),
    ]),
  );
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      duration: Duration(milliseconds: onTap == null ? 1600 : 4500),
      width: 340,
      content: onTap == null
          ? panel
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  messenger.hideCurrentSnackBar();
                  onTap();
                },
                child: panel,
              ),
            ),
    ),
  );
}

OverlayEntry? _toastEntry;
Timer? _toastTimer;

/// The toast for places without a Scaffold (see [showToast]): a pill at the top of the window,
/// over the player and anything else. One at a time; a new one replaces the last.
void _toastAbove(OverlayState overlay, Widget message, {required IconData icon, VoidCallback? onTap}) {
  void clear() {
    _toastTimer?.cancel();
    _toastTimer = null;
    _toastEntry?.remove();
    _toastEntry = null;
  }

  clear();
  final Widget panel = Glass(
    radius: 14,
    solid: true,
    borderColor: Colors.white.withValues(alpha: .14),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: VyseColors.accent),
      const SizedBox(width: 10),
      Flexible(
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
          child: message,
        ),
      ),
      if (onTap != null) ...[const SizedBox(width: 6), const Icon(Icons.chevron_right_rounded, size: 18, color: VyseColors.textDim)],
    ]),
  );
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.viewPaddingOf(context).top + 18,
      left: 16,
      right: 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // It slides in; nothing over the video may fade (the video is a native surface
          // behind Flutter's).
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: -1.4, end: 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (_, t, child) => FractionalTranslation(translation: Offset(0, t), child: child),
            child: Material(
              type: MaterialType.transparency,
              child: onTap == null
                  ? IgnorePointer(child: panel)
                  : MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          clear();
                          onTap();
                        },
                        child: panel,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
  _toastTimer = Timer(Duration(milliseconds: onTap == null ? 2600 : 4500), () {
    if (_toastEntry == entry) clear();
  });
}

/// Frosted panel used by the rail, bottom bar and floating controls.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
    this.opacity = .55,
    this.blur = 22,
    this.borderColor = VyseColors.stroke,
    this.solid = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double opacity;
  final double blur;
  final Color borderColor;

  /// The no-blur look (as on Android). For panels over the video: Plezy's player draws it on a
  /// native surface behind Flutter, where a BackdropFilter can't see it.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final light = lightEffects || solid;
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        // without the blur behind it, a denser tint keeps text just as readable
        color: VyseColors.surface.withValues(alpha: light ? (opacity + .35).clamp(0, .96) : opacity),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
    if (light) return panel;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: panel),
    );
  }
}

/// Android: skip live background blurs. Re-blurring everything behind a panel on every frame is
/// cheap on a desktop GPU but one of the costliest things a phone does while scrolling.
final bool lightEffects = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class VyseMark extends StatelessWidget {
  const VyseMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/brand/vyse_mark.svg', width: size, height: size);
}

class VyseWordmark extends StatelessWidget {
  const VyseWordmark({super.key, this.fontSize = 20});
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: const [
          TextSpan(text: 'Vyse'),
          TextSpan(text: 'TV', style: TextStyle(color: VyseColors.accent)),
        ]),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, letterSpacing: -.6),
      );
}

/// Fades and lifts its child in once, after [delay]. Used for staggered row entrances.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18, this.dx = 0});
  final Widget child;
  final Duration delay;
  final double offset;

  /// Horizontal travel, for panels that slide in from the side.
  final double dx;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () => mounted ? _c.forward() : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (_, child) => Opacity(
          opacity: _t.value,
          child: Transform.translate(
            offset: Offset(widget.dx * (1 - _t.value), widget.offset * (1 - _t.value)),
            child: child,
          ),
        ),
      );
}

/// Moving sheen over skeleton blocks while rows load.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final dx = bounds.width * 3 * _c.value - bounds.width;
            return LinearGradient(
              colors: const [VyseColors.surface, VyseColors.surfaceHi, VyseColors.surface],
              stops: const [.35, .5, .65],
              transform: _Slide(dx),
            ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height));
          },
          child: child,
        ),
      );
}

class _Slide extends GradientTransform {
  const _Slide(this.dx);
  final double dx;
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(dx, 0, 0);
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, required this.width, required this.height, this.radius = 12});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: VyseColors.surface, borderRadius: BorderRadius.circular(radius)),
      );
}

/// Small round icon button on glass, used in the hero and top bar.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.label, this.onTap, this.size = 44});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Pressable(
        tooltip: label,
        onTap: onTap ?? () => comingSoon(context, label),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .92 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: hovered ? .2 : .1),
              border: Border.all(color: Colors.white.withValues(alpha: hovered ? .35 : .14)),
            ),
            child: Icon(icon, size: size * .45, color: VyseColors.text),
          ),
        ),
      );
}

/// Pill button: solid white for primary, glass for secondary.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.icon,
    this.primary = false,
    this.onTap,
    this.expand = false,
    this.accent,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final bool expand;

  /// A primary pill in this colour instead of white (Music follows the Appearance theme).
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap ?? () => comingSoon(context, label),
        builder: (context, hovered, pressed) {
          final a = primary ? accent : null;
          final fg = a != null ? (a.computeLuminance() > .3 ? Colors.black : Colors.white) : (primary ? Colors.black : VyseColors.text);
          return AnimatedScale(
            scale: pressed ? .95 : (hovered ? 1.03 : 1),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: a != null
                    ? (hovered ? Color.lerp(a, Colors.white, .15) : a)
                    : primary
                    ? (hovered ? Colors.white : const Color(0xFFF1F1F5))
                    : Colors.white.withValues(alpha: hovered ? .2 : .1),
                border: primary ? null : Border.all(color: Colors.white.withValues(alpha: .14)),
                boxShadow: primary && hovered
                    ? [BoxShadow(color: (a ?? Colors.white).withValues(alpha: a != null ? .45 : .25), blurRadius: 24)]
                    : null,
              ),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
                ],
              ),
            ),
          );
        },
      );
}
