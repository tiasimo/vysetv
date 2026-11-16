import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/addons.dart' show Addon;
import '../data/badges.dart' show SourceBadge;
import '../data/intro_db.dart' show Segment;
import '../widgets/common.dart';
import 'sources_page.dart' show AddonLogo, BadgeRow;

/// The player's controls, apart from the player itself: what's playing (bottom left), the seek
/// rail with its caption, and the dock (volume, transport, tools).

/// A chapter in the video file.
@immutable
class PlayerChapter {
  const PlayerChapter(this.start, this.title);
  final Duration start;
  final String title;
}

String formatTime(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

PlayerChapter? _chapterAt(List<PlayerChapter> chapters, Duration at) {
  PlayerChapter? now;
  for (final c in chapters) {
    if (c.start > at) break;
    now = c;
  }
  return now;
}

/// What's playing: the title's logo (or its name), the episode, and the source with its badges.
class NowPlaying extends StatelessWidget {
  const NowPlaying({
    super.key,
    required this.title,
    required this.logo,
    required this.source,
    required this.onSource,
    this.episode,
    this.addon,
    this.badges = const [],
    this.phone = false,
  });
  final String title;
  final Future<String?> logo;
  final String? episode; // "S2:E13  Dark Clouds"
  final String source; // "1080p · Torrentio"
  final Addon? addon;
  final List<SourceBadge> badges;
  final VoidCallback onSource;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final name = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: phone ? 21 : 30, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -.6),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<String?>(
          future: logo,
          builder: (context, snap) => snap.data == null
              ? name
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: phone ? 40 : 62, maxWidth: phone ? 190 : 300),
                  child: Image(
                    image: CachedNetworkImageProvider(snap.data!),
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomLeft,
                    errorBuilder: (_, _, _) => name,
                  ),
                ),
        ),
        if (episode != null) ...[
          const SizedBox(height: 7),
          Text(
            episode!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: phone ? 13 : 14.5, fontWeight: FontWeight.w600, color: const Color(0xE6FFFFFF)),
          ),
        ],
        SizedBox(height: phone ? 6 : 8),
        Pressable(
          tooltip: 'Change source',
          onTap: onSource,
          builder: (context, hovered, _) => Wrap(
            spacing: 9,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (addon != null) ...[AddonLogo(addon: addon!, size: 18), const SizedBox(width: 7)],
                  Text(
                    source,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: hovered ? Colors.white : const Color(0xB3FFFFFF)),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 16, color: hovered ? Colors.white : const Color(0x80FFFFFF)),
                ],
              ),
              if (badges.isNotEmpty) BadgeRow(badges: badges, height: 14),
            ],
          ),
        ),
      ],
    );
  }
}

/// The line over the rail: the chapter on the left; the time, and when it'll end, on the right.
class RailCaption extends StatelessWidget {
  const RailCaption({super.key, required this.position, required this.duration, this.chapters = const [], this.rate = 1});
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final List<PlayerChapter> chapters;
  final double rate;

  static const _time = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]);
  static const _dim = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0x99FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([position, duration]),
    builder: (context, _) {
      final p = position.value, d = duration.value;
      final chapter = _chapterAt(chapters, p);
      final left = d - p;
      final ends = d > Duration.zero ? DateTime.now().add(left * (1 / (rate <= 0 ? 1 : rate))) : null;
      return Row(
        children: [
          Expanded(
            child: Text(
              chapter?.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xCCFFFFFF)),
            ),
          ),
          const SizedBox(width: 12),
          Text(formatTime(p), style: _time),
          Text('  /  ${formatTime(d)}', style: _dim),
          if (ends != null) Text('   ·   ends ${TimeOfDay.fromDateTime(ends).format(context)}', style: _dim),
        ],
      );
    },
  );
}

