import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../data/trackers/tracker_hub.dart';
import 'open_link.dart';
import 'player_page.dart';

/// Search: a glowing bar up top, then sliders. Before typing you get recents, suggestions,
/// trending and genres; while typing, a Top result spotlight plus Movies / TV / People rows.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;
  Timer? _remember;
  String _query = '';

  // A link in the bar (a video's address, or a magnet link) plays instead of being searched for.
  String _before = ''; // the bar's text before this change, to tell a paste from typing
  bool _opening = false;
  PastedLink? get _link => PastedLink.parse(_text.text);

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTyped);
    // Land with the cursor ready, once the page transition has settled.
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _remember?.cancel();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _typing => _text.text.trim() != _query;

  void _onTyped() {
    final now = _text.text.trim(), before = _before;
    _before = now;
    final link = PastedLink.parse(now);
    if (link != null) {
      _debounce?.cancel();
      _remember?.cancel();
      setState(() => _query = ''); // nothing to search for
      // pasted in one go (not typed out letter by letter): play it straight away
      if (now != before && now.length - before.length > 8 && PastedLink.parse(before) == null) _open(link);
      return;
    }
    setState(() {}); // clear button + spinner
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 320), () {
      final q = _text.text.trim();
      if (q == _query) return;
      setState(() => _query = q);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      // Settled on something for a moment: remember it.
      _remember?.cancel();
      _remember = Timer(const Duration(milliseconds: 1600), () => RecentSearches.add(q));
    });
  }

  /// Plays the link in the bar. One at a time: a second Enter while it's getting ready does nothing.
  Future<void> _open(PastedLink link) async {
    if (_opening) return;
    _opening = true;
    _focus.unfocus();
    try {
      await playPastedLink(context, link);
    } finally {
      _opening = false;
    }
  }

  void _searchFor(String q) {
    if (PastedLink.parse(q) case final link?) {
      _open(link);
      return;
    }
    _text.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    _debounce?.cancel();
    setState(() => _query = q.trim());
    RecentSearches.add(q);
  }

  void _clear() {
    _text.clear();
    _debounce?.cancel();
    setState(() => _query = '');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 34);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -260, left: 0, right: 0, child: Center(child: _Glow())),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(inset, top, phone ? 16 : 40, phone ? 18 : 30),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: FadeSlideIn(
                      offset: 14,
                      child: _SearchBar(
                        controller: _text,
                        focus: _focus,
                        busy: _link == null && _typing && _text.text.trim().isNotEmpty,
                        onClear: _clear,
                        onSubmit: _searchFor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, .02), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                child: switch (_link) {
                  final link? => _LinkCard(key: ValueKey('link/${link.isMagnet ? link.magnet!.hash : link.url}'), link: link, onPlay: () => _open(link)),
                  _ when _query.isEmpty => _Idle(key: const ValueKey('idle'), onPick: _searchFor),
                  _ => _Results(key: ValueKey('q/$_query'), query: _query, onPick: _searchFor),
                },
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: phone ? 110 + MediaQuery.paddingOf(context).bottom : 48)),
          ]),
        ),
      ]),
    );
  }
}

/// A link is in the bar: what it is, how it will play, and a button (Enter does the same).
class _LinkCard extends StatelessWidget {
  const _LinkCard({super.key, required this.link, required this.onPlay});
  final PastedLink link;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final magnet = link.isMagnet;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(magnet ? 'LINK MAGNET' : 'LINK', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.1, color: VyseColors.accent)),
        const SizedBox(height: 6),
        Text(link.what, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, height: 1.25, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        Text(
          magnet ? '${link.how}. Scegli tu il file da riprodurre.' : '${link.how}. Si riproduce nel player così com\'è.',
          style: TextStyle(fontSize: 13, height: 1.4, color: VyseColors.textDim),
        ),
      ],
    );
    final icon = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.accent.withValues(alpha: .14)),
      child: Icon(magnet ? Icons.hub_outlined : Icons.link_rounded, color: VyseColors.accent, size: 22),
    );
    final play = PillButton(label: 'Riproduci', icon: Icons.play_arrow_rounded, primary: true, expand: phone, onTap: onPlay);
    return Padding(
      padding: EdgeInsets.fromLTRB(Layout.inset(context), 6, phone ? 16 : 40, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            padding: EdgeInsets.all(phone ? 16 : 20),
            decoration: BoxDecoration(
              color: VyseColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: VyseColors.stroke),
            ),
            child: phone
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [icon, const SizedBox(width: 14), Expanded(child: details)]),
                      const SizedBox(height: 16),
                      play,
                    ],
                  )
                : Row(children: [icon, const SizedBox(width: 16), Expanded(child: details), const SizedBox(width: 16), play]),
          ),
        ),
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: 900,
          height: 520,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              colors: [Color(0x26FF8A1A), Color(0x127A5CFF), Color(0x0007080F)],
              stops: [0, .45, 1],
            ),
          ),
        ),
      );
}

