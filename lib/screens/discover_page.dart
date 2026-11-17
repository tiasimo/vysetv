import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/discover.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';

/// Browse everything on TMDB: a filter column on the left, sort pills and an endless poster grid
/// on the right. On tablets and phones the filters live in a sheet.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({
    super.key,
    this.title = 'Scopri',
    this.subtitle = 'Film e serie TV',
    this.initial = const DiscoverQuery(),
    this.logo,
  });

  final String title;
  final String subtitle;
  final DiscoverQuery initial;

  /// Studio / network logo shown above the title.
  final String? logo;

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  late final _c = DiscoverController(widget.initial);
  final _scroll = ScrollController();
  final _filterScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 1000) _c.loadMore();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    _filterScroll.dispose();
    super.dispose();
  }

  void _apply(DiscoverQuery q, {bool debounce = false}) {
    _c.update(q, debounce: debounce);
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    }
  }

  /// Desktop: a panel that slides in from the right edge, results stay visible beside it.
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
            width: 400,
            decoration: BoxDecoration(border: Border(left: BorderSide(color: VyseColors.stroke))),
            child: ListenableBuilder(
              listenable: _c,
              builder: (context, _) => Column(children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(24, Layout.topChrome(context) + 8, 12, 4),
                  child: Row(children: [
                    Icon(Icons.tune_rounded, size: 20, color: VyseColors.accent),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Filtri', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                    if (_c.query.activeFilters > 0)
                      TextButton(onPressed: () => _apply(_c.query.cleared()), child: const Text('Cancella tutto')),
                    IconButton(
                      onPressed: () => Navigator.pop(panel),
                      icon: Icon(Icons.close_rounded, color: VyseColors.textDim),
                    ),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _filterScroll,
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: _FilterPanel(query: _c.query, onChanged: _apply),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Pressable(
                    onTap: () => Navigator.pop(panel),
                    builder: (context, hovered, pressed) => AnimatedScale(
                      scale: pressed ? .97 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: hovered ? VyseColors.strong : VyseColors.pick(0xFFF1F1F5, 0xFF1C1E28),
                          borderRadius: BorderRadius.circular(23),
                        ),
                        child: _c.initialLoading || _c.reloading
                            ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.onStrong))
                            : Text('Mostra ${fmtThousands(_c.total)} titoli',
                                style: TextStyle(color: VyseColors.onStrong, fontWeight: FontWeight.w700, fontSize: 14)),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
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
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) => Column(children: [
              Expanded(
                child: ListView(controller: sc, padding: const EdgeInsets.fromLTRB(18, 10, 18, 18), children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(color: VyseColors.strokeHi, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _FilterPanel(query: _c.query, onChanged: _apply),
                ]),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                  child: Pressable(
                    onTap: () => Navigator.pop(sheet),
                    builder: (context, hovered, pressed) => AnimatedScale(
                      scale: pressed ? .97 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: Container(
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                        child: _c.initialLoading || _c.reloading
                            ? const SizedBox.square(
                                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : Text('Mostra ${fmtThousands(_c.total)} titoli',
                                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 14)),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = Layout.of(context) == FormFactor.desktop;
    final top = Layout.topChrome(context) + (Layout.isPhone(context) ? 12 : 26);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        // Soft amber + violet haze in the corner so the page isn't a flat slab.
        const Positioned(top: -220, right: -160, child: _Haze()),
        ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            return _Results(
              controller: _c,
              scroll: _scroll,
              top: top,
              header: _Header(title: widget.title, subtitle: widget.subtitle, total: _c.total, logo: widget.logo),
              onApply: _apply,
              onOpenFilters: desktop ? _openFilterDrawer : _openFilterSheet,
            );
          },
        ),
      ]),
    );
  }
}

class _Haze extends StatelessWidget {
  const _Haze();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: 640,
          height: 640,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [Color(0x1FFF8A1A), Color(0x0F7A5CFF), VyseColors.pick(0x0007080F, 0x00F4F5FA)], stops: [0, .45, 1]),
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, required this.total, this.logo});
  final String title;
  final String subtitle;
  final int total;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    final phone = Layout.isPhone(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (canPop) ...[
        Transform.translate(offset: const Offset(-8, 0), child: _BackLink(onTap: () => Navigator.of(context).maybePop())),
        const SizedBox(height: 10),
      ],
      if (logo != null) ...[
        FadeSlideIn(offset: 10, child: StudioLogo(url: logo!, height: phone ? 46 : 56)),
        const SizedBox(height: 14),
      ],
      FadeSlideIn(
        offset: 10,
        child: Text(title,
            style: TextStyle(fontSize: phone ? 28 : 32, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.05)),
      ),
      const SizedBox(height: 6),
      FadeSlideIn(
        delay: const Duration(milliseconds: 60),
        offset: 8,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
          ),
          if (total > 0) ...[
            Text('  ·  ', style: TextStyle(color: VyseColors.textFaint, fontSize: 13)),
            // Count rolls to the new number instead of jumping.
            TweenAnimationBuilder<double>(
              tween: Tween(end: total.toDouble()),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => Text('${fmtThousands(v.round())} titoli',
                  style: TextStyle(color: VyseColors.textFaint, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ],
        ]),
      ),
    ]);
  }
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
            Text('Indietro',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim)),
          ]),
        ),
      );
}

