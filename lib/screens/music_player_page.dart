import 'dart:ui';

import 'package:flutter/material.dart';
import '../core/accent.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/music_player.dart';
import '../data/party/rooms.dart';
import '../data/party/watch_party.dart';
import '../models/music/music_track.dart';
import '../widgets/common.dart';
import '../widgets/music_widgets.dart';
import '../widgets/section_chrome.dart';
import 'music_detail_pages.dart';
import 'party/party_music_room.dart' show shareMusicWithRoom;
import 'shell.dart' show WindowBar;
import 'music/music_ui.dart' show LikeButton, showAddToPlaylist;

/// Full-screen player: blurred artwork, big cover, seek bar and transport, with Lyrics and Up next
/// beside it on wide screens (tabs on phones). Space plays / pauses, ← → seek, Esc closes.
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  final _p = MusicPlayer.instance;

  /// Phone only: 0 artwork, 1 lyrics, 2 queue. Wide screens: 1 lyrics, 2 queue in the side panel.
  int _view = 0;
  int _panel = 1;

  void _close() => Navigator.of(context).maybePop();

  void _seekBy(int seconds) {
    final d = _p.position.value + Duration(seconds: seconds);
    _p.seek(d < Duration.zero ? Duration.zero : d);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = Layout.windowChrome(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.space): _p.toggle,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(5),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekBy(-5),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: VyseColors.bg,
          body: ListenableBuilder(
            listenable: _p,
            builder: (context, _) {
              final t = _p.current;
              if (t == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _close();
                });
                return const SizedBox.shrink();
              }
              return Stack(children: [
                Positioned.fill(child: _Backdrop(url: t.coverUrl)),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(phone ? 20 : 40, top + (phone ? 8 : 16), phone ? 20 : 40, phone ? 16 : 28),
                    child: Column(children: [
                      _topBar(t),
                      SizedBox(height: phone ? 12 : 24),
                      Expanded(child: phone ? _phoneBody(t) : _wideBody(t)),
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

  Widget _topBar(MusicTrack t) => Row(children: [
        GlassIconButton(icon: Icons.keyboard_arrow_down_rounded, label: 'Close (Esc)', size: 40, onTap: _close),
        const Spacer(),
        Column(children: [
          const Text('NOW PLAYING', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.textDim)),
          const SizedBox(height: 2),
          Text(t.album, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
        const Spacer(),
        if (Rooms.mine.value != null && WatchParty.canControl && WatchParty.state.value?.isMusic != true) ...[
          GlassIconButton(icon: Icons.groups_rounded, label: 'Play in my room', size: 40, onTap: () => shareMusicWithRoom(context)),
          const SizedBox(width: 8),
        ],
        GlassIconButton(
          icon: Icons.more_horiz_rounded,
          label: 'More',
          size: 40,
          onTap: () {
            final size = MediaQuery.sizeOf(context);
            showTrackMenu(context, t, Offset(size.width - 60, 80));
          },
        ),
      ]);

  Widget _phoneBody(MusicTrack t) => Column(children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            child: switch (_view) {
              1 => _LyricsView(key: ValueKey('lyrics/${t.id}'), track: t),
              2 => const _QueueView(key: ValueKey('queue')),
              _ => Center(key: const ValueKey('art'), child: _Cover(track: t)),
            },
          ),
        ),
        const SizedBox(height: 18),
        _Info(track: t),
        const SizedBox(height: 14),
        _Seek(player: _p),
        const SizedBox(height: 8),
        _Transport(player: _p),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          FilterChipPill(label: 'Lyrics', icon: Icons.lyrics_outlined, selected: _view == 1, onTap: () => setState(() => _view = _view == 1 ? 0 : 1)),
          const SizedBox(width: 8),
          FilterChipPill(label: 'Up next', icon: Icons.queue_music_rounded, selected: _view == 2, onTap: () => setState(() => _view = _view == 2 ? 0 : 2)),
        ]),
      ]);

  Widget _wideBody(MusicTrack t) => Row(children: [
        Expanded(
          flex: 5,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: _Cover(track: t)),
                const SizedBox(height: 28),
                _Info(track: t),
                const SizedBox(height: 18),
                _Seek(player: _p),
                const SizedBox(height: 10),
                _Transport(player: _p),
                const SizedBox(height: 14),
                _Volume(player: _p),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 40),
        Expanded(
          flex: 4,
          child: Glass(
            radius: 22,
            opacity: .35,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(children: [
                  FilterChipPill(label: 'Lyrics', icon: Icons.lyrics_outlined, selected: _panel == 1, onTap: () => setState(() => _panel = 1)),
                  const SizedBox(width: 8),
                  FilterChipPill(label: 'Up next', icon: Icons.queue_music_rounded, selected: _panel == 2, onTap: () => setState(() => _panel = 2)),
                ]),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  child: _panel == 1 ? _LyricsView(key: ValueKey('lyrics/${t.id}'), track: t) : const _QueueView(key: ValueKey('queue')),
                ),
              ),
            ]),
          ),
        ),
      ]);
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 800),
        child: Stack(key: ValueKey(url), fit: StackFit.expand, children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            child: Transform.scale(scale: 1.3, child: Opacity(opacity: .55, child: NetImage(url: url))),
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
      );
}

