import 'dart:ui' show PathMetric;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/anilist.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import 'player_menus.dart';
import 'player_page.dart' show PlayerEpisode;

class EpisodeInfo {
  const EpisodeInfo(this.season, this.number, this.name, this.overview, this.still, this.runtime, this.aired);
  final int season;
  final int number;
  final String name;
  final String overview;
  final String? still;
  final int? runtime;
  final DateTime? aired;

  factory EpisodeInfo.fromJson(int season, Map<String, dynamic> j) => EpisodeInfo(
    season,
    j['episode_number'] as int,
    (j['name'] as String?)?.trim().isNotEmpty == true ? j['name'] as String : 'Episode ${j['episode_number']}',
    (j['overview'] as String?) ?? '',
    j['still_path'] as String?,
    (j['runtime'] as num?)?.toInt(),
    DateTime.tryParse((j['air_date'] as String?) ?? ''),
  );

  bool get upcoming => aired != null && aired!.isAfter(DateTime.now());
  String? stillUrl([String size = 'w300']) => still == null ? null : (still!.startsWith('http') ? still : 'https://image.tmdb.org/t/p/$size$still');
  PlayerEpisode toPlayer() => PlayerEpisode(season: season, number: number, name: name, runtime: runtime);
}

/// Seasons and episodes of one show, fetched once per player.
class EpisodeStore {
  EpisodeStore(this.show);
  final Media show;
  final _seasons = <int, Future<List<EpisodeInfo>>>{};

  /// Real seasons first, specials (season 0) last.
  late final Future<List<Season>> seasons = HomeFeed.instance.details(show).then((d) {
    final list = [for (final s in d.seasons) if (s.episodes > 0) s];
    list.sort((a, b) => a.number == 0 ? 1 : (b.number == 0 ? -1 : a.number.compareTo(b.number)));
    return list;
  });

  Future<List<EpisodeInfo>> season(int n) => _seasons.putIfAbsent(n, () async {
    try {
      final j = await Tmdb.get('/tv/${show.id}/season/$n');
      return [for (final e in (j['episodes'] as List? ?? const [])) EpisodeInfo.fromJson(n, e as Map<String, dynamic>)];
    } catch (_) {
      _seasons.remove(n); // try again next time
      rethrow;
    }
  });

  /// The episode after [e]: the next in its season, else the first of the next season.
  Future<EpisodeInfo?> after(PlayerEpisode e) async {
    final eps = await season(e.season);
    final i = eps.indexWhere((x) => x.number == e.number);
    if (i >= 0 && i + 1 < eps.length) return eps[i + 1];
    if (e.season == 0) return null;
    final later = (await seasons).where((s) => s.number > e.season).toList();
    if (later.isEmpty) return null;
    final next = await season(later.first.number);
    return next.isEmpty ? null : next.first;
  }

  /// The episodes the panel lists out of a season's [all].
  List<EpisodeInfo> shown(List<EpisodeInfo> all, PlayerEpisode current) => all;
}

/// An anime's episodes (AniList's count, ani.zip's titles and stills) as one run, season 0. Long
/// runs make a long list, so the panel shows the playing episode and the 25 after it.
class AnimeEpisodeStore extends EpisodeStore {
  AnimeEpisodeStore(this.anime) : super(anime.media);
  final Anime anime;
  static const ahead = 25;

  late final Future<List<EpisodeInfo>> _all = AnimeExtras.episodesOf(anime).then((list) => [
    for (final e in list)
      EpisodeInfo(0, e.number, e.title, e.overview, e.image, e.runtime,
          // not out yet, even when the date isn't known
          e.upcoming ? (e.aired ?? DateTime.now().add(const Duration(days: 7))) : e.aired),
  ]);

  @override
  Future<List<Season>> get seasons => Future.value([Season(0, 'Episodi', anime.episodes ?? 0, anime.year?.toString(), null)]);

  @override
  Future<List<EpisodeInfo>> season(int n) => _all;

  @override
  List<EpisodeInfo> shown(List<EpisodeInfo> all, PlayerEpisode current) =>
      [for (final e in all) if (e.number >= current.number && e.number <= current.number + ahead) e];
}

