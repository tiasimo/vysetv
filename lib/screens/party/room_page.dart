import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/layout.dart';
import '../../core/nav.dart' show rootNavigatorKey;
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/anilist.dart';
import '../../data/party/alerts.dart' show PartyAlerts;
import '../../data/party/friends.dart';
import '../../data/party/party_live.dart';
import '../../data/party/rooms.dart';
import '../../data/party/voice.dart';
import '../../data/party/watch_party.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import '../../data/anime_sources.dart' show AnimeTarget;
import '../../data/tmdb.dart' show Media, episodeLabel;
import '../player_page.dart' show PlayerPage, PlayerEpisode, MiniPlayer;

import 'party_live_player.dart';
import 'party_music_room.dart';
import 'member_menu.dart';
import 'rooms_view.dart' show showRoomSizeDialog;
import 'party_strip.dart' show HoldToTalk;
import 'party_widgets.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

void _toast(BuildContext context, String text, {IconData icon = Icons.error_outline_rounded}) => showToast(
  context,
  Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  icon: icon,
);

/// The room you're in: its voice call, its watch party (playing right here, like a screen share),
/// owner tools and the chat. Being in the room means being in the call: this page connects it,
/// and Leave hangs up and leaves. Leaving this page keeps you in.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key});

  /// The watch party fills the window (full screen on desktop).
  static final theater = ValueNotifier<bool>(false);

  /// Room pages open anywhere (one per tab at most); only the newest plays the video.
  static final _open = <_RoomPageState>[];
  static final _openChanged = ValueNotifier<int>(0);

  static bool isOpenIn(NavigatorState nav) => _open.any((s) => s.mounted && s._nav == nav);

  // The watch party's player: one per title, and the same one wherever it shows. Its key moves
  // it between the tile, full screen and the small window over the app without a restart.
  static GlobalKey _playerKey = GlobalKey();
  static String? _playerFor;
  static ({Media media, PlayerEpisode? episode, AnimeTarget? anime})? _playing;

  /// The watch party in the small window over the app ([MiniPlayer.room]), with this page
  /// closed: the room is still yours, and so is the rest of the app.
  static Widget? miniPlayer() {
    final p = _playing;
    if (p == null) return null;
    return PlayerPage(
      key: _playerKey,
      media: p.media,
      episode: p.episode,
      party: true,
      embedded: true,
      anime: p.anime,
      mini: true,
      onRestore: restoreMini,
      onClose: () => MiniPlayer.room.value = false,
    );
  }

  /// Back from the small window: the room opens with the watch party filling the window, and
  /// takes its player back as it does.
  static void restoreMini() {
    theater.value = true;
    rootNavigatorKey.currentState?.popUntil((r) => r.isFirst); // a page over the app would hide it
    PartyAlerts.onOpen?.call('room');
  }

  @override
  State<RoomPage> createState() => _RoomPageState();
}

/// The room's watch party in the small window (the floating layer shows this while
/// [MiniPlayer.room] is on). It ends with the watch, and when the room moves on to another
/// title: that one starts on the room page.
class RoomMiniPlayer extends StatefulWidget {
  // Not const on purpose: the floating layer makes a new one every time it builds (a drag, a
  // resize), which is what gets the video underneath to report where it has moved to.
  // ignore: prefer_const_constructors_in_immutables
  RoomMiniPlayer({super.key});

  @override
  State<RoomMiniPlayer> createState() => _RoomMiniPlayerState();
}

class _RoomMiniPlayerState extends State<RoomMiniPlayer> {
  @override
  void initState() {
    super.initState();
    WatchParty.state.addListener(_watchChanged);
  }

  @override
  void dispose() {
    WatchParty.state.removeListener(_watchChanged);
    super.dispose();
  }

  void _watchChanged() {
    final s = WatchParty.state.value;
    if (s != null && !s.isMusic && !s.isLive && s.media.key == RoomPage._playerFor) return;
    MiniPlayer.room.value = false;
    if (s != null && !s.mine && mounted) {
      _toast(context, s.isMusic ? 'Music is on in your room now.' : '${s.media.title} is on in your room now. Open the room to watch together.', icon: Icons.groups_rounded);
    }
  }

  @override
  Widget build(BuildContext context) => RoomPage.miniPlayer() ?? const SizedBox.shrink();
}

/// A chat line, or "X joined" / "X left".
class _Line {
  const _Line.message(RoomMessage this.message) : note = null, at = null;
  _Line.note(String this.note) : message = null, at = DateTime.now();
  final RoomMessage? message;
  final String? note;
  final DateTime? at;
}

class _RoomPageState extends State<RoomPage> {
  final _lines = <_Line>[]; // oldest first
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  StreamSubscription<RoomMessage>? _sub;
  String? _roomId;
  Map<String, String> _people = {}; // id → name, to notice joins and leaves
  bool _sending = false;
  NavigatorState? _nav;
  WatchState? _watch; // what the video tile shows
  bool _full = false; // this page has the whole window for the video
  Anime? _anime; // an anime watch's AniList details, for its player
  int? _animeAsked;

  /// The watch's anime, once AniList has answered (asked once per title).
  Anime? _animeOf(Media m) {
    if (_anime?.id == m.id) return _anime;
    if (_animeAsked != m.id) {
      _animeAsked = m.id;
      AniList.details(m.id).then((a) {
        if (mounted && _animeAsked == a.id) setState(() => _anime = a);
      }, onError: (Object _) {});
    }
    return null;
  }

  bool get _active => RoomPage._open.isNotEmpty && identical(RoomPage._open.last, this);

