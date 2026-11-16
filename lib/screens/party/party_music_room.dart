import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/music_player.dart';
import '../../data/party/party.dart';
import '../../data/party/party_music.dart';
import '../../data/party/rooms.dart';
import '../../data/party/voice.dart';
import '../../data/party/watch_party.dart';
import '../../models/music/music_track.dart';
import '../../services/music/music_service.dart';
import '../../widgets/common.dart';
import '../../widgets/music_widgets.dart';
import 'party_music_view.dart';
import 'party_strip.dart' show MicLeakPrompt;
import 'rooms_view.dart' show openRoom;
import 'party_widgets.dart' show dismissKeyboard;

void _say(BuildContext context, String text, {IconData icon = Icons.groups_rounded}) => showToast(
  context,
  Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  icon: icon,
);

/// Can you put music on for your room? Says why not when you can't.
bool _canHost(BuildContext context) {
  if (!Account.signedIn || !Party.joined) {
    _say(context, 'Sign in and join Party to listen together');
    return false;
  }
  if (Rooms.mine.value == null) {
    _say(context, 'Make or join a room in Party first: everyone in it listens with you');
    return false;
  }
  if (!WatchParty.canControl) {
    _say(context, "Only the room's host can put music on");
    return false;
  }
  return true;
}

/// Plays [t] for everyone in your room, and goes there.
Future<void> playInRoom(BuildContext context, MusicTrack t) async {
  if (!_canHost(context)) return;
  final nav = Navigator.of(context);
  try {
    await PartyMusic.play(t);
  } catch (e) {
    if (context.mounted) _say(context, Account.describe(e), icon: Icons.error_outline_rounded);
    return;
  }
  await openRoom(nav);
}

/// Shares what's playing now with your room, and goes there.
Future<void> shareMusicWithRoom(BuildContext context) async {
  if (!_canHost(context)) return;
  final nav = Navigator.of(context);
  try {
    await PartyMusic.host();
  } catch (e) {
    if (context.mounted) _say(context, Account.describe(e), icon: Icons.error_outline_rounded);
    return;
  }
  await openRoom(nav);
}

/// The room's music, live: the player in [PartyMusicView], fed by the real thing.
class PartyMusicRoom extends StatefulWidget {
  const PartyMusicRoom({super.key, required this.onExpand, this.full = false});
  final VoidCallback onExpand;
  final bool full;

  @override
  State<PartyMusicRoom> createState() => _PartyMusicRoomState();
}

class _PartyMusicRoomState extends State<PartyMusicRoom> {
  final _p = MusicPlayer.instance;
  final _roomClock = ValueNotifier(Duration.zero); // where the room is, for anyone not listening
  final _roomLength = ValueNotifier(Duration.zero);
  Timer? _clock;
  String? _lyricsFor;
  List<PartyLyric> _lyrics = const [];

  @override
  void initState() {
    super.initState();
    PartyMusic.join(); // opening the room is saying yes
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _clock?.cancel();
    _roomClock.dispose();
    _roomLength.dispose();
    super.dispose();
  }

  void _tick() {
    final s = WatchParty.state.value;
    if (s == null) return;
    _roomClock.value = Duration(milliseconds: (s.now * 1000).round());
    _roomLength.value = Duration(seconds: s.song?.seconds ?? 0);
  }

  /// Lyrics for the song you're hearing (once per song).
  void _loadLyrics(MusicTrack? t) {
    if (t == null || t.id == _lyricsFor) return;
    _lyricsFor = t.id;
    _lyrics = const [];
    _p.lyricsFor(t).then((d) {
      if (!mounted || _lyricsFor != t.id || !d.isSynced) return;
      setState(() => _lyrics = [for (final l in d.syncedLines) PartyLyric(l.timestamp, l.text)]);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([WatchParty.state, WatchParty.waiting, PartyMusic.listening, _p, Voice.speaking, Rooms.mine]),
    builder: (context, _) {
      final s = WatchParty.state.value;
      final song = s?.song;
      if (s == null || song == null) return const SizedBox.shrink();
      final room = Rooms.mine.value;
      final listening = PartyMusic.listening.value;
      final hearing = listening && _p.current?.id == song.id;
      if (hearing) _loadLyrics(_p.current);
      final host = s.mine ? '' : room?.members.where((m) => m.id == s.by).firstOrNull?.name ?? '';
      final view = PartyMusicView(
        song: song,
        position: hearing ? _p.position : _roomClock,
        duration: hearing ? _p.duration : _roomLength,
        playing: hearing ? _p.playing : s.playing,
        loading: listening && (_p.resolving || (hearing && _p.buffering)),
        host: host,
        listeners: [
          for (final m in room?.members ?? const <RoomMember>[])
            PartyListener(id: m.id, name: m.isMe ? 'You' : m.name, avatarUrl: m.avatarUrl, speaking: Voice.speaking.value.contains(m.id)),
        ],
        upNext: s.upNext,
        lyrics: hearing ? _lyrics : const [],
        canPlay: WatchParty.canCommand,
        canSkip: s.mine,
        listening: listening,
        waitingFor: [for (final w in WatchParty.waiting.value) w.name],
        full: widget.full,
        volume: _p.volume,
        onToggle: _p.toggle,
        onSeek: _p.seek,
        onNext: _p.next,
        onPrevious: _p.previous,
        onJoin: PartyMusic.join,
        onExpand: widget.onExpand,
        onStop: s.mine ? WatchParty.stop : null,
        onAdd: s.mine ? () => showPartyMusicPicker(context) : null,
        onVolume: _p.setVolume,
      );
      if (widget.full) {
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): widget.onExpand,
            const SingleActivator(LogicalKeyboardKey.space): _p.toggle,
          },
          child: Focus(autofocus: true, child: view),
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [view, const MicLeakPrompt()],
      );
    },
  );
}

