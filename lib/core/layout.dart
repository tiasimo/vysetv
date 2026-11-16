import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool get isDesktopNative =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

bool get isMacNative => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Windows and Linux draw their own min/max/close; macOS keeps its traffic lights.
bool get hasCustomWindowButtons => isDesktopNative && !isMacNative;

/// Whether the Mac window is full screen, from the window's own events (main.dart). However it
/// got there: the green button, or a player's full screen button.
final macFullScreen = ValueNotifier<bool>(false);

/// Sits above every page so they follow [macFullScreen]: in full screen a Mac takes its traffic
/// lights away, and the strip kept free for them at the top goes with them.
class MacFullScreenScope extends InheritedNotifier<ValueNotifier<bool>> {
  MacFullScreenScope({super.key, required super.child}) : super(notifier: macFullScreen);

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MacFullScreenScope>()?.notifier?.value ?? false;
}

enum FormFactor { phone, tablet, desktop }

/// Pages that need the whole phone screen (chats, rooms) raise this while open; the phone's
/// bottom tab bar stays hidden while it's above zero.
final hideBottomBar = ValueNotifier<int>(0);

/// A page showing something over the whole window (a room's watch party in full screen): the
/// shell's rail, bars and glow step aside while it's above zero.
final fullWindow = ValueNotifier<int>(0);

/// A part of the window that lays out its own pages (the music frame, beside its sidebar):
/// pages inside start [inset] from its left edge, with no window chrome above them.
class LayoutFrame extends InheritedWidget {
  const LayoutFrame({super.key, required this.inset, required super.child});
  final double inset;

  static LayoutFrame? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LayoutFrame>();

  @override
  bool updateShouldNotify(LayoutFrame old) => old.inset != inset;
}

class Layout {
  static const railCollapsed = 72.0;
  static const railExpanded = 280.0;

  static FormFactor of(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < 640) return FormFactor.phone;
    if (w < 1100) return FormFactor.tablet;
    return FormFactor.desktop;
  }

  static bool isPhone(BuildContext context) => of(context) == FormFactor.phone;

  /// Left edge of page content, clearing the floating rail.
  static double inset(BuildContext context) => LayoutFrame.of(context)?.inset ?? switch (of(context)) {
        FormFactor.phone => 16,
        FormFactor.tablet => railCollapsed + 24,
        FormFactor.desktop => railCollapsed + 38,
      };

  /// Space eaten at the top by window chrome or the status bar.
  static double topChrome(BuildContext context) => LayoutFrame.of(context) != null ? 0 : windowChrome(context);

  /// Window chrome / status bar only (same as [topChrome] now that the nav lives in the rail).
  static double windowChrome(BuildContext context) {
    if (hasCustomWindowButtons) return 36;
    if (isMacNative) return MacFullScreenScope.of(context) ? 0 : 28;
    return MediaQuery.paddingOf(context).top;
  }
}
