import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/accent.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/music/music_library.dart';
import '../data/music/yt_music.dart';
import '../data/music_player.dart';
import '../models/music/music_track.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/music_widgets.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'music/music_pages.dart';
import 'music/music_shell.dart' show MusicShellScope;
import 'music/music_ui.dart';

/// Music tab, from YouTube Music. Idle: made for you, your library at a glance, what you played,
/// then YouTube Music's own home. Typing: everything for the query, or one kind of it.
///
/// [embedded]: inside the desktop music frame, whose top bar has the search box.
class MusicPage extends StatefulWidget {
  const MusicPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  final _scroll = ScrollController();
  final _text = TextEditingController();
  Timer? _debounce;
  Timer? _suggestTimer;
  String _query = '';
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _text.addListener(_typed);
  }

  void _typed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 420), () => _search(_text.text));
    _suggestTimer?.cancel();
    final now = _text.text;
    _suggestTimer = Timer(const Duration(milliseconds: 160), () async {
      final s = await YtMusic.instance.suggestions(now);
      if (mounted && _text.text == now) setState(() => _suggestions = s.where((x) => x.toLowerCase() != now.trim().toLowerCase()).take(6).toList());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestTimer?.cancel();
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  void _search(String q) {
    q = q.trim();
    if (q == _query) return;
    setState(() => _query = q);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _pick(String s) {
    _text.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
    _debounce?.cancel();
    setState(() => _suggestions = const []);
    _search(s);
  }

  Widget _content(String query) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 340),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
    child: query.isEmpty ? const _Home(key: ValueKey('home')) : _Results(key: ValueKey('q/$query'), query: query),
  );

  @override
  Widget build(BuildContext context) {
    final scope = widget.embedded ? MusicShellScope.of(context) : null;
    if (scope != null) {
      return ColoredBox(
        color: const Color(0xFF07080D),
        child: ValueListenableBuilder<String>(
          valueListenable: scope.query,
          builder: (context, q, _) => PageScrollbar(
            controller: _scroll,
            child: CustomScrollView(controller: _scroll, slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 14)),
              SliverToBoxAdapter(child: _content(q)),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ]),
          ),
        ),
      );
    }
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, top, right, 18),
              sliver: SliverToBoxAdapter(
                child: MusicTitle(
                  title: 'Musica',
                  subtitle: 'Tutti i brani di YouTube Music. Mi piace e playlist ti seguono ovunque.',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    RoundAction(icon: Icons.library_music_rounded, tooltip: 'La tua libreria', onTap: () => openMusicLibrary(context)),
                    const SizedBox(width: 8),
                    RoundAction(icon: Icons.history_rounded, tooltip: 'Cronologia', onTap: () => openMusicHistory(context)),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, _suggestions.isNotEmpty && _text.text.trim().isNotEmpty ? 10 : 26),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: FadeSlideIn(
                      delay: const Duration(milliseconds: 90),
                      offset: 10,
                      child: VyseSearchField(controller: _text, hint: 'Cerca artisti, brani, album e playlist', onSubmit: _pick),
                    ),
                  ),
                ),
              ),
            ),
            if (_suggestions.isNotEmpty && _text.text.trim().isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 0, right, 22),
                sliver: SliverToBoxAdapter(
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in _suggestions)
                      Pressable(
                        onTap: () => _pick(s),
                        builder: (context, hovered, _) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(99),
                            color: VyseColors.ink.withValues(alpha: hovered ? .12 : .06),
                            border: Border.all(color: VyseColors.stroke),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.north_west_rounded, size: 13, color: VyseColors.textFaint),
                            const SizedBox(width: 6),
                            Text(s, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ),
            SliverToBoxAdapter(child: _content(_query)),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────── home ─────────────────────────

