import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/tmdb.dart';
import '../data/watch_progress.dart';
import '../widgets/common.dart';
import '../widgets/page_scrollbar.dart';
import '../data/trackers/tracker_hub.dart';
import 'player_page.dart';

enum _Filter {
  all('Tutti'),
  films('Film'),
  series('Serie'),
  anime('Anime'),
  watching('In corso'),
  fresh('Non iniziati');

  const _Filter(this.label);
  final String label;
}

enum _Sort {
  added('Aggiunti di recente', Icons.schedule_rounded),
  title('Titolo A–Z', Icons.sort_by_alpha_rounded),
  year('Anno di uscita', Icons.calendar_today_rounded),
  rating('Rating', Icons.star_rounded);

  const _Sort(this.label, this.icon);
  final String label;
  final IconData icon;
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'adesso';
  if (d.inHours < 1) return '${d.inMinutes} min fa';
  if (d.inDays < 1) return '${d.inHours} h fa';
  if (d.inDays < 7) return '${d.inDays} g fa';
  if (d.inDays < 60) return '${d.inDays ~/ 7} sett. fa';
  return '${d.inDays ~/ 30} mesi fa';
}

String _left(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  if (m <= 1) return 'Quasi finito';
  if (m < 60) return '$m min rimanenti';
  final r = m % 60;
  return r == 0 ? '${m ~/ 60} h rimanenti' : '${m ~/ 60} h $r min rimanenti';
}

void _play(BuildContext context, Media m, WatchEntry? progress) => openPlayer(
  context,
  m,
  episode: progress?.season != null && progress?.episode != null
      ? PlayerEpisode(season: progress!.season!, number: progress.episode!, name: progress.episodeName)
      : (m.isTv ? const PlayerEpisode(season: 1, number: 1) : null),
);

/// Everything saved with + / Save: search, filter, sort, grid or rows, progress from Continue
/// watching, multi-select removal and a "pick for me" spinner.
class MyListPage extends StatefulWidget {
  const MyListPage({super.key});

  @override
  State<MyListPage> createState() => _MyListPageState();
}