/// Search for a song without leaving the room: tap to play it for everyone, + to queue it.
Future<void> showPartyMusicPicker(BuildContext context) {
  const body = _Picker();
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B0D16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => const FractionallySizedBox(heightFactor: .86, child: body),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (_) => Dialog(
      backgroundColor: const Color(0xFF0B0D16),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: VyseColors.stroke)),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620), child: body),
    ),
  );
}

class _Picker extends StatefulWidget {
  const _Picker();

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  final _text = TextEditingController();
  Timer? _debounce;
  Future<List<MusicTrack>>? _found;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 360), () {
      final query = q.trim();
      if (!mounted) return;
      setState(() => _found = query.isEmpty ? null : MusicService.instance.searchFull(query).then((d) => d.tracks));
    });
  }

  Future<void> _play(MusicTrack t) async {
    final nav = Navigator.of(context);
    try {
      await PartyMusic.play(t);
    } catch (e) {
      if (mounted) _say(context, Account.describe(e), icon: Icons.error_outline_rounded);
      return;
    }
    nav.pop();
  }

  void _queue(MusicTrack t) {
    MusicPlayer.instance.addToQueue(t);
    _say(context, 'Added to the room: ${t.title}', icon: Icons.queue_music_rounded);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Music for the room', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -.3)),
        const SizedBox(height: 12),
        TextField(
          onTapOutside: dismissKeyboard,
          controller: _text,
          autofocus: true,
          onChanged: _changed,
          style: const TextStyle(fontSize: 14.5),
          cursorColor: VyseColors.accent,
          decoration: InputDecoration(
            hintText: 'Search songs and artists',
            hintStyle: const TextStyle(color: VyseColors.textFaint),
            prefixIcon: const Icon(Icons.search_rounded, size: 20, color: VyseColors.textFaint),
            filled: true,
            fillColor: Colors.white.withValues(alpha: .06),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _found == null
              ? const Center(child: Text('Find something to play for everyone.', style: TextStyle(fontSize: 13, color: VyseColors.textDim)))
              : FutureBuilder<List<MusicTrack>>(
                  future: _found,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const Center(child: Text("Couldn't search right now.", style: TextStyle(fontSize: 13, color: VyseColors.textDim)));
                    }
                    final list = snap.data;
                    if (list == null) {
                      return const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)));
                    }
                    if (list.isEmpty) return const Center(child: Text('Nothing found.', style: TextStyle(fontSize: 13, color: VyseColors.textDim)));
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => _Found(track: list[i], onPlay: () => _play(list[i]), onQueue: () => _queue(list[i])),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _Found extends StatelessWidget {
  const _Found({required this.track, required this.onPlay, required this.onQueue});
  final MusicTrack track;
  final VoidCallback onPlay;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onPlay,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white.withValues(alpha: hovered ? .07 : 0)),
      child: Row(
        children: [
          Artwork(url: track.coverUrl, size: 46, radius: 8),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, letterSpacing: -.1)),
                const SizedBox(height: 1),
                Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ],
            ),
          ),
          Pressable(
            tooltip: 'Add to the queue',
            onTap: onQueue,
            builder: (context, h, _) => SizedBox.square(
              dimension: 40,
              child: Icon(Icons.playlist_add_rounded, size: 22, color: h ? Colors.white : VyseColors.textDim),
            ),
          ),
        ],
      ),
    ),
  );
}