class _Home extends StatefulWidget {
  const _Home({super.key});

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late Future<YtHome> _home = YtMusic.instance.home();

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final right = pageRight(context);
    return FutureBuilder<YtHome>(
      future: _home,
      builder: (context, snap) {
        final h = snap.data;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _MadeForYou(home: h),
          const SizedBox(height: 30),
          const _QuickTiles(),
          const _Recent(),
          if (h != null && h.moods.isNotEmpty) ...[
            const ShelfHeader(title: 'Stati d\'animo'),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
                itemCount: h.moods.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => i == h.moods.length
                    ? _Chip(label: 'Tutti i generi e stati d\'animo', icon: Icons.grid_view_rounded, onTap: () => openMusicBrowse(context))
                    : _Chip(label: h.moods[i].title, onTap: () => openMood(context, h.moods[i])),
              ),
            ),
            const SizedBox(height: 26),
          ],
          const _Yours(),
          if (snap.hasError)
            EmptyState(
              icon: Icons.wifi_off_rounded,
              title: "Impossibile raggiungere YouTube Music",
              body: 'La tua libreria funziona comunque. Controlla la connessione e riprova.',
              action: ('Riprova', () => setState(() => _home = YtMusic.instance.home())),
            )
          else if (h == null)
            const RowsSkeleton(rows: 4)
          else
            for (final s in h.shelves) YtShelfView(shelf: s),
        ]);
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.icon});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 15),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: VyseColors.ink.withValues(alpha: hovered ? .14 : .07),
        border: Border.all(color: VyseColors.stroke),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 15, color: VyseColors.textDim), const SizedBox(width: 6)],
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    ),
  );
}

/// Mixes and picks from YouTube Music's home as a deck: the middle card biggest, the others
/// smaller and lower the further out they are. "Surprise me" sits in the middle to start.
/// Drag, scroll sideways, use the arrows, or click a card to bring it to the middle.
class _MadeForYou extends StatefulWidget {
  const _MadeForYou({required this.home});
  final YtHome? home;

  @override
  State<_MadeForYou> createState() => _MadeForYouState();
}

class _MadeForYouState extends State<_MadeForYou> with SingleTickerProviderStateMixin {
  late final _pos = AnimationController.unbounded(vsync: this, value: 0);
  int _count = 0;
  bool _placed = false;

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  List<YtItem> get _picks {
    final h = widget.home;
    if (h == null) return const [];
    final out = <YtItem>[];
    final seen = <String>{};
    for (final s in h.shelves) {
      for (final i in s.items) {
        if ((i.kind == YtKind.playlist || i.kind == YtKind.album) && i.thumb != null && seen.add(i.id)) out.add(i);
        if (out.length >= 14) return out;
      }
    }
    return out;
  }

  Future<void> _surprise() async {
    final likes = MusicLibrary.likes;
    final p = MusicPlayer.instance;
    if (likes.length >= 5) {
      await p.playQueue([for (final l in likes) l.track], shuffled: true);
      return;
    }
    final last = MusicLibrary.history.value.firstOrNull?.track;
    if (last != null) {
      await p.startRadio(last);
      return;
    }
    final picks = widget.home?.shelves.expand((s) => s.items).where((i) => i.playable).toList() ?? const [];
    if (picks.isNotEmpty) {
      await p.playQueue(ytTracks(picks), shuffled: true);
    } else if (mounted) {
      showToast(context, const Text('Ancora niente da scegliere'), icon: Icons.info_outline_rounded);
    }
  }

