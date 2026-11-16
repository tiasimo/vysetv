import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/party/watch_party.dart' show PartySong;
import '../../widgets/common.dart';
import 'party_widgets.dart' show PartyAvatar;

/// The room's music: the song's own colours fill the space, the cover breathes while it plays, and
/// the lyrics move with it. Everyone's faces are here too, because this is a room, not a player.
/// There's no audio in this file; [PartyMusicRoom] connects it to the real thing.

const _speaking = Color(0xFF3DDC97);
const _ease = Cubic(.22, 1, .36, 1);

@immutable
class PartyLyric {
  const PartyLyric(this.at, this.text);
  final Duration at;
  final String text;
}

@immutable
class PartyListener {
  const PartyListener({required this.id, required this.name, this.avatarUrl = '', this.speaking = false});
  final String id;
  final String name;
  final String avatarUrl;
  final bool speaking;
}

class PartyMusicView extends StatefulWidget {
  const PartyMusicView({
    super.key,
    required this.song,
    required this.position,
    required this.duration,
    required this.playing,
    this.loading = false,
    this.host = '',
    this.listeners = const [],
    this.upNext = const [],
    this.lyrics = const [],
    this.canPlay = false,
    this.canSkip = false,
    this.listening = true,
    this.waitingFor = const [],
    this.full = false,
    this.volume = 100,
    this.onToggle,
    this.onSeek,
    this.onNext,
    this.onPrevious,
    this.onJoin,
    this.onExpand,
    this.onStop,
    this.onAdd,
    this.onVolume,
  });
  final PartySong song;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final bool playing;
  final bool loading;
  final String host; // their name; empty when it's you
  final List<PartyListener> listeners;
  final List<PartySong> upNext;
  final List<PartyLyric> lyrics;
  final bool canPlay; // may play, pause and seek for the room
  final bool canSkip; // hosts: the queue is theirs
  final bool listening; // false: stepped out, or hasn't joined yet
  final List<String> waitingFor;
  final bool full; // the whole window, rather than a card in the room
  final double volume;
  final VoidCallback? onToggle;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onJoin;
  final VoidCallback? onExpand; // card: go full; full: back to the room
  final VoidCallback? onStop;
  final VoidCallback? onAdd;
  final ValueChanged<double>? onVolume;

  @override
  State<PartyMusicView> createState() => _PartyMusicViewState();
}

enum _Side { art, lyrics, next }

class _PartyMusicViewState extends State<PartyMusicView> {
  Color _tone = VyseColors.accent;
  _Side _side = _Side.art;

  bool get _hasLyrics => widget.lyrics.isNotEmpty;

  @override
  void didUpdateWidget(PartyMusicView old) {
    super.didUpdateWidget(old);
    if (old.song.id != widget.song.id && _side == _Side.lyrics && !_hasLyrics) _side = _Side.art;
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Color?>(
    tween: ColorTween(end: _tone),
    duration: const Duration(milliseconds: 1100),
    curve: Curves.easeOut,
    builder: (context, c, _) {
      final tone = c ?? _tone;
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.full ? 0 : 22),
        child: Stack(
          fit: widget.full ? StackFit.expand : StackFit.loose,
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CoverLight(url: widget.song.cover, onTone: (t) => setState(() => _tone = t)),
              ),
            ),
            LayoutBuilder(builder: (context, box) => widget.full ? _full(box, tone) : _card(box, tone)),
            if (!widget.full)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0x1AFFFFFF)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  // ── the card in the room ──

