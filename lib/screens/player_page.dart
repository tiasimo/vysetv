import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/layout.dart';
import '../core/nav.dart' show rootNavigatorKey;
import '../core/sub_log.dart';
import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/playback_prefs.dart';
import '../data/audio_focus.dart';
import '../data/anilist.dart' show Anime, AniList;
import '../data/addons.dart';
import '../data/badges.dart';
import '../data/debrid/debrid.dart';
import '../data/downloads.dart';
import '../data/torrents.dart';
import '../data/anime_sources.dart';
import '../data/intro_db.dart';
import '../data/party/party.dart' show PartyPresence;
import '../data/party/rooms.dart' show Rooms;
import '../data/party/voice.dart';
import 'party/party_strip.dart';
import 'party/rooms_view.dart' show openRoom;
import '../data/party/watch_party.dart';
import '../data/account.dart' show Account;
import '../data/film_sources/film_sources.dart';
import '../data/film_sources/source_settings.dart';
import '../data/outside_play.dart';
import '../data/sources.dart';
import '../data/stream_proxy.dart';
import '../mpv/mpv.dart' as pz;
import '../data/watch_progress.dart';
import '../data/trackers/media_ref.dart';
import '../data/trackers/tracker_hub.dart';
import '../data/subtitle_style.dart';
import '../data/subtitles.dart' as sub;
import '../data/tmdb.dart' hide Video;
import '../widgets/common.dart';
import '../widgets/debrid_consent.dart';
import '../widgets/p2p_consent.dart';
import '../widgets/hero_carousel.dart' show screenDecodeWidth;
import 'shell.dart' show WindowBar;
import 'player_chrome.dart';
import 'player_episodes.dart';
import 'player_menus.dart';
import 'sources_page.dart';
import '../media_servers/media_servers.dart' show serverError;
import 'subtitle_sync_panel.dart';

/// The episode being played, when the title is a show.
class PlayerEpisode {
  const PlayerEpisode({required this.season, required this.number, this.name, this.runtime});
  final int season;
  final int number;
  final String? name;
  final int? runtime;

  // anime episodes are numbered straight through (season 0 here): no season in the code
  String get code => '${season == 0 ? '' : 'S${season.toString().padLeft(2, '0')}'}E${number.toString().padLeft(2, '0')}';
}