  void _go(double to) {
    final target = to.roundToDouble().clamp(0.0, (_count - 1).toDouble());
    _pos.animateTo(target, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final picks = _picks;
    // the surprise card in the middle, picks either side
    final half = picks.length ~/ 2;
    final cards = <YtItem?>[...picks.take(half), null, ...picks.skip(half)];
    _count = cards.length;
    if (!_placed || _pos.value > _count - 1) {
      _pos.value = half.toDouble();
      _placed = picks.isNotEmpty;
    }
    final cardW = phone ? 150.0 : 190.0;
    final cardH = cardW * 1.32;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 8),
        child: Row(children: [
          Expanded(child: Text('Fatti per te', style: TextStyle(fontSize: phone ? 26 : 34, fontWeight: FontWeight.w800, letterSpacing: -1.1))),
          if (!phone && picks.isNotEmpty) ...[
            _Arrow(icon: Icons.chevron_left_rounded, onTap: () => _go(_pos.value - 1)),
            const SizedBox(width: 8),
            _Arrow(icon: Icons.chevron_right_rounded, onTap: () => _go(_pos.value + 1)),
          ],
        ]),
      ),
      SizedBox(
        height: cardH + 40,
        child: LayoutBuilder(
          builder: (context, c) => Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs()) _go(_pos.value + e.scrollDelta.dx.sign);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) => _pos.value = (_pos.value - d.delta.dx / (cardW * .8)).clamp(-.4, _count - .6),
              onHorizontalDragEnd: (d) => _go(_pos.value - (d.primaryVelocity ?? 0) / 1800),
              child: AnimatedBuilder(
                animation: _pos,
                builder: (context, _) {
                  final mid = c.maxWidth / 2;
                  final order = [for (var i = 0; i < cards.length; i++) i]..sort((a, b) => (b - _pos.value).abs().compareTo((a - _pos.value).abs()));
                  return Stack(clipBehavior: Clip.none, children: [
                    for (final i in order)
                      if ((i - _pos.value).abs() < 5.2) _place(i, cards[i], mid, cardW, cardH, picks, half),
                  ]);
                },
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _place(int i, YtItem? card, double mid, double cardW, double cardH, List<YtItem> picks, int half) {
    final d = i - _pos.value;
    final ad = d.abs();
    final scale = 1 - math.min(ad, 4) * .1;
    final w = cardW * scale, h = cardH * scale;
    // each step out moves a little less, so the far cards tuck in
    final x = d.sign * (math.min(ad, 1) * cardW * .86 + math.max(ad - 1, 0) * cardW * .62);
    final fade = ad < 4 ? 1.0 : (5.2 - ad) / 1.2;
    return Positioned(
      key: ValueKey('deck/$i'),
      left: mid + x - w / 2,
      top: 10 + (cardH - h) * .62,
      width: w,
      height: h,
      child: Opacity(
        opacity: fade.clamp(0.0, 1.0),
        child: _DeckCard(
          dim: math.min(ad, 3) * .14,
          title: card?.title ?? 'Sorprendimi',
          subtitle: card == null ? 'Scegli qualcosa per me' : (card.subtitle.isNotEmpty ? card.subtitle : card.artistNames),
          art: card != null ? sizedArt(card.thumb, 600) : (picks.isEmpty ? null : sizedArt(picks[math.min(half, picks.length - 1)].thumb, 600)),
          surprise: card == null,
          onTap: ad > .5 ? () => _go(i.toDouble()) : (card != null ? () => openYtItem(context, card) : _surprise),
          onPlay: card != null && ad <= .5 ? () => playYtItem(context, card) : null,
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.ink.withValues(alpha: hovered ? .16 : .08), border: Border.all(color: VyseColors.stroke)),
      child: Icon(icon, size: 22),
    ),
  );
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.title, required this.subtitle, required this.art, required this.onTap, this.onPlay, this.surprise = false, this.dim = 0});
  final String title;
  final String subtitle;
  final String? art;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final bool surprise;
  final double dim;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 26, offset: const Offset(0, 12))],
    ),
    child: OutlineCard(
      label: title,
      radius: 14,
      onTap: onTap,
      builder: (hovered) => Stack(fit: StackFit.expand, children: [
        AnimatedScale(
          scale: hovered ? 1.05 : 1,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          child: art == null
              ? const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF3A2A6E), Color(0xFF151829)])))
              : NetImage(url: art, fallback: Icons.queue_music_rounded),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.center,
              colors: [Colors.black.withValues(alpha: .85), Colors.black.withValues(alpha: 0)],
            ),
          ),
        ),
        if (dim > 0) IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: dim))),
        if (surprise)
          Center(
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [accentOf(context), accentHotOf(context)]),
                boxShadow: [BoxShadow(color: accentHotOf(context).withValues(alpha: .55), blurRadius: 22, offset: const Offset(0, 6))],
              ),
              child: Icon(Icons.shuffle_rounded, color: onAccentOf(context), size: 28),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Color(0xCCFFFFFF))),
              ]),
            ),
            if (onPlay != null)
              AnimatedOpacity(
                opacity: hovered ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Padding(padding: const EdgeInsets.only(left: 8), child: PlayBubble(onTap: onPlay!, size: 36)),
              ),
          ]),
        ),
      ]),
    ),
  );
}

