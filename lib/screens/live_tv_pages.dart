import 'dart:async';

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/live_tv.dart';
import '../data/match_finder.dart';
import '../data/sports_schedule.dart';
import '../models/iptv/iptv_models.dart';
import '../models/iptv/m3u_models.dart';
import '../services/iptv/hardcoded_channels.dart';
import '../widgets/common.dart';
import '../widgets/live_tv_widgets.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import '../widgets/match_widgets.dart';
import 'live_tv_player_page.dart';

/// Shared scaffold: glow, header, a toolbar row, then the page's slivers.
class _LivePage extends StatelessWidget {
  const _LivePage({required this.scroll, required this.title, required this.subtitle, required this.slivers});
  final ScrollController scroll;
  final String title;
  final String subtitle;
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);
    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: scroll,
          child: CustomScrollView(controller: scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(Layout.inset(context), top, pageRight(context), 18),
              sliver: SliverToBoxAdapter(child: SectionHeader(title: title, subtitle: subtitle)),
            ),
            ...slivers,
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }
}

SliverPadding _pad(BuildContext context, Widget child, {double bottom = 14}) => SliverPadding(
      padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), bottom),
      sliver: SliverToBoxAdapter(child: child),
    );

double _tileW(BuildContext context) => Layout.isPhone(context) ? 120.0 : 160.0;

/// Tiny search box for filtering a grid in place.
class _Filter extends StatelessWidget {
  const _Filter({required this.controller, required this.hint});
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: VyseSearchField(controller: controller, hint: hint)),
      );
}

// ───────────────────────── Featured channel: search portals for it ─────────────────────────

class LiveChannelPage extends StatefulWidget {
  const LiveChannelPage({super.key, required this.channel, this.match});
  final HardcodedChannel channel;

  /// Opened from a fixture: check each feed's TV guide and point at the one showing it.
  final Match? match;

  @override
  State<LiveChannelPage> createState() => _LiveChannelPageState();
}

class _LiveChannelPageState extends State<LiveChannelPage> {
  final _scroll = ScrollController();
  String? _num;
  String? _lang;
  String? _quality;
  late final MatchFinder? _finder = widget.match == null ? null : MatchFinder(widget.match!, widget.channel);

  void _feed() {
    if (iptv.activeHardcoded?.id == ch.id) _finder?.update(iptv.channelResults);
  }

  bool _matches(HitTags t) =>
      (_num == null || t.number == _num) && (_lang == null || t.lang == _lang) && (_quality == null || t.quality == _quality);

