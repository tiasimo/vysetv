import 'package:flutter/material.dart';
import '../../core/accent.dart';
import 'package:flutter/services.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/music/music_library.dart';
import '../../data/music/yt_music.dart';
import '../../data/music_player.dart';
import '../../widgets/common.dart';
import '../../widgets/music_widgets.dart';
import '../music_detail_pages.dart' show openMusicPlayer;
import '../music_page.dart';
import 'music_pages.dart';
import 'music_ui.dart';

/// Tells music pages they sit inside the desktop music frame (its top bar has the back button
/// and the search box, its bottom bar the player).
class MusicShellScope extends InheritedWidget {
  const MusicShellScope({super.key, required this.query, required this.search, required super.child});

  /// What's typed in the top bar.
  final ValueNotifier<String> query;

  /// Shows results for a query from anywhere in the frame.
  final void Function(String q) search;

  static MusicShellScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MusicShellScope>();

  @override
  bool updateShouldNotify(MusicShellScope old) => false;
}

/// The Music tab. On a desktop: your playlists down the side, a search bar on top, pages in
/// between, and the player along the bottom with the queue beside it, like a music app. On a
/// phone: the music home on its own.
class MusicShell extends StatefulWidget {
  const MusicShell({super.key});

  @override
  State<MusicShell> createState() => _MusicShellState();
}

class _MusicShellState extends State<MusicShell> {
  final _nav = GlobalKey<NavigatorState>();
  final _query = ValueNotifier('');
  final _text = TextEditingController();
  final _searchFocus = FocusNode();
  late final _observer = _Observer(() {
    if (mounted) setState(() {});
  });
  bool _queue = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _query.dispose();
    _text.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+Space (or Ctrl+K) puts you in the search box, from anywhere in Music.
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || !HardwareKeyboard.instance.isControlPressed || !mounted) return false;
    if (e.logicalKey != LogicalKeyboardKey.space && e.logicalKey != LogicalKeyboardKey.keyK) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true) || !TickerMode.valuesOf(context).enabled) return false;
    _searchFocus.requestFocus();
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    return true;
  }

  void _search(String q) {
    q = q.trim();
    _nav.currentState?.popUntil((r) => r.isFirst);
    _query.value = q;
  }

  @override
  Widget build(BuildContext context) {
    if (Layout.of(context) != FormFactor.desktop) return const MusicPage();
    final top = Layout.topChrome(context);
    return MusicShellScope(
      query: _query,
      search: (q) {
        _text.text = q;
        _search(q);
      },
      child: ColoredBox(
        color: const Color(0xFF07080D),
        child: Column(children: [
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Sidebar(top: top, open: (page) => _nav.currentState?.push(ShellRoute(child: page))),
              Expanded(
                child: Column(children: [
                  SizedBox(height: top + 10),
                  _TopBar(
                    canPop: _nav.currentState?.canPop() ?? false,
                    onBack: () => _nav.currentState?.maybePop(),
                    controller: _text,
                    focus: _searchFocus,
                    onChanged: (q) {
                      if (q.trim().isEmpty) _search('');
                    },
                    onSubmit: _search,
                  ),
                  Expanded(
                    child: ClipRect(
                      child: LayoutFrame(
                        inset: 30,
                        child: Navigator(
                          key: _nav,
                          observers: [_observer],
                          onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const MusicPage(embedded: true)),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: _queue ? _QueuePanel(top: top, onClose: () => setState(() => _queue = false)) : const SizedBox(width: 0),
              ),
            ]),
          ),
          MusicBar(queueOpen: _queue, onQueue: () => setState(() => _queue = !_queue)),
        ]),
      ),
    );
  }
}

class _Observer extends NavigatorObserver {
  _Observer(this.changed);
  final VoidCallback changed;
  @override
  void didPush(Route route, Route? previousRoute) => WidgetsBinding.instance.addPostFrameCallback((_) => changed());
  @override
  void didPop(Route route, Route? previousRoute) => WidgetsBinding.instance.addPostFrameCallback((_) => changed());
  @override
  void didRemove(Route route, Route? previousRoute) => WidgetsBinding.instance.addPostFrameCallback((_) => changed());
}

// ───────────────────────── top bar ─────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({required this.canPop, required this.onBack, required this.controller, required this.focus, required this.onChanged, required this.onSubmit});
  final bool canPop;
  final VoidCallback onBack;
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 0, 26, 8),
    child: Row(children: [
      AnimatedOpacity(
        opacity: canPop ? 1 : .3,
        duration: const Duration(milliseconds: 160),
        child: Pressable(
          tooltip: 'Back',
          onTap: canPop ? onBack : null,
          builder: (context, hovered, _) => Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: hovered && canPop ? .12 : 0)),
            child: const Icon(Icons.arrow_back_rounded, size: 21),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: _SearchPill(controller: controller, focus: focus, onChanged: onChanged, onSubmit: onSubmit),
          ),
        ),
      ),
    ]),
  );
}

