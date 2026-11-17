import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/anilist.dart';
import '../data/app_settings.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import 'details_page.dart' show openAnime, animeColor, airsIn;

/// The Anime tab: AniList's catalogue with search and every filter AniList's own browse page has.
class AnimePage extends StatefulWidget {
  const AnimePage({super.key, this.title = 'Anime', this.initial = const AnimeQuery()});
  final String title;
  final AnimeQuery initial;

  @override
  State<AnimePage> createState() => _AnimePageState();
}

class _AnimePageState extends State<AnimePage> {
  late var _q = widget.initial;
  final _items = <Anime>[];
  final _ids = <int>{};
  var _page = 0;
  var _hasMore = true;
  var _total = 0;
  var _loading = false;
  var _reloading = false; // new filters on their way while the old results stay up
  Object? _error;
  var _generation = 0; // each new result set; pages from an older one are dropped
  Timer? _debounce;
  var _searching = false; // the search box is open
  final _changed = ValueNotifier<int>(0); // the filter drawer follows the page through this
  final _scroll = ScrollController();
  final _filterScroll = ScrollController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 1000) _more();
    });
    // AniList names streaming services; its filter takes their ids
    AniList.streamingSites().then((sites) {
      for (final s in sites) {
        AnimeQuery.streamingIds[s.name] = s.ids;
      }
    }, onError: (Object _) {});
    AniList.tags().then((tags) => _adultTags.addAll([for (final t in tags) if (t.adult) t.name]), onError: (Object _) {});
    AppSettings.animeAdult.addListener(_adultChanged);
    _load();
  }

  /// Adult tags, so they can come off the query when the 18+ switch goes off.
  static final _adultTags = <String>{};

  /// What goes to AniList: never anything adult while the switch is off.
  AnimeQuery get _sent => AppSettings.animeAdult.value ? _q : _q.withoutAdult(_adultTags);

  // switched off (here or on another device): take adult titles and their genre and tags out
  void _adultChanged() {
    if (!AppSettings.animeAdult.value) _apply(_q.withoutAdult(_adultTags));
  }

  @override
  void dispose() {
    AppSettings.animeAdult.removeListener(_adultChanged);
    _debounce?.cancel();
    _changed.dispose();
    _scroll.dispose();
    _filterScroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _notify() {
    if (mounted) setState(() {});
    _changed.value++;
  }

  Future<void> _load() async {
    final gen = ++_generation;
    _loading = true;
    _reloading = _items.isNotEmpty;
    _error = null;
    _notify();
    try {
      final r = await AniList.browse(_sent);
      if (!mounted || gen != _generation) return;
      _items
        ..clear()
        ..addAll(r.items);
      _ids
        ..clear()
        ..addAll(r.items.map((a) => a.id));
      _page = 1;
      _hasMore = r.hasMore;
      _total = r.total;
    } catch (e) {
      if (!mounted || gen != _generation) return;
      _error = e;
    }
    _loading = _reloading = false;
    _notify();
  }

  Future<void> _more() async {
    if (_loading || !_hasMore || _error != null || _items.isEmpty) return;
    final gen = _generation;
    _loading = true;
    _notify();
    try {
      final r = await AniList.browse(_sent, page: _page + 1);
      if (!mounted || gen != _generation) return;
      for (final a in r.items) {
        if (_ids.add(a.id)) _items.add(a);
      }
      _page++;
      _hasMore = r.hasMore;
    } catch (e) {
      if (!mounted || gen != _generation) return;
      _error = e;
    }
    _loading = false;
    _notify();
  }

  void _retry() {
    if (_items.isEmpty) {
      _load();
    } else {
      _error = null;
      _more();
    }
  }

  void _apply(AnimeQuery q, {bool debounce = false}) {
    _q = q;
    _notify();
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 450), _load);
    } else {
      _load();
    }
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    }
  }

  void _toggleSearch() {
    if (_searching) {
      _closeSearch();
    } else {
      setState(() => _searching = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    }
  }

  void _closeSearch() {
    final had = _search.text.isNotEmpty;
    _search.clear();
    setState(() => _searching = false);
    if (had) _apply(_q.copyWith(search: ''));
  }

  Widget _showButton(BuildContext context, VoidCallback close, {double radius = 23}) => ValueListenableBuilder<int>(
        valueListenable: _changed,
        builder: (context, _, _) => Pressable(
          onTap: close,
          builder: (context, hovered, pressed) => AnimatedScale(
            scale: pressed ? .97 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: hovered ? VyseColors.strong : VyseColors.pick(0xFFF1F1F5, 0xFF1C1E28), borderRadius: BorderRadius.circular(radius)),
              child: _loading && (_reloading || _items.isEmpty)
                  ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.onStrong))
                  : Text('Mostra ${_countLabel(_total)}', style: TextStyle(color: VyseColors.onStrong, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ),
        ),
      );

  /// Desktop: a panel that slides in from the right, the results staying in view beside it.
  void _openFilterDrawer() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Filtri',
      barrierColor: Colors.black.withValues(alpha: .45),
      transitionDuration: const Duration(milliseconds: 340),
      transitionBuilder: (_, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
      pageBuilder: (panel, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: VyseColors.surface,
          child: Container(
            width: 420,
            decoration: BoxDecoration(border: Border(left: BorderSide(color: VyseColors.stroke))),
            child: Column(children: [
              Padding(
                padding: EdgeInsets.fromLTRB(24, Layout.topChrome(context) + 8, 12, 4),
                child: ValueListenableBuilder<int>(
                  valueListenable: _changed,
                  builder: (context, _, _) => Row(children: [
                    Icon(Icons.tune_rounded, size: 20, color: VyseColors.accent),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Filtri', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                    if (_q.activeFilters > 0) TextButton(onPressed: () => _apply(_q.cleared()), child: const Text('Cancella tutto')),
                    IconButton(onPressed: () => Navigator.pop(panel), icon: Icon(Icons.close_rounded, color: VyseColors.textDim)),
                  ]),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _filterScroll,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _changed,
                    builder: (context, _, _) => _AnimeFilters(query: _q, onChanged: _apply),
                  ),
                ),
              ),
              Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 20), child: _showButton(context, () => Navigator.pop(panel))),
            ]),
          ),
        ),
      ),
    );
  }

  void _openFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (sheet) => DraggableScrollableSheet(
        initialChildSize: .86,
        minChildSize: .5,
        maxChildSize: .95,
        builder: (context, sc) => Container(
          decoration: BoxDecoration(
            color: VyseColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(top: BorderSide(color: VyseColors.stroke)),
          ),
          child: Column(children: [
            Expanded(
              child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(18, 10, 18, 18), children: [
                Center(
                  child: Container(width: 38, height: 4, decoration: BoxDecoration(color: VyseColors.strokeHi, borderRadius: BorderRadius.circular(2))),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _changed,
                  builder: (context, _, _) => _AnimeFilters(query: _q, onChanged: _apply),
                ),
              ]),
            ),
            SafeArea(
              top: false,
              child: Padding(padding: const EdgeInsets.fromLTRB(18, 8, 18, 14), child: _showButton(context, () => Navigator.pop(sheet), radius: 12)),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final ff = Layout.of(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = phone ? 16.0 : 40.0;
    final top = Layout.topChrome(context) + (phone ? 12 : 26);
    final maxExtent = switch (ff) {
      FormFactor.phone => 128.0,
      FormFactor.tablet => 160.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .11).clamp(160.0, 210.0),
    };

    return ColoredBox(
      color: VyseColors.bg,
      child: PageScrollbar(
        controller: _scroll,
        child: CustomScrollView(controller: _scroll, slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, top, right, 0),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (Navigator.of(context).canPop()) ...[
                        Transform.translate(offset: const Offset(-8, 0), child: _BackLink(onTap: () => Navigator.of(context).maybePop())),
                        const SizedBox(height: 10),
                      ],
                      Text(widget.title, style: TextStyle(fontSize: phone ? 28 : 32, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.05)),
                      const SizedBox(height: 6),
                      Text(
                        _total > 0 ? 'Da AniList  ·  ${_countLabel(_total)}' : 'Da AniList',
                        style: TextStyle(color: VyseColors.textDim, fontSize: 13),
                      ),
                    ]),
                  ),
                  _RoundButton(
                    icon: _searching ? Icons.close_rounded : Icons.search_rounded,
                    tooltip: _searching ? 'Chiudi la ricerca' : 'Cerca anime',
                    active: _searching,
                    onTap: _toggleSearch,
                  ),
                ]),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: !_searching
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _SearchField(
                            controller: _search,
                            focus: _searchFocus,
                            onChanged: (v) => _apply(_q.copyWith(search: v), debounce: true),
                            onClose: _closeSearch,
                          ),
                        ),
                ),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(
                    child: _SortBar(
                      sort: _q.sort,
                      searching: _q.search.trim().isNotEmpty,
                      onChanged: (s) => _apply(_q.copyWith(sort: s)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _FiltersButton(count: _q.activeFilters, onTap: ff == FormFactor.desktop ? _openFilterDrawer : _openFilterSheet),
                ]),
                _ActiveFilters(query: _q, onChanged: _apply),
                const SizedBox(height: 16),
                AnimatedOpacity(
                  opacity: _reloading ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: ClipRRect(
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                    child: LinearProgressIndicator(minHeight: 2, color: VyseColors.accent, backgroundColor: VyseColors.pick(0x14FFFFFF, 0x14000000)),
                  ),
                ),
                const SizedBox(height: 10),
              ]),
            ),
          ),
          SliverPadding(padding: EdgeInsets.fromLTRB(side, 0, right, 0), sliver: _grid(maxExtent)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, 24, right, phone ? 110 + MediaQuery.paddingOf(context).bottom : 48),
              child: _footer(),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _grid(double maxExtent) {
    final delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxExtent,
      childAspectRatio: 2 / 3,
      mainAxisSpacing: 14,
      crossAxisSpacing: 12,
    );
    if (_items.isEmpty && _loading) {
      return SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (_, i) => FadeSlideIn(
            delay: Duration(milliseconds: 20 * (i % 12)),
            offset: 6,
            child: const Shimmer(child: SkeletonBox(width: double.infinity, height: double.infinity, radius: 7)),
          ),
          childCount: 18,
        ),
      );
    }
    if (_items.isEmpty) {
      return SliverToBoxAdapter(
        child: _error != null
            ? _Message(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile raggiungere AniList",
                body: 'Controlla la connessione e riprova.',
                action: 'Riprova',
                onAction: _retry,
              )
            : _Message(
                icon: Icons.travel_explore_rounded,
                title: 'Nessun risultato',
                body: _q.search.trim().isNotEmpty ? 'Prova un altro nome, o meno filtri.' : 'Prova a togliere un filtro o ad allargare un intervallo.',
                action: 'Azzera i filtri',
                onAction: () => _apply(_q.cleared()),
              ),
      );
    }
    return SliverAnimatedOpacity(
      opacity: _reloading ? .35 : 1,
      duration: const Duration(milliseconds: 220),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final a = _items[i];
            return FadeSlideIn(
              key: ValueKey('$_generation/${a.id}'),
              delay: Duration(milliseconds: 22 * (i % 20)),
              offset: 12,
              child: AnimeCard(anime: a, heroTag: 'anime/${a.id}'),
            );
          },
          childCount: _items.length,
        ),
      ),
    );
  }

  Widget _footer() {
    if (_items.isEmpty) return const SizedBox.shrink();
    if (_error != null) return Center(child: TextButton(onPressed: _retry, child: const Text("Impossibile caricarne altri · Riprova")));
    if (_loading && !_reloading) {
      return Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)));
    }
    if (!_hasMore) return Center(child: Text("Non c'è altro", style: TextStyle(color: VyseColors.textFaint, fontSize: 12)));
    return const SizedBox(height: 22);
  }
}