class _MyListPageState extends State<MyListPage> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;
  bool _selecting = false;
  final _selected = <String>{};

  _Sort get _sort => _Sort.values[AppSettings.myListSort.value.clamp(0, _Sort.values.length - 1)];
  bool get _grid => AppSettings.myListGrid.value;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  List<SavedTitle> _visible(List<SavedTitle> all, Map<String, WatchEntry> progress) {
    final q = _search.text.trim().toLowerCase();
    final list = all.where((s) {
      final m = s.media;
      if (q.isNotEmpty && !m.title.toLowerCase().contains(q)) return false;
      return switch (_filter) {
        _Filter.all => true,
        _Filter.films => !m.isTv && !m.anime,
        _Filter.series => m.isTv && !m.anime,
        _Filter.anime => m.anime,
        _Filter.watching => progress.containsKey(m.key),
        _Filter.fresh => !progress.containsKey(m.key),
      };
    }).toList();
    switch (_sort) {
      case _Sort.added:
        list.sort((a, b) => b.added.compareTo(a.added));
      case _Sort.title:
        list.sort((a, b) => a.media.title.toLowerCase().compareTo(b.media.title.toLowerCase()));
      case _Sort.year:
        list.sort((a, b) => (b.media.year ?? '').compareTo(a.media.year ?? ''));
      case _Sort.rating:
        list.sort((a, b) => b.media.rating.compareTo(a.media.rating));
    }
    return list;
  }

  void _toggleSelect(String key) => setState(() {
    if (!_selected.remove(key)) _selected.add(key);
    if (_selected.isEmpty) _selecting = false;
  });

  void _startSelect([String? key]) => setState(() {
    _selecting = true;
    if (key != null) _selected.add(key);
  });

  void _endSelect() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final ff = Layout.of(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = phone ? 16.0 : 40.0;
    final top = Layout.windowChrome(context) + (phone ? 12 : 24);

    return ListenableBuilder(
      listenable: Listenable.merge([MyList.items, WatchProgress.entries, AppSettings.myListGrid, AppSettings.myListSort]),
      builder: (context, _) {
        final all = MyList.items.value;
        // unfinished only: finished titles count as "not started" again here
        final progress = {for (final e in WatchProgress.entries.value) if (!e.finished) e.media.key: e};
        final shown = _visible(all, progress);
        _selected.removeWhere((k) => !all.any((s) => s.media.key == k));

        final posterMax = switch (ff) {
          FormFactor.phone => 120.0,
          FormFactor.tablet => 156.0,
          FormFactor.desktop => (MediaQuery.sizeOf(context).width * .11).clamp(160.0, 205.0),
        };

        return PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverToBoxAdapter(
              child: _Header(
                items: all,
                inProgress: all.where((s) => progress.containsKey(s.media.key)).length,
                top: top,
                side: side,
                right: right,
                onPick: all.isEmpty ? null : () => _pickForMe(context, shown.isNotEmpty ? shown : all, progress),
              ),
            ),
            if (all.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(side, 4, right, 14),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _selecting
                        ? _SelectBar(
                            key: const ValueKey('select'),
                            count: _selected.length,
                            total: shown.length,
                            onAll: () => setState(() => _selected.addAll(shown.map((s) => s.media.key))),
                            onRemove: _selected.isEmpty
                                ? null
                                : () {
                                    TrackerHub.myListRemove({..._selected});
                                    _endSelect();
                                  },
                            onCancel: _endSelect,
                          )
                        : _Toolbar(
                            key: const ValueKey('tools'),
                            search: _search,
                            filter: _filter,
                            sort: _sort,
                            grid: _grid,
                            phone: phone,
                            counts: {
                              for (final f in _Filter.values)
                                f: switch (f) {
                                  _Filter.all => all.length,
                                  _Filter.films => all.where((s) => !s.media.isTv && !s.media.anime).length,
                                  _Filter.series => all.where((s) => s.media.isTv && !s.media.anime).length,
                                  _Filter.anime => all.where((s) => s.media.anime).length,
                                  _Filter.watching => all.where((s) => progress.containsKey(s.media.key)).length,
                                  _Filter.fresh => all.where((s) => !progress.containsKey(s.media.key)).length,
                                },
                            },
                            onFilter: (f) => setState(() => _filter = f),
                            onSort: (s) => AppSettings.myListSort.set(s.index),
                            onGrid: (g) => AppSettings.myListGrid.set(g),
                            onSelect: () => _startSelect(),
                          ),
                  ),
                ),
              ),
            if (all.isEmpty)
              SliverToBoxAdapter(child: _Empty(side: side, right: right))
            else if (shown.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(side, 40, right, 40),
                  child: const Column(children: [
                    Icon(Icons.filter_alt_off_outlined, size: 34, color: VyseColors.textFaint),
                    SizedBox(height: 12),
                    Text('Niente corrisponde', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('Prova un altro filtro o ricerca', style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
                  ]),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 0, right, 0),
                sliver: _grid
                    ? SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: posterMax,
                          childAspectRatio: 2 / 3,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 12,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final s = shown[i];
                            return FadeSlideIn(
                              key: ValueKey('g/${s.media.key}'),
                              delay: Duration(milliseconds: 18 * (i % 14)),
                              offset: 8,
                              child: _PosterTile(
                                item: s,
                                progress: progress[s.media.key],
                                selecting: _selecting,
                                selected: _selected.contains(s.media.key),
                                onTap: () => _selecting ? _toggleSelect(s.media.key) : openDetails(context, s.media, heroTag: 'mylist/${s.media.key}'),
                                onLongPress: () => _selecting ? _toggleSelect(s.media.key) : _startSelect(s.media.key),
                              ),
                            );
                          },
                          childCount: shown.length,
                        ),
                      )
                    : SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 760,
                          mainAxisExtent: phone ? 118 : 152,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 14,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final s = shown[i];
                            return FadeSlideIn(
                              key: ValueKey('r/${s.media.key}'),
                              delay: Duration(milliseconds: 22 * (i % 10)),
                              offset: 8,
                              child: _RowTile(
                                item: s,
                                progress: progress[s.media.key],
                                phone: phone,
                                selecting: _selecting,
                                selected: _selected.contains(s.media.key),
                                onTap: () => _selecting ? _toggleSelect(s.media.key) : openDetails(context, s.media),
                                onLongPress: () => _selecting ? _toggleSelect(s.media.key) : _startSelect(s.media.key),
                              ),
                            );
                          },
                          childCount: shown.length,
                        ),
                      ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: phone ? 110 + MediaQuery.paddingOf(context).bottom : 48)),
          ]),
        );
      },
    );
  }

  void _pickForMe(BuildContext context, List<SavedTitle> pool, Map<String, WatchEntry> progress) => showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Scegli tu per me',
    barrierColor: Colors.black.withValues(alpha: .7),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (dialog, _, _) => _PickForMe(
      pool: pool,
      progress: progress,
      onPlay: (m, p) {
        Navigator.of(dialog).pop();
        _play(context, m, p);
      },
      onDetails: (m) {
        Navigator.of(dialog).pop();
        openDetails(context, m);
      },
    ),
    transitionBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: .94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
  );
}

