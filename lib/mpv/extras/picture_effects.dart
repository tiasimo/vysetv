// Lorewatch: picture effects for Plezy's mpv player — upscaling shaders and
// ambient lighting. Shader chains and the ambient-lighting shader generator are
// from Plezy (edde746/plezy, GPL-3.0: shader_asset_loader.dart,
// shader_service.dart, ambient_lighting_service.dart). The shader files in
// assets/shaders are MIT (Anime4K by bloc97; ArtCNN by Joao Chrisostomo and
// Kacper Michajłow; NVIDIA Image Scaling).

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../player/player.dart';

/// An upscaling preset: mpv GLSL shaders run in order on every frame.
class Upscaler {
  const Upscaler(this.id, this.label, this.detail, this.files);
  final String id;
  final String label;
  final String detail;
  final List<String> files; // under assets/shaders/

  bool get isOff => files.isEmpty;

  static const off = Upscaler('none', 'Off', "mpv's own scaling", []);

  static const all = [
    off,
    Upscaler('nvscaler', 'NVIDIA Image Scaling', 'Sharper upscale · light on the GPU', ['nvscaler/NVScaler.glsl']),
    Upscaler('artcnn', 'ArtCNN', 'Anime & art · neural upscale', ['artcnn/ArtCNN_C4F16.glsl']),
    Upscaler('artcnn_hq', 'ArtCNN · high quality', 'Anime & art · needs a strong GPU', ['artcnn/ArtCNN_C4F32.glsl']),
    Upscaler('anime4k', 'Anime4K', 'Anime · restores lines', ['anime4k/Anime4K_Clamp_Highlights.glsl', 'anime4k/Anime4K_Restore_CNN_M.glsl']),
    Upscaler('anime4k_hq', 'Anime4K · high quality', 'Anime · needs a strong GPU', [
      'anime4k/Anime4K_Clamp_Highlights.glsl',
      'anime4k/Anime4K_Restore_CNN_VL.glsl',
    ]),
  ];

  static Upscaler byId(String id) => all.firstWhere((u) => u.id == id, orElse: () => off);
}

/// Applies an [Upscaler] and ambient lighting to one player. Calls are queued, so a quick
/// series of changes always lands in order.
class PictureEffects {
  PictureEffects(this._player);
  final Player _player;

  Future<void> _queue = Future.value();
  String? _ambientPath;
  bool _ambientOn = false;

  /// Rebuilds mpv's shader chain: the upscaler's shaders, then ambient lighting last.
  /// [videoAspect] (width / height) is needed for ambient lighting; without it, it stays off.
  Future<void> apply({required Upscaler upscaler, required bool ambient, double? videoAspect}) {
    return _queue = _queue.then((_) => _apply(upscaler, ambient, videoAspect)).catchError((Object _) {});
  }

  Future<void> _apply(Upscaler upscaler, bool ambient, double? videoAspect) async {
    // NVIDIA Image Scaling is an SDR filter: on HDR it only crushes the picture, so skip it there.
    var chosen = upscaler;
    if (upscaler.id == 'nvscaler') {
      final peak = double.tryParse(await _safeGet('video-params/sig-peak') ?? '') ?? 1;
      if (peak > 1) chosen = Upscaler.off;
    }
    final files = <String>[for (final f in chosen.files) await _extract(f)];
    final wantAmbient = ambient && videoAspect != null && videoAspect > 0;

    // Leaving ambient: letterbox first, so dropping the shader is invisible.
    if (_ambientOn && !wantAmbient) {
      await _safeSet('keepaspect', 'yes');
      await _safeSet('sub-video-rect-aspect', 'no');
      _ambientOn = false;
    }
    await _safeCommand(['change-list', 'glsl-shaders', 'clr', '']);
    for (final f in files) {
      await _safeCommand(['change-list', 'glsl-shaders', 'append', f]);
    }
    if (wantAmbient) {
      // Subtitles stay on the picture, not in the glowing bars (a Plezy mpv patch).
      await _safeSet('sub-video-rect-aspect', videoAspect.toString());
      await _safeCommand(['change-list', 'glsl-shaders', 'append', _ambientPath ??= await _writeAmbientShader()]);
      await _safeSet('keepaspect', 'no');
      _ambientOn = true;
    }
  }

  Future<String?> _safeGet(String name) async {
    try {
      return await _player.getProperty(name);
    } catch (_) {
      return null;
    }
  }

  Future<void> _safeSet(String name, String value) async {
    try {
      await _player.setProperty(name, value);
    } catch (_) {}
  }

  Future<void> _safeCommand(List<String> args) async {
    try {
      await _player.command(args);
    } catch (_) {}
  }

