import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../data/tmdb.dart';
import 'shell.dart';

/// Boot animation: the helm fades up in the dark, the eyes draw outward like filaments, sputter,
/// flash on, a light sweep crosses the helm, then the wordmark rises in. Everything sits on one
/// centred column, and every glow is anchored to the eyes themselves.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
  bool _leaving = false;

  Animation<double> _seg(double a, double b, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _c, curve: Interval(a, b, curve: curve));

  late final _helm = _seg(0, .24);
  late final _reveal = _seg(.22, .38, Curves.easeInOutCubic);
  late final _power = TweenSequence([
    TweenSequenceItem(tween: ConstantTween(.12), weight: 38), // ember while drawing
    TweenSequenceItem(tween: Tween(begin: .12, end: .9), weight: 3),
    TweenSequenceItem(tween: Tween(begin: .9, end: .2), weight: 3),
    TweenSequenceItem(tween: Tween(begin: .2, end: 1.0), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: .45), weight: 2),
    TweenSequenceItem(tween: Tween(begin: .45, end: 1.35), weight: 3), // catches, flares
    TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 9),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
  ]).animate(_c);
  late final _sweep = _seg(.54, .72, Curves.easeInOut);
  late final _tagline = _seg(.76, .9);
  late final _exit = _seg(.92, 1, Curves.easeInCubic);

  @override
  void initState() {
    super.initState();
    HomeFeed.instance.warmUp();
    _c.forward().whenComplete(_goHome);
  }

  void _goHome() {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 650),
      pageBuilder: (_, _, _) => const AppShell(),
      transitionsBuilder: (_, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: t,
          child: ScaleTransition(scale: Tween(begin: 1.03, end: 1.0).animate(t), child: child),
        );
      },
    ));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    final markSize = (shortest * .34).clamp(140.0, 240.0);
    final wordSize = (markSize * .24).clamp(30.0, 50.0);

    return Scaffold(
      backgroundColor: VyseColors.bg,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _goHome,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final exit = _exit.value;
            return Opacity(
              opacity: 1 - exit,
              child: Transform.scale(
                scale: 1 + exit * .06,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Opacity(
                      opacity: _helm.value,
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - _helm.value)),
                        child: _Helm(
                          size: markSize,
                          reveal: _reveal.value,
                          power: _power.value,
                          sweep: _sweep.value,
                        ),
                      ),
                    ),
                    SizedBox(height: markSize * .14),
                    _RisingWordmark(progress: _c.value, fontSize: wordSize),
                    const SizedBox(height: 14),
                    Opacity(
                      opacity: _tagline.value,
                      child: Transform.translate(
                        offset: Offset(0, 6 * (1 - _tagline.value)),
                        child: const _SpacedText('FIND YOUR NEXT OBSESSION', spacing: 3.2),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Helm artwork with the eyes painted live on top, plus the light sweep.
class _Helm extends StatelessWidget {
  const _Helm({required this.size, required this.reveal, required this.power, required this.sweep});
  final double size;
  final double reveal;
  final double power;
  final double sweep;

  @override
  Widget build(BuildContext context) {
    Widget helm = SvgPicture.asset('assets/brand/vyse_helm.svg', width: size, height: size);
    if (sweep > 0 && sweep < 1) {
      helm = ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [Color(0x00FFFFFF), Color(0x44FFFFFF), Color(0x00FFFFFF)],
          stops: const [.42, .5, .58],
          transform: _Shift(-r.width + sweep * r.width * 3),
        ).createShader(Offset.zero & r.size),
        child: helm,
      );
    }
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        foregroundPainter: _EyesPainter(reveal: reveal, power: power),
        child: helm,
      ),
    );
  }
}

class _Shift extends GradientTransform {
  const _Shift(this.dx);
  final double dx;
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(dx, 0, 0);
}

/// Eye blades from vyse_mark.svg (512 viewBox). Inner edge first, outer tip last.
const _leftEye = [Offset(240, 276), Offset(236, 294), Offset(170, 272), Offset(146, 250)];
const _rightEye = [Offset(272, 276), Offset(276, 294), Offset(342, 272), Offset(366, 250)];