/// AniList stops counting at 5,000.
String _countLabel(int n) => n >= 5000 ? 'Oltre 5.000 titoli' : '${fmtThousands(n)} title${n == 1 ? '' : 's'}';

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Pressable(
        tooltip: tooltip,
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .92 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? VyseColors.accent.withValues(alpha: .22) : VyseColors.ink.withValues(alpha: hovered ? .14 : .07),
              border: Border.all(color: active ? VyseColors.accent.withValues(alpha: .5) : VyseColors.stroke),
            ),
            child: Icon(icon, size: 21, color: active ? VyseColors.accent : VyseColors.text),
          ),
        ),
      );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focus, required this.onChanged, required this.onClose});
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
        child: TextField(
          controller: controller,
          focusNode: focus,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'Cerca anime per nome (inglese, romaji o giapponese)',
            hintStyle: TextStyle(color: VyseColors.textFaint),
            prefixIcon: Icon(Icons.search_rounded, color: VyseColors.textDim),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, v, _) => v.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Cancella',
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                        focus.requestFocus();
                      },
                      icon: Icon(Icons.close_rounded, size: 18, color: VyseColors.textDim),
                    ),
            ),
            filled: true,
            fillColor: VyseColors.ink.withValues(alpha: .06),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: VyseColors.stroke)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: VyseColors.stroke)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .6))),
          ),
        ),
      );
}

