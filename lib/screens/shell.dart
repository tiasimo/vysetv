import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/nav_sections.dart';
import '../core/theme.dart';
import '../data/account.dart';
import '../data/app_settings.dart';
import '../data/debrid/debrid.dart' show Debrid;
import '../data/party/alerts.dart';
import '../data/party/dms.dart';
import '../data/party/friends.dart';
import '../data/party/party_music.dart';
import '../data/party/watch_party.dart';
import '../data/discover.dart';
import '../data/updater.dart';
import '../widgets/update_dialog.dart';
import '../widgets/common.dart';
import '../widgets/p2p_consent.dart';
import '../widgets/audiobook_widgets.dart';
import 'anime_page.dart';
import 'discover_page.dart';
import 'downloads_page.dart';
import 'home_page.dart';
import 'live_tv_page.dart';
import 'history_page.dart';
import 'my_list_page.dart';
import 'floating.dart';
import 'party/dm_page.dart' show openDm, MiniChat;
import 'party/party_page.dart';
import 'party/party_widgets.dart' show PartyAvatar;
import '../data/party/rooms.dart';
import '../data/party/voice.dart';
import 'party/rooms_view.dart' show openRoom;
import 'manga_page.dart';
import 'audiobooks_page.dart';
import 'music/music_shell.dart';
import 'profile_page.dart';
import 'search_page.dart';
import 'servers/servers_page.dart';

/// What each sidebar entry shows, by its id (the sections themselves are in core/nav_sections.dart;
/// their place in the navbar is the user's to change). Movies / TV / Anime / Top Rated are
/// Discover with presets.
/// The update box is on its way up by itself (or has been) this run of the app: once per start.
bool _updateOffered = false;