// ───────────────────────── Search bar ─────────────────────────

class _SearchBar extends StatefulWidget {
  const _SearchBar({
    required this.controller,
    required this.focus,
    required this.busy,
    required this.onClear,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final VoidCallback onClear;
  final ValueChanged<String> onSubmit;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() => setState(() => _focused = widget.focus.hasFocus);

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final hasText = widget.controller.text.isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.focus.requestFocus,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: phone ? 52 : 60,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(phone ? 16 : 20),
            color: VyseColors.ink.withValues(alpha: _focused ? .09 : (_hovered ? .07 : .05)),
            border: Border.all(
              color: _focused ? VyseColors.accent.withValues(alpha: .55) : VyseColors.ink.withValues(alpha: _hovered ? .14 : .08),
              width: _focused ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: _focused ? VyseColors.accent.withValues(alpha: .18) : Colors.black.withValues(alpha: .25),
                blurRadius: _focused ? 36 : 20,
                spreadRadius: _focused ? 2 : 0,
                offset: Offset(0, _focused ? 0 : 8),
              ),
            ],
          ),
          child: Row(children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: widget.busy
                  ? SizedBox.square(
                      key: ValueKey('busy'),
                      dimension: 20,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent),
                      ),
                    )
                  : Icon(Icons.search_rounded,
                      key: ValueKey('icon'),
                      size: 22,
                      color: _focused ? VyseColors.accent : VyseColors.textDim),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      hasText ? widget.onClear() : widget.focus.unfocus(),
                },
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: widget.onSubmit,
                  cursorColor: VyseColors.accent,
                  cursorWidth: 2,
                  cursorRadius: const Radius.circular(2),
                  style: TextStyle(fontSize: phone ? 15.5 : 17, fontWeight: FontWeight.w500, color: VyseColors.text),
                  decoration: InputDecoration.collapsed(
                    // says what else the bar takes: a pasted link plays, a magnet lists its files
                    hintText: phone ? 'Cerca, o incolla un link o un magnet' : 'Film, serie e persone, o incolla un link magnet o di stream',
                    hintMaxLines: 1,
                    hintStyle: TextStyle(fontSize: phone ? 15.5 : 17, color: VyseColors.textFaint),
                  ),
                ),
              ),
            ),
            AnimatedScale(
              scale: hasText ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Pressable(
                onTap: widget.onClear,
                tooltip: 'Cancella (Esc)',
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VyseColors.ink.withValues(alpha: hovered ? .2 : .1),
                  ),
                  child: const Icon(Icons.close_rounded, size: 16),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── Before typing ─────────────────────────

class _Idle extends StatefulWidget {
  const _Idle({super.key, required this.onPick});
  final ValueChanged<String> onPick;

  @override
  State<_Idle> createState() => _IdleState();
}

class _IdleState extends State<_Idle> {
  late final _trending = HomeFeed.instance.trendingToday();

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final phone = Layout.isPhone(context);
    final right = phone ? 16.0 : 40.0;
    final landW = phone ? 240.0 : (MediaQuery.sizeOf(context).width * .2).clamp(250.0, 360.0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ValueListenableBuilder<List<String>>(
        valueListenable: RecentSearches.items,
        builder: (context, recent, _) => AnimatedSize(
          duration: const Duration(milliseconds: 260),
          alignment: Alignment.topLeft,
          child: recent.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.fromLTRB(inset, 0, right, 26),
                  child: _ChipSection(
                    title: 'Recenti',
                    icon: Icons.history_rounded,
                    children: [
                      for (final (i, r) in recent.indexed)
                        FadeSlideIn(
                          key: ValueKey('recent/$r'),
                          delay: Duration(milliseconds: 30 * i),
                          offset: 6,
                          child: _SuggestionChip(
                            label: r,
                            onTap: () => widget.onPick(r),
                            onRemove: () => RecentSearches.remove(r),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
      FutureBuilder<List<Media>>(
        future: _trending,
        builder: (context, snap) {
          final picks = (snap.data ?? const <Media>[]).take(10).toList();
          return AnimatedSize(
            duration: const Duration(milliseconds: 300),
            alignment: Alignment.topLeft,
            child: picks.isEmpty
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.fromLTRB(inset, 0, right, 30),
                    child: _ChipSection(
                      title: 'Prova a cercare',
                      icon: Icons.trending_up_rounded,
                      children: [
                        for (final (i, m) in picks.indexed)
                          FadeSlideIn(
                            delay: Duration(milliseconds: 30 * i),
                            offset: 6,
                            child: _SuggestionChip(label: m.title, onTap: () => widget.onPick(m.title)),
                          ),
                      ],
                    ),
                  ),
          );
        },
      ),
      Shelf<Media>(
        title: 'Di tendenza oggi',
        load: () => _trending,
        itemWidth: landW,
        itemHeight: landW * 9 / 16,
        itemBuilder: (_, m, _) => LandscapeCard(media: m),
      ),
      const GenreGrid(),
    ]);
  }
}

class _ChipSection extends StatelessWidget {
  const _ChipSection({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 15, color: VyseColors.textFaint),
          const SizedBox(width: 6),
          Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: children),
      ]);
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap, this.onRemove});
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .95 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: EdgeInsets.fromLTRB(12, 7, onRemove == null ? 12 : 6, 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: VyseColors.ink.withValues(alpha: hovered ? .12 : .05),
              border: Border.all(color: VyseColors.ink.withValues(alpha: hovered ? .18 : .07)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : const Color(0xFFC3C7D4))),
              if (onRemove != null) ...[
                const SizedBox(width: 4),
                Pressable(
                  onTap: onRemove,
                  builder: (context, h, _) =>
                      Icon(Icons.close_rounded, size: 14, color: h ? VyseColors.text : VyseColors.textFaint),
                ),
              ],
            ]),
          ),
        ),
      );
}