/// An anime's cover card: title, format, year and score on hover; the next episode or the
/// format in the corner.
class AnimeCard extends StatelessWidget {
  const AnimeCard({super.key, required this.anime, this.heroTag});
  final Anime anime;
  final String? heroTag; // the cover flies to the details page (only where it's unique on screen)

  @override
  Widget build(BuildContext context) {
    final a = anime;
    final tag = heroTag;
    final tint = animeColor(a) ?? VyseColors.surface;
    final cover = Layout.isPhone(context) ? a.coverSmall : a.cover;
    final badge = a.nextEpisode != null && a.nextEpisodeAt != null
        ? 'EP ${a.nextEpisode} · ${airsIn(a.nextEpisodeAt!)}'
        : (a.format != 'TV' && a.format.isNotEmpty ? a.formatLabel.toUpperCase() : null);
    return OutlineCard(
      label: a.title,
      onTap: () => openAnime(context, a, heroTag: tag),
      builder: (hovered) => Stack(fit: StackFit.expand, children: [
        _MaybeHero(
          tag: tag,
          child: cover == null
              ? Container(
                  color: tint.withValues(alpha: .35),
                  padding: const EdgeInsets.all(12),
                  alignment: Alignment.center,
                  child: Text(a.title, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: VyseColors.textDim)),
                )
              : CachedNetworkImage(
                  imageUrl: cover,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 300),
                  placeholder: (_, _) => ColoredBox(color: tint.withValues(alpha: .35)),
                  errorWidget: (_, _, _) => ColoredBox(color: tint.withValues(alpha: .35)),
                ),
        ),
        AnimatedOpacity(
          opacity: hovered ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.center, colors: [Color(0xF0000000), Color(0x00000000)]),
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 9,
          child: AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: AnimatedSlide(
              offset: Offset(0, hovered ? 0 : .3),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2)),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(
                    child: Text(
                      [a.formatLabel, if (a.year != null) '${a.year}', if (a.episodes != null && !a.isMovie) '${a.episodes} ep'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                    ),
                  ),
                  if (a.score != null) ...[
                    const Icon(Icons.star_rounded, size: 12, color: VyseColors.star),
                    const SizedBox(width: 2),
                    Text('${a.score}%', style: const TextStyle(fontSize: 10.5, color: VyseColors.star)),
                  ],
                ]),
              ]),
            ),
          ),
        ),
        if (badge != null)
          Positioned(
            top: 7,
            left: 7,
            right: 7,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: .65), borderRadius: BorderRadius.circular(4)),
                child: Text(badge, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: .4, color: Colors.white)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _MaybeHero extends StatelessWidget {
  const _MaybeHero({required this.tag, required this.child});
  final String? tag;
  final Widget child;

  @override
  Widget build(BuildContext context) => tag == null ? child : Hero(tag: tag!, child: child);
}

