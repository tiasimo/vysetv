import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/audio_focus.dart';
import '../data/audiobook_player.dart';
import '../data/music_player.dart';
import '../models/audiobook/audiobook_model.dart';
import '../screens/audiobook_player_page.dart';
import 'common.dart';
import 'media_rows.dart';
import 'music_widgets.dart';
import 'section_chrome.dart';

/// Seek slider with elapsed / remaining times, for any player.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.position, required this.duration, required this.onSeek});
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Duration>(
        valueListenable: widget.duration,
        builder: (context, total, _) => ValueListenableBuilder<Duration>(
          valueListenable: widget.position,
          builder: (context, pos, _) {
            final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
            final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max);
            final left = Duration(milliseconds: (max - value).round());
            const style = TextStyle(fontSize: 11.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]);
            return Column(children: [
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: VyseColors.accent,
                  inactiveTrackColor: Colors.white.withValues(alpha: .14),
                  thumbColor: Colors.white,
                  overlayColor: VyseColors.accent.withValues(alpha: .15),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: value,
                  max: max,
                  onChanged: total == Duration.zero ? null : (v) => setState(() => _drag = v),
                  onChangeEnd: (v) {
                    widget.onSeek(Duration(milliseconds: v.round()));
                    setState(() => _drag = null);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(children: [
                  Text(fmtClock(Duration(milliseconds: value.round())), style: style),
                  const Spacer(),
                  Text(total == Duration.zero ? '--:--' : '-${fmtClock(left)}', style: style),
                ]),
              ),
            ]);
          },
        ),
      );
}

/// A book cover, Discover-style: art fills the card, title + author slide up on hover.
/// With [progress] it gets a thin amber bar along the bottom and the chapter in its caption.
class BookCard extends StatelessWidget {
  const BookCard({super.key, required this.book, required this.onTap, this.progress, this.onRemove});
  final Audiobook book;
  final VoidCallback onTap;
  final BookProgress? progress;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return OutlineCard(
      label: book.title,
      onTap: onTap,
      builder: (hovered) => Stack(fit: StackFit.expand, children: [
        Hero(tag: 'book/${book.uuid}', child: NetImage(url: book.coverImage, fallback: Icons.headphones_rounded)),
        AnimatedOpacity(
          opacity: hovered ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.center, colors: [Color(0xF0000000), Color(0x00000000)]),
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: p == null ? 9 : 12,
          child: AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: AnimatedSlide(
              offset: Offset(0, hovered ? 0 : .3),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(book.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2)),
                const SizedBox(height: 3),
                Text(
                  p != null ? '${p.chapterTitle ?? 'Chapter ${p.chapter + 1}'} · ${fmtClock(p.position)}' : (book.author ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: VyseColors.textDim),
                ),
              ]),
            ),
          ),
        ),
        if (book.source.isNotEmpty)
          Positioned(top: 7, left: 7, child: SourceBadge(book.source)),
        if (onRemove != null && hovered)
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: 'Rimuovi',
              onPressed: onRemove,
              iconSize: 16,
              style: IconButton.styleFrom(backgroundColor: Colors.black.withValues(alpha: .6), minimumSize: const Size(30, 30)),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        if (p != null)
          const Positioned(left: 0, right: 0, bottom: 0, child: SizedBox(height: 3, child: ColoredBox(color: VyseColors.accent))),
      ]),
    );
  }
}

/// Small dark tag in the corner, like Discover's SERIES label.
class SourceBadge extends StatelessWidget {
  const SourceBadge(this.source, {super.key});
  final String source;

  @override
  Widget build(BuildContext context) => source.isEmpty
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(4)),
          child: Text(source.toUpperCase(), style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: .4)),
        );
}

/// Shows the mini player for whichever of music / audiobooks played last.
class ActiveMiniPlayer extends StatelessWidget {
  const ActiveMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Object?>(
        valueListenable: AudioFocus.owner,
        builder: (context, owner, _) => ListenableBuilder(
          listenable: AudiobookPlayer.instance,
          builder: (context, _) {
            final book = AudiobookPlayer.instance.book != null;
            final music = MusicPlayer.instance.current != null;
            final showBook = book && (identical(owner, AudiobookPlayer.instance) || !music);
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: showBook ? const _BookMiniBar(key: ValueKey('book')) : const MiniPlayer(key: ValueKey('music')),
            );
          },
        ),
      );
}

class _BookMiniBar extends StatelessWidget {
  const _BookMiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AudiobookPlayer.instance;
    final b = p.book!;
    return Pressable(
      onTap: () => openAudiobookPlayer(context),
      builder: (context, hovered, _) => Glass(
        radius: 16,
        opacity: .8,
        borderColor: hovered ? VyseColors.strokeHi : VyseColors.stroke,
        child: SizedBox(
          height: 64,
          child: Stack(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
              child: Row(children: [
                Artwork(url: b.coverImage, size: 44, radius: 7),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(p.error ?? p.currentChapter?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: p.error != null ? VyseColors.accentHot : VyseColors.textDim)),
                  ]),
                ),
                IconButton(tooltip: 'Indietro 30s', onPressed: () => p.skip(-30), icon: const Icon(Icons.replay_30_rounded), iconSize: 22),
                p.loading || p.buffering
                    ? const SizedBox.square(
                        dimension: 40,
                        child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)),
                      )
                    : IconButton(
                        tooltip: p.playing ? 'Pausa' : 'Riproduci',
                        onPressed: p.toggle,
                        icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        iconSize: 28,
                      ),
                IconButton(tooltip: 'Avanti 30s', onPressed: () => p.skip(30), icon: const Icon(Icons.forward_30_rounded), iconSize: 22),
                IconButton(tooltip: 'Chiudi', onPressed: p.stop, icon: const Icon(Icons.close_rounded), iconSize: 18, color: VyseColors.textFaint),
              ]),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ValueListenableBuilder<Duration>(
                valueListenable: p.position,
                builder: (context, pos, _) {
                  final total = p.duration.value.inMilliseconds;
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: total <= 0 ? 0 : (pos.inMilliseconds / total).clamp(0.0, 1.0),
                      child: Container(height: 2, color: VyseColors.accent),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