class _Cover extends StatelessWidget {
  const _Cover({required this.track});
  final MusicTrack track;

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: 1,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: .94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
          ),
          child: Container(
            key: ValueKey(track.id),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .6), blurRadius: 50, offset: const Offset(0, 24))],
            ),
            child: Hero(tag: 'music/art', child: Artwork(url: track.coverUrl, radius: 18)),
          ),
        ),
      );
}

class _Info extends StatelessWidget {
  const _Info({required this.track});
  final MusicTrack track;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return Column(children: [
      Text(track.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.6, height: 1.15)),
      const SizedBox(height: 6),
      Pressable(
        onTap: track.artistId.isEmpty
            ? null
            : () {
                Navigator.of(context).maybePop();
                // Lands in whichever tab is showing; good enough for a jump to the artist.
                Future.delayed(const Duration(milliseconds: 380), () {
                  if (context.mounted) openArtist(context, track.artistId, track.artist);
                });
              },
        builder: (context, hovered, _) => Text(track.artist,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : accentOf(context))),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        LikeButton(track: track, size: 24),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Add to playlist',
          iconSize: 22,
          color: VyseColors.textDim,
          onPressed: () => showAddToPlaylist(context, [track]),
          icon: const Icon(Icons.playlist_add_rounded),
        ),
        IconButton(
          tooltip: 'Start radio from this song',
          iconSize: 21,
          color: VyseColors.textDim,
          onPressed: () => MusicPlayer.instance.startRadio(track),
          icon: const Icon(Icons.sensors_rounded),
        ),
      ]),
      if (p.error != null) ...[
        const SizedBox(height: 6),
        Text(p.error!, style: TextStyle(fontSize: 12, color: accentHotOf(context))),
      ],
    ]);
  }
}

class _Seek extends StatefulWidget {
  const _Seek({required this.player});
  final MusicPlayer player;

  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _drag;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Duration>(
        valueListenable: widget.player.duration,
        builder: (context, total, _) => ValueListenableBuilder<Duration>(
          valueListenable: widget.player.position,
          builder: (context, pos, _) {
            final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
            final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max);
            const style = TextStyle(fontSize: 11.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]);
            return Column(children: [
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  activeTrackColor: accentOf(context),
                  inactiveTrackColor: Colors.white.withValues(alpha: .14),
                  thumbColor: Colors.white,
                  overlayColor: accentOf(context).withValues(alpha: .15),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  value: value,
                  max: max,
                  onChanged: (v) => setState(() => _drag = v),
                  onChangeEnd: (v) {
                    widget.player.seek(Duration(milliseconds: v.round()));
                    setState(() => _drag = null);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(children: [
                  Text(fmtClock(Duration(milliseconds: value.round())), style: style),
                  const Spacer(),
                  Text(fmtClock(total), style: style),
                ]),
              ),
            ]);
          },
        ),
      );
}

class _Transport extends StatelessWidget {
  const _Transport({required this.player});
  final MusicPlayer player;

  @override
  Widget build(BuildContext context) {
    final p = player;
    Widget side(IconData icon, String label, bool on, VoidCallback onTap) => IconButton(
          tooltip: label,
          onPressed: onTap,
          iconSize: 22,
          color: on ? accentOf(context) : VyseColors.textDim,
          icon: Icon(icon),
        );
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      side(Icons.shuffle_rounded, 'Shuffle', p.shuffle, p.toggleShuffle),
      const SizedBox(width: 10),
      IconButton(tooltip: 'Previous', onPressed: p.previous, iconSize: 34, icon: const Icon(Icons.skip_previous_rounded)),
      const SizedBox(width: 10),
      p.resolving || p.buffering
          ? Container(
              width: 66,
              height: 66,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: .1)),
              child: CircularProgressIndicator(strokeWidth: 2.4, color: accentOf(context)),
            )
          : PlayBubble(onTap: p.toggle, size: 66, playing: p.playing),
      const SizedBox(width: 10),
      IconButton(tooltip: 'Next', onPressed: p.next, iconSize: 34, icon: const Icon(Icons.skip_next_rounded)),
      const SizedBox(width: 10),
      side(
        p.repeat == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
        switch (p.repeat) { LoopMode.off => 'Repeat', LoopMode.all => 'Repeat all', LoopMode.one => 'Repeat one' },
        p.repeat != LoopMode.off,
        p.cycleRepeat,
      ),
    ]);
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.player});
  final MusicPlayer player;

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(player.volume == 0 ? Icons.volume_off_rounded : Icons.volume_down_rounded, size: 18, color: VyseColors.textDim),
        SizedBox(
          width: 180,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: Colors.white.withValues(alpha: .8),
              inactiveTrackColor: Colors.white.withValues(alpha: .14),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(value: player.volume, max: 100, onChanged: player.setVolume),
          ),
        ),
        const Icon(Icons.volume_up_rounded, size: 18, color: VyseColors.textDim),
      ]);
}