class _BackLink extends StatelessWidget {
  const _BackLink({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: hovered ? VyseColors.ink.withValues(alpha: .1) : Colors.transparent,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chevron_left_rounded, size: 20, color: hovered ? VyseColors.text : VyseColors.textDim),
            Text('Indietro', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim)),
          ]),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body, required this.action, required this.onAction});
  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Column(children: [
            Icon(icon, size: 40, color: VyseColors.textFaint),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: VyseColors.textDim)),
            const SizedBox(height: 14),
            TextButton(onPressed: onAction, child: Text(action)),
          ]),
        ),
      );
}

// ───────────────────────── Sort + active filters ─────────────────────────

class _SortBar extends StatelessWidget {
  const _SortBar({required this.sort, required this.searching, required this.onChanged});
  final AnimeSort sort;
  final bool searching; // "Trending" orders by best match while there's a search
  final ValueChanged<AnimeSort> onChanged;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: VyseColors.ink.withValues(alpha: .05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: VyseColors.ink.withValues(alpha: .06)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final s in AnimeSort.values)
                Pressable(
                  onTap: () => onChanged(s),
                  builder: (context, hovered, pressed) {
                    final on = s == sort;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: on ? VyseColors.pick(0xFF242842, 0xFFFFFFFF) : VyseColors.ink.withValues(alpha: hovered ? .05 : 0),
                        boxShadow: on ? [BoxShadow(color: Colors.black.withValues(alpha: VyseColors.light ? .12 : .35), blurRadius: 10, offset: const Offset(0, 3))] : null,
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          width: on ? 6 : 0,
                          height: 6,
                          margin: EdgeInsets.only(right: on ? 7 : 0),
                          decoration: BoxDecoration(color: VyseColors.accent, shape: BoxShape.circle),
                        ),
                        Text(
                          searching && s == AnimeSort.trending ? 'Più pertinenti' : s.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                            color: on || hovered ? VyseColors.text : VyseColors.textDim,
                          ),
                        ),
                      ]),
                    );
                  },
                ),
            ]),
          ),
        ),
      );
}

class _FiltersButton extends StatelessWidget {
  const _FiltersButton({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .94 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: VyseColors.ink.withValues(alpha: hovered ? .14 : .07),
              border: Border.all(color: VyseColors.stroke),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.tune_rounded, size: 16),
              const SizedBox(width: 6),
              const Text('Filtri', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              if (count > 0)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(10)),
                  child: Text('$count', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black)),
                ),
            ]),
          ),
        ),
      );
}