// ───────────────────────── Header ─────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.items, required this.inProgress, required this.top, required this.side, required this.right, required this.onPick});
  final List<SavedTitle> items;
  final int inProgress;
  final double top;
  final double side;
  final double right;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final films = items.where((s) => !s.media.isTv && !s.media.anime).length;
    final anime = items.where((s) => s.media.anime).length;
    final backdrop = items.map((s) => s.media.backdrop('w780')).whereType<String>().firstOrNull;
    final stats = [
      '${items.length} ${items.length == 1 ? 'title' : 'titles'}',
      if (films > 0) '$films ${films == 1 ? 'film' : 'films'}',
      if (items.length - films - anime > 0) '${items.length - films - anime} serie',
      if (anime > 0) '$anime anime',
      if (inProgress > 0) '$inProgress in corso',
    ];
    return Stack(children: [
      // the newest addition, blurred into the page
      if (backdrop != null)
        Positioned.fill(
          child: RepaintBoundary(
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
                stops: [.15, 1],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: Opacity(
                opacity: .45,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36, tileMode: TileMode.decal),
                  child: CachedNetworkImage(imageUrl: backdrop, fit: BoxFit.cover, fadeInDuration: const Duration(milliseconds: 500)),
                ),
              ),
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(side, top, right, phone ? 18 : 24),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: phone ? 36 : 42,
                  height: phone ? 36 : 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(colors: [VyseColors.accent, VyseColors.accent.withValues(alpha: .55)]),
                    boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .35), blurRadius: 16)],
                  ),
                  child: Icon(Icons.bookmark_rounded, size: phone ? 20 : 24, color: Colors.black),
                ),
                const SizedBox(width: 12),
                Text('La mia lista', style: TextStyle(fontSize: phone ? 26 : 34, fontWeight: FontWeight.w900, letterSpacing: -.8)),
              ]),
              const SizedBox(height: 8),
              Text(
                items.isEmpty ? 'I titoli che salvi compaiono qui' : stats.join('  ·  '),
                style: TextStyle(fontSize: phone ? 12.5 : 14, color: VyseColors.textDim, fontWeight: FontWeight.w500),
              ),
            ]),
          ),
          if (onPick != null) _PickButton(onTap: onPick!, compact: phone),
        ]),
      ),
    ]);
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.onTap, required this.compact});
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: 'Scegli qualcosa dalla tua lista',
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : (hovered ? 1.03 : 1),
      duration: const Duration(milliseconds: 140),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: compact ? 9 : 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: hovered ? Colors.white : Colors.white.withValues(alpha: .92),
          boxShadow: [if (hovered) BoxShadow(color: Colors.white.withValues(alpha: .25), blurRadius: 18)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.casino_rounded, size: 18, color: Colors.black),
          if (!compact) ...[
            const SizedBox(width: 8),
            const Text("Indeciso?", style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Colors.black)),
          ],
        ]),
      ),
    ),
  );
}