/// In a room you own, whatever you play is shared with the room the moment you press Play: it
/// plays inside the room, like a screen share, and everyone there follows you. Only the title and
/// timeline are shared; each device finds and plays its own copy of the video.
Future<void> openPlayer(BuildContext context, Media media, {PlayerEpisode? episode, int? runtime, bool party = false}) async {
  if (media.anime) {
    // from My List, Continue watching or History: the anime player, with AniList's details
    final Anime a;
    try {
      a = await AniList.details(media.id);
    } catch (_) {
      if (context.mounted) {
        showToast(context, const Text("Impossibile raggiungere AniList", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
      }
      return;
    }
    if (!context.mounted) return;
    return openAnimePlayer(context, a, episode: episode?.number ?? 1);
  }
  // your room (streaming mode off: once you've picked a source for it)
  if (Rooms.mine.value?.iOwn == true && AppSettings.streamingMode.value) {
    final at = WatchProgress.resumeSeconds(media, season: episode?.season, episode: episode?.number);
    unawaited(WatchParty.host(media, season: episode?.season, episode: episode?.number, episodeName: episode?.name, position: at).catchError((Object _) {}));
    return openRoom(Navigator.of(context), theater: true);
  }
  // Streaming mode off: you pick a source from your addons first, always. "Autoplay the best
  // source" only chooses for the next episode (see _loadPicked).
  if (!AppSettings.streamingMode.value && !party) return openSources(context, media, episode: episode, runtime: runtime);
  await Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => PlayerPage(media: media, episode: episode, runtime: runtime, party: party),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// Plays episode [episode] of an anime from the anime servers. It's saved to Continue watching
/// and History (and synced) like any title, and in a room you own it plays for the room.
Future<void> openAnimePlayer(BuildContext context, Anime a, {int episode = 1, int? episodes, Map<int, String> names = const {}}) {
  final ep = a.isMovie ? null : PlayerEpisode(season: 0, number: episode, name: names[episode]);
  if (Rooms.mine.value?.iOwn == true && AppSettings.streamingMode.value) {
    final at = WatchProgress.resumeSeconds(a.media, season: ep?.season, episode: ep?.number);
    unawaited(WatchParty.host(a.media, season: ep?.season, episode: ep?.number, episodeName: ep?.name, position: at).catchError((Object _) {}));
    return openRoom(Navigator.of(context), theater: true);
  }
  if (!AppSettings.streamingMode.value) {
    return openSources(context, a.media, episode: ep, runtime: a.duration, anime: AnimeTarget(a, episodes: episodes ?? a.aired ?? a.episodes, names: names));
  }
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => PlayerPage(
      media: a.media,
      episode: ep,
      runtime: a.duration,
      anime: AnimeTarget(a, episodes: episodes ?? a.aired ?? a.episodes, names: names),
    ),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// "Autoplay the best source" is on and there are addons to ask: the Next episode button plays
/// the best match by your autoplay order. It never starts anything by itself, and opening a
/// title always shows its sources. Not in a room you own: there you pick what the room watches.
bool get _playsBest => AppSettings.autoplayBest.value && Addons.streamAddons.isNotEmpty && Rooms.mine.value?.iOwn != true;

/// A party player for [media] (an episode for shows): anime ones get their AniList details first.
Future<Widget> partyPlayer(Media media, PlayerEpisode? episode, {Key? key, bool embedded = false, bool expanded = false, VoidCallback? onExpand}) async {
  final a = media.anime ? await AniList.details(media.id) : null;
  return PlayerPage(
    key: key,
    media: a?.media ?? media,
    episode: episode,
    party: true,
    embedded: embedded,
    expanded: expanded,
    onExpand: onExpand,
    anime: a == null ? null : AnimeTarget(a, episodes: a.aired ?? a.episodes),
  );
}

typedef _Tab = MenuTab;
typedef _Srv = SourceState;





const _speeds = [.5, .75, 1.0, 1.25, 1.5, 2.0];
const _moreSpeeds = [.25, 1.75, 2.5, 3.0, 4.0, 8.0]; // Plezy's player goes 0.25x to 8x

String _speedLabel(double s) => s == 1 ? 'Normale' : '${s == s.roundToDouble() ? s.toInt() : s}×';

/// Full-screen player. Fetches sources, plays via Plezy's mpv player (lib/mpv). Shows controls, subtitle sync, episodes.
/// controls and the settings panel. Esc leaves, S opens settings, C subtitles, F full screen.
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.media,
    this.episode,
    this.runtime,
    this.party = false,
    this.embedded = false,
    this.expanded = false,
    this.onExpand,
    this.anime,
    this.pick,
    this.server,
    this.mini = false,
    this.onMinimize,
    this.onRestore,
    this.onClose,
  }) : _session = null;

  /// The page a minimized player comes back to: the same player, carried over.
  PlayerPage._resume(MiniSession session)
    : media = session.page.media,
      episode = session.page.episode,
      runtime = session.page.runtime,
      party = session.page.party,
      embedded = false,
      expanded = false,
      onExpand = null,
      anime = session.page.anime,
      pick = session.page.pick,
      server = session.page.server,
      mini = false,
      onMinimize = null,
      onRestore = null,
      onClose = null,
      _session = session;

  final Media media;
  final MiniSession? _session;

  /// Embedded: shown in the small window over the app ([onRestore] and [onClose] are its
  /// buttons). A player on its own page minimizes by itself ([MiniPlayer]).
  final bool mini;

  /// Embedded: the minimize button (the room moves the player to the small window).
  final VoidCallback? onMinimize;
  final VoidCallback? onRestore;
  final VoidCallback? onClose;

  /// Played from your own Plex, Jellyfin or Emby server: its stream, subtitles and episodes,
  /// with your progress going back to the server instead of Lorewatch's history.
  final OutsidePlayback? server;

  /// A stream picked from your addons on the sources screen: it plays as it is (no server
  /// search), and the next episode comes from the same addon, the same release when it can.
  final AddonPick? pick;

  /// An anime from AniList: played from the anime servers.
  final AnimeTarget? anime;
  final PlayerEpisode? episode;

  /// Part of the room's watch party: the host's player reports, everyone else's follows.
  final bool party;

  /// Shown inside the room (like a screen share) instead of as its own page.
  final bool embedded;

  /// Embedded and filling the window right now.
  final bool expanded;

  /// Embedded: full screen on / off (the room does it).
  final VoidCallback? onExpand;

  /// Minutes, for films (episodes carry their own).
  final int? runtime;

  @override
  State<PlayerPage> createState() => _PlayerHostState();
}

/// A player on its own page that can be minimized. The page shows it, or the small window over
/// the app does: the same player either way (its key moves it across without a restart).
class MiniSession {
  MiniSession._(this.page);
  final PlayerPage page; // what it plays
  final _key = GlobalKey();

  String get title => page.media.title;

  Widget view({required bool mini, VoidCallback? onMinimize}) =>
      _PlayerView(page, key: _key, mini: mini, onMinimize: onMinimize, onRestore: MiniPlayer.restore, onClose: MiniPlayer.close);
}

/// The player, minimized: a small window that stays over every page while you do something
/// else (the floating layer draws it). One video at a time: a film or show you opened
/// ([session]), or your room's watch party ([room], which the room page hands over).
class MiniPlayer {
  static final session = ValueNotifier<MiniSession?>(null);
  static final room = ValueNotifier<bool>(false);

  static void minimize(MiniSession s) {
    room.value = false;
    session.value = s;
  }

  /// Back to its own page, where it left off.
  static void restore() {
    final s = session.value, nav = rootNavigatorKey.currentState;
    if (s == null || nav == null) return;
    session.value = null;
    // no fade: a fading page hides the video until it's done (see VyseVideo)
    nav.push(PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => PlayerPage._resume(s),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  static void close() {
    session.value = null;
    room.value = false;
  }
}

/// Where a [PlayerPage] sits: it draws the player itself, except while that player is in the
/// small window.
class _PlayerHostState extends State<PlayerPage> {
  late final MiniSession _session = widget._session ?? MiniSession._(widget);
  bool _left = false; // minimized from here: this page is on its way out

  @override
  void initState() {
    super.initState();
    if (widget.embedded) return;
    // one video at a time: one in the small window makes way for this one
    final other = MiniPlayer.session.value;
    if ((other != null && !identical(other, _session)) || MiniPlayer.room.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (other != null && identical(MiniPlayer.session.value, other)) MiniPlayer.session.value = null;
        MiniPlayer.room.value = false;
      });
    }
  }

  void _minimize() {
    final nav = Navigator.of(context), route = ModalRoute.of(context);
    _left = true;
    MiniPlayer.minimize(_session);
    if (route == null || route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
    // the sources list it was picked from goes too: minimizing takes you back to the app
    nav.popUntil((r) => r.settings.name != SourcesPage.route);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget;
    // in the room: the room moves it between its tile, full screen and the small window
    if (p.embedded) return _PlayerView(p, mini: p.mini, onMinimize: p.onMinimize, onRestore: p.onRestore, onClose: p.onClose);
    return ValueListenableBuilder<MiniSession?>(
      valueListenable: MiniPlayer.session,
      builder: (context, mini, _) => _left || identical(mini, _session) ? const SizedBox.shrink() : _session.view(mini: false, onMinimize: _minimize),
    );
  }
}

/// The player itself: see [PlayerPage] for what each of these is.
class _PlayerView extends StatefulWidget {
  _PlayerView(PlayerPage p, {super.key, required this.mini, this.onMinimize, this.onRestore, this.onClose})
    : media = p.media,
      episode = p.episode,
      runtime = p.runtime,
      party = p.party,
      embedded = p.embedded,
      expanded = p.expanded,
      onExpand = p.onExpand,
      anime = p.anime,
      pick = p.pick,
      server = p.server;

  final Media media;
  final PlayerEpisode? episode;
  final int? runtime;
  final bool party;
  final bool embedded;
  final bool expanded;
  final VoidCallback? onExpand;
  final AnimeTarget? anime;
  final AddonPick? pick;
  final OutsidePlayback? server;
  final bool mini;
  final VoidCallback? onMinimize;
  final VoidCallback? onRestore;
  final VoidCallback? onClose;

  @override
  State<_PlayerView> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<_PlayerView> {
  late final Future<String?> _logo = widget.server != null
      ? Future.value(widget.server!.logo)
      : widget.anime != null
      ? Future.value()
      : Tmdb.logo(widget.media).catchError((Object _) => null);
  late PlayerEpisode? _ep = widget.episode;
  late final EpisodeStore? _store = widget.server != null
      ? widget.server!.episodes
      : widget.episode == null || !widget.media.isTv
      ? null
      : (widget.anime != null ? AnimeEpisodeStore(widget.anime!.anime) : EpisodeStore(widget.media));
  bool _episodes = false;
  EpisodeInfo? _upNext;
  EpisodeInfo? _nextInfo; // looked up when an episode starts
  bool _upNextDismissed = false;

  // ── player: Plezy's mpv (lib/mpv); the video is a native surface behind Flutter ──
  late final _player = pz.Player();
  // One video widget for the page's whole life: picture-in-picture moves it rather than
  // building a new one, so the native surface never loses its place.
  final _videoKey = GlobalKey();
  final _subs = <StreamSubscription<Object?>>[];
  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);
  bool _buffering = true;
  bool _started = false; // first frame shown; the backdrop stays away after that
  bool _playing = false;
  String? _error;

  // ── sources & subtitles ──
  List<StreamSource> _sources = [];
  bool _loadingSources = true; // still looking for the first server that plays
  List<Segment> _segments = const []; // intro / recap / credits / preview from TheIntroDB
  Segment? _segNow; // the skippable segment playing right now
  final _segDismissed = <Segment>{};
  DateTime _savedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration? _resumeAt; // where this film or episode was left last time
  FilmSession? _session;
  FilmLink? _playingLink; // the film or episode link on screen
  FilmLink? _wanted; // the last one you picked, while it's being checked
  bool _hostOrder = false; // a party guest, asking the host's sources in the host's order
  final _serverState = <String, _Srv>{}; // per server name; missing = not asked yet
  bool _userPicked = false; // a server was chosen by hand, so the start-up fallback stops
  // playing a source picked from your addons (in a watch party: the one the host shared)
  late AddonPick? _pick = widget.pick ?? (widget.party ? WatchParty.sourcePick(WatchParty.state.value) : null);
  bool _sourcesOverlay = false; // the sources list over the video ("Choose another source")
  final _buffered = ValueNotifier(Duration.zero); // how far ahead the player has it
  List<PlayerChapter> _chapters = const []; // the file's chapters, for the rail
  Duration? _resumeOverride; // switching source mid-video: carry on from here
  List<sub.SubtitleTrack> _addonSubs = const []; // your subtitle addons' files for this video
  String? _torrent; // info hash of the torrent playing (through our engine)
  String? _torrentNote; // "12 peers · 4.1 MB/s", under the spinner while it loads
  String? _loadNote; // "Getting it from Real-Debrid…", "Waiting for the host's stream…"
  String? _sharedUrl; // a party guest playing the host's own link
  String? _sharedSkip; // the host's link that wouldn't play here: we found our own
  Timer? _torrentTimer;
  List<sub.SubtitleTrack> _subtitleTracks = [];
  List<sub.SubtitleTrack> _builtIn = const []; // inside the video file, and files in the torrent
  String? _embeddedSid; // a track inside the video file is showing (mpv's id for it)
  bool _subsChosen = false; // picked by hand: built-in tracks arriving later don't take over
  Timer? _scanTimer;
  sub.SubtitleTrack? _activeSubTrack;

  bool _chrome = true;
  bool _typing = false; // a text field has focus: keys are for it, not the player shortcuts
  final _keys = FocusNode(debugLabel: 'player');

  // ── touch: lock and swipe gestures ──
  static final _touch = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool _locked = false; // UI hidden, touches ignored
  bool _lockHint = false; // unlock button, shown for a moment after a tap while locked
  Timer? _lockTimer;
  String? _hud; // 'volume' or 'brightness' while a swipe adjusts it
  double _hudValue = 0;
  Timer? _hudTimer;
  double? _brightness;
  bool _brightnessChanged = false;
  bool _dragBrightness = false;
  bool _panel = false;
  bool _sync = false; // subtitle sync panel
  double _subOffset = 0; // seconds added to subtitle times
  bool _fullscreen = false;
  _Tab _tab = _Tab.sources;
  Timer? _hide;
  Timer? _noteTimer;
  String? _note; // brief line under the spinner after a switch

  int _source = 1;
  List<StreamVariant> _variants = const []; // renditions of the current server; empty = just one
  int? _variant; // index into [_variants]; null = Auto
  String _playUrl = ''; // upstream playlist being played: the source, or one of its variants
  int _videoW = 0, _videoH = 0;

  // ── Plezy extras: picture, sleep timer, display, other players (More tab) ──
  late final _effects = pz.PictureEffects(_player);
  late final _display = pz.DisplayMatch(_player);
  int _zoom = 100; // %, this session only
  int? _sleepMinutes; // null: off; -1: at the end of this episode
  DateTime? _sleepAt;
  Timer? _sleepTimer;
  bool _pipOk = false;
  List<pz.ExternalPlayer> _externals = const [];
  bool _displayTried = false; // refresh-rate matching runs once per video
  bool _panelOverDock = false; // a short window: the panel needs the dock's room
  bool _subsLoading = true;
  List<pz.AudioTrack> _audioTracks = const [];
  pz.AudioTrack? _audioNow;
  List<SyncCue> _cues = const []; // lines of the subtitle in use, for the sync panel
  /// Films, TV series and anime keep their own audio and subtitle languages (Settings → Languages).
  late final PlayKind _kind = PlaybackPrefs.of(widget.media, anime: widget.anime != null);
  late String _subtitle = PlaybackPrefs.autoOn(_kind) ? PlaybackPrefs.subtitles(_kind).value : 'Off';
  int _audioPrefLoad = -1; // the load the preferred audio language was last looked for in
  bool _audioByHand = false; // picked in the player's menu: the Settings language no longer applies
  double _speed = 1;
  double _volume = 80;

  // ── watch party ──
  Timer? _partyTimer;
  int _partyTicks = 0;
  Timer? _partyDebounce;
  String? _partySubLoading; // the host's subtitle file being fetched
  DateTime? _partyJumpAt; // when a follower last jumped to catch up
  DateTime _partySteadyAt = DateTime.now(); // when playback last came back from buffering
  Timer? _stallTimer;
  Timer? _startTimer;
  bool _stalled = false; // buffering for over a second: the room waits for us
  bool _autoPaused = false; // the host paused because someone is loading
  List<String> _waitingFor = const [];
  bool _ownSubs = false; // a follower picked their own subtitles: the host's no longer apply
  DateTime? _commandAt; // a follower with control just played, paused or seeked
  bool get _host => widget.party && WatchParty.canControl;
  bool get _follower => widget.party && !WatchParty.canControl;

  @override
  void initState() {
    super.initState();
    PlaybackPrefs.current = _kind; // subtitle searches while this plays use this kind's language
    SubLog.line('==== player opened: ${widget.media.title}${widget.media.isTv ? ' (show)' : ''}');
    if (SubLog.enabled) unawaited(_player.setLogLevel('info').catchError((Object _) {}));
    _poke();
    _scheduleUpNext();
    if (widget.party) {
      WatchParty.playerOpen++;
      WatchParty.state.addListener(_partyChanged);
      // host: a heartbeat every 4 s; followers: drift checks every second
      _partyTimer = Timer.periodic(const Duration(seconds: 1), (_) => _partyTick());
      WidgetsBinding.instance.addPostFrameCallback((_) => _partyChanged());
      _subs.add(WatchParty.commands.listen(_onCommand));
    }
    _subs
      ..add(_player.streams.playing.listen((v) {
        if (_pipOk) unawaited(pz.Pip.setAutoReady(v && !widget.mini, width: _videoW > 0 ? _videoW : 16, height: _videoH > 0 ? _videoH : 9));
        if (mounted) setState(() => _playing = v);
        if (!v) _saveProgress();
        if (v) _track(playing: true);
        _partyReport();
      }))
      ..add(_player.streams.buffering.listen((v) {
        if (!mounted) return;
        setState(() => _buffering = v);
        if (!widget.party) return;
        _stallTimer?.cancel();
        if (v) {
          _stallTimer = Timer(const Duration(seconds: 1), () => _setStalled(true));
        } else {
          _partySteadyAt = DateTime.now();
          _partyJumpAt = null;
          _setStalled(false);
        }
      }))
      ..add(_player.streams.position.listen((p) {
        if (_reopening) return;
        p += _offsetDur;
        final target = _seekTarget;
        if (target != null) {
          // mpv reports the old spot for a moment after a seek; keep the bar on the target
          final landed = (p - target).abs() < const Duration(milliseconds: 1500);
          if (!landed && DateTime.now().difference(_seekAt) < const Duration(seconds: 15)) return;
          _seekTarget = null;
          _position.value = p; // land the bar right away
        }
        if (_veil && !_buffering && mounted) setState(() => _veil = false);
        // mpv reports the position every frame; the bar only needs a few updates a second,
        // and each update rebuilds it
        if ((p - _position.value).abs() >= const Duration(milliseconds: 200)) _position.value = p;
        _checkUpNext(p);
        _checkSegment(p);
        if (DateTime.now().difference(_savedAt) > const Duration(seconds: 10)) _saveProgress();
        if (!_started && !_buffering && p > Duration.zero && mounted) setState(() => _started = true);
      }))
      ..add(_player.streams.duration.listen((d) {
        if (!_reopening && d > Duration.zero) _duration.value = d + _offsetDur;
      }))
      ..add(_player.videoSize.listen((s) {
        if (mounted && (s.$1 != _videoW || s.$2 != _videoH)) {
          final first = _videoW == 0 && s.$1 > 0;
          setState(() {
            _videoW = s.$1;
            _videoH = s.$2;
          });
          // ambient lighting needs the picture's shape; refresh matching needs it decoding
          if (s.$1 > 0) unawaited(_applyPicture());
          if (first) unawaited(_maybeMatchDisplay());
        }
      }))
      ..add(_player.streams.completed.listen((done) {
        if (done && _sleepMinutes == -1) _sleepNow();
      }))
      ..add(_player.streams.buffer.listen((b) => _buffered.value = b + _offsetDur))
      ..add(_player.streams.tracks.listen((t) {
        final audio = t.audio.where((a) => a.id != 'auto' && a.id != 'no').toList();
        if (mounted) setState(() => _audioTracks = audio);
        _pickPreferredAudio(audio);
        _scanTimer?.cancel();
        _scanTimer = Timer(const Duration(milliseconds: 300), _scanEmbedded);
        // after every load (a reopen for a seek, a quality or server switch), make sure the
        // subtitle you picked is the one showing
        if (_subPath != null || _embeddedSid != null) {
          _subCheckTimer?.cancel();
          _subCheckTimer = Timer(const Duration(milliseconds: 700), () => _checkSubs('tracks changed'));
        }
      }))
      ..add(_player.streams.track.listen((t) { if (mounted) setState(() => _audioNow = t.audio); }))
      ..add(_player.streams.log.listen(_mpvLog))
      ;
    // Buffer about three minutes ahead. 4K runs ~16 Mbps (~360 MB for 3 min); mpv keeps the
    // cache on disk, so the byte limits don't sit in RAM.
    {
      final mpv = _player;
      for (final (k, v) in const [
        ('cache', 'yes'),
        ('cache-secs', '180'),
        ('demuxer-readahead-secs', '180'),
        ('demuxer-max-bytes', '400MiB'),
        ('demuxer-max-back-bytes', '128MiB'), // ~30 s+ behind even at 4K
        ('demuxer-seekable-cache', 'yes'),
      ]) {
        unawaited(mpv.setProperty(k, v));
      }
    }
    // mpv draws the subtitles; Lorewatch's subtitle settings become its style
    unawaited(_applySubtitleStyle());
    for (final setting in _subtitleSettings) {
      setting.addListener(_subtitleStyleChanged);
    }
    // sound and picture settings (Audio and More tabs)
    unawaited(_applySound());
    unawaited(_applyPicture());
    for (final setting in _soundSettings) {
      setting.addListener(_soundChanged);
    }
    for (final setting in _pictureSettings) {
      setting.addListener(_pictureChanged);
    }
    pz.Pip.active.addListener(_pipChanged);
    pz.Pip.isSupported().then((ok) {
      if (mounted && ok && !widget.embedded) setState(() => _pipOk = true);
    });
    pz.ExternalPlayer.available().then((list) {
      if (mounted) setState(() => _externals = list);
    });
    FocusManager.instance.addListener(_onFocusChange);
    // start the player where the volume control says it is
    unawaited(_player.setVolume(_volume));
    if (_touch) {
      ScreenBrightness.instance.application.then((b) => _brightness = b, onError: (Object _) {});
    }
    _loadAndPlay();
    // Opened from a plain Play button: fill in the episode's name and length.
    final ep = _ep;
    if (_store != null && ep != null && ep.name == null) {
      _store.season(ep.season).then((eps) {
        final hit = eps.where((x) => x.number == ep.number).firstOrNull;
        if (mounted && hit != null && _ep == ep) setState(() => _ep = hit.toPlayer());
      }, onError: (Object _) {});
    }
  }

  @override
  void didUpdateWidget(_PlayerView old) {
    super.didUpdateWidget(old);
    // the room just went full screen with it: Esc, space and the arrows work straight away
    if (widget.expanded && !old.expanded) _keys.requestFocus();
    if (old.mini != widget.mini) {
      // Android would shrink the whole app around a player that's already a small window
      if (_pipOk) unawaited(pz.Pip.setAutoReady(_playing && !widget.mini, width: _videoW > 0 ? _videoW : 16, height: _videoH > 0 ? _videoH : 9));
      // back from the small window: the controls show, and the keys are the player's again
      if (!widget.mini) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _poke();
          if (!widget.embedded || widget.expanded) _keys.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _subCheckTimer?.cancel();
    _syncTimer?.cancel();
    SubLog.line('==== player closed');
    for (final setting in _subtitleSettings) {
      setting.removeListener(_subtitleStyleChanged);
    }
    for (final setting in _soundSettings) {
      setting.removeListener(_soundChanged);
    }
    for (final setting in _pictureSettings) {
      setting.removeListener(_pictureChanged);
    }
    pz.Pip.active.removeListener(_pipChanged);
    if (_pipOk) unawaited(pz.Pip.setAutoReady(false));
    // the desktop mini player is the app window itself: give it back its size
    if (pz.Pip.active.value) unawaited(pz.Pip.exit());
    _sleepTimer?.cancel();
    unawaited(_display.restore());
    _scanTimer?.cancel();
    _saveProgress();
    if (widget.server case final s?) unawaited(s.close()); // tells the server, then its pages reload
    TrackerHub.playerClosed(this);
    _torrentTimer?.cancel();
    if (_torrent != null) unawaited(Torrents.release(_torrent!)); // stop downloading it
    _hide?.cancel();
    _noteTimer?.cancel();
    _reopenTimer?.cancel();
    FocusManager.instance.removeListener(_onFocusChange);
    _keys.dispose();
    _lockTimer?.cancel();
    _hudTimer?.cancel();
    // give the screen its own brightness back
    if (_brightnessChanged) ScreenBrightness.instance.resetApplicationScreenBrightness().catchError((Object _) {});
    for (final s in _subs) {
      s.cancel();
    }
    if (_fullscreen && isDesktopNative) windowManager.setFullScreen(false);
    AudioFocus.release(this);
    if (widget.party) {
      WatchParty.playerOpen--;
      WatchParty.state.removeListener(_partyChanged);
      _partyTimer?.cancel();
      _partyDebounce?.cancel();
      _stallTimer?.cancel();
      _startTimer?.cancel();
      // the host leaving pauses everyone where they are (unless the watch was just stopped)
      if (WatchParty.state.value != null) _partyReport(playing: false);
      if (_follower) WatchParty.wait(false); // nobody waits for a player that's closed
    }
    _player.dispose();
    PartyPresence.stopped();
    _position.dispose();
    _duration.dispose();
    _buffered.dispose();
    super.dispose();
  }

  int _loadId = 0;
  final _subCache = <String, String>{};

  // fMP4 servers can't be seeked by mpv; they reopen a playlist trimmed at the target instead,
  // and everything mpv reports is shifted by where that playlist starts.
  bool _fragmented = false;
  String? _timeline; // fMP4 played as a segment timeline (StreamProxy.timeline): seeks natively
  double _offset = 0;
  bool _reopening = false;
  bool _veil = false; // black over the video while a reopen swaps streams, so it doesn't flicker
  Timer? _reopenTimer;
  Duration get _offsetDur => Duration(milliseconds: (_offset * 1000).round());

  Duration? _seekTarget; // where the bar stays until the player catches up
  DateTime _seekAt = DateTime.now();

  void _holdAt(Duration t) {
    _seekTarget = t;
    _seekAt = DateTime.now();
    _position.value = t;
  }

  /// Seeking from the controls, keys or panels. In a watch party, the host or a member the owner
  /// gave control (the host's player does it for everyone).
  void _seek(Duration to) {
    if (_follower) {
      if (!WatchParty.canCommand) return _hostOnly();
      _commandAt = DateTime.now();
      _seekTo(to);
      _sendCommand('seek', position: to.inMilliseconds / 1000);
      return;
    }
    _seekTo(to);
    _partyReport(position: to);
  }

  void _seekTo(Duration to) {
    final end = _duration.value;
    if (end <= Duration.zero || _sources.isEmpty) return;
    final t = to < Duration.zero ? Duration.zero : (to > end ? end : to);
    _holdAt(t);
    _poke();
    if (_subPath != null || _embeddedSid != null) SubLog.line('SEEK to ${_secs(t)} (${_fragmented ? 'fMP4: may reopen' : 'plain seek'}) offset=$_offset');
    if (!_fragmented) {
      _player.seek(t);
      return;
    }
    _reopenTimer?.cancel();
    final seq = ++_seekSeq;
    _cached(t).then((hit) {
      if (!mounted || seq != _seekSeq) return;
      // already downloaded: mpv jumps inside its cache, no reopen and no black screen
      if (hit) {
        SubLog.line('  in cache: seek without reopening');
        _player.seek(t - _offsetDur);
        return;
      }
      // held arrow keys and quick clicks settle into one reopen
      _reopenTimer = Timer(const Duration(milliseconds: 220), () => _reopenAt(t));
    });
  }

  int _seekSeq = 0;

  /// Whether [t] sits in the stretch mpv has cached around the playhead (up to ~3 min ahead,
  /// some behind). Seeking there never touches the network, so fMP4 streams don't need a reopen.
  Future<bool> _cached(Duration t) async {
    final mpv = _player;
    if (_reopening) return false;
    try {
      final state = json.decode(await mpv.getProperty('demuxer-cache-state') ?? '');
      final now = double.parse(await mpv.getProperty('time-pos') ?? '');
      final at = t.inMilliseconds / 1000 - _offset;
      for (final r in (state['seekable-ranges'] as List? ?? const [])) {
        final start = (r['start'] as num).toDouble();
        final end = (r['end'] as num).toDouble();
        // the range the playhead is in, with a margin so mpv never falls back to a real seek
        if (now >= start && now <= end + 1 && at >= start + .5 && at <= end - 2) return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _reopenAt(Duration t) async {
    final src = _sources[_source];
    final from = _playUrl;
    final secs = t.inMilliseconds / 1000;
    final id = _loadId;
    final seq = ++_openSeq;
    final proxy = StreamProxy.instance;
    try {
      final frag = _fragmented;
      final tl = _timeline;
      final start = frag ? await proxy.fragmentedStart(from, secs) ?? 0 : 0.0;
      final url = tl ?? (frag ? await proxy.wrap(from, from: secs) : await proxy.wrap(from));
      if (!mounted || id != _loadId || seq != _openSeq || src != _sources[_source] || from != _playUrl) return;
      final play = _playing;
      _reopening = true;
      setState(() => _veil = true);
      SubLog.line('REOPEN at ${secs.toStringAsFixed(2)}s: playlist starts at ${start.toStringAsFixed(3)}s (was offset $_offset)${tl != null ? ' timeline' : ''}');
      _offset = start;
      await _prepOpen();
      // the trimmed playlist begins at its segment's start; a short seek inside it lands exactly
      final into = Duration(milliseconds: ((secs - start) * 1000).round());
      await _player.open(pz.Media(url, start: frag ? (into > const Duration(milliseconds: 200) ? into : null) : t), play: play);
      if (tl != null) _watchTimeline(tl, seq);
    } catch (_) {
      if (mounted) setState(() => _veil = false);
    } finally {
      _reopening = false;
    }
  }

  /// If mpv can't play the segment timeline (no length after a while, or an error before it
  /// starts), go back to reopening trimmed playlists.
  void _watchTimeline(String tl, int seq) {
    late final StreamSubscription<pz.PlayerError> errors;
    late final Timer timer;
    void check() {
      timer.cancel();
      errors.cancel();
      if (!mounted || seq != _openSeq || _timeline != tl || _player.state.duration > Duration.zero) return;
      _timeline = null;
      _fragmented = true;
      _reopenAt(_position.value);
    }
    timer = Timer(const Duration(seconds: 12), check);
    errors = _player.streams.error.listen((_) => check());
  }

  int _openSeq = 0; // the newest load; an older one that finishes late is ignored
  String? _subPath; // the subtitle in use, as a file mpv loads with every open

  /// Lorewatch: switches to the audio language picked in Settings for this kind of video (films,
  /// TV series, anime), once per load, when the file has more than one audio track and one of
  /// them is in that language. A track you pick by hand afterwards stays.
  void _pickPreferredAudio(List<pz.AudioTrack> audio) {
    if (_audioByHand || _audioPrefLoad == _loadId || audio.length < 2 || _follower) return;
    _audioPrefLoad = _loadId;
    final want = PlaybackPrefs.audio(_kind).value;
    if (want.isEmpty) return; // the original: whatever the file starts on
    final code = sub.exactLanguage(want);
    if (code == null) return;
    final base = code.split('-').first;
    String? baseOf(String? l) {
      if (l == null || l.trim().isEmpty) return null;
      return (sub.exactLanguage(l) ?? l.toLowerCase()).split('-').first;
    }

    final hit = audio.where((a) => baseOf(a.language) == base).firstOrNull;
    if (hit == null || hit.id == _audioNow?.id) return;
    unawaited(_player.selectAudioTrack(hit).catchError((Object _) {}));
  }

  /// Hands mpv the subtitle file and its timing before a load, so the right line is up from
  /// the first frame instead of being added once the stream is already playing.
  Future<void> _prepOpen() async {
    final mpv = _player;
    if (_subPath != null || _embeddedSid != null) {
      SubLog.line('PREP open: sub-delay=${(_subOffset - _offset).toStringAsFixed(3)} file=${_subPath == null ? '-' : _subPath!.split(Platform.pathSeparator).last} built-in=${_embeddedSid ?? '-'}');
    }
    await mpv.setProperty('sub-delay', (_subOffset - _offset).toStringAsFixed(3));
    final path = _subPath;
    if (path == null) {
      await mpv.command(['change-list', 'sub-files', 'clr', '']);
    } else {
      await mpv.setProperty('sub-files', path);
    }
    // mpv only switches an external file on by itself when its language is a wanted one
    final lang = path == null ? null : RegExp(r'\.([a-z]{2,3})\.\w+$').firstMatch(path)?[1];
    if (lang != null) await mpv.setProperty('slang', lang);
    await mpv.setProperty('sid', _subPath != null ? 'auto' : (_embeddedSid ?? 'no'));
  }

  Future<String> _writeSub(sub.SubtitleTrack track, String content) async {
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}vyse_subs');
    await dir.create(recursive: true);
    final ext = content.trimLeft().startsWith('WEBVTT') ? 'vtt' : (content.contains('[Script Info]') ? 'ass' : 'srt');
    final lang = track.lang.split('-').first.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    final file = File('${dir.path}${Platform.pathSeparator}${track.url.hashCode.toUnsigned(32)}${lang.length >= 2 && lang.length <= 3 ? '.$lang' : ''}.$ext');
    await file.writeAsString(content);
    return file.path;
  }

  Future<void> _pickQuality(int? i) async {
    if (i == _variant || _sources.isEmpty) return;
    final src = _sources[_source];
    final at = _position.value;
    _switch(i == null ? 'Scelta della qualità' : 'Passo a ${_variants[i].label}', () => _variant = i);
    _playUrl = i == null ? src.url : _variants[i].url;
    if (!src.hls) {
      // another file of the same episode: open it where we are
      _holdAt(at);
      await _prepOpen();
      await _player.open(pz.Media(_playUrl, headers: src.headers, start: at), play: _playing);
      return;
    }
    final url = _playUrl;
    final frag = await StreamProxy.instance.fragmentedStart(url, 0).then((s) => s != null, onError: (Object _) => false);
    final tl = frag ? await StreamProxy.instance.timeline(url).catchError((Object _) => null) : null;
    if (!mounted || url != _playUrl) return;
    _timeline = tl;
    _fragmented = frag && tl == null;
    _holdAt(at);
    await _reopenAt(at);
  }

  void _pickSource(int i) {
    if (i == _source) return;
    final at = _position.value;
    _switch('Passo a ${_sources[i].server}', () => _source = i);
    _playSource(_sources[i], at: at);
    if (widget.anime != null) _useAnimeExtras(_sources[i], _loadId); // skip times from this stream, subs from all
  }

  String _audioName(pz.AudioTrack t) {
    final lang = t.language;
    if (lang != null && lang.isNotEmpty && lang != 'und') return sub.languageName(lang);
    final title = t.title;
    if (title != null && title.isNotEmpty) return title;
    // one unnamed track, on a link whose source says what language it's in: that's the language
    // ('English sub' says the subtitles, not the sound)
    final said = _films ? _playingLink?.audio : null;
    if (said != null && _audioTracks.length == 1 && audioLabel(said) == said) return said;
    return 'Traccia ${t.id}';
  }

  String _audioInfo(pz.AudioTrack t, {required bool single}) {
    final ch = t.channels;
    return [
      if (t.title != null && t.title!.isNotEmpty && t.title != _audioName(t)) t.title!,
      switch (ch) { 1 => 'Mono', 2 => 'Stereo', 6 => '5.1', 8 => '7.1', null => null, _ => '$ch canali' },
      if (t.codec != null && t.codec!.isNotEmpty) t.codec!.toUpperCase(),
      if (single) 'l\'unico audio su questo server',
    ].whereType<String>().join(' · ');
  }

  /// The quality playing, by the server's own labels.
  String get _nowQuality {
    final v = _variant;
    if (v != null && v < _variants.length) return _variants[v].label;
    if (_variants.isNotEmpty) return _variants.first.label; // Auto: mpv takes the best stream
    if (_videoW > 0) return qualityLabel(_videoW, _videoH);
    return _sources.isEmpty ? '' : _sources[_source].quality;
  }

  /// A master playlist offers "Auto"; separate per-quality streams don't.
  bool get _hasAuto => _sources.isNotEmpty && _sources[_source].qualities.isEmpty && _variants.length > 1;

  /// Subtitle files are timed from the start of the film; mpv's clock starts at [_offset].
  /// mpv draws subtitles itself: full ASS/SSA styling via libass, and on Android's hardware
  /// path its own subtitle plane. Set to false to go back to Lorewatch's Flutter overlay, which draws
  /// plain text from mpv's sub-text.
  static const _mpvSubtitles = true;

  static List<Listenable> get _subtitleSettings => SubtitleStyle.settings;

  void _subtitleStyleChanged() => unawaited(_applySubtitleStyle());

  /// Lorewatch's subtitle settings as mpv's style for plain-text subtitles (SRT, VTT). Styled ASS keeps
  /// its own look (mpv's default sub-ass-override=scale only scales it).
  Future<void> _applySubtitleStyle() async {
    if (!_mpvSubtitles) {
      try {
        await _player.setProperty('sub-visibility', 'no');
      } catch (_) {}
      return;
    }
    // font, colours, outline, shadow, box, placement, styled-subtitle policy (Settings > Subtitles)
    await SubtitleStyle.apply(_player);
    // apply() put sub-pos back to its resting place: let the next frame lift it again if needed
    _subPos = -1;
    if (mounted) setState(() {});
  }

  /// Where mpv puts the subtitles (`sub-pos`, % of the height): lifted above the controls while
  /// they show, like the old overlay did.
  double _subPos = 100;

  void _syncSubPos(double pos) {
    final p = pos.clamp(40.0, 100.0).roundToDouble();
    if (p == _subPos) return;
    _subPos = p;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _subPos != p) return;
      _player.setProperty('sub-pos', p.toStringAsFixed(0)).catchError((Object _) {});
    });
  }

  // ── sound (Audio tab) ──

  static final List<Listenable> _soundSettings = [
    AppSettings.audioDelayMs,
    AppSettings.audioPassthrough,
    AppSettings.audioChannels,
    AppSettings.volumeLevelling,
    AppSettings.hdrOutput,
  ];

  void _soundChanged() {
    unawaited(_applySound());
    if (mounted) setState(() {});
  }

  pz.AudioChannelLimit get _channelLimit => switch (AppSettings.audioChannels.value) {
    'surround51' => pz.AudioChannelLimit.surround51,
    'stereo' => pz.AudioChannelLimit.stereo,
    _ => pz.AudioChannelLimit.original,
  };

  /// Lip-sync, channel limit, levelling, passthrough and HDR output, as Plezy's player takes
  /// them. Its own queue settles the order (levelling and stereo turn passthrough off).
  Future<void> _applySound() async {
    Future<void> safe(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {}
    }

    await safe(() => _player.setProperty('audio-delay', (AppSettings.audioDelayMs.value / 1000).toStringAsFixed(3)));
    await safe(() => _player.setAudioChannelLimit(_channelLimit, centerBoostDb: 0, normalize: true));
    await safe(() => _player.setAudioNormalization(AppSettings.volumeLevelling.value));
    await safe(() => _player.setAudioPassthrough(AppSettings.audioPassthrough.value));
    if (Platform.isWindows) await safe(() => _player.setProperty('hdr-enabled', AppSettings.hdrOutput.value ? 'yes' : 'no'));
  }

  void _nudgeDelay(int ms) => AppSettings.audioDelayMs.set((AppSettings.audioDelayMs.value + ms).clamp(-5000, 5000));

  String get _delayLabel {
    final ms = AppSettings.audioDelayMs.value;
    if (ms == 0) return 'Sincronizzato';
    return '${ms > 0 ? '+' : '−'}${(ms.abs() / 1000).toStringAsFixed(2)} s';
  }

  // ── picture (More tab) ──

  static final List<Listenable> _pictureSettings = [AppSettings.upscaler, AppSettings.ambientLight];

  void _pictureChanged() {
    unawaited(_applyPicture());
    if (mounted) setState(() {});
  }

  Future<void> _applyPicture() => _effects.apply(
    upscaler: pz.Upscaler.byId(AppSettings.upscaler.value),
    ambient: AppSettings.ambientLight.value,
    videoAspect: _videoW > 0 && _videoH > 0 ? _videoW / _videoH : null,
  );

  void _setZoom(int percent) {
    final z = percent.clamp(50, 200);
    setState(() => _zoom = z);
    // Apple scales its video layer; everywhere else mpv zooms (video-zoom is log2)
    _player.setVideoZoom(z / 100).catchError((Object _) {});
    if (!Platform.isIOS && !Platform.isMacOS) {
      _player.setProperty('video-zoom', (math.log(z / 100) / math.ln2).toStringAsFixed(4)).catchError((Object _) {});
    }
  }

  // ── sleep timer ──

  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    setState(() {
      _sleepMinutes = minutes == 0 ? null : minutes;
      _sleepAt = minutes > 0 ? DateTime.now().add(Duration(minutes: minutes)) : null;
    });
    if (minutes > 0) _sleepTimer = Timer(Duration(minutes: minutes), _sleepNow);
  }

  void _sleepNow() {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _sleepMinutes = null;
      _sleepAt = null;
      _upNext = null;
    });
    _player.pause();
    showToast(context, const Text('Timer di spegnimento: in pausa', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.bedtime_rounded);
  }

  String get _sleepTitle {
    final at = _sleepAt;
    if (_sleepMinutes == -1) return 'Si ferma alla fine di questo episodio';
    if (at != null) return 'Si ferma alle ${TimeOfDay.fromDateTime(at).format(context)}';
    return 'Metti in pausa dopo';
  }

  // ── display and other players ──

  /// Refresh-rate matching (off by default): once per video, full screen on Windows,
  /// never in a watch party (switching pauses for a moment).
  Future<void> _maybeMatchDisplay() async {
    if (!AppSettings.matchRefreshRate.value || widget.party || widget.embedded || _displayTried) return;
    if (Platform.isWindows && !_fullscreen) return;
    _displayTried = true;
    String? raw;
    try {
      raw = await _player.getProperty('container-fps');
    } catch (_) {}
    final fps = double.tryParse(raw ?? '') ?? 0;
    if (!mounted || fps <= 0) return;
    await _display.match(fps: fps, duration: _duration.value, width: _videoW, height: _videoH);
  }

  void _pipChanged() {
    if (mounted) setState(() {});
  }

  /// What picture-in-picture shows: the video alone (Android, iPhone, Mac), or on Windows and
  /// Linux, where the app window itself becomes the small player, the video with a few controls.
  Widget _pipView() {
    final video = pz.VyseVideo(key: _videoKey, player: _player);
    if (kIsWeb || !(Platform.isWindows || Platform.isLinux)) return Material(color: Colors.transparent, child: video);
    return Material(
      color: Colors.transparent,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): pz.Pip.exit,
          const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        },
        child: Focus(
          autofocus: true,
          child: _MiniPlayer(video: video, playing: _playing, onTogglePause: _togglePause, onExpand: pz.Pip.exit),
        ),
      ),
    );
  }

  Future<void> _enterPip() async {
    setState(() {
      _panel = false;
      _chrome = false;
    });
    final err = await pz.Pip.enter(width: _videoW > 0 ? _videoW : 16, height: _videoH > 0 ? _videoH : 9);
    if (err != null && mounted) {
      showToast(context, Text(err, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.picture_in_picture_alt_rounded);
    }
  }

  /// The address being played, as it is: for a torrent that is Lorewatch's own engine on this
  /// device (127.0.0.1). Never offered in a watch party, where the link may be the host's.
  bool get _canCopyLink => !widget.party && _playUrl.isNotEmpty;

  bool get _linkIsLocal {
    final host = Uri.tryParse(_playUrl)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  /// More → Download. Not in a watch party (the link there may be the host's own), not for a
  /// title from your server (it keeps its own copies), not for something already downloaded.
  bool get _canDownload {
    if (widget.party || _sources.isEmpty || _playUrl.isEmpty || _loadingSources) return false;
    final s = widget.server;
    return s == null || (s is DirectPlayback && s.downloadable && !s.isLocal);
  }

  /// Saves what's playing to this device, fetched the way it streams: a file as a file, a stream
  /// piece by piece through the relay, a torrent through the torrent engine. It carries on after
  /// the player closes; Downloads in the navbar shows how far it is.
  Future<void> _download() async {
    if (!_canDownload) return;
    final src = _sources[_source];
    final ep = _ep;
    final url = _playUrl;
    final u = Uri.tryParse(url.split('#').first);
    final detail = ep != null ? [ep.code, ?ep.name].join(' · ') : (widget.media.year ?? '');
    void say(String text, {IconData icon = Icons.download_rounded}) {
      if (mounted) showToast(context, Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: icon);
    }

    try {
      final DownloadRequest r;
      // through the torrent engine: its address is on this device and names the torrent and file
      final hash = _torrent ?? (_linkIsLocal ? u?.queryParameters['link'] : null);
      final index = int.tryParse(u?.queryParameters['index'] ?? '');
      if (hash != null && hash.isNotEmpty && index != null && _linkIsLocal) {
        final file = await Torrents.fileOf(hash, index);
        r = DownloadRequest(
          title: widget.media.title,
          detail: detail,
          poster: widget.media.poster(),
          kind: DownloadKind.torrent,
          url: url,
          torrentHash: hash,
          torrentFile: index,
          trackers: _pick?.stream.trackers ?? const [],
          torrentTitle: _pick?.stream.release,
          extension: RegExp(r'\.([A-Za-z0-9]{2,4})$').firstMatch(file?.path ?? '')?[1],
        );
      } else if (_linkIsLocal || u == null || !u.scheme.startsWith('http')) {
        // a manifest Lorewatch wrote for this play (some of Movy's servers): nothing to fetch as it is
        throw const DownloadRefused("Questa sorgente non si può scaricare. Scegline un'altra da Sorgenti e riprova.");
      } else {
        r = DownloadRequest(
          title: widget.media.title,
          detail: detail,
          poster: widget.media.poster(),
          kind: src.hls ? DownloadKind.hls : DownloadKind.file,
          url: url,
          headers: src.headers,
          exactHeaders: widget.server is DirectPlayback,
          audioLanguage: _audioNow?.language,
          subtitleLanguage: PlaybackPrefs.autoOn(_kind) ? PlaybackPrefs.subtitles(_kind).value : null,
        );
      }
      await Downloads.instance.add(r);
      say('Added to Downloads: ${[widget.media.title, ?ep?.code].join(' · ')}');
      if (mounted) setState(() => _panel = false); // the menu is done; the notice says the rest
    } on DownloadRefused catch (e) {
      say(e.message, icon: Icons.error_outline_rounded);
    } catch (_) {
      say("Impossibile avviare il download.", icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _copyLink() async {
    if (!_canCopyLink) return;
    await Clipboard.setData(ClipboardData(text: _playUrl));
    if (!mounted) return;
    showToast(context, const Text('Link copiato', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.link_rounded);
  }

  Future<void> _openExternal(pz.ExternalPlayer p) async {
    if (_playUrl.isEmpty || widget.party) return;
    final ep = _ep;
    final title = ep == null ? widget.media.title : '${widget.media.title} · ${ep.code}';
    final headers = _sources.isEmpty ? const <String, String>{} : _sources[_source].headers;
    final err = await p.open(_playUrl, start: _position.value, title: title, headers: headers);
    if (!mounted) return;
    if (err == null) {
      unawaited(_player.pause());
      setState(() => _panel = false);
    }
    showToast(
      context,
      Text(err ?? 'In riproduzione su ${p.name} · Lorewatch è in pausa', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      icon: err == null ? Icons.open_in_new_rounded : Icons.error_outline_rounded,
    );
  }

  void _applySubDelay() {
    _player.setProperty('sub-delay', (_subOffset - _offset).toStringAsFixed(3));
  }

  Future<void> _loadAndPlay() async {
    final id = ++_loadId;
    final ep = _ep;
    final viaNext = _nextPressed; // only this load: an episode picked in the list isn't "next"
    _nextPressed = false;
    final saved = widget.server != null ? null : WatchProgress.find(widget.media);
    final room = widget.party ? WatchParty.state.value : null;
    if (_follower &&
        _resumeOverride == null &&
        room != null &&
        !room.isMusic &&
        !room.isLive &&
        room.media.key == widget.media.key &&
        room.season == ep?.season &&
        room.episode == ep?.number &&
        room.now > 5) {
      _resumeOverride = Duration(milliseconds: (room.now * 1000).round());
    }
    _resumeAt = _resumeOverride ??
        (saved != null && saved.season == ep?.season && saved.episode == ep?.number && saved.fraction < WatchProgress.finishedAt ? saved.position : null);
    _resumeOverride = null;
    // carrying on with this film or episode: the subtitle and timing you had beat Settings
    final sameEp = saved != null && saved.season == ep?.season && saved.episode == ep?.number;
    _restoreSub = sameEp && !_follower ? saved.subtitle : null;
    if (_restoreSub != null && _restoreSub!['off'] != true) _subOffset = saved!.subDelay;
    _player.stop();
    _subPath = null;
    setState(() {
      _loadingSources = true;
      _started = false;
      _error = null;
      _loadNote = null;
      _sources = [];
      _source = 0;
      _segments = const [];
      _segNow = null;
      _segDismissed.clear();
      _serverState.clear();
      _userPicked = false;
      _chapters = const [];
      _buffered.value = Duration.zero;
      _subtitleTracks = [];
      _builtIn = const [];
      _embeddedSid = null;
      _subsChosen = false;
      _activeSubTrack = null;
      _cues = const [];
      _subsLoading = true;
    });
    _animeStreams.clear();
    _addonSubs = const [];
    if (widget.server != null) return _loadServer(id);
    // a party guest plays the host's exact link when they share one
    _sharedUrl = null;
    if (_follower && await _playShared(id)) return;
    if (!mounted || id != _loadId) return;
    if (_pick != null) return _loadPicked(id, viaNext: viaNext);
    // the host shared a source but is still finding this episode's: wait for it
    if (_follower && WatchParty.state.value?.source != null) return;
    if (widget.anime != null) return _loadAnime(id);
    final subs = _filmSubtitles(ep);
    if (!widget.media.isTv || ep != null) {
      fetchSegments(tmdbId: widget.media.id, season: ep?.season, episode: ep?.number).then((s) {
        if (mounted && id == _loadId) setState(() => _segments = s);
      });
    }
    // A party guest looks in the host's sources, in the host's order, starting with the one
    // they're playing; everyone else in their own (Settings → Sources).
    final host = _follower ? WatchParty.state.value : null;
    final theirs = filmSourcesFrom(host?.sources ?? const []);
    _hostOrder = theirs.isNotEmpty;
    final session = _session = FilmSession(
      tmdbId: widget.media.id,
      isTv: widget.media.isTv,
      season: ep?.season,
      episode: ep?.number,
      order: _hostOrder ? theirs : activeFilmSources(),
      onChange: () {
        if (mounted && id == _loadId) setState(() {});
      },
    )..warmUp();
    _playingLink = null;
    _wanted = null;
    // One source at a time: the first link that plays is used, and nothing else is asked
    // unless you pick another source from the menu.
    final hit = await session.firstHit(first: host?.server, stop: () => !mounted || id != _loadId || _userPicked);
    if (!mounted || id != _loadId) return;
    if (!_userPicked) {
      if (hit == null) {
        setState(() {
          _loadingSources = false;
          _error = 'Nessuna sorgente trovata';
        });
      } else {
        await _playLink(hit);
      }
    }
    _loadSubtitles(id, await subs);
  }

  // ── a party guest: the host's own stream ──

  /// The link the host is streaming this episode from, when they share one: everyone in the
  /// room plays the same file (their debrid link, their source's stream). Waits a while for it
  /// while the host is still finding theirs. False: find our own (the host streams peer to peer
  /// or from their own server, theirs wouldn't play here, or none came).
  Future<bool> _playShared(int id) async {
    Map<String, dynamic>? link() {
      final s = WatchParty.state.value, ep = _ep;
      if (s == null || s.isMusic || s.isLive || s.media.key != widget.media.key || s.season != ep?.season || s.episode != ep?.number) return null;
      return s.link;
    }

    var l = link();
    if (l == null) {
      setState(() => _loadNote = "In attesa dello stream dell'host…");
      final until = DateTime.now().add(const Duration(seconds: 25));
      while (l == null && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || id != _loadId) return true;
        l = link();
      }
      setState(() => _loadNote = null);
    }
    final m = l;
    final url = m?['url'];
    if (m == null || url is! String || url.isEmpty || url == _sharedSkip) return false;
    final headers = <String, String>{
      if (m['headers'] is Map) for (final e in (m['headers'] as Map).entries) '${e.key}': '${e.value}',
    };
    final src = StreamSource(
      url: url,
      server: '${m['server'] ?? 'Host'}',
      quality: '${m['quality'] ?? ''}',
      referrer: '${m['referrer'] ?? ''}',
      userAgent: '${m['userAgent'] ?? ''}',
      headers: headers,
      hls: m['hls'] != false,
      audio: m['audio'] is String ? m['audio'] as String : null,
      qualities: [
        if (m['qualities'] is List)
          for (final q in m['qualities'] as List)
            if (q is Map && q['url'] is String) (label: '${q['label'] ?? ''}', url: q['url'] as String),
      ],
    );
    final proxy = StreamProxy.instance;
    proxy.useHeaders(src.url, headers);
    for (final q in src.qualities) {
      proxy.useHeaders(q.url, headers);
    }
    _sharedUrl = url;
    final ep = _ep;
    if (widget.anime == null && (!widget.media.isTv || ep != null)) {
      fetchSegments(tmdbId: widget.media.id, season: ep?.season, episode: ep?.number).then((s) {
        if (mounted && id == _loadId) setState(() => _segments = s);
      });
    }
    setState(() {
      _sources = [src];
      _source = 0;
      _loadingSources = false;
      _serverState[src.server] = _Srv.ready;
    });
    final room = WatchParty.state.value;
    await _playSource(src, at: room != null && room.now > 5 ? Duration(milliseconds: (room.now * 1000).round()) : _resumeAt);
    if (!mounted || id != _loadId) return true;
    _watchShared(url, id);
    if (widget.anime != null) {
      _fetchAddonSubs(id);
      _useAnimeExtras(src, id);
    } else {
      _loadSubtitles(id, await _filmSubtitles(ep));
    }
    return true;
  }

  /// The host's link hasn't started here in 20 s (tied to their connection, say): find our own.
  void _watchShared(String url, int id) {
    Timer(const Duration(seconds: 20), () {
      if (!mounted || id != _loadId || _sharedUrl != url || _player.state.duration > Duration.zero) return;
      _sharedSkip = url;
      _sharedUrl = null;
      _switch("Lo stream dell'host non parte qui. Ne cerco un altro", () {});
      _loadAndPlay();
    });
  }

  /// The stream playing here, for the room's guests to play too (see [_playShared]). `own`: it
  /// only exists on this machine (our torrent engine, your own media server) or none was found,
  /// so guests look for their own. Null while it's still loading.
  Map<String, dynamic>? get _shareLink {
    if (widget.server != null) return const {'own': true};
    if (_loadingSources) return null;
    if (_torrent != null) return const {'own': true};
    if (_sources.isEmpty || _source >= _sources.length) return _error != null ? const {'own': true} : null;
    final s = _sources[_source];
    final host = Uri.tryParse(s.url)?.host ?? '';
    if (!s.url.startsWith('http') || host.isEmpty || host == 'localhost' || host == '127.0.0.1' || host == '::1') return const {'own': true};
    final l = <String, dynamic>{
      'url': s.url,
      'server': s.server,
      'quality': s.quality,
      'hls': s.hls,
      if (s.headers.isNotEmpty) 'headers': s.headers,
      if (s.referrer.isNotEmpty) 'referrer': s.referrer,
      if (s.userAgent.isNotEmpty) 'userAgent': s.userAgent,
      'audio': ?s.audio,
      if (s.qualities.isNotEmpty) 'qualities': [for (final q in s.qualities.take(4)) {'label': q.label, 'url': q.url}],
    };
    // the room's state has a size cap: the other qualities go first
    if (jsonEncode(l).length > 3000) l.remove('qualities');
    return jsonEncode(l).length > 3000 ? const {'own': true} : l;
  }

  // ── your own server (Plex, Jellyfin, Emby) ──

  Future<void> _loadServer(int id) async {
    final ServerStream stream;
    try {
      stream = await widget.server!.open(_ep);
    } catch (e) {
      if (!mounted || id != _loadId) return;
      setState(() {
        _loadingSources = false;
        _subsLoading = false;
        _error = serverError(e);
      });
      return;
    }
    if (!mounted || id != _loadId) return;
    final src = stream.source;
    stream.segments?.then((s) {
      if (mounted && id == _loadId) setState(() => _segments = s);
    });
    setState(() {
      _sources = [src];
      _source = 0;
      _loadingSources = false;
      _serverState[src.server] = _Srv.ready;
    });
    _resumeAt ??= stream.resumeAt;
    await _playSource(src, at: _resumeAt);
    if (!mounted || id != _loadId) return;
    _loadSubtitles(id, stream.subtitles);
  }

  // ── a source picked from your addons ──

  /// Your subtitle addons' files for the episode now playing (none when you have none).
  Future<List<sub.SubtitleTrack>> _addonSubtitles(PlayerEpisode? ep) async {
    if (Addons.subtitleAddons.isEmpty) return const [];
    try {
      final t = await Addons.target(widget.media, season: ep?.season, episode: ep?.number, anime: widget.anime?.anime);
      return await Addons.subtitles(t);
    } catch (_) {
      return const [];
    }
  }

  /// Films and shows: the usual subtitle sites plus your subtitle addons.
  Future<List<sub.SubtitleTrack>> _filmSubtitles(PlayerEpisode? ep) async {
    final l = await Future.wait([
      sub.fetchSubtitles(widget.media, season: ep?.season, episode: ep?.number).catchError((Object _) => <sub.SubtitleTrack>[]),
      _addonSubtitles(ep),
    ]);
    return [...l[0], ...l[1]];
  }

  /// Anime: the addons' files join the servers' in the merged menu as they arrive.
  void _fetchAddonSubs(int id) {
    _addonSubtitles(_ep).then((l) {
      if (!mounted || id != _loadId || l.isEmpty) return;
      _addonSubs = l;
      if (_sources.isNotEmpty && _source < _sources.length) _useAnimeExtras(_sources[_source], id);
    });
  }

  /// Peers and speed for the torrent playing, once a second, for the line under the spinner.
  void _watchTorrent(String hash) {
    _torrent = hash;
    _torrentTimer?.cancel();
    _torrentTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || _torrent != hash || !(_buffering || _loadingSources)) return;
      final t = await Torrents.stats(hash);
      if (t == null || !mounted || _torrent != hash) return;
      final speed = t.downloadSpeed >= 1e6 ? '${(t.downloadSpeed / 1e6).toStringAsFixed(1)} MB/s' : '${(t.downloadSpeed / 1e3).round()} KB/s';
      final note = t.fileStats.isEmpty
          ? (t.activePeers > 0 ? 'Recupero della lista dei file da ${t.activePeers} peer…' : 'Ricerca di peer…')
          : '${t.activePeers} peer · $speed';
      if (note != _torrentNote) setState(() => _torrentNote = note);
    });
  }

  // ── built-in subtitles ──

  /// Text subtitle tracks inside the video file (an MKV's), from mpv's track list. Pictures (PGS,
  /// VobSub) are left out: they have no text for the overlay to draw.
  Future<void> _scanEmbedded() async {
    if (!mounted) return;
    final mpv = _player;
    final id = _loadId;
    Future<String> get(String p) async {
      try {
        return await mpv.getProperty(p) ?? '';
      } catch (_) {
        return '';
      }
    }

    final n = int.tryParse(await get('track-list/count')) ?? 0;
    final found = <sub.SubtitleTrack>[];
    for (var i = 0; i < n; i++) {
      if (await get('track-list/$i/type') != 'sub' || await get('track-list/$i/external') == 'yes') continue;
      final codec = (await get('track-list/$i/codec')).toLowerCase();
      if (!const {'subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text'}.contains(codec)) continue;
      final sid = await get('track-list/$i/id');
      final lang = await get('track-list/$i/lang');
      final title = await get('track-list/$i/title');
      final forced = await get('track-list/$i/forced') == 'yes';
      found.add(sub.subtitleTrack(
        'builtin-$sid',
        'Built in',
        lang.isEmpty ? 'und' : lang,
        'mpv-sid:$sid',
        release: [if (title.isNotEmpty) title, if (forced) 'Forced'].join(' · '),
        format: codec == 'ass' || codec == 'ssa' ? 'ass' : 'srt',
      ));
    }
    if (!mounted || id != _loadId) return;
    // the file's chapters, for the rail
    final chapters = <PlayerChapter>[];
    final count = int.tryParse(await get('chapter-list/count')) ?? 0;
    for (var i = 0; i < count; i++) {
      final at = double.tryParse(await get('chapter-list/$i/time'));
      if (at == null) continue;
      final title = (await get('chapter-list/$i/title')).trim();
      chapters.add(PlayerChapter(Duration(milliseconds: ((at + _offset) * 1000).round()), title.isEmpty ? 'Capitolo ${i + 1}' : title));
    }
    if (!mounted || id != _loadId) return;
    final files = _builtIn.where((t) => !t.url.startsWith('mpv-sid:'));
    setState(() {
      _builtIn = [...found, ...files];
      _chapters = chapters;
    });
    _pickBuiltIn(id);
  }

  /// The badges for what's on screen: the addon stream's, or the picture size on our own servers.
  List<SourceBadge> get _nowBadges {
    final p = _pick?.stream;
    if (p != null) return p.badges;
    final w = _videoW;
    if (w <= 0) return const [];
    return Badges.of(w >= 3000 ? '2160p' : (w >= 1800 ? '1080p' : (w >= 1200 ? '720p' : '480p')));
  }

  /// Subtitle files that came in the torrent, served by the engine; the language is read from
  /// the file name ("Movie.en.srt", "Subs/2_English.srt").
  Future<void> _torrentSubtitles(String hash, int id) async {
    final files = await Torrents.subtitleFiles(hash);
    if (files.isEmpty || !mounted || id != _loadId) return;
    final tracks = <sub.SubtitleTrack>[];
    for (final (i, f) in files.indexed) {
      final name = f.path.split(RegExp(r'[/\\]')).last;
      final words = name.replaceFirst(RegExp(r'\.[^.]+$'), '').split(RegExp(r'[\s._\-\[\]()]+')).where((w) => w.isNotEmpty).toList();
      String? lang;
      for (final w in words.reversed.take(3)) {
        lang = sub.exactLanguage(w);
        if (lang != null) break;
      }
      final ext = name.split('.').last.toLowerCase();
      tracks.add(sub.subtitleTrack('torrent-$i', 'Built in', lang ?? 'und', f.url, release: name, format: ext == 'ssa' ? 'ass' : ext));
    }
    if (!mounted || id != _loadId) return;
    setState(() => _builtIn = [..._builtIn.where((t) => t.url.startsWith('mpv-sid:')), ...tracks]);
    _pickBuiltIn(id);
  }

  /// With subtitles turning on by themselves, a built-in track in the Settings language (timed
  /// to this very file) beats one found online, unless one was picked by hand.
  void _pickBuiltIn(int id) {
    final r = _restoreSub;
    if (r != null && !_subsChosen && !_follower && id == _loadId) {
      // the one you had was inside the video: it's back as soon as the file lists it
      final url = r['url'];
      if (url is String && url.startsWith('mpv-sid:')) {
        final t = _builtIn.where((b) => b.url == url).firstOrNull;
        if (t != null) {
          _restoreSub = null;
          _subsChosen = true;
          _setSubtitleTrack(t);
        }
      }
      return; // the one you had comes first; nothing is picked for you meanwhile
    }
    if (!PlaybackPrefs.autoOn(_kind) || _subsChosen || _follower || id != _loadId) return;
    if (_activeSubTrack?.provider == 'Built in') return;
    final mine = sub.inLanguage(_builtIn, sub.preferredLang());
    final pick = mine.where((t) => !t.release.contains('Forced')).firstOrNull ?? mine.firstOrNull;
    if (pick != null) _setSubtitleTrack(pick);
  }

  /// Another source picked in the overlay: plays from where the video is now. (The old one's
  /// torrent, if it was one, is let go once the new one takes over.)
  void _usePick(AddonPick p) {
    setState(() => _sourcesOverlay = false);
    final now = _pick?.stream;
    if (now != null && (p.stream.torrent ? p.stream.infoHash == now.infoHash && p.stream.fileIdx == now.fileIdx : p.stream.url == now.url)) return;
    _resumeOverride = _position.value > const Duration(seconds: 5) ? _position.value : null;
    _pick = p;
    // picked by hand: the next episodes follow this one, not the best
    _bestPicked = false;
    _bestRest = const [];
    _switch('Passo a ${p.stream.addon.name}', () {});
    _loadAndPlay();
  }

  // ── "Autoplay the best source" (Settings → Playback, for streaming mode off) ──
  // It never plays anything by itself. You pick the first source; the Next episode button (the
  // Up next card too) then plays the best match for the next one, by your autoplay order.

  bool _bestPicked = false; // what's playing was chosen for you (by Next), not picked by hand
  List<AddonPick> _bestRest = const []; // the next best ones, should it not play
  int _bestTries = 0;

  /// Next was pressed for the episode about to load. [_loadAndPlay] takes it and clears it.
  bool _nextPressed = false;

  bool get _autoBest => _bestPicked && AppSettings.autoplayBest.value;

  /// Your addons' streams for [ep] in the order to try them: your autoplay order from Settings,
  /// or best first without one ([Addons.best]). Without the ones that would have to ask first:
  /// a torrent goes through your debrid service, or peer to peer once you've allowed that
  /// (never for a room, where everyone has to). Among equals, [like]'s release.
  Future<List<AddonPick>> _findBest(PlayerEpisode? ep, {AddonPick? like}) async {
    try {
      final t = like?.target.withEpisode(ep?.season, ep?.number) ??
          await Addons.target(widget.media, season: ep?.season, episode: ep?.number, anime: widget.anime?.anime);
      final p2p = AppSettings.p2pStreaming.value && !widget.party;
      final list = await Addons.best(t, where: (s) => !s.torrent || Debrid.active || p2p);
      final group = like?.stream.bingeGroup;
      if (group != null && list.isNotEmpty) {
        final same = list.takeWhile((s) => s.rank == list.first.rank).where((s) => s.bingeGroup == group).firstOrNull;
        if (same != null) {
          list
            ..remove(same)
            ..insert(0, same);
        }
      }
      return [for (final s in list) AddonPick(s, t)];
    } catch (_) {
      return const [];
    }
  }

  void _useBest(List<AddonPick> found) {
    _pick = found.first;
    _bestRest = found.sublist(1);
    _bestPicked = true;
    _bestTries = 0;
    final s = found.first.stream;
    showToast(
      context,
      Text(
        'Best source: ${[if (s.quality != 'SD') s.quality, ?s.audio, ?s.channels, s.addon.name].join(' · ')}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      icon: Icons.auto_awesome_rounded,
    );
  }

  /// The best source didn't play: the next one down your order, a few times over.
  bool _nextBest(int id) {
    if (!mounted || id != _loadId || !_autoBest || _bestRest.isEmpty || _bestTries >= 4) return false;
    _bestTries++;
    _pick = _bestRest.first;
    _bestRest = _bestRest.sublist(1);
    setState(() {
      _error = null;
      _loadingSources = true;
      _loadNote = "Quella non è partita. Provo la migliore successiva…";
    });
    unawaited(_loadPicked(id));
    return true;
  }

  /// Nothing to play [ep] from by itself: its sources screen, to pick from.
  void _toSources(PlayerEpisode? ep) {
    if (widget.embedded) return;
    if (widget.mini) {
      // the small window has no page of its own to swap for the list
      showToast(
        context,
        Text(
          "Nessuna sorgente trovata per ${ep == null ? widget.media.title : episodeLabel(ep.season, ep.number)}",
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        icon: Icons.error_outline_rounded,
      );
      widget.onClose?.call();
      return;
    }
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      settings: const RouteSettings(name: SourcesPage.route),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => SourcesPage(media: widget.media, episode: ep, runtime: widget.runtime, anime: widget.anime),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  /// Plays the picked stream. Another episode comes from the same addon, the same release when
  /// it has it. The exception is the Next episode button with "Autoplay the best source" on
  /// ([viaNext]): then every addon is asked and the best match by your autoplay order plays,
  /// staying with the source you had only when nothing fits. An episode picked in the list is
  /// never chosen for you. When nothing has the episode, its sources screen opens.
  Future<void> _loadPicked(int id, {bool viaNext = false}) async {
    final ep = _ep;
    var pick = _pick!;
    final t = pick.target;
    if (ep != null && (t.episode != ep.number || (!t.anime && t.season != ep.season))) {
      if (_follower) return; // the host sends the next episode's source
      AddonPick? next;
      if (viaNext && _playsBest) {
        setState(() => _loadNote = 'Ricerca della sorgente migliore…');
        final found = await _findBest(ep, like: pick);
        if (!mounted || id != _loadId) return;
        _loadNote = null;
        if (found.isNotEmpty) {
          _useBest(found);
          next = found.first;
        }
      }
      if (next == null) {
        next = await Addons.follow(pick, ep.season, ep.number);
        if (!mounted || id != _loadId) return;
        // following what you picked: there's no "next best" lined up behind it
        _bestPicked = false;
        _bestRest = const [];
      }
      if (next == null) return _toSources(ep);
      pick = _pick = next;
    }
    // a torrent from the last episode stops downloading
    final was = _torrent;
    if (was != null && was != pick.stream.infoHash) {
      _torrent = null;
      unawaited(Torrents.release(was));
    }
    // debrid on: the service fetches the torrent and hands back an HTTPS link, no P2P here
    final viaDebrid = pick.stream.torrent && Debrid.active;
    // P2P turned off since (the next episode's torrent, say): ask before the engine starts
    if (pick.stream.torrent && !viaDebrid && !await allowP2p(context)) {
      if (!mounted || id != _loadId) return;
      setState(() {
        _loadingSources = false;
        _error = 'Lo streaming P2P è disattivato. Scegli un\'altra sorgente.';
      });
      return;
    }
    if (!mounted || id != _loadId) return;
    // Your room, through your debrid account: everyone there plays the link it makes. Asked
    // once per room; the sources list asks first, this catches every other way in (the next
    // episode, a source changed from the player, the room reopened after a restart).
    if (viaDebrid && _host && !await allowDebridInRoom(context)) {
      if (!mounted || id != _loadId) return;
      setState(() {
        _loadingSources = false;
        _error = 'Non condivisa con la stanza. Scegli un\'altra sorgente.';
      });
      return;
    }
    if (!mounted || id != _loadId) return;
    final StreamSource src;
    if (viaDebrid) {
      final st = pick.stream;
      setState(() => _loadNote = 'Lo prendo da ${Debrid.name}…');
      try {
        final f = await Debrid.resolve(st, season: widget.anime != null ? null : ep?.season, episode: ep?.number, episodeTitle: ep?.name);
        if (!mounted || id != _loadId) return;
        unawaited(Torrents.forgetPrepared());
        _loadNote = null;
        src = StreamSource(url: f.downloadUrl, server: st.addon.name, quality: st.quality, referrer: '', userAgent: '', hls: false);
      } catch (e) {
        if (!mounted || id != _loadId) return;
        if (_nextBest(id)) return;
        final why = '$e'.replaceFirst(RegExp(r'^\w*Exception[^:]*:\s*'), '').trim();
        setState(() {
          _loadNote = null;
          _loadingSources = false;
          _error = "${Debrid.name} couldn't get this one${why.isEmpty || why.length > 140 ? '' : ': $why'}. Try another source.";
        });
        return;
      }
    } else if (pick.stream.torrent) {
      // peer to peer: our engine fetches it and the player streams it from 127.0.0.1
      final st = pick.stream;
      _watchTorrent(st.infoHash!);
      setState(() => _torrentNote = 'Ricerca di peer…');
      try {
        // the season and episode are for a source that names no file (the built-in one): the
        // episode's file is then found by name. Anime has no season number here, as with debrid.
        final url = await Torrents.open(
          st.infoHash!,
          fileIdx: st.fileIdx,
          filename: st.filename,
          trackers: st.trackers,
          title: st.release,
          season: widget.anime != null ? null : ep?.season,
          episode: ep?.number,
          episodeTitle: ep?.name,
        );
        if (!mounted || id != _loadId) return;
        unawaited(_torrentSubtitles(st.infoHash!, id));
        unawaited(Torrents.forgetPrepared()); // ones only pointed at on the sources list go
        src = StreamSource(url: url, server: st.addon.name, quality: st.quality, referrer: '', userAgent: '', hls: false);
      } catch (e) {
        if (!mounted || id != _loadId) return;
        if (_nextBest(id)) return;
        setState(() {
          _loadingSources = false;
          _error = e is EpisodeNotInTorrent
              ? "Questo torrent non ha quell'episodio. Prova un'altra sorgente."
              : 'Nessun peer per questo torrent ora. Prova un\'altra sorgente.';
        });
        return;
      }
    } else {
      src = Addons.sourceOf(pick);
    }
    if (widget.anime == null && (!widget.media.isTv || ep != null)) {
      fetchSegments(tmdbId: widget.media.id, season: ep?.season, episode: ep?.number).then((s) {
        if (mounted && id == _loadId) setState(() => _segments = s);
      });
    }
    setState(() {
      _sources = [src];
      _source = 0;
      _loadingSources = false;
      _loadNote = null;
      _serverState[src.server] = _Srv.ready;
    });
    await _playSource(src, at: _resumeAt);
    if (!mounted || id != _loadId) return;
    if (widget.anime != null) {
      // the anime servers' subtitles (MegaPlay, ReCloud…) and your addons', together
      _fetchAddonSubs(id);
      _useAnimeExtras(src, id);
    } else {
      _loadSubtitles(id, await _filmSubtitles(ep));
    }
  }

  // ── anime ──

  final _animeStreams = <String, AnimeStream>{}; // server name → its stream, with subtitles and skip times

  /// The servers on offer: the anime ones for anime, the film ones otherwise.
  List<({String name, String? audio, String? note})> get _servers => widget.server != null
      ? [(name: widget.server!.label, audio: null, note: widget.server!.note)]
      : _pick != null
      ? [
          (
            name: _pick!.stream.addon.name,
            audio: null,
            note: [?_pick!.stream.source, ?_pick!.stream.hdr, ?_pick!.stream.sizeLabel, if (_pick!.stream.cached) 'cached'].join(' · '),
          ),
        ]
      : widget.anime != null
      ? [for (final s in animeServersFor(widget.anime!.anime)) (name: s.name, audio: s.audio, note: s.note)]
      // films: Movy's servers, for the dubbed-audio rows (the Sources menu has its own pane)
      : [
          for (final l in _session?.links ?? const <FilmLink>[])
            if (l.source.scraper == null && l.state != FilmState.dead) (name: l.name, audio: l.audio, note: null),
        ];

  bool get _films => widget.server == null && _pick == null && widget.anime == null;

  /// The other languages the source that's playing has, each on a link of its own (VidBolt can
  /// have twenty): one row per language, on the first of its links that hasn't failed. Movy's
  /// dubbed servers have their own rows.
  List<MenuAudio> get _linkLanguages {
    final now = _playingLink, session = _session;
    if (!_films || now == null || session == null || now.source.scraper == null) return const [];
    final seen = <String>{?now.audio?.toLowerCase()};
    return [
      for (final l in session.links)
        if (l.source == now.source && l != now && l.audio != null && l.state != FilmState.dead && seen.add(l.audio!.toLowerCase()))
          MenuAudio(
            title: audioLabel(l.audio!),
            detail: [l.name, if (l.quality.isNotEmpty) l.quality, ?l.format].join(' · '),
            onTap: () => _tapLink(l),
          ),
    ];
  }

  /// While the first link is being found: which source it's on.
  String? get _searchNote {
    final session = _session;
    if (!_loadingSources || !_films || session == null) return null;
    final list = session.sources;
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      final l = s.links.where((l) => l.state == FilmState.trying).firstOrNull;
      if (s.state == FilmState.trying || l != null) {
        return 'Provo ${s.isMovy && l != null ? l.name : s.source.name}  ·  ${i + 1} di ${list.length}';
      }
    }
    return null;
  }

  /// Anime: the anime servers in order, each with a 2.5 s head start, as for films. The dub
  /// first when that's what was last picked (falling back to the original when there's none),
  /// otherwise the original only. Subtitles and skip times come with whichever stream plays.
  Future<void> _loadAnime(int id) async {
    _fetchAddonSubs(id);
    final all = animeServersFor(widget.anime!.anime);
    final want = AppSettings.animeAudio.value;
    final dub = want.isNotEmpty && all.any((s) => s.audio == want);
    final order = [...all.where((s) => dub ? s.audio == want : s.audio == null), if (dub) ...all.where((s) => s.audio == null)];
    final first = Completer<StreamSource?>();
    final asked = <Future<void>>[];
    for (final server in order) {
      if (first.isCompleted || !mounted || id != _loadId || _userPicked) break;
      final f = _resolveAnime(server, id).then((s) {
        if (s != null && !first.isCompleted) first.complete(s);
      });
      asked.add(f);
      await Future.any([f, Future<void>.delayed(const Duration(milliseconds: 2500))]);
    }
    if (!first.isCompleted) {
      unawaited(Future.wait(asked).then((_) {
        if (!first.isCompleted) first.complete(null);
      }));
    }
    final found = await first.future;
    if (!mounted || id != _loadId || _userPicked) return;
    if (found == null) {
      setState(() {
        _loadingSources = false;
        _subsLoading = false;
        _error = 'Nessuna sorgente trovata';
      });
      return;
    }
    setState(() {
      _loadingSources = false;
      _source = _sources.indexOf(found);
    });
    await _playSource(found, at: _resumeAt);
    _useAnimeExtras(found, id);
  }

  Future<StreamSource?> _resolveAnime(AnimeServer server, int id) async {
    final have = _sources.where((s) => s.server == server.name).firstOrNull;
    if (have != null) return have;
    setState(() => _serverState[server.name] = _Srv.loading);
    final found = await server.fetch(widget.anime!.anime, _ep?.number ?? 1);
    if (!mounted || id != _loadId) return null;
    setState(() {
      _serverState[server.name] = found == null ? _Srv.dead : _Srv.ready;
      if (found != null) {
        _sources.add(found.source);
        _animeStreams[server.name] = found;
      }
    });
    // a newly resolved source may carry subtitles the playing source doesn't — refresh the
    // merged subtitle list so they show up immediately
    if (found != null && found.subtitles.isNotEmpty && _source >= 0 && _source < _sources.length) {
      _useAnimeExtras(_sources[_source], id);
    }
    return found?.source;
  }

  int _subsSweep = -1; // the load whose subtitle servers were asked

  /// Resolves, in the background, every subtitle-carrying server not yet asked (ones still
  /// loading add theirs when they land). Each one that answers refreshes the merged menu.
  Future<void> _sweepSubtitles(int id) async {
    final rest = [
      for (final s in animeServersFor(widget.anime!.anime))
        if (s.subtitles && !_animeStreams.containsKey(s.name) && _serverState[s.name] == null) s,
    ];
    await Future.wait(rest.map((s) => _resolveAnime(s, id)));
  }

  /// The skip times from the playing source, and subtitles aggregated from every resolved source
  /// (so you always get the full subtitle menu, whichever server is playing the video).
  void _useAnimeExtras(StreamSource src, int id) {
    if (!mounted || id != _loadId) return;
    final s = _animeStreams[src.server]; // null for a source picked from your addons
    if (s != null) setState(() => _segments = s.segments);
    // once per episode: ask every server that carries subtitles, so their tracks join the menu
    // without anyone opening them
    if (_subsSweep != id) {
      _subsSweep = id;
      unawaited(_sweepSubtitles(id));
    }
    // merge subtitles from all resolved sources, the playing source first; the same file once
    final seen = <String>{};
    final all = <sub.SubtitleTrack>[];
    for (final name in [src.server, ..._animeStreams.keys.where((k) => k != src.server)]) {
      for (final t in _animeStreams[name]?.subtitles ?? const <sub.SubtitleTrack>[]) {
        if (seen.add(t.url)) all.add(t);
      }
    }
    for (final t in _addonSubs) {
      if (seen.add(t.url)) all.add(t);
    }
    _loadSubtitles(id, all);
  }

  Future<void> _pickAnime(AnimeServer server) async {
    if (_serverState[server.name] == _Srv.loading) return;
    final id = _loadId;
    _userPicked = true;
    AppSettings.animeAudio.set(server.audio ?? ''); // the next episode starts in the same language
    final found = await _resolveAnime(server, id);
    if (!mounted || id != _loadId) return;
    if (found == null) {
      showToast(
        context,
        Text("${server.name} non ce l'ha", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    final i = _sources.indexOf(found);
    if (_loadingSources) {
      setState(() {
        _loadingSources = false;
        _error = null;
        _source = i;
      });
      await _playSource(found, at: _resumeAt);
      _useAnimeExtras(found, id);
    } else {
      _pickSource(i);
    }
  }

  /// A server picked from the Sources list or a dubbed audio row, by name.
  void _pickNamed(String name) {
    if (widget.anime != null) {
      final s = animeServers.where((x) => x.name == name).firstOrNull;
      if (s != null) _pickAnime(s);
    } else {
      final l = _session?.links.where((x) => x.source.scraper == null && x.name == name).firstOrNull;
      if (l != null) _tapLink(l);
    }
  }

  /// The next anime episode, while there is one out.
  void _animeNext() {
    final t = widget.anime!, ep = _ep;
    final n = (ep?.number ?? 1) + 1;
    if (ep == null || (t.episodes != null && n > t.episodes!)) {
      showToast(context, const Text("È l'ultimo episodio", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.check_rounded);
      return;
    }
    _saveProgress();
    _switch('Caricamento E$n', () {
      _ep = PlayerEpisode(season: 0, number: n, name: t.names[n]);
      _upNext = null;
      _episodes = false;
      _subOffset = 0;
    });
    _poke();
    _nextPressed = true;
    _loadAndPlay();
    _partyReport(position: Duration.zero);
  }

  /// Plays [l], which answered: the first one, or in place of what's on.
  Future<void> _playLink(FilmLink l) async {
    final src = l.stream;
    if (src == null || !mounted) return;
    var i = _sources.indexOf(src);
    if (i < 0) {
      _sources.add(src);
      i = _sources.length - 1;
    }
    _playingLink = l;
    if (_loadingSources || i == _source) {
      // nothing is playing yet
      setState(() {
        _loadingSources = false;
        _error = null;
        _source = i;
      });
      await _playSource(src, at: _resumeAt);
    } else {
      _pickSource(i);
    }
    _partyReport();
  }

  /// From the Sources menu (or a dubbed audio row): check that link now and switch to it. The
  /// start-up search stops here.
  Future<void> _tapLink(FilmLink l) async {
    final session = _session;
    if (session == null || l == _playingLink) return;
    final id = _loadId;
    _userPicked = true;
    _startTimer?.cancel();
    _wanted = l;
    final src = await session.open(l);
    if (!mounted || id != _loadId || _wanted != l) return;
    _wanted = null;
    if (src == null) {
      final what = l.source.scraper == null ? l.name : '${l.name} su ${l.source.name}';
      showToast(context, Text("$what non lo riproduce", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
      return;
    }
    await _playLink(l);
  }

  int _subsPicked = -1; // the load whose subtitle was picked automatically

  void _loadSubtitles(int id, List<sub.SubtitleTrack> tracks) {
    try {
      if (!mounted || id != _loadId) return;
      setState(() {
        _subtitleTracks = tracks;
        _subsLoading = false;
      });
      // with Auto-enable subtitles on, the first track in the Settings language (none in it: off)
      if (_follower && !_ownSubs) {
        _partyFollow(); // the host's subtitle, not ours
      } else if (_restoreSub != null && !_subsChosen) {
        _resumeSubtitle(id);
      } else if (PlaybackPrefs.autoOn(_kind) && !_subsChosen && _subsPicked != id && _activeSubTrack?.provider != 'Built in') {
        // once per episode: later refreshes (anime servers adding their tracks) keep what's on,
        // or off
        final mine = sub.inLanguage(_subtitleTracks, sub.preferredLang());
        final pick = mine.where((t) => !t.translated).firstOrNull ?? mine.firstOrNull;
        if (pick != null) {
          _subsPicked = id;
          _setSubtitleTrack(pick);
        } else if (_activeSubTrack == null && _subtitle != 'Off') {
          setState(() => _subtitle = 'Off'); // the CC button stops claiming captions are on
        }
      }
    } catch (_) {}
  }

  /// The subtitle you had when you left this film or episode, to put back (WatchEntry.subtitle).
  Map<String, dynamic>? _restoreSub;

  /// What to remember with your progress: the subtitle on, "off" if you turned them off, or null
  /// when nothing was chosen (Settings decides next time).
  Map<String, dynamic>? get _subMemo {
    final t = _activeSubTrack;
    if (t != null) {
      return {
        'id': t.id,
        'provider': t.provider,
        'lang': t.lang,
        'language': t.language,
        'release': t.release,
        'url': t.url,
        'format': t.format,
        if (t.translated) 'translated': true,
      };
    }
    return _subsChosen ? const {'off': true} : null;
  }

  /// Puts back the subtitle (and its delay) you had: the same file from the list when it's there,
  /// otherwise straight from its link. If it can't be loaded any more, Settings' default takes over.
  Future<void> _resumeSubtitle(int id) async {
    final r = _restoreSub;
    if (r == null) return;
    if (r['off'] == true) {
      _restoreSub = null;
      _subsChosen = true;
      await _setSubtitleTrack(null);
      return;
    }
    final url = '${r['url'] ?? ''}';
    if (url.isEmpty) {
      _restoreSub = null;
      return;
    }
    if (url.startsWith('mpv-sid:')) return; // waits for the file's own tracks (_pickBuiltIn)
    _restoreSub = null;
    final listed = _subtitleTracks.where((t) => t.url == url || (t.provider == r['provider'] && t.id == r['id'])).firstOrNull;
    final track = listed ??
        sub.SubtitleTrack(
          id: '${r['id'] ?? url}',
          provider: '${r['provider'] ?? 'Sottotitoli'}',
          lang: '${r['lang'] ?? 'und'}',
          language: '${r['language'] ?? 'Sottotitoli'}',
          release: '${r['release'] ?? ''}',
          url: url,
          format: '${r['format'] ?? 'srt'}',
          translated: r['translated'] == true,
        );
    _subsChosen = true;
    await _setSubtitleTrack(track);
    if (!mounted || id != _loadId || _activeSubTrack != null) return;
    // gone from where it came from: Settings' default, at no delay
    _subsChosen = false;
    if (_subOffset != 0) {
      setState(() => _subOffset = 0);
      _applySubDelay();
    }
    _loadSubtitles(id, _subtitleTracks);
  }

  int _subSeq = 0; // the newest pick; an older one that finishes late is dropped
  Timer? _subCheckTimer;
  Timer? _syncTimer;

  static String _secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';

  Future<void> _setSubtitleTrack(sub.SubtitleTrack? track) async {
    final seq = ++_subSeq;
    SubLog.line(track == null
        ? 'PICK off'
        : 'PICK ${track.language} · ${track.provider} · ${track.format}${track.translated ? ' · translated' : ''} · ${SubLog.clip(track.release, 50)} · ${SubLog.clip(track.url, 90)}');
    _embeddedSid = null;
    if (track != null && track.url.startsWith('mpv-sid:')) {
      // a track inside the video file: mpv already has it; the overlay draws it like any other
      final sid = track.url.substring(8);
      _subPath = null;
      try {
        await _player.command(['change-list', 'sub-files', 'clr', '']);
        await _player.setProperty('sid', sid);
      } catch (e) {
        SubLog.line('  built-in #$sid FAILED: $e');
      }
      _embeddedSid = sid;
      if (mounted) setState(() { _activeSubTrack = track; _subtitle = track.language; _cues = const []; });
      _partyReport();
      unawaited(_checkSubs('after pick'));
      return;
    }
    if (track == null) {
      _subPath = null;
      await _player.command(['change-list', 'sub-files', 'clr', '']);
      await _player.selectSubtitleTrack(pz.SubtitleTrack.off);
      if (mounted) setState(() { _activeSubTrack = null; _subtitle = 'Off'; _cues = const []; });
      _syncTimer?.cancel();
      _partyReport();
      return;
    }
    try {
      if (track.translated && !_subCache.containsKey(track.url) && mounted) {
        showToast(context, Text('Traduzione dei sottotitoli in ${track.language}…', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.translate_rounded);
      }
      final sw = Stopwatch()..start();
      final cached = _subCache.containsKey(track.url);
      final content = _subCache[track.url] ??= await sub.fetchSubtitleContent(track);
      if (seq != _subSeq || !mounted) {
        SubLog.line('  dropped: another subtitle was picked while this one loaded');
        return;
      }
      final cues = parseCues(content);
      SubLog.line('  ${cached ? 'cached' : 'downloaded in ${sw.elapsedMilliseconds} ms'}: ${content.length} chars, ${cues.length} lines'
          '${cues.isEmpty ? '' : ' from ${cues.first.start.toStringAsFixed(1)}s to ${cues.last.end.toStringAsFixed(1)}s'}, starts "${SubLog.clip(content, 50)}"');
      if (cues.isEmpty) SubLog.line('  WARNING: no lines could be read from it');
      final path = await _writeSub(track, content);
      _subPath = path;
      final mpv = _player;
      await mpv.setProperty('sub-files', path);
      await mpv.command(['sub-add', path, 'select', track.language, track.lang]);
      SubLog.line('  handed to mpv: ${path.split(Platform.pathSeparator).last}');
      await _dropOtherSubs(path);
      if (mounted) setState(() { _activeSubTrack = track; _subtitle = track.language; _cues = cues; });
      _warnIfShort(cues);
      _partyReport();
      unawaited(_checkSubs('after pick'));
      if (SubLog.enabled) _syncTimer ??= Timer.periodic(const Duration(seconds: 8), (_) => _syncProbe());
    } catch (e) {
      SubLog.line('  FAILED: $e');
      if (mounted && seq == _subSeq) {
        showToast(
          context,
          Text("Impossibile caricare i sottotitoli in ${track.language} da ${track.provider}. Provane altri.", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }

  /// What mpv has for subtitles, written to the log; and if the file you picked isn't the one
  /// selected (a reload can leave another track on, or none), it's put back.
  Future<void> _checkSubs(String why, {bool retried = false}) async {
    final mpv = _player;
    final path = _subPath;
    String norm(String x) => x.replaceAll('\\', '/').toLowerCase();
    try {
      Future<String> get(String name) async => (await mpv.getProperty(name)) ?? '';
      final n = int.tryParse(await get('track-list/count')) ?? 0;
      final rows = <String>[];
      String? ours;
      var oursOn = false;
      for (var i = 0; i < n; i++) {
        if (await get('track-list/$i/type') != 'sub') continue;
        final id = await get('track-list/$i/id');
        final ext = await get('track-list/$i/external') == 'yes';
        final file = await get('track-list/$i/external-filename');
        final on = await get('track-list/$i/selected') == 'yes';
        final lang = await get('track-list/$i/lang');
        final codec = await get('track-list/$i/codec');
        final def = await get('track-list/$i/default') == 'yes';
        rows.add('#$id${on ? '(on)' : ''} ${ext ? 'file ${file.split(RegExp(r'[\\/]')).last}' : 'in-stream${def ? ' default' : ''}'} $lang $codec');
        if (path != null && ext && norm(file) == norm(path)) {
          ours = id;
          if (on) oursOn = true;
        }
      }
      SubLog.line('CHECK ($why): sid=${await get('sid')} sub-delay=${await get('sub-delay')} visible=${await get('sub-visibility')} '
          'offset=$_offset yours=$_subOffset · ${rows.isEmpty ? 'no subtitle tracks' : rows.join(' | ')}');
      if (_embeddedSid != null) {
        if (await get('sid') != _embeddedSid) {
          SubLog.line('  FIX: built-in #$_embeddedSid was not on, selecting it');
          await mpv.setProperty('sid', _embeddedSid!);
        }
        return;
      }
      if (path == null) return;
      if (ours == null) {
        // mpv may still be loading it with the video: look again before adding a second copy
        if (!retried) {
          _subCheckTimer?.cancel();
          _subCheckTimer = Timer(const Duration(milliseconds: 1500), () => _checkSubs('cerca di nuovo', retried: true));
          return;
        }
        SubLog.line('  FIX: your subtitle file was not loaded, adding it again');
        await mpv.command(['sub-add', path, 'select']);
      } else if (!oursOn) {
        SubLog.line('  FIX: your subtitle file was loaded but not on, selecting #$ours');
        await mpv.setProperty('sid', ours);
      }
    } catch (e) {
      SubLog.line('CHECK ($why) failed: $e');
    }
  }

  /// Removes subtitle files mpv still holds from earlier picks (and second copies of [keep]).
  Future<void> _dropOtherSubs(String keep) async {
    final mpv = _player;
    String norm(String x) => x.replaceAll('\\', '/').toLowerCase();
    try {
      Future<String> get(String name) async => (await mpv.getProperty(name)) ?? '';
      final n = int.tryParse(await get('track-list/count')) ?? 0;
      final drop = <String>[];
      var kept = false;
      for (var i = 0; i < n; i++) {
        if (await get('track-list/$i/type') != 'sub' || await get('track-list/$i/external') != 'yes') continue;
        final id = await get('track-list/$i/id');
        final mine = norm(await get('track-list/$i/external-filename')) == norm(keep);
        final on = await get('track-list/$i/selected') == 'yes';
        if (mine && (!kept || on) && !drop.contains(id)) {
          kept = true;
          continue;
        }
        drop.add(id);
      }
      for (final id in drop) {
        await mpv.command(['sub-remove', id]);
      }
      if (drop.isNotEmpty) SubLog.line('  removed old subtitle tracks ${drop.map((d) => '#$d').join(', ')}');
    } catch (e) {
      SubLog.line('  removing old tracks failed: $e');
    }
  }

  /// A file whose lines stop long before the film ends is for something else (a making-of, a
  /// trailer, another film of the same name): it looks like nothing was added, so say so.
  void _warnIfShort(List<SyncCue> cues) {
    final total = _duration.value.inMilliseconds / 1000;
    if (cues.isEmpty || total < 600) return;
    final end = cues.last.end;
    if (end >= total * .6) return;
    String clock(double s) => '${s ~/ 3600 > 0 ? '${s ~/ 3600}:' : ''}${((s % 3600) ~/ 60).toString().padLeft(s ~/ 3600 > 0 ? 2 : 1, '0')}:${(s % 60).floor().toString().padLeft(2, '0')}';
    SubLog.line('  WARNING: its lines end at ${end.toStringAsFixed(0)}s of a ${total.toStringAsFixed(0)}s video');
    if (!mounted) return;
    showToast(
      context,
      Text('Questi sottotitoli finiscono a ${clock(end)} di ${clock(total)}. Probabilmente sono di un altro video; provane altri.', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      icon: Icons.warning_amber_rounded,
    );
  }

  static String _plain(String s) => s.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '').replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Every few seconds while a subtitle file is on: the line mpv shows next to the line the file
  /// says should be up now, and how far off it is when they differ.
  Future<void> _syncProbe() async {
    if (!mounted || _subPath == null || _cues.isEmpty || !_started || !_playing || _reopening) return;
    try {
      final tp = double.tryParse(await _player.getProperty('time-pos') ?? '');
      if (tp == null) return;
      final shown = await _player.getProperty('sub-text') ?? '';
      final film = tp + _offset; // where we are in the film
      final at = film - _subOffset; // the file's clock
      final want = _cues.where((c) => c.start <= at && at < c.end).map((c) => c.text).join(' / ');
      if (shown.trim().isEmpty && want.trim().isEmpty) return;
      final same = _plain(shown) == _plain(want) || (_plain(want).isNotEmpty && _plain(shown).contains(_plain(want)));
      var drift = '';
      if (!same && shown.trim().isNotEmpty) {
        final p = _plain(shown);
        SyncCue? best;
        for (final c in _cues) {
          if (_plain(c.text) == p && (best == null || (c.start - at).abs() < (best.start - at).abs())) best = c;
        }
        if (best != null) drift = ' · mpv is showing the line from ${best.start.toStringAsFixed(1)}s, ${(at - best.start).toStringAsFixed(1)}s off';
      }
      SubLog.line('SYNC film ${film.toStringAsFixed(1)}s (mpv ${tp.toStringAsFixed(1)} + offset ${_offset.toStringAsFixed(1)}): '
          'shows "${SubLog.clip(shown, 45)}" · file says "${SubLog.clip(want, 45)}"${same ? '' : '  <-- DIFFERENT$drift'}');
    } catch (_) {}
  }

  /// mpv's own messages about subtitles and loading, plus every warning and error.
  void _mpvLog(pz.PlayerLog l) {
    if (!SubLog.enabled) return;
    final t = l.text.trim();
    if (t.isEmpty) return;
    final level = l.level.name;
    final subby = l.prefix.contains('sub') || l.prefix.contains('ass') || RegExp(r'\b(Subs|subtitle|sub-|--sid)', caseSensitive: false).hasMatch(t);
    if (subby || level == 'warn' || level == 'error' || level == 'fatal') SubLog.line('mpv [${l.prefix}] $level: ${SubLog.clip(t, 200)}');
  }

  /// A link that was picked for you and never gets going shouldn't leave you on the spinner:
  /// after a while, carry on the search from there, one at a time, to the next that plays.
  void _watchStart(StreamSource src, int seq) {
    _startTimer?.cancel();
    if (_userPicked) return;
    _startTimer = Timer(const Duration(seconds: 25), () async {
      final session = _session, l = _playingLink, id = _loadId;
      // the best source was a dead link (a torrent is still finding peers, so it's left be)
      if (mounted && _pick != null && _torrent == null && seq == _openSeq && _player.state.duration == Duration.zero && _nextBest(id)) return;
      if (!mounted || session == null || l == null || l.stream != src || seq != _openSeq || _userPicked || _player.state.duration > Duration.zero) {
        return;
      }
      session.giveUp(l);
      bool stop() => !mounted || id != _loadId || seq != _openSeq || _userPicked;
      final next = await session.firstHit(after: l, stop: stop);
      if (next != null && !stop()) await _playLink(next);
    });
  }

  /// Everything plays through the local relay, which sends each host the headers it expects.
  Future<void> _playSource(StreamSource src, {Duration? at}) async {
    AudioFocus.claim(this, _player.pause);
    setState(() => _error = null);
    final resume = at != null && at > const Duration(seconds: 5) ? at : null;
    if (resume != null) _holdAt(resume);
    _reopenTimer?.cancel();
    final seq = ++_openSeq;
    _watchStart(src, seq);
    _offset = 0;
    _fragmented = false;
    _timeline = null;
    _playUrl = src.url;
    setState(() {
      _variant = null;
      _variants = const [];
      _videoW = _videoH = 0;
      _displayTried = false;
    });
    if (!src.hls) {
      // plain video files (addon links, some anime servers) and DASH: mpv fetches them itself,
      // with their host's headers; one file per quality, 1080p first
      final files = [for (final q in src.qualities) StreamVariant(url: q.url, name: q.label)];
      final hd = files.indexWhere((v) => v.label == '1080p');
      setState(() {
        _variants = files;
        _variant = files.isEmpty ? null : (hd >= 0 ? hd : 0);
      });
      _playUrl = _variant == null ? src.url : files[_variant!].url;
      await _prepOpen();
      // a torrent can make the player wait on pieces still arriving: let it wait (2 min)
      // instead of giving up on the stream at 60 s
      await _player.setProperty('network-timeout', _torrent != null ? '120' : '60');
      await _player.open(pz.Media(_playUrl, headers: src.headers, start: resume));
      return;
    }
    final proxy = StreamProxy.instance;
    // Read the server's qualities first so playback starts on the right one: 1080p when it's
    // there. (mpv can't switch quality on its own, so "Auto" would always take the 4K stream.)
    final variants = src.qualities.isNotEmpty
        ? [for (final q in src.qualities) StreamVariant(url: q.url, name: q.label)]
        : await proxy.variants(src.url).catchError((Object _) => const <StreamVariant>[]);
    if (!mounted || _playUrl != src.url) return;
    final hd = variants.indexWhere((v) => v.label == '1080p');
    final pick = hd >= 0 ? hd : (src.qualities.isNotEmpty ? 0 : null);
    setState(() {
      _variants = variants;
      _variant = pick;
    });
    final url0 = pick == null ? src.url : variants[pick].url;
    _playUrl = url0;
    final frag = await proxy.fragmentedStart(url0, 0).then((s) => s != null, onError: (Object _) => false);
    final tl = frag ? await proxy.timeline(url0).catchError((Object _) => null) : null;
    if (!mounted || _playUrl != url0 || seq != _openSeq) return;
    _timeline = tl;
    _fragmented = frag && tl == null;
    if (tl != null) {
      await _prepOpen();
      await _player.open(pz.Media(tl, start: resume));
      _watchTimeline(tl, seq);
    } else if (resume != null && frag) {
      // fMP4 can't start mid-way by seeking; open a playlist trimmed at that point
      final secs = resume.inMilliseconds / 1000;
      final start = await proxy.fragmentedStart(url0, secs) ?? 0;
      final url = await proxy.wrap(url0, from: secs);
      _reopening = true;
      setState(() => _veil = true);
      _offset = start;
      await _prepOpen();
      try {
        await _player.open(pz.Media(url, start: Duration(milliseconds: ((secs - start) * 1000).round())));
      } finally {
        _reopening = false;
      }
    } else {
      final url = await proxy.wrap(url0);
      await _prepOpen();
      await _player.open(pz.Media(url, start: resume));
    }
  }

  void _switch(String note, VoidCallback change) {
    setState(() {
      change();
      _note = note;
    });
    _noteTimer?.cancel();
    _noteTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _note = null);
    });
  }

  void _openPanel([_Tab? tab]) {
    setState(() {
      if (_panel && (tab == null || tab == _tab)) {
        _panel = false;
      } else {
        _panel = true;
        if (tab != null) _tab = tab;
      }
    });
    _poke();
  }

  Future<void> _toggleFullscreen() async {
    if (widget.embedded) return widget.onExpand?.call(); // the room fills the window with it
    if (!isDesktopNative) return;
    _fullscreen = !_fullscreen;
    await windowManager.setFullScreen(_fullscreen);
    if (mounted) setState(() {});
    // refresh-rate matching only holds while full screen
    if (_fullscreen) {
      _displayTried = false;
      unawaited(_maybeMatchDisplay());
    } else {
      unawaited(_display.restore());
    }
  }

  void _openSync() {
    setState(() {
      _panel = false;
      _episodes = false;
      _sync = true;
    });
  }

  void _toggleEpisodes() {
    if (_store == null) return;
    setState(() {
      _panel = false;
      _sync = false;
      _episodes = !_episodes;
    });
  }

  /// Finds the next episode ahead of time; the card itself waits for the end of this one.
  void _scheduleUpNext() {
    _nextInfo = null;
    _upNextDismissed = false;
    final store = _store, ep = _ep;
    if (store == null || ep == null) return;
    store.after(ep).then((next) {
      if (mounted && _ep == ep && next != null && !next.upcoming) _nextInfo = next;
    }, onError: (Object _) {});
  }

  /// The card shows for the last stretch of the episode, where the credits usually roll:
  /// 4% of its length, kept between 30 and 90 seconds. Seeking back before that hides it.
  /// Which skippable part is playing. Show credits hand over to the up-next card instead.
  void _checkSegment(Duration p) {
    final d = _duration.value;
    if (d <= Duration.zero) return;
    Segment? now;
    for (final s in _segments) {
      if (_segDismissed.contains(s) || !s.covers(p, d)) continue;
      if (s.kind == SegmentKind.credits && widget.media.isTv && _nextInfo != null) continue;
      now = s;
      break;
    }
    if (now != _segNow && mounted) setState(() => _segNow = now);
  }

  void _skipSegment() {
    final s = _segNow;
    if (s == null) return;
    setState(() {
      _segDismissed.add(s);
      _segNow = null;
    });
    final end = s.end;
    if (end == null || end >= _duration.value - const Duration(seconds: 2)) {
      // credits that run to the very end: the film is done
      if (s.kind == SegmentKind.credits && !widget.media.isTv && !widget.embedded) _leave();
      return;
    }
    _seek(end);
  }

  void _checkUpNext(Duration p) {
    if (_follower) return; // the host moves everyone on
    final next = _nextInfo, d = _duration.value;
    if (next == null || d <= Duration.zero || _seekTarget != null) return;
    // TheIntroDB's credits start when it has one; otherwise the last 4% (30-90s)
    final credits = _segments.where((s) => s.kind == SegmentKind.credits && s.start > d * .5).lastOrNull;
    final lead = Duration(milliseconds: (d.inMilliseconds * .04).round().clamp(30000, 90000));
    final near = credits != null ? p >= credits.start : p >= d - lead;
    if (near) {
      if (_upNext == null && !_upNextDismissed) setState(() => _upNext = next);
    } else {
      _upNextDismissed = false;
      if (_upNext != null) setState(() => _upNext = null);
    }
  }

  /// Switches to episode [e]. [next]: it was asked for with the Next button or the Up next
  /// card, which is when "Autoplay the best source" chooses the source; an episode picked in
  /// the list stays with the source you have.
  void _goTo(EpisodeInfo e, {bool next = false}) {
    if (_follower) return _hostOnly();
    _saveProgress();
    _switch('Caricamento ${episodeLabel(e.season, e.number)}', () {
      _ep = e.toPlayer();
      _upNext = null;
      _episodes = false;
      _subOffset = 0;
    });
    _scheduleUpNext();
    _poke();
    _nextPressed = next;
    _loadAndPlay();
    _partyReport(position: Duration.zero);
  }

  Future<void> _playNext() async {
    if (_follower) return _hostOnly();
    if (widget.anime != null && _store == null) return _animeNext();
    final store = _store, ep = _ep;
    if (store == null || ep == null) return;
    final next = await store.after(ep).catchError((Object _) => null);
    if (!mounted) return;
    if (next == null || next.upcoming) {
      showToast(context, const Text("È l'ultimo episodio", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.check_rounded);
    } else {
      _goTo(next, next: true);
    }
  }

  void _back() {
    if (_sourcesOverlay) {
      setState(() => _sourcesOverlay = false); // back to the video, still playing
      return;
    }
    if (_locked) {
      _setLocked(false);
    } else if (_episodes) {
      setState(() => _episodes = false);
    } else if (_sync) {
      setState(() => _sync = false);
    } else if (_panel) {
      setState(() => _panel = false);
    } else if (_fullscreen) {
      _toggleFullscreen();
    } else if (widget.embedded) {
      if (widget.expanded) widget.onExpand?.call(); // back to the room
    } else {
      _leave();
    }
  }

  /// Closes the player: its page, or the small window when it's minimized.
  void _leave() {
    if (widget.mini) return widget.onClose?.call();
    Navigator.of(context).maybePop();
  }

  /// Shrinks the player to a small window over the app. It keeps playing there while you do
  /// something else; its page closes.
  void _minimize() {
    final go = widget.onMinimize;
    if (go == null || _locked || pz.Pip.active.value) return;
    if (_fullscreen) unawaited(_toggleFullscreen());
    setState(() => _panel = _sync = _episodes = _sourcesOverlay = false);
    _saveProgress();
    go();
  }

  /// Minimized: the picture in a small window, with play/pause, back to full size and close on
  /// it. Where the window sits, and dragging it, are the floating layer's.
  Widget _miniView() {
    final next = _follower ? null : _upNext;
    return Material(
      color: Colors.transparent,
      child: _MiniWindow(
        video: pz.VyseVideo(key: _videoKey, player: _player),
        cover: _veil ? const ColoredBox(color: Colors.black) : (_started ? null : RepaintBoundary(child: _Backdrop(media: widget.media))),
        busy: _loadingSources || _buffering,
        error: _error,
        playing: _playing,
        position: _position,
        duration: _duration,
        onTogglePause: _togglePause,
        onRestore: () => widget.onRestore?.call(),
        onClose: () => widget.onClose?.call(),
        next: next == null
            ? null
            : _MiniNext(
                key: ValueKey('${next.season}/${next.number}'),
                label: episodeLabel(next.season, next.number),
                auto: AppSettings.autoNext.value && _sleepMinutes != -1,
                onPlay: () => _goTo(next, next: true),
              ),
      ),
    );
  }

  void _setLocked(bool locked) {
    _lockTimer?.cancel();
    _hide?.cancel();
    setState(() {
      _locked = locked;
      _chrome = !locked;
      _panel = false;
    });
    if (locked) {
      _flashUnlock();
    } else {
      _lockHint = false;
      _poke();
    }
  }

  void _flashUnlock() {
    _lockTimer?.cancel();
    setState(() => _lockHint = true);
    _lockTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _lockHint = false);
    });
  }

  bool get _canSwipe => _touch && !_locked && !_panel && !_sync && !_episodes && (!widget.embedded || widget.expanded);

  void _swipeStart(DragStartDetails d, double width) {
    _dragBrightness = d.localPosition.dx < width / 2;
    _showHud();
  }

  /// A swipe across 70% of the screen's height covers the whole range.
  void _swipeUpdate(DragUpdateDetails d, double height) {
    final step = -d.delta.dy / (height * .7);
    if (_dragBrightness) {
      final b = ((_brightness ?? .5) + step).clamp(0.0, 1.0);
      _brightness = b;
      _brightnessChanged = true;
      ScreenBrightness.instance.setApplicationScreenBrightness(b).catchError((Object _) {});
    } else {
      _volume = (_volume + step * 100).clamp(0.0, 100.0);
      _player.setVolume(_volume);
    }
    _showHud();
  }

  void _swipeEnd() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _showHud() {
    _hudTimer?.cancel();
    setState(() {
      _hud = _dragBrightness ? 'brightness' : 'volume';
      _hudValue = _dragBrightness ? (_brightness ?? .5) : _volume / 100;
    });
  }

  void _onFocusChange() {
    final typing = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing != _typing && mounted) setState(() => _typing = typing);
  }

  // ── watch party ──

  void _hostOnly() => showToast(
    context,
    const Text('The host controls playback in a watch party', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    icon: Icons.groups_rounded,
  );

  void _say(String text) => showToast(context, Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.groups_rounded);

  /// A follower with control asks the host's player to play, pause or seek.
  void _sendCommand(String action, {double? position}) {
    WatchParty.command(action, position: position).catchError((Object e) {
      if (mounted) _say(Account.describe(e));
    });
  }

  /// The host's player carries out a member's play, pause or seek, and tells the room who did it.
  void _onCommand(WatchCommand c) {
    if (!_host || !mounted) return;
    switch (c.action) {
      case 'pause':
        _autoPaused = false;
        _player.pause();
        _say('${c.byName} paused');
      case 'play':
        if (_autoPaused) {
          _autoPaused = false;
          WatchParty.skipWaiting();
        }
        _player.play();
        _say('${c.byName} pressed play');
      case 'seek':
        final p = c.position;
        if (p == null) return;
        final to = Duration(milliseconds: (p * 1000).round());
        _seekTo(to);
        _partyReport(position: to);
        _say('${c.byName} skipped to ${_clockOf(to)}');
    }
  }

  static String _clockOf(Duration t) {
    final h = t.inHours, m = t.inMinutes % 60, s = t.inSeconds % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }

  /// The host's player tells the room what it's doing (followers never report).
  void _partyReport({Duration? position, bool? playing}) {
    if (!_host || !mounted) return;
    // the room is on a song, live TV or another title now: this player closing (or still
    // running a moment) mustn't put its title back over it
    final room = WatchParty.state.value;
    if (room != null && (room.isMusic || room.isLive || room.media.key != widget.media.key)) return;
    final ep = _ep, t = _activeSubTrack;
    WatchParty.report(WatchState(
      media: widget.media,
      season: ep?.season,
      episode: ep?.number,
      episodeName: ep?.name,
      position: (position ?? _position.value).inMilliseconds / 1000,
      playing: playing ?? (_playing && !_stalled),
      rate: _speed,
      subtitle: t == null
          ? null
          : {'id': t.id, 'provider': t.provider, 'lang': t.lang, 'language': t.language, 'release': t.release, 'url': t.url, 'format': t.format, 'translated': t.translated},
      subDelay: _subOffset,
      by: Account.user.value?.id ?? '',
      source: _pick == null ? null : WatchParty.sourceJson(_pick!),
      // guests look in these, in this order, starting with the one playing here
      sources: _films ? [for (final s in activeFilmSources()) s.id] : null,
      server: _films ? _playingLink?.partyKey : null,
      link: _shareLink,
    ));
  }

  void _partyTick() {
    _partyTicks++;
    final names = WatchParty.blocking();
    if (!listEquals(names, _waitingFor) && mounted) setState(() => _waitingFor = names);
    if (_host) {
      // pause while someone is loading, carry on once they're ready
      if (names.isNotEmpty && _playing && _started && !_autoPaused) {
        _autoPaused = true;
        _player.pause();
      } else if (names.isEmpty && _autoPaused) {
        _autoPaused = false;
        _player.play();
      }
      if (_started && _partyTicks % 4 == 0) _partyReport();
    } else {
      WatchParty.wait(_error == null && (!_started || _stalled));
      _partyFollow();
    }
  }

  /// Buffering for over a second (or back from it). The host's room pauses with it; a follower's
  /// waiting is sent on the next tick.
  void _setStalled(bool v) {
    if (_stalled == v) return;
    _stalled = v;
    if (_host && _started) _partyReport();
  }

  /// Something changed in the room's watch: a new title or episode, or the host's state.
  void _partyChanged() {
    if (!mounted || !widget.party) return;
    final s = WatchParty.state.value;
    if (s == null) {
      if (_follower) {
        _player.pause();
        showToast(context, const Text('The watch party ended', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.groups_rounded);
      }
      return;
    }
    if (s.isMusic || s.isLive) {
      // whatever plays next in the room ends this: the video stops, a full-screen one closes
      _player.pause();
      if (!widget.embedded) _leave();
      return;
    }
    if (!_follower || s.mine) return;
    if (s.media.key != widget.media.key) {
      if (widget.embedded) return; // the room swaps in a player for it
      if (widget.mini) return _leave(); // no page of its own to open the new one on
      // the host picked something else: open it in place of this one
      final ep = s.season != null && s.episode != null ? PlayerEpisode(season: s.season!, number: s.episode!, name: s.episodeName) : null;
      final nav = Navigator.of(context);
      partyPlayer(s.media, ep).then((page) {
        if (!mounted) return;
        nav.pushReplacement(PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 360),
          pageBuilder: (_, _, _) => page,
          transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        ));
      }, onError: (Object _) {});
      return;
    }
    if (widget.media.isTv && s.season != null && s.episode != null && (s.season != _ep?.season || s.episode != _ep?.number)) {
      _saveProgress();
      _switch('Caricamento ${episodeLabel(s.season, s.episode!)}', () {
        _ep = PlayerEpisode(season: s.season!, number: s.episode!, name: s.episodeName);
        _upNext = null;
        _episodes = false;
      });
      _pick = WatchParty.sourcePick(s);
      _scheduleUpNext();
      _loadAndPlay();
      return;
    }
    // the host is streaming a link everyone can play (or another one now): play that too
    final hostUrl = s.link?['url'];
    if (hostUrl is String && hostUrl != _sharedUrl && hostUrl != _sharedSkip) {
      if (s.source != null) _pick = WatchParty.sourcePick(s) ?? _pick;
      _resumeOverride = Duration(milliseconds: (s.now * 1000).round());
      _switch("Playing the host's stream", () {});
      _loadAndPlay();
      return;
    }
    // the host shared a source (or another one): play that exact one, from where they are
    if (s.source != null || _pick != null) {
      final shared = WatchParty.sourcePick(s);
      if (s.source != null && shared == null) return; // theirs for this episode isn't ready yet
      String? key(AddonPick? p) => p == null ? null : (p.stream.torrent ? '${p.stream.infoHash}:${p.stream.fileIdx}' : p.stream.url);
      if (key(shared) != key(_pick)) {
        _pick = shared;
        _resumeOverride = Duration(milliseconds: (s.now * 1000).round());
        _switch('Cambio sorgente', () {});
        _loadAndPlay();
        return;
      }
    }
    _partyFollow();
  }

  /// Followers match the host: speed, subtitle file and timing, play/pause, then position.
  /// Syncplay's thresholds: over 5 s behind or 4 s ahead jumps (the room waits while that
  /// loads), smaller gaps close by playing a touch faster or slower. Never while buffering or just
  /// after it.
  void _partyFollow() {
    final s = WatchParty.state.value;
    if (s == null || !_follower || s.mine || !mounted) return;

    final sub0 = s.subtitle;
    final want = sub0 == null ? null : '${sub0['provider']}:${sub0['id']}';
    final have = _activeSubTrack == null ? null : '${_activeSubTrack!.provider}:${_activeSubTrack!.id}';
    if (!_ownSubs && want != have && want != _partySubLoading && !_subsLoading) {
      _partySubLoading = want;
      final track = sub0 == null
          ? null
          : sub.SubtitleTrack(
              id: '${sub0['id']}',
              provider: '${sub0['provider']}',
              lang: '${sub0['lang'] ?? ''}',
              language: '${sub0['language'] ?? sub0['lang'] ?? ''}',
              release: '${sub0['release'] ?? ''}',
              url: '${sub0['url']}',
              format: '${sub0['format'] ?? 'srt'}',
              translated: sub0['translated'] == true,
            );
      _setSubtitleTrack(track).whenComplete(() => _partySubLoading = null);
    }
    if (!_ownSubs && (_subOffset - s.subDelay).abs() > .01) {
      setState(() => _subOffset = s.subDelay);
      _applySubDelay();
    }

    // just played, paused or seeked for the room: give the host a moment to catch up
    final at = _commandAt;
    if (at != null && DateTime.now().difference(at) < const Duration(seconds: 3)) return;

    if (s.playing != _playing && _started) s.playing ? _player.play() : _player.pause();

    var rate = s.rate;
    final now = DateTime.now(), jump = _partyJumpAt;
    if (jump != null && !_buffering && now.difference(jump) > const Duration(seconds: 4)) _partyJumpAt = null; // landed in what was already loaded
    final steady = !_buffering && _partyJumpAt == null && now.difference(_partySteadyAt) > const Duration(milliseconds: 1500);
    if (_started && !_reopening && _seekTarget == null && _sources.isNotEmpty && steady) {
      final want = s.now + (s.playing ? .1 : 0); // ~what the message took to arrive
      final diff = want - _position.value.inMilliseconds / 1000; // > 0: behind the host
      if (s.playing ? (diff > 5 || diff < -4) : diff.abs() > 1.5) {
        _partyJumpAt = DateTime.now();
        _seekTo(Duration(milliseconds: (want * 1000).round()));
      } else if (s.playing && diff.abs() > .3) {
        rate = s.rate * (1 + (diff > 0 ? 1 : -1) * (diff.abs() > 2 ? .1 : .05));
      }
    }
    if (_speed != s.rate && mounted) setState(() => _speed = s.rate);
    if ((_player.state.rate - rate).abs() > .001) _player.setRate(rate);
  }

  /// For the home page's Continue watching row.
  /// Simkl follows what's playing here: start, pause and stop, as they happen.
  void _track({bool? playing}) {
    if (widget.server != null) return; // your server keeps track itself
    final d = _duration.value;
    if (!_started || d <= Duration.zero) return;
    final ep = _ep;
    TrackerHub.playback(
      this,
      MediaRef.playing(widget.media, anime: widget.anime?.anime, season: ep?.season, episode: ep?.number),
      playing: playing ?? _playing,
      position: _position.value,
      duration: d,
    );
  }

  void _saveProgress() {
    if (!_started || _sources.isEmpty) return;
    final d = _duration.value;
    if (d <= Duration.zero) return;
    final server = widget.server;
    if (server != null) {
      server.progress(_position.value, d, paused: !_playing);
      _savedAt = DateTime.now();
      return;
    }
    final ep = _ep;
    final m = widget.media;
    WatchProgress.record(
      widget.media,
      position: _position.value,
      duration: d,
      season: ep?.season,
      episode: ep?.number,
      episodeName: ep?.name,
      subtitle: _subMemo,
      subDelay: _subMemo == null ? 0 : _subOffset,
    );
    _savedAt = DateTime.now();
    // an anime episode (or film) watched to Lorewatch's "finished" point: AniList
    // hear about it
    final anime = widget.anime;
    final n = ep?.number ?? (anime?.anime.isMovie == true ? 1 : null);
    if (anime != null && n != null && _position.value.inMilliseconds >= d.inMilliseconds * WatchProgress.finishedAt) {
      TrackerHub.animeEpisodeFinished(anime.anime, n);
    }
    _track();
    if (widget.anime != null) {
      // not a TMDB title: Party shows its name and episode, no TMDB poster
      PartyPresence.watching(title: m.title, tv: m.isTv, episode: ep?.number);
      return;
    }
    // "Watching …" in Party (only changes reach the server)
    PartyPresence.watching(title: m.title, tv: m.isTv, season: ep?.season, episode: ep?.number, poster: m.posterPath, tmdbId: m.id);
  }

  void _togglePause() {
    if (_follower) {
      if (!WatchParty.canCommand) return _hostOnly();
      final pause = WatchParty.state.value?.playing ?? _playing;
      _commandAt = DateTime.now();
      pause ? _player.pause() : _player.play(); // right away here; the host's player does it for everyone
      _sendCommand(pause ? 'pause' : 'play');
      return;
    }
    if (_autoPaused) {
      // the host plays anyway
      _autoPaused = false;
      WatchParty.skipWaiting();
    }
    if (!_playing) AudioFocus.claim(this, _player.pause);
    _player.playOrPause();
  }

  /// Double-click is worked out by hand: a GestureDetector onDoubleTap holds every click on the
  /// screen (buttons included) for ~300ms while it waits for a second one.
  DateTime? _lastTap;
  bool _isDoubleTap() {
    final now = DateTime.now();
    final hit = _lastTap != null && now.difference(_lastTap!) < const Duration(milliseconds: 300);
    _lastTap = hit ? null : now;
    return hit;
  }


  /// Shows the controls and restarts the idle timer. They stay while the panel is open.
  void _poke() {
    if (_locked) return;
    _hide?.cancel();
    if (!_chrome) setState(() => _chrome = true);
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && !_panel && !_sync && !_episodes) setState(() => _chrome = false);
    });
  }

  String _value(_Tab t) => switch (t) {
    _Tab.sources => _sources.isEmpty ? 'Caricamento…' : [_nowQuality, _sources[_source].server].where((x) => x.isNotEmpty).join(' · '),
    _Tab.quality => _variant != null ? _variants[_variant!].label : (_variants.length > 1 ? 'Auto' : _nowQuality),
    _Tab.audio => _audioNow == null ? '' : _audioName(_audioNow!),
    _Tab.subtitles => _subOffset == 0 ? (_subtitle == 'Off' ? 'Nessuno' : _subtitle) : '$_subtitle · ${_subOffset > 0 ? '+' : ''}${_subOffset}s',
    _Tab.speed => _speedLabel(_speed),
    _Tab.more => [
        if (AppSettings.upscaler.value != 'none') pz.Upscaler.byId(AppSettings.upscaler.value).label,
        if (_zoom != 100) '$_zoom%',
        if (_sleepMinutes != null) 'Timer',
      ].join(' · '),
  };

  @override
  Widget build(BuildContext context) {
    if (widget.mini) return _miniView();
    final size = MediaQuery.sizeOf(context);
    // a phone turned sideways is wider than the phone breakpoint, but it's still a phone
    final phone = Layout.isPhone(context) || (_touch && size.shortestSide < 600);
    // embedded in the room there's no window chrome over it (full screen on desktop when expanded)
    final top = _fullscreen || (widget.embedded && (!widget.expanded || isDesktopNative)) ? 0.0 : Layout.windowChrome(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final side = phone ? 16.0 : 32.0;
    // the rail and the dock; and with what's playing above them
    final showInfo = !widget.embedded || widget.expanded;
    final dockH = (phone ? 112.0 : 118.0) + bottomInset;
    final barH = dockH + (showInfo ? (phone ? 96.0 : 124.0) : 0);
    _panelOverDock = _panel && size.height < 520;
    if (_mpvSubtitles && size.height > 0) {
      final rest = SubtitleStyle.basePosition;
      // bottom subtitles clear the controls while they show; top ones stay put
      _syncSubPos(_chromeUp && !AppSettings.subtitleTop.value ? math.min(rest, 100 - (barH - 30) / size.height * 100) : rest);
    }
    // the whole width of a phone held upright; a phone on its side keeps the picture in view
    final syncW = size.width < 640 ? size.width : (phone ? math.min(500.0, size.width * .62) : math.min(540.0, size.width * .5));
    final episodesW = size.width < 640 ? size.width : (phone ? math.min(460.0, size.width * .6) : math.min(560.0, math.max(400.0, size.width * .5)));

    // picture-in-picture: the small window shows the video and nothing else
    if (pz.Pip.active.value) return _pipView();
    return CallbackShortcuts(
      // while typing (e.g. the sync panel's search), letters, space and arrows go to the text
      bindings: _typing
          ? {const SingleActivator(LogicalKeyboardKey.escape): _keys.requestFocus}
          : {
        const SingleActivator(LogicalKeyboardKey.escape): _back,
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
        const SingleActivator(LogicalKeyboardKey.keyS): () => _openPanel(),
        const SingleActivator(LogicalKeyboardKey.keyC): () => _openPanel(_Tab.subtitles),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyE): _toggleEpisodes,
        const SingleActivator(LogicalKeyboardKey.keyN): _playNext,
        const SingleActivator(LogicalKeyboardKey.keyM): _minimize,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seek(_position.value - Duration(seconds: AppSettings.seekSeconds.value)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seek(_position.value + Duration(seconds: AppSettings.seekSeconds.value)),
      },
      child: Focus(
        focusNode: _keys,
        autofocus: !widget.embedded, // in the room, the chat box keeps the keyboard until you click the video
        child: Material(
          // Transparent: the video is a native surface behind Flutter (see VyseVideo).
          color: Colors.transparent,
          child: MouseRegion(
            cursor: _chrome || _sync || _episodes ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: (_) => _poke(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: _canSwipe ? (d) => _swipeStart(d, size.width) : null,
              onVerticalDragUpdate: _canSwipe ? (d) => _swipeUpdate(d, size.height) : null,
              onVerticalDragEnd: _canSwipe ? (_) => _swipeEnd() : null,
              onTap: () {
                _keys.requestFocus(); // clicking the picture leaves any text field
                if (_locked) {
                  _flashUnlock();
                } else if (_sync || _episodes) {
                  setState(() => _sync = _episodes = false);
                } else if (_isDoubleTap()) {
                  _toggleFullscreen();
                } else if (_panel) {
                  setState(() => _panel = false);
                } else if (_chrome) {
                  setState(() => _chrome = false);
                } else {
                  _poke();
                }
              },
              child: Stack(children: [
                // Plezy's player: mpv renders into a native surface behind Flutter; VyseVideo
                // clears the pixels here so it shows through whatever the page paints below.
                Positioned.fill(child: pz.VyseVideo(key: _videoKey, player: _player)),
                if (_veil) const Positioned.fill(child: ColoredBox(color: Colors.black)),
                if (!_started)
                  Positioned.fill(child: RepaintBoundary(child: _Backdrop(media: widget.media))),
                // on a phone the middle button turns into the spinner while the controls are up
                if (_loadingSources || (_buffering && (!phone || !_chromeUp)))
                  Center(child: RepaintBoundary(child: _Spinner(note: _error ?? _note ?? _loadNote ?? (_torrent != null ? _torrentNote : _searchNote)))),
                // Shade behind the controls, so they read over any picture.
                _fade(
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      height: barH + 120,
                      width: double.infinity,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xE6000000), Color(0xA6000000), Color(0x00000000)],
                            stops: [0, .5, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _fade(
                  const Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      height: 130,
                      width: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x8C000000), Color(0x00000000)]),
                        ),
                      ),
                    ),
                  ),
                ),
                // Subtitles ride above the controls while they show. mpv draws them by default
                // (full ASS via libass, see _mpvSubtitles); this overlay is the plain-text fallback.
                if (!_mpvSubtitles) AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: side,
                  right: side,
                  bottom: _chromeUp ? barH + 14 : 44 + bottomInset,
                  child: IgnorePointer(child: _SubtitleOverlay(lines: _player.subText.map((t) => [t]), initial: [_player.currentSubText], phone: phone)),
                ),
                // Top: back, and the room's and the lock's buttons.
                _fade(
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(side - 10, top + (phone ? 10 : 18), side - 10, 0),
                      child: Row(children: [
                        if (!widget.embedded || widget.expanded) ...[
                          _IconBtn(icon: Icons.arrow_back_rounded, tooltip: widget.embedded ? 'Torna alla stanza (Esc)' : 'Indietro (Esc)', onTap: _back),
                          const SizedBox(width: 8),
                        ],
                        if (widget.onMinimize != null)
                          _IconBtn(icon: Icons.keyboard_arrow_down_rounded, tooltip: 'Riduci: continua a guardare in una finestrella (M)', size: 28, onTap: _minimize),
                        const Spacer(),
                        if (widget.party) const _VoiceButtons(),
                        if (_touch) _IconBtn(icon: Icons.lock_open_rounded, tooltip: 'Blocca', onTap: () => _setLocked(true)),
                      ]),
                    ),
                  ),
                ),
                if (phone && !_loadingSources)
                  _fade(
                    Center(
                      child: _PhoneTransport(
                        paused: !_playing,
                        buffering: _buffering,
                        note: _error ?? _note,
                        onPause: _togglePause,
                        onSeek: _seek,
                        position: _position,
                      ),
                    ),
                  ),
                // Bottom: what's playing, the rail, the dock.
                _fade(
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(side, 0, side, (phone ? 8 : 12) + bottomInset),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showInfo) ...[
                            ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: phone ? double.infinity : size.width * .55),
                              child: NowPlaying(
                                title: widget.media.title,
                                logo: _logo,
                                episode: _ep == null ? null : '${episodeLabel(_ep!.season, _ep!.number)}${_ep!.name == null ? '' : '  ·  ${_ep!.name}'}',
                                source: _value(_Tab.sources),
                                addon: _pick?.stream.addon,
                                badges: _nowBadges,
                                phone: phone,
                                onSource: () => _openPanel(_Tab.sources),
                              ),
                            ),
                            SizedBox(height: phone ? 10 : 16),
                          ],
                          RailCaption(position: _position, duration: _duration, chapters: _chapters, rate: _speed),
                          PlayerRail(
                            position: _position,
                            duration: _duration,
                            buffered: _buffered,
                            chapters: _chapters,
                            marks: _segments,
                            onSeek: _seek,
                          ),
                          if (phone)
                            PhoneTools(
                              subtitlesOn: _subtitle != 'Off',
                              onSubtitles: () => _openPanel(_Tab.subtitles),
                              onAudio: () => _openPanel(_Tab.audio),
                              onSettings: _openPanel,
                              onEpisodes: _store == null ? null : _toggleEpisodes,
                              onNext: _store == null && widget.anime == null ? null : _playNext,
                            )
                          else
                            PlayerDock(
                              paused: !_playing,
                              seekSeconds: AppSettings.seekSeconds.value,
                              volume: _volume,
                              subtitlesOn: _subtitle != 'Off',
                              fullscreen: _fullscreen,
                              onPause: _togglePause,
                              onBack: () => _seek(_position.value - Duration(seconds: AppSettings.seekSeconds.value)),
                              onForward: () => _seek(_position.value + Duration(seconds: AppSettings.seekSeconds.value)),
                              onVolume: (v) {
                                setState(() => _volume = v);
                                _player.setVolume(v);
                              },
                              onSubtitles: () => _openPanel(_Tab.subtitles),
                              onAudio: () => _openPanel(_Tab.audio),
                              onSpeed: () => _openPanel(_Tab.speed),
                              onSources: () => _openPanel(_Tab.sources),
                              onSettings: _openPanel,
                              onEpisodes: _store == null ? null : _toggleEpisodes,
                              onNext: _store == null && widget.anime == null ? null : _playNext,
                              onFullscreen: isDesktopNative ? _toggleFullscreen : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Settings panel.
                Positioned.fill(
                  child: PlayerPanel(
                    open: _panel,
                    tab: _tab,
                    side: side,
                    top: top,
                    dockH: dockH,
                    onTab: (t) => setState(() => _tab = t),
                    body: _body,
                  ),
                ),
                // Subtitle sync, from the right edge like the home rail.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 340),
                  curve: Curves.easeOutCubic,
                  top: 0,
                  bottom: 0,
                  width: syncW,
                  right: _sync ? 0 : -syncW,
                  child: IgnorePointer(
                    ignoring: !_sync,
                    child: AnimatedOpacity(
                      opacity: _sync ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: SubtitleSyncPanel(
                        cues: _cues,
                        position: _position,
                        duration: _duration,
                        playing: _playing,
                        onPlayPause: _togglePause,
                        onSeekBy: (s) => _seek(_position.value + Duration(milliseconds: (s * 1000).round())),
                        offset: _subOffset,
                        onOffset: (v) {
                          if (_follower) _ownSubs = true; // their own timing from now on
                          setState(() => _subOffset = v);
                          _applySubDelay();
                          // the sync panel nudges in small steps: send where it settles
                          _partyDebounce?.cancel();
                          _partyDebounce = Timer(const Duration(milliseconds: 400), _partyReport);
                        },
                        onClose: () => setState(() => _sync = false),
                      ),
                    ),
                  ),
                ),
                if (_store != null && _ep != null)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 340),
                    curve: Curves.easeOutCubic,
                    top: 0,
                    bottom: 0,
                    width: episodesW,
                    right: _episodes ? 0 : -episodesW,
                    child: IgnorePointer(
                      ignoring: !_episodes,
                      child: AnimatedOpacity(
                        opacity: _episodes ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: TickerMode(
                          enabled: _episodes,
                          child: EpisodesPanel(
                            store: _store,
                            current: _ep!,
                            onPick: _goTo,
                            onClose: () => setState(() => _episodes = false),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.party)
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + (phone ? 64 : 84),
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: (_chrome && !_locked) || _waitingFor.isNotEmpty ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Center(child: _PartyPill(host: _host, control: WatchParty.canCommand, waitingFor: _waitingFor)),
                      ),
                    ),
                  ),
                // The room: who's in the call, its chat, and a talk button on phones.
                if (widget.party && (!widget.embedded || widget.expanded))
                  Positioned(
                    left: side + MediaQuery.paddingOf(context).left,
                    top: top + (phone ? 104 : 124),
                    child: Offstage(
                      offstage: size.width < 640 && (_sync || _episodes || _panel), // they fill a narrow screen
                      child: PartyStrip(controlsUp: _chromeUp && !_locked, touch: _touch, compact: phone, onDone: _keys.requestFocus),
                    ),
                  ),
                // Skip intro / recap / preview / credits.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  right: side,
                  bottom: _chrome && !_locked ? dockH + 10 : 24 + bottomInset,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(position: Tween(begin: const Offset(.15, 0), end: Offset.zero).animate(a), child: child),
                    ),
                    child: _segNow == null || _upNext != null || _sync || _episodes || _locked || _panel
                        ? const SizedBox.shrink()
                        : _SkipButton(
                            key: ValueKey(_segNow),
                            segment: _segNow!,
                            position: _position,
                            duration: _duration,
                            compact: phone,
                            onTap: _skipSegment,
                          ),
                  ),
                ),
                // Up next: rides above the controls, drops lower when they hide.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  right: side,
                  left: phone ? side : null,
                  width: phone ? null : 440,
                  bottom: _chrome ? dockH + 10 : 24 + bottomInset,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(position: Tween(begin: const Offset(.12, 0), end: Offset.zero).animate(a), child: child),
                    ),
                    child: _upNext == null || _sync || _episodes || _locked
                        ? const SizedBox.shrink()
                        : UpNextCard(
                            key: ValueKey('${_upNext!.season}/${_upNext!.number}'),
                            episode: _upNext!,
                            auto: AppSettings.autoNext.value && _sleepMinutes != -1,
                            compact: phone,
                            onPlay: () {
                              final next = _upNext;
                              if (next != null) _goTo(next, next: true);
                            },
                            onDismiss: () => setState(() {
                              _upNext = null;
                              _upNextDismissed = true;
                            }),
                          ),
                  ),
                ),
                if (_locked)
                  Positioned(
                    left: side,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IgnorePointer(
                        ignoring: !_lockHint,
                        child: AnimatedOpacity(
                          opacity: _lockHint ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: _UnlockButton(onTap: () => _setLocked(false)),
                        ),
                      ),
                    ),
                  ),
                if (_hud != null)
                  Align(
                    alignment: const Alignment(0, -.55),
                    child: IgnorePointer(child: _SwipeHud(brightness: _hud == 'brightness', value: _hudValue)),
                  ),
                // "Choose another source": the same sources list, over the video that keeps playing
                if (_sourcesOverlay)
                  Positioned.fill(
                    child: SourcesPage(
                      media: widget.media,
                      episode: _ep,
                      runtime: widget.runtime,
                      anime: widget.anime,
                      overlay: true,
                      playing: _pick?.stream,
                      onClose: () => setState(() => _sourcesOverlay = false),
                      onPick: _usePick,
                    ),
                  ),
                if (isDesktopNative && !_fullscreen && !widget.embedded) const Positioned(top: 0, left: 0, right: 0, child: WindowBar()),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  bool get _chromeUp => _chrome && !_sync && !_episodes && !_panelOverDock;

  Widget _fade(Widget child) => IgnorePointer(
    ignoring: !_chromeUp,
    // quick to appear, slower to fade away
    child: AnimatedOpacity(
      opacity: _chromeUp ? 1 : 0,
      duration: Duration(milliseconds: _chromeUp ? 110 : 280),
      child: RepaintBoundary(child: child),
    ),
  );

  /// Films and shows: each source in the order it's asked, opening to its links.
  Widget _filmSourcesPane(FilmSession session) {
    SourceState? shown(FilmState s) => switch (s) {
      FilmState.untried => null,
      FilmState.trying => SourceState.loading,
      FilmState.ready => SourceState.ready,
      FilmState.dead => SourceState.dead,
    };
    return FilmSourcesPane(
      hostOrder: _hostOrder,
      sources: [
        for (final s in session.sources)
          MenuFilmSource(
            id: s.source.id,
            name: s.source.name,
            note: s.source.note,
            servers: s.isMovy,
            state: s.isMovy ? SourceState.ready : shown(s.state),
            links: [
              for (final l in s.links)
                MenuLink(
                  name: l.name,
                  quality: switch (l == _playingLink ? _nowQuality : l.quality) {
                    '' => null,
                    final q => q,
                  },
                  format: l.format,
                  audio: l.audio,
                  state: shown(l.state),
                  current: l == _playingLink,
                  onTap: () => _tapLink(l),
                ),
            ],
            onOpen: s.isMovy ? null : () => session.scrape(s),
          ),
      ],
    );
  }

  Widget _body(PanelFit fit) => switch (_tab) {
    _Tab.sources when _films && _session != null => _filmSourcesPane(_session!),
    _Tab.sources => SourcesPane(
      now: _pick == null
          ? null
          : MenuNow(
              title: _value(_Tab.sources),
              leading: AddonLogo(addon: _pick!.stream.addon, size: 30),
              badges: _nowBadges.isEmpty ? null : BadgeRow(badges: _nowBadges, height: 14),
            ),
      onMore: _pick == null || widget.embedded
          ? null
          : () => setState(() {
              _panel = false;
              _sourcesOverlay = true;
            }),
      sources: [
        for (final s in _servers)
          () {
            final i = _sources.indexWhere((x) => x.server == s.name);
            final current = i >= 0 && i == _source && !_loadingSources;
            return MenuSource(
              name: s.name,
              note: s.note,
              quality: i < 0 ? null : switch (current ? _nowQuality : _sources[i].quality) { '' => null, final q => q },
              state: _serverState[s.name] ?? _Srv.ready,
              current: current,
              onTap: () => current ? null : _pickNamed(s.name),
            );
          }(),
      ],
    ),
    _Tab.quality => QualityPane(
      auto: _variants.length > 1 && _hasAuto
          ? MenuQuality(
              label: 'Auto',
              detail: 'La massima di questo server (${_variants.first.label})',
              selected: _variant == null,
              onTap: () => _pickQuality(null),
            )
          : null,
      only: _variants.length > 1
          ? null
          : MenuQuality(
              label: _nowQuality.isEmpty ? 'Caricamento…' : _nowQuality,
              detail: [
                if (_videoW > 0) '$_videoW×$_videoH',
                if (_sources.isNotEmpty) 'l\'unica qualità su ${_sources[_source].server}',
              ].join(' · '),
            ),
      items: [
        if (_variants.length > 1)
          for (var i = 0; i < _variants.length; i++)
            MenuQuality(
              label: _variants[i].label,
              detail: [
                if (_variants[i].width > 0) '${_variants[i].width}×${_variants[i].height}',
                if (_variants[i].bandwidth > 0) '${(_variants[i].bandwidth / 1e6).toStringAsFixed(1)} Mbps',
              ].join(' · '),
              selected: _variant == i,
              onTap: () => _pickQuality(i),
            ),
      ],
    ),
    _Tab.audio => AudioPane(
      tracks: [
        for (final t in _audioTracks)
          MenuAudio(
            title: _audioName(t),
            detail: _audioInfo(t, single: _audioTracks.length == 1),
            current: t.id == _audioNow?.id,
            onTap: () {
              if (t.id == _audioNow?.id) return;
              _switch('Passo a ${_audioName(t)}', () {});
              _audioByHand = true;
              _player.selectAudioTrack(t);
            },
          ),
      ],
      // the source that's playing, when its languages are links of their own
      links: _linkLanguages,
      linksCaption: 'ALSO ON ${(_playingLink?.source.name ?? '').toUpperCase()}',
      elsewhere: [
        // other languages live on their own servers
        for (final s in _servers)
          if (s.audio != null &&
              (_sources.isEmpty || _sources[_source].server != s.name) &&
              s.audio!.toLowerCase() != _playingLink?.audio?.toLowerCase() &&
              _servers.where((x) => x.audio == s.audio && _serverState[x.name] != _Srv.dead).firstOrNull == s)
            MenuAudio(title: s.audio!, detail: 'Doppiato · passa a ${s.name}', onTap: () => _pickNamed(s.name)),
        // on an anime dub: back to the original
        if (widget.anime != null && _sources.isNotEmpty && _sources[_source].audio != null)
          for (final s in _servers.where((s) => s.audio == null && _serverState[s.name] != _Srv.dead).take(1))
            MenuAudio(title: 'Japanese', detail: 'Audio originale · passa a ${s.name}', onTap: () => _pickNamed(s.name)),
      ],
      sound: [
        MenuStepper(
          title: 'Sincronizzazione audio',
          detail: 'Corregge il labiale · + fa partire l\'audio più tardi',
          label: _delayLabel,
          changed: AppSettings.audioDelayMs.value != 0,
          onMinus: () => _nudgeDelay(-50),
          onPlus: () => _nudgeDelay(50),
          onReset: () => AppSettings.audioDelayMs.set(0),
        ),
        MenuChoice<String>(
          title: 'Canali',
          detail: 'Lo stereo riduce il surround per cuffie e altoparlanti della TV',
          value: AppSettings.audioChannels.value,
          options: const [('original', 'Originale'), ('surround51', '5.1'), ('stereo', 'Stereo')],
          onChanged: AppSettings.audioChannels.set,
        ),
        MenuToggle(
          title: 'Livellamento del volume',
          detail: 'Uniforma dialoghi bassi e azione rumorosa',
          value: AppSettings.volumeLevelling.value,
          onChanged: AppSettings.volumeLevelling.set,
        ),
        if (!Platform.isIOS)
          MenuToggle(
            title: 'Passthrough',
            detail: 'Invia Dolby e DTS intatti al ricevitore · non con livellamento, stereo o altre velocità',
            value: AppSettings.audioPassthrough.value,
            onChanged: AppSettings.audioPassthrough.set,
          ),
      ],
    ),
    _Tab.subtitles => SubtitlesPane(
      fit: fit,
      offset: _subOffset,
      tracks: [..._builtIn, ..._subtitleTracks],
      loading: _subsLoading,
      active: _activeSubTrack,
      art: widget.media.backdrop('w780'),
      onTrack: (t) {
        if (_follower) _ownSubs = true; // anyone can pick their own; the host's stop applying
        _subsChosen = true;
        _setSubtitleTrack(t);
      },
      onSync: _openSync,
    ),
    _Tab.speed => SpeedPane(
      speeds: [for (final s in _speeds) (s, _speedLabel(s))],
      more: [for (final s in _moreSpeeds) (s, _speedLabel(s))],
      value: _speed,
      position: _position,
      duration: _duration,
      onChanged: (s) {
        if (_follower) return _hostOnly();
        setState(() => _speed = s);
        _player.setRate(s);
        _partyReport();
      },
    ),
    _Tab.more => MorePane(
      sections: [
        ('PICTURE', [
          MenuStepper(
            title: 'Zoom',
            detail: 'Taglia le bande nere, o rimpicciolisci l\'immagine',
            label: '$_zoom%',
            changed: _zoom != 100,
            onMinus: () => _setZoom(_zoom - 5),
            onPlus: () => _setZoom(_zoom + 5),
            onReset: () => _setZoom(100),
          ),
          MenuToggle(
            title: 'Illuminazione ambientale',
            detail: 'Riempie le bande nere con un bagliore morbido dell\'immagine',
            value: AppSettings.ambientLight.value,
            onChanged: AppSettings.ambientLight.set,
          ),
        ]),
        ('UPSCALING', [
          for (final u in pz.Upscaler.all)
            MenuRow(title: u.label, detail: u.detail, selected: AppSettings.upscaler.value == u.id, onTap: () => AppSettings.upscaler.set(u.id)),
        ]),
        if (!widget.party)
          ('TIMER DI SPEGNIMENTO', [
            MenuChoice<int>(
              title: _sleepTitle,
              value: _sleepMinutes ?? 0,
              options: const [(0, 'Spento'), (15, '15m'), (30, '30m'), (60, '1h'), (90, '1½h'), (-1, 'Episodio')],
              onChanged: _setSleep,
            ),
          ]),
        ('DISPLAY', [
          if (Platform.isWindows)
            MenuToggle(
              title: 'HDR',
              detail: 'HDR vero su schermo HDR · se spento lo converte in SDR',
              value: AppSettings.hdrOutput.value,
              onChanged: AppSettings.hdrOutput.set,
            ),
          if (Platform.isWindows || Platform.isAndroid)
            MenuToggle(
              title: 'Adatta la frequenza di aggiornamento',
              detail: Platform.isWindows ? "Porta lo schermo al frame rate del video a schermo intero" : "Porta lo schermo al frame rate del video",
              value: AppSettings.matchRefreshRate.value,
              onChanged: (on) {
                AppSettings.matchRefreshRate.set(on);
                setState(() {});
                if (on) {
                  _displayTried = false;
                  unawaited(_maybeMatchDisplay());
                } else {
                  unawaited(_display.restore());
                }
              },
            ),
        ]),
        ('OPEN', [
          if (_pipOk) MenuRow(title: 'Picture-in-picture', detail: 'Continua a guardare in una finestrella', chevron: true, onTap: _enterPip),
          if (_canDownload)
            MenuRow(
              title: 'Scarica',
              detail: 'Lo salva su questo dispositivo · vedi Download',
              onTap: _download,
            ),
          if (_canCopyLink)
            MenuRow(
              title: 'Copia link',
              detail: _linkIsLocal ? 'Si riproduce solo su questo dispositivo, finché Lorewatch resta aperto' : 'L\'indirizzo dello stream, da incollare in un\'altra app',
              onTap: _copyLink,
            ),
          // not in a watch party: another app would be handed the room's link
          if (!widget.party)
            for (final p in _externals)
              MenuRow(title: 'Apri in ${p.name}', detail: 'Da dove sei arrivato · Lorewatch va in pausa', chevron: true, onTap: () => _openExternal(p)),
        ]),
      ],
    ),
  };
}

