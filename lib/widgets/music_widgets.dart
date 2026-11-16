import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/accent.dart';
import '../core/format.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/music_player.dart';
import '../models/music/music_track.dart';
import '../screens/music_detail_pages.dart';
import '../data/party/rooms.dart';
import '../data/party/watch_party.dart';
import '../screens/party/party_music_room.dart' show playInRoom;
import '../data/music/music_library.dart';
import '../screens/music/music_ui.dart' show LikeButton, showAddToPlaylist;
import 'common.dart';
import 'media_rows.dart';
import 'section_chrome.dart';

/// Square artwork with rounded corners.
class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.url, this.size, this.radius = 8, this.circle = false});
  final String? url;
  final double? size;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
      color: VyseColors.surface,
    ),
    clipBehavior: Clip.antiAlias,
    child: NetImage(url: url, fallback: circle ? Icons.person_rounded : Icons.music_note_rounded),
  );
}

/// Three bouncing bars beside the playing track.
class Equalizer extends StatefulWidget {
  const Equalizer({super.key, required this.active, this.size = 14, this.color});
  final bool active;
  final double size;

  /// The theme's accent when not given.
  final Color? color;

  @override
  State<Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<Equalizer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(Equalizer old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat();
    if (!widget.active) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) SizedBox(width: widget.size * .12),
            Expanded(
              child: Container(
                height: widget.size * (.3 + .7 * (.5 + .5 * math.sin((_c.value + i * .33) * 2 * math.pi)).abs()),
                decoration: BoxDecoration(color: widget.color ?? accentOf(context), borderRadius: BorderRadius.circular(1)),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// One track in a list: number or artwork, title / artist, duration, and a menu.
/// Tapping plays [queue] from this track.
class TrackRow extends StatelessWidget {
  const TrackRow({super.key, required this.track, required this.queue, required this.index, this.showArt = true, this.showNumber = false, this.onRemove});

  final MusicTrack track;
  final List<MusicTrack> queue;
  final int index;
  final bool showArt;
  final bool showNumber;

  /// In a playlist of yours: the menu offers to take it out.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([player, MusicLibrary.likesListenable]),
      builder: (context, _) {
        final isCurrent = player.current?.id == track.id;
        return Pressable(
          onTap: () => isCurrent ? player.toggle() : player.playQueue(queue, start: index),
          builder: (context, hovered, pressed) => GestureDetector(
            onSecondaryTapUp: (d) => showTrackMenu(context, track, d.globalPosition, onRemove: onRemove),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.white.withValues(alpha: isCurrent ? .07 : (hovered ? .06 : 0)),
              ),
              child: Row(
                children: [
                  if (showNumber)
                    SizedBox(
                      width: 28,
                      child: Center(
                        child: isCurrent
                            ? Equalizer(active: player.playing)
                            : hovered
                            ? const Icon(Icons.play_arrow_rounded, size: 18)
                            : Text('${track.trackNumber ?? index + 1}', style: const TextStyle(color: VyseColors.textFaint, fontSize: 13)),
                      ),
                    ),
                  if (showArt) ...[
                    if (showNumber) const SizedBox(width: 8),
                    Stack(
                      children: [
                        Artwork(url: track.coverUrl, size: 42, radius: 6),
                        if (!showNumber && (hovered || isCurrent))
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                              child: Center(
                                child: isCurrent && !hovered
                                    ? Equalizer(active: player.playing)
                                    : Icon(isCurrent && player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 20),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: isCurrent ? accentOf(context) : VyseColors.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (track.explicit) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(color: VyseColors.textFaint, borderRadius: BorderRadius.circular(3)),
                                child: const Text(
                                  'E',
                                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.black),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: VyseColors.textDim),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!Layout.isPhone(context) && track.album.isNotEmpty)
                    Expanded(
                      child: Text(
                        track.album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: VyseColors.textFaint),
                      ),
                    ),
                  // liked: always a heart; otherwise one appears on hover
                  if (!Layout.isPhone(context) || MusicLibrary.isLiked(track.id))
                    AnimatedOpacity(
                      opacity: MusicLibrary.isLiked(track.id) || hovered ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: LikeButton(track: track, size: 17, dim: true),
                    ),
                  const SizedBox(width: 6),
                  if (track.durationSeconds > 0)
                    Text(
                      fmtClock(Duration(seconds: track.durationSeconds)),
                      style: const TextStyle(fontSize: 12, color: VyseColors.textFaint, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  const SizedBox(width: 4),
                  Builder(
                    builder: (context) => IconButton(
                      tooltip: 'More',
                      iconSize: 18,
                      color: hovered ? VyseColors.text : VyseColors.textFaint,
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox;
                        showTrackMenu(context, track, box.localToGlobal(box.size.center(Offset.zero)), onRemove: onRemove);
                      },
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
}

Future<void> showTrackMenu(BuildContext context, MusicTrack t, Offset at, {VoidCallback? onRemove}) async {
  final player = MusicPlayer.instance;
  final liked = MusicLibrary.isLiked(t.id);
  final choice = await showMenu<String>(
    context: context,
    color: VyseColors.surfaceHi,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: VyseColors.stroke),
    ),
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      if (Rooms.mine.value != null && WatchParty.canControl) _item('room', Icons.groups_rounded, 'Play in my room'),
      _item('next', Icons.playlist_play_rounded, 'Play next'),
      _item('queue', Icons.queue_music_rounded, 'Add to queue'),
      _item('radio', Icons.sensors_rounded, 'Start radio'),
      const PopupMenuDivider(height: 8),
      _item('like', liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, liked ? 'Remove from Liked songs' : 'Like'),
      _item('playlist', Icons.playlist_add_rounded, 'Add to playlist…'),
      if (onRemove != null) _item('remove', Icons.playlist_remove_rounded, 'Remove from this playlist'),
      if (t.artistId.isNotEmpty || t.albumId.isNotEmpty) const PopupMenuDivider(height: 8),
      if (t.artistId.isNotEmpty) _item('artist', Icons.person_rounded, 'Go to artist'),
      if (t.albumId.isNotEmpty) _item('album', Icons.album_rounded, 'Go to album'),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'room':
      await playInRoom(context, t);
    case 'next':
      player.addNext(t);
      showToast(context, Text('Playing next: ${t.title}', maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icons.playlist_play_rounded);
    case 'queue':
      player.addToQueue(t);
      showToast(context, Text('Added to queue: ${t.title}', maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icons.queue_music_rounded);
    case 'radio':
      await player.startRadio(t);
    case 'like':
      MusicLibrary.setLiked(t, !liked);
      showToast(context, Text(liked ? 'Removed from Liked songs' : 'Added to Liked songs', maxLines: 1), icon: liked ? Icons.heart_broken_rounded : Icons.favorite_rounded);
    case 'playlist':
      await showAddToPlaylist(context, [t]);
    case 'remove':
      onRemove?.call();
    case 'artist':
      openArtist(context, t.artistId, t.artist);
    case 'album':
      openAlbum(context, t.albumId);
  }
}

PopupMenuItem<String> _item(String value, IconData icon, String label) => PopupMenuItem(
  value: value,
  height: 40,
  child: Row(
    children: [
      Icon(icon, size: 18, color: VyseColors.textDim),
      const SizedBox(width: 10),
      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    ],
  ),
);

/// A song as a square cover (Home's poster shelves, but square). Hover dims the art and shows a
/// play button; the playing song gets the equalizer. Tapping plays [queue] from here.
class TrackCard extends StatelessWidget {
  const TrackCard({super.key, required this.track, required this.queue, required this.index});
  final MusicTrack track;
  final List<MusicTrack> queue;
  final int index;

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final current = player.current?.id == track.id;
        void play() => current ? player.toggle() : player.playQueue(queue, start: index);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Flexible(
            child: AspectRatio(
              aspectRatio: 1,
              child: GestureDetector(
                onSecondaryTapUp: (d) => showTrackMenu(context, track, d.globalPosition),
                onLongPress: () {
                  final box = context.findRenderObject() as RenderBox;
                  showTrackMenu(context, track, box.localToGlobal(box.size.center(Offset.zero)));
                },
                child: OutlineCard(
                  label: track.title,
                  onTap: play,
                  builder: (hovered) => Stack(fit: StackFit.expand, children: [
                    NetImage(url: track.coverUrl, fallback: Icons.music_note_rounded),
                    IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        color: Colors.black.withValues(alpha: hovered ? .3 : (current ? .35 : .08)),
                      ),
                    ),
                    if (current && !hovered) Positioned(left: 10, bottom: 10, child: Equalizer(active: player.playing, size: 16)),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: AnimatedSlide(
                        offset: Offset(0, hovered ? 0 : .3),
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: hovered ? 1 : 0,
                          duration: const Duration(milliseconds: 160),
                          child: PlayBubble(onTap: play, size: 40, playing: current && player.playing),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: current ? accentOf(context) : VyseColors.text)),
          const SizedBox(height: 2),
          Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
        ]);
      },
    );
  }
}

/// Square cover with a title and subtitle underneath (albums, playlists, genres).
class CoverTile extends StatelessWidget {
  const CoverTile({super.key, required this.title, required this.subtitle, required this.cover, required this.onTap, this.onPlay});
  final String title;
  final String subtitle;
  final String? cover;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Flexible so the square gives up a pixel or two rather than pushing the captions out.
      Flexible(
        child: AspectRatio(
          aspectRatio: 1,
          child: OutlineCard(
            label: title,
            radius: 10,
            onTap: onTap,
            builder: (hovered) => Stack(
              fit: StackFit.expand,
              children: [
                NetImage(url: cover, fallback: Icons.album_rounded),
                if (onPlay != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedSlide(
                      offset: Offset(0, hovered ? 0 : .3),
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: PlayBubble(onTap: onPlay!),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 2),
      Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint),
      ),
    ],
  );
}

/// Round amber play button.
class PlayBubble extends StatelessWidget {
  const PlayBubble({super.key, required this.onTap, this.size = 42, this.playing = false});
  final VoidCallback onTap;
  final double size;
  final bool playing;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : (hovered ? 1.06 : 1),
      duration: const Duration(milliseconds: 140),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [accentOf(context), accentHotOf(context)]),
          boxShadow: [BoxShadow(color: accentHotOf(context).withValues(alpha: .45), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: onAccentOf(context), size: size * .55),
      ),
    ),
  );
}

class ArtistTile extends StatelessWidget {
  const ArtistTile({super.key, required this.artist});
  final MusicArtist artist;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => openArtist(context, artist.id, artist.name),
    builder: (context, hovered, pressed) => Column(
      children: [
        Flexible(
          child: AnimatedScale(
            scale: pressed ? .95 : (hovered ? 1.05 : 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AspectRatio(
              aspectRatio: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: hovered ? Colors.white : Colors.white.withValues(alpha: .06), width: hovered ? 2 : 1),
                ),
                child: Artwork(url: artist.pictureUrl, circle: true),
              ),
            ),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          artist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : const Color(0xFFDADCE6)),
        ),
        if (artist.fanCount > 0)
          Text(
            '${fmtCompact(artist.fanCount)} fans',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, color: VyseColors.textFaint),
          ),
      ],
    ),
  );
}

/// Floating now-playing bar that follows you across tabs. Tap to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final t = p.current;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, .4), end: Offset.zero).animate(a),
              child: child,
            ),
          ),
          child: t == null
              ? const SizedBox.shrink()
              : Pressable(
                  key: const ValueKey('mini'),
                  onTap: () => openMusicPlayer(context),
                  builder: (context, hovered, _) => Glass(
                    radius: 16,
                    opacity: .8,
                    borderColor: hovered ? VyseColors.strokeHi : VyseColors.stroke,
                    child: SizedBox(
                      height: 64,
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                            child: Row(
                              children: [
                                Hero(
                                  tag: 'music/art',
                                  child: Artwork(url: t.coverUrl, size: 44, radius: 7),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                                      ),
                                      Text(
                                        p.error ?? t.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: p.error != null ? accentHotOf(context) : VyseColors.textDim,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                LikeButton(track: t, size: 19),
                                IconButton(
                                  tooltip: 'Previous',
                                  onPressed: p.previous,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  iconSize: 22,
                                ),
                                p.resolving || p.buffering
                                    ? SizedBox.square(
                                        dimension: 40,
                                        child: Padding(
                                          padding: EdgeInsets.all(10),
                                          child: CircularProgressIndicator(strokeWidth: 2, color: accentOf(context)),
                                        ),
                                      )
                                    : IconButton(
                                        tooltip: p.playing ? 'Pause' : 'Play',
                                        onPressed: p.toggle,
                                        icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                        iconSize: 28,
                                      ),
                                IconButton(tooltip: 'Next', onPressed: p.next, icon: const Icon(Icons.skip_next_rounded), iconSize: 22),
                                IconButton(
                                  tooltip: 'Close',
                                  onPressed: p.stop,
                                  icon: const Icon(Icons.close_rounded),
                                  iconSize: 18,
                                  color: VyseColors.textFaint,
                                ),
                              ],
                            ),
                          ),
                          Positioned(left: 0, right: 0, bottom: 0, child: _ThinProgress(player: p)),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _ThinProgress extends StatelessWidget {
  const _ThinProgress({required this.player});
  final MusicPlayer player;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Duration>(
    valueListenable: player.position,
    builder: (context, pos, _) {
      final total = player.duration.value.inMilliseconds;
      final f = total <= 0 ? 0.0 : (pos.inMilliseconds / total).clamp(0.0, 1.0);
      return Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: f,
          child: Container(height: 2, color: accentOf(context)),
        ),
      );
    },
  );
}