// ───────────────────────── Toolbar ─────────────────────────

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    super.key,
    required this.search,
    required this.filter,
    required this.sort,
    required this.grid,
    required this.phone,
    required this.counts,
    required this.onFilter,
    required this.onSort,
    required this.onGrid,
    required this.onSelect,
  });
  final TextEditingController search;
  final _Filter filter;
  final _Sort sort;
  final bool grid;
  final bool phone;
  final Map<_Filter, int> counts;
  final ValueChanged<_Filter> onFilter;
  final ValueChanged<_Sort> onSort;
  final ValueChanged<bool> onGrid;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final searchBox = SizedBox(
      height: 40,
      child: TextField(
        controller: search,
        style: const TextStyle(fontSize: 13.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Cerca nella tua lista',
          hintStyle: const TextStyle(fontSize: 13.5, color: VyseColors.textFaint),
          prefixIcon: const Icon(Icons.search_rounded, size: 19, color: VyseColors.textFaint),
          suffixIcon: search.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 17, color: VyseColors.textDim),
                  onPressed: search.clear,
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          filled: true,
          fillColor: Colors.white.withValues(alpha: .06),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
        ),
      ),
    );
    final tools = Row(mainAxisSize: MainAxisSize.min, children: [
      _SortMenu(sort: sort, onSort: onSort, compact: phone),
      const SizedBox(width: 6),
      _ViewToggle(grid: grid, onGrid: onGrid),
      const SizedBox(width: 6),
      _RoundTool(icon: Icons.checklist_rounded, tooltip: 'Seleziona', onTap: onSelect),
    ]);
    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final f in _Filter.values)
          if (f == _Filter.all || (counts[f] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _Chip(label: f.label, count: counts[f] ?? 0, selected: f == filter, onTap: () => onFilter(f)),
            ),
      ]),
    );
    if (phone) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: searchBox), const SizedBox(width: 8), tools]),
        const SizedBox(height: 10),
        chips,
      ]);
    }
    return Row(children: [
      SizedBox(width: 260, child: searchBox),
      const SizedBox(width: 14),
      Expanded(child: chips),
      const SizedBox(width: 10),
      tools,
    ]);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.count, required this.selected, required this.onTap});
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: selected ? LinearGradient(colors: [VyseColors.accent.withValues(alpha: .24), VyseColors.accent.withValues(alpha: .08)]) : null,
        color: selected ? null : Colors.white.withValues(alpha: hovered ? .09 : .05),
        border: Border.all(color: selected ? VyseColors.accent.withValues(alpha: .45) : Colors.transparent),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: selected ? Colors.white : VyseColors.textDim)),
        const SizedBox(width: 6),
        Text('$count', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: selected ? VyseColors.accent : VyseColors.textFaint)),
      ]),
    ),
  );
}

class _RoundTool extends StatelessWidget {
  const _RoundTool({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: hovered ? .12 : .06),
      ),
      child: Icon(icon, size: 19, color: VyseColors.text),
    ),
  );
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.grid, required this.onGrid});
  final bool grid;
  final ValueChanged<bool> onGrid;

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .06), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (g, icon, tip) in const [(true, Icons.grid_view_rounded, 'Locandine'), (false, Icons.view_agenda_outlined, 'Righe')])
        Pressable(
          tooltip: tip,
          onTap: () => onGrid(g),
          builder: (context, hovered, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              color: grid == g ? Colors.white.withValues(alpha: .16) : Colors.transparent,
            ),
            child: Icon(icon, size: 17, color: grid == g ? Colors.white : VyseColors.textDim),
          ),
        ),
    ]),
  );
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onSort, required this.compact});
  final _Sort sort;
  final ValueChanged<_Sort> onSort;
  final bool compact;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Color(0xF7101118)),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.white.withValues(alpha: .08))),
      ),
    ),
    menuChildren: [
      for (final s in _Sort.values)
        MenuItemButton(
          onPressed: () => onSort(s),
          leadingIcon: Icon(s.icon, size: 17, color: s == sort ? VyseColors.accent : VyseColors.textDim),
          trailingIcon: s == sort ? const Icon(Icons.check_rounded, size: 17, color: VyseColors.accent) : null,
          style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(210, 42))),
          child: Text(s.label, style: TextStyle(fontSize: 13.5, fontWeight: s == sort ? FontWeight.w800 : FontWeight.w500)),
        ),
    ],
    builder: (context, controller, _) => Pressable(
      tooltip: 'Ordina',
      onTap: () => controller.isOpen ? controller.close() : controller.open(),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 40,
        padding: EdgeInsets.symmetric(horizontal: compact ? 11 : 14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: Colors.white.withValues(alpha: hovered ? .12 : .06)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(sort.icon, size: 17),
          if (!compact) ...[
            const SizedBox(width: 7),
            Text(sort.label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: VyseColors.textDim),
          ],
        ]),
      ),
    ),
  );
}