  /// mpv reads shaders from disk: copies one bundled shader out once and returns its path.
  static Future<String> _extract(String asset) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(path.join(dir.path, 'shaders', asset));
    final data = await rootBundle.load('assets/shaders/$asset');
    if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    return file.path;
  }

  // ── ambient lighting (Plezy's generator) ──
  //
  // `keepaspect=no` makes mpv scale the frame to the whole window; the shader then draws the
  // sharp picture centred at its own aspect over a blurred, dimmed copy of its edges. It reads
  // mpv's input_size / target_size every frame, so resizes need no rewrite.

  static const _brightness = 0.3;

  static Future<String> _writeAmbientShader() async {
    final dir = await getTemporaryDirectory();
    final file = File(path.join(dir.path, 'shaders', 'ambient_lighting.glsl'));
    file.parent.createSync(recursive: true);
    await file.writeAsString(_ambientShader());
    return file.path;
  }

  static String _ambientShader() {
    final br = _brightness.toStringAsFixed(2);
    final b = StringBuffer()
      ..writeln('//!HOOK MAIN')
      ..writeln('//!BIND HOOKED')
      ..writeln('//!SAVE ORIGINAL')
      ..writeln('//!DESC Ambient Lighting Save')
      ..writeln('vec4 hook() {')
      ..writeln('    return HOOKED_tex(HOOKED_pos);')
      ..writeln('}')
      ..writeln()
      ..writeln('//!HOOK MAIN')
      ..writeln('//!BIND ORIGINAL')
      ..writeln('//!SAVE SMALL')
      ..writeln('//!WIDTH ORIGINAL.w 8 /')
      ..writeln('//!HEIGHT ORIGINAL.h 8 /')
      ..writeln('//!DESC Ambient Lighting Downscale')
      ..writeln('vec4 hook() {')
      ..writeln('    vec2 uv = ORIGINAL_pos * 0.6 + 0.2;')
      ..writeln('    return ORIGINAL_tex(uv);')
      ..writeln('}')
      ..writeln();
    for (final (input, output, offset, desc) in const [
      ('SMALL', 'BLUR8A', '2.0', 'Blur1'),
      ('BLUR8A', 'BLUR8B', '6.0', 'Blur2'),
      ('BLUR8B', 'BLUR8C', '12.0', 'Blur3'),
    ]) {
      _kawase(b, input, output, offset, desc);
    }
    b
      ..writeln('//!HOOK MAIN')
      ..writeln('//!BIND BLUR8C')
      ..writeln('//!SAVE TINY')
      ..writeln('//!WIDTH BLUR8C.w 8 /')
      ..writeln('//!HEIGHT BLUR8C.h 8 /')
      ..writeln('//!DESC Ambient Lighting Downscale2')
      ..writeln('vec4 hook() {')
      ..writeln('    return BLUR8C_tex(BLUR8C_pos);')
      ..writeln('}')
      ..writeln();
    for (final (input, output, offset, desc) in const [('TINY', 'GLOW1', '3.0', 'Blur4'), ('GLOW1', 'GLOW', '6.0', 'Blur5')]) {
      _kawase(b, input, output, offset, desc);
    }
    b
      ..writeln('//!HOOK MAIN')
      ..writeln('//!BIND ORIGINAL')
      ..writeln('//!BIND GLOW')
      ..writeln('//!DESC Ambient Lighting Composite')
      ..writeln('vec4 hook() {')
      ..writeln('    float vid_aspect = input_size.x / input_size.y;')
      ..writeln('    float out_aspect = target_size.x / target_size.y;')
      ..writeln('    vec2 scale, off;')
      ..writeln('    if (vid_aspect > out_aspect) {')
      ..writeln('        float s = out_aspect / vid_aspect;')
      ..writeln('        scale = vec2(1.0, s);')
      ..writeln('        off = vec2(0.0, (1.0 - s) * 0.5);')
      ..writeln('    } else {')
      ..writeln('        float s = vid_aspect / out_aspect;')
      ..writeln('        scale = vec2(s, 1.0);')
      ..writeln('        off = vec2((1.0 - s) * 0.5, 0.0);')
      ..writeln('    }')
      ..writeln('    vec2 vid_pos = (ORIGINAL_pos - off) / scale;')
      ..writeln('    if (all(greaterThanEqual(vid_pos, vec2(0.0))) &&')
      ..writeln('        all(lessThanEqual(vid_pos, vec2(1.0)))) {')
      ..writeln('        return ORIGINAL_tex(vid_pos);')
      ..writeln('    }')
      ..writeln('    return GLOW_tex(ORIGINAL_pos) * $br;')
      ..writeln('}');
    return b.toString();
  }

  static void _kawase(StringBuffer b, String input, String output, String offset, String desc) {
    b
      ..writeln('//!HOOK MAIN')
      ..writeln('//!BIND $input')
      ..writeln('//!SAVE $output')
      ..writeln('//!WIDTH $input.w')
      ..writeln('//!HEIGHT $input.h')
      ..writeln('//!DESC Ambient Lighting $desc')
      ..writeln('vec4 hook() {')
      ..writeln('    vec2 ps = ${input}_pt;')
      ..writeln('    vec4 s = ${input}_tex(${input}_pos + vec2( $offset,  $offset) * ps)')
      ..writeln('           + ${input}_tex(${input}_pos + vec2( $offset, -$offset) * ps)')
      ..writeln('           + ${input}_tex(${input}_pos + vec2(-$offset,  $offset) * ps)')
      ..writeln('           + ${input}_tex(${input}_pos + vec2(-$offset, -$offset) * ps);')
      ..writeln('    return s * 0.25;')
      ..writeln('}')
      ..writeln();
  }
}
