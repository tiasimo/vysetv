import 'dart:async';

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/match_finder.dart';
import '../data/sports_schedule.dart';
import '../widgets/common.dart';
import '../widgets/live_tv_widgets.dart';
import '../widgets/match_widgets.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'live_tv_pages.dart';

const _weekdays = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];
const _months = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];

/// Live TV → Matches: pick a day and a sport, see every fixture by league with where it's on.
class MatchesView extends StatefulWidget {
  const MatchesView({super.key});

  @override
  State<MatchesView> createState() => _MatchesViewState();
}

class _MatchesViewState extends State<MatchesView> {
  static int _lastOffset = 0;
  static SportKind? _lastSport;

  late int _offset = _lastOffset;
  late SportKind? _sport = _lastSport;
  late Future<List<Match>> _future = SportsSchedule.day(_day);
  int _revision = 0;
  Timer? _tick;

  DateTime get _day {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day).add(Duration(days: _offset));
  }

  @override
  void initState() {
    super.initState();
    // Scores move: refresh every minute while anything is live.
    _tick = Timer.periodic(const Duration(seconds: 60), (_) async {
      final list = await _future;
      if (mounted && list.any((m) => m.state == MatchState.live)) {
        setState(() {
          _future = SportsSchedule.day(_day, refresh: true);
          _revision++;
        });
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _pickDay(int o) => setState(() {
        _offset = _lastOffset = o;
        _future = SportsSchedule.day(_day);
      });

  String _dayLabel(int o) {
    if (o == -1) return 'Ieri';
    if (o == 0) return 'Oggi';
    if (o == 1) return 'Domani';
    final d = DateTime.now().add(Duration(days: o));
    return '${_weekdays[d.weekday - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final phone = Layout.isPhone(context);
    final cardW = phone ? 260.0 : (MediaQuery.sizeOf(context).width * .2).clamp(280.0, 360.0);
    final cardH = cardW * .58;

    return FutureBuilder<List<Match>>(
      future: _future,
      builder: (context, snap) {
        final all = snap.data ?? const <Match>[];
        final sports = {for (final m in all) m.league.sport};
        final list = [for (final m in all) if (_sport == null || m.league.sport == _sport) m];
        final live = [for (final m in list) if (m.state == MatchState.live) m];
        final byLeague = <League, List<Match>>{};
        for (final l in leagues) {
          final ms = [for (final m in list) if (m.league == l) m];
          if (ms.isNotEmpty) byLeague[l] = ms;
        }

        Widget shelf(String title, List<Match> ms, String key) => Shelf<Match>(
              key: ValueKey('$key/$_offset/${_sport?.name}/$_revision/${ms.length}'),
              title: title,
              load: () async => ms,
              itemWidth: cardW,
              itemHeight: cardH,
              maxItems: 60,
              itemBuilder: (context, m, _) => MatchCard(
                match: m,
                onTap: () => Navigator.of(context).push(ShellRoute(child: MatchPage(match: m))),
              ),
            );

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 36,
            child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.only(left: inset, right: right), children: [
              for (var o = -1; o <= 6; o++)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FilterChipPill(label: _dayLabel(o), selected: _offset == o, onTap: () => _pickDay(o)),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          if (sports.length > 1)
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.only(left: inset, right: right), children: [
                FilterChipPill(label: 'Tutti gli sport', selected: _sport == null, onTap: () => setState(() => _sport = _lastSport = null)),
                for (final s in SportKind.values)
                  if (sports.contains(s))
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FilterChipPill(
                        label: s.label,
                        icon: s.icon,
                        selected: _sport == s,
                        onTap: () => setState(() => _sport = _lastSport = s),
                      ),
                    ),
              ]),
            ),
          const SizedBox(height: 22),
          if (snap.connectionState == ConnectionState.waiting && all.isEmpty)
            for (var i = 0; i < 3; i++)
              Shelf<Match>(
                key: ValueKey('skeleton/$i/$_offset'),
                title: ' ',
                load: () => Completer<List<Match>>().future,
                itemWidth: cardW,
                itemHeight: cardH,
                itemBuilder: (_, _, _) => const SizedBox.shrink(),
              )
          else if (list.isEmpty)
            EmptyState(
              icon: Icons.event_busy_rounded,
              title: snap.hasError ? "Impossibile caricare il calendario" : 'Nessuna partita ${_dayLabel(_offset).toLowerCase()}',
              body: snap.hasError ? 'Controlla la connessione e riprova.' : 'Prova un altro giorno o sport.',
              action: snap.hasError ? ('Riprova', () => _pickDay(_offset)) : null,
            )
          else ...[
            if (live.isNotEmpty) shelf('In diretta ora', live, 'live'),
            for (final e in byLeague.entries) shelf(e.key.name, e.value, e.key.path),
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 4, right, 0),
              child: const Text('Calendari e palinsesti USA da ESPN. Canali internazionali aggiunti da Lorewatch.',
                  style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
            ),
          ],
        ]);
      },
    );
  }
}