/// Library, Browse, History and Liked songs, with what's in each.
class _QuickTiles extends StatelessWidget {
  const _QuickTiles();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicLibrary.changes,
    builder: (context, _) {
      final saved = MusicLibrary.playlists.length + MusicLibrary.albums.length + MusicLibrary.artists.length + MusicLibrary.savedPlaylists.length;
      final tiles = [
        (Icons.library_music_rounded, 'Libreria', '$saved salvati', () => openMusicLibrary(context)),
        (Icons.explore_rounded, 'Sfoglia', 'Classifiche, stati d\'animo, nuove uscite', () => openMusicBrowse(context)),
        (Icons.history_rounded, 'Cronologia', '${MusicLibrary.plays} ascolti', () => openMusicHistory(context)),
        (Icons.favorite_rounded, 'Brani preferiti', songCount(MusicLibrary.likes.length), () => openLikedSongs(context)),
      ];
      final phone = Layout.isPhone(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 28),
        child: LayoutBuilder(builder: (context, c) {
          final cols = phone ? 2 : 4;
          final w = (c.maxWidth - 12 * (cols - 1)) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final (icon, title, sub, tap) in tiles)
              SizedBox(
                width: w,
                child: Pressable(
                  onTap: tap,
                  builder: (context, hovered, pressed) => AnimatedScale(
                    scale: pressed ? .98 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: VyseColors.ink.withValues(alpha: hovered ? .09 : .05),
                        border: Border.all(color: hovered ? VyseColors.strokeHi : VyseColors.stroke),
                      ),
                      child: Row(children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: accentOf(context).withValues(alpha: .14)),
                          child: Icon(icon, size: 20, color: accentOf(context)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: VyseColors.textDim)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        }),
      );
    },
  );
}