// ───────────────────────── Backdrop & loading ─────────────────────────

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.media});
  final Media media;

  @override
  Widget build(BuildContext context) {
    final url = media.backdrop(Layout.isPhone(context) ? 'w1280' : 'original');
    return Stack(fit: StackFit.expand, children: [
      if (url != null)
        CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          memCacheWidth: screenDecodeWidth(context),
          fadeInDuration: const Duration(milliseconds: 500),
          placeholder: (_, _) => media.backdrop() == null
              ? const ColoredBox(color: Colors.black)
              : Image(image: CachedNetworkImageProvider(media.backdrop()!), fit: BoxFit.cover),
          errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
        ),
      ColoredBox(color: Colors.black.withValues(alpha: .55)),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
            stops: [0, .2, .65, 1],
          ),
        ),
      ),
    ]);
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({this.note});
  final String? note;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(
        dimension: 46,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white, strokeCap: StrokeCap.round),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: note == null
            ? const SizedBox(width: 0)
            : Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(note!, style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
              ),
      ),
    ]),
  );
}

class _PhoneTransport extends StatelessWidget {
  const _PhoneTransport({required this.paused, required this.buffering, required this.note, required this.onPause, required this.onSeek, required this.position});
  final bool paused;
  final bool buffering;
  final String? note;
  final VoidCallback onPause;
  final ValueChanged<Duration> onSeek;
  final ValueListenable<Duration> position;

