// Lorewatch: refresh-rate matching for Plezy's mpv player, so 23.976 fps film plays on a
// 23.976/24 Hz-family mode instead of juddering on 60 Hz. The mode choice
// (findBestRefreshRate) and the Android decoder refresh follow Plezy
// (edde746/plezy, GPL-3.0: display_mode_service.dart, display_matching.dart).
//
// Windows switches the monitor with ChangeDisplaySettingsExW (Plezy's
// display_mode_manager.cpp, standard Windows calls, no DDC/CI) and restores it
// afterwards; Android asks the system for a matching display mode.
// Off by default (AppSettings.matchRefreshRate).

import 'dart:io';

import 'package:flutter/services.dart';

import '../player/player.dart';

class DisplayMatch {
  DisplayMatch(this._player);
  final Player _player;

  static const _channel = MethodChannel('com.plezy/mpv_player');

  bool _windowsChanged = false;
  bool _androidChanged = false;

  /// Matches the display to [fps]. On Windows only call this while full screen.
  /// Returns whether the display changed.
  Future<bool> match({required double fps, required Duration duration, int width = 0, int height = 0}) async {
    if (fps <= 0) return false;
    try {
      if (Platform.isWindows) return await _matchWindows(fps);
      if (Platform.isAndroid) return await _matchAndroid(fps, duration, width, height);
    } catch (_) {}
    return false;
  }

  /// Puts the display back the way it was.
  Future<void> restore() async {
    try {
      if (_windowsChanged) {
        final ok = await _channel.invokeMethod<bool>('restoreDisplayMode');
        if (ok == true) _windowsChanged = false;
      }
      if (_androidChanged) {
        await _player.clearVideoFrameRate();
        _androidChanged = false;
      }
    } catch (_) {}
  }

  Future<bool> _matchWindows(double fps) async {
    final current = await _channel.invokeMapMethod<String, dynamic>('getCurrentDisplayMode');
    if (current == null) return false;
    final w = current['width'] as int, h = current['height'] as int;
    final currentRate = current['refreshRate'] as num;
    final modes = await _channel.invokeListMethod<Map>('getDisplayModes');
    if (modes == null || modes.isEmpty) return false;
    final best = findBestRefreshRate(fps, modes, w, h);
    if (best == 0 || best == currentRate) return false;
    final ok = await _channel.invokeMethod<bool>('setDisplayMode', {'width': w, 'height': h, 'refreshRate': best});
    if (ok == true) _windowsChanged = true;
    return ok == true;
  }

  Future<bool> _matchAndroid(double fps, Duration duration, int width, int height) async {
    final wasPlaying = _player.state.playing;
    await _player.pause();
    try {
      final switched = await _player.setVideoFrameRate(fps, duration.inMilliseconds, videoWidth: width, videoHeight: height);
      if (switched) {
        _androidChanged = true;
        // mpv's hardware decoder has to be re-primed after the display switched under it.
        if (_player.needsDecoderRefreshAfterDisplaySwitch) await _player.seek(_player.state.position);
      }
      return switched;
    } finally {
      if (wasPlaying) await _player.play();
    }
  }

  /// Windows reports whole hertz, with the 1000/1001 rates one below nominal (23 for 23.976).
  static double _effectiveRate(num rate) {
    if (rate is double) return rate;
    final nominal = rate + 1;
    if (nominal % 24 == 0 || nominal % 30 == 0) return nominal * 1000 / 1001;
    return rate.toDouble();
  }

  /// The lowest whole multiple of [fps] within 0.5% at the current resolution (Plezy's rule),
  /// as the platform reported it; 0 when none fits.
  static num findBestRefreshRate(double fps, List<Map> modes, int width, int height) {
    if (fps <= 0) return 0;
    final rates = <num>{
      for (final m in modes)
        if (m['width'] == width && m['height'] == height) m['refreshRate'] as num,
    };
    num best = 0;
    var bestMultiplier = 0;
    var bestDeviation = 0.0;
    for (final rate in rates) {
      final ratio = _effectiveRate(rate) / fps;
      final rounded = ratio.roundToDouble();
      if (rounded < 1) continue;
      final multiplier = rounded.toInt();
      final deviation = (ratio - rounded).abs() / rounded;
      if (deviation > .005) continue;
      if (best == 0 ||
          multiplier < bestMultiplier ||
          (multiplier == bestMultiplier && (deviation < bestDeviation || (deviation == bestDeviation && rate > best)))) {
        best = rate;
        bestMultiplier = multiplier;
        bestDeviation = deviation;
      }
    }
    return best;
  }
}