  /// One chip row per tag that actually varies across the results (e.g. beIN 1 / 2 / 3, AR / FR / EN).
  List<Widget> _filters(BuildContext context, Iterable<HitTags> tags) {
    List<String> values(String? Function(HitTags) f) {
      final v = {for (final t in tags) ?f(t)}.toList();
      v.sort((a, b) {
        final x = int.tryParse(a), y = int.tryParse(b);
        return x != null && y != null ? x.compareTo(y) : a.compareTo(b);
      });
      return v;
    }

    Widget row(String label, List<String> vals, String? sel, ValueChanged<String?> pick) => Row(children: [
          SizedBox(
            width: 84,
            child: Text(label.toUpperCase(),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: VyseColors.textFaint)),
          ),
          Expanded(
            child: SizedBox(
              height: 34,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                FilterChipPill(label: 'Tutti', selected: sel == null, onTap: () => pick(null)),
                for (final v in vals)
                  Padding(padding: const EdgeInsets.only(left: 4), child: FilterChipPill(label: v, selected: sel == v, onTap: () => pick(v))),
              ]),
            ),
          ),
        ]);

    final nums = values((t) => t.number), langs = values((t) => t.lang), qs = values((t) => t.quality);
    return [
      if (nums.length > 1) _pad(context, row('Channel', nums, _num, (v) => setState(() => _num = v)), bottom: 6),
      if (langs.length > 1) _pad(context, row('Language', langs, _lang, (v) => setState(() => _lang = v)), bottom: 6),
      if (qs.length > 1) _pad(context, row('Qualità', qs, _quality, (v) => setState(() => _quality = v)), bottom: 6),
      if (nums.length > 1 || langs.length > 1 || qs.length > 1) const SliverToBoxAdapter(child: SizedBox(height: 12)),
    ];
  }

  HardcodedChannel get ch => widget.channel;

  @override
  void initState() {
    super.initState();
    iptv.openHardcodedChannel(ch);
    if (_finder != null) iptv.addListener(_feed);
  }

  @override
  void dispose() {
    if (iptv.channelIsRunning) iptv.stopChannelSearch();
    iptv.removeListener(_feed);
    _finder?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([iptv, ?_finder]),
        builder: (context, _) {
          final all = iptv.activeHardcoded?.id == ch.id ? iptv.channelResults : const <ChannelHit>[];
          final tags = {for (final h in all) h: HitTags.of(h.stream.name)};
          final f = _finder;
          // Feeds showing the match go first, so Watch plays the right one.
          final hits = [for (final h in all) if (_matches(tags[h]!)) h]
            ..sort((a, b) => (f?.entryFor(b) != null ? 1 : 0) - (f?.entryFor(a) != null ? 1 : 0));
          final running = iptv.channelIsRunning;
          final items = [for (final h in hits) LiveItem.hit(h, channelName: ch.name)];
          return _LivePage(
            scroll: _scroll,
            title: ch.name,
            subtitle: '${ch.category}  ·  ${hits.isEmpty ? 'Search your portals for this channel' : '${all.length} sorgenti trovate'}',
            slivers: [
              _pad(
                context,
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (hits.isNotEmpty)
                    PillButton(primary: true, icon: Icons.play_arrow_rounded, label: 'Guarda', onTap: () => openLivePlayer(context, items, 0)),
                  ToolButton(icon: Icons.search_rounded, label: 'Cerca nei portali', onTap: running ? null : () => iptv.runChannelScan(ch)),
                  ToolButton(
                    icon: Icons.travel_explore_rounded,
                    label: 'Cerca più a fondo',
                    onTap: running ? null : () => iptv.runChannelScan(ch, scrapeMore: true),
                  ),
                  if (hits.isNotEmpty)
                    ToolButton(icon: Icons.clear_all_rounded, label: 'Cancella', danger: true, onTap: () => iptv.removeAllChannelHits(ch.id)),
                ]),
                bottom: 16,
              ),
              if (f != null) _pad(context, _MatchGuide(finder: f, sources: all.length, onPick: _pickGroup), bottom: 18),
              ..._filters(context, tags.values),
              if (running || iptv.channelStatus.isNotEmpty)
                _pad(context, StatusLine(text: iptv.channelStatus.isEmpty ? 'Ricerca…' : iptv.channelStatus, busy: running, onStop: running ? iptv.stopChannelSearch : null)),
              if (hits.isEmpty && !running)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.live_tv_rounded,
                    title: all.isEmpty ? 'Ancora nessuna sorgente' : 'Nessun risultato con questi filtri',
                    body: iptv.verified.isEmpty ? 'Aggiungi un portale nella scheda Portali, poi cerca di nuovo.' : 'Cerca nei tuoi portali uno stream per ${ch.name}.',
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 0),
                  sliver: SliverList.builder(
                    itemCount: hits.length,
                    itemBuilder: (context, i) => FadeSlideIn(
                      delay: Duration(milliseconds: 20 * (i % 14)),
                      offset: 6,
                      child: _HitRow(channelId: ch.id, hit: hits[i], guide: f?.entryFor(hits[i]), onTap: () => openLivePlayer(context, items, i)),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  void _pickGroup(String key) {
    final [n, lang] = key.split('|');
    setState(() {
      _num = n.isEmpty ? null : n;
      _lang = lang.isEmpty ? null : lang;
    });
  }
}

/// "On beIN Sports 2 · AR" panel above the sources, filled in as the TV guides come back.
class _MatchGuide extends StatelessWidget {
  const _MatchGuide({required this.finder, required this.sources, required this.onPick});
  final MatchFinder finder;
  final int sources;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final m = finder.match;
    final found = finder.hits;
    final busy = finder.busy || (sources == 0 && iptv.channelIsRunning);
    final String status;
    if (found.isNotEmpty) {
      status = 'Trasmette questa partita';
    } else if (busy) {
      status = finder.total == 0 ? 'Ricerca dei canali…' : 'Lettura delle guide TV  ${finder.checked}/${finder.total}';
    } else if (sources == 0) {
      status = 'Cerca nei tuoi portali i canali di questa partita';
    } else {
      status = "Non trovata nelle guide TV. Di solito è su uno dei canali qui sotto.";
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: VyseColors.pick(0xFF0D0F18, 0xFFF7F8FC), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (m.leagueLogo != null) ...[TeamBadge(url: m.leagueLogo, size: 18), const SizedBox(width: 8)],
          Expanded(
            child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          if (m.state == MatchState.live)
            LivePill(m.status)
          else
            Text(hhmm(m.start), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          if (busy && found.isEmpty) ...[
            SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: VyseColors.textDim)),
            const SizedBox(width: 8),
          ] else if (found.isNotEmpty) ...[
            Icon(Icons.check_circle_rounded, size: 14, color: VyseColors.accent),
            const SizedBox(width: 6),
          ],
          Expanded(child: Text(status, style: TextStyle(fontSize: 12, color: VyseColors.textDim))),
        ]),
        if (found.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (key, label, entry) in found)
              Tooltip(
                message: '${entry.title}  ·  ${hhmm(entry.start)}–${hhmm(entry.stop)}',
                child: FilterChipPill(label: label, icon: Icons.live_tv_rounded, selected: true, onTap: () => onPick(key)),
              ),
          ]),
        ],
      ]),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.channelId, required this.hit, required this.onTap, this.guide});
  final String channelId;
  final ChannelHit hit;
  final EpgEntry? guide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fav = iptv.isFavoriteHit(channelId, hit);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: VyseColors.ink.withValues(alpha: hovered ? .06 : 0),
          ),
          child: Row(children: [
            Container(
              width: 56,
              height: 38,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: VyseColors.surfaceHi, borderRadius: BorderRadius.circular(7)),
              child: NetImage(url: hit.stream.icon, fit: BoxFit.contain, fallback: Icons.live_tv_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(hit.stream.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(hit.portal.name.isEmpty ? hit.portal.portal.url : hit.portal.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: VyseColors.textDim)),
                if (guide != null) ...[
                  const SizedBox(height: 3),
                  Text('In onda  ${guide!.title}  ·  ${hhmm(guide!.start)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: VyseColors.accent)),
                ],
              ]),
            ),
            IconButton(
              tooltip: fav ? 'Togli la sorgente dai preferiti' : 'Sorgente preferita',
              onPressed: () => iptv.toggleFavoriteHit(hit),
              icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded, color: fav ? VyseColors.star : VyseColors.textFaint),
            ),
            Icon(Icons.play_circle_outline_rounded, color: hovered ? VyseColors.accent : VyseColors.textFaint),
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}