  @override
  Widget build(BuildContext context) {
    final seek = AppSettings.seekSeconds.value;
    final (back, fwd) = switch (seek) {
      5 => (Icons.replay_5_rounded, Icons.forward_5_rounded),
      10 => (Icons.replay_10_rounded, Icons.forward_10_rounded),
      30 => (Icons.replay_30_rounded, Icons.forward_30_rounded),
      _ => (Icons.fast_rewind_rounded, Icons.fast_forward_rounded), // no numbered icon for 15
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        _IconBtn(icon: back, tooltip: 'Indietro ${seek}s', size: 30, onTap: () => onSeek(position.value - Duration(seconds: seek))),
        const SizedBox(width: 36),
        Pressable(
          onTap: onPause,
          builder: (context, _, pressed) => AnimatedScale(
            scale: pressed ? .92 : 1,
            duration: const Duration(milliseconds: 120),
            // buffering: the spinner takes the button's place (it still pauses), not a ring
            // squeezed round its corners
            child: SizedBox.square(
              dimension: 72,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: buffering && !paused
                      ? const SizedBox.square(
                          key: ValueKey('wait'),
                          dimension: 46,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white, strokeCap: StrokeCap.round),
                        )
                      : Container(
                          key: const ValueKey('button'),
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                          child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 36, color: Colors.black),
                        ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 36),
        _IconBtn(icon: fwd, tooltip: 'Avanti ${seek}s', size: 30, onTap: () => onSeek(position.value + Duration(seconds: seek))),
      ]),
      if (note != null) ...[
        const SizedBox(height: 14),
        Text(note!, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
      ],
    ]);
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap, this.size = 24});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .88 : (hovered ? 1.12 : 1),
      duration: const Duration(milliseconds: 130),
      child: SizedBox.square(
        dimension: size + 20,
        child: Icon(icon, size: size, color: hovered ? Colors.white : const Color(0xFFE8E9F0)),
      ),
    ),
  );
}