// ───────────────────────── Results column ─────────────────────────

class _Results extends StatelessWidget {
  const _Results({
    required this.controller,
    required this.scroll,
    required this.top,
    required this.header,
    required this.onApply,
    required this.onOpenFilters,
  });

  final DiscoverController controller;
  final ScrollController scroll;
  final double top;
  final Widget? header;
  final void Function(DiscoverQuery q, {bool debounce}) onApply;
  final VoidCallback? onOpenFilters;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final q = c.query;
    final phone = Layout.isPhone(context);
    final ff = Layout.of(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = phone ? 16.0 : 40.0;

    final maxExtent = switch (ff) {
      FormFactor.phone => 128.0,
      FormFactor.tablet => 160.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .11).clamp(160.0, 210.0),
    };

    return PageScrollbar(
      controller: scroll,
      child: CustomScrollView(controller: scroll, slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, top, right, 0),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (header != null) ...[header!, const SizedBox(height: 20)],
              Row(children: [
                Expanded(child: _SortBar(sort: q.sort, onChanged: (s) => onApply(q.copyWith(sort: s)))),
                if (onOpenFilters != null) ...[
                  const SizedBox(width: 10),
                  _FiltersButton(count: q.activeFilters, onTap: onOpenFilters!),
                ],
              ]),
              _ActiveFilters(query: q, onChanged: onApply),
              const SizedBox(height: 16),
              // Thin progress line while a new result set is on its way.
              AnimatedOpacity(
                opacity: c.reloading ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: VyseColors.accent,
                    backgroundColor: VyseColors.pick(0x14FFFFFF, 0x14000000),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ]),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 0, right, 0),
          sliver: _grid(context, maxExtent),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 24, right, phone ? 110 + MediaQuery.paddingOf(context).bottom : 48),
            child: _footer(context),
          ),
        ),
      ]),
    );
  }

  Widget _grid(BuildContext context, double maxExtent) {
    final c = controller;
    final delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxExtent,
      childAspectRatio: 2 / 3,
      mainAxisSpacing: 14,
      crossAxisSpacing: 12,
    );

    if (c.initialLoading || (c.items.isEmpty && c.loading)) {
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

    if (c.items.isEmpty) {
      return SliverToBoxAdapter(
        child: c.error != null
            ? _Message(
                icon: Icons.wifi_off_rounded,
                title: "Impossibile raggiungere TMDB",
                body: 'Controlla la connessione e riprova.',
                action: 'Riprova',
                onAction: c.retry,
              )
            : _Message(
                icon: Icons.travel_explore_rounded,
                title: 'Nessun risultato con questi filtri',
                body: 'Prova ad allargare gli anni, abbassare il voto o togliere un genere.',
                action: 'Azzera i filtri',
                onAction: () => onApply(c.query.cleared()),
              ),
      );
    }

    return SliverAnimatedOpacity(
      opacity: c.reloading ? .35 : 1,
      duration: const Duration(milliseconds: 220),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final m = c.items[i];
            return FadeSlideIn(
              key: ValueKey('${c.generation}/${m.key}'),
              delay: Duration(milliseconds: 22 * (i % 20)),
              offset: 12,
              child: _DiscoverCard(media: m, showKind: c.query.type == MediaType.all),
            );
          },
          childCount: c.items.length,
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final c = controller;
    if (c.items.isEmpty) return const SizedBox.shrink();
    if (c.error != null) {
      return Center(child: TextButton(onPressed: c.retry, child: const Text("Impossibile caricarne altri · Riprova")));
    }
    if (c.loading && !c.reloading) {
      return Center(
        child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)),
      );
    }
    if (!c.hasMore) {
      return Center(
        child: Text("Non c'è altro", style: TextStyle(color: VyseColors.textFaint, fontSize: 12)),
      );
    }
    return const SizedBox(height: 22);
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body, required this.action, required this.onAction});
  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => FadeSlideIn(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 70),
          child: Column(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.ink.withValues(alpha: .05)),
              child: Icon(icon, size: 28, color: VyseColors.textDim),
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: VyseColors.textDim, fontSize: 13)),
            const SizedBox(height: 18),
            _Chip(label: action, selected: true, onTap: onAction),
          ]),
        ),
      );
}