class _SearchPill extends StatefulWidget {
  const _SearchPill({required this.controller, required this.focus, required this.onChanged, required this.onSubmit});
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;

  @override
  State<_SearchPill> createState() => _SearchPillState();
}

class _SearchPillState extends State<_SearchPill> {
  List<String> _suggest = const [];
  final _link = LayerLink();
  OverlayEntry? _menu;
  int _ask = 0;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_focusChanged);
    _menu?.remove();
    super.dispose();
  }

  void _focusChanged() {
    if (!widget.focus.hasFocus) {
      Future.delayed(const Duration(milliseconds: 160), _hide);
    }
    setState(() {});
  }

  void _hide() {
    _menu?.remove();
    _menu = null;
  }

  Future<void> _typed(String q) async {
    widget.onChanged(q);
    final n = ++_ask;
    final s = q.trim().isEmpty ? const <String>[] : await YtMusic.instance.suggestions(q);
    if (!mounted || n != _ask) return;
    _suggest = s.take(7).toList();
    _hide();
    if (_suggest.isEmpty || !widget.focus.hasFocus) return;
    _menu = OverlayEntry(
      builder: (context) => Positioned(
        width: 520,
        child: CompositedTransformFollower(
          link: _link,
          offset: const Offset(0, 50),
          child: Material(
            color: const Color(0xFF15161D),
            elevation: 12,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: VyseColors.stroke)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final s in _suggest)
                  Pressable(
                    onTap: () => _submit(s),
                    builder: (context, hovered, _) => Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      color: Colors.white.withValues(alpha: hovered ? .06 : 0),
                      child: Row(children: [
                        const Icon(Icons.search_rounded, size: 17, color: VyseColors.textFaint),
                        const SizedBox(width: 12),
                        Expanded(child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                        const Icon(Icons.north_west_rounded, size: 15, color: VyseColors.textFaint),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_menu!);
  }

  void _submit(String s) {
    widget.controller.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
    _ask++;
    _hide();
    widget.onSubmit(s);
    widget.focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focus.hasFocus;
    return CompositedTransformTarget(
      link: _link,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          color: Colors.white.withValues(alpha: focused ? .1 : .065),
          border: Border.all(color: focused ? VyseColors.strokeHi : VyseColors.stroke),
        ),
        child: Row(children: [
          const SizedBox(width: 16),
          const Icon(Icons.search_rounded, size: 20, color: VyseColors.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focus,
              onChanged: _typed,
              onSubmitted: _submit,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14.5),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Search artists, songs, playlists, and albums',
                hintStyle: TextStyle(color: VyseColors.textFaint, fontSize: 14.5),
              ),
            ),
          ),
          if (widget.controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              iconSize: 18,
              color: VyseColors.textDim,
              onPressed: () {
                widget.controller.clear();
                _hide();
                widget.onSubmit('');
              },
              icon: const Icon(Icons.close_rounded),
            )
          else
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: Colors.white.withValues(alpha: .08)),
              child: const Text('Ctrl Space', style: TextStyle(fontSize: 11, color: VyseColors.textDim, fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
    );
  }
}

// ───────────────────────── sidebar ─────────────────────────

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.top, required this.open});
  final double top;
  final void Function(Widget page) open;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _albums = false;
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: 268,
    margin: EdgeInsets.fromLTRB(Layout.railCollapsed + 8, widget.top + 10, 0, 10),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      color: Colors.white.withValues(alpha: .035),
      border: Border.all(color: VyseColors.stroke),
    ),
    child: ListenableBuilder(
      listenable: MusicLibrary.changes,
      builder: (context, _) {
        final q = _filter.text.trim().toLowerCase();
        bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);
        final likes = MusicLibrary.likes;
        final rows = <Widget>[
          if (!_albums) ...[
            if (match('liked songs'))
              _SideRow(
                art: const LikedArt(size: 44, radius: 7),
                title: 'Liked songs',
                subtitle: songCount(likes.length),
                onTap: () => widget.open(const LikedSongsPage()),
              ),
            for (final p in MusicLibrary.playlists)
              if (match(p.name))
                _SideRow(
                  art: PlaylistArt(covers: p.covers, cover: p.cover, size: 44, radius: 7),
                  title: p.name,
                  subtitle: '${p.public ? 'Playlist' : 'Private'} · ${songCount(p.tracks.length)}',
                  onTap: () => widget.open(MyPlaylistPage(id: p.id)),
                ),
            for (final s in MusicLibrary.savedPlaylists)
              if (match(s.title))
                _SideRow(
                  art: Artwork(url: sizedArt(s.thumb, 120), size: 44, radius: 7),
                  title: s.title,
                  subtitle: s.subtitle.isEmpty ? 'Playlist' : s.subtitle,
                  onTap: () => widget.open(YtPlaylistPage(id: s.id, title: s.title, art: s.thumb)),
                ),
          ] else
            for (final a in MusicLibrary.albums)
              if (match(a.title))
                _SideRow(
                  art: Artwork(url: sizedArt(a.thumb, 120), size: 44, radius: 7),
                  title: a.title,
                  subtitle: a.subtitle,
                  onTap: () => widget.open(YtAlbumPage(id: a.id, title: a.title, art: a.thumb)),
                ),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: _Segments(albums: _albums, onChanged: (v) => setState(() => _albums = v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Pressable(
              onTap: () async {
                final id = await showPlaylistEditor(context);
                if (id != null) widget.open(MyPlaylistPage(id: id));
              },
              builder: (context, hovered, _) => Container(
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white.withValues(alpha: hovered ? .07 : .02),
                  border: Border.all(color: Colors.white.withValues(alpha: hovered ? .3 : .14)),
                ),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add_circle_outline_rounded, size: 18, color: VyseColors.textDim),
                  SizedBox(width: 8),
                  Text('New playlist', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: SizedBox(
              height: 34,
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: _albums ? 'Filter albums' : 'Filter playlists',
                  hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, size: 17, color: VyseColors.textFaint),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .05),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(99), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      _albums ? 'Albums you save show up here.' : 'Playlists you make or save show up here.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint, height: 1.4),
                    ),
                  )
                : ListView(padding: const EdgeInsets.fromLTRB(6, 2, 6, 10), children: rows),
          ),
        ]);
      },
    ),
  );
}