String _range(int? lo, int? hi, String unit) =>
    lo != null && hi != null ? '$lo–$hi$unit' : (lo != null ? '$lo+$unit' : 'fino a $hi$unit');

/// A removable pill for every active filter, so what narrows the grid is always in view.
class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.query, required this.onChanged});
  final AnimeQuery query;
  final void Function(AnimeQuery q, {bool debounce}) onChanged;

  @override
  Widget build(BuildContext context) {
    final q = query;
    Set<String> minus(Set<String> s, String x) => {...s}..remove(x);
    final pills = <(String, AnimeQuery)>[
      for (final g in q.genres) (g, q.copyWith(genres: minus(q.genres, g))),
      for (final g in q.genresNot) ('Non $g', q.copyWith(genresNot: minus(q.genresNot, g))),
      for (final t in q.tags) (t, q.copyWith(tags: minus(q.tags, t))),
      for (final t in q.tagsNot) ('Non $t', q.copyWith(tagsNot: minus(q.tagsNot, t))),
      for (final f in q.formats) (animeFormats[f] ?? f, q.copyWith(formats: minus(q.formats, f))),
      for (final s in q.statuses) (animeStatuses[s] ?? s, q.copyWith(statuses: minus(q.statuses, s))),
      if (q.season != null) (animeSeasons[q.season] ?? q.season!, q.copyWith(season: null)),
      if (q.yearFrom != null || q.yearTo != null)
        (
          q.yearFrom == q.yearTo ? '${q.yearFrom}' : (q.yearFrom != null && q.yearTo != null ? '${q.yearFrom}–${q.yearTo}' : (q.yearFrom != null ? '${q.yearFrom} on' : 'Fino al ${q.yearTo}')),
          q.copyWith(yearFrom: null, yearTo: null),
        ),
      for (final s in q.sources) (animeSources[s] ?? s, q.copyWith(sources: minus(q.sources, s))),
      if (q.country != null) (animeCountries[q.country] ?? q.country!, q.copyWith(country: null)),
      for (final s in q.streaming) ('Su $s', q.copyWith(streaming: minus(q.streaming, s))),
      if (q.episodesMin != null || q.episodesMax != null) (_range(q.episodesMin, q.episodesMax, ' episodes'), q.copyWith(episodesMin: null, episodesMax: null)),
      if (q.durationMin != null || q.durationMax != null) (_range(q.durationMin, q.durationMax, ' min'), q.copyWith(durationMin: null, durationMax: null)),
      if (q.scoreMin != null || q.scoreMax != null) ('Score ${_range(q.scoreMin, q.scoreMax, '%')}', q.copyWith(scoreMin: null, scoreMax: null)),
      if (q.doujin) ('Doujin', q.copyWith(doujin: false)),
      if (q.tagRank != null && (q.tags.isNotEmpty || q.tagsNot.isNotEmpty)) ('Tag ${q.tagRank}%+', q.copyWith(tagRank: null)),
      if (q.adult == AdultFilter.only) ('Solo per adulti', q.copyWith(adult: AdultFilter.include)),
      if (q.adult == AdultFilter.include) ('Incl. adulti', q.copyWith(adult: AdultFilter.hide)),
    ];
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: pills.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final (label, next) in pills)
                  Pressable(
                    key: ValueKey(label),
                    onTap: () => onChanged(next),
                    builder: (context, hovered, _) => AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: VyseColors.accent.withValues(alpha: hovered ? .24 : .14),
                        border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 4),
                        Icon(Icons.close_rounded, size: 14, color: VyseColors.textDim),
                      ]),
                    ),
                  ),
                Pressable(
                  onTap: () => onChanged(q.cleared()),
                  builder: (context, hovered, _) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Text('Cancella tutto',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: hovered ? VyseColors.accent : VyseColors.textDim)),
                  ),
                ),
              ]),
            ),
    );
  }
}

// ───────────────────────── Filter panel ─────────────────────────

/// Every AniList filter. Genres and tags take three taps: include, exclude, off.
class _AnimeFilters extends StatefulWidget {
  const _AnimeFilters({required this.query, required this.onChanged});
  final AnimeQuery query;
  final void Function(AnimeQuery q, {bool debounce}) onChanged;

  @override
  State<_AnimeFilters> createState() => _AnimeFiltersState();
}

class _AnimeFiltersState extends State<_AnimeFilters> {
  final _genres = AniList.genres();
  final _tags = AniList.tags();
  final _sites = AniList.streamingSites();
  final _tagSearch = TextEditingController();

  @override
  void dispose() {
    _tagSearch.dispose();
    super.dispose();
  }

  AnimeQuery get q => widget.query;
  bool get _adult => AppSettings.animeAdult.value;