Widget _tabRoot(NavItem item) => switch (item.id) {
      'home' => const HomePage(),
      'discover' => const DiscoverPage(),
      'search' => const SearchPage(),
      'movies' => const DiscoverPage(
          title: 'Film',
          subtitle: 'Tutti i film su TMDB',
          initial: DiscoverQuery(type: MediaType.movie),
        ),
      'tv' => const DiscoverPage(
          title: 'Serie TV',
          subtitle: 'Serie da tutto il mondo',
          initial: DiscoverQuery(type: MediaType.tv),
        ),
      'anime' => const AnimePage(),
      'top' => const DiscoverPage(
          title: 'Più votati',
          subtitle: 'I titoli più votati di sempre',
          initial: DiscoverQuery(sort: SortBy.topRated),
        ),
      'party' => const PartyPage(),
      'list' => const MyListPage(),
      'downloads' => const DownloadsPage(),
      'history' => const HistoryPage(),
      'servers' => const ServersPage(),
      'manga' => const MangaPage(),
      'music' => const MusicShell(),
      'audiobooks' => const AudiobooksPage(),
      'live' => const LiveTvPage(),
      _ => _PlaceholderPage(item: item),
    };

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// The section on screen, by id. The app opens on the first one the navbar shows.
  String _current = NavLayout.visible.first.id;

  /// Whether that section has been in the navbar since it opened. One that never was (Party,
  /// hidden, opened by a notification) stays until you leave it; one that was and got switched
  /// off in Settings is left for the first section (see [_settle]).
  bool _inBar = true;

  /// Settings pages open inside the section on screen (they live in its navigator).
  int _settingsOpen = 0;
  bool _railOpen = false;
  StreamSubscription<(String, DmMessage)>? _dms;
  StreamSubscription<String>? _p2pAsks;
  WatchState? _lastWatch;
  Set<String>? _requests; // who had asked to be friends, as of the last update

  /// Someone new asked to be friends (the first load only notes who's already waiting).
  /// A newer version turned up (the check runs by itself after start-up): the update box comes
  /// up once, when nothing else is over the app. Over a player or another box it waits.
  void _updateChanged() {
    final u = Updater.instance.newer;
    if (u == null || Updater.instance.stage != UpdateStage.available || _updateOffered || !Updater.instance.shouldOffer(u)) return;
    _updateOffered = true;
    void offer([int tries = 0]) {
      // opened from Settings in the meantime, or no longer on offer: nothing to bring up
      if (!mounted || Updater.instance.shownThisRun || Updater.instance.newer == null || Updater.instance.busy) return;
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        // something is open on top (the player, a dialog): look again in a while
        if (tries < 40) Timer(const Duration(minutes: 3), () => offer(tries + 1));
        return;
      }
      showUpdateDialog(context);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => offer());
  }

  void _friendsChanged() {
    final lists = Friends.lists.value;
    if (identical(lists, FriendLists.empty)) {
      _requests = null; // signed out, or another account
      return;
    }
    final was = _requests;
    _requests = {for (final p in lists.incoming) p.id};
    if (was == null || !mounted || Account.user.value?.statusMode == 'dnd') return;
    final fresh = [for (final p in lists.incoming) if (!was.contains(p.id)) p];
    if (fresh.isEmpty) return;
    showToast(
      context,
      Text(
        fresh.length == 1 ? '${fresh.first.name} sent you a friend request' : '${fresh.length} nuove richieste di amicizia',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      icon: Icons.person_add_alt_1_rounded,
    );
  }

  /// The host started something in your room: say so (unless you're already watching).
  void _watchChanged() {
    final s = WatchParty.state.value, was = _lastWatch;
    _lastWatch = s;
    if (s == null || s.mine || WatchParty.playerOpen > 0 || s.sameTitle(was) || !mounted) return;
    if (s.isMusic && (was?.isMusic == true || PartyMusic.listening.value)) return; // said once, not every song
    showToast(
      context,
      Text(
        s.isMusic ? 'Music is on in your room. Open the room to listen along.' : '${s.media.title} is on in your room. Open the room to watch together.',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      icon: Icons.groups_rounded,
    );
  }

  @override
  void initState() {
    super.initState();
    // the minimized player and the floating chat live over every page from here on
    WidgetsBinding.instance.addPostFrameCallback((_) => FloatingLayer.attach());
    WatchParty.state.addListener(_watchChanged);
    // the room's host wants to play a torrent together: P2P streaming is off here, so ask
    _p2pAsks = WatchParty.p2pAsks.listen((who) async {
      if (!mounted) return;
      unawaited(WatchParty.replyP2p(Debrid.active || await allowP2p(context, who: who)));
    });
    Friends.lists.addListener(_friendsChanged);
    NavLayout.changes.addListener(_layoutChanged);
    Updater.instance.addListener(_updateChanged);
    unawaited(Updater.instance.initialize());
    // a tapped notification: the conversation, or the room, in the Party tab (also when the
    // navbar hides Party: it opens anyway, with nothing lit in the bar)
    PartyAlerts.onOpen = (target) {
      if (!mounted) return;
      if (_current != 'party') _go('party');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = _nav('party').currentState;
        if (nav == null) return;
        if (target == 'room') {
          openRoom(nav);
        } else if (target.startsWith('dm:')) {
          final p = Dms.threads.value.where((t) => t.partner.id == target.substring(3)).firstOrNull?.partner;
          if (p != null && Dms.openWith != p.id) openDm(nav, p);
        }
      });
    };
    // a DM arriving while its chat isn't open (and not on Do not disturb)
    _dms = Dms.events.listen((ev) {
      final (action, m) = ev;
      if (action != 'create' || m.mine || Dms.openWith == m.sender || Account.user.value?.statusMode == 'dnd' || PartyMutes.has(m.sender) || !mounted) {
        return;
      }
      final from = Dms.threads.value.where((t) => t.partner.id == m.sender).firstOrNull?.partner;
      final who = from?.name ?? 'Un amico';
      showToast(
        context,
        Text.rich(
          TextSpan(children: [
            TextSpan(text: '$who  ', style: const TextStyle(fontWeight: FontWeight.w800)),
            TextSpan(text: m.body.replaceAll('\n', ' '), style: const TextStyle(color: VyseColors.textDim)),
          ]),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: VyseColors.text),
        ),
        icon: Icons.chat_bubble_rounded,
        // pressing it opens their chat in a small window that stays over whatever you're doing
        onTap: from == null ? null : () => MiniChat.open(from),
      );
    });
  }

  @override
  void dispose() {
    FloatingLayer.detach();
    WatchParty.state.removeListener(_watchChanged);
    Friends.lists.removeListener(_friendsChanged);
    NavLayout.changes.removeListener(_layoutChanged);
    Updater.instance.removeListener(_updateChanged);
    _dms?.cancel();
    _p2pAsks?.cancel();
    super.dispose();
  }

  /// One navigator per tab, so details pages open beside the rail instead of over it.
  final _navigators = <String, GlobalKey<NavigatorState>>{};
  GlobalKey<NavigatorState> _nav(String id) => _navigators.putIfAbsent(id, GlobalKey<NavigatorState>.new);

  void _go(String id) => setState(() {
        _current = id;
        _inBar = NavLayout.shows(id);
        _settingsOpen = 0; // a tab's navigator starts over each time it's shown
      });

  void _select(String id) {
    if (id == _current) {
      // Tapping the current tab again returns to its root (e.g. Home from a details page).
      _nav(id).currentState?.popUntil((r) => r.isFirst);
      return;
    }
    _go(id);
  }

  /// The navbar changed (Settings → Appearance, or another device through the account): the
  /// rail and the bottom bar redraw, and the section on screen is checked.
  void _layoutChanged() {
    if (!mounted) return;
    setState(() {});
    _settle();
  }

  /// The section on screen was switched off: go to the first one still showing. Not while
  /// Settings is open inside it, or the page with the switch would vanish under the hand that
  /// flipped it; that case is settled when Settings closes.
  void _settle() {
    if (!mounted) return;
    if (NavLayout.shows(_current)) {
      _inBar = true;
    } else if (_inBar && _settingsOpen == 0) {
      _go(NavLayout.visible.first.id);
    }
  }

  /// A Settings page opened or closed in the navigator of section [id].
  void _settingsRoute(String id, bool opened) {
    if (id != _current) return; // the tab fading out
    if (opened) {
      _settingsOpen++;
    } else {
      if (_settingsOpen > 0) _settingsOpen--;
      // after the pop that reported it has finished
      scheduleMicrotask(_settle);
    }
  }

  /// Profile & settings open inside the current tab, so Back returns to where you were.
  void _openProfile() {
    final nav = _nav(_current).currentState;
    if (nav == null) return;
    var open = false;
    nav.popUntil((r) {
      open = r.settings.name == ProfilePage.route;
      return true;
    });
    if (!open) nav.push(ShellRoute(settings: const RouteSettings(name: ProfilePage.route), child: const ProfilePage()));
  }

  void _onSystemBack() {
    final nav = _nav(_current).currentState;
    // home is the first section the navbar shows, whichever that is
    final home = NavLayout.visible.first.id;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (_current != home) {
      _go(home);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final id = _current;

    // keyed by the section, not by its place in the navbar: reordering leaves the page alone
    final page = AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
      child: _TabNavigator(
        key: ValueKey(id),
        navigatorKey: _nav(id),
        root: _tabRoot(navItem(id)),
        onSettings: (opened) => _settingsRoute(id, opened),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onSystemBack();
      },
      child: _scaffold(context, phone, page),
    );
  }

  Widget _scaffold(BuildContext context, bool phone, Widget page) {
    // read above the Scaffold: inside it, the keyboard's height is already taken out
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    // the navbar's sections: the user's order, without the ones they hid
    final sections = NavLayout.visible;
    return Scaffold(
      backgroundColor: VyseColors.bg,
      body: ValueListenableBuilder<int>(
        valueListenable: fullWindow,
        builder: (context, full, _) => Stack(children: [
        Positioned.fill(child: page),
        if (full == 0) ...[
        // its own layer: the page scrolling underneath doesn't repaint it
        const Positioned.fill(child: RepaintBoundary(child: _AmbientGlow())),
        if (!phone) ...[
          // Darkens the page behind the labels while the rail is open.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _railOpen ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xF205070D), Color(0xB305070D), Color(0x0005070D)],
                      stops: [0, .22, .5],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: SideRail(
              items: sections,
              selected: _current,
              onSelect: _select,
              onProfile: _openProfile,
              onOpenChanged: (v) => setState(() => _railOpen = v),
            ),
          ),
        ],
        // Now-playing bar: above the bottom bar on phones, floating bottom-center elsewhere.
        if (phone)
          Positioned(left: 8, right: 8, bottom: 68 + MediaQuery.paddingOf(context).bottom, child: const ActiveMiniPlayer())
        // Music on a desktop has its own player bar along the bottom
        else if (!(_current == 'music' && Layout.of(context) == FormFactor.desktop))
          Positioned(
            left: Layout.railCollapsed + 24,
            right: 24,
            bottom: 20,
            child: const Center(child: SizedBox(width: 560, child: ActiveMiniPlayer())),
          ),
        if (phone)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // out of the way while typing (it would sit right on top of the text box) and on
            // pages that ask for the whole screen
            child: ValueListenableBuilder<int>(
              valueListenable: hideBottomBar,
              builder: (_, hiders, _) => hiders > 0 || keyboardOpen
                  ? const SizedBox.shrink()
                  : BottomBar(items: sections, selected: _current, onSelect: _select, onProfile: _openProfile),
            ),
          ),
        if (isDesktopNative) const Positioned(top: 0, left: 0, right: 0, child: WindowBar()),
        // who's in your room's call, on every page
        Positioned(top: Layout.windowChrome(context) + 10, right: phone ? 12 : 18, child: _VoiceDots(onTap: () => PartyAlerts.onOpen?.call('room'))),
        ],
      ]),
      ),
    );
  }
}

