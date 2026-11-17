import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/audiobook_player.dart';
import '../widgets/audiobook_widgets.dart';
import '../widgets/common.dart';
import '../widgets/music_widgets.dart';
import '../widgets/section_chrome.dart';
import 'shell.dart' show WindowBar;

Future<void> openAudiobookPlayer(BuildContext context) => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 480),
      reverseTransitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, _, _) => const AudiobookPlayerPage(),
      transitionsBuilder: (_, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: t,
          child: SlideTransition(position: Tween(begin: const Offset(0, .08), end: Offset.zero).animate(t), child: child),
        );
      },
    ));

const _speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// Full-screen chapter player: cover, seek bar, ±30 s, chapter skip, speed, sleep timer and the
/// chapter list. Space plays / pauses, ← → skip 30 s, Esc closes.
class AudiobookPlayerPage extends StatefulWidget {
  const AudiobookPlayerPage({super.key});

  @override
  State<AudiobookPlayerPage> createState() => _AudiobookPlayerPageState();
}

class _AudiobookPlayerPageState extends State<AudiobookPlayerPage> {
  final _p = AudiobookPlayer.instance;
  bool _showChapters = false;

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = Layout.windowChrome(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.space): _p.toggle,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _p.skip(30),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _p.skip(-30),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: VyseColors.bg,
          body: ListenableBuilder(
            listenable: _p,
            builder: (context, _) {
              final b = _p.book;
              if (b == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _close();
                });
                return const SizedBox.shrink();
              }
              final player = Column(children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380, maxHeight: 380),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .6), blurRadius: 50, offset: const Offset(0, 24))],
                        ),
                        child: Hero(tag: 'book/${b.uuid}', child: Artwork(url: b.coverImage, radius: 18)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                Text(b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.5, height: 1.15)),
                const SizedBox(height: 6),
                Text(
                  _p.error ?? [_p.currentChapter?.title ?? '', '${_p.chapter + 1} of ${_p.chapters.length}'].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: _p.error != null ? VyseColors.accentHot : VyseColors.textDim),
                ),
                const SizedBox(height: 16),
                SeekBar(position: _p.position, duration: _p.duration, onSeek: _p.seek),
                const SizedBox(height: 8),
                _transport(),
                const SizedBox(height: 14),
                Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                  _speedChip(),
                  _sleepChip(),
                  if (phone)
                    FilterChipPill(
                      label: 'Capitoli',
                      icon: Icons.list_rounded,
                      selected: _showChapters,
                      onTap: () => setState(() => _showChapters = !_showChapters),
                    ),
                ]),
              ]);

              return Stack(children: [
                Positioned.fill(
                  child: Stack(fit: StackFit.expand, children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
                      child: Transform.scale(scale: 1.3, child: Opacity(opacity: .5, child: NetImage(url: b.coverImage))),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x9907080F), Color(0xE607080F)],
                        ),
                      ),
                    ),
                  ]),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(phone ? 20 : 40, top + (phone ? 8 : 16), phone ? 20 : 40, phone ? 16 : 28),
                    child: Column(children: [
                      Row(children: [
                        GlassIconButton(icon: Icons.keyboard_arrow_down_rounded, label: 'Chiudi (Esc)', size: 40, onTap: _close),
                        const Spacer(),
                        const Text('AUDIOBOOK',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.textDim)),
                        const Spacer(),
                        const SizedBox(width: 40),
                      ]),
                      SizedBox(height: phone ? 12 : 24),
                      Expanded(
                        child: phone
                            ? AnimatedSwitcher(
                                duration: const Duration(milliseconds: 280),
                                child: _showChapters
                                    ? Column(key: const ValueKey('ch'), children: [
                                        Expanded(child: _Chapters(player: _p)),
                                        const SizedBox(height: 10),
                                        FilterChipPill(
                                          label: 'Torna al player',
                                          icon: Icons.headphones_rounded,
                                          selected: false,
                                          onTap: () => setState(() => _showChapters = false),
                                        ),
                                      ])
                                    : KeyedSubtree(key: const ValueKey('player'), child: player),
                              )
                            : Row(children: [
                                Expanded(flex: 5, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: player))),
                                const SizedBox(width: 40),
                                Expanded(
                                  flex: 4,
                                  child: Glass(
                                    radius: 22,
                                    opacity: .35,
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      const Padding(
                                        padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                                        child: Text('Capitoli', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                      ),
                                      Expanded(child: _Chapters(player: _p)),
                                    ]),
                                  ),
                                ),
                              ]),
                      ),
                    ]),
                  ),
                ),
                if (isDesktopNative) const Positioned(top: 0, left: 0, right: 0, child: WindowBar()),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _transport() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
          tooltip: 'Capitolo precedente',
          onPressed: _p.previousChapter,
          iconSize: 26,
          color: VyseColors.textDim,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        const SizedBox(width: 6),
        IconButton(tooltip: 'Indietro 30s (←)', onPressed: () => _p.skip(-30), iconSize: 32, icon: const Icon(Icons.replay_30_rounded)),
        const SizedBox(width: 10),
        _p.loading || _p.buffering
            ? Container(
                width: 66,
                height: 66,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .1)),
                child: const CircularProgressIndicator(strokeWidth: 2.4, color: VyseColors.accent),
              )
            : PlayBubble(onTap: _p.toggle, size: 66, playing: _p.playing),
        const SizedBox(width: 10),
        IconButton(tooltip: 'Avanti 30s (→)', onPressed: () => _p.skip(30), iconSize: 32, icon: const Icon(Icons.forward_30_rounded)),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Capitolo successivo',
          onPressed: _p.hasNext ? _p.nextChapter : null,
          iconSize: 26,
          color: VyseColors.textDim,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ]);

  Widget _speedChip() => PopupMenuButton<double>(
        tooltip: 'Velocità di riproduzione',
        color: VyseColors.surfaceHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: VyseColors.stroke)),
        onSelected: _p.setSpeed,
        itemBuilder: (_) => [
          for (final s in _speeds)
            PopupMenuItem(
              value: s,
              height: 38,
              child: Text('${_fmtSpeed(s)}×',
                  style: TextStyle(fontWeight: FontWeight.w600, color: s == _p.speed ? VyseColors.accent : VyseColors.text)),
            ),
        ],
        child: IgnorePointer(
          child: FilterChipPill(label: '${_fmtSpeed(_p.speed)}×', icon: Icons.speed_rounded, selected: _p.speed != 1, onTap: () {}),
        ),
      );

  Widget _sleepChip() {
    String label() {
      if (_p.sleepAtChapterEnd) return 'Fine del capitolo';
      final at = _p.sleepAt;
      if (at == null) return 'Timer di spegnimento';
      final left = at.difference(DateTime.now());
      return '${left.inMinutes.clamp(0, 999) + 1} min';
    }

    return PopupMenuButton<int>(
      tooltip: 'Timer di spegnimento',
      color: VyseColors.surfaceHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: VyseColors.stroke)),
      onSelected: (m) => switch (m) {
        0 => _p.setSleep(null),
        -1 => _p.setSleep(null, endOfChapter: true),
        _ => _p.setSleep(Duration(minutes: m)),
      },
      itemBuilder: (_) => [
        for (final m in const [15, 30, 45, 60]) PopupMenuItem(value: m, height: 38, child: Text('$m minuti')),
        const PopupMenuItem(value: -1, height: 38, child: Text('Fine del capitolo')),
        if (_p.sleeping) const PopupMenuItem(value: 0, height: 38, child: Text('Disattiva', style: TextStyle(color: VyseColors.accentHot))),
      ],
      child: IgnorePointer(
        child: FilterChipPill(label: label(), icon: Icons.bedtime_outlined, selected: _p.sleeping, onTap: () {}),
      ),
    );
  }

  static String _fmtSpeed(double s) => s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString();
}

class _Chapters extends StatefulWidget {
  const _Chapters({required this.player});
  final AudiobookPlayer player;

  @override
  State<_Chapters> createState() => _ChaptersState();
}

class _ChaptersState extends State<_Chapters> {
  static const _rowH = 50.0;
  late final _scroll = ScrollController(initialScrollOffset: (widget.player.chapter - 2).clamp(0, 1 << 20) * _rowH);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      itemCount: p.chapters.length,
      itemExtent: _rowH,
      itemBuilder: (context, i) {
        final current = i == p.chapter;
        return Pressable(
          onTap: () => p.jumpToChapter(i),
          builder: (context, hovered, _) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: current ? .08 : (hovered ? .06 : 0)),
            ),
            child: Row(children: [
              SizedBox(
                width: 30,
                child: current
                    ? Equalizer(active: p.playing)
                    : Text('${i + 1}', style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
              ),
              Expanded(
                child: Text(p.chapters[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                      color: current ? VyseColors.text : const Color(0xFFC3C7D4),
                    )),
              ),
            ]),
          ),
        );
      },
    );
  }
}