class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({required this.media, required this.showKind});
  final Media media;
  final bool showKind;

  @override
  Widget build(BuildContext context) {
    final tag = 'discover/${media.key}';
    return OutlineCard(
      label: media.title,
      onTap: () => openDetails(context, media, heroTag: tag),
      builder: (hovered) => Stack(fit: StackFit.expand, children: [
        Hero(
          tag: tag,
          child: media.poster() == null
              ? Container(
                  color: VyseColors.surfaceHi,
                  padding: const EdgeInsets.all(12),
                  alignment: Alignment.center,
                  child: Text(media.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: VyseColors.textDim)),
                )
              : CachedNetworkImage(
                  imageUrl: media.poster()!,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 300),
                  placeholder: (_, _) => ColoredBox(color: VyseColors.surface),
                  errorWidget: (_, _, _) => ColoredBox(color: VyseColors.surface),
                ),
        ),
        AnimatedOpacity(
          opacity: hovered ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.center,
                colors: [Color(0xF0000000), Color(0x00000000)],
              ),
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
                Text(media.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2)),
                const SizedBox(height: 3),
                Row(children: [
                  Text(media.year ?? '—', style: TextStyle(fontSize: 10.5, color: VyseColors.textDim)),
                  const Spacer(),
                  const Icon(Icons.star_rounded, size: 12, color: VyseColors.star),
                  const SizedBox(width: 2),
                  Text(media.rating.toStringAsFixed(1), style: const TextStyle(fontSize: 10.5, color: VyseColors.star)),
                ]),
              ]),
            ),
          ),
        ),
        if (showKind && media.isTv)
          Positioned(
            top: 7,
            left: 7,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: .6), borderRadius: BorderRadius.circular(4)),
              child: const Text('SERIES', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: .4)),
            ),
          ),
      ]),
    );
  }
}

// ───────────────────────── Sort + active filters ─────────────────────────

class _SortBar extends StatelessWidget {
  const _SortBar({required this.sort, required this.onChanged});
  final SortBy sort;
  final ValueChanged<SortBy> onChanged;

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
              for (final s in SortBy.values)
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
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 220),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                            color: on || hovered ? VyseColors.text : VyseColors.textDim,
                          ),
                          child: Text(s.label),
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
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                child: count == 0
                    ? const SizedBox.shrink()
                    : Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(10)),
                        child: Text('$count',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black)),
                      ),
              ),
            ]),
          ),
        ),
      );
}

/// Removable pills for every active filter, so you always see (and can undo) what's narrowing the grid.
class _ActiveFilters extends StatelessWidget {
  const _ActiveFilters({required this.query, required this.onChanged});
  final DiscoverQuery query;
  final void Function(DiscoverQuery q, {bool debounce}) onChanged;