/// Everyone in your room's voice call, as small faces at the top right of every page; a green
/// ring while they talk. Tapping opens the room.
class _VoiceDots extends StatelessWidget {
  const _VoiceDots({required this.onTap});
  final VoidCallback onTap;

  static const _green = Color(0xFF3DDC97);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Voice.state, Voice.inCall, Voice.speaking, Rooms.mine]),
    builder: (context, _) {
      final members = Rooms.mine.value?.members ?? const <RoomMember>[];
      final call = Voice.inCall.value, talking = Voice.speaking.value;
      final people = [for (final m in members) if (call.containsKey(m.id)) m];
      if (Voice.state.value != VoiceState.on || people.isEmpty) return const SizedBox.shrink();
      final shown = people.take(6).toList();
      return Pressable(
        tooltip: 'Apri la stanza',
        onTap: onTap,
        builder: (context, hovered, _) => Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: hovered ? .7 : .5), borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in shown)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: talking.contains(m.id) ? _green : Colors.transparent, width: 2)),
                    child: PartyAvatar(url: m.avatarUrl, name: m.name, size: 24),
                  ),
                ),
              if (people.length > shown.length)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('+${people.length - shown.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// The Appearance theme's light, laid softly over the top of every page.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder(
          valueListenable: AppSettings.themeId,
          builder: (context, _, _) {
            final t = AppSettings.theme;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: !t.glow
                  ? const SizedBox.expand()
                  : DecoratedBox(
                      key: ValueKey(t.id),
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(.7, -1.15),
                          radius: 1.25,
                          colors: [t.color.withValues(alpha: .16), t.color.withValues(alpha: .05), t.color.withValues(alpha: 0)],
                          stops: const [0, .45, 1],
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
            );
          },
        ),
      );
}