class _SelectBar extends StatelessWidget {
  const _SelectBar({super.key, required this.count, required this.total, required this.onAll, required this.onRemove, required this.onCancel});
  final int count;
  final int total;
  final VoidCallback onAll;
  final VoidCallback? onRemove;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: LinearGradient(colors: [VyseColors.accent.withValues(alpha: .18), VyseColors.accent.withValues(alpha: .05)]),
      border: Border.all(color: VyseColors.accent.withValues(alpha: .3)),
    ),
    child: Row(children: [
      _RoundTool(icon: Icons.close_rounded, tooltip: 'Fatto', onTap: onCancel),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          count == 0 ? 'Tocca i titoli per selezionarli' : '$count selezionati',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (count < total)
        TextButton(
          onPressed: onAll,
          child: const Text('Seleziona tutto', style: TextStyle(color: VyseColors.text, fontWeight: FontWeight.w700)),
        ),
      const SizedBox(width: 4),
      Pressable(
        onTap: onRemove,
        builder: (context, hovered, _) => AnimatedOpacity(
          opacity: onRemove == null ? .4 : 1,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: const Color(0xFFFF4D4F).withValues(alpha: hovered ? .3 : .18),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.delete_outline_rounded, size: 17, color: Color(0xFFFF8A8C)),
              SizedBox(width: 6),
              Text('Rimuovi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFFFB3B4))),
            ]),
          ),
        ),
      ),
    ]),
  );
}

// ───────────────────────── Tiles ─────────────────────────

Widget _img(String? url) => url == null
    ? const ColoredBox(color: VyseColors.surface, child: Center(child: Icon(Icons.movie_outlined, color: VyseColors.textFaint)))
    : CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 250),
        placeholder: (_, _) => const ColoredBox(color: VyseColors.surface),
        errorWidget: (_, _, _) => const ColoredBox(color: VyseColors.surface),
      );

class _Check extends StatelessWidget {
  const _Check({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 150),
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: on ? VyseColors.accent : Colors.black.withValues(alpha: .5),
      border: Border.all(color: on ? VyseColors.accent : Colors.white.withValues(alpha: .7), width: 1.5),
    ),
    child: on ? const Icon(Icons.check_rounded, size: 16, color: Colors.black) : null,
  );
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) => Stack(children: [
    Container(height: 3, color: Colors.white.withValues(alpha: .18)),
    FractionallySizedBox(
      widthFactor: fraction,
      child: Container(
        height: 3,
        decoration: BoxDecoration(
          color: VyseColors.accent,
          boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .7), blurRadius: 6)],
        ),
      ),
    ),
  ]);
}