// The portal browser lives in portal_browser_page.dart.

// ───────────────────────── Series episodes ─────────────────────────

class SeriesPage extends StatefulWidget {
  const SeriesPage({super.key, required this.portal, required this.series});
  final VerifiedPortal portal;
  final IptvStream series;

  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  final _scroll = ScrollController();
  late Future<List<IptvEpisode>> _future = fetchSeriesEpisodes(widget.portal, widget.series);
  int? _season;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<IptvEpisode>>(
        future: _future,
        builder: (context, snap) {
          final all = snap.data ?? const <IptvEpisode>[];
          final seasons = {for (final e in all) e.season}.toList()..sort();
          final season = _season ?? seasons.firstOrNull;
          final eps = all.where((e) => e.season == season).toList();
          final items = [for (final e in eps) LiveItem.episode(widget.portal, widget.series, e)];
          return _LivePage(
            scroll: _scroll,
            title: widget.series.name,
            subtitle: all.isEmpty ? widget.portal.name : '${seasons.length} stagioni  ·  ${all.length} episodi',
            slivers: [
              if (seasons.length > 1)
                _pad(
                  context,
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in seasons) FilterChipPill(label: 'Stagione $s', selected: s == season, onTap: () => setState(() => _season = s)),
                  ]),
                ),
              if (snap.hasError)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.wifi_off_rounded,
                    title: "Impossibile caricare gli episodi",
                    body: 'Il portale non ha risposto. Riprova.',
                    action: ('Riprova', () => setState(() { _future = fetchSeriesEpisodes(widget.portal, widget.series); })),
                  ),
                )
              else if (!snap.hasData)
                _pad(context, Shimmer(child: Column(children: [for (var i = 0; i < 6; i++) const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(width: double.infinity, height: 84))])))
              else if (eps.isEmpty)
                const SliverToBoxAdapter(child: EmptyState(icon: Icons.video_library_outlined, title: 'Nessun episodio', body: 'Questa serie non ha episodi su questo portale.'))
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 0),
                  sliver: SliverList.builder(
                    itemCount: eps.length,
                    itemBuilder: (context, i) => _EpisodeRow(episode: eps[i], fallbackImage: widget.series.icon, onTap: () => openLivePlayer(context, items, i)),
                  ),
                ),
            ],
          );
        },
      );
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.episode, required this.fallbackImage, required this.onTap});
  final IptvEpisode episode;
  final String fallbackImage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Pressable(
          onTap: onTap,
          builder: (context, hovered, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: VyseColors.ink.withValues(alpha: hovered ? .06 : 0),
            ),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 64,
                  child: Stack(fit: StackFit.expand, children: [
                    NetImage(url: episode.image.isNotEmpty ? episode.image : fallbackImage, fallback: Icons.movie_outlined),
                    if (hovered) const ColoredBox(color: Color(0x66000000), child: Icon(Icons.play_arrow_rounded, size: 30)),
                  ]),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('E${episode.episode}  ${episode.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  if (episode.plot.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(episode.plot, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: VyseColors.textDim, height: 1.4)),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      );
}

// ───────────────────────── M3U playlist ─────────────────────────

class M3uPlaylistPage extends StatefulWidget {
  const M3uPlaylistPage({super.key, required this.playlist});
  final M3uPlaylist playlist;

  @override
  State<M3uPlaylistPage> createState() => _M3uPlaylistPageState();
}

class _M3uPlaylistPageState extends State<M3uPlaylistPage> {
  final _scroll = ScrollController();
  final _text = TextEditingController();
  String? _group;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pl = widget.playlist;
    final groups = <String>{for (final c in pl.channels) if (c.group.isNotEmpty) c.group}.toList()..sort();
    final q = _text.text.trim().toLowerCase();
    final list = [
      for (final c in pl.channels)
        if ((_group == null || c.group == _group) && (q.isEmpty || c.name.toLowerCase().contains(q))) c,
    ];
    final items = [for (final c in list) LiveItem.m3u(c, playlist: pl.name)];
    return _LivePage(
      scroll: _scroll,
      title: pl.name,
      subtitle: '${pl.channels.length} channels${groups.isEmpty ? '' : '  ·  ${groups.length} groups'}',
      slivers: [
        _pad(context, _Filter(controller: _text, hint: 'Filtra canali')),
        if (groups.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(left: Layout.inset(context), right: pageRight(context)),
                  itemCount: groups.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => i == 0
                      ? FilterChipPill(label: 'Tutti', selected: _group == null, onTap: () => setState(() => _group = null))
                      : FilterChipPill(label: groups[i - 1], selected: _group == groups[i - 1], onTap: () => setState(() => _group = groups[i - 1])),
                ),
              ),
            ),
          ),
        if (list.isEmpty)
          const SliverToBoxAdapter(child: EmptyState(icon: Icons.search_off_rounded, title: 'Nessun risultato', body: 'Prova un altro gruppo o filtro.'))
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 0),
            sliver: captionedGrid(
              maxWidth: _tileW(context),
              aspect: .62,
              caption: 26,
              itemCount: list.length,
              itemBuilder: (context, i) => StreamCard(name: list[i].name, image: list[i].logo, onTap: () => openLivePlayer(context, items, i)),
            ),
          ),
      ],
    );
  }
}
