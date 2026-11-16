// VyseTV: picture-in-picture for Plezy's player.
//
// Android, iOS and macOS use the system's own picture-in-picture through the
// `com.plezy/pip` channel (MainActivity.kt on Android, Plezy's MpvPlayerPlugin
// + MpvPipController on Apple). Windows and Linux have no system PiP, so the app
// window itself becomes the small player: borderless, always on top, in the
// corner of the screen, draggable; it goes back to how it was on exit.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

abstract final class Pip {
  static const _channel = MethodChannel('com.plezy/pip');

  /// True while the video is in picture-in-picture (system PiP, or the desktop mini player).
  static final active = ValueNotifier(false);

  static bool _listening = false;
  static bool? _supported;

  static bool get _desktopMini => !kIsWeb && (Platform.isWindows || Platform.isLinux);
  static bool get _system => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static void _listen() {
    if (_listening || !_system) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipChanged') active.value = call.arguments == true;
    });
  }

  static Future<bool> isSupported() async {
    if (_desktopMini) return true;
    if (!_system) return false;
    _listen();
    try {
      return _supported ??= await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return _supported = false;
    }
  }

  /// Enters picture-in-picture. Returns null on success, otherwise what went wrong.
  static Future<String?> enter({int width = 16, int height = 9}) async {
    if (_desktopMini) return _enterMini(width, height);
    _listen();
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('enter', {'width': width, 'height': height});
      if (r?['success'] == true) return null;
      return switch (r?['errorCode']) {
        'permission_disabled' => 'Picture-in-picture is turned off for VyseTV in Android settings',
        'android_version' => 'Picture-in-picture needs Android 8 or newer',
        'not_supported' => "This device doesn't do picture-in-picture",
        _ => "Couldn't start picture-in-picture",
      };
    } catch (_) {
      return "Couldn't start picture-in-picture";
    }
  }

  /// Leaves picture-in-picture (the desktop mini player, or Apple's PiP window).
  static Future<void> exit() async {
    if (_desktopMini) return _exitMini();
    if (!_system) return;
    try {
      await _channel.invokeMethod('exit');
    } catch (_) {}
  }

  /// While playing, going home shrinks the video instead of stopping it (Android and iOS
  /// handle this themselves once told the player is ready).
  static Future<void> setAutoReady(bool ready, {int width = 16, int height = 9}) async {
    if (!_system || !(await isSupported())) return;
    try {
      await _channel.invokeMethod('setAutoPipReady', {'ready': ready, 'width': width, 'height': height});
    } catch (_) {}
  }

  // ── desktop mini player ──

  static Rect? _savedBounds;
  static bool _savedFullScreen = false;
  static bool _savedMaximized = false;

  static Future<String?> _enterMini(int width, int height) async {
    if (active.value) return null;
    try {
      _savedFullScreen = await windowManager.isFullScreen();
      _savedMaximized = await windowManager.isMaximized();
      if (_savedFullScreen) await windowManager.setFullScreen(false);
      if (_savedMaximized) await windowManager.unmaximize();
      _savedBounds = await windowManager.getBounds();

      // about a fifth of the screen wide, at the picture's shape, bottom right
      final display = await _displayFor(_savedBounds!);
      final area = (display?.visiblePosition ?? Offset.zero) & (display?.visibleSize ?? display?.size ?? const Size(1920, 1080));
      final aspect = width > 0 && height > 0 ? (width / height).clamp(.5, 3.0) : 16 / 9;
      final w = (area.width * .22).clamp(320.0, 640.0);
      final size = Size(w, w / aspect);
      const margin = 24.0;

      await windowManager.setMinimumSize(const Size(200, 120));
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(Rect.fromLTWH(area.right - size.width - margin, area.bottom - size.height - margin, size.width, size.height));
      active.value = true;
      return null;
    } catch (_) {
      await _exitMini();
      return "Couldn't shrink the window";
    }
  }

  static Future<void> _exitMini() async {
    if (!active.value) return;
    active.value = false;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(400, 640)); // main.dart's
      final b = _savedBounds;
      if (b != null) await windowManager.setBounds(b);
      if (_savedMaximized) await windowManager.maximize();
      if (_savedFullScreen) await windowManager.setFullScreen(true);
    } catch (_) {}
  }

  static Future<Display?> _displayFor(Rect window) async {
    try {
      final c = window.center;
      for (final d in await screenRetriever.getAllDisplays()) {
        final r = (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
        if (r.contains(c)) return d;
      }
      return await screenRetriever.getPrimaryDisplay();
    } catch (_) {
      return null;
    }
  }
}