  Widget _card(BoxConstraints box, Color tone) {
    final w = box.maxWidth;
    final screen = MediaQuery.sizeOf(context);
    if (w < 540 || screen.height < 460) return _small(tone);
    final h = (w * .4).clamp(236.0, math.min(380.0, screen.height * .54)).toDouble();
    final next = w >= 880 && widget.upNext.isNotEmpty;
    return SizedBox(
      height: h,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            _Cover(url: widget.song.cover, id: widget.song.id, size: h - 44, tone: tone, playing: widget.playing && widget.listening, radius: 16),
            const SizedBox(width: 26),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Label(host: widget.host, waitingFor: widget.waitingFor, tone: tone),
                  const SizedBox(height: 10),
                  _Title(song: widget.song, size: w >= 760 ? 31 : 26, lines: h >= 290 ? 2 : 1),
                  const Spacer(),
                  _Seek(position: widget.position, duration: widget.duration, tone: tone, onSeek: widget.canPlay && widget.listening ? widget.onSeek : null),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _transport(tone, key: 50),
                      const SizedBox(width: 14),
                      Expanded(child: _Faces(people: widget.listeners)),
                      if (widget.onAdd != null) _Plain(icon: Icons.playlist_add_rounded, tip: 'Add music', onTap: widget.onAdd),
                      if (widget.onStop != null) _Plain(icon: Icons.stop_rounded, tip: 'End the party', onTap: widget.onStop),
                      _Plain(icon: Icons.open_in_full_rounded, tip: 'Full screen', size: 19, onTap: widget.onExpand),
                    ],
                  ),
                ],
              ),
            ),
            if (next) ...[
              const SizedBox(width: 22),
              SizedBox(width: 216, child: _UpNext(songs: widget.upNext.take(4).toList())),
            ],
          ],
        ),
      ),
    );
  }

  /// A phone in the room, or a short window: one line, and a tap opens the whole thing.
  Widget _small(Color tone) => Pressable(
    onTap: widget.onExpand,
    builder: (context, _, _) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Cover(url: widget.song.cover, id: widget.song.id, size: 74, tone: tone, playing: widget.playing && widget.listening, radius: 11),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Label(host: widget.host, waitingFor: widget.waitingFor, tone: tone, small: true),
                    const SizedBox(height: 5),
                    _Title(song: widget.song, size: 17, lines: 1),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _transport(tone, key: 44, skips: false),
            ],
          ),
          const SizedBox(height: 8),
          _Seek(position: widget.position, duration: widget.duration, tone: tone, thin: true),
        ],
      ),
    ),
  );

  // ── the whole window ──

  Widget _full(BoxConstraints box, Color tone) {
    final w = box.maxWidth, h = box.maxHeight;
    final top = Layout.windowChrome(context);
    final safe = MediaQuery.paddingOf(context);
    final landscape = w > h * 1.12;
    final short = h < 480;
    final side = w < 640 ? 18.0 : 36.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(side + safe.left, top + (short ? 6 : 12), side + safe.right, (short ? 8 : 18) + safe.bottom),
      child: Column(
        children: [
          Row(
            children: [
              _Plain(icon: Icons.keyboard_arrow_down_rounded, tip: 'Back to the room', size: 28, onTap: widget.onExpand),
              Expanded(child: Center(child: _Label(host: widget.host, waitingFor: widget.waitingFor, tone: tone))),
              if (widget.onAdd != null) _Plain(icon: Icons.playlist_add_rounded, tip: 'Add music', onTap: widget.onAdd),
              if (widget.onStop != null) _Plain(icon: Icons.stop_rounded, tip: 'End the party', onTap: widget.onStop),
              if (widget.onAdd == null && widget.onStop == null) const SizedBox(width: 44),
            ],
          ),
          SizedBox(height: short ? 4 : 14),
          Expanded(child: landscape ? _wide(w - side * 2, h, tone, short) : _tall(w, tone)),
        ],
      ),
    );
  }

  Widget _wide(double w, double h, Color tone, bool short) {
    final three = w >= 1040 && (_hasLyrics || widget.upNext.isNotEmpty);
    return LayoutBuilder(
      builder: (context, c) {
        final art = math.min(c.maxHeight - (short ? 8 : 24), w * (three ? .3 : .38));
        final left = _side == _Side.art || three
            ? _Cover(url: widget.song.cover, id: widget.song.id, size: art, tone: tone, playing: widget.playing && widget.listening, radius: short ? 14 : 22)
            : SizedBox(width: art, child: _sidePanel(tone, short ? 21 : 26));
        final detail = Column(
          mainAxisSize: short ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Title(song: widget.song, size: short ? 24 : (w >= 1500 ? 48 : (three ? 40 : 44)), lines: 2),
            SizedBox(height: short ? 10 : 26),
            _Seek(position: widget.position, duration: widget.duration, tone: tone, onSeek: widget.canPlay && widget.listening ? widget.onSeek : null),
            SizedBox(height: short ? 6 : 16),
            _transport(tone, key: short ? 52 : 68, wide: true),
            SizedBox(height: short ? 8 : 24),
            Row(
              children: [
                Expanded(child: _Faces(people: widget.listeners, big: !short)),
                if (!three) ..._switches(),
              ],
            ),
            if (!short && widget.onVolume != null) ...[
              const SizedBox(height: 14),
              _Volume(value: widget.volume, tone: tone, onChanged: widget.onVolume!),
            ],
          ],
        );
        return Row(
          children: [
            left,
            SizedBox(width: short ? 22 : 44),
            Expanded(child: short ? Center(child: SingleChildScrollView(child: detail)) : detail),
            if (three) ...[
              const SizedBox(width: 44),
              Expanded(child: _hasLyrics ? _Lyrics(lines: widget.lyrics, position: widget.position, size: 28, onSeek: widget.canPlay ? widget.onSeek : null) : _UpNext(songs: widget.upNext, big: true)),
            ],
          ],
        );
      },
    );
  }

  Widget _tall(double w, Color tone) => Column(
    children: [
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: _ease,
          child: _side == _Side.art
              ? LayoutBuilder(
                  key: const ValueKey('art'),
                  builder: (context, c) => Center(
                    child: _Cover(
                      url: widget.song.cover,
                      id: widget.song.id,
                      size: math.max(120.0, math.min(c.maxWidth, c.maxHeight) - 8),
                      tone: tone,
                      playing: widget.playing && widget.listening,
                      radius: 20,
                    ),
                  ),
                )
              : KeyedSubtree(key: ValueKey(_side), child: _sidePanel(tone, 23)),
        ),
      ),
      const SizedBox(height: 18),
      Align(alignment: Alignment.centerLeft, child: _Title(song: widget.song, size: 25, lines: 2)),
      const SizedBox(height: 14),
      _Seek(position: widget.position, duration: widget.duration, tone: tone, onSeek: widget.canPlay && widget.listening ? widget.onSeek : null),
      const SizedBox(height: 6),
      _transport(tone, key: 64, wide: true),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(child: _Faces(people: widget.listeners)),
          ..._switches(),
        ],
      ),
    ],
  );

  Widget _sidePanel(Color tone, double size) => _side == _Side.lyrics
      ? _Lyrics(lines: widget.lyrics, position: widget.position, size: size, onSeek: widget.canPlay ? widget.onSeek : null)
      : _UpNext(songs: widget.upNext, big: true);

  List<Widget> _switches() => [
    if (_hasLyrics)
      _Plain(
        icon: Icons.lyrics_outlined,
        tip: 'Lyrics',
        on: _side == _Side.lyrics,
        onTap: () => setState(() => _side = _side == _Side.lyrics ? _Side.art : _Side.lyrics),
      ),
    if (widget.upNext.isNotEmpty)
      _Plain(
        icon: Icons.queue_music_rounded,
        tip: 'Up next',
        on: _side == _Side.next,
        onTap: () => setState(() => _side = _side == _Side.next ? _Side.art : _Side.next),
      ),
  ];

  Widget _transport(Color tone, {required double key, bool skips = true, bool wide = false}) {
    if (!widget.listening) {
      return _Join(tone: tone, height: math.min(key, 50), onTap: widget.onJoin);
    }
    final play = _PlayKey(size: key, playing: widget.playing, loading: widget.loading, tone: tone, onTap: widget.onToggle);
    final skip = skips && widget.canSkip;
    return Row(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: wide ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        if (skip) ...[_Plain(icon: Icons.skip_previous_rounded, tip: 'Previous', size: key * .56, onTap: widget.onPrevious), SizedBox(width: wide ? 22 : 6)],
        play,
        if (skip) ...[SizedBox(width: wide ? 22 : 6), _Plain(icon: Icons.skip_next_rounded, tip: 'Next', size: key * .56, onTap: widget.onNext)],
      ],
    );
  }
}

