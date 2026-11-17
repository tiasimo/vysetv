import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../media_servers/media_servers.dart';
import '../../media_servers/server_playback.dart';
import '../../plezy/media/media_item.dart';
import '../../plezy/media/media_kind.dart';
import '../../plezy/media/media_server_client.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import 'server_widgets.dart';

/// A film or a show: backdrop, what it is, Play / Resume, watched, and for shows every season
/// and episode. Seasons and episodes open on their show, at their season.
class ServerItemPage extends StatefulWidget {
  const ServerItemPage({super.key, required this.server, required this.item});
  final MediaServer server;
  final MediaItem item;

  @override
  State<ServerItemPage> createState() => _ServerItemPageState();
}

class _ServerItemPageState extends State<ServerItemPage> {
  final _scroll = ScrollController();
  late final Future<MediaServerClient> _client = MediaServers.instance.client(widget.server);
  MediaServerClient? _c;

  MediaItem? _title; // the film or show
  MediaItem? _next; // a show's next episode to watch
  String? _error;

  List<MediaItem>? _seasons;
  int? _seasonIndex; // index into _seasons
  final _episodes = <String, Future<List<MediaItem>>>{};
  final _watched = <String, bool>{}; // marked here, before the server says so
  bool _expanded = false;
  bool _marking = false;

  MediaServer get server => widget.server;

  /// The show or film this page is about.
  String get _titleId => switch (widget.item.kind) {
    MediaKind.episode => widget.item.grandparentId ?? widget.item.id,
    MediaKind.season => widget.item.parentId ?? widget.item.id,
    _ => widget.item.id,
  };

  @override
  void initState() {
    super.initState();
    ServerPlayback.ended.addListener(_afterWatching);
    _load();
  }

  @override
  void dispose() {
    ServerPlayback.ended.removeListener(_afterWatching);
    _scroll.dispose();
    super.dispose();
  }

  /// A show's seasons: real seasons first, specials last.
  static Future<List<MediaItem>> _seasonsOf(MediaServerClient c, MediaItem show) async {
    final seasons = (await c.fetchChildren(show.id)).where((s) => s.kind == MediaKind.season).toList();
    seasons.sort((a, b) => (a.index ?? 0) == 0 ? 1 : ((b.index ?? 0) == 0 ? -1 : (a.index ?? 0).compareTo(b.index ?? 0)));
    return seasons;
  }

  static Future<List<MediaItem>> _fetchEpisodes(MediaServerClient c, MediaItem season) =>
      c.fetchChildren(season.id).then((l) => l.where((e) => e.kind == MediaKind.episode).toList());