/// The last songs you played: cover, title, artist and a play button, four to a row.
class _Recent extends StatelessWidget {
  const _Recent();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MusicLibrary.history,
    builder: (context, list, _) {
      if (list.isEmpty) return const SizedBox.shrink();
      final tracks = [for (final h in list.take(16)) h.track];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const ShelfHeader(title: 'Ascoltati di recente'),
        Padding(
          padding: EdgeInsets.fromLTRB(Layout.inset(context) - 8, 0, pageRight(context) - 8, 26),
          child: LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 1100 ? 4 : (c.maxWidth > 760 ? 3 : (c.maxWidth > 480 ? 2 : 1));
            final shown = tracks.take(cols * 2).toList();
            final w = (c.maxWidth - 8 * (cols - 1)) / cols;
            return Wrap(spacing: 8, runSpacing: 2, children: [
              for (var i = 0; i < shown.length; i++) SizedBox(width: w, child: _RecentTile(track: shown[i], queue: tracks, index: i)),
            ]);
          }),
        ),
      ]);
    },
  );
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.track, required this.queue, required this.index});
  final MusicTrack track;
  final List<MusicTrack> queue;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = MusicPlayer.instance;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final current = p.current?.id == track.id;
        return GestureDetector(
          onSecondaryTapUp: (d) => showTrackMenu(context, track, d.globalPosition),
          child: Pressable(
            onTap: () => current ? p.toggle() : p.playQueue(queue, start: index),
            builder: (context, hovered, pressed) => AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 62,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: VyseColors.ink.withValues(alpha: hovered ? .06 : 0)),
              child: Row(children: [
                Stack(children: [
                  Artwork(url: track.coverUrl, size: 46, radius: 6),
                  if (current)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                        child: Center(child: Equalizer(active: p.playing)),
                      ),
                    ),
                ]),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: current ? accentOf(context) : VyseColors.text)),
                    const SizedBox(height: 2),
                    Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                  ]),
                ),
                AnimatedScale(
                  scale: hovered ? 1.15 : 1,
                  duration: const Duration(milliseconds: 140),
                  child: Icon(current && p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 28, color: Colors.white),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Liked songs, your playlists and the artists you follow.
class _Yours extends StatelessWidget {
  const _Yours();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicLibrary.changes,
    builder: (context, _) {
      final lists = MusicLibrary.playlists;
      final likes = MusicLibrary.likes;
      final artists = MusicLibrary.artists;
      final w = musicTileW(context);
      final aw = Layout.isPhone(context) ? 120.0 : 150.0;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (lists.isNotEmpty || likes.isNotEmpty)
          Shelf<Object>(
            key: ValueKey('yours/${lists.length}/${likes.length}'),
            title: 'Le tue playlist',
            load: () async => [likes, ...lists],
            maxItems: 40,
            itemWidth: w,
            itemHeight: w + 46,
            itemBuilder: (context, x, _) => x is MyPlaylist ? MyPlaylistCard(p: x) : LikedSongsCard(likes: likes),
          ),
        if (artists.isNotEmpty)
          Shelf<SavedRef>(
            key: ValueKey('artists/${artists.length}'),
            title: 'Artisti che segui',
            load: () async => artists,
            maxItems: 40,
            itemWidth: aw,
            itemHeight: aw + 46,
            itemBuilder: (context, a, _) => YtArtistCard(item: YtItem(kind: YtKind.artist, id: a.id, title: a.title, thumb: a.thumb, subtitle: a.subtitle)),
          ),
      ]);
    },
  );
}

// ───────────────────────── search ─────────────────────────