class _Segments extends StatelessWidget {
  const _Segments({required this.albums, required this.onChanged});
  final bool albums;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white.withValues(alpha: .05), border: Border.all(color: VyseColors.stroke)),
    child: Row(children: [
      for (final (v, icon, label) in [(false, Icons.queue_music_rounded, 'Playlists'), (true, Icons.album_rounded, 'Albums')])
        Expanded(
          child: Pressable(
            onTap: () => onChanged(v),
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: albums == v ? Colors.white.withValues(alpha: .13) : Colors.transparent,
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 16, color: albums == v ? VyseColors.text : VyseColors.textDim),
                const SizedBox(width: 7),
                Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: albums == v ? VyseColors.text : VyseColors.textDim)),
              ]),
            ),
          ),
        ),
    ]),
  );
}

class _SideRow extends StatelessWidget {
  const _SideRow({required this.art, required this.title, required this.subtitle, required this.onTap});
  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.white.withValues(alpha: hovered ? .06 : 0)),
      child: Row(children: [
        art,
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
          ]),
        ),
      ]),
    ),
  );
}

// ───────────────────────── player bar ─────────────────────────

/// The player along the bottom: the song and its heart, the controls over the progress, and on
/// the right shuffle, repeat, the queue, volume and the full player.
class MusicBar extends StatelessWidget {
  const MusicBar({super.key, required this.queueOpen, required this.onQueue});
  final bool queueOpen;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final t = p.current;
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: t == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  height: 84,
                  padding: EdgeInsets.fromLTRB(Layout.railCollapsed + 16, 0, 22, 0),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0B0C12),
                    border: Border(top: BorderSide(color: VyseColors.stroke)),
                  ),
                  child: Row(children: [
                    // the song
                    Expanded(
                      flex: 3,
                      child: Row(children: [
                        Pressable(
                          onTap: () => openMusicPlayer(context),
                          builder: (context, hovered, _) => Artwork(url: t.coverUrl, size: 52, radius: 8),
                        ),
                        const SizedBox(width: 14),
                        Flexible(
                          child: Pressable(
                            onTap: () => openMusicPlayer(context),
                            builder: (context, hovered, _) => Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, decoration: hovered ? TextDecoration.underline : null)),
                              const SizedBox(height: 2),
                              Text(p.error ?? t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: p.error != null ? accentHotOf(context) : VyseColors.textDim)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        LikeButton(track: t, size: 21),
                      ]),
                    ),
                    // the controls
                    Expanded(
                      flex: 4,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          _BarIcon(icon: Icons.shuffle_rounded, tooltip: 'Shuffle', on: p.shuffle, onTap: p.toggleShuffle),
                          const SizedBox(width: 6),
                          _BarIcon(icon: Icons.skip_previous_rounded, tooltip: 'Previous', size: 26, onTap: p.previous),
                          const SizedBox(width: 10),
                          Pressable(
                            tooltip: p.playing ? 'Pause' : 'Play',
                            onTap: p.toggle,
                            builder: (context, hovered, pressed) => AnimatedScale(
                              scale: pressed ? .92 : (hovered ? 1.05 : 1),
                              duration: const Duration(milliseconds: 120),
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(colors: [accentOf(context), accentHotOf(context)]),
                                  boxShadow: [BoxShadow(color: accentHotOf(context).withValues(alpha: .4), blurRadius: 16, offset: const Offset(0, 4))],
                                ),
                                child: p.resolving || p.buffering
                                    ? Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.2, color: onAccentOf(context)))
                                    : Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 26, color: onAccentOf(context)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _BarIcon(icon: Icons.skip_next_rounded, tooltip: 'Next', size: 26, onTap: p.next),
                          const SizedBox(width: 6),
                          _BarIcon(
                            icon: p.repeat == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                            tooltip: 'Repeat',
                            on: p.repeat != LoopMode.off,
                            onTap: p.cycleRepeat,
                          ),
                        ]),
                        const SizedBox(height: 4),
                        const _Progress(),
                      ]),
                    ),
                    // the rest
                    Expanded(
                      flex: 3,
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        _BarIcon(icon: Icons.queue_music_rounded, tooltip: 'Up next', on: queueOpen, onTap: onQueue),
                        const SizedBox(width: 4),
                        Icon(p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 19, color: VyseColors.textDim),
                        SizedBox(
                          width: 110,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              overlayShape: SliderComponentShape.noOverlay,
                              activeTrackColor: VyseColors.text,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                            ),
                            child: Slider(value: p.volume.clamp(0, 100), max: 100, onChanged: p.setVolume),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _BarIcon(icon: Icons.open_in_full_rounded, tooltip: 'Full player', size: 19, onTap: () => openMusicPlayer(context)),
                      ]),
                    ),
                  ]),
                ),
        );
      },
    );
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({required this.icon, required this.tooltip, required this.onTap, this.on = false, this.size = 20});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, _) => Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(shape: BoxShape.circle, color: on ? accentOf(context).withValues(alpha: .14) : Colors.white.withValues(alpha: hovered ? .08 : 0)),
      child: Icon(icon, size: size, color: on ? accentOf(context) : (hovered ? VyseColors.text : VyseColors.textDim)),
    ),
  );
}