/// "Skip intro" and friends: a glass pill with a thin line showing how far through the part
/// playback is.
class _SkipButton extends StatelessWidget {
  const _SkipButton({super.key, required this.segment, required this.position, required this.duration, required this.compact, required this.onTap});
  final Segment segment;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : (hovered ? 1.03 : 1),
      duration: const Duration(milliseconds: 140),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 22 : 26),
        child: Container(
          decoration: BoxDecoration(
            color: hovered ? const Color(0xF51A1C26) : const Color(0xE6101118),
            border: Border.all(color: Colors.white.withValues(alpha: hovered ? .28 : .14)),
            borderRadius: BorderRadius.circular(compact ? 22 : 26),
          ),
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 16 : 20, compact ? 10 : 13, compact ? 14 : 18, compact ? 10 : 13),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  segment.kind.action,
                  style: TextStyle(fontSize: compact ? 13.5 : 15, fontWeight: FontWeight.w800, letterSpacing: -.1),
                ),
                const SizedBox(width: 8),
                Icon(Icons.fast_forward_rounded, size: compact ? 18 : 20, color: VyseColors.accent),
              ]),
            ),
            // progress through the part
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ValueListenableBuilder<Duration>(
                valueListenable: position,
                builder: (context, p, _) {
                  final end = segment.end ?? duration.value;
                  final span = (end - segment.start).inMilliseconds;
                  final f = span <= 0 ? 0.0 : ((p - segment.start).inMilliseconds / span).clamp(0.0, 1.0);
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: f,
                      child: Container(height: 2.5, color: VyseColors.accent.withValues(alpha: .85)),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

class _UnlockButton extends StatelessWidget {
  const _UnlockButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: 'Sblocca',
    onTap: onTap,
    builder: (context, _, pressed) => AnimatedScale(
      scale: pressed ? .92 : 1,
      duration: const Duration(milliseconds: 120),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(28)),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_rounded, size: 22),
          SizedBox(width: 8),
          Text('Tocca per sbloccare', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ]),
      ),
    ),
  );
}