// ───────────────────────── Results ─────────────────────────

class _Results extends StatefulWidget {
  const _Results({super.key, required this.query, required this.onPick});
  final String query;
  final ValueChanged<String> onPick;

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> {
  late Future<(List<Media>, List<Media>, List<Person>, List<Studio>)> _all = _load();

  Future<(List<Media>, List<Media>, List<Person>, List<Studio>)> _load() {
    final feed = HomeFeed.instance;
    final q = widget.query;
    return (
      feed.searchMedia(q, tv: false),
      feed.searchMedia(q, tv: true),
      feed.searchPeople(q),
      // A studio lookup failing shouldn't sink the whole search.
      feed.searchStudios(q).catchError((Object _) => <Studio>[]),
    ).wait;
  }

  /// Most popular title among the closest matches from both catalogues.
  Media? _topResult(List<Media> movies, List<Media> shows) {
    final q = widget.query.toLowerCase();
    final pool = [...movies.take(6), ...shows.take(6)].where((m) => m.backdropPath != null).toList();
    if (pool.isEmpty) return null;
    int score(Media m) {
      final t = m.title.toLowerCase();
      final match = t == q ? 3 : (t.startsWith(q) ? 2 : (t.contains(q) ? 1 : 0));
      return match * 100000 + m.voteCount.clamp(0, 99999);
    }

    pool.sort((a, b) => score(b).compareTo(score(a)));
    return pool.first;
  }

  @override
  Widget build(BuildContext context) {
    final ff = Layout.of(context);
    final phone = ff == FormFactor.phone;
    final inset = Layout.inset(context);
    final right = phone ? 16.0 : 40.0;
    final posterW = switch (ff) {
      FormFactor.phone => 112.0,
      FormFactor.tablet => 132.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .1).clamp(140.0, 184.0),
    };

    return FutureBuilder<(List<Media>, List<Media>, List<Person>, List<Studio>)>(
      future: _all,
      builder: (context, snap) {
        if (snap.hasError) {
          return _Empty(
            icon: Icons.wifi_off_rounded,
            title: "Impossibile raggiungere TMDB",
            body: 'Controlla la connessione e riprova.',
            action: ('Riprova', () => setState(() { _all = _load(); })),
          );
        }
        if (!snap.hasData) return _ResultsSkeleton(posterW: posterW);

        final (movies, shows, rawPeople, studios) = snap.data!;
        // TMDB lists every name-match; lead with recognisable faces.
        final people = [...rawPeople]..sort((a, b) {
            final photo = (b.photo != null ? 1 : 0) - (a.photo != null ? 1 : 0);
            return photo != 0 ? photo : b.popularity.compareTo(a.popularity);
          });
        if (movies.isEmpty && shows.isEmpty && people.isEmpty && studios.isEmpty) {
          return _Empty(
            icon: Icons.search_off_rounded,
            title: 'Nessun risultato per "${widget.query}"',
            body: 'Controlla l\'ortografia, o prova un titolo più corto.',
          );
        }

        final top = _topResult(movies, shows);
        List<Media> withPosters(List<Media> l) => l.where((m) => m.posterPath != null && m != top).toList();
        final q = widget.query;

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (top != null)
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, phone ? 26 : 36),
              child: FadeSlideIn(offset: 16, child: _TopResult(media: top)),
            ),
          if (withPosters(movies).isNotEmpty)
            Shelf<Media>(
              key: ValueKey('movies/$q'),
              title: 'Film',
              load: () async => withPosters(movies),
              itemWidth: posterW,
              itemHeight: posterW * 1.5 + 38,
              itemBuilder: (_, m, _) => _TitledPoster(media: m, heroTag: 'search/movies/${m.key}'),
            ),
          if (withPosters(shows).isNotEmpty)
            Shelf<Media>(
              key: ValueKey('shows/$q'),
              title: 'Serie TV',
              load: () async => withPosters(shows),
              itemWidth: posterW,
              itemHeight: posterW * 1.5 + 38,
              itemBuilder: (_, m, _) => _TitledPoster(media: m, heroTag: 'search/shows/${m.key}'),
            ),
          if (people.isNotEmpty)
            Shelf<Person>(
              key: ValueKey('people/$q'),
              title: 'Persone',
              load: () async => people,
              itemWidth: 108,
              itemHeight: 150,
              spacing: 8,
              itemBuilder: (_, p, _) => _PersonTile(person: p, onPick: widget.onPick),
            ),
          if (studios.isNotEmpty)
            Shelf<Studio>(
              key: ValueKey('studios/$q'),
              title: 'Studi e reti TV',
              load: () async => studios,
              itemWidth: phone ? 150 : 180,
              itemHeight: (phone ? 150 : 180) * .56 + 40,
              itemBuilder: (_, s, _) => StudioTile(studio: s),
            ),
        ]);
      },
    );
  }
}