class _TabNavigator extends StatefulWidget {
  const _TabNavigator({super.key, required this.navigatorKey, required this.root, required this.onSettings});
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget root;

  /// A Settings page opened (true) or closed (false) in this tab.
  final ValueChanged<bool> onSettings;

  @override
  State<_TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<_TabNavigator> {
  // Nested navigators need their own HeroController for poster flights.
  final _heroes = HeroController(createRectTween: (b, e) => MaterialRectArcTween(begin: b, end: e));
  late final _settings = _SettingsWatch((opened) => widget.onSettings(opened));

  @override
  void dispose() {
    _heroes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Navigator(
        key: widget.navigatorKey,
        observers: [_heroes, _settings],
        onGenerateInitialRoutes: (_, _) => [ShellRoute(child: widget.root)],
      );
}

/// Tells the shell when Settings (any route named [ProfilePage.route]) enters or leaves a tab:
/// hiding the section you're in waits for it to close.
class _SettingsWatch extends NavigatorObserver {
  _SettingsWatch(this.onChange);
  final ValueChanged<bool> onChange;

  void _report(Route<dynamic>? route, bool opened) {
    if (route?.settings.name == ProfilePage.route) onChange(opened);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(route, true);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(route, false);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(route, false);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _report(oldRoute, false);
    _report(newRoute, true);
  }
}

// ───────────────────────── Desktop / tablet: icon rail ─────────────────────────

class SideRail extends StatefulWidget {
  const SideRail({super.key, required this.items, required this.selected, required this.onSelect, required this.onOpenChanged, required this.onProfile});

  /// The sections to show, in order (Settings → Appearance → Navigation).
  final List<NavItem> items;

  /// The id of the section on screen. It may be one the navbar hides: then nothing is lit.
  final String selected;
  final ValueChanged<String> onSelect;
  final ValueChanged<bool> onOpenChanged;
  final VoidCallback onProfile;

  @override
  State<SideRail> createState() => _SideRailState();
}

class _SideRailState extends State<SideRail> {
  bool _open = false;

  void _setOpen(bool v) {
    if (v == _open) return;
    setState(() => _open = v);
    widget.onOpenChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final top = Layout.topChrome(context);
    final items = widget.items;
    final at = items.indexWhere((s) => s.id == widget.selected);
    return MouseRegion(
      onEnter: (_) => _setOpen(true),
      onExit: (_) => _setOpen(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutQuart,
        width: _open ? Layout.railExpanded : Layout.railCollapsed,
        child: LayoutBuilder(builder: (context, c) {
          final itemH = (c.maxHeight < 620) ? 46.0 : 60.0;
          return Column(children: [
            SizedBox(height: top + (isDesktopNative ? 0 : 18)),
            _RailBrand(open: _open),
            SizedBox(height: c.maxHeight < 620 ? 20 : 44),
            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Stack(children: [
                  // Soft lit capsule that glides behind the selected item.
                  if (at >= 0)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 380),
                    curve: Curves.easeOutCubic,
                    left: 12,
                    right: 12,
                    top: at * itemH + 6,
                    height: itemH - 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: LinearGradient(
                          colors: [VyseColors.accent.withValues(alpha: .2), VyseColors.accent.withValues(alpha: .04)],
                        ),
                        border: Border.all(color: VyseColors.accent.withValues(alpha: .25)),
                      ),
                    ),
                  ),
                  Column(children: [
                    for (final item in items)
                      _RailItem(
                        key: ValueKey(item.id),
                        item: item,
                        height: itemH,
                        active: item.id == widget.selected,
                        open: _open,
                        onTap: () => widget.onSelect(item.id),
                      ),
                  ]),
                ]),
              ),
            ),
            _RailProfile(open: _open, onTap: widget.onProfile),
            const SizedBox(height: 20),
          ]);
        }),
      ),
    );
  }
}

