import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../mpv/mpv.dart' as pz;
import 'app_settings.dart';

/// The text colours offered for captions, in Settings > Subtitles and in the player's own
/// subtitle style menu: the same ones, so a pick in one is a pick in the other.
const captionColors = [0xFFFFFFFF, 0xFFFFE14D, 0xFF4DE1FF, 0xFF5BE37D, 0xFFFF6FB5];

/// The caption sizes both offer: 16 to 60, two at a time.
const captionSizeMin = 16, captionSizeMax = 60, captionSizeStep = 2;

/// How solid the box behind captions can be.
const captionBoxLevels = [0, 50, 75, 100];

/// A font the subtitles can be drawn in.
class SubtitleFontChoice {
  const SubtitleFontChoice(this.family, {this.label, this.preview, this.systemFiles = const []});

  /// The family libass is asked for (`sub-font`).
  final String family;
  final String? label;

  /// The Flutter family that shows it in the settings preview.
  final String? preview;

  /// Android: the file in /system/fonts that has it (copied next to Go Noto, since libass
  /// there sees no system fonts).
  final List<String> systemFiles;

  String get name => label ?? family;
}

/// How Plezy's player (mpv + libass) draws subtitles, from Settings > Subtitles.
abstract final class SubtitleStyle {
  static const defaultFamily = 'Go Noto Current-Regular';
  static const defaultFont = SubtitleFontChoice(defaultFamily, label: 'Go Noto (default)', preview: defaultFamily);

  /// Everything that changes the look; listen to re-apply.
  static final List<Listenable> settings = [
    AppSettings.subtitleSize,
    AppSettings.subtitleColor,
    AppSettings.subtitleBackground,
    AppSettings.subtitleFont,
    AppSettings.subtitleBold,
    AppSettings.subtitleItalic,
    AppSettings.subtitleBackColor,
    AppSettings.subtitleOutline,
    AppSettings.subtitleOutlineColor,
    AppSettings.subtitleShadow,
    AppSettings.subtitleShadowColor,
    AppSettings.subtitleBlur,
    AppSettings.subtitleSpacing,
    AppSettings.subtitleTop,
    AppSettings.subtitleLift,
    AppSettings.subtitleOnPicture,
    AppSettings.subtitleAss,
  ];

  static String get family => AppSettings.subtitleFont.value.isEmpty ? defaultFamily : AppSettings.subtitleFont.value;

  /// The phone's own fonts that exist on (nearly) every Android, with their family names.
  static const androidFonts = [
    SubtitleFontChoice('Roboto', preview: 'Roboto', systemFiles: ['Roboto-Regular.ttf']),
    SubtitleFontChoice('Noto Serif', preview: 'serif', systemFiles: ['NotoSerif-Regular.ttf']),
    SubtitleFontChoice('Source Sans Pro', preview: 'sans-serif', systemFiles: ['SourceSansPro-Regular.ttf']),
    SubtitleFontChoice('Carrois Gothic SC', preview: 'sans-serif-smallcaps', systemFiles: ['CarroisGothicSC-Regular.ttf']),
    SubtitleFontChoice('Droid Sans Mono', preview: 'monospace', systemFiles: ['DroidSansMono.ttf']),
    SubtitleFontChoice('Cutive Mono', preview: 'serif-monospace', systemFiles: ['CutiveMono.ttf']),
    SubtitleFontChoice('Coming Soon', preview: 'casual', systemFiles: ['ComingSoon.ttf']),
    SubtitleFontChoice('Dancing Script', preview: 'cursive', systemFiles: ['DancingScript-Regular.ttf']),
  ];

  static const _fonts = MethodChannel('vyse/fonts');
  static List<SubtitleFontChoice>? _available;

  /// Fonts to pick from: Go Noto first, then this device's.
  static Future<List<SubtitleFontChoice>> available() async {
    final cached = _available;
    if (cached != null) return cached;
    final list = <SubtitleFontChoice>[defaultFont];
    if (!kIsWeb && Platform.isWindows) {
      // libass finds any installed font by name on Windows (DirectWrite)
      try {
        final names = await _fonts.invokeListMethod<String>('families') ?? const [];
        list.addAll([for (final n in names) if (n != defaultFamily) SubtitleFontChoice(n, preview: n)]);
      } catch (_) {}
    } else if (!kIsWeb && Platform.isAndroid) {
      list.addAll(androidFonts.where((f) => f.systemFiles.any((file) => File('/system/fonts/$file').existsSync())));
    }
    return _available = list;
  }