// ───────────────────────── The light ─────────────────────────

/// The cover, blurred once into a small image and stretched: a plain image to draw, nothing per
/// frame. Dark enough to read over, and with a little grain, because dark blurs show bands. It also
/// finds the song's colour, which everything else takes on.
class CoverLight extends StatefulWidget {
  const CoverLight({super.key, required this.url, this.onTone});
  final String url;
  final ValueChanged<Color>? onTone;

  @override
  State<CoverLight> createState() => _CoverLightState();
}

class _CoverLightState extends State<CoverLight> {
  static const _n = 160;
  static const _vivid = ColorFilter.matrix([
    1.34, -.26, -.08, 0, 0, //
    -.12, 1.2, -.08, 0, 0, //
    -.12, -.26, 1.38, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  ui.Image? _soft;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  String? _loaded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(CoverLight old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _listener = null;
  }

  void _load() {
    final url = widget.url;
    if (url.isEmpty || url == _loaded) return;
    _loaded = url;
    _stop();
    final stream = CachedNetworkImageProvider(url).resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      _soften(info.image.clone(), url);
      info.dispose();
      _stop();
    }, onError: (_, _) {});
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  Future<void> _soften(ui.Image src, String url) async {
    final sw = src.width.toDouble(), sh = src.height.toDouble();
    final side = math.min(sw, sh);
    final cut = Rect.fromCenter(center: Offset(sw / 2, sh / 2), width: side, height: side);
    final room = Rect.fromLTWH(0, 0, _n.toDouble(), _n.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // drawn past the edges so the blur doesn't darken them
    canvas.saveLayer(room.inflate(36), Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 13, sigmaY: 13, tileMode: TileMode.clamp));
    canvas.drawImageRect(src, cut, room.inflate(26), Paint()..colorFilter = _vivid..filterQuality = FilterQuality.medium);
    canvas.restore();
    final picture = recorder.endRecording();
    final out = await picture.toImage(_n, _n);
    picture.dispose();
    src.dispose();
    if (!mounted || url != widget.url) return;
    setState(() => _soft = out);
    final data = await out.toByteData();
    if (data != null && mounted) widget.onTone?.call(_toneOf(data));
  }

  /// The song's colour: its average, weighted to what's vivid. A grey cover gets a soft white.
  static Color _toneOf(ByteData d) {
    var r = 0.0, g = 0.0, b = 0.0, sum = 0.0;
    for (var i = 0; i + 3 < d.lengthInBytes; i += 4 * 5) {
      final pr = d.getUint8(i), pg = d.getUint8(i + 1), pb = d.getUint8(i + 2);
      final sat = (math.max(pr, math.max(pg, pb)) - math.min(pr, math.min(pg, pb))) / 255;
      final w = .01 + sat * sat * sat;
      r += pr * w;
      g += pg * w;
      b += pb * w;
      sum += w;
    }
    final hsl = HSLColor.fromColor(Color.fromARGB(255, (r / sum).round(), (g / sum).round(), (b / sum).round()));
    if (hsl.saturation < .14) return const Color(0xFFE6E7F0);
    return hsl.withSaturation(math.max(.62, math.min(1, hsl.saturation * 1.2))).withLightness(hsl.lightness.clamp(.6, .72)).toColor();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Color(0xFF08090E)),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 1100),
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
        child: _soft == null
            ? const SizedBox.expand(key: ValueKey('none'))
            : RawImage(key: ValueKey(_soft), image: _soft, fit: BoxFit.cover, filterQuality: FilterQuality.high),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x4D08090E), Color(0x8008090E), Color(0xC708090E)],
            stops: [0, .5, 1],
          ),
        ),
      ),
      const CustomPaint(painter: _Grain()),
    ],
  );
}