class _EyesPainter extends CustomPainter {
  _EyesPainter({required this.reveal, required this.power});

  /// 0..1 how far each blade has drawn out from the nose toward its tip.
  final double reveal;

  /// 0 = dark, ~0.1 = ember, 1 = lit, >1 = flash.
  final double power;

  static const _ember = Color(0xFF4A1E04);
  static const _hot = Color(0xFFFFF6DC);
  static const _amber = Color(0xFFFFB347);
  static const _orange = Color(0xFFFF6A00);

  Path _blade(List<Offset> pts, double s) {
    final innerTop = pts[0], innerBottom = pts[1];
    Offset grow(Offset p) => Offset.lerp(Offset.lerp(innerTop, innerBottom, .5)!, p, reveal)!;
    return Path()
      ..moveTo(innerTop.dx * s, innerTop.dy * s)
      ..lineTo(innerBottom.dx * s, innerBottom.dy * s)
      ..lineTo(grow(pts[2]).dx * s, grow(pts[2]).dy * s)
      ..lineTo(grow(pts[3]).dx * s, grow(pts[3]).dy * s)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    final s = size.width / 512;
    final lit = power.clamp(0.0, 1.0);
    final flare = (power - 1).clamp(0.0, 1.0);
    final center = Offset(256 * s, 274 * s);

    // wide amber bloom across the brow, anchored to the eyes
    if (lit > .15) {
      // Squash a circular falloff into a soft ellipse so it never shows an edge.
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(1, .32);
      canvas.drawCircle(
        Offset.zero,
        230 * s,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            230 * s,
            [
              const Color(0xFFFF8A1A).withValues(alpha: .22 * lit + .2 * flare),
              const Color(0xFFFF8A1A).withValues(alpha: .07 * lit),
              const Color(0x00FF8A1A),
            ],
            [0, .45, 1],
          ),
      );
      canvas.restore();
    }

    for (final eye in [_leftEye, _rightEye]) {
      final path = _blade(eye, s);
      final bounds = path.getBounds();
      final innerIsRight = eye == _leftEye;

      // soft glow halo
      if (lit > .05) {
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFFFF8A1A).withValues(alpha: (.9 * lit + .1 * flare).clamp(0, 1))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, (10 + 10 * flare) * s),
        );
      }

      // the blade: white-hot at the nose, burning out to orange at the tip
      final inner = Color.lerp(_ember, _hot, lit)!;
      final mid = Color.lerp(_ember, _amber, lit)!;
      final outer = Color.lerp(_ember, _orange, lit)!;
      canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.linear(
            innerIsRight ? bounds.centerRight : bounds.centerLeft,
            innerIsRight ? bounds.centerLeft : bounds.centerRight,
            [inner, mid, outer],
            [0, .4, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_EyesPainter old) => old.reveal != reveal || old.power != power;
}

class _RisingWordmark extends StatelessWidget {
  const _RisingWordmark({required this.progress, required this.fontSize});
  final double progress;
  final double fontSize;

  static const _letters = ['V', 'y', 's', 'e', 'T', 'V'];

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < _letters.length; i++)
          Builder(builder: (_) {
            final start = .58 + i * .035;
            final t = Curves.easeOutCubic.transform(((progress - start) / .14).clamp(0.0, 1.0));
            final tv = i >= 4;
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, fontSize * .45 * (1 - t)),
                child: Text(
                  _letters[i],
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.5,
                    height: 1,
                    color: tv ? VyseColors.accent : VyseColors.text,
                    shadows: tv ? [Shadow(color: VyseColors.accentHot.withValues(alpha: .5 * t), blurRadius: 20)] : null,
                  ),
                ),
              ),
            );
          }),
      ]);
}

/// Letter-spaced text that stays optically centred (Flutter adds the spacing after the last glyph too).
class _SpacedText extends StatelessWidget {
  const _SpacedText(this.text, {required this.spacing});
  final String text;
  final double spacing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: spacing),
        child: Text(
          text,
          style: TextStyle(
            color: VyseColors.textFaint,
            fontSize: 11.5,
            letterSpacing: spacing,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
