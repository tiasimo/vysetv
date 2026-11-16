import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';

/// Slim always-visible thumb you can grab and drag; widens and brightens on hover.
/// Phones only show it while scrolling. [hidden] removes it entirely (spotlight mode).
class PageScrollbar extends StatelessWidget {
  const PageScrollbar({super.key, required this.controller, required this.child, this.hidden = false});
  final ScrollController controller;
  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged) ? 9 : 5,
        ),
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.dragged)) return VyseColors.accent;
          if (s.contains(WidgetState.hovered)) return Colors.white.withValues(alpha: .55);
          return Colors.white.withValues(alpha: .25);
        }),
        trackColor: WidgetStateProperty.all(Colors.white.withValues(alpha: .04)),
        trackBorderColor: WidgetStateProperty.all(Colors.transparent),
        radius: const Radius.circular(8),
        crossAxisMargin: 3,
        mainAxisMargin: 4,
        minThumbLength: 48,
      ),
      // The scrollbar insets its track by MediaQuery padding: push it below the window controls,
      // then hand the page its real MediaQuery back.
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: EdgeInsets.only(top: Layout.topChrome(context), bottom: phone ? 70 : 0),
        ),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: !hidden && !phone,
          interactive: !hidden,
          child: MediaQuery(data: MediaQuery.of(context), child: child),
        ),
      ),
    );
  }
}