/// The level while a swipe changes volume or brightness.
class _SwipeHud extends StatelessWidget {
  const _SwipeHud({required this.brightness, required this.value});
  final bool brightness;
  final double value;

  @override
  Widget build(BuildContext context) {
    final icon = brightness
        ? (value < .35 ? Icons.brightness_low_rounded : (value < .7 ? Icons.brightness_medium_rounded : Icons.brightness_high_rounded))
        : (value == 0 ? Icons.volume_off_rounded : (value < .5 ? Icons.volume_down_rounded : Icons.volume_up_rounded));
    return Container(
      width: 200,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .62), borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 4,
              color: Colors.white,
              backgroundColor: Colors.white.withValues(alpha: .22),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // as wide as "100%" at any text size, so the number never drops to a second line
        Stack(alignment: Alignment.centerRight, children: [
          const Opacity(opacity: 0, child: Text('100%', softWrap: false, style: _number)),
          Text('${(value * 100).round()}%', softWrap: false, style: _number),
        ]),
      ]),
    );
  }

  static const _number = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
}

/// The subtitle line on screen, in the size, colour and backing from the Subtitles tab.
class _SubtitleOverlay extends StatelessWidget {
  const _SubtitleOverlay({required this.lines, required this.initial, required this.phone});
  final Stream<List<String>> lines;
  final List<String> initial;
  final bool phone;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.subtitleSize, AppSettings.subtitleColor, AppSettings.subtitleBackground]),
    builder: (context, _) => StreamBuilder<List<String>>(
      stream: lines,
      initialData: initial,
      builder: (context, snap) {
        final text = [
          for (final l in snap.data ?? const <String>[])
            for (final part in l.split('\n'))
              if (part.trim().isNotEmpty) part.trim(),
        ];
        if (text.isEmpty) return const SizedBox.shrink();
        // sized for a 1080p-tall window, scaled to this one
        final scale = (MediaQuery.sizeOf(context).height / 1080).clamp(.6, 1.6) * (phone ? .85 : 1);
        final size = AppSettings.subtitleSize.value * 1.3 * scale;
        final backing = AppSettings.subtitleBackground.value / 100;
        final style = TextStyle(
          fontSize: size,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: Color(AppSettings.subtitleColor.value),
          shadows: backing == 0
              ? const [
                  Shadow(blurRadius: 3, color: Colors.black),
                  Shadow(offset: Offset(1.5, 1.5), blurRadius: 2, color: Colors.black),
                  Shadow(offset: Offset(-1, -1), blurRadius: 2, color: Colors.black),
                ]
              : const [Shadow(blurRadius: 2, color: Color(0x99000000))],
        );
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (final line in text)
            Container(
              margin: const EdgeInsets.only(top: 3),
              padding: EdgeInsets.symmetric(horizontal: size * .4, vertical: size * .08),
              decoration: backing == 0
                  ? null
                  : BoxDecoration(color: Colors.black.withValues(alpha: backing), borderRadius: BorderRadius.circular(size * .22)),
              child: Text(line, textAlign: TextAlign.center, style: style),
            ),
        ]);
      },
    ),
  );
}