class _Progress extends StatefulWidget {
  const _Progress();

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return ValueListenableBuilder<Duration>(
      valueListenable: p.duration,
      builder: (context, dur, _) => ValueListenableBuilder<Duration>(
        valueListenable: p.position,
        builder: (context, pos, _) {
          final total = dur.inMilliseconds.toDouble();
          final at = _drag ?? (total <= 0 ? 0.0 : (pos.inMilliseconds / total).clamp(0.0, 1.0));
          const time = TextStyle(fontSize: 11.5, color: VyseColors.textFaint, fontFeatures: [FontFeature.tabularFigures()]);
          return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(width: 44, child: Text(fmtClock(Duration(milliseconds: (at * total).round())), textAlign: TextAlign.right, style: time)),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SizedBox(
                width: 420,
                height: 16,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: SliderComponentShape.noOverlay,
                    activeTrackColor: accentOf(context),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: at,
                    onChanged: total <= 0 ? null : (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      p.seek(Duration(milliseconds: (v * total).round()));
                      setState(() => _drag = null);
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 44, child: Text(fmtClock(dur), style: time)),
          ]);
        },
      ),
    );
  }
}

// ───────────────────────── queue ─────────────────────────

/// Up next, beside the pages: what's playing, what you added, then what came on its own.
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({required this.top, required this.onClose});
  final double top;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return Container(
      width: 340,
      margin: EdgeInsets.fromLTRB(0, top + 10, 10, 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: Colors.white.withValues(alpha: .035), border: Border.all(color: VyseColors.stroke)),
      child: ListenableBuilder(
        listenable: p,
        builder: (context, _) {
          final now = p.current;
          final up = p.upNext;
          final mine = <int>[], auto = <int>[];
          for (var i = 0; i < up.length; i++) {
            (p.autoIds.contains(up[i].id) ? auto : mine).add(i);
          }
          Widget row(int i) {
            final t = up[i];
            return Pressable(
              key: ValueKey('q/$i/${t.id}'),
              onTap: () => p.jumpTo(p.index + 1 + i),
              builder: (context, hovered, _) => Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: Colors.white.withValues(alpha: hovered ? .06 : 0)),
                child: Row(children: [
                  Artwork(url: t.coverUrl, size: 40, radius: 6),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                    ]),
                  ),
                  if (hovered)
                    IconButton(
                      tooltip: 'Remove',
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      color: VyseColors.textFaint,
                      onPressed: () => p.removeAt(p.index + 1 + i),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ]),
              ),
            );
          }

          Widget label(String text, int n) => Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
            child: Row(children: [
              Expanded(child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: VyseColors.textDim))),
              Text('$n', style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
            ]),
          );

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
              child: Row(children: [
                const Icon(Icons.queue_music_rounded, size: 20, color: VyseColors.textDim),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Up next', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    Text(songCount(up.length), style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                  ]),
                ),
                _BarIcon(icon: Icons.shuffle_rounded, tooltip: 'Shuffle what’s next', on: p.shuffle, onTap: p.toggleShuffle),
                _BarIcon(
                  icon: Icons.playlist_add_rounded,
                  tooltip: 'More like this',
                  onTap: () {
                    final c = p.current;
                    if (c != null) p.startRadio(c);
                  },
                ),
                _BarIcon(icon: Icons.close_rounded, tooltip: 'Close', onTap: onClose),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(6, 4, 6, 12), children: [
                if (now != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: accentOf(context).withValues(alpha: .1)),
                    child: Row(children: [
                      Stack(children: [
                        Artwork(url: now.coverUrl, size: 44, radius: 6),
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                            child: Center(child: Equalizer(active: p.playing)),
                          ),
                        ),
                      ]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('NOW PLAYING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1, color: accentOf(context))),
                          Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                          Text(now.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                        ]),
                      ),
                    ]),
                  ),
                if (up.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Nothing after this one. "Play next" and "Add to queue" on any song put it here.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: VyseColors.textFaint, height: 1.4)),
                  ),
                if (mine.isNotEmpty) ...[label('ADDED BY YOU', mine.length), for (final i in mine) row(i)],
                if (auto.isNotEmpty) ...[label('UP NEXT', auto.length), for (final i in auto) row(i)],
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