class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: Row(children: [
          const SizedBox(width: Layout.railCollapsed, child: Center(child: VyseMark(size: 34))),
          Expanded(
            child: AnimatedOpacity(
              opacity: open ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: const VyseWordmark(fontSize: 24),
            ),
          ),
        ]),
      );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.item,
    required this.height,
    required this.active,
    required this.open,
    required this.onTap,
  });

  final NavItem item;
  final double height;
  final bool active;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) {
          final color = active || hovered ? VyseColors.text : const Color(0xFF8B90A3);
          return SizedBox(
            height: height,
            child: Row(children: [
              SizedBox(
                width: Layout.railCollapsed,
                child: Center(
                  child: AnimatedScale(
                    scale: pressed ? .86 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: _NavIcon(item: item, active: active, color: active ? VyseColors.accent : color, size: 25),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedOpacity(
                  opacity: open ? 1 : 0,
                  duration: Duration(milliseconds: open ? 240 : 100),
                  child: AnimatedSlide(
                    offset: Offset(open ? 0 : -.2, 0),
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: color,
                        fontSize: 18,
                        letterSpacing: -.2,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          );
        },
      );
}

class _RailProfile extends StatelessWidget {
  const _RailProfile({required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => SizedBox(
          height: 56,
          child: Row(children: [
            const SizedBox(width: Layout.railCollapsed, child: Center(child: Avatar(size: 32))),
            Expanded(
              child: AnimatedOpacity(
                opacity: open ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: ValueListenableBuilder(
                  valueListenable: AppSettings.displayName,
                  builder: (context, name, _) => Text(name,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: hovered ? VyseColors.text : VyseColors.textDim,
                      )),
                ),
              ),
            ),
          ]),
        ),
      );
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.item, required this.active, required this.color, this.size = 19});
  final NavItem item;
  final bool active;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = item.glyph != null
        ? Text(item.glyph!,
            style: TextStyle(fontSize: size * .9, height: 1, color: color, fontWeight: active ? FontWeight.w700 : FontWeight.w400))
        : Icon(active ? item.activeIcon : item.icon, size: size, color: color);
    if (item.label != 'Party') return icon;
    // unread messages and friend requests
    return ValueListenableBuilder<int>(
      valueListenable: Dms.badge,
      child: icon,
      builder: (context, n, child) => n == 0
          ? child!
          : Stack(clipBehavior: Clip.none, children: [
              child!,
              Positioned(
                right: -8,
                top: -6,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF4D4F),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: VyseColors.bg, width: 2),
                  ),
                  child: Text(n > 99 ? '99+' : '$n',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10, height: 1.2, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
              ),
            ]),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, this.size = 26});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: .35))),
        child: ProfileAvatar(size: size - 3),
      );
}