  /// A player that was playing from a server has closed: your place, the next episode and the
  /// watched ticks are fetched again. Nothing on the page blanks while they are, and what's
  /// there stays if the server doesn't answer.
  Future<void> _afterWatching() async {
    final c = _c;
    if (c == null || _title == null || !mounted) return; // not loaded yet: the first load is still to come
    final seasonId = _seasons != null && _seasonIndex != null && _seasonIndex! < _seasons!.length ? _seasons![_seasonIndex!].id : null;
    try {
      final r = await c.fetchItemWithOnDeck(_titleId);
      final title = r.item ?? (await c.fetchItem(_titleId));
      if (title == null) return;
      final seasons = title.kind == MediaKind.show ? await _seasonsOf(c, title) : null;
      // the season that's open, read again; the others are read again when they're opened
      final open = seasons?.where((s) => s.id == seasonId).firstOrNull;
      final episodes = open == null ? null : await _fetchEpisodes(c, open);
      if (!mounted) return;
      final shown = _seasons != null && _seasonIndex != null && _seasonIndex! < _seasons!.length ? _seasons![_seasonIndex!].id : null;
      setState(() {
        _title = title;
        _next = r.onDeckEpisode;
        _watched.clear();
        _episodes.clear();
        if (open != null && episodes != null) _episodes[open.id] = Future.value(episodes);
        if (seasons != null) {
          // you may have picked another season while this was loading: stay on it
          final i = seasons.indexWhere((s) => s.id == shown);
          _seasons = seasons;
          _seasonIndex = seasons.isEmpty ? null : math.max(0, i);
        }
      });
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = _c = await _client;
      final r = await c.fetchItemWithOnDeck(_titleId);
      final title = r.item ?? (await c.fetchItem(_titleId));
      if (title == null) throw StateError('Questo titolo non è più sul server');
      if (!mounted) return;
      setState(() {
        _title = title;
        _next = r.onDeckEpisode;
      });
      if (title.kind == MediaKind.show) {
        final seasons = await _seasonsOf(c, title);
        final want = switch (widget.item.kind) {
          MediaKind.season => widget.item.index,
          MediaKind.episode => widget.item.parentIndex,
          _ => r.onDeckEpisode?.parentIndex,
        };
        var i = want == null ? -1 : seasons.indexWhere((s) => s.index == want);
        if (i < 0) i = seasons.indexWhere((s) => !s.isWatched && (s.index ?? 0) > 0);
        if (!mounted) return;
        setState(() {
          _seasons = seasons;
          _seasonIndex = seasons.isEmpty ? null : math.max(0, i);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = serverError(e));
    }
  }

  Future<List<MediaItem>> _episodesOf(MediaItem season) => _episodes.putIfAbsent(
    season.id,
    () => _fetchEpisodes(_c!, season).catchError((Object e) {
      _episodes.remove(season.id);
      throw e;
    }),
  );

  MediaItem _shown(MediaItem m) => _watched.containsKey(m.id) ? m.withWatchedFlag(_watched[m.id]!) : m;

  Future<void> _toggleWatched(MediaItem m) async {
    final c = _c;
    if (c == null || _marking) return;
    final now = !_shown(m).isWatched;
    setState(() {
      _marking = true;
      _watched[m.id] = now;
    });
    final ok = await tryServer(context, () => now ? c.markWatched(m) : c.markUnwatched(m));
    if (!mounted) return;
    setState(() {
      _marking = false;
      if (!ok) _watched.remove(m.id);
    });
    if (ok && m.kind != MediaKind.episode) {
      // a whole show or season changes its episodes too
      _episodes.clear();
      _watched.removeWhere((id, _) => id != m.id);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _title;
    final c = _c;
    final phone = Layout.isPhone(context);
    final size = MediaQuery.sizeOf(context);
    final backdropH = phone ? 300.0 : math.max(size.height * .66, 420.0);
    final inset = Layout.inset(context);
    final right = pageRight(context);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        // backdrop, fading into the page
        if (title != null && c != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: backdropH,
            child: FadeSlideIn(
              offset: 0,
              child: Stack(fit: StackFit.expand, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1.06, end: 1),
                  duration: const Duration(milliseconds: 1800),
                  curve: Curves.easeOutCubic,
                  builder: (context, s, child) => Transform.scale(scale: s, child: child),
                  child: serverImage(c.backdropOf(title), alignment: Alignment.topCenter),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x6607080F), VyseColors.pick(0x0007080F, 0x00F4F5FA), Color(0xCC07080F), VyseColors.bg],
                      stops: [0, .25, .78, 1],
                    ),
                  ),
                ),
                if (!phone)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [VyseColors.pick(0xE607080F, 0xE6F4F5FA), VyseColors.pick(0x0007080F, 0x00F4F5FA)], stops: [0, .65]),
                    ),
                  ),
              ]),
            ),
          ),
        CustomScrollView(controller: _scroll, slivers: [
          SliverToBoxAdapter(child: SizedBox(height: Layout.topChrome(context) + (phone ? 8 : 24))),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
            sliver: SliverToBoxAdapter(
              child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())),
            ),
          ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 80),
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: "Impossibile aprirlo",
                  body: _error!,
                  action: ('Riprova', _load),
                ),
              ),
            )
          else if (title == null || c == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(inset, backdropH * .42, right, 0),
                child: const Shimmer(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SkeletonBox(width: 380, height: 44, radius: 10),
                    SizedBox(height: 16),
                    SkeletonBox(width: 260, height: 14, radius: 6),
                    SizedBox(height: 22),
                    SkeletonBox(width: 300, height: 46, radius: 12),
                  ]),
                ),
              ),
            )
          else ...[
            SliverToBoxAdapter(child: SizedBox(height: phone ? backdropH * .42 : backdropH * .3)),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
              sliver: SliverToBoxAdapter(child: FadeSlideIn(offset: 14, child: _info(c, _shown(title), phone))),
            ),
            if (_seasons != null && _seasons!.isNotEmpty) ..._seasonSlivers(c, inset, right, phone),
          ],
          SliverToBoxAdapter(child: SizedBox(height: pageBottom(context) + 20)),
        ]),
      ]),
    );
  }

  Widget _info(MediaServerClient c, MediaItem t, bool phone) {
    final isShow = t.kind == MediaKind.show;
    final logo = c.art(t.clearLogoPath, width: 800);
    final p = progressOf(t);
    final next = _next;
    final seasons = _seasons?.where((s) => (s.index ?? 0) > 0).length;
    final meta = <String>[
      ?t.year?.toString(),
      if (isShow && seasons != null && seasons > 0) seasons == 1 ? '1 stagione' : '$seasons stagioni',
      if (!isShow && t.durationMs != null) lengthNote(t.copyWith(viewOffsetMs: null)) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    final rating = t.rating;
    final genres = t.genres ?? const [];

    final String playLabel;
    if (isShow) {
      final code = next == null ? null : episodeCode(next);
      playLabel = next == null ? 'Riproduci' : '${progressOf(next) != null ? 'Resume' : 'Riproduci'} ${code ?? ''}'.trim();
    } else {
      playLabel = p != null ? 'Riprendi' : 'Riproduci';
    }

    final poster = c.posterOf(t, width: 500);
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: phone ? 300 : 520, maxHeight: phone ? 90 : 140),
        child: logo != null
            ? Align(alignment: Alignment.centerLeft, child: serverImage(logo, fit: BoxFit.contain, alignment: Alignment.centerLeft))
            : Text(
                t.title ?? '',
                style: TextStyle(fontSize: phone ? 30 : 46, height: 1.02, fontWeight: FontWeight.w900, letterSpacing: -1),
              ),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final m in meta) Text(m, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
        if (t.contentRating != null && t.contentRating!.isNotEmpty) _Tag(t.contentRating!),
        if (rating != null && rating > 0)
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.star_rounded, size: 16, color: VyseColors.star),
            const SizedBox(width: 3),
            Text(rating.toStringAsFixed(1), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ]),
        if (t.isWatched) const _Tag('Visto', accent: true),
      ]),
      const SizedBox(height: 20),
      Wrap(spacing: 10, runSpacing: 10, children: [
        PillButton(label: playLabel, icon: Icons.play_arrow_rounded, primary: true, onTap: () => playFromServer(context, server, isShow && next != null ? next : t)),
        if (!isShow && p != null)
          PillButton(label: 'Dall\'inizio', icon: Icons.replay_rounded, onTap: () => playFromServer(context, server, t, fromStart: true)),
        _WatchedButton(watched: t.isWatched, busy: _marking, onTap: () => _toggleWatched(t)),
      ]),
      if (p != null && !isShow) ...[
        const SizedBox(height: 14),
        SizedBox(width: 300, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: ThinProgress(p))),
        const SizedBox(height: 4),
        Text(lengthNote(t) ?? '', style: TextStyle(fontSize: 12, color: VyseColors.textFaint, fontWeight: FontWeight.w600)),
      ],
      if (isShow && next != null) ...[
        const SizedBox(height: 10),
        Text(
          'Up next: ${next.title ?? episodeCode(next) ?? ''}',
          style: TextStyle(fontSize: 12.5, color: VyseColors.textFaint, fontWeight: FontWeight.w700),
        ),
      ],
      if ((t.tagline ?? '').isNotEmpty) ...[
        const SizedBox(height: 22),
        Text(t.tagline!, style: TextStyle(fontSize: 15, fontStyle: FontStyle.italic, color: VyseColors.text, fontWeight: FontWeight.w600)),
      ],
      if ((t.summary ?? '').isNotEmpty) ...[
        SizedBox(height: (t.tagline ?? '').isNotEmpty ? 8 : 22),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Pressable(
            onTap: () => setState(() => _expanded = !_expanded),
            builder: (context, hovered, _) => AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: Text(
                t.summary!,
                maxLines: _expanded ? null : 4,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14.5, height: 1.55, color: hovered ? VyseColors.text : VyseColors.textDim),
              ),
            ),
          ),
        ),
      ],
      if (genres.isNotEmpty) ...[
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final g in genres.take(5)) _Tag(g)]),
      ],
      if ((t.directors ?? const []).isNotEmpty) ...[
        const SizedBox(height: 14),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Regia di  ', style: TextStyle(color: VyseColors.textFaint)),
            TextSpan(text: t.directors!.take(3).join(', '), style: TextStyle(color: VyseColors.text)),
          ]),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
      if ((t.studio ?? '').isNotEmpty) ...[
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: isShow ? 'Rete  ' : 'Studio  ', style: TextStyle(color: VyseColors.textFaint)),
            TextSpan(text: t.studio, style: TextStyle(color: VyseColors.text)),
          ]),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    ]);

    if (phone || poster == null) return details;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Container(
        width: 210,
        height: 315,
        margin: const EdgeInsets.only(right: 34),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 40, offset: const Offset(0, 18))],
        ),
        clipBehavior: Clip.antiAlias,
        child: serverImage(poster),
      ),
      Expanded(child: details),
    ]);
  }

  List<Widget> _seasonSlivers(MediaServerClient c, double inset, double right, bool phone) {
    final seasons = _seasons!;
    final i = (_seasonIndex ?? 0).clamp(0, seasons.length - 1);
    final season = seasons[i];
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 44, right, 14),
        sliver: SliverToBoxAdapter(
          child: Row(children: [
            const Text('Episodi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -.3)),
            const Spacer(),
            if (seasons.isNotEmpty)
              _WatchedButton(
                watched: _shown(season).isWatched,
                busy: _marking,
                compact: true,
                label: _shown(season).isWatched ? 'Stagione vista' : 'Segna la stagione come vista',
                onTap: () => _toggleWatched(season),
              ),
          ]),
        ),
      ),
      if (seasons.length > 1)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(left: inset, right: right),
              itemCount: seasons.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, j) {
                final s = seasons[j];
                return FilterChipPill(
                  label: s.title ?? ((s.index ?? 0) == 0 ? 'Speciali' : 'Stagione ${s.index}'),
                  selected: j == i,
                  icon: _shown(s).isWatched ? Icons.check_rounded : null,
                  onTap: () => setState(() => _seasonIndex = j),
                );
              },
            ),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 18, right, 0),
        sliver: FutureBuilder<List<MediaItem>>(
          key: ValueKey(season.id),
          future: _episodesOf(season),
          builder: (context, snap) {
            if (snap.hasError) {
              return SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: "Impossibile caricare gli episodi",
                  body: serverError(snap.error!),
                  action: ('Riprova', () => setState(() => _episodes.remove(season.id))),
                ),
              );
            }
            final eps = snap.data;
            if (eps == null) {
              return SliverList.separated(
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(height: 14),
                itemBuilder: (_, _) => Shimmer(
                  child: Row(children: [
                    SkeletonBox(width: phone ? 140 : 220, height: (phone ? 140 : 220) * 9 / 16, radius: 10),
                    const SizedBox(width: 16),
                    const Expanded(child: SkeletonBox(width: double.infinity, height: 16, radius: 6)),
                  ]),
                ),
              );
            }
            if (eps.isEmpty) {
              return SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Text('Ancora nessun episodio in questa stagione.', style: TextStyle(color: VyseColors.textFaint)),
                ),
              );
            }
            return SliverList.separated(
              itemCount: eps.length,
              separatorBuilder: (_, _) => SizedBox(height: phone ? 12 : 8),
              itemBuilder: (context, j) => FadeSlideIn(
                delay: Duration(milliseconds: 30 * math.min(j, 12)),
                offset: 8,
                child: _EpisodeRow(
                  client: c,
                  episode: _shown(eps[j]),
                  highlight: eps[j].id == (_next?.id ?? (widget.item.kind == MediaKind.episode ? widget.item.id : null)),
                  phone: phone,
                  onPlay: () => playFromServer(context, server, eps[j]),
                  onWatched: () => _toggleWatched(eps[j]),
                ),
              ),
            );
          },
        ),
      ),
    ];
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.accent = false});
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(7),
      color: accent ? VyseColors.accent.withValues(alpha: .16) : VyseColors.ink.withValues(alpha: .07),
      border: Border.all(color: accent ? VyseColors.accent.withValues(alpha: .4) : VyseColors.ink.withValues(alpha: .1)),
    ),
    child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: accent ? VyseColors.accent : VyseColors.text)),
  );
}