  @override
  Widget build(BuildContext context) {
    final q = query;
    final pills = <(String, DiscoverQuery)>[
      for (final g in q.genres) (g, q.copyWith(genres: {...q.genres}..remove(g))),
      if (q.hasYears) (_yearLabel(q.yearFrom, q.yearTo), q.copyWith(yearFrom: null, yearTo: null)),
      if (q.upcoming) ('Incl. in uscita', q.copyWith(upcoming: false)),
      if (q.hasRating) (_ratingLabel(q.minRating, q.maxRating), q.copyWith(minRating: 0, maxRating: 10)),
      if (q.minVotes != null) ('${_short(q.minVotes!)}+ voti', q.copyWith(minVotes: null)),
      if (q.language != null) (languageName(q.language), q.copyWith(language: null)),
      for (final p in q.providers) (_providerNames[p] ?? 'Servizio', q.copyWith(providers: {...q.providers}..remove(p))),
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
                  FadeSlideIn(
                    key: ValueKey(label),
                    offset: 0,
                    dx: -8,
                    child: _RemovablePill(label: label, onRemove: () => onChanged(next)),
                  ),
                Pressable(
                  onTap: () => onChanged(q.cleared()),
                  builder: (context, hovered, _) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Text('Cancella tutto',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: hovered ? VyseColors.accent : VyseColors.textDim)),
                  ),
                ),
              ]),
            ),
    );
  }
}

/// Filled in as provider logos load, so pills can show names rather than ids.
final _providerNames = <int, String>{};

class _RemovablePill extends StatelessWidget {
  const _RemovablePill({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onRemove,
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
            Icon(Icons.close_rounded, size: 14, color: hovered ? VyseColors.text : VyseColors.textDim),
          ]),
        ),
      );
}