  @override
  void initState() {
    super.initState();
    Rooms.mine.addListener(_roomChanged);
    WatchParty.state.addListener(_watchChanged);
    RoomPage.theater.addListener(_syncTheater);
    RoomPage._openChanged.addListener(_syncTheater);
    MiniPlayer.room.addListener(_syncTheater);
    RoomPage._open.add(this);
    PartyAlerts.roomChatsOpen++; // its chat is on screen: no sound for it
    _tellOthers();
    _watch = WatchParty.state.value;
    hideBottomBar.value++; // phones: the room gets the whole screen
    _sub = Rooms.messages.listen((m) {
      if (_lines.any((l) => l.message?.id == m.id) || Friends.lists.value.blockedIds.contains(m.user)) return;
      setState(() => _lines.add(_Line.message(m)));
      _toBottom();
    });
    _roomChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Voice.state.value == VoiceState.off && Rooms.mine.value != null) _joinVoice();
      // the room is on screen again: its watch party comes back from the small window
      if (mounted) MiniPlayer.room.value = false;
      _syncTheater();
    });
  }

  bool _minimized = false; // the player left for the small window from here: this page is closing

  /// The watch party carries on in the small window over the app, and this page closes.
  void _minimize() {
    _minimized = true;
    RoomPage.theater.value = false;
    MiniPlayer.session.value = null; // one video at a time
    MiniPlayer.room.value = true;
    Navigator.of(context).maybePop().then((left) {
      if (!left && mounted) setState(() => _minimized = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _nav = Navigator.maybeOf(context);
  }

  static void _tellOthers() => WidgetsBinding.instance.addPostFrameCallback((_) => RoomPage._openChanged.value++);

  Future<void> _joinVoice() async {
    try {
      await Voice.join();
    } catch (e) {
      if (mounted) _toast(context, "Couldn't connect to the room's voice: ${Account.describe(e)}");
    }
  }

  /// A new title (or none) in the room: the tile follows; full screen ends with the watch.
  void _watchChanged() {
    final s = WatchParty.state.value, was = _watch;
    _watch = s;
    if (s == null && RoomPage.theater.value) RoomPage.theater.value = false;
    if ((s == null) != (was == null) || (s != null && !s.sameTitle(was))) {
      _syncTheater();
    }
  }

  /// Takes the whole window for the video, or gives it back.
  void _syncTheater() {
    final want = RoomPage.theater.value && _watch != null && _active && mounted;
    if (want != _full) {
      _full = want;
      fullWindow.value += want ? 1 : -1;
      if (isDesktopNative) unawaited(windowManager.setFullScreen(want));
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Rooms.mine.removeListener(_roomChanged);
    WatchParty.state.removeListener(_watchChanged);
    RoomPage.theater.removeListener(_syncTheater);
    RoomPage._openChanged.removeListener(_syncTheater);
    MiniPlayer.room.removeListener(_syncTheater);
    RoomPage._open.remove(this);
    final full = _full;
    if (full && isDesktopNative) unawaited(windowManager.setFullScreen(false));
    // after this frame: the tree is locked while pages are being taken down
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (full) fullWindow.value--;
      if (RoomPage._open.isEmpty) RoomPage.theater.value = false;
    });
    _tellOthers();
    PartyAlerts.roomChatsOpen--;
    hideBottomBar.value--;
    _sub?.cancel();
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _roomChanged() {
    final room = Rooms.mine.value;
    if (room == null) {
      if (mounted) setState(() {});
      return;
    }
    if (room.id != _roomId) {
      _roomId = room.id;
      _people = {for (final m in room.members) m.id: m.name};
      _lines.clear();
      Rooms.history(room.id).then((list) {
        if (!mounted || _roomId != room.id) return;
        final blocked = Friends.lists.value.blockedIds;
        setState(() => _lines.insertAll(0, list.where((m) => !blocked.contains(m.user)).map(_Line.message)));
        _toBottom();
      }, onError: (Object _) {});
    } else {
      final now = {for (final m in room.members) m.id: m.name};
      for (final e in now.entries) {
        if (!_people.containsKey(e.key)) _lines.add(_Line.note('${e.value} joined'));
      }
      for (final e in _people.entries) {
        if (!now.containsKey(e.key)) _lines.add(_Line.note('${e.value} left'));
      }
      _people = now;
    }
    if (mounted) setState(() {});
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await Rooms.send(text);
      _input.clear();
      if (mounted && !_lines.any((l) => l.message?.id == m.id)) {
        setState(() => _lines.add(_Line.message(m)));
        _toBottom();
      }
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    } finally {
      if (mounted) setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  Future<void> _leave() async {
    try {
      await Rooms.leave();
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  Future<void> _manage(Map<String, dynamic> body, {String? done}) async {
    try {
      await Rooms.manage(body);
      if (mounted && done != null) _toast(context, done, icon: Icons.check_circle_rounded);
    } catch (e) {
      if (mounted) _toast(context, Account.describe(e));
    }
  }

  Future<void> _edit(PartyRoom room) async {
    final name = TextEditingController(text: room.name);
    final topic = TextEditingController(text: room.topic);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Edit room', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onTapOutside: dismissKeyboard,
                controller: name,
                maxLength: 40,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                onTapOutside: dismissKeyboard,
                controller: topic,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Topic'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) await _manage({'name': name.text.trim(), 'topic': topic.text.trim()});
    name.dispose();
    topic.dispose();
  }

  Future<void> _kick(RoomMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101118),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Remove ${m.name}?', style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Text("They can't come back for 10 minutes.", style: TextStyle(color: VyseColors.textDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: VyseColors.text)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok == true) await _manage({'kick': m.id});
  }

  @override
  Widget build(BuildContext context) {
    final room = Rooms.mine.value;
    final phone = Layout.isPhone(context);
    final side = phone ? 12.0 : Layout.inset(context);
    if (room == null) {
      return Material(
        color: VyseColors.bg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.meeting_room_outlined, size: 40, color: VyseColors.textFaint),
              const SizedBox(height: 12),
              const Text("You're not in a room.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              PartyChipButton(icon: Icons.arrow_back_rounded, label: 'Back to Party', onTap: () => Navigator.of(context).maybePop()),
            ],
          ),
        ),
      );
    }
    // the watch party's player: one per title, kept while it moves between the tile and full screen
    final s = _watch;
    Widget? video;
    if (s != null && !s.isMusic && _active) {
      final id = s.media.key;
      if (id != RoomPage._playerFor) {
        RoomPage._playerFor = id;
        RoomPage._playerKey = GlobalKey();
        RoomPage._playing = null;
      }
      final a = s.media.anime ? _animeOf(s.media) : null;
      if (s.isLive) {
        video = PartyLivePlayer(
          key: RoomPage._playerKey,
          url: PartyLive.urlFor(s),
          title: s.media.title,
          full: _full,
          onExpand: () => RoomPage.theater.value = !RoomPage.theater.value,
        );
      } else
      // an anime plays from the anime servers, once AniList has given its details
      if (!s.media.anime || a != null) {
        // kept for the small window, which shows this same player when it's minimized
        final p = RoomPage._playing = (
          media: a?.media ?? s.media,
          episode: s.season != null && s.episode != null ? PlayerEpisode(season: s.season!, number: s.episode!, name: s.episodeName) : null,
          anime: a == null ? null : AnimeTarget(a, episodes: a.aired ?? a.episodes),
        );
        // minimized: it plays in the small window over the app, not here
        if (!MiniPlayer.room.value && !_minimized) {
          video = PlayerPage(
            key: RoomPage._playerKey,
            media: p.media,
            episode: p.episode,
            party: true,
            embedded: true,
            expanded: _full,
            onExpand: () => RoomPage.theater.value = !RoomPage.theater.value,
            anime: p.anime,
            onMinimize: _minimize,
          );
        }
      }
    }
    if (_full && video != null) return Material(color: Colors.black, child: video);
    if (_full && s != null && s.isMusic) {
      return Material(
        color: Colors.black,
        child: PartyMusicRoom(full: true, onExpand: () => RoomPage.theater.value = false),
      );
    }

    // the call's controls: built here, so they can stay put while the people above them scroll
    final bar = _VoiceBar(onJoin: _joinVoice, onLeave: _leave, silenced: room.members.any((m) => m.isMe && m.silenced));
    Widget stageFor({bool typing = false, bool compact = false, double? videoHeight}) => _Stage(
      room: room,
      watch: s,
      video: video,
      typing: typing,
      compact: compact,
      showBar: false,
      videoHeight: videoHeight,
      onKick: _kick,
      onOwner: (m) => _manage({'owner': m.id}, done: '${m.name} owns the room now'),
      onSilence: (m, on) => _manage({on ? 'mute' : 'unmute': m.id}, done: on ? '${m.name} is muted for everyone' : '${m.name} can talk again'),
      onControl: (m, on) =>
          _manage({on ? 'allow' : 'disallow': m.id}, done: on ? '${m.name} can play and pause for everyone now' : '${m.name} can no longer play or pause'),
      onJoinVoice: _joinVoice,
      onLeave: _leave,
    );
    // with an on-screen keyboard the box waits for a tap: opening a room shouldn't cover half of it
    final chat = _Chat(lines: _lines, scroll: _scroll, input: _input, focus: _focus, sending: _sending, onSend: _send, autofocus: !phone && !hasSoftKeyboard);
    return Material(
      color: VyseColors.bg,
      // The page is laid out for the room it really has: the window's, less the keyboard.
      child: LayoutBuilder(
        builder: (context, page) {
          // the keyboard is up (read from the window itself: the shell has already taken its
          // height out of this page, which is what makes this builder run again)
          final typing = View.of(context).viewInsets.bottom > 0;
          // Side by side when there's width for both. A phone on its side counts: it has the
          // width, and no height to stack them.
          final beside = !phone || (page.maxWidth >= 520 && page.maxHeight < 480);
          // hardly any height left (a phone on its side with the keyboard up): the chat alone
          final cramped = page.maxHeight < 250;
          if (cramped) return SafeArea(bottom: false, child: chat);
          return Column(
            children: [
              _Header(room: room, side: side, onEdit: () => _edit(room), onManage: _manage),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    if (beside) {
                      final chatWidth = (c.maxWidth * .38).clamp(250.0, 380.0);
                      // not much height (a phone on its side, a small window): the people as a strip
                      final short = c.maxHeight < 520;
                      final right = phone || short ? 12.0 : 24.0;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    padding: EdgeInsets.fromLTRB(side, short ? 12 : 22, right, 12),
                                    child: stageFor(compact: short),
                                  ),
                                ),
                                Padding(padding: EdgeInsets.fromLTRB(side, 0, right, short ? 10 : 18), child: bar),
                              ],
                            ),
                          ),
                          Container(
                            width: chatWidth,
                            decoration: BoxDecoration(
                              border: Border(left: BorderSide(color: VyseColors.stroke)),
                            ),
                            child: chat,
                          ),
                        ],
                      );
                    }
                    // Stacked (a phone held upright). The chat always keeps room for its box and
                    // a few messages; the stage above takes the rest and scrolls if it's taller.
                    // While typing the stage shrinks to the call's controls (and the video).
                    final video = s != null && !s.isMusic;
                    // typing with something on: the video and the chat; otherwise the controls stay
                    final showBar = !(typing && video);
                    final showStage = !typing || video;
                    final barRoom = !showBar ? 0.0 : (Voice.state.value == VoiceState.on && Voice.pushToTalk.value ? 124.0 : 74.0);
                    final stageMax = math.max(0.0, c.maxHeight - barRoom - (typing ? 140 : 170));
                    return Column(
                      children: [
                        if (showStage)
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: stageMax),
                            child: SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(side, typing ? 8 : 12, side, showBar ? 10 : 8),
                              child: stageFor(typing: typing, videoHeight: typing ? math.max(120.0, stageMax - 16) : null),
                            ),
                          ),
                        if (showBar) Padding(padding: EdgeInsets.fromLTRB(side, showStage ? 0 : 8, side, 8), child: bar),
                        Divider(height: 1, color: VyseColors.stroke),
                        Expanded(child: chat),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.room, required this.side, required this.onEdit, required this.onManage});
  final PartyRoom room;
  final double side;
  final VoidCallback onEdit;
  final Future<void> Function(Map<String, dynamic> body, {String? done}) onManage;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(side - 8, Layout.windowChrome(context) + 10, pageRight(context), 12),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: VyseColors.stroke)),
    ),
    // One row at every width: Back, the room's name and topic (which give way first), then the
    // invite code and the owner's settings.
    child: LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 520;
        return Row(
          children: [
            if (Navigator.of(context).canPop())
              IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.arrow_back_rounded, color: VyseColors.textDim),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: narrow ? 17 : 20, fontWeight: FontWeight.w900),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(room.private ? Icons.lock_rounded : Icons.public_rounded, size: 16, color: VyseColors.textDim),
                      const SizedBox(width: 8),
                      Text(
                        '${room.size}/${room.limit}',
                        style: TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  if (room.topic.isNotEmpty)
                    Text(
                      room.topic,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: VyseColors.textDim),
                    ),
                ],
              ),
            ),
            if (room.private && room.code.isNotEmpty) ...[
              const SizedBox(width: 8),
              Pressable(
                tooltip: 'Copy invite code',
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: room.code));
                  if (context.mounted) _toast(context, 'Invite code copied', icon: Icons.check_circle_rounded);
                },
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: EdgeInsets.symmetric(horizontal: narrow ? 10 : 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: hovered ? .12 : .07),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.vpn_key_outlined, size: 15, color: VyseColors.textDim),
                      SizedBox(width: narrow ? 6 : 8),
                      Text(room.code, style: TextStyle(fontSize: narrow ? 13 : 14, fontWeight: FontWeight.w800, letterSpacing: narrow ? 1.2 : 2.5)),
                      if (!narrow) ...[const SizedBox(width: 8), Icon(Icons.copy_rounded, size: 14, color: VyseColors.textFaint)],
                    ],
                  ),
                ),
              ),
            ],
            if (room.iOwn)
              PopupMenuButton<String>(
                tooltip: 'Room settings',
                color: VyseColors.surfaceHi,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                icon: Icon(Icons.tune_rounded, color: VyseColors.textDim),
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      onEdit();
                    case 'public':
                      onManage({'visibility': 'public'}, done: 'The room is public now');
                    case 'private':
                      onManage({'visibility': 'private'}, done: 'The room is private; share the invite code');
                    case 'code':
                      onManage({'newCode': true}, done: 'New invite code made; the old one stopped working');
                    case 'size':
                      showRoomSizeDialog(context, room).then((n) {
                        if (n != null && n != room.limit) onManage({'limit': n}, done: 'Up to $n people now');
                      });
                    case 'controls-owner':
                      onManage({'controls': 'owner'}, done: 'Only you and the people you pick control the watch party now');
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit name and topic')),
                  PopupMenuItem(value: 'size', child: Text('Room size (up to ${room.limit})')),
                  room.private
                      ? const PopupMenuItem(value: 'public', child: Text('Make public'))
                      : const PopupMenuItem(value: 'private', child: Text('Make private')),
                  if (room.private) const PopupMenuItem(value: 'code', child: Text('New invite code')),
                  // rooms from before per-person control: anyone could play/pause
                  if (room.everyoneControls) const PopupMenuItem(value: 'controls-owner', child: Text("Stop letting everyone play/pause")),
                ],
              ),
          ],
        );
      },
    ),
  );
}