  /// Asks once that you're 18 or older, then lets adult titles in.
  Future<void> _allowAdult() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Anime per adulti (18+)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 380,
          child: Text(
            'Mostra gli hentai e gli altri titoli che AniList segna per adulti, comprese copertine esplicite. '
            "Attivalo solo se hai almeno 18 anni. Puoi disattivarlo di nuovo qui.",
            style: TextStyle(color: VyseColors.textDim, height: 1.5),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Ho almeno 18 anni", style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    AppSettings.animeAdult.set(true);
    _set(q.copyWith(adult: AdultFilter.include));
  }
  void _set(AnimeQuery next, {bool debounce = false}) => widget.onChanged(next, debounce: debounce);

  Set<String> _flip(Set<String> s, String x) => s.contains(x) ? ({...s}..remove(x)) : {...s, x};

  /// off → include → exclude → off
  void _cycle(String x, {required bool tag}) {
    final inc = tag ? q.tags : q.genres, exc = tag ? q.tagsNot : q.genresNot;
    final (Set<String> i, Set<String> e) = inc.contains(x)
        ? ({...inc}..remove(x), {...exc, x})
        : (exc.contains(x) ? (inc, {...exc}..remove(x)) : ({...inc, x}, exc));
    _set(tag ? q.copyWith(tags: i, tagsNot: e) : q.copyWith(genres: i, genresNot: e));
  }

  int _state(String x, {required bool tag}) =>
      (tag ? q.tags : q.genres).contains(x) ? 1 : ((tag ? q.tagsNot : q.genresNot).contains(x) ? 2 : 0);