// ───────────────────────── Episodes panel ─────────────────────────

/// Right-hand season and episode picker, in the same rail style as subtitle sync.
class EpisodesPanel extends StatefulWidget {
  const EpisodesPanel({super.key, required this.store, required this.current, required this.onPick, required this.onClose});
  final EpisodeStore store;
  final PlayerEpisode current;
  final ValueChanged<EpisodeInfo> onPick;
  final VoidCallback onClose;

  @override
  State<EpisodesPanel> createState() => _EpisodesPanelState();
}

class _EpisodesPanelState extends State<EpisodesPanel> {
  late int _season = widget.current.season;
  final _currentKey = GlobalKey();
  String? _revealedFor; // scroll to the playing episode once per season / episode change

  @override
  void didUpdateWidget(EpisodesPanel old) {
    super.didUpdateWidget(old);
    if (old.current.season != widget.current.season || old.current.number != widget.current.number) {
      _season = widget.current.season;
    }
  }

  /// Bring the playing episode into view once its list has laid out.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = _currentKey.currentContext;
    if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: .25, duration: const Duration(milliseconds: 380), curve: MenuInk.ease);
  });

  Widget _close(double size) => Pressable(
    tooltip: 'Chiudi',
    onTap: widget.onClose,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: hovered ? .16 : .07)),
      child: Icon(Icons.close_rounded, size: size * .52),
    ),
  );

  Widget _seasons(double height, {bool title = false}) => FutureBuilder<List<Season>>(
    future: widget.store.seasons,
    builder: (context, snap) {
      final seasons = snap.data ?? const <Season>[];
      if (seasons.length < 2) {
        if (!title) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(widget.store.show.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: MenuInk.dim)),
        );
      }
      return SizedBox(
        height: height,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final s in seasons)
              _SeasonPill(
                label: s.number == 0 ? 'Speciali' : 'Stagione ${s.number}',
                selected: s.number == _season,
                playing: s.number == widget.current.season,
                onTap: () => setState(() => _season = s.number),
              ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final top = Layout.windowChrome(context);
      final safe = MediaQuery.paddingOf(context);
      final full = box.maxWidth >= MediaQuery.sizeOf(context).width - 1; // the whole screen: no fade at its edge
      final short = MediaQuery.sizeOf(context).height < 520; // a phone on its side
      final compact = short || box.maxWidth < 470;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: full ? const Color(0xF705070D) : null,
          gradient: full
              ? null
              : LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: const [Color(0xF705070D), Color(0xEB05070D), Color(0x0005070D)],
                  stops: short ? const [0, .92, 1] : const [0, .78, 1],
                ),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Padding(
            padding: EdgeInsets.fromLTRB(full ? 14 + safe.left : (short ? 30 : (compact ? 40 : 56)), top + (short ? 8 : (compact ? 12 : 20)), (compact ? 12 : 22) + safe.right, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (short)
                  SizedBox(
                    height: 38,
                    child: Row(
                      children: [
                        const Text('Episodi', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -.3, color: MenuInk.title)),
                        const SizedBox(width: 14),
                        Expanded(child: _seasons(34, title: true)),
                        const SizedBox(width: 8),
                        _close(36),
                      ],
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Episodi', style: TextStyle(fontSize: compact ? 21 : 25, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -.5, color: MenuInk.title)),
                            const SizedBox(height: 1),
                            Text(
                              widget.store.show.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, height: 1.3, color: MenuInk.dim),
                            ),
                          ],
                        ),
                      ),
                      _close(38),
                    ],
                  ),
                  SizedBox(height: compact ? 10 : 16),
                  _seasons(36),
                ],
                SizedBox(height: short ? 2 : 8),
                Expanded(
                  child: FutureBuilder<List<EpisodeInfo>>(
                    key: ValueKey(_season),
                    future: widget.store.season(_season),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: TextButton(onPressed: () => setState(() {}), child: const Text("Impossibile caricare gli episodi · Riprova")),
                        );
                      }
                      final all = snap.data;
                      if (all == null) {
                        return const Center(
                          child: SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white)),
                        );
                      }
                      final eps = widget.store.shown(all, widget.current);
                      final k = '$_season/${widget.current.season}/${widget.current.number}';
                      if (_revealedFor != k) {
                        _revealedFor = k;
                        _reveal();
                      }
                      return ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (r) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: const [Color(0x00FFFFFF), Colors.white, Colors.white, Color(0x00FFFFFF)],
                          stops: [0, 10 / r.height, 1 - 26 / r.height, 1],
                        ).createShader(r),
                        child: ListView(
                          padding: EdgeInsets.only(top: short ? 4 : 6, bottom: (short ? 14 : 30) + safe.bottom),
                          children: [
                            for (final e in eps)
                              _EpisodeRow(
                                key: e.season == widget.current.season && e.number == widget.current.number ? _currentKey : null,
                                episode: e,
                                compact: compact,
                                short: short,
                                playing: e.season == widget.current.season && e.number == widget.current.number,
                                onTap: e.upcoming ? null : () => widget.onPick(e),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _SeasonPill extends StatelessWidget {
  const _SeasonPill({required this.label, required this.selected, required this.playing, required this.onTap});
  final String label;
  final bool selected;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: MenuInk.ease,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.white.withValues(alpha: selected ? .19 : (hovered ? .1 : .06)),
          border: Border.all(color: Colors.white.withValues(alpha: selected ? .08 : 0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (playing) ...[
              Container(width: 5, height: 5, decoration: const BoxDecoration(color: VyseColors.accent, shape: BoxShape.circle)),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: -.1, color: selected || hovered ? Colors.white : MenuInk.dim),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({super.key, required this.episode, required this.playing, required this.compact, required this.onTap, this.short = false});
  final EpisodeInfo episode;
  final bool playing;
  final bool compact;
  final bool short;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final w = short ? 100.0 : (compact ? 116.0 : 148.0);
    final meta = [
      'Episode ${e.number}',
      if (e.upcoming && e.aired != null) 'Uscito il ${e.aired!.day}/${e.aired!.month}/${e.aired!.year}' else if (e.runtime != null) '${e.runtime} min',
    ].join('  ·  ');
    return Opacity(
      opacity: onTap == null && !playing ? .45 : 1,
      child: Pressable(
        onTap: playing ? null : onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .985 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: MenuInk.ease,
            margin: EdgeInsets.symmetric(vertical: short ? 1 : 2),
            padding: EdgeInsets.all(short ? 6 : 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              color: playing ? null : (hovered ? MenuInk.hover : const Color(0x00FFFFFF)),
              gradient: playing
                  ? LinearGradient(
                      colors: [VyseColors.accent.withValues(alpha: .24), VyseColors.accent.withValues(alpha: .09), VyseColors.accent.withValues(alpha: .02)],
                      stops: const [0, .6, 1],
                    )
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: w,
                    height: w * 9 / 16,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedScale(
                          scale: hovered ? 1.06 : 1,
                          duration: const Duration(milliseconds: 420),
                          curve: MenuInk.ease,
                          child: e.stillUrl() != null
                              ? CachedNetworkImage(imageUrl: e.stillUrl()!, fit: BoxFit.cover, memCacheWidth: 340, fadeInDuration: const Duration(milliseconds: 200))
                              : const ColoredBox(color: VyseColors.surfaceHi, child: Icon(Icons.movie_outlined, color: VyseColors.textFaint)),
                        ),
                        AnimatedOpacity(
                          opacity: playing || hovered ? 1 : 0,
                          duration: const Duration(milliseconds: 160),
                          child: ColoredBox(
                            color: const Color(0x73000000),
                            child: Center(child: playing ? const LiveBars(color: Colors.white, height: 19) : const Icon(Icons.play_arrow_rounded, size: 30, color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: compact ? 11 : 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: compact ? 0 : 1),
                      Text(
                        e.name,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 13.5 : 14.5,
                          height: 1.25,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.15,
                          color: playing || hovered ? Colors.white : MenuInk.body,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        playing ? 'In riproduzione' : meta,
                        style: TextStyle(fontSize: compact ? 11 : 11.5, fontWeight: FontWeight.w600, color: playing ? VyseColors.accent : MenuInk.dim),
                      ),
                      if (!compact) ...[
                        const SizedBox(height: 4),
                        Text(
                          e.overview.isEmpty ? 'Ancora nessuna trama.' : e.overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, height: 1.4, color: MenuInk.dim),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Up next ─────────────────────────

/// "Up next" card. With autoplay on, a light runs round its edge for [countdown] and then the
/// next episode starts; clicking plays it now, × dismisses it. With autoplay off it just waits.
class UpNextCard extends StatefulWidget {
  const UpNextCard({
    super.key,
    required this.episode,
    required this.auto,
    required this.onPlay,
    required this.onDismiss,
    this.compact = false,
    this.countdown = const Duration(seconds: 3),
  });
  final EpisodeInfo episode;
  final bool auto;
  final bool compact;
  final Duration countdown;
  final VoidCallback onPlay;
  final VoidCallback onDismiss;

  @override
  State<UpNextCard> createState() => _UpNextCardState();
}

class _UpNextCardState extends State<UpNextCard> with SingleTickerProviderStateMixin {
  late final _timer = AnimationController(vsync: this, duration: widget.countdown);

  @override
  void initState() {
    super.initState();
    _timer.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onPlay();
    });
    if (widget.auto) _timer.forward();
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final stillW = widget.compact ? 120.0 : 150.0;
    const radius = 20.0;
    return Pressable(
      onTap: widget.onPlay,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .98 : (hovered ? 1.015 : 1),
        duration: const Duration(milliseconds: 160),
        child: AnimatedBuilder(
          animation: _timer,
          builder: (context, child) => CustomPaint(
            foregroundPainter: widget.auto ? _EdgeTrace(progress: _timer.value, radius: radius) : null,
            child: child,
          ),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xF2101118),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: hovered ? .16 : .08)),
              boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 12))],
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: stillW,
                  height: stillW * 9 / 16,
                  child: Stack(fit: StackFit.expand, children: [
                    if (e.stillUrl() != null)
                      CachedNetworkImage(imageUrl: e.stillUrl()!, fit: BoxFit.cover)
                    else
                      const ColoredBox(color: VyseColors.surfaceHi),
                    ColoredBox(color: Colors.black.withValues(alpha: hovered ? .2 : .35)),
                    const Center(child: Icon(Icons.play_arrow_rounded, size: 34, color: Colors.white)),
                  ]),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        'A SEGUIRE  ·  ${episodeLabel(e.season, e.number)}',
                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.accent),
                      ),
                    ),
                    Pressable(
                      tooltip: 'Chiudi',
                      onTap: widget.onDismiss,
                      builder: (context, h, _) => Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: h ? .16 : .06)),
                        child: const Icon(Icons.close_rounded, size: 15),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    e.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.25),
                  ),
                  const SizedBox(height: 10),
                  AnimatedBuilder(
                    animation: _timer,
                    builder: (context, _) {
                      final left = (widget.countdown.inMilliseconds * (1 - _timer.value) / 1000).ceil();
                      return Container(
                        height: 32,
                        padding: const EdgeInsets.fromLTRB(8, 0, 14, 0),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.play_arrow_rounded, size: 20, color: Colors.black),
                          const SizedBox(width: 4),
                          Text(
                            widget.auto ? 'Parte tra $left' : 'Riproduci dopo',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A glowing line that runs once round the card's rounded edge as the countdown goes.
class _EdgeTrace extends CustomPainter {
  _EdgeTrace({required this.progress, required this.radius});
  final double progress;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(.75);
    final path = Path()..addRRect(rrect);
    final PathMetric metric = path.computeMetrics().first;
    final trace = metric.extractPath(0, metric.length * progress);
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = VyseColors.accent.withValues(alpha: .35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = VyseColors.accent;
    canvas
      ..drawPath(trace, glow)
      ..drawPath(trace, line);
  }

  @override
  bool shouldRepaint(_EdgeTrace old) => old.progress != progress;
}