/// Synced lyrics follow the song (tap a line to jump there); plain lyrics just scroll.
class _LyricsView extends StatefulWidget {
  const _LyricsView({super.key, required this.track});
  final MusicTrack track;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final _p = MusicPlayer.instance;
  late final Future<LyricsData> _future = _p.lyricsFor(widget.track);
  final _keys = <GlobalKey>[];
  List<SyncedLyricLine> _lines = const [];
  int _current = -1;

  @override
  void initState() {
    super.initState();
    _p.position.addListener(_follow);
  }

  @override
  void dispose() {
    _p.position.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    if (_lines.isEmpty) return;
    final pos = _p.position.value + const Duration(milliseconds: 250);
    var i = -1;
    for (var j = 0; j < _lines.length; j++) {
      if (_lines[j].timestamp <= pos) {
        i = j;
      } else {
        break;
      }
    }
    if (i == _current) return;
    setState(() => _current = i);
    final ctx = i >= 0 ? _keys[i].currentContext : null;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: .4, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<LyricsData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: accentOf(context))));
          }
          final d = snap.data;
          final synced = d != null && d.isSynced && d.syncedLines.isNotEmpty;
          if (d == null || (!synced && d.plainLyrics.trim().isEmpty)) {
            return const EmptyState(icon: Icons.lyrics_outlined, title: 'No lyrics', body: "We couldn't find lyrics for this song.");
          }
          if (!synced) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              child: Text(d.plainLyrics, style: const TextStyle(fontSize: 17, height: 1.7, fontWeight: FontWeight.w600, color: Color(0xFFDADCE6))),
            );
          }
          if (!identical(_lines, d.syncedLines)) {
            _lines = d.syncedLines;
            _keys
              ..clear()
              ..addAll(List.generate(_lines.length, (_) => GlobalKey()));
          }
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
              stops: [0, .1, .85, 1],
            ).createShader(r),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 200),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < _lines.length; i++)
                  Pressable(
                    key: _keys[i],
                    onTap: () => _p.seek(_lines[i].timestamp),
                    builder: (context, hovered, _) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 260),
                        style: TextStyle(
                          fontSize: i == _current ? 24 : 20,
                          height: 1.3,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.4,
                          color: i == _current
                              ? VyseColors.text
                              : hovered
                                  ? Colors.white.withValues(alpha: .7)
                                  : Colors.white.withValues(alpha: i < _current ? .35 : .45),
                        ),
                        child: Text(_lines[i].text.isEmpty ? '♪' : _lines[i].text),
                      ),
                    ),
                  ),
              ]),
            ),
          );
        },
      );
}

class _QueueView extends StatelessWidget {
  const _QueueView({super.key});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final up = p.upNext;
        if (up.isEmpty) {
          return const EmptyState(icon: Icons.queue_music_rounded, title: 'Nothing up next', body: 'Use "Play next" or "Add to queue" on any song.');
        }
        return ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 40),
          buildDefaultDragHandles: false,
          itemCount: up.length,
          onReorderItem: (from, to) => p.reorder(p.index + 1 + from, p.index + 1 + to),
          itemBuilder: (context, i) {
            final t = up[i];
            return Pressable(
              key: ValueKey('q/$i/${t.id}'),
              onTap: () => p.jumpTo(p.index + 1 + i),
              builder: (context, hovered, _) => Container(
                height: 58,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white.withValues(alpha: hovered ? .06 : 0),
                ),
                child: Row(children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(padding: EdgeInsets.all(6), child: Icon(Icons.drag_indicator_rounded, size: 18, color: VyseColors.textFaint)),
                    ),
                  ),
                  Artwork(url: t.coverUrl, size: 40, radius: 6),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim)),
                    ]),
                  ),
                  // came on its own (autoplay or radio), not added by you
                  if (p.autoIds.contains(t.id))
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: Colors.white.withValues(alpha: .08)),
                      child: const Text('Autoplay', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: VyseColors.textFaint)),
                    ),
                  IconButton(
                    tooltip: 'Remove',
                    iconSize: 16,
                    color: VyseColors.textFaint,
                    onPressed: () => p.removeAt(p.index + 1 + i),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