  @override
  Widget build(BuildContext context) {
    final year = DateTime.now().year + 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Label('Genres', hint: 'Tocca una volta per includere, due per escludere'),
      _Loaded<List<String>>(
        future: _genres,
        builder: (genres) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (final g in genres)
            if (_adult || !adultGenres.contains(g)) _TriChip(label: g, state: _state(g, tag: false), onTap: () => _cycle(g, tag: false)),
        ]),
      ),
      const _Label('Tags'),
      _Loaded<List<AnimeTag>>(
        future: _tags,
        builder: (tags) => ValueListenableBuilder<TextEditingValue>(
          valueListenable: _tagSearch,
          builder: (context, v, _) {
            final picked = [...q.tags, ...q.tagsNot];
            final find = v.text.trim().toLowerCase();
            final matches = find.isEmpty
                ? const <AnimeTag>[]
                : tags.where((t) => !picked.contains(t.name) && (_adult || !t.adult) && (t.name.toLowerCase().contains(find) || t.category.toLowerCase().contains(find))).take(30).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: _tagSearch,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Cerca un tag: isekai, viaggi nel tempo, iyashikei…',
                  hintStyle: TextStyle(color: VyseColors.textFaint, fontSize: 13),
                  prefixIcon: Icon(Icons.sell_outlined, size: 17, color: VyseColors.textDim),
                  filled: true,
                  fillColor: VyseColors.ink.withValues(alpha: .05),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              if (picked.isNotEmpty || matches.isNotEmpty) const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in picked) _TriChip(label: t, state: _state(t, tag: true), onTap: () => _cycle(t, tag: true)),
                for (final t in matches) _TriChip(label: t.name, state: 0, tooltip: t.description, onTap: () => _cycle(t.name, tag: true)),
              ]),
              if (find.isNotEmpty && matches.isEmpty)
                Padding(padding: EdgeInsets.only(top: 8), child: Text('Nessun tag con questo nome', style: TextStyle(fontSize: 12, color: VyseColors.textFaint))),
              if (picked.isNotEmpty)
                _Percent(
                  label: 'Rilevanza minima del tag',
                  value: q.tagRank ?? 0,
                  onChanged: (v) => _set(q.copyWith(tagRank: v == 0 ? null : v), debounce: true),
                ),
            ]);
          },
        ),
      ),
      const _Label('Format'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in animeFormats.entries)
          _Chip(label: value, selected: q.formats.contains(key), onTap: () => _set(q.copyWith(formats: _flip(q.formats, key)))),
      ]),
      const _Label('Stato di trasmissione'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in animeStatuses.entries)
          _Chip(label: value, selected: q.statuses.contains(key), onTap: () => _set(q.copyWith(statuses: _flip(q.statuses, key)))),
      ]),
      const _Label('Stagione'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in animeSeasons.entries)
          _Chip(label: value, selected: q.season == key, onTap: () => _set(q.copyWith(season: q.season == key ? null : key))),
      ]),
      const _Label('Anno'),
      Row(children: [
        Expanded(
          child: _YearPick(
            label: q.yearFrom == null ? 'Da qualsiasi anno' : 'Dal ${q.yearFrom}',
            active: q.yearFrom != null,
            first: year,
            onPicked: (y) => _set(q.copyWith(yearFrom: y, yearTo: y != null && q.yearTo != null && q.yearTo! < y ? y : q.yearTo)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _YearPick(
            label: q.yearTo == null ? 'A qualsiasi anno' : 'Al ${q.yearTo}',
            active: q.yearTo != null,
            first: year,
            onPicked: (y) => _set(q.copyWith(yearTo: y, yearFrom: y != null && q.yearFrom != null && q.yearFrom! > y ? y : q.yearFrom)),
          ),
        ),
      ]),
      const _Label('In streaming su'),
      _Loaded<List<StreamingSite>>(
        future: _sites,
        builder: (sites) => Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in sites) _Chip(label: s.name, selected: q.streaming.contains(s.name), onTap: () => _set(q.copyWith(streaming: _flip(q.streaming, s.name)))),
        ]),
      ),
      const _Label('Paese d\'origine'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in animeCountries.entries)
          _Chip(label: value, selected: q.country == key, onTap: () => _set(q.copyWith(country: q.country == key ? null : key))),
      ]),
      const _Label('Opera originale'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in animeSources.entries)
          _Chip(label: value, selected: q.sources.contains(key), onTap: () => _set(q.copyWith(sources: _flip(q.sources, key)))),
      ]),
      _Range(
        label: 'Episodi',
        max: AnimeQuery.maxEpisodes,
        lo: q.episodesMin,
        hi: q.episodesMax,
        unit: '',
        onChanged: (lo, hi) => _set(q.copyWith(episodesMin: lo, episodesMax: hi), debounce: true),
      ),
      _Range(
        label: 'Durata dell\'episodio',
        max: AnimeQuery.maxDuration,
        lo: q.durationMin,
        hi: q.durationMax,
        unit: ' min',
        onChanged: (lo, hi) => _set(q.copyWith(durationMin: lo, durationMax: hi), debounce: true),
      ),
      _Range(
        label: 'Voto medio',
        max: 100,
        lo: q.scoreMin,
        hi: q.scoreMax,
        unit: '%',
        onChanged: (lo, hi) => _set(q.copyWith(scoreMin: lo, scoreMax: hi), debounce: true),
      ),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Solo doujin', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            SizedBox(height: 2),
            Text('Opere autoprodotte, senza licenza', style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
          ]),
        ),
        Switch(value: q.doujin, activeThumbColor: VyseColors.accent, onChanged: (v) => _set(q.copyWith(doujin: v))),
      ]),
      const _Label('Contenuti per adulti (18+)'),
      if (!_adult)
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Mostra anime per adulti', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text('Hentai e altri titoli che AniList segna 18+', style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
            ]),
          ),
          Switch(value: false, activeThumbColor: VyseColors.accent, onChanged: (_) => _allowAdult()),
        ])
      else ...[
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (f, label) in const [(AdultFilter.hide, 'Nascondi'), (AdultFilter.include, 'Includi'), (AdultFilter.only, 'Solo adulti')])
            _Chip(label: label, selected: q.adult == f, onTap: () => _set(q.copyWith(adult: f))),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: VyseColors.textDim),
            onPressed: () => AppSettings.animeAdult.set(false),
            child: const Text('Disattiva i contenuti per adulti', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    ]);
  }
}

/// Waits for one of AniList's lists (genres, tags, services), with a retry if it fails.
class _Loaded<T> extends StatelessWidget {
  const _Loaded({required this.future, required this.builder});
  final Future<T> future;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, s) {
          if (s.hasData) return builder(s.data as T);
          if (s.hasError) return Text("Impossibile caricarli da AniList", style: TextStyle(fontSize: 12, color: VyseColors.textFaint));
          return const Shimmer(child: SkeletonBox(width: double.infinity, height: 64, radius: 8));
        },
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.hint});
  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Row(children: [
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Flexible(child: Text(hint!, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: VyseColors.textFaint))),
          ],
        ]),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _TriChip(label: label, state: selected ? 1 : 0, onTap: onTap);
}