/// The seek rail: one bar, split only at the video's own chapters and skippable parts, with
/// what's buffered ahead shaded in. It thickens under the pointer and shows the time and chapter.
class PlayerRail extends StatefulWidget {
  const PlayerRail({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    this.chapters = const [],
    this.marks = const [],
  });
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueListenable<Duration> buffered;
  final ValueChanged<Duration> onSeek;
  final List<PlayerChapter> chapters;
  final List<Segment> marks; // intro, recap, credits

  @override
  State<PlayerRail> createState() => _PlayerRailState();
}

class _PlayerRailState extends State<PlayerRail> with SingleTickerProviderStateMixin {
  late final _grow = AnimationController(vsync: this, duration: const Duration(milliseconds: 140));
  double? _hover; // 0..1 under the pointer
  double? _drag; // 0..1 while held

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  void _set({double? hover, double? drag, bool clearHover = false, bool clearDrag = false}) {
    setState(() {
      if (hover != null || clearHover) _hover = hover;
      if (drag != null || clearDrag) _drag = drag;
    });
    (_hover != null || _drag != null) ? _grow.forward() : _grow.reverse();
  }

  void _seekTo(double f) {
    final total = widget.duration.value;
    if (total > Duration.zero) widget.onSeek(total * f);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth;
      double at(double dx) => (dx / w).clamp(0.0, 1.0);
      final shown = _drag ?? _hover;
      final total = widget.duration.value;
      final time = shown == null ? null : total * shown;
      final chapter = time == null ? null : _chapterAt(widget.chapters, time);
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (e) => _set(hover: at(e.localPosition.dx)),
        onExit: (_) => _set(clearHover: true),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => _seekTo(at(e.localPosition.dx)),
          onHorizontalDragStart: (e) => _set(drag: at(e.localPosition.dx)),
          onHorizontalDragUpdate: (e) => _set(drag: at(e.localPosition.dx)),
          onHorizontalDragEnd: (_) {
            final f = _drag;
            _set(clearDrag: true);
            if (f != null) _seekTo(f);
          },
          onHorizontalDragCancel: () => _set(clearDrag: true),
          child: SizedBox(
            height: 22,
            width: w,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _RailPainter(
                        position: widget.position,
                        duration: widget.duration,
                        buffered: widget.buffered,
                        grow: _grow,
                        chapters: widget.chapters,
                        marks: widget.marks,
                        drag: _drag,
                      ),
                    ),
                  ),
                ),
                if (time != null && total > Duration.zero)
                  Positioned(
                    bottom: 26,
                    left: (shown! * w - 80).clamp(0.0, math.max(0.0, w - 160)),
                    width: 160,
                    child: IgnorePointer(
                      child: Center(
                        child: _RailBubble(time: time, chapter: chapter?.title),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _RailBubble extends StatelessWidget {
  const _RailBubble({required this.time, this.chapter});
  final Duration time;
  final String? chapter;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xF20E1020),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: VyseColors.stroke),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatTime(time),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
        ),
        if (chapter != null && chapter!.isNotEmpty)
          Text(
            chapter!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: VyseColors.textDim),
          ),
      ],
    ),
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.grow,
    required this.chapters,
    required this.marks,
    required this.drag,
  }) : super(repaint: Listenable.merge([position, duration, buffered, grow]));
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueListenable<Duration> buffered;
  final Animation<double> grow;
  final List<PlayerChapter> chapters;
  final List<Segment> marks;
  final double? drag;

  static const _gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration.value.inMilliseconds;
    final w = size.width;
    final t = grow.value;
    final h = 4 + 3 * t;
    final y = size.height / 2;
    double x(Duration d) => total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0) * w;

    // the rail is one bar, cut only at what's really in the video: its own chapters, and where
    // a skippable part starts and ends
    final points = <double>{
      if (chapters.length <= 60)
        for (final c in chapters) x(c.start),
      for (final m in marks) ...[x(m.start), if (m.end != null) x(m.end!)],
    }.where((v) => v > 0 && v < w).toList()..sort();
    final cuts = <double>[];
    for (final v in points) {
      if (cuts.isEmpty || v - cuts.last >= 4) cuts.add(v); // two that land together make one cut
    }
    final path = Path();
    var from = 0.0;
    for (final cut in [...cuts, w]) {
      final to = cut == w ? w : cut - _gap / 2;
      if (to > from) path.addRRect(RRect.fromLTRBR(from, y - h / 2, to, y + h / 2, Radius.circular(h / 2)));
      from = cut + _gap / 2;
    }
    final played = drag != null ? drag! * w : x(position.value);
    canvas.save();
    canvas.clipPath(path);
    final top = y - h / 2, bottom = y + h / 2;
    canvas.drawRect(Rect.fromLTRB(0, top, w, bottom), Paint()..color = const Color(0x38FFFFFF));
    canvas.drawRect(Rect.fromLTRB(0, top, x(buffered.value), bottom), Paint()..color = const Color(0x59FFFFFF));
    for (final m in marks) {
      canvas.drawRect(Rect.fromLTRB(x(m.start), top, m.end == null ? w : x(m.end!), bottom), Paint()..color = const Color(0x8CFFE3B8));
    }
    canvas.drawRect(
      Rect.fromLTRB(0, top, played, bottom),
      Paint()
        ..shader = const LinearGradient(colors: [VyseColors.accentHot, VyseColors.accent]).createShader(Rect.fromLTRB(0, top, math.max(1, played), bottom)),
    );
    canvas.restore();
    if (t > 0) {
      canvas.drawCircle(Offset(played, y), 8.5 * t, Paint()..color = VyseColors.accent.withValues(alpha: .28));
      canvas.drawCircle(Offset(played, y), 5.5 * t, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) => true;
}

