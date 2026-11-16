// VyseTV addition (not upstream Plezy).
//
// Plezy's player draws the video on a native surface *behind* the Flutter
// window, so the video only shows where Flutter leaves pixels transparent.
// Plezy only plays full screen on a transparent route, so that is enough
// there. VyseTV also shows video inside screens that paint their own
// background (watch-party tiles, the room page's theater mode, the shell), so
// this widget first clears ("punches") the pixels under the video, then lays
// Plezy's [Video] on top. Controls drawn above it still paint normally.
//
// On Linux X11 there is no native surface: mpv draws into a Flutter texture
// (linux/runner/mpv/vyse_texture_fallback.h), shown here instead of the hole.
//
// It also keeps the screen awake while the video plays, which media_kit's
// Video used to do on its own.
//
// Limits: a hole only clears what was painted in the same compositing pass, so
// an ancestor that renders through an offscreen layer (Opacity fades,
// BackdropFilter, ShaderMask) hides the video while that effect is active.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'player/platform/player_linux.dart';
import 'player/player.dart';
import 'video.dart';

class VyseVideo extends StatefulWidget {
  const VyseVideo({super.key, required this.player, this.backgroundColor = const Color(0xFF000000)});

  final Player player;

  /// Painted until the first video frame arrives.
  final Color backgroundColor;

  @override
  State<VyseVideo> createState() => _VyseVideoState();
}

class _VyseVideoState extends State<VyseVideo> {
  StreamSubscription<bool>? _playing;
  StreamSubscription<void>? _loaded;
  StreamSubscription<void>? _restart;
  StreamSubscription<void>? _started;

  /// Whether the current file has shown a frame. Plezy's [Video] paints its
  /// background (opaque) until it hears the next playback-restart; a Video
  /// mounted mid-playback (picture-in-picture, leaving it, a rebuilt page)
  /// would stay black until a seek. The player already knows: start from that.
  final _firstFrame = ValueNotifier(false);
  bool _awake = false;
  int? _textureId; // Linux X11 fallback

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(VyseVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _playing?.cancel();
      _loaded?.cancel();
      _restart?.cancel();
      _started?.cancel();
      _textureId = null;
      _listen();
    }
  }

  void _listen() {
    _setAwake(widget.player.state.playing);
    _playing = widget.player.streams.playing.listen(_setAwake);
    _firstFrame.value = widget.player.state.hasRenderedFrame;
    _restart = widget.player.streams.playbackRestart.listen((_) => _firstFrame.value = true);
    _started = widget.player.streams.fileStarted.listen((_) => _firstFrame.value = false);
    final player = widget.player;
    if (!kIsWeb && Platform.isLinux && player is PlayerLinux) {
      // the texture exists once the player has started; ask again with every file
      _loaded = player.streams.fileLoaded.listen((_) => _checkTexture(player));
      _checkTexture(player);
    }
  }

  Future<void> _checkTexture(PlayerLinux player) async {
    final id = await player.vyseTextureId();
    if (mounted && id != _textureId) setState(() => _textureId = id);
  }

  void _setAwake(bool on) {
    if (on == _awake) return;
    _awake = on;
    unawaited((on ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _playing?.cancel();
    _loaded?.cancel();
    _restart?.cancel();
    _started?.cancel();
    _firstFrame.dispose();
    _setAwake(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final texture = _textureId;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Own repaint boundary: a single small picture, never worth raster
        // caching, so the clear always reaches the window's pixels.
        if (texture == null) const RepaintBoundary(child: CustomPaint(painter: _VideoHolePainter(), child: SizedBox.expand())),
        // still there with a texture: it reports the size mpv renders at
        Video(player: widget.player, backgroundColor: widget.backgroundColor, hasFirstFrame: _firstFrame),
        if (texture != null) Positioned.fill(child: Texture(textureId: texture, filterQuality: FilterQuality.medium)),
      ],
    );
  }
}

class _VideoHolePainter extends CustomPainter {
  const _VideoHolePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);
  }

  @override
  bool shouldRepaint(_VideoHolePainter oldDelegate) => false;
}