// ───────────────────────── Filter panel ─────────────────────────

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({required this.query, required this.onChanged});
  final DiscoverQuery query;
  final void Function(DiscoverQuery q, {bool debounce}) onChanged;

  static final _thisYear = DateTime.now().year;

  static final _decades = <(String, int?, int?)>[
    ('Quest\'anno', _thisYear, _thisYear),
    ('2020s', 2020, 2029),
    ('2010s', 2010, 2019),
    ('2000s', 2000, 2009),
    ('1990s', 1990, 1999),
    ('Più vecchi', null, 1989),
  ];

  @override
  Widget build(BuildContext context) {
    final q = query;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.tune_rounded, size: 16, color: VyseColors.text),
        const SizedBox(width: 8),
        const Text('Filtri', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const Spacer(),
        AnimatedOpacity(
          opacity: q.activeFilters > 0 ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: q.activeFilters == 0,
            child: Pressable(
              onTap: () => onChanged(q.cleared()),
              builder: (context, hovered, _) => Text('Ripristina',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.accent)),
            ),
          ),
        ),
      ]),
      const _Label('Tipo'),
      _Segmented(
        options: const ['Tutti', 'Film', 'Serie TV'],
        index: q.type.index,
        onChanged: (i) {
          final type = MediaType.values[i];
          // Drop genres the new catalogue can't filter by.
          final next = q.copyWith(type: type);
          onChanged(next.copyWith(
            genres: {
              for (final g in next.genres)
                if (next.genreAvailable(DiscoverGenre.byName(g)!)) g,
            },
          ));
        },
      ),
      const _Label('Genres'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final g in discoverGenres)
          if (q.genreAvailable(g))
            _Chip(
              label: g.name,
              selected: q.genres.contains(g.name),
              onTap: () {
                final set = {...q.genres};
                if (!set.remove(g.name)) set.add(g.name);
                onChanged(q.copyWith(genres: set));
              },
            ),
      ]),
      const _Label('Anno di uscita'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, from, to) in _decades)
          _Chip(
            label: label,
            selected: q.yearFrom == from && q.yearTo == to,
            onTap: () => q.yearFrom == from && q.yearTo == to
                ? onChanged(q.copyWith(yearFrom: null, yearTo: null))
                : onChanged(q.copyWith(yearFrom: from, yearTo: to)),
          ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: _MenuButton<int?>(
            label: q.yearFrom?.toString() ?? 'Da',
            active: q.yearFrom != null,
            options: [(null, 'Qualsiasi'), for (var y = _thisYear + 2; y >= 1920; y--) (y, '$y')],
            onSelected: (y) => onChanged(q.copyWith(
              yearFrom: y,
              yearTo: y != null && q.yearTo != null && q.yearTo! < y ? y : q.yearTo,
            )),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('to', style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
        ),
        Expanded(
          child: _MenuButton<int?>(
            label: q.yearTo?.toString() ?? 'A',
            active: q.yearTo != null,
            options: [(null, 'Qualsiasi'), for (var y = _thisYear + 2; y >= 1920; y--) (y, '$y')],
            onSelected: (y) => onChanged(q.copyWith(
              yearTo: y,
              yearFrom: y != null && q.yearFrom != null && q.yearFrom! > y ? y : q.yearFrom,
            )),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text('Includi le prossime uscite', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
        ),
        _Toggle(value: q.upcoming, onChanged: (v) => onChanged(q.copyWith(upcoming: v))),
      ]),
      const _Label('Rating'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _Chip(
          label: 'Qualsiasi voto',
          icon: Icons.star_rounded,
          selected: !q.hasRating,
          onTap: () => onChanged(q.copyWith(minRating: 0, maxRating: 10)),
        ),
        for (final r in const [6, 7, 8, 9])
          _Chip(
            label: '$r+',
            icon: Icons.star_rounded,
            selected: q.minRating == r && q.maxRating == 10,
            onTap: () => onChanged(q.copyWith(minRating: r.toDouble(), maxRating: 10)),
          ),
      ]),
      const SizedBox(height: 6),
      SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          activeTrackColor: VyseColors.accent,
          inactiveTrackColor: VyseColors.ink.withValues(alpha: .1),
          thumbColor: Colors.white,
          overlayColor: VyseColors.accent.withValues(alpha: .15),
          rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 7, elevation: 2),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
          showValueIndicator: ShowValueIndicator.never,
          padding: EdgeInsets.zero,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: RangeSlider(
            values: RangeValues(q.minRating, q.maxRating),
            min: 0,
            max: 10,
            divisions: 20,
            onChanged: (v) => onChanged(q.copyWith(minRating: v.start, maxRating: v.end), debounce: true),
          ),
        ),
      ),
      Text(q.hasRating ? _ratingLabel(q.minRating, q.maxRating) : 'Qualsiasi voto',
          style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
      const _Label('Numero di voti'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, v) in const [('Auto', null), ('100+', 100), ('1K+', 1000), ('10K+', 10000)])
          _Chip(label: label, selected: q.minVotes == v, onTap: () => onChanged(q.copyWith(minVotes: v))),
      ]),
      const _Label('Lingua originale'),
      _MenuButton<String?>(
        label: languageName(q.language),
        active: q.language != null,
        options: discoverLanguages,
        onSelected: (code) => onChanged(q.copyWith(language: code)),
      ),
      const _Label('In streaming su'),
      _ProviderPicker(
        selected: q.providers,
        onToggle: (id) {
          final set = {...q.providers};
          if (!set.remove(id)) set.add(id);
          onChanged(q.copyWith(providers: set));
        },
      ),
    ]);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap, this.icon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Pressable(
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
              color: selected ? VyseColors.strong : VyseColors.ink.withValues(alpha: hovered ? .12 : .05),
              border: Border.all(color: selected ? VyseColors.strong : VyseColors.ink.withValues(alpha: .06)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: selected ? VyseColors.accentHot : VyseColors.star),
                const SizedBox(width: 4),
              ],
              Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? VyseColors.onStrong : (hovered ? VyseColors.text : VyseColors.textDim),
                  )),
            ]),
          ),
        ),
      );
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.options, required this.index, required this.onChanged});
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: VyseColors.ink.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: VyseColors.ink.withValues(alpha: .05)),
        ),
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth / options.length;
          return Stack(children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              left: index * w,
              top: 0,
              bottom: 0,
              width: w,
              child: Container(
                decoration: BoxDecoration(
                  color: VyseColors.ink.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: 8, offset: const Offset(0, 2))],
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < options.length; i++)
                SizedBox(
                  width: w,
                  child: Pressable(
                    onTap: () => onChanged(i),
                    builder: (context, hovered, _) => Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: i == index ? VyseColors.text : (hovered ? VyseColors.text : VyseColors.textFaint),
                        ),
                        child: Text(options[i]),
                      ),
                    ),
                  ),
                ),
            ]),
          ]);
        }),
      );
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: () => onChanged(!value),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 36,
          height: 21,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            color: value ? VyseColors.accent : VyseColors.ink.withValues(alpha: hovered ? .2 : .13),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1))],
              ),
            ),
          ),
        ),
      );
}