/// Volume on the left, the transport on the true centre, the tools in a capsule on the right.
class PlayerDock extends StatelessWidget {
  const PlayerDock({
    super.key,
    required this.paused,
    required this.seekSeconds,
    required this.volume,
    required this.subtitlesOn,
    required this.onPause,
    required this.onBack,
    required this.onForward,
    required this.onVolume,
    required this.onSubtitles,
    required this.onAudio,
    required this.onSpeed,
    required this.onSources,
    required this.onSettings,
    this.onEpisodes,
    this.onNext,
    this.onFullscreen,
    this.fullscreen = false,
  });
  final bool paused;
  final int seekSeconds;
  final double volume;
  final bool subtitlesOn;
  final bool fullscreen;
  final VoidCallback onPause;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final ValueChanged<double> onVolume;
  final VoidCallback onSubtitles;
  final VoidCallback onAudio;
  final VoidCallback onSpeed;
  final VoidCallback onSources;
  final VoidCallback onSettings;
  final VoidCallback? onEpisodes;
  final VoidCallback? onNext;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    final (back, fwd) = switch (seekSeconds) {
      5 => (Icons.replay_5_rounded, Icons.forward_5_rounded),
      10 => (Icons.replay_10_rounded, Icons.forward_10_rounded),
      30 => (Icons.replay_30_rounded, Icons.forward_30_rounded),
      _ => (Icons.fast_rewind_rounded, Icons.fast_forward_rounded), // no numbered icon for 15
    };
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 860; // everything
        final mid = c.maxWidth >= 620; // the slider and the shortcuts go first
        return SizedBox(
          height: 60,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                children: [
                  _Volume(volume: volume, onVolume: onVolume, slider: mid),
                  const Spacer(),
                  _Capsule(
                    children: [
                      if (onNext != null) _Tool(icon: Icons.skip_next_rounded, tooltip: 'Next episode (N)', onTap: onNext!),
                      if (onEpisodes != null) _Tool(icon: Icons.video_library_outlined, tooltip: 'Episodes (E)', onTap: onEpisodes!),
                      _Tool(
                        icon: subtitlesOn ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined,
                        tooltip: 'Subtitles (C)',
                        on: subtitlesOn,
                        onTap: onSubtitles,
                      ),
                      if (wide) ...[
                        _Tool(icon: Icons.graphic_eq_rounded, tooltip: 'Audio', onTap: onAudio),
                        _Tool(icon: Icons.speed_rounded, tooltip: 'Speed', onTap: onSpeed),
                        _Tool(icon: Icons.stream_rounded, tooltip: 'Sources', onTap: onSources),
                      ],
                      _Tool(icon: Icons.tune_rounded, tooltip: 'Settings (S)', onTap: onSettings),
                      if (onFullscreen != null)
                        _Tool(icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, tooltip: 'Full screen (F)', onTap: onFullscreen!),
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mid) _Skip(icon: back, tooltip: 'Back ${seekSeconds}s', onTap: onBack),
                  const SizedBox(width: 10),
                  PlayKey(paused: paused, onTap: onPause),
                  const SizedBox(width: 10),
                  if (mid) _Skip(icon: fwd, tooltip: 'Forward ${seekSeconds}s', onTap: onForward),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A row of tools for phones, spread across the width.
class PhoneTools extends StatelessWidget {
  const PhoneTools({
    super.key,
    required this.subtitlesOn,
    required this.onSubtitles,
    required this.onAudio,
    required this.onSettings,
    this.onEpisodes,
    this.onNext,
  });
  final bool subtitlesOn;
  final VoidCallback onSubtitles;
  final VoidCallback onAudio;
  final VoidCallback onSettings;
  final VoidCallback? onEpisodes;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Center(
    child: _Capsule(
      children: [
        _Tool(icon: subtitlesOn ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined, tooltip: 'Subtitles', on: subtitlesOn, onTap: onSubtitles),
        _Tool(icon: Icons.graphic_eq_rounded, tooltip: 'Audio', onTap: onAudio),
        _Tool(icon: Icons.tune_rounded, tooltip: 'Settings', onTap: onSettings),
        if (onEpisodes != null) _Tool(icon: Icons.video_library_outlined, tooltip: 'Episodes', onTap: onEpisodes!),
        if (onNext != null) _Tool(icon: Icons.skip_next_rounded, tooltip: 'Next episode', onTap: onNext!),
      ],
    ),
  );
}

/// Play / pause: a soft-cornered key rather than a circle.
class PlayKey extends StatelessWidget {
  const PlayKey({super.key, required this.paused, required this.onTap});
  final bool paused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: 'Play / pause (Space)',
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .92 : (hovered ? 1.05 : 1),
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(17),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 130),
          child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, key: ValueKey(paused), size: 32, color: Colors.black),
        ),
      ),
    ),
  );
}