/// Spotlight card for the best match: backdrop, poster, meta, overview and actions.
class _TopResult extends StatelessWidget {
  const _TopResult({required this.media});
  final Media media;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final tag = 'search/top/${media.key}';
    return Pressable(
      onTap: () => openDetails(context, media, heroTag: tag),
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .99 : 1,
        duration: const Duration(milliseconds: 140),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: phone ? 210 : 260,
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: hovered ? VyseColors.ink.withValues(alpha: .7) : VyseColors.ink.withValues(alpha: .07), width: hovered ? 2 : 1),
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: VyseColors.surface,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .4), blurRadius: 30, offset: const Offset(0, 14))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(fit: StackFit.expand, children: [
            AnimatedScale(
              scale: hovered ? 1.04 : 1,
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              child: CachedNetworkImage(
                imageUrl: media.backdrop()!,
                fit: BoxFit.cover,
                alignment: const Alignment(.5, -.3),
                fadeInDuration: const Duration(milliseconds: 400),
                placeholder: (_, _) => ColoredBox(color: VyseColors.surface),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xF207080F), Color(0xB307080F), Color(0x1407080F)],
                  stops: [0, .45, 1],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(phone ? 16 : 24),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (!phone && media.poster() != null) ...[
                  Hero(
                    tag: tag,
                    child: Container(
                      width: 140,
                      height: 210,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 20, offset: const Offset(0, 8))],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CachedNetworkImage(imageUrl: media.poster()!, fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 24),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(4)),
                      child: const Text('RISULTATO PRINCIPALE',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: .4)),
                    ),
                    const SizedBox(height: 10),
                    Text(media.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: phone ? 22 : 30, fontWeight: FontWeight.w800, letterSpacing: -.8, height: 1.08)),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.star_rounded, size: 15, color: VyseColors.star),
                      const SizedBox(width: 3),
                      Text(media.rating.toStringAsFixed(1),
                          style: const TextStyle(color: VyseColors.star, fontWeight: FontWeight.w700, fontSize: 13)),
                      const SizedBox(width: 10),
                      Text([media.year ?? '', media.kind].where((s) => s.isNotEmpty).join('  ·  '),
                          style: const TextStyle(color: Color(0xFFC3C7D4), fontSize: 13)),
                    ]),
                    if (!phone) ...[
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Text(media.overview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFFC3C7D4), fontSize: 13.5, height: 1.55)),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      _MiniPill(
                        icon: Icons.play_arrow_rounded,
                        label: 'Riproduci',
                        primary: true,
                        onTap: () => openPlayer(context, media, episode: media.isTv ? const PlayerEpisode(season: 1, number: 1) : null),
                      ),
                      const SizedBox(width: 8),
                      _MiniPill(
                        icon: Icons.info_outline_rounded,
                        label: 'Dettagli',
                        onTap: () => openDetails(context, media, heroTag: tag),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<Set<String>>(
                        valueListenable: MyList.saved,
                        builder: (context, saved, _) {
                          final on = saved.contains(media.key);
                          return _MiniPill(
                            icon: on ? Icons.check_rounded : Icons.add_rounded,
                            label: on ? 'Nella mia lista' : 'La mia lista',
                            onTap: () => TrackerHub.myListToggle(media),
                          );
                        },
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) {
          final fg = primary ? Colors.black : VyseColors.text;
          return AnimatedScale(
            scale: pressed ? .94 : 1,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: primary
                    ? (hovered ? const Color(0xFFE6E7EE) : Colors.white)
                    : VyseColors.ink.withValues(alpha: hovered ? .2 : .1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12.5)),
              ]),
            ),
          );
        },
      );
}