final Future<ui.Image> _grainTile = () {
  const n = 128;
  final rng = math.Random(7);
  final px = Uint8List(n * n * 4);
  for (var i = 0; i < px.length; i += 4) {
    // premultiplied: a speck of white, or of black
    final a = rng.nextInt(9);
    px[i] = px[i + 1] = px[i + 2] = rng.nextBool() ? a : 0;
    px[i + 3] = a;
  }
  return ui.ImmutableBuffer.fromUint8List(px).then((buffer) async {
    final descriptor = ui.ImageDescriptor.raw(buffer, width: n, height: n, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  });
}();

ui.Image? _grainReady;

class _Grain extends CustomPainter {
  const _Grain();

  @override
  void paint(Canvas canvas, Size size) {
    final tile = _grainReady;
    if (tile == null) {
      _grainTile.then((t) => _grainReady = t);
      return;
    }
    canvas.drawRect(Offset.zero & size, Paint()..shader = ui.ImageShader(tile, TileMode.repeated, TileMode.repeated, Matrix4.identity().storage));
  }

  @override
  bool shouldRepaint(_Grain old) => false;
}

// ───────────────────────── The parts ─────────────────────────

/// The cover: it breathes while the music plays, settles when it stops, and throws its colour.
class _Cover extends StatefulWidget {
  const _Cover({required this.url, required this.id, required this.size, required this.tone, required this.playing, required this.radius});
  final String url;
  final String id;
  final double size;
  final Color tone;
  final bool playing;
  final double radius;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 3400));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Cover old) {
    super.didUpdateWidget(old);
    if (old.playing == widget.playing) return;
    widget.playing ? _breath.repeat(reverse: true) : _breath.stop();
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return AnimatedScale(
      scale: widget.playing ? 1 : .955,
      duration: const Duration(milliseconds: 620),
      curve: _ease,
      child: AnimatedBuilder(
        animation: _breath,
        builder: (context, child) => Transform.scale(scale: 1 + .012 * Curves.easeInOutSine.transform(_breath.value), child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 620),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            borderRadius: r,
            color: const Color(0xFF14151D),
            boxShadow: [
              BoxShadow(color: widget.tone.withValues(alpha: widget.playing ? .42 : .2), blurRadius: widget.size * .3, spreadRadius: widget.size * .01),
              const BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 16)),
            ],
          ),
          child: ClipRRect(
            borderRadius: r,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 620),
              switchInCurve: _ease,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(a), child: child),
              ),
              child: widget.url.isEmpty
                  ? const Center(key: ValueKey('none'), child: Icon(Icons.music_note_rounded, size: 40, color: Color(0x66FFFFFF)))
                  : CachedNetworkImage(
                      key: ValueKey(widget.id),
                      imageUrl: widget.url,
                      width: widget.size,
                      height: widget.size,
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 240),
                      errorWidget: (_, _, _) => const Center(child: Icon(Icons.music_note_rounded, size: 40, color: Color(0x66FFFFFF))),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.host, required this.waitingFor, required this.tone, this.small = false});
  final String host;
  final List<String> waitingFor;
  final Color tone;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final n = waitingFor.length;
    final text = n > 0
        ? 'Waiting for ${n == 1 ? waitingFor.first : '${waitingFor.first} and ${n - 1} more'}…'
        : (host.isEmpty ? 'Listening together' : 'Listening with $host');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: tone,
            boxShadow: [BoxShadow(color: tone.withValues(alpha: .7), blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: small ? 11.5 : 12.5, fontWeight: FontWeight.w700, letterSpacing: .1, color: const Color(0xD9FFFFFF)),
          ),
        ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.song, required this.size, required this.lines});
  final PartySong song;
  final double size;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final by = [song.artist, if (song.album.isNotEmpty && size >= 24) song.album].where((x) => x.isNotEmpty).join('  ·  ');
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 460),
      switchInCurve: _ease,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, .12), end: Offset.zero).animate(a), child: child),
      ),
      child: Column(
        key: ValueKey(song.id),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            song.title,
            maxLines: lines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: size, height: 1.12, fontWeight: FontWeight.w800, letterSpacing: -size * .025, color: Colors.white),
          ),
          SizedBox(height: size * .16),
          Text(
            by,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: math.max(13, size * .46), height: 1.25, fontWeight: FontWeight.w500, color: const Color(0xB3FFFFFF)),
          ),
        ],
      ),
    );
  }
}