class _Skip extends StatelessWidget {
  const _Skip({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .88 : 1,
      duration: const Duration(milliseconds: 120),
      child: SizedBox.square(dimension: 46, child: Icon(icon, size: 29, color: hovered ? Colors.white : const Color(0xE6FFFFFF))),
    ),
  );
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0x1FFFFFFF),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x14FFFFFF)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.tooltip, required this.onTap, this.on = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool on; // in use: a small dot under it

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: Colors.white.withValues(alpha: pressed ? .2 : (hovered ? .13 : 0)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon, size: 22, color: hovered || on ? Colors.white : const Color(0xD9FFFFFF)),
          if (on)
            Positioned(
              bottom: 4,
              child: Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(color: VyseColors.accent, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Volume extends StatelessWidget {
  const _Volume({required this.volume, required this.onVolume, required this.slider});
  final double volume;
  final ValueChanged<double> onVolume;
  final bool slider;

  @override
  Widget build(BuildContext context) {
    final v = volume;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Pressable(
          tooltip: 'Mute',
          onTap: () => onVolume(v == 0 ? 80 : 0),
          builder: (context, hovered, _) => SizedBox.square(
            dimension: 40,
            child: Icon(
              v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
              size: 24,
              color: hovered ? Colors.white : const Color(0xE6FFFFFF),
            ),
          ),
        ),
        if (slider)
          SizedBox(
            width: 96,
            height: 40,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: .25),
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
              ),
              child: Slider(value: v.clamp(0, 100), max: 100, onChanged: onVolume),
            ),
          ),
      ],
    );
  }
}