  /// The choice for [family], for the preview and labels.
  static SubtitleFontChoice choiceFor(String family) {
    if (family.isEmpty || family == defaultFamily) return defaultFont;
    for (final f in androidFonts) {
      if (f.family == family) return f;
    }
    return SubtitleFontChoice(family, preview: family);
  }

  // ── the fonts folder libass reads ──

  static const _bundled = [
    ('assets/fonts/go-noto-current-regular.ttf', 'go-noto-current-regular.ttf', 14700060),
    ('assets/fonts/go-noto-kurrent-hangul.ttf', 'go-noto-kurrent-hangul.ttf', 1976696),
  ];

  /// Go Noto, plus on Android the chosen phone font. libass loads every file in the folder, so
  /// anything else is removed.
  static Future<String?> _fontsDir(String family) async {
    try {
      final dir = Directory(path.join((await getApplicationSupportDirectory()).path, 'subtitle_fonts'));
      await dir.create(recursive: true);
      final keep = <String, int?>{for (final (_, file, len) in _bundled) file: len};
      String? systemFile;
      if (!kIsWeb && Platform.isAndroid) {
        for (final f in androidFonts.where((f) => f.family == family)) {
          systemFile = f.systemFiles.where((file) => File('/system/fonts/$file').existsSync()).firstOrNull;
        }
        if (systemFile != null) keep[systemFile] = File('/system/fonts/$systemFile').lengthSync();
      }
      await for (final e in dir.list(followLinks: false)) {
        final name = path.basename(e.path);
        if (e is! File || !keep.containsKey(name) || await e.length() != keep[name]) await e.delete(recursive: true);
      }
      for (final (asset, file, _) in _bundled) {
        final f = File(path.join(dir.path, file));
        if (f.existsSync()) continue;
        final data = await rootBundle.load(asset);
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      if (systemFile != null) {
        final f = File(path.join(dir.path, systemFile));
        if (!f.existsSync()) await File('/system/fonts/$systemFile').copy(f.path);
      }
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  // ── to mpv ──

  /// Where the subtitles sit (`sub-pos`, % of the height) with the controls hidden.
  static double get basePosition {
    final lift = AppSettings.subtitleLift.value.clamp(0, 45).toDouble();
    return AppSettings.subtitleTop.value ? lift : 100 - lift;
  }

  static String _hex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static String _tenths(int v) => (v / 10).toStringAsFixed(1);

  /// Sends the whole style to the player. Each write stands alone: one mpv refuses never stops
  /// the rest, or playback.
  static Future<void> apply(pz.Player player) async {
    final fontsDir = await _fontsDir(family);
    final back = AppSettings.subtitleBackground.value.clamp(0, 100);
    final box = back > 0;
    final alpha = (back * 255 / 100).round();
    final props = <(String, String)>[
      if (fontsDir != null) ('sub-fonts-dir', fontsDir),
      ('sub-font', family),
      ('sub-visibility', 'yes'),
      // sized for a 1080-tall window like the old overlay; mpv sizes for a 720-tall one
      ('sub-font-size', (AppSettings.subtitleSize.value * 1.3 * 720 / 1080).toStringAsFixed(1)),
      ('sub-bold', AppSettings.subtitleBold.value ? 'yes' : 'no'),
      ('sub-italic', AppSettings.subtitleItalic.value ? 'yes' : 'no'),
      ('sub-color', _hex(AppSettings.subtitleColor.value)),
      ('sub-border-style', box ? 'background-box' : 'outline-and-shadow'),
      ('sub-back-color', _hex((AppSettings.subtitleBackColor.value & 0x00FFFFFF) | (alpha << 24))),
      ('sub-border-size', box ? '0' : _tenths(AppSettings.subtitleOutline.value)),
      ('sub-border-color', _hex(AppSettings.subtitleOutlineColor.value)),
      ('sub-shadow-offset', box ? '0' : _tenths(AppSettings.subtitleShadow.value)),
      ('sub-shadow-color', _hex(AppSettings.subtitleShadowColor.value)),
      ('sub-blur', _tenths(AppSettings.subtitleBlur.value)),
      ('sub-spacing', _tenths(AppSettings.subtitleSpacing.value)),
      ('sub-align-y', AppSettings.subtitleTop.value ? 'top' : 'bottom'),
      ('sub-pos', basePosition.round().toString()),
      ('sub-use-margins', AppSettings.subtitleOnPicture.value ? 'no' : 'yes'),
      ('sub-ass-override', AppSettings.subtitleAss.value),
    ];
    for (final (k, v) in props) {
      try {
        await player.setProperty(k, v);
      } catch (_) {}
    }
  }
}