/// One fixture: crests and score up top, then every channel it's on. Tapping a channel searches
/// your portals for it, same as picking it from Channels.
class MatchPage extends StatefulWidget {
  const MatchPage({super.key, required this.match});
  final Match match;

  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);
    final channels = m.channels;
    final tileW = phone ? 230.0 : (MediaQuery.sizeOf(context).width * .2).clamp(250.0, 340.0);
    final when = '${_weekdays[m.start.weekday - 1]} ${m.start.day} ${_months[m.start.month - 1]}  ·  ${hhmm(m.start)}';

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset - 8, top, right, 18),
              sliver: SliverToBoxAdapter(
                child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 34),
              sliver: SliverToBoxAdapter(
                child: FadeSlideIn(
                  offset: 12,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      if (m.leagueLogo != null) ...[TeamBadge(url: m.leagueLogo, size: 20), const SizedBox(width: 8)],
                      Text(m.league.name, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 10),
                      if (m.state == MatchState.live) LivePill(m.status),
                    ]),
                    const SizedBox(height: 22),
                    if (m.hasTeams)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Row(children: [
                          Expanded(child: _BigSide(team: m.home!)),
                          Column(children: [
                            Text(
                              m.state == MatchState.upcoming ? hhmm(m.start) : '${m.home!.score ?? '-'}  –  ${m.away!.score ?? '-'}',
                              style: TextStyle(
                                fontSize: phone ? 30 : 44,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(m.state == MatchState.upcoming ? 'Calcio d\'inizio' : m.status,
                                style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                          ]),
                          Expanded(child: _BigSide(team: m.away!)),
                        ]),
                      )
                    else
                      Text(m.name, style: TextStyle(fontSize: phone ? 26 : 38, fontWeight: FontWeight.w800, letterSpacing: -1.1, height: 1.05)),
                    const SizedBox(height: 18),
                    Text([when, ?m.venue].join('  ·  '), style: const TextStyle(fontSize: 13, color: Color(0xFFC3C7D4))),
                  ]),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: ShelfHeader(title: 'Dove vederla')),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 4, right, 0),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: tileW,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 10,
                  childAspectRatio: 16 / 9,
                ),
                itemCount: channels.length,
                itemBuilder: (context, i) => FadeSlideIn(
                  delay: Duration(milliseconds: 30 * i),
                  offset: 8,
                  child: Stack(children: [
                    Positioned.fill(
                      child: ChannelTile(
                        channel: channels[i],
                        onTap: () => Navigator.of(context).push(ShellRoute(child: LiveChannelPage(channel: channels[i], match: m))),
                      ),
                    ),
                    // Once a channel's TV guides have been read, name the exact feed.
                    ValueListenableBuilder(
                      valueListenable: MatchFinder.found,
                      builder: (context, found, _) {
                        final exact = found[m.id]?[channels[i].id];
                        if (exact == null || exact.isEmpty) return const SizedBox.shrink();
                        return Positioned(
                          left: 8,
                          bottom: 8,
                          right: 8,
                          child: IgnorePointer(
                            child: Wrap(spacing: 4, runSpacing: 4, children: [
                              for (final l in exact.take(3))
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: .78), borderRadius: BorderRadius.circular(5)),
                                  child: Text(l, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white)),
                                ),
                            ]),
                          ),
                        );
                      },
                    ),
                  ]),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 16, right, 0),
              sliver: const SliverToBoxAdapter(
                child: Text('Scegli un canale e Lorewatch cerca nei tuoi portali, poi legge le loro guide TV per trovare il canale esatto (beIN Sports 2, AR…).',
                    style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }
}

class _BigSide extends StatelessWidget {
  const _BigSide({required this.team});
  final Team team;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    return Column(children: [
      TeamBadge(url: team.logo, size: phone ? 64 : 96),
      const SizedBox(height: 12),
      Text(team.name,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: phone ? 14 : 17, fontWeight: FontWeight.w800)),
    ]);
  }
}
