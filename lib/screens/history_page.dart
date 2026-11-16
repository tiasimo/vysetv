import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/tmdb.dart' show episodeLabel;
import '../data/watch_progress.dart';
import '../widgets/common.dart';
import '../widgets/page_scrollbar.dart';
import '../data/trackers/tracker_hub.dart';
import 'player_page.dart';

enum _Filter {
  all('All'),
  movies('Movies'),
  series('Series'),
  anime('Anime'),
  watching('In progress'),
  finished('Finished');

  const _Filter(this.label);
  final String label;

  bool test(WatchEntry e) => switch (this) {
    _Filter.all => true,
    _Filter.movies => !e.media.isTv && !e.media.anime,
    _Filter.series => e.media.isTv && !e.media.anime,
    _Filter.anime => e.media.anime,
    _Filter.watching => !e.finished,
    _Filter.finished => e.finished,
  };
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  if (d.inDays < 60) return '${d.inDays ~/ 7}w ago';
  return '${d.inDays ~/ 30}mo ago';
}

/// "Today", "Yesterday", "This week", "This month", "Earlier".
String _bucket(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'This week';
  if (days < 31) return 'This month';
  return 'Earlier';
}

/// Everything played, newest first: progress for what's unfinished, a Finished badge for the
/// rest, grouped by when it was watched.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;

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

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF101118),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clear watch history?', style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
          'This removes everything here and empties Continue watching. It can\'t be undone.',
          style: TextStyle(color: VyseColors.textDim, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: VyseColors.text))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok == true) WatchProgress.clear();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = phone ? 16.0 : 40.0;
    final top = Layout.windowChrome(context) + (phone ? 12 : 24);

    return ValueListenableBuilder<List<WatchEntry>>(
      valueListenable: WatchProgress.entries,
      builder: (context, all, _) {
        final q = _search.text.trim().toLowerCase();
        final shown = all.where((e) => _filter.test(e) && (q.isEmpty || e.media.title.toLowerCase().contains(q))).toList();
        final finished = all.where((e) => e.finished).length;

        // group by when it was watched, keeping newest-first order
        final groups = <String, List<WatchEntry>>{};
        for (final e in shown) {
          (groups[_bucket(e.updated)] ??= []).add(e);
        }

        return PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, top, right, 0),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Watch History', style: TextStyle(fontSize: phone ? 26 : 34, fontWeight: FontWeight.w900, letterSpacing: -.8)),
                            const SizedBox(height: 6),
                            Text(
                              all.isEmpty
                                  ? 'What you watch shows up here'
                                  : [
                                      '${all.length} ${all.length == 1 ? 'title' : 'titles'}',
                                      if (finished > 0) '$finished finished',
                                      if (all.length - finished > 0) '${all.length - finished} in progress',
                                    ].join('  ·  '),
                              style: TextStyle(fontSize: phone ? 12.5 : 14, color: VyseColors.textDim, fontWeight: FontWeight.w500),
                            ),
                          ]),
                        ),
                        if (all.isNotEmpty) _ClearButton(onTap: _confirmClear, compact: phone),
                      ]),
                      if (all.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _Toolbar(
                          phone: phone,
                          search: _search,
                          filter: _filter,
                          counts: {for (final f in _Filter.values) f: all.where(f.test).length},
                          onFilter: (f) => setState(() => _filter = f),
                        ),
                      ],
                      const SizedBox(height: 8),
                    ]),
                  ),
                ),
              ),
            ),
            if (all.isEmpty)
              const SliverToBoxAdapter(child: _Empty())
            else if (shown.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: 50),
                  child: Column(children: [
                    Icon(Icons.manage_search_rounded, size: 34, color: VyseColors.textFaint),
                    SizedBox(height: 10),
                    Text('Nothing here matches', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ]),
                ),
              )
            else
              for (final MapEntry(key: label, value: list) in groups.entries) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 18, right, 8),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: Row(children: [
                          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: VyseColors.textDim, letterSpacing: .2)),
                          const SizedBox(width: 10),
                          Expanded(child: Container(height: 1, color: Colors.white.withValues(alpha: .06))),
                        ]),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, 0, right, 0),
                  sliver: SliverList.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: FadeSlideIn(
                          key: ValueKey('h/${list[i].media.key}'),
                          delay: Duration(milliseconds: 20 * (i % 10)),
                          offset: 8,
                          child: _HistoryRow(entry: list[i], phone: phone),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            SliverToBoxAdapter(child: SizedBox(height: phone ? 110 + MediaQuery.paddingOf(context).bottom : 48)),
          ]),
        );
      },
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onTap, required this.compact});
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: 'Clear watch history',
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .96 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18, vertical: compact ? 9 : 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: hovered ? const Color(0xFFFF4D4F).withValues(alpha: .18) : Colors.white.withValues(alpha: .07),
          border: Border.all(color: hovered ? const Color(0xFFFF4D4F).withValues(alpha: .4) : Colors.white.withValues(alpha: .06)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.delete_sweep_outlined, size: 18, color: hovered ? const Color(0xFFFF8A8C) : VyseColors.text),
          if (!compact) ...[
            const SizedBox(width: 8),
            Text('Clear all', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: hovered ? const Color(0xFFFFB3B4) : VyseColors.text)),
          ],
        ]),
      ),
    ),
  );
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.phone, required this.search, required this.filter, required this.counts, required this.onFilter});
  final bool phone;
  final TextEditingController search;
  final _Filter filter;
  final Map<_Filter, int> counts;
  final ValueChanged<_Filter> onFilter;

  @override
  Widget build(BuildContext context) {
    // segmented pill like a tab strip
    final segments = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(14)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final f in _Filter.values)
            if (f == _Filter.all || (counts[f] ?? 0) > 0)
              Pressable(
                onTap: () => onFilter(f),
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 170),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: f == filter ? Colors.white.withValues(alpha: .14) : (hovered ? Colors.white.withValues(alpha: .05) : Colors.transparent),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      f.label,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: f == filter ? Colors.white : VyseColors.textDim),
                    ),
                    if (f != _Filter.all) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${counts[f]}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: f == filter ? VyseColors.accent : VyseColors.textFaint),
                      ),
                    ],
                  ]),
                ),
              ),
        ]),
      ),
    );
    final searchBox = SizedBox(
      height: 44,
      child: TextField(
        controller: search,
        style: const TextStyle(fontSize: 13.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search history',
          hintStyle: const TextStyle(fontSize: 13.5, color: VyseColors.textFaint),
          prefixIcon: const Icon(Icons.search_rounded, size: 19, color: VyseColors.textFaint),
          suffixIcon: search.text.isEmpty
              ? null
              : IconButton(icon: const Icon(Icons.close_rounded, size: 17, color: VyseColors.textDim), onPressed: search.clear),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          filled: true,
          fillColor: Colors.white.withValues(alpha: .05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        ),
      ),
    );
    if (phone) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [searchBox, const SizedBox(height: 10), segments]);
    }
    return Row(children: [
      Flexible(child: Align(alignment: Alignment.centerLeft, child: segments)),
      const SizedBox(width: 14),
      SizedBox(width: 260, child: searchBox),
    ]);
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.phone});
  final WatchEntry entry;
  final bool phone;

  void _play(BuildContext context) {
    final e = entry;
    openPlayer(
      context,
      e.media,
      episode: e.season != null && e.episode != null ? PlayerEpisode(season: e.season!, number: e.episode!, name: e.episodeName) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final m = e.media;
    final pct = (e.fraction * 100).round();
    final meta = [
      if (m.year != null) m.year!,
      m.kind,
      if (m.rating > 0) '★ ${m.rating.toStringAsFixed(1)}',
      if (e.season != null && e.episode != null) episodeLabel(e.season, e.episode ?? 0, gap: ' '),
      _ago(e.updated),
    ].join('  ·  ');
    final watchedEps = e.episodes.length;
    final thumbW = phone ? 50.0 : 62.0;

    return Pressable(
      onTap: () => openDetails(context, m),
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .99 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.all(phone ? 10 : 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withValues(alpha: hovered ? .065 : .035),
            border: Border.all(color: Colors.white.withValues(alpha: hovered ? .12 : .04)),
          ),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: thumbW,
                height: thumbW * 1.5,
                child: m.poster() == null
                    ? const ColoredBox(color: VyseColors.surface)
                    : CachedNetworkImage(
                        imageUrl: m.poster()!,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 250),
                        errorWidget: (_, _, _) => const ColoredBox(color: VyseColors.surface),
                      ),
              ),
            ),
            SizedBox(width: phone ? 12 : 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: phone ? 14.5 : 16, fontWeight: FontWeight.w800, letterSpacing: -.2),
                    ),
                  ),
                  if (e.finished) ...[const SizedBox(width: 8), const _FinishedBadge()],
                ]),
                const SizedBox(height: 4),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                if (m.isTv && watchedEps > 1) ...[
                  const SizedBox(height: 3),
                  Text(
                    '$watchedEps episodes watched${e.episodesFinished > 0 ? ' · ${e.episodesFinished} finished' : ''}',
                    style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                  ),
                ],
                SizedBox(height: phone ? 8 : 10),
                Row(children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Stack(children: [
                        Container(height: 4, color: Colors.white.withValues(alpha: .1)),
                        FractionallySizedBox(
                          widthFactor: e.fraction,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              color: e.finished ? const Color(0xFF3DDC97) : VyseColors.accent,
                              boxShadow: [
                                BoxShadow(color: (e.finished ? const Color(0xFF3DDC97) : VyseColors.accent).withValues(alpha: .55), blurRadius: 6),
                              ],
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 38,
                    child: Text(
                      '$pct%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: e.finished ? const Color(0xFF3DDC97) : VyseColors.textDim,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ]),
              ]),
            ),
            SizedBox(width: phone ? 8 : 16),
            _RowButton(
              icon: e.finished ? Icons.replay_rounded : Icons.play_arrow_rounded,
              tooltip: e.finished ? 'Watch again' : 'Resume',
              primary: hovered || phone,
              size: phone ? 36 : 42,
              onTap: () => _play(context),
            ),
            SizedBox(width: phone ? 6 : 10),
            _RowButton(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Remove from history',
              size: phone ? 36 : 42,
              danger: true,
              onTap: () {
                WatchProgress.remove(m);
                TrackerHub.historyRemoved(m);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class _FinishedBadge extends StatelessWidget {
  const _FinishedBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      color: const Color(0xFF3DDC97).withValues(alpha: .14),
      border: Border.all(color: const Color(0xFF3DDC97).withValues(alpha: .35)),
    ),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF3DDC97)),
      SizedBox(width: 4),
      Text('Finished', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Color(0xFF3DDC97))),
    ]),
  );
}

class _RowButton extends StatelessWidget {
  const _RowButton({required this.icon, required this.tooltip, required this.onTap, required this.size, this.primary = false, this.danger = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : (hovered ? 1.06 : 1),
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary
              ? Colors.white.withValues(alpha: hovered ? 1 : .92)
              : (danger && hovered ? const Color(0xFFFF4D4F).withValues(alpha: .22) : Colors.white.withValues(alpha: hovered ? .12 : .07)),
        ),
        child: Icon(
          icon,
          size: size * .5,
          color: primary ? Colors.black : (danger && hovered ? const Color(0xFFFF8A8C) : VyseColors.text),
        ),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 60, left: 24, right: 24),
    child: Column(children: [
      Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [VyseColors.accent.withValues(alpha: .25), Colors.transparent]),
        ),
        child: const Icon(Icons.history_rounded, size: 40, color: VyseColors.accent),
      ),
      const SizedBox(height: 18),
      const Text('Nothing watched yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      const Text(
        'Start anything and it shows up here, with how far you got.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13.5, color: VyseColors.textDim),
      ),
    ]),
  );
}
