import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Lorewatch: the app's colours, for night (the original look) and day. [light] is set by
/// [ThemeModeController] from Settings → Aspetto (Sistema, Chiaro, Scuro).
class VyseColors {
  static bool light = false;

  static Color get bg => light ? const Color(0xFFF4F5FA) : const Color(0xFF07080F);
  static Color get surface => light ? const Color(0xFFFFFFFF) : const Color(0xFF0E1020);
  static Color get surfaceHi => light ? const Color(0xFFE9EBF3) : const Color(0xFF171A2E);
  static Color get stroke => light ? const Color(0x1A000000) : const Color(0x14FFFFFF);
  static Color get strokeHi => light ? const Color(0x40000000) : const Color(0x33FFFFFF);
  static Color get text => light ? const Color(0xFF14151F) : const Color(0xFFF4F5FB);
  static Color get textDim => light ? const Color(0xFF4B5068) : const Color(0xFFA3A8C3);
  static Color get textFaint => light ? const Color(0xFF8187A2) : const Color(0xFF61668A);
  static Color get accent => light ? const Color(0xFFE88A00) : const Color(0xFFFFA53A);
  static Color get accentHot => light ? const Color(0xFFE05A00) : const Color(0xFFFF6A00);
  static const violet = Color(0xFF7A5CFF);
  static const star = Color(0xFFFFC23A);

  /// What the original dark look drew in translucent white (hover tints, soft boxes, dividers):
  /// black in day mode, so they still show on a light page.
  static Color get ink => light ? Colors.black : Colors.white;
}

/// Day, night or whatever the system is set to.
class ThemeModeController {
  /// Settings value: 'system', 'light' or 'dark'.
  static final mode = ValueNotifier<String>('dark');

  static bool resolveLight(String mode, Brightness platform) => switch (mode) {
    'light' => true,
    'dark' => false,
    _ => platform == Brightness.light,
  };
}

ThemeData buildVyseTheme() {
  final base = ThemeData(
    brightness: VyseColors.light ? Brightness.light : Brightness.dark,
    useMaterial3: true,
    // google_fonts 9 speaks material_ui's TextTheme, so take just the family (this also starts the download).
    fontFamily: GoogleFonts.inter().fontFamily,
    scaffoldBackgroundColor: VyseColors.bg,
    colorScheme: VyseColors.light
        ? ColorScheme.light(primary: VyseColors.accent, secondary: VyseColors.violet, surface: VyseColors.surface)
        : ColorScheme.dark(primary: VyseColors.accent, secondary: VyseColors.violet, surface: VyseColors.surface),
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
      textStyle: TextStyle(color: VyseColors.text, fontSize: 12),
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