/// "Watch party" over the video: who's in charge.
class _PartyPill extends StatelessWidget {
  const _PartyPill({required this.host, this.control = false, this.waitingFor = const []});
  final bool host;
  final bool control; // may play and pause for everyone
  final List<String> waitingFor; // people still loading

  @override
  Widget build(BuildContext context) {
    final n = waitingFor.length;
    return Glass(
      solid: true, // over the video: a blur can't see Plezy's native video surface
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(n > 0 ? Icons.hourglass_top_rounded : Icons.groups_rounded, size: 16, color: VyseColors.accent),
          const SizedBox(width: 8),
          Text(
            n > 0
                ? 'Waiting for ${n == 1 ? waitingFor.first : '${waitingFor.first} and ${n - 1} more'} to load…'
                : host
                ? "Watch party · you're the host"
                : control
                ? 'Watch party · you can play and pause for everyone'
                : 'Watch party · the host controls playback',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Mute and deafen for the room's voice call, without leaving the video.
class _VoiceButtons extends StatelessWidget {
  const _VoiceButtons();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Voice.state, Voice.micOn, Voice.deafened, Voice.pushToTalk, Voice.talking]),
    builder: (context, _) {
      if (Voice.state.value != VoiceState.on) return const SizedBox.shrink();
      final deaf = Voice.deafened.value;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (Voice.pushToTalk.value)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Voice.talking.value ? Icons.mic_rounded : Icons.mic_none_rounded,
                size: 22,
                color: Voice.talking.value ? const Color(0xFF3DDC97) : VyseColors.textDim,
              ),
            )
          else
            _IconBtn(
              icon: Voice.micOn.value && !deaf ? Icons.mic_rounded : Icons.mic_off_rounded,
              tooltip: Voice.micOn.value && !deaf ? 'Muto' : 'Riattiva audio',
              onTap: Voice.toggleMic,
            ),
          _IconBtn(icon: deaf ? Icons.headset_off_rounded : Icons.headset_rounded, tooltip: deaf ? 'Undeafen' : 'Deafen', onTap: Voice.toggleDeafen),
          const SizedBox(width: 6),
        ],
      );
    },
  );
}