class _Seek extends StatefulWidget {
  const _Seek({required this.position, required this.duration, required this.tone, this.onSeek, this.thin = false});
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final Color tone;
  final ValueChanged<Duration>? onSeek; // null: it only shows where the room is
  final bool thin;

  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _drag;

  static String _clock(Duration d) {
    final s = math.max(0, d.inSeconds);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _to(double f) {
    final total = widget.duration.value;
    if (total > Duration.zero) widget.onSeek?.call(total * f);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, c) {
          final w = math.max(1.0, c.maxWidth);
          double at(double dx) => (dx / w).clamp(0.0, 1.0);
          final bar = CustomPaint(
            size: Size(w, widget.thin ? 6 : 20),
            painter: _Line(widget.position, widget.duration, widget.tone, _drag, widget.thin ? 3 : (_drag != null ? 7 : 5), knob: widget.onSeek != null && !widget.thin),
          );
          if (widget.onSeek == null) return bar;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (e) => _to(at(e.localPosition.dx)),
              onHorizontalDragStart: (e) => setState(() => _drag = at(e.localPosition.dx)),
              onHorizontalDragUpdate: (e) => setState(() => _drag = at(e.localPosition.dx)),
              onHorizontalDragEnd: (_) {
                final f = _drag;
                setState(() => _drag = null);
                if (f != null) _to(f);
              },
              onHorizontalDragCancel: () => setState(() => _drag = null),
              child: bar,
            ),
          );
        },
      ),
      if (!widget.thin)
        AnimatedBuilder(
          animation: Listenable.merge([widget.position, widget.duration]),
          builder: (context, _) {
            final total = widget.duration.value;
            final now = _drag != null ? total * _drag! : widget.position.value;
            const style = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0x99FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);
            return Row(
              children: [
                Text(_clock(now), style: style),
                const Spacer(),
                Text(_clock(total), style: style),
              ],
            );
          },
        ),
    ],
  );
}