/// Poster with its title and year underneath (search results need the names visible).
class _TitledPoster extends StatelessWidget {
  const _TitledPoster({required this.media, required this.heroTag});
  final Media media;
  final String heroTag;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: PosterCard(media: media, heroTag: heroTag)),
        const SizedBox(height: 7),
        Text(media.title,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 1),
        Row(children: [
          Text(media.year ?? '—', style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
          const Spacer(),
          if (media.rating > 0) ...[
            const Icon(Icons.star_rounded, size: 11, color: VyseColors.star),
            const SizedBox(width: 2),
            Text(media.rating.toStringAsFixed(1), style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
          ],
        ]),
      ]);
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, required this.onPick});
  final Person person;
  final ValueChanged<String> onPick;

  String get _tag => 'search/person/${person.id}';

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: () => openPerson(context, id: person.id, name: person.name, profilePath: person.profilePath, heroTag: _tag),
        tooltip: person.knownFor.isEmpty ? null : 'Known for ${person.knownFor.take(3).join(', ')}',
        builder: (context, hovered, pressed) => Column(children: [
          AnimatedScale(
            scale: pressed ? .95 : (hovered ? 1.05 : 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VyseColors.surfaceHi,
                border: Border.all(color: hovered ? Colors.white : VyseColors.ink.withValues(alpha: .06), width: hovered ? 2 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: person.photo == null
                  ? Icon(Icons.person_rounded, color: VyseColors.textFaint, size: 36)
                  : Hero(
                      tag: _tag,
                      child: CachedNetworkImage(imageUrl: person.photo!, fit: BoxFit.cover, placeholder: (_, _) => const SizedBox()),
                    ),
            ),
          ),
          const SizedBox(height: 9),
          Text(person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : const Color(0xFFDADCE6))),
          const SizedBox(height: 2),
          Text(
            person.knownFor.isNotEmpty ? person.knownFor.first : person.department,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: VyseColors.textFaint),
          ),
        ]),
      );
}

class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton({required this.posterW});
  final double posterW;

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final phone = Layout.isPhone(context);
    return Padding(
      padding: EdgeInsets.only(left: inset, right: phone ? 16 : 40),
      child: Shimmer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(width: double.infinity, height: phone ? 210 : 260, radius: 16),
          const SizedBox(height: 36),
          const SkeletonBox(width: 90, height: 14, radius: 4),
          const SizedBox(height: 14),
          SizedBox(
            height: posterW * 1.5,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 8,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, _) => SkeletonBox(width: posterW, height: posterW * 1.5, radius: 7),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) => FadeSlideIn(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
          child: Center(
            child: Column(children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.ink.withValues(alpha: .05)),
                child: Icon(icon, size: 28, color: VyseColors.textDim),
              ),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, textAlign: TextAlign.center, style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
              if (action != null) ...[
                const SizedBox(height: 16),
                TextButton(onPressed: action!.$2, child: Text(action!.$1)),
              ],
            ]),
          ),
        ),
      );
}