/// 0 off, 1 included (white), 2 excluded (red, struck through).
class _TriChip extends StatelessWidget {
  const _TriChip({required this.label, required this.state, required this.onTap, this.tooltip});
  final String label;
  final int state;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Pressable(
        tooltip: tooltip == null || tooltip!.isEmpty ? null : tooltip,
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .93 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: switch (state) {
                1 => Colors.white,
                2 => const Color(0x33FF4D4F),
                _ => VyseColors.ink.withValues(alpha: hovered ? .12 : .05),
              },
              border: Border.all(
                color: switch (state) {
                  1 => Colors.white,
                  2 => const Color(0x99FF4D4F),
                  _ => VyseColors.ink.withValues(alpha: .06),
                },
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (state == 2) ...[const Icon(Icons.remove_circle_outline_rounded, size: 13, color: Color(0xFFFF8A8C)), const SizedBox(width: 4)],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  decoration: state == 2 ? TextDecoration.lineThrough : null,
                  decorationColor: const Color(0xFFFF8A8C),
                  color: switch (state) {
                    1 => Colors.black,
                    2 => const Color(0xFFFF8A8C),
                    _ => hovered ? VyseColors.text : VyseColors.textDim,
                  },
                ),
              ),
            ]),
          ),
        ),
      );
}

class _YearPick extends StatelessWidget {
  const _YearPick({required this.label, required this.active, required this.first, required this.onPicked});
  final String label;
  final bool active;
  final int first; // the newest year offered
  final ValueChanged<int?> onPicked;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
        tooltip: '',
        color: VyseColors.surfaceHi,
        constraints: const BoxConstraints(maxHeight: 320, minWidth: 140),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: VyseColors.stroke)),
        onSelected: (y) => onPicked(y == 0 ? null : y),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 0, height: 34, child: Text('Qualsiasi anno', style: TextStyle(fontSize: 13))),
          for (var y = first; y >= 1940; y--) PopupMenuItem(value: y, height: 34, child: Text('$y', style: const TextStyle(fontSize: 13))),
        ],
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: VyseColors.ink.withValues(alpha: .05),
            border: Border.all(color: active ? VyseColors.accent.withValues(alpha: .5) : VyseColors.ink.withValues(alpha: .06)),
          ),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 12.5, color: active ? VyseColors.text : VyseColors.textDim))),
            Icon(Icons.expand_more_rounded, size: 16, color: VyseColors.textFaint),
          ]),
        ),
      );
}

/// A percentage slider; 0 means no minimum.
class _Percent extends StatefulWidget {
  const _Percent({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_Percent> createState() => _PercentState();
}

class _PercentState extends State<_Percent> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final v = _dragging ?? widget.value.toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(children: [
          Text(widget.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
          const Spacer(),
          Text(v == 0 ? 'Qualsiasi' : '${v.round()}%+', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: v == 0 ? VyseColors.textFaint : VyseColors.text)),
        ]),
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: VyseColors.accent,
          inactiveTrackColor: VyseColors.ink.withValues(alpha: .1),
          thumbColor: Colors.white,
          overlayColor: VyseColors.accent.withValues(alpha: .15),
          trackHeight: 3,
        ),
        child: Slider(
          value: v,
          max: 100,
          divisions: 20,
          onChanged: (x) => setState(() => _dragging = x),
          onChangeEnd: (x) {
            setState(() => _dragging = null);
            widget.onChanged(x.round());
          },
        ),
      ),
    ]);
  }
}

/// A two-ended slider; at its ends a side means "no limit".
class _Range extends StatefulWidget {
  const _Range({required this.label, required this.max, required this.lo, required this.hi, required this.unit, required this.onChanged});
  final String label;
  final int max;
  final int? lo;
  final int? hi;
  final String unit;
  final void Function(int? lo, int? hi) onChanged;

  @override
  State<_Range> createState() => _RangeState();
}

class _RangeState extends State<_Range> {
  RangeValues? _dragging;

  RangeValues get _values => _dragging ?? RangeValues((widget.lo ?? 0).toDouble(), (widget.hi ?? widget.max).toDouble());

  @override
  Widget build(BuildContext context) {
    final v = _values;
    final lo = v.start.round(), hi = v.end.round();
    final any = lo == 0 && hi == widget.max;
    final text = any ? 'Qualsiasi' : '$lo–${hi == widget.max ? '${widget.max}+' : '$hi'}${widget.unit}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 22),
        child: Row(children: [
          Text(widget.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
          const Spacer(),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: any ? VyseColors.textFaint : VyseColors.text)),
        ]),
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: VyseColors.accent,
          inactiveTrackColor: VyseColors.ink.withValues(alpha: .1),
          thumbColor: Colors.white,
          overlayColor: VyseColors.accent.withValues(alpha: .15),
          trackHeight: 3,
        ),
        child: RangeSlider(
          values: v,
          max: widget.max.toDouble(),
          divisions: widget.max,
          onChanged: (r) => setState(() => _dragging = r),
          onChangeEnd: (r) {
            setState(() => _dragging = null);
            final a = r.start.round(), b = r.end.round();
            widget.onChanged(a == 0 ? null : a, b == widget.max ? null : b);
          },
        ),
      ),
    ]);
  }
}