class _WatchedButton extends StatelessWidget {
  const _WatchedButton({required this.watched, required this.busy, required this.onTap, this.compact = false, this.label});
  final bool watched;
  final bool busy;
  final bool compact;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: busy ? null : onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : (hovered ? 1.03 : 1),
      duration: const Duration(milliseconds: 160),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: compact ? 36 : 46,
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 10 : 12),
          color: watched ? VyseColors.accent.withValues(alpha: hovered ? .26 : .18) : VyseColors.ink.withValues(alpha: hovered ? .2 : .1),
          border: Border.all(color: watched ? VyseColors.accent.withValues(alpha: .5) : VyseColors.ink.withValues(alpha: .14)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
            child: Icon(
              watched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
              key: ValueKey(watched),
              size: compact ? 16 : 19,
              color: watched ? VyseColors.accent : VyseColors.text,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label ?? (watched ? 'Visto' : 'Segna come visto'),
            style: TextStyle(fontSize: compact ? 12.5 : 14, fontWeight: FontWeight.w800, color: watched ? VyseColors.accent : VyseColors.text),
          ),
        ]),
      ),
    ),
  );
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.client,
    required this.episode,
    required this.highlight,
    required this.phone,
    required this.onPlay,
    required this.onWatched,
  });
  final MediaServerClient client;
  final MediaItem episode;
  final bool highlight;
  final bool phone;
  final VoidCallback onPlay;
  final VoidCallback onWatched;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final p = progressOf(e);
    final thumbW = phone ? 140.0 : 220.0;
    final aired = DateTime.tryParse(e.originallyAvailableAt ?? '');
    final sub = [
      ?lengthNote(e),
      if (aired != null) _date(aired),
    ].join('  ·  ');
    return Pressable(
      onTap: onPlay,
      builder: (context, hovered, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: highlight
              ? VyseColors.accent.withValues(alpha: hovered ? .12 : .07)
              : VyseColors.ink.withValues(alpha: hovered ? .05 : 0),
          border: Border.all(color: highlight ? VyseColors.accent.withValues(alpha: .3) : Colors.transparent),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: thumbW,
            height: thumbW * 9 / 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(fit: StackFit.expand, children: [
                AnimatedScale(
                  scale: hovered ? 1.05 : 1,
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  child: serverImage(client.wideOf(e, width: 480), icon: Icons.tv_rounded),
                ),
                AnimatedContainer(duration: const Duration(milliseconds: 180), color: Colors.black.withValues(alpha: hovered ? .3 : 0)),
                Center(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: const Icon(Icons.play_circle_fill_rounded, size: 40, color: Colors.white),
                  ),
                ),
                if (e.isWatched)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: VyseColors.accent, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 12, color: Colors.black),
                    ),
                  ),
                if (p != null) Positioned(left: 0, right: 0, bottom: 0, child: ThinProgress(p)),
              ]),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      '${e.index != null ? '${e.index}.  ' : ''}${e.title ?? 'Episode'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: phone ? 14 : 15.5, fontWeight: FontWeight.w800, color: e.isWatched ? VyseColors.textDim : VyseColors.text),
                    ),
                  ),
                  if (!phone)
                    Tooltip(
                      message: e.isWatched ? 'Segna come non visto' : 'Segna come visto',
                      child: Pressable(
                        onTap: onWatched,
                        builder: (context, h, _) => Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            e.isWatched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
                            size: 20,
                            color: e.isWatched ? VyseColors.accent : (h ? VyseColors.text : VyseColors.textFaint),
                          ),
                        ),
                      ),
                    ),
                ]),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(sub, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textFaint)),
                ],
                if ((e.summary ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    e.summary!,
                    maxLines: phone ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, height: 1.45, color: VyseColors.textDim),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  static String _date(DateTime d) {
    const months = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