class _Line extends CustomPainter {
  _Line(this.position, this.duration, this.tone, this.drag, this.height, {this.knob = false}) : super(repaint: Listenable.merge([position, duration]));
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final Color tone;
  final double? drag;
  final double height;
  final bool knob;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration.value.inMilliseconds;
    final f = drag ?? (total <= 0 ? 0.0 : (position.value.inMilliseconds / total).clamp(0.0, 1.0));
    final y = size.height / 2, x = f * size.width, r = Radius.circular(height / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, y - height / 2, size.width, y + height / 2, r), Paint()..color = const Color(0x2EFFFFFF));
    if (x <= 0) return;
    final played = RRect.fromLTRBR(0, y - height / 2, x, y + height / 2, r);
    canvas.drawRRect(played, Paint()..color = tone.withValues(alpha: .5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    canvas.drawRRect(played, Paint()..color = Color.lerp(tone, Colors.white, .28)!);
    if (knob) canvas.drawCircle(Offset(x, y), height + 1.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_Line old) => old.tone != tone || old.drag != drag || old.height != height;
}

/// Play / pause: white, with the song's colour in the icon, and a ring while it loads.
class _PlayKey extends StatelessWidget {
  const _PlayKey({required this.size, required this.playing, required this.loading, required this.tone, this.onTap});
  final double size;
  final bool playing;
  final bool loading;
  final Color tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ink = HSLColor.fromColor(tone).withLightness(.14).withSaturation(.5).toColor();
    return Pressable(
      tooltip: 'Play / pause',
      onTap: onTap,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .92 : (hovered ? 1.05 : 1),
        duration: const Duration(milliseconds: 160),
        curve: _ease,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [BoxShadow(color: tone.withValues(alpha: .4), blurRadius: size * .55)],
          ),
          child: loading
              ? SizedBox.square(dimension: size * .4, child: CircularProgressIndicator(strokeWidth: 2.4, color: ink))
              : TweenAnimationBuilder<double>(
                  tween: Tween(end: playing ? 1 : 0),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => AnimatedIcon(icon: AnimatedIcons.play_pause, progress: AlwaysStoppedAnimation(v), size: size * .54, color: ink),
                ),
        ),
      ),
    );
  }
}

class _Join extends StatelessWidget {
  const _Join({required this.tone, required this.height, this.onTap});
  final Color tone;
  final double height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .96 : (hovered ? 1.03 : 1),
      duration: const Duration(milliseconds: 160),
      curve: _ease,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          color: Colors.white,
          boxShadow: [BoxShadow(color: tone.withValues(alpha: .4), blurRadius: 24)],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones_rounded, size: 19, color: Color(0xFF0A0B10)),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                'Listen along',
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -.1, color: Color(0xFF0A0B10)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Plain extends StatelessWidget {
  const _Plain({required this.icon, required this.tip, this.onTap, this.size = 22, this.on = false});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final double size;
  final bool on;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: math.max(40, size + 18),
        height: math.max(40, size + 18),
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: on ? .2 : (hovered ? .12 : 0))),
        child: Icon(icon, size: size, color: on || hovered ? Colors.white : const Color(0xD9FFFFFF)),
      ),
    ),
  );
}

/// Who's here: faces overlapping, a green ring on whoever's talking.
class _Faces extends StatelessWidget {
  const _Faces({required this.people, this.big = false});
  final List<PartyListener> people;
  final bool big;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final size = big ? 32.0 : 27.0;
    final step = size * .72;
    final text = people.length == 1 ? people.first.name : '${people.first.name} and ${people.length - 1} more';
    final faces = step * (people.length - 1) + size + 4;
    return LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          SizedBox(
            width: math.min(faces, c.maxWidth),
            height: size + 4,
            child: ClipRect(
              child: Stack(
                children: [
                  for (var i = 0; i < people.length; i++)
                    Positioned(
                      left: i * step,
                      child: Tooltip(
                        message: people[i].name,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: people[i].speaking ? _speaking : const Color(0xFF14151D),
                          ),
                          child: PartyAvatar(url: people[i].avatarUrl, name: people[i].name, size: size),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (c.maxWidth - faces >= 96) ...[
            const SizedBox(width: 9),
            Flexible(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xB3FFFFFF))),
            ),
          ],
        ],
      ),
    );
  }
}