/// Who's here, Discord-style: the watch party's video as the big tile (like a screen share) when
/// something's on, one tile per person (lit up while they talk), the voice controls, and the
/// owner's tools.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.room,
    required this.watch,
    required this.video,
    required this.onKick,
    required this.onOwner,
    required this.onSilence,
    required this.onControl,
    required this.onJoinVoice,
    required this.onLeave,
    this.typing = false,
    this.compact = false,
    this.showBar = true,
    this.videoHeight,
  });
  final PartyRoom room;
  final WatchState? watch;
  final Widget? video;

  /// A phone with its keyboard up: only the call's controls (and the video) stay, so the chat
  /// has the room.
  final bool typing;

  /// The people as a strip, as on a phone, wherever height is short (a phone on its side).
  final bool compact;

  /// Whether the call's controls are part of it (the room page keeps them outside, pinned).
  final bool showBar;

  /// The most the video may take then.
  final double? videoHeight;
  final ValueChanged<RoomMember> onKick;
  final ValueChanged<RoomMember> onOwner;
  final void Function(RoomMember m, bool on) onSilence;
  final void Function(RoomMember m, bool on) onControl;
  final VoidCallback onJoinVoice;
  final Future<void> Function() onLeave;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Voice.state, Voice.speaking, Voice.inCall]),
    builder: (context, _) {
      final phone = compact || Layout.isPhone(context);
      final live = Voice.state.value == VoiceState.on;
      final watching = watch != null;
      final tiles = [
        for (final m in room.members)
          _Tile(
            member: m,
            speaking: Voice.speaking.value.contains(m.id),
            inVoice: live ? Voice.inCall.value.containsKey(m.id) : null,
            micOn: Voice.inCall.value[m.id] ?? false,
            ownerTools: room.iOwn && !m.isMe,
            small: watching,
            compact: phone,
            onKick: () => onKick(m),
            onOwner: () => onOwner(m),
            onSilence: (on) => onSilence(m, on),
            onControl: (on) => onControl(m, on),
          ),
        if (!watching)
          for (var i = room.size; i < room.limit; i++) const _EmptySeat(),
      ];
      final bar = _VoiceBar(onJoin: onJoinVoice, onLeave: onLeave, silenced: room.members.any((m) => m.isMe && m.silenced));
      final Widget screen = watching
          ? (watch!.isMusic
                ? PartyMusicRoom(onExpand: () => RoomPage.theater.value = true)
                : _WatchTile(state: watch!, video: video, host: WatchParty.canControl, maxVideoHeight: videoHeight, bare: typing))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PartyNote(
                  icon: Icons.movie_outlined,
                  text: room.iOwn
                      ? 'Watch or listen together: play any film, show or song and it plays right here for everyone, in sync.'
                      : "When the room's owner plays something, it shows up right here.",
                ),
              ],
            );
      if (phone && typing) {
        // the video if there is one, otherwise the call's controls: the chat has the rest
        return watching && !watch!.isMusic ? screen : (showBar ? bar : const SizedBox.shrink());
      }
      if (phone) {
        return Column(
          children: [
            if (watching) ...[screen, const SizedBox(height: 10)],
            SizedBox(
              height: watching ? 84 : 112,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final t in tiles)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: SizedBox(width: watching ? 76 : 96, child: t),
                    ),
                ],
              ),
            ),
            if (showBar) ...[const SizedBox(height: 10), bar],
            if (!watching) ...[const SizedBox(height: 10), screen],
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (watching) ...[screen, const SizedBox(height: 14)],
          LayoutBuilder(
            builder: (context, c) {
              if (watching) {
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [for (final t in tiles) SizedBox(width: 132, height: 112, child: t)],
                );
              }
              // bigger rooms: four across and a little shorter, so 10 seats still fit
              final big = room.limit > 6;
              final cols = c.maxWidth > 760 ? (big ? 4 : 3) : 2;
              final w = (c.maxWidth - (cols - 1) * 14) / cols;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [for (final t in tiles) SizedBox(width: w, height: big ? 140 : 170, child: t)],
              );
            },
          ),
          if (showBar) ...[const SizedBox(height: 16), bar],
          if (!watching) ...[const SizedBox(height: 16), screen],
        ],
      );
    },
  );
}