// ───────────────────────── Phone: flush bottom bar ─────────────────────────

// Not a section: always the last thing in the bar, whatever the navbar hides.
const _profileItem = NavItem('profile', 'Profilo', Icons.person_outline_rounded, Icons.person_rounded);

/// Every tab in one row that scrolls sideways; the selected tab is kept in view.
class BottomBar extends StatefulWidget {
  const BottomBar({super.key, required this.items, required this.selected, required this.onSelect, required this.onProfile});

  /// The sections to show, in order (Settings → Appearance → Navigation).
  final List<NavItem> items;

  /// The id of the section on screen. It may be one the navbar hides: then nothing is lit.
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onProfile;

  @override
  State<BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<BottomBar> {
  static const _itemW = 74.0;
  final _scroll = ScrollController();

  /// Where the section on screen sits in the bar, -1 when the bar doesn't have it.
  static int _place(BottomBar w) => w.items.indexWhere((s) => s.id == w.selected);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(animate: false));
  }

  @override
  void didUpdateWidget(BottomBar old) {
    super.didUpdateWidget(old);
    // another tab, or the same one moved by a reorder
    if (_place(old) != _place(widget)) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal({bool animate = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final at = _place(widget);
    if (at < 0) return;
    final p = _scroll.position;
    final target = (at * _itemW - (p.viewportDimension - _itemW) / 2).clamp(0.0, p.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final bar = Container(
      padding: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: VyseColors.bg.withValues(alpha: lightEffects ? .97 : .82),
        border: const Border(top: BorderSide(color: VyseColors.stroke)),
      ),
      child: SizedBox(
        height: 60,
        child: ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          itemExtent: _itemW,
          itemCount: widget.items.length + 1,
          itemBuilder: (context, i) {
            if (i == widget.items.length) return _BottomItem(item: _profileItem, active: false, onTap: widget.onProfile);
            final item = widget.items[i];
            return _BottomItem(item: item, active: widget.selected == item.id, onTap: () => widget.onSelect(item.id));
          },
        ),
      ),
    );
    // Android: a solid bar instead of blurring the scrolling page behind it every frame
    if (lightEffects) return bar;
    return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: bar));
  }
}

class _BottomItem extends StatelessWidget {
  const _BottomItem({required this.item, required this.active, required this.onTap});
  final NavItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, _, pressed) => AnimatedScale(
          scale: pressed ? .88 : 1,
          duration: const Duration(milliseconds: 120),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              width: active ? 18 : 0,
              height: 3,
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(2)),
            ),
            _NavIcon(item: item, active: active, color: active ? VyseColors.text : const Color(0xFF8B90A3), size: 21),
            const SizedBox(height: 4),
            Text(item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? VyseColors.text : VyseColors.textFaint,
                )),
          ]),
        ),
      );
}

// ───────────────────────── Desktop window chrome ─────────────────────────

class WindowBar extends StatelessWidget {
  const WindowBar({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: Layout.windowChrome(context),
        child: Row(children: [
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          if (hasCustomWindowButtons) ...[
            _WinButton(icon: Icons.remove_rounded, onTap: () => windowManager.minimize()),
            _WinButton(
              icon: Icons.crop_square_rounded,
              onTap: () async => await windowManager.isMaximized()
                  ? windowManager.unmaximize()
                  : windowManager.maximize(),
            ),
            _WinButton(icon: Icons.close_rounded, danger: true, onTap: () => windowManager.close()),
          ],
        ]),
      );
}

class _WinButton extends StatelessWidget {
  const _WinButton({required this.icon, required this.onTap, this.danger = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 32,
          color: hovered
              ? (danger ? const Color(0xFFE5383B) : Colors.white.withValues(alpha: .08))
              : Colors.transparent,
          child: Icon(icon, size: 13, color: hovered ? Colors.white : const Color(0xFF8B90A3)),
        ),
      );
}

// ───────────────────────── Placeholder for the pages we haven't built ─────────────────────────

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.item});
  final NavItem item;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: Layout.isPhone(context) ? 0 : Layout.railCollapsed),
        child: Center(
          child: FadeSlideIn(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _NavIcon(item: item, active: true, color: VyseColors.textDim, size: 40),
              const SizedBox(height: 18),
              Text(item.label, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.6)),
              const SizedBox(height: 6),
              const Text('In arrivo.', style: TextStyle(color: VyseColors.textDim)),
            ]),
          ),
        ),
      );
}