class _UpNext extends StatelessWidget {
  const _UpNext({required this.songs, this.big = false});
  final List<PartySong> songs;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final art = big ? 52.0 : 40.0;
    final rows = [
      for (final s in songs)
        Padding(
          padding: EdgeInsets.only(bottom: big ? 12 : 9),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: s.cover.isEmpty
                    ? SizedBox.square(dimension: art, child: const ColoredBox(color: Color(0x1FFFFFFF)))
                    : CachedNetworkImage(imageUrl: s.cover, width: art, height: art, fit: BoxFit.cover, memCacheWidth: 140, fadeInDuration: const Duration(milliseconds: 200)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: big ? 14.5 : 13, fontWeight: FontWeight.w700, letterSpacing: -.1, color: Colors.white)),
                    const SizedBox(height: 1),
                    Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: big ? 12.5 : 11.5, color: const Color(0x99FFFFFF))),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
    final head = Padding(
      padding: EdgeInsets.only(bottom: big ? 14 : 10),
      child: const Text('Up next', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0x99FFFFFF))),
    );
    if (big) return ListView(padding: EdgeInsets.zero, children: [head, ...rows]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [head, ...rows]);
  }
}

/// The words as they're sung: the line being sung bright and large, the rest waiting in the dark.
class _Lyrics extends StatefulWidget {
  const _Lyrics({required this.lines, required this.position, required this.size, this.onSeek});
  final List<PartyLyric> lines;
  final ValueListenable<Duration> position;
  final double size;
  final ValueChanged<Duration>? onSeek;

  @override
  State<_Lyrics> createState() => _LyricsState();
}

class _LyricsState extends State<_Lyrics> {
  late List<GlobalKey> _keys = _make();
  int _now = -1;

  List<GlobalKey> _make() => List.generate(widget.lines.length, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_follow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  @override
  void didUpdateWidget(_Lyrics old) {
    super.didUpdateWidget(old);
    if (!identical(old.lines, widget.lines)) {
      _keys = _make();
      _now = -1;
    }
    if (old.position != widget.position) {
      old.position.removeListener(_follow);
      widget.position.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (!mounted) return;
    final at = widget.position.value + const Duration(milliseconds: 200);
    var i = -1;
    for (var j = 0; j < widget.lines.length; j++) {
      if (widget.lines[j].at > at) break;
      i = j;
    }
    if (i == _now) return;
    setState(() => _now = i);
    final c = i >= 0 ? _keys[i].currentContext : null;
    if (c != null) Scrollable.ensureVisible(c, alignment: .38, duration: const Duration(milliseconds: 560), curve: _ease);
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00FFFFFF), Colors.white, Colors.white, Color(0x00FFFFFF)],
        stops: [0, .16, .78, 1],
      ).createShader(r),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.lines.length; i++)
              Pressable(
                key: _keys[i],
                onTap: widget.onSeek == null ? null : () => widget.onSeek!(widget.lines[i].at),
                builder: (context, hovered, _) => Padding(
                  padding: EdgeInsets.symmetric(vertical: widget.size * .3),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 340),
                    curve: _ease,
                    style: base.merge(
                      TextStyle(
                        fontSize: widget.size,
                        height: 1.24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -widget.size * .018,
                        color: i == _now ? Colors.white : Colors.white.withValues(alpha: hovered ? .62 : (i < _now ? .26 : .36)),
                      ),
                    ),
                    child: Text(widget.lines[i].text.isEmpty ? '♪' : widget.lines[i].text),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.value, required this.tone, required this.onChanged});
  final double value;
  final Color tone;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(value == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 18, color: const Color(0xB3FFFFFF)),
      const SizedBox(width: 8),
      SizedBox(
        width: 150,
        height: 24,
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            activeTrackColor: Colors.white,
            inactiveTrackColor: const Color(0x2EFFFFFF),
            thumbColor: Colors.white,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
          ),
          child: Slider(value: value.clamp(0, 100), max: 100, onChanged: onChanged),
        ),
      ),
    ],
  );
}