/// The call: mic, deafen, devices, and Leave (which leaves the room: the room is its call).
class _VoiceBar extends StatelessWidget {
  const _VoiceBar({required this.onJoin, required this.onLeave, required this.silenced});
  final VoidCallback onJoin; // reconnect after the call dropped
  final Future<void> Function() onLeave;
  final bool silenced; // the owner muted you

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Voice.state, Voice.micOn, Voice.deafened, Voice.pushToTalk, Voice.talking, Voice.pttKey]),
    builder: (context, _) {
      final state = Voice.state.value;
      final phone = Layout.isPhone(context);
      final on = state == VoiceState.on;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: partyCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: VyseColors.stroke),
        ),
        // Laid out for the width the bar really has (a phone, a narrow window, the strip beside
        // the chat), not for the window's: the buttons always fit, and the words give way.
        child: LayoutBuilder(
          builder: (context, c) {
            final labels = c.maxWidth >= 560; // room to name the buttons
            final ptt = on && Voice.pushToTalk.value;
            // the hold-to-talk button gets a row of its own (and a bigger target) when the bar is narrow
            final pttBelow = ptt && c.maxWidth < 520;
            final controls = <Widget>[
              if (state == VoiceState.off)
                PartyChipButton(icon: Icons.refresh_rounded, label: 'Reconnect', primary: true, onTap: onJoin)
              else if (state == VoiceState.connecting)
                SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))
              else ...[
                if (ptt) ...[if (!pttBelow) const HoldToTalk()] else
                  _RoundToggle(
                    icon: Voice.micOn.value ? Icons.mic_rounded : Icons.mic_off_rounded,
                    tooltip: Voice.micOn.value ? 'Mute' : 'Unmute',
                    label: labels ? (Voice.micOn.value ? 'Mute' : 'Unmute') : null,
                    off: !Voice.micOn.value,
                    onTap: Voice.toggleMic,
                  ),
                if (!pttBelow) const SizedBox(width: 6),
                _RoundToggle(
                  icon: Voice.deafened.value ? Icons.headset_off_rounded : Icons.headset_rounded,
                  tooltip: Voice.deafened.value ? 'Undeafen' : 'Deafen',
                  label: labels ? (Voice.deafened.value ? 'Undeafen' : 'Deafen') : null,
                  off: Voice.deafened.value,
                  onTap: Voice.toggleDeafen,
                ),
                const SizedBox(width: 6),
                _RoundToggle(icon: Icons.settings_rounded, tooltip: 'Voice settings (microphone, speakers, push to talk)', onTap: () => _devices(context)),
              ],
              const SizedBox(width: 6),
              _RoundToggle(icon: Icons.call_end_rounded, tooltip: 'Leave the room', label: labels ? 'Leave' : null, danger: true, onTap: onLeave),
            ];
            final status = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // one line each, cut short when the bar is narrow: never a letter per line
                Text(
                  switch (state) {
                    VoiceState.on => labels ? 'Voice connected' : 'Connected',
                    VoiceState.connecting => 'Connecting…',
                    VoiceState.off => 'Not connected',
                  },
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: on ? const Color(0xFF3DDC97) : VyseColors.text),
                ),
                Text(
                  silenced
                      ? 'The owner muted you'
                      : switch (state) {
                          VoiceState.on when Voice.deafened.value => 'Deafened',
                          VoiceState.on when Voice.pushToTalk.value =>
                            Voice.talking.value ? 'Talking' : (phone || hasSoftKeyboard ? 'Hold the talk button' : 'Hold ${keyName(Voice.pttKey.value)} to talk'),
                          VoiceState.on => Voice.micOn.value ? 'Mic on' : 'Mic off',
                          VoiceState.connecting => 'Joining the call',
                          VoiceState.off => labels ? "Reconnect to stay in the room (you're taken out after a minute)" : 'Reconnect to stay in',
                        },
                  maxLines: labels ? 2 : 1,
                  softWrap: labels,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: silenced ? const Color(0xFFFF8A8C) : VyseColors.textDim),
                ),
              ],
            );
            final row = Row(
              children: [
                // a very narrow bar keeps the words rather than the picture
                if (c.maxWidth >= 300) ...[
                  Icon(
                    on ? Icons.graphic_eq_rounded : Icons.headset_off_rounded,
                    color: on ? const Color(0xFF3DDC97) : VyseColors.textFaint,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(child: status),
                const SizedBox(width: 6),
                ...controls,
              ],
            );
            if (!pttBelow) return row;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row,
                const SizedBox(height: 10),
                const SizedBox(width: double.infinity, child: HoldToTalk()),
              ],
            );
          },
        ),
      );
    },
  );

  Future<void> _devices(BuildContext context) async {
    final ins = await Voice.inputs();
    final outs = await Voice.outputs();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: VyseColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Voice settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: Voice.pushToTalk.value,
                    activeThumbColor: VyseColors.accent,
                    title: const Text('Push to talk', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      'Your mic only sends while you hold the key or the talk button. Best without headphones, so the movie stays out of your mic.',
                      style: TextStyle(fontSize: 12, color: VyseColors.textDim),
                    ),
                    onChanged: (v) async {
                      await Voice.setPushToTalk(v);
                      setState(() {});
                    },
                  ),
                  if (Voice.pushToTalk.value && !Layout.isPhone(context))
                    Row(
                      children: [
                        const Expanded(
                          child: Text('Push-to-talk key', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: .08), borderRadius: BorderRadius.circular(8)),
                          child: Text(keyName(Voice.pttKey.value), style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () async {
                            final k = await _askKey(ctx);
                            if (k != null) await Voice.setPushToTalk(true, key: k);
                            setState(() {});
                          },
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                  Divider(color: VyseColors.stroke),
                  for (final (label, list, current, use) in [
                    ('Microphone', ins, Voice.inputId, Voice.useInput),
                    ('Speakers / headphones', outs, Voice.outputId, Voice.useOutput),
                  ]) ...[
                    Text(
                      label,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.textDim),
                    ),
                    const SizedBox(height: 6),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: list.any((d) => d.deviceId == current) ? current : (list.isEmpty ? null : list.first.deviceId),
                      dropdownColor: VyseColors.surfaceHi,
                      items: [
                        for (final d in list)
                          DropdownMenuItem(
                            value: d.deviceId,
                            child: Text(d.label.isEmpty ? 'Default' : d.label, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (id) async {
                        final d = list.where((x) => x.deviceId == id).firstOrNull;
                        if (d != null) await use(d);
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  Divider(color: VyseColors.stroke),
                  for (final (label, hint, value, set) in [
                    (
                      'Noise suppression',
                      'Less background noise. Off sounds more natural on a good mic.',
                      Voice.noiseSuppression.value,
                      (bool v) => Voice.setProcessing(noise: v),
                    ),
                    (
                      'Echo cancellation',
                      'Stops your speakers from coming back through your mic.',
                      Voice.echoCancellation.value,
                      (bool v) => Voice.setProcessing(echo: v),
                    ),
                    ('Automatic volume', 'Evens out how loud you are.', Voice.autoGain.value, (bool v) => Voice.setProcessing(gain: v)),
                  ])
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: value,
                      activeThumbColor: VyseColors.accent,
                      title: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      subtitle: Text(hint, style: TextStyle(fontSize: 12, color: VyseColors.textDim)),
                      onChanged: (v) async {
                        await set(v);
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      ),
    );
  }
}

class _RoundToggle extends StatelessWidget {
  const _RoundToggle({required this.icon, required this.tooltip, required this.onTap, this.off = false, this.danger = false, this.label});
  final IconData icon;
  final String tooltip;
  final Future<void> Function() onTap;
  final bool off; // shown red: muted / deafened
  final bool danger;
  final String? label; // written next to the icon, so similar icons can't be mixed up

  @override
  Widget build(BuildContext context) {
    final red = danger || off;
    final fg = red ? const Color(0xFFFF8A8C) : VyseColors.text;
    return Pressable(
      tooltip: label == null ? tooltip : null,
      onTap: () => unawaited(onTap()),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 40,
        width: label == null ? 40 : null,
        padding: label == null ? null : const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: red ? const Color(0xFFFF4D4F).withValues(alpha: hovered ? .3 : .18) : Colors.white.withValues(alpha: hovered ? .14 : .08),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: fg),
            if (label != null) ...[
              const SizedBox(width: 7),
              Text(
                label!,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.member,
    required this.speaking,
    required this.inVoice,
    required this.micOn,
    required this.ownerTools,
    required this.onKick,
    required this.onOwner,
    required this.onSilence,
    required this.onControl,
    this.small = false,
    this.compact = false,
  });
  final RoomMember member;
  final bool speaking;
  final bool? inVoice; // null while you aren't in the call yourself
  final bool micOn;
  final bool ownerTools;
  final bool small; // next to the watch party's video
  final bool compact; // in the strip of people (a phone, or any short window)
  final VoidCallback onKick;
  final VoidCallback onOwner;
  final ValueChanged<bool> onSilence;
  final ValueChanged<bool> onControl; // let them play/pause the watch party, or not

  void _menu(BuildContext context) => showMemberMenu(
    context,
    member,
    ownerTools: ownerTools,
    onKick: onKick,
    onOwner: onOwner,
    onSilence: onSilence,
    onControl: onControl,
  );

  @override
  Widget build(BuildContext context) {
    final m = member;
    final narrow = compact || Layout.isPhone(context);
    final phone = narrow || small;
    final size = small ? (narrow ? 40.0 : 52.0) : (phone ? 52.0 : 76.0);
    final away = inVoice == false; // in the room, not in the call (yet)
    return Pressable(
      // someone else: their volume and options (their profile is a tap away in there)
      onTap: () => m.isMe ? showPartyProfile(context, m.id) : _menu(context),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovered ? .07 : .04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: speaking ? const Color(0xFF3DDC97).withValues(alpha: .7) : VyseColors.stroke, width: speaking ? 1.5 : 1),
        ),
        child: Stack(
          children: [
            Center(
              child: Opacity(
                opacity: away ? .45 : 1,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // green ring while they talk
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: speaking ? const Color(0xFF3DDC97) : Colors.transparent, width: 3),
                        boxShadow: [if (speaking) BoxShadow(color: const Color(0xFF3DDC97).withValues(alpha: .45), blurRadius: 18)],
                      ),
                      child: PartyAvatar(url: m.avatarUrl, name: m.name, size: size, presence: m.presence, ring: const Color(0xFF12141E)),
                    ),
                    SizedBox(height: phone ? 4 : 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.owner) ...[const Icon(Icons.workspace_premium_rounded, size: 15, color: VyseColors.star), const SizedBox(width: 4)],
                        if (m.controls && !m.owner)
                          Tooltip(
                            message: 'Can play and pause for everyone',
                            child: Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.smart_display_rounded, size: 14, color: VyseColors.accent)),
                          ),
                        Flexible(
                          child: Text(
                            m.isMe ? '${m.name} (you)' : m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: phone ? 12 : 14, fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (m.silenced || (inVoice == true && !micOn)) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.mic_off_rounded, size: 14, color: m.silenced ? const Color(0xFFFF8A8C) : VyseColors.textFaint),
                        ],
                      ],
                    ),
                    if (away && !phone)
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text('connecting…', style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
                      ),
                  ],
                ),
              ),
            ),
            if (!m.isMe)
              Positioned(
                top: 6,
                right: 6,
                child: Pressable(
                  tooltip: 'Volume and more',
                  onTap: () => _menu(context),
                  builder: (context, hovered, _) => Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: hovered ? .12 : .06)),
                    child: Icon(Icons.more_horiz_rounded, size: 18, color: hovered ? VyseColors.text : VyseColors.textDim),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptySeat extends StatelessWidget {
  const _EmptySeat();

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .05)),
    ),
    child: const Center(child: Icon(Icons.person_add_alt_outlined, size: 22, color: Color(0x22FFFFFF))),
  );
}

