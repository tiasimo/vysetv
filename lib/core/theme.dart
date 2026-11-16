import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class VyseColors {
  static const bg = Color(0xFF07080F);
  static const surface = Color(0xFF0E1020);
  static const surfaceHi = Color(0xFF171A2E);
  static const stroke = Color(0x14FFFFFF);
  static const strokeHi = Color(0x33FFFFFF);
  static const text = Color(0xFFF4F5FB);
  static const textDim = Color(0xFFA3A8C3);
  static const textFaint = Color(0xFF61668A);
  static const accent = Color(0xFFFFA53A);
  static const accentHot = Color(0xFFFF6A00);
  static const violet = Color(0xFF7A5CFF);
  static const star = Color(0xFFFFC23A);
}

ThemeData buildVyseTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    // google_fonts 9 speaks material_ui's TextTheme, so take just the family (this also starts the download).
    fontFamily: GoogleFonts.inter().fontFamily,
    scaffoldBackgroundColor: VyseColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: VyseColors.accent,
      secondary: VyseColors.violet,
      surface: VyseColors.surface,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: VyseColors.text,
      displayColor: VyseColors.text,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: VyseColors.surfaceHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VyseColors.stroke),
      ),
      textStyle: const TextStyle(color: VyseColors.text, fontSize: 12),
    ),
  );
}

/// Drag-to-scroll with mouse and trackpad, no scrollbars: feels like a native media app.
class VyseScrollBehavior extends MaterialScrollBehavior {
  const VyseScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