/// The desktop mini player: drag it anywhere, hover for play/pause and "back to the full window".
class _MiniPlayer extends StatefulWidget {
  const _MiniPlayer({required this.video, required this.playing, required this.onTogglePause, required this.onExpand});
  final Widget video;
  final bool playing;
  final VoidCallback onTogglePause;
  final Future<void> Function() onExpand;

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.video,
        DragToMoveArea(
          child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: widget.onExpand, child: const SizedBox.expand()),
        ),
        IgnorePointer(
          ignoring: !_hover,
          child: AnimatedOpacity(
            opacity: _hover ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Stack(
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.center, colors: [Color(0x99000000), Color(0x00000000)]),
                    ),
                  ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: Row(
                    children: [
                      _MiniButton(icon: widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, tip: widget.playing ? 'Pausa' : 'Riproduci', onTap: widget.onTogglePause),
                      const SizedBox(width: 4),
                      _MiniButton(icon: Icons.open_in_full_rounded, tip: 'Torna alla finestra intera', onTap: () => widget.onExpand()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.tip, required this.onTap, this.size = 34});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: hovered ? .7 : .5)),
        child: Icon(icon, size: size * .56, color: Colors.white),
      ),
    ),
  );
}

/// The minimized player's face: the picture, and on hover or a tap its buttons.
class _MiniWindow extends StatefulWidget {
  const _MiniWindow({
    required this.video,
    required this.busy,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onTogglePause,
    required this.onRestore,
    required this.onClose,
    this.cover,
    this.error,
    this.next,
  });
  final Widget video;
  final Widget? cover; // over the picture until there is one
  final bool busy;
  final String? error;
  final bool playing;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final VoidCallback onTogglePause;
  final VoidCallback onRestore;
  final VoidCallback onClose;
  final Widget? next;

  @override
  State<_MiniWindow> createState() => _MiniWindowState();
}

class _MiniWindowState extends State<_MiniWindow> {
  bool _show = false;
  Timer? _hide;

  void _reveal() {
    _hide?.cancel();
    if (!_show) setState(() => _show = true);
    _hide = Timer(const Duration(seconds: 3), _conceal);
  }

  void _conceal() {
    _hide?.cancel();
    if (mounted && _show) setState(() => _show = false);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => _reveal(),
    onHover: (_) => _reveal(),
    onExit: (_) => _conceal(),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _show ? _conceal() : _reveal(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.video,
          ?widget.cover,
          if (widget.busy)
            const Center(
              child: SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white, strokeCap: StrokeCap.round)),
            )
          else if (widget.error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  widget.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: VyseColors.textDim),
                ),
              ),
            ),
          // only the buttons fade: a fade over the picture itself would hide it (see VyseVideo)
          IgnorePointer(
            ignoring: !_show,
            child: AnimatedOpacity(
              opacity: _show ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0x73000000)),
                  Positioned(top: 6, left: 6, child: _MiniButton(icon: Icons.open_in_full_rounded, tip: 'Torna a dimensione piena', onTap: widget.onRestore)),
                  Positioned(top: 6, right: 6, child: _MiniButton(icon: Icons.close_rounded, tip: 'Chiudi', onTap: widget.onClose)),
                  Center(
                    child: _MiniButton(
                      icon: widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      tip: widget.playing ? 'Pausa' : 'Riproduci',
                      size: 44,
                      onTap: () {
                        widget.onTogglePause();
                        _reveal();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.next != null) Positioned(right: 6, bottom: 8, child: widget.next!),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: ValueListenableBuilder<Duration>(
                valueListenable: widget.position,
                builder: (context, p, _) {
                  final d = widget.duration.value.inMilliseconds;
                  return LinearProgressIndicator(
                    value: d <= 0 ? 0 : (p.inMilliseconds / d).clamp(0.0, 1.0),
                    minHeight: 2.5,
                    color: VyseColors.accent,
                    backgroundColor: const Color(0x33FFFFFF),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// "Up next" in the small window: a pill that plays the next episode when pressed, and by
/// itself after three seconds with autoplay on, like the full-size card (the ring round its
/// icon is the wait).
class _MiniNext extends StatefulWidget {
  const _MiniNext({super.key, required this.label, required this.auto, required this.onPlay});
  final String label;
  final bool auto;
  final VoidCallback onPlay;

  @override
  State<_MiniNext> createState() => _MiniNextState();
}

class _MiniNextState extends State<_MiniNext> with SingleTickerProviderStateMixin {
  late final _timer = AnimationController(vsync: this, duration: const Duration(seconds: 3));

  @override
  void initState() {
    super.initState();
    _timer.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onPlay();
    });
    if (widget.auto) _timer.forward();
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: 'Riproduci il prossimo episodio',
    onTap: widget.onPlay,
    builder: (context, hovered, _) => Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: hovered ? .88 : .72), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 20,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.auto)
                  AnimatedBuilder(
                    animation: _timer,
                    builder: (context, _) => CircularProgressIndicator(value: _timer.value, strokeWidth: 2, color: VyseColors.accent, backgroundColor: const Color(0x33FFFFFF)),
                  ),
                const Icon(Icons.skip_next_rounded, size: 14, color: Colors.white),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(widget.label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
        ],
      ),
    ),
  );
}