class _Chat extends StatelessWidget {
  const _Chat({
    required this.lines,
    required this.scroll,
    required this.input,
    required this.focus,
    required this.sending,
    required this.onSend,
    required this.autofocus,
  });
  final List<_Line> lines; // oldest first
  final ScrollController scroll;
  final TextEditingController input;
  final FocusNode focus;
  final bool sending;
  final VoidCallback onSend;
  final bool autofocus;

  static Future<void> _messageMenu(BuildContext context, RoomMessage m, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      color: VyseColors.surfaceHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        if (!m.mine)
          const PopupMenuItem(
            value: 'report',
            child: Text('Report', style: TextStyle(color: Color(0xFFFF8A8C))),
          ),
      ],
    );
    if (v == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.body));
    } else if (v == 'report' && context.mounted) {
      await showReportDialog(context, userId: m.user, name: m.name, kind: 'room_message', ref: m.id);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: ListView.builder(
          controller: scroll,
          reverse: true,
          // dragging the messages puts the keyboard away, as chats do
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          itemCount: lines.length + 1,
          itemBuilder: (context, i) {
            if (i == lines.length) {
              return Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text('Room chat. It disappears when the room closes.', style: TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
              );
            }
            final idx = lines.length - 1 - i;
            final line = lines[idx];
            if (line.note != null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.arrow_right_alt_rounded, size: 16, color: VyseColors.textFaint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        line.note!,
                        style: TextStyle(fontSize: 12.5, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
            }
            final m = line.message!;
            final prev = idx > 0 ? lines[idx - 1].message : null;
            final first = prev == null || prev.user != m.user || m.created.difference(prev.created) > const Duration(minutes: 5);
            // right-click or long-press: copy, or report someone else's message
            return GestureDetector(
              onSecondaryTapDown: (d) => _messageMenu(context, m, d.globalPosition),
              onLongPressStart: (d) => _messageMenu(context, m, d.globalPosition),
              child: Padding(
                padding: EdgeInsets.only(top: first ? 12 : 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 38,
                      child: first ? PartyAvatar(url: m.avatarUrl, name: m.name, size: 34) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (first)
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    m.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: m.mine ? VyseColors.accent : VyseColors.text),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(_clock(m.created), style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
                              ],
                            ),
                          Text(m.body, style: const TextStyle(fontSize: 14, height: 1.4)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(12, 6, 12, 12 + MediaQuery.paddingOf(context).bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
          decoration: BoxDecoration(
            color: partyCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: VyseColors.stroke),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.enter): onSend},
                  child: TextField(
                    controller: input,
                    focusNode: focus,
                    autofocus: autofocus,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    // a phone's keyboard has its own Send key; sending keeps it up for the next message
                    textInputAction: hasSoftKeyboard ? TextInputAction.send : TextInputAction.newline,
                    onEditingComplete: hasSoftKeyboard ? () {} : null,
                    onSubmitted: hasSoftKeyboard ? (_) => onSend() : null,
                    onTapOutside: dismissKeyboard,
                    style: const TextStyle(fontSize: 14, height: 1.35),
                    cursorColor: VyseColors.accent,
                    decoration: InputDecoration(
                      counterText: '',
                      border: InputBorder.none,
                      hintText: 'Message the room',
                      hintStyle: TextStyle(color: VyseColors.textFaint),
                    ),
                  ),
                ),
              ),
              // part of the text box as far as taps go: pressing Send leaves the keyboard up
              TextFieldTapRegion(
                child: IconButton(
                  tooltip: 'Send',
                  onPressed: sending ? null : onSend,
                  icon: sending
                      ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))
                      : Icon(Icons.send_rounded, color: VyseColors.accent, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// The room's watch party: what's on and where the host is, with Join; for the host, Stop.
/// The watch party playing right here, like a screen share: the video, what's on, full screen,
/// and Stop for the host.
class _WatchTile extends StatelessWidget {
  const _WatchTile({required this.state, required this.video, required this.host, this.maxVideoHeight, this.bare = false});
  final WatchState state;
  final Widget? video; // null while the room is open in another tab, which plays it
  final bool host;
  final double? maxVideoHeight; // a phone with its keyboard up: the video makes room for the chat
  final bool bare; // just the video, without the line under it

  @override
  Widget build(BuildContext context) {
    final s = state;
    final screenH = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, c) {
        // as big as fits without pushing the people and the call off the screen
        var w = math.min(c.maxWidth, screenH * .58 * 16 / 9);
        if (maxVideoHeight != null) w = math.min(w, maxVideoHeight! * 16 / 9);
        final h = w * 9 / 16;
        final v = video;
        return Column(
          crossAxisAlignment: bare ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: w,
                height: h,
                child: v == null
                    ? ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Text('Playing in your other tab', style: TextStyle(color: VyseColors.textDim)),
                        ),
                      )
                    // the player lays itself out for the tile's size, not the window's
                    : MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          size: Size(w, h),
                          padding: EdgeInsets.zero,
                          viewPadding: EdgeInsets.zero,
                          viewInsets: EdgeInsets.zero,
                        ),
                        child: v,
                      ),
              ),
            ),
            if (!bare) const SizedBox(height: 8),
            if (!bare)
            SizedBox(
              width: w,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(5)),
                    child: const Text('LIVE', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: .6)),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      [s.media.title, if (s.season != null && s.episode != null) episodeLabel(s.season, s.episode ?? 0)].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Full screen (F)',
                    onPressed: v == null ? null : () => RoomPage.theater.value = true,
                    icon: Icon(Icons.fullscreen_rounded, color: VyseColors.textDim),
                  ),
                  if (host) ...[
                    const SizedBox(width: 4),
                    PartyChipButton(icon: Icons.stop_rounded, label: 'Stop', danger: true, onTap: WatchParty.stop),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A key's name for people: "`", "V", "Caps Lock", "Mouse 4"…
String keyName(LogicalKeyboardKey k) => k.keyLabel.trim().isNotEmpty ? k.keyLabel : (k.debugName ?? 'Key');

/// Waits for the next key press and returns it (Esc cancels).
Future<LogicalKeyboardKey?> _askKey(BuildContext context) => showDialog<LogicalKeyboardKey>(
  context: context,
  builder: (ctx) => Focus(
    autofocus: true,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent) Navigator.pop(ctx, e.logicalKey == LogicalKeyboardKey.escape ? null : e.logicalKey);
      return KeyEventResult.handled;
    },
    child: AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Press a key', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: Text('The key you hold to talk. Esc cancels.', style: TextStyle(color: VyseColors.textDim)),
    ),
  ),
);
