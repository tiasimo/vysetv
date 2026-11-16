import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import 'theme.dart';

/// The colour of the theme picked in Settings → Appearance, for the parts of the app that wear
/// it (Music). Provided above every page so switching theme repaints them at once.
class ThemeAccent extends InheritedWidget {
  const ThemeAccent({super.key, required this.color, required super.child});
  final Color color;

  static ThemeAccent? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ThemeAccent>();

  @override
  bool updateShouldNotify(ThemeAccent old) => old.color != color;
}

/// Keeps [ThemeAccent] in step with the Appearance setting.
Widget withThemeAccent(Widget? child) => ValueListenableBuilder<String>(
  valueListenable: AppSettings.themeId,
  builder: (context, _, _) => ThemeAccent(color: AppSettings.theme.color, child: child ?? const SizedBox.shrink()),
);

Color accentOf(BuildContext context) => ThemeAccent.maybeOf(context)?.color ?? AppSettings.theme.color;

/// The accent's deeper end, for gradients (Vyse's own amber keeps its orange).
Color accentHotOf(BuildContext context) {
  final c = accentOf(context);
  if (c.toARGB32() == VyseColors.accent.toARGB32()) return VyseColors.accentHot;
  final hsl = HSLColor.fromColor(c);
  return hsl.withHue((hsl.hue - 10) % 360).withLightness((hsl.lightness - .08).clamp(0, 1)).toColor();
}

/// Text and icons on the accent: dark on light accents (amber, emerald, cyan), white on deep ones.
Color onAccentOf(BuildContext context) => accentOf(context).computeLuminance() > .3 ? Colors.black : Colors.white;
