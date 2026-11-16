import 'dart:async';

import 'core/accent.dart';
import 'data/account.dart';
import 'data/account_sync.dart';
import 'data/addons.dart' show Addons;
import 'data/badges.dart' show Badges;
import 'data/audiobook_player.dart' show AudiobookPlayer;
import 'data/manga_library.dart' show MangaFavorites, MangaHistory;
import 'data/party/alerts.dart' show PartyAlerts;
import 'data/party/dms.dart' show Dms;
import 'data/party/friends.dart' show Friends;
import 'data/party/party.dart' show PartyPresence;
import 'data/party/party_live.dart' show PartyLive;
import 'data/party/party_music.dart' show PartyMusic;
import 'data/party/rooms.dart' show Rooms;
import 'data/party/voice.dart' show Voice;
import 'data/party/watch_party.dart' show WatchParty;
import 'data/app_settings.dart';
import 'data/tmdb.dart' show MyList;
import 'data/downloads.dart';
import 'data/torrents.dart' show Torrents;
import 'data/music/music_library.dart' show MusicLibrary;
import 'data/debrid/debrid.dart' show Debrid;
import 'data/watch_progress.dart';
import 'data/trackers/tracker_hub.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:window_manager/window_manager.dart';

import 'core/layout.dart';
import 'core/nav.dart' show rootNavigatorKey;
import 'core/perf.dart';
import 'core/theme.dart';
import 'screens/intro_screen.dart';
import 'services/iptv/iptv_settings.dart';

/// Phones: no status bar or navigation buttons. A swipe from the edge shows them for a moment
/// (sticky immersive); anything that brings them back for good gets them hidden again.
void _hideSystemBars() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
    _hideSystemBars();
    SystemChrome.setSystemUIChangeCallback((barsShowing) async {
      if (barsShowing) Future.delayed(const Duration(seconds: 3), _hideSystemBars);
    });
    AppLifecycleListener(onResume: _hideSystemBars); // registers itself for the app's lifetime
    // 90/120 Hz screens: Android otherwise keeps Flutter apps at 60 Hz
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await FlutterDisplayMode.setHighRefreshRate();
      } catch (_) {}
    }
  }
  await IptvSettings.initialize();
  await AppSettings.initialize();
  await Torrents.initialize(); // iPhone and iPad: is the engine in this build (instant elsewhere)
  unawaited(Downloads.instance.initialize()); // the saved list; nothing starts by itself
  Addons.start();
  Badges.start();
  await WatchProgress.initialize();
  await MyList.initialize();
  await MusicLibrary.initialize();
  await Debrid.initialize();
  await Account.initialize();
  PartyPresence.start();
  Friends.start();
  Dms.start();
  Rooms.start();
  Voice.start();
  WatchParty.start();
  PartyMusic.start();
  PartyLive.start();
  unawaited(PartyAlerts.start());
  await AccountSync.initialize([
    SyncSource(
      kind: 'progress',
      snapshot: WatchProgress.syncSnapshot,
      apply: WatchProgress.syncApply,
      changes: WatchProgress.entries,
      timeOf: (d) => (d['u'] as num?)?.toInt(),
    ),
    SyncSource(
      kind: 'mylist',
      snapshot: MyList.syncSnapshot,
      apply: MyList.syncApply,
      changes: MyList.items,
      timeOf: (d) => (d['a'] as num?)?.toInt(),
    ),
    SyncSource(
      kind: 'settings',
      snapshot: AppSettings.syncSnapshot,
      apply: AppSettings.syncApply,
      changes: AppSettings.anySynced,
      remoteWinsFirst: true,
    ),
    SyncSource(kind: 'manga_fav', snapshot: MangaFavorites.syncSnapshot, apply: MangaFavorites.syncApply, changes: MangaFavorites.items),
    SyncSource(
      kind: 'manga_read',
      snapshot: MangaHistory.syncSnapshot,
      apply: MangaHistory.syncApply,
      changes: MangaHistory.revision,
      timeOf: (d) => (d['t'] as num?)?.toInt(),
    ),
    SyncSource(
      kind: 'audiobooks',
      snapshot: AudiobookPlayer.syncSnapshot,
      apply: AudiobookPlayer.syncApply,
      changes: AudiobookPlayer.syncRevision,
    ),
    ...MusicLibrary.syncSources,
  ]);
  // Trakt, Simkl, AniList: sign-ins on this device, and updates still waiting to go out
  unawaited(TrackerHub.initialize());

  // Full-screen backdrops are ~15 MB each at 1440p. With Flutter's default 100 MB cache, flipping
  // in and out of the spotlight evicted and re-decoded them (and the posters) mid-animation,
  // which measured as 200-800 ms stalls. Desktops have the memory to keep them.
  final cache = PaintingBinding.instance.imageCache;
  if (isDesktopNative || kIsWeb) {
    cache.maximumSizeBytes = 768 << 20;
    cache.maximumSize = 3000;
    // The GPU-side texture cache is sized from the screen (~175 MB at 1440p), so the same
    // images were being evicted from VRAM and re-uploaded on every spotlight transition.
    if (isDesktopNative) {
      SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', 1024 << 20);
    }
  } else {
    cache.maximumSizeBytes = 256 << 20;
  }

  if (isDesktopNative) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'Lorewatch',
      size: Size(1440, 900),
      minimumSize: Size(400, 640),
      center: true,
      backgroundColor: VyseColors.bg,
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
      if (isMacNative) macFullScreen.value = await windowManager.isFullScreen();
    });
    if (isMacNative) windowManager.addListener(_MacFullScreenWatch());
  }

  runApp(const VyseApp());
  startPerfLog();
}

class VyseApp extends StatelessWidget {
  const VyseApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Lorewatch',
        navigatorKey: rootNavigatorKey,
        debugShowCheckedModeBanner: false,
        theme: buildVyseTheme(),
        scrollBehavior: const VyseScrollBehavior(),
        home: const IntroScreen(),
        builder: (context, child) => MacFullScreenScope(child: withThemeAccent(child)),
      );
}

/// Keeps [macFullScreen] in step with the Mac window.
class _MacFullScreenWatch with WindowListener {
  @override
  void onWindowEnterFullScreen() => macFullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => macFullScreen.value = false;
}