class _PosterTile extends StatelessWidget {
  const _PosterTile({
    required this.item,
    required this.progress,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final SavedTitle item;
  final WatchEntry? progress;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final m = item.media;
    final p = progress;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .97 : (selecting && !selected ? .96 : 1),
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 170),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: VyseColors.surface),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected ? VyseColors.accent : (hovered ? Colors.white : Colors.white.withValues(alpha: .05)),
                width: selected || hovered ? 2 : 1,
              ),
            ),
            child: Stack(fit: StackFit.expand, children: [
              Hero(tag: 'mylist/${m.key}', child: _img(m.poster())),
              // shade + actions on hover
              AnimatedOpacity(
                opacity: hovered && !selecting ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.center, colors: [Color(0xE0000000), Color(0x00000000)]),
                  ),
                ),
              ),
              if (!selecting)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: p == null ? 8 : 12,
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(
                      ignoring: !hovered,
                      child: Row(children: [
                        _TileAction(icon: Icons.play_arrow_rounded, tooltip: p == null ? 'Riproduci' : 'Riprendi', primary: true, onTap: () => _play(context, m, p)),
                        const Spacer(),
                        _TileAction(icon: Icons.bookmark_remove_outlined, tooltip: 'Rimuovi da La mia lista', onTap: () => TrackerHub.myListRemove({m.key})),
                      ]),
                    ),
                  ),
                ),
              // where you are
              if (p != null) ...[
                if (p.season != null && p.episode != null)
                  Positioned(
                    top: 7,
                    left: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(6)),
                      child: Text(episodeLabel(p.season, p.episode ?? 0), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ),
                Positioned(left: 0, right: 0, bottom: 0, child: _ProgressLine(fraction: p.fraction)),
              ],
              if (selecting) Positioned(top: 7, right: 7, child: _Check(on: selected)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({required this.icon, required this.tooltip, required this.onTap, this.primary = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : (hovered ? 1.08 : 1),
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: primary ? 36 : 32,
        height: primary ? 36 : 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary ? Colors.white : Colors.black.withValues(alpha: .6),
          border: primary ? null : Border.all(color: Colors.white.withValues(alpha: .3)),
        ),
        child: Icon(icon, size: primary ? 22 : 17, color: primary ? Colors.black : Colors.white),
      ),
    ),
  );
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.item,
    required this.progress,
    required this.phone,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final SavedTitle item;
  final WatchEntry? progress;
  final bool phone;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final m = item.media;
    final p = progress;
    final meta = [
      m.kind,
      if (m.year != null) m.year!,
      if (m.rating > 0) '★ ${m.rating.toStringAsFixed(1)}',
      'aggiunto ${_ago(item.added)}',
    ].join('  ·  ');
    return GestureDetector(
      onLongPress: onLongPress,
      child: Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .985 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 170),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected ? VyseColors.accent.withValues(alpha: .1) : Colors.white.withValues(alpha: hovered ? .07 : .035),
              border: Border.all(color: selected ? VyseColors.accent.withValues(alpha: .6) : Colors.white.withValues(alpha: hovered ? .14 : .05)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // backdrop thumb with progress
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(fit: StackFit.expand, children: [
                    _img(m.backdrop('w300') ?? m.poster()),
                    if (p != null) Positioned(left: 0, right: 0, bottom: 0, child: _ProgressLine(fraction: p.fraction)),
                    if (selecting) Positioned(top: 6, left: 6, child: _Check(on: selected)),
                  ]),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(
                    m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: phone ? 14.5 : 16, fontWeight: FontWeight.w800, letterSpacing: -.2),
                  ),
                  const SizedBox(height: 3),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
                  if (p != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      [if (p.season != null && p.episode != null) episodeLabel(p.season, p.episode ?? 0), _left(p.left)].join('  ·  '),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.accent),
                    ),
                  ] else if (!phone && m.overview.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(m.overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.35, color: VyseColors.textDim)),
                  ],
                ]),
              ),
              if (!selecting) ...[
                const SizedBox(width: 10),
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _TileAction(icon: Icons.play_arrow_rounded, tooltip: p == null ? 'Riproduci' : 'Riprendi', primary: true, onTap: () => _play(context, m, p)),
                  if (!phone) ...[
                    const SizedBox(height: 8),
                    _TileAction(icon: Icons.bookmark_remove_outlined, tooltip: 'Rimuovi da La mia lista', onTap: () => TrackerHub.myListRemove({m.key})),
                  ],
                ]),
                const SizedBox(width: 4),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Empty ─────────────────────────

class _Empty extends StatelessWidget {
  const _Empty({required this.side, required this.right});
  final double side;
  final double right;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(side, 40, right, 40),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(children: [
          // a small fan of posters: solid cards, the front one lit
          SizedBox(
            height: 150,
            width: 230,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              // glow behind the front card
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .18), blurRadius: 50, spreadRadius: 6)],
                ),
              ),
              for (final side in const [-1.0, 1.0])
                Transform.translate(
                  offset: Offset(side * 44, 8),
                  child: Transform.rotate(
                    angle: side * .16,
                    child: Container(
                      width: 72,
                      height: 108,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF1A1D29), Color(0xFF12141D)],
                        ),
                        border: Border.all(color: Colors.white.withValues(alpha: .07)),
                        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 14, offset: Offset(0, 6))],
                      ),
                    ),
                  ),
                ),
              Container(
                width: 84,
                height: 126,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF242838), Color(0xFF171A25)],
                  ),
                  border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
                  boxShadow: const [BoxShadow(color: Color(0xB3000000), blurRadius: 20, offset: Offset(0, 10))],
                ),
                child: const Icon(Icons.bookmark_add_rounded, color: VyseColors.accent, size: 32),
              ),
            ]),
          ),
          const SizedBox(height: 22),
          const Text('La tua lista è vuota', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'Tocca + o Salva su qualsiasi film o serie e finisce qui, pronto per dopo.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, height: 1.4, color: VyseColors.textDim),
          ),
        ]),
      ),
    ),
  );
}