/// Chip-styled dropdown that opens a dark popup menu under itself.
class _MenuButton<T> extends StatelessWidget {
  const _MenuButton({required this.label, required this.active, required this.options, required this.onSelected});
  final String label;
  final bool active;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(topLeft & Size(box.size.width, 0), Offset.zero & overlay.size),
      constraints: BoxConstraints(minWidth: box.size.width, maxWidth: box.size.width + 60, maxHeight: 320),
      color: VyseColors.surfaceHi,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: VyseColors.stroke)),
      items: [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 34,
            child: Text(options[i].$2,
                style: TextStyle(
                  fontSize: 13,
                  color: options[i].$2 == label ? VyseColors.accent : VyseColors.text,
                  fontWeight: options[i].$2 == label ? FontWeight.w700 : FontWeight.w500,
                )),
          ),
      ],
    );
    if (picked != null) onSelected(options[picked].$1);
  }

  @override
  Widget build(BuildContext context) => Builder(
        builder: (context) => Pressable(
          onTap: () => _open(context),
          builder: (context, hovered, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: VyseColors.ink.withValues(alpha: hovered ? .1 : .05),
              border: Border.all(color: active ? VyseColors.accent.withValues(alpha: .5) : VyseColors.ink.withValues(alpha: .06)),
            ),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: active ? VyseColors.text : VyseColors.textDim)),
              ),
              Icon(Icons.expand_more_rounded, size: 16, color: hovered ? VyseColors.text : VyseColors.textFaint),
            ]),
          ),
        ),
      );
}

class _ProviderPicker extends StatefulWidget {
  const _ProviderPicker({required this.selected, required this.onToggle});
  final Set<int> selected;
  final ValueChanged<int> onToggle;

  @override
  State<_ProviderPicker> createState() => _ProviderPickerState();
}

class _ProviderPickerState extends State<_ProviderPicker> {
  late final _providers = HomeFeed.instance.providers();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<WatchProvider>>(
        future: _providers,
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) {
            return Shimmer(
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < 10; i++) const SkeletonBox(width: 40, height: 40, radius: 10),
              ]),
            );
          }
          for (final p in list) {
            _providerNames[p.id] = p.name;
          }
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in list)
              Pressable(
                tooltip: p.name,
                onTap: () => widget.onToggle(p.id),
                builder: (context, hovered, pressed) {
                  final on = widget.selected.contains(p.id);
                  return AnimatedScale(
                    scale: pressed ? .9 : (hovered ? 1.06 : 1),
                    duration: const Duration(milliseconds: 160),
                    child: Stack(clipBehavior: Clip.none, children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: on ? VyseColors.strong : VyseColors.ink.withValues(alpha: .06),
                            width: on ? 2 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: AnimatedOpacity(
                          opacity: on || hovered || widget.selected.isEmpty ? 1 : .45,
                          duration: const Duration(milliseconds: 180),
                          child: p.logo == null
                              ? Center(child: Text(p.name.characters.first, style: const TextStyle(fontWeight: FontWeight.w800)))
                              : CachedNetworkImage(imageUrl: p.logo!, fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        right: -4,
                        top: -4,
                        child: AnimatedScale(
                          scale: on ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: VyseColors.accent,
                              border: Border.all(color: VyseColors.bg, width: 2),
                            ),
                            child: const Icon(Icons.check_rounded, size: 9, color: Colors.black),
                          ),
                        ),
                      ),
                    ]),
                  );
                },
              ),
          ]);
        },
      );
}

// ───────────────────────── Formatting ─────────────────────────

String _short(int n) => n >= 1000 ? '${n ~/ 1000}K' : '$n';

String _ratingLabel(double min, double max) =>
    max >= 10 ? '★ ${min.toStringAsFixed(min % 1 == 0 ? 0 : 1)}+' : '★ ${min.toStringAsFixed(1)} – ${max.toStringAsFixed(1)}';

String _yearLabel(int? from, int? to) {
  if (from != null && to != null) return from == to ? '$from' : '$from – $to';
  if (from != null) return 'Dal $from';
  return 'Prima del ${to! + 1}';
}