class _Results extends StatefulWidget {
  const _Results({super.key, required this.query});
  final String query;

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> {
  YtKind? _kind; // null: everything
  late final Future<YtSearch> _all = YtMusic.instance.search(widget.query);
  final _only = <YtKind, Future<List<YtItem>>>{};

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final right = pageRight(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 18),
        child: MusicChips<YtKind?>(
          value: _kind,
          options: const [(null, 'Tutti'), (YtKind.song, 'Brani'), (YtKind.album, 'Albums'), (YtKind.artist, 'Artists'), (YtKind.playlist, 'Playlist'), (YtKind.video, 'Videos')],
          onChanged: (k) => setState(() => _kind = k),
        ),
      ),
      if (_kind == null) _everything() else _one(_kind!),
    ]);
  }

  Widget _error() => const EmptyState(icon: Icons.wifi_off_rounded, title: "Impossibile cercare ora", body: 'Controlla la connessione e riprova.');

  Widget _everything() => FutureBuilder<YtSearch>(
    future: _all,
    builder: (context, snap) {
      if (snap.hasError) return _error();
      final d = snap.data;
      if (d == null) return const RowsSkeleton(rows: 6);
      if (d.top == null && d.shelves.isEmpty) {
        return EmptyState(icon: Icons.search_off_rounded, title: 'Nessun risultato per "${widget.query}"', body: 'Controlla l\'ortografia, o prova con meno parole.');
      }
      final inset = Layout.inset(context);
      final right = pageRight(context);
      final phone = Layout.isPhone(context);
      final topSongs = d.shelves.where((s) => s.title == 'Top result').expand((s) => s.items).where((i) => i.playable).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (d.top != null)
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 26),
            child: Flex(
              direction: phone ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: phone ? double.infinity : 380, child: _TopResult(item: d.top!)),
                if (topSongs.isNotEmpty) ...[
                  const SizedBox(width: 22, height: 14),
                  Flexible(
                    fit: phone ? FlexFit.loose : FlexFit.tight,
                    child: Column(children: [
                      for (var i = 0; i < topSongs.length && i < 4; i++) TrackRow(track: ytTrack(topSongs[i]), queue: ytTracks(topSongs), index: i),
                    ]),
                  ),
                ],
              ],
            ),
          ),
        for (final s in d.shelves.where((s) => s.title != 'Top result'))
          if (s.items.every((i) => i.playable) && s.items.first.kind == YtKind.song) ...[
            ShelfHeader(title: s.title),
            Padding(
              padding: EdgeInsets.fromLTRB(inset - 10, 0, right - 10, 24),
              child: Column(children: [
                for (var i = 0; i < s.items.length && i < 6; i++) TrackRow(track: ytTrack(s.items[i]), queue: ytTracks(s.items), index: i),
              ]),
            ),
          ] else
            YtShelfView(shelf: YtShelf(title: s.title, items: s.items)),
      ]);
    },
  );

  Widget _one(YtKind kind) => FutureBuilder<List<YtItem>>(
    future: _only[kind] ??= YtMusic.instance.searchOnly(widget.query, kind),
    builder: (context, snap) {
      if (snap.hasError) return _error();
      final items = snap.data;
      if (items == null) return const RowsSkeleton(rows: 8);
      if (items.isEmpty) return EmptyState(icon: Icons.search_off_rounded, title: 'Niente di simile a "${widget.query}"', body: 'Prova Tutti, o altre parole.');
      final inset = Layout.inset(context);
      final right = pageRight(context);
      if (kind == YtKind.song || kind == YtKind.video) {
        final tracks = ytTracks(items);
        return Padding(
          padding: EdgeInsets.fromLTRB(inset - 10, 0, right - 10, 0),
          child: Column(children: [for (var i = 0; i < tracks.length; i++) FadeSlideIn(delay: Duration(milliseconds: 18 * i), offset: 6, child: TrackRow(track: tracks[i], queue: tracks, index: i))]),
        );
      }
      final artists = kind == YtKind.artist;
      final w = artists ? (Layout.isPhone(context) ? 120.0 : 150.0) : musicTileW(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: w + 20, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: (w + 20) / (w + 66)),
          itemCount: items.length,
          itemBuilder: (context, i) => FadeSlideIn(delay: Duration(milliseconds: 15 * (i % 20)), offset: 8, child: YtCard(item: items[i])),
        ),
      );
    },
  );
}

/// The best match, big: an artist's portrait, or an album, playlist or song cover.
class _TopResult extends StatelessWidget {
  const _TopResult({required this.item});
  final YtItem item;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final round = i.kind == YtKind.artist;
    final MusicTrack? t = i.playable ? ytTrack(i) : null;
    return Pressable(
      onTap: () => openYtItem(context, i),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: VyseColors.ink.withValues(alpha: hovered ? .09 : .055),
          border: Border.all(color: hovered ? VyseColors.strokeHi : VyseColors.stroke),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Artwork(url: sizedArt(i.thumb, 400), size: 104, radius: 10, circle: round),
          const SizedBox(height: 16),
          Text(i.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.6)),
          const SizedBox(height: 6),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), color: VyseColors.ink.withValues(alpha: .1)),
              child: Text(
                switch (i.kind) {
                  YtKind.artist => 'Artista',
                  YtKind.album => i.albumType ?? 'Album',
                  YtKind.playlist => 'Playlist',
                  YtKind.video => 'Video',
                  _ => 'Song',
                },
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                i.subtitle.replaceFirst(RegExp(r'^(Artist|Album|Single|EP|Playlist|Song|Video) · '), ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: VyseColors.textDim),
              ),
            ),
            if (t != null) LikeButton(track: t, size: 20),
            const SizedBox(width: 6),
            PlayBubble(onTap: () => playYtItem(context, i), size: 44),
          ]),
        ]),
      ),
    );
  }
}