// ───────────────────────── Pick for me ─────────────────────────

/// Spins through the list's posters and lands on one.
class _PickForMe extends StatefulWidget {
  const _PickForMe({required this.pool, required this.progress, required this.onPlay, required this.onDetails});
  final List<SavedTitle> pool;
  final Map<String, WatchEntry> progress;
  final void Function(Media media, WatchEntry? progress) onPlay;
  final ValueChanged<Media> onDetails;

  @override
  State<_PickForMe> createState() => _PickForMeState();
}

class _PickForMeState extends State<_PickForMe> {
  final _rand = math.Random();
  late int _i = _rand.nextInt(widget.pool.length);
  bool _spinning = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _spin();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Fast at first, slowing to a stop.
  void _spin() {
    setState(() => _spinning = true);
    var step = 0;
    const steps = 16;
    void tick() {
      if (!mounted) return;
      setState(() => _i = widget.pool.length == 1 ? 0 : (_i + 1 + _rand.nextInt(widget.pool.length - 1)) % widget.pool.length);
      step++;
      if (step >= steps) {
        setState(() => _spinning = false);
        return;
      }
      _timer = Timer(Duration(milliseconds: 55 + (step * step * 2.4).round()), tick);
    }

    tick();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final s = widget.pool[_i];
    final m = s.media;
    final p = widget.progress[m.key];
    final posterW = phone ? 170.0 : 210.0;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: phone ? MediaQuery.sizeOf(context).width - 40 : 420,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
          decoration: BoxDecoration(
            color: const Color(0xF7101118),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
            boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: _spinning ? .1 : .25), blurRadius: 40)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              _spinning ? 'Scelgo…' : 'Stasera guarda',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: VyseColors.accent),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: posterW,
              height: posterW * 1.5,
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: _spinning ? 90 : 300),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(0, .06), end: Offset.zero).animate(a), child: child),
                ),
                child: ClipRRect(
                  key: ValueKey(_i),
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox.expand(child: _img(m.poster())),
                ),
              ),
            ),
            const SizedBox(height: 16),
            AnimatedOpacity(
              opacity: _spinning ? .35 : 1,
              duration: const Duration(milliseconds: 200),
              child: Column(children: [
                Text(m.title, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -.3)),
                const SizedBox(height: 4),
                Text(
                  [m.kind, if (m.year != null) m.year!, if (m.rating > 0) '★ ${m.rating.toStringAsFixed(1)}', if (p != null) _left(p.left)].join('  ·  '),
                  style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                ),
              ]),
            ),
            const SizedBox(height: 18),
            IgnorePointer(
              ignoring: _spinning,
              child: AnimatedOpacity(
                opacity: _spinning ? .3 : 1,
                duration: const Duration(milliseconds: 200),
                child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                  _DialogButton(
                    icon: Icons.play_arrow_rounded,
                    label: p == null ? 'Riproduci' : 'Riprendi',
                    primary: true,
                    onTap: () => widget.onPlay(m, p),
                  ),
                  _DialogButton(
                    icon: Icons.info_outline_rounded,
                    label: 'Dettagli',
                    onTap: () => widget.onDetails(m),
                  ),
                  if (widget.pool.length > 1) _DialogButton(icon: Icons.casino_rounded, label: 'Gira di nuovo', onTap: _spin),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: primary ? (hovered ? Colors.white : Colors.white.withValues(alpha: .92)) : Colors.white.withValues(alpha: hovered ? .14 : .08),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: primary ? Colors.black : Colors.white),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: primary ? Colors.black : Colors.white)),
        ]),
      ),
    ),
  );
}
