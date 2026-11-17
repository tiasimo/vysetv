import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../screens/player_page.dart';
import 'common.dart';

const _still = 'https://image.tmdb.org/t/p/w780';
const _thumb = 'https://image.tmdb.org/t/p/w300';
const _months = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];

/// An episode as the explorer shows it (from TMDB, or for anime from AniList's sources).
class ExplorerEpisode {
  const ExplorerEpisode(this.number, this.name, this.overview, this.still, this.thumb, this.aired, this.runtime, this.rating, {this.notOut});
  final int number;
  final String name;
  final String overview;
  final String? still; // full-size image URL
  final String? thumb; // small image URL
  final DateTime? aired;
  final int? runtime;
  final double rating;
  final bool? notOut; // known to be (or not be) out yet; null: go by the air date

  factory ExplorerEpisode.fromTmdb(Map<String, dynamic> j) {
    final still = j['still_path'] as String?;
    return ExplorerEpisode(
      j['episode_number'] as int,
      (j['name'] as String?)?.trim().isNotEmpty == true ? j['name'] as String : 'Episode ${j['episode_number']}',
      (j['overview'] as String?) ?? '',
      still == null ? null : '$_still$still',
      still == null ? null : '$_thumb$still',
      DateTime.tryParse((j['air_date'] as String?) ?? ''),
      (j['runtime'] as num?)?.toInt(),
      (j['vote_average'] as num?)?.toDouble() ?? 0,
    );
  }

  bool get upcoming => notOut ?? (aired != null && aired!.isAfter(DateTime.now()));
}

/// Seasons as a typographic index; episodes as stops on a timeline you scrub like a seek bar,
/// with the episode under your pointer previewed live above it. Long seasons are seen through a
/// window (12 stops on phones, up to 30 on wide screens) that slides along, and "Go to #" glides
/// it to any episode.
class EpisodeExplorer extends StatefulWidget {
  const EpisodeExplorer({super.key, required Media this.show, required this.seasons}) : episodes = null, backdrop = null, onPlay = null;

  /// One run of episodes with no seasons (anime, numbered straight through), played by [onPlay].
  const EpisodeExplorer.list({super.key, required Future<List<ExplorerEpisode>> this.episodes, this.backdrop, this.onPlay})
    : show = null,
      seasons = const [];

  final Media? show;
  final List<Season> seasons;
  final Future<List<ExplorerEpisode>>? episodes;
  final void Function(ExplorerEpisode episode)? onPlay;

  /// Shown for episodes without their own still (list mode).
  final String? backdrop;

  @override
  State<EpisodeExplorer> createState() => _EpisodeExplorerState();
}

class _EpisodeExplorerState extends State<EpisodeExplorer> with SingleTickerProviderStateMixin {
  static final _cache = <String, Future<List<ExplorerEpisode>>>{};

  late Season? _season = widget.seasons.isEmpty ? null : widget.seasons.firstWhere((s) => s.number == 1, orElse: () => widget.seasons.first);
  late Future<List<ExplorerEpisode>> _episodes = widget.episodes ?? _load(_season!);
  int _picked = 0; // episode index in the season
  int _start = 0; // first episode shown on the timeline (long seasons are viewed through a window)
  int _size = 1 << 30; // episodes per window, worked out from the width
  final _focus = FocusNode();
  final _goto = TextEditingController();

  // the window glides between starts instead of jumping
  late final _slide = AnimationController(vsync: this, duration: const Duration(milliseconds: 520))..addListener(() => setState(() {}));
  double _from = 0, _to = 0;

  /// Where the window is right now, between episodes while it glides.
  double get _shown => _slide.isAnimating ? _from + (_to - _from) * Curves.easeOutCubic.transform(_slide.value) : _start.toDouble();

  void _moveTo(int start, {bool glide = true}) {
    if (!glide) {
      _slide.stop();
      setState(() => _start = start);
      return;
    }
    _from = _shown;
    _to = start.toDouble();
    _start = start;
    _slide.forward(from: 0);
  }

  /// Pick an episode and slide the window so it's in view.
  void _select(int i, int count) {
    final picked = i.clamp(0, count - 1);
    var start = _start;
    if (picked < start) start = picked;
    if (picked >= start + _size) start = picked - _size + 1;
    setState(() => _picked = picked);
    if (start != _start) _moveTo(start);
  }

  /// One request per season, shared; a failed one is forgotten so reopening retries.
  Future<List<ExplorerEpisode>> _load(Season s) {
    final show = widget.show!;
    final key = '${show.id}/${s.number}';
    return _cache[key] ??= Tmdb.get('/tv/${show.id}/season/${s.number}')
        .then((json) => (json['episodes'] as List).cast<Map<String, dynamic>>().map(ExplorerEpisode.fromTmdb).toList())
        .catchError((Object _) {
          _cache.remove(key);
          return const <ExplorerEpisode>[];
        });
  }

  void _pickSeason(Season s) {
    if (s == _season) return;
    _slide.stop();
    setState(() {
      _season = s;
      _episodes = _load(s);
      _picked = 0;
      _start = 0;
    });
  }

  @override
  void dispose() {
    _slide.dispose();
    _focus.dispose();
    _goto.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e, int count) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight && _picked < count - 1) {
      _select(_picked + 1, count);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft && _picked > 0) {
      _select(_picked - 1, count);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final seasons = widget.seasons;

    final index = phone
        ? SizedBox(
            height: 74,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final s in seasons)
                  _SeasonNumber(season: s, selected: s == _season, horizontal: true, onTap: () => _pickSeason(s)),
              ],
            ),
          )
        : SizedBox(
            width: 180,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0, .88, 1],
                ).createShader(r),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 30),
                  children: [
                    for (final s in seasons) _SeasonNumber(season: s, selected: s == _season, onTap: () => _pickSeason(s)),
                  ],
                ),
              ),
            ),
          );

    final stage = FutureBuilder<List<ExplorerEpisode>>(
      future: _episodes,
      builder: (context, snap) {
        final eps = snap.data;
        if (eps == null) {
          return SizedBox(
            height: 320,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)),
          );
        }
        if (eps.isEmpty) {
          return SizedBox(
            height: 200,
            child: Center(
              child: Text(
                _season == null ? 'Ancora nessun episodio.' : 'Ancora nessun episodio per questa stagione.',
                style: TextStyle(color: VyseColors.textDim),
              ),
            ),
          );
        }
        final i = _picked.clamp(0, eps.length - 1);
        return Focus(
          focusNode: _focus,
          onKeyEvent: (n, e) => _onKey(n, e, eps.length),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(.015, 0), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: _Preview(
                  key: ValueKey('${_season?.number}/${eps[i].number}'),
                  show: widget.show,
                  season: _season,
                  episode: eps[i],
                  backdrop: widget.backdrop,
                  onPlay: widget.onPlay,
                  compact: phone,
                ),
              ),
              const SizedBox(height: 26),
              LayoutBuilder(
                builder: (context, box) {
                  // About one stop per 34px, 12-30 stops; anything longer gets the zoom window.
                  _size = phone ? 12 : (box.maxWidth / 34).floor().clamp(12, 30);
                  final long = eps.length > _size;
                  final last = math.max(0, eps.length - _size);
                  final target = long ? _start.clamp(0, last) : 0;
                  // mid-glide the window sits between two episodes: one extra stop slides in
                  final pos = long ? _shown.clamp(0.0, last.toDouble()) : 0.0;
                  final start = pos.floor();
                  final shift = pos - start;
                  final end = long ? math.min(eps.length, start + _size + (shift > 0 ? 1 : 0)) : eps.length;
                  void pick(int k) {
                    if (k != _picked) setState(() => _picked = k);
                    _focus.requestFocus();
                  }

                  final timeline = _Timeline(
                    episodes: eps.sublist(start, end),
                    offset: start,
                    slots: long ? _size : eps.length,
                    shift: shift,
                    picked: i,
                    onPick: pick,
                  );
                  if (!long) return timeline;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _RangeBar(
                        total: eps.length,
                        start: target,
                        size: _size,
                        picked: i,
                        goto: _goto,
                        onMove: (v) => _moveTo(v, glide: false),
                        onStep: _moveTo,
                        onJump: (k) => _select(k, eps.length),
                      ),
                      const SizedBox(height: 10),
                      timeline,
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );

    if (seasons.isEmpty) return stage;
    if (phone) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [index, const SizedBox(height: 18), stage]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        index,
        Container(width: 1, height: 400, margin: const EdgeInsets.symmetric(horizontal: 34), color: VyseColors.ink.withValues(alpha: .07)),
        Expanded(child: stage),
      ],
    );
  }
}

/// "03" in big type. Outlined until chosen, then solid with an accent tick and its details.
class _SeasonNumber extends StatelessWidget {
  const _SeasonNumber({required this.season, required this.selected, required this.onTap, this.horizontal = false});
  final Season season;
  final bool selected;
  final bool horizontal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = season.number == 0 ? 'SP' : season.number.toString().padLeft(2, '0');
    return Pressable(
      tooltip: season.name,
      onTap: onTap,
      builder: (context, hovered, _) {
        final numeral = Text(
          label,
          style: selected
              ? TextStyle(fontSize: 46, height: 1, fontWeight: FontWeight.w900, letterSpacing: -2, color: VyseColors.text)
              : TextStyle(
                  fontSize: 46,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = 1.4
                    ..color = VyseColors.ink.withValues(alpha: hovered ? .7 : .28),
                ),
        );
        final meta = AnimatedOpacity(
          opacity: selected || hovered ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                season.number == 0 ? 'Speciali' : '${season.episodes} episodi',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
              if (season.year != null)
                Text(season.year!, style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
            ],
          ),
        );
        return Padding(
          padding: EdgeInsets.only(bottom: horizontal ? 0 : 10, right: horizontal ? 20 : 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: 3,
                height: selected ? 30 : 0,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(2)),
              ),
              numeral,
              const SizedBox(width: 10),
              meta,
            ],
          ),
        );
      },
    );
  }
}

/// The chosen episode: still on one side, its details on the other (stacked on phones).
class _Preview extends StatelessWidget {
  const _Preview({super.key, required this.show, required this.season, required this.episode, required this.compact, this.backdrop, this.onPlay});
  final Media? show; // null: played by [onPlay] (anime)
  final Season? season; // null: numbered straight through
  final ExplorerEpisode episode;
  final String? backdrop;
  final void Function(ExplorerEpisode episode)? onPlay;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final s = season, show = this.show;
    final code = s == null
        ? 'EPISODE ${e.number.toString().padLeft(2, '0')}'
        : 'S${s.number.toString().padLeft(2, '0')}  ·  E${e.number.toString().padLeft(2, '0')}';
    final art = e.still ?? show?.backdrop() ?? backdrop;
    final still = AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: VyseColors.surfaceHi,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 30, offset: const Offset(0, 14))],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (art != null)
              CachedNetworkImage(
                imageUrl: art,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 250),
                placeholder: (_, _) => ColoredBox(color: VyseColors.surfaceHi),
              ),
            // big faint episode number in the corner of the frame
            Positioned(
              right: 14,
              bottom: -6,
              child: Text(
                e.number.toString().padLeft(2, '0'),
                style: TextStyle(
                  fontSize: compact ? 64 : 96,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -4,
                  color: VyseColors.ink.withValues(alpha: .18),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(code, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: VyseColors.accent)),
        const SizedBox(height: 8),
        Text(
          e.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: compact ? 22 : 28, fontWeight: FontWeight.w800, letterSpacing: -.8, height: 1.1),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (e.aired != null)
              Text(
                '${e.upcoming ? 'Airs ' : ''}${e.aired!.day} ${_months[e.aired!.month - 1]} ${e.aired!.year}',
                style: const TextStyle(fontSize: 13, color: Color(0xFFC3C7D4)),
              ),
            if (e.runtime != null && e.runtime! > 0)
              Text(fmtRuntime(e.runtime!), style: const TextStyle(fontSize: 13, color: Color(0xFFC3C7D4))),
            if (e.rating > 0)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star_rounded, size: 15, color: VyseColors.star),
                  const SizedBox(width: 3),
                  Text(
                    e.rating.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: VyseColors.star),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          e.overview.isEmpty ? 'Ancora nessuna trama.' : e.overview,
          maxLines: compact ? 4 : 5,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, height: 1.6, color: Color(0xFFC3C7D4)),
        ),
        if (show != null && s != null) ...[
          const SizedBox(height: 18),
          _PlayEpisode(
            label: e.upcoming ? 'Non ancora uscito' : 'Riproduci E${e.number}',
            enabled: !e.upcoming,
            onTap: () => openPlayer(
              context,
              show,
              episode: PlayerEpisode(season: s.number, number: e.number, name: e.name, runtime: e.runtime),
            ),
          ),
        ] else if (onPlay != null) ...[
          const SizedBox(height: 18),
          _PlayEpisode(label: e.upcoming ? 'Non ancora uscito' : 'Riproduci E${e.number}', enabled: !e.upcoming, onTap: () => onPlay!(e)),
        ],
      ],
    );

    if (compact) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [still, const SizedBox(height: 18), info]);
    return LayoutBuilder(
      builder: (context, c) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: math.min(560, c.maxWidth * .52), child: still),
          const SizedBox(width: 30),
          Expanded(child: info),
        ],
      ),
    );
  }
}

class _PlayEpisode extends StatelessWidget {
  const _PlayEpisode({required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: enabled ? onTap : null,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 42,
        padding: const EdgeInsets.fromLTRB(8, 0, 20, 0),
        decoration: BoxDecoration(
          color: !enabled ? VyseColors.ink.withValues(alpha: .08) : (hovered ? Colors.white : const Color(0xFFF1F1F5)),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: enabled ? VyseColors.accent : VyseColors.ink.withValues(alpha: .24), shape: BoxShape.circle),
              child: Icon(enabled ? Icons.play_arrow_rounded : Icons.schedule_rounded, size: 18, color: Colors.black),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: enabled ? Colors.black : VyseColors.textDim),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The season as a seek bar: one stop per episode. Drag (or hover-and-click) along it and the
/// preview follows the stop under the pointer; a small floating card names the hovered episode.
class _Timeline extends StatefulWidget {
  const _Timeline({required this.episodes, required this.picked, required this.onPick, this.offset = 0, int? slots, this.shift = 0})
    : slots = slots ?? episodes.length;

  /// The episodes in view; [offset] is the season index of the first one. [picked] and [onPick]
  /// use season indexes, so the chosen episode may sit outside the window.
  final List<ExplorerEpisode> episodes;
  final int offset;
  final int picked;
  final ValueChanged<int> onPick;

  /// Stops the track has room for, and how far (in stops) they're slid left while the window
  /// glides; during a glide one extra episode is in [episodes], sliding in from the edge.
  final int slots;
  final double shift;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  int? _hover;

  int _at(double x, double w) {
    final n = widget.episodes.length, slots = widget.slots;
    if (n == 1 || slots <= 1) return widget.offset;
    return widget.offset + ((x - _pad) / (w - _pad * 2) * (slots - 1) + widget.shift).round().clamp(0, n - 1);
  }

  static const _pad = 14.0;

  /// 1 on the track, fading to 0 one stop's width past either end.
  static double _edgeFade(double x, double w, int slots) {
    final step = slots <= 1 ? w : (w - _pad * 2) / (slots - 1);
    final out = x < _pad ? _pad - x : (x > w - _pad ? x - (w - _pad) : 0.0);
    return (1 - out / step).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final eps = widget.episodes;
    final n = eps.length;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final slots = widget.slots, shift = widget.shift;
        double xOf(int i) => n == 1 || slots <= 1 ? w / 2 : _pad + (w - _pad * 2) * (i - shift) / (slots - 1);
        final rel = widget.picked - widget.offset; // may be outside 0..n-1
        final fillTo = (rel < 0 ? _pad : (rel >= n ? w - _pad : xOf(rel))).clamp(_pad, w - _pad);
        final hover = _hover == null ? null : _hover! - widget.offset;
        final dense = (w - _pad * 2) / math.max(1, slots - 1) < 26;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => setState(() => _hover = _at(e.localPosition.dx, w)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => widget.onPick(_at(d.localPosition.dx, w)),
            onHorizontalDragStart: (d) => widget.onPick(_at(d.localPosition.dx, w)),
            onHorizontalDragUpdate: (d) {
              final i = _at(d.localPosition.dx, w);
              setState(() => _hover = i);
              widget.onPick(i);
            },
            onHorizontalDragEnd: (_) => setState(() => _hover = null),
            child: SizedBox(
              height: 92,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // track
                  Positioned(
                    left: _pad,
                    right: _pad,
                    top: 55,
                    child: Container(height: 2, color: VyseColors.ink.withValues(alpha: .1)),
                  ),
                  // watched-so-far fill up to the chosen stop
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    left: _pad,
                    width: math.max(0, fillTo - _pad),
                    top: 55,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [VyseColors.accent.withValues(alpha: .2), VyseColors.accent]),
                      ),
                    ),
                  ),
                  for (var i = 0; i < n; i++)
                    if (_edgeFade(xOf(i), w, slots) > 0)
                      Positioned(
                        left: xOf(i) - 14,
                        top: 42,
                        width: 28,
                        height: 50,
                        // stops gliding past the ends of the track fade out (and in)
                        child: Opacity(
                          opacity: _edgeFade(xOf(i), w, slots),
                          child: _Stop(
                            number: eps[i].number,
                            picked: i == rel,
                            passed: i < rel,
                            hovered: i == hover,
                            upcoming: eps[i].upcoming,
                            showNumber: !dense || i == rel || i == hover || i == 0 || i == n - 1,
                          ),
                        ),
                      ),
                  // floating name card over the hovered stop
                  if (hover != null && hover >= 0 && hover < n && hover != rel)
                    Positioned(
                      left: (xOf(hover) - 110).clamp(0.0, math.max(0.0, w - 220)),
                      top: -6,
                      width: 220,
                      child: IgnorePointer(child: _HoverCard(episode: eps[hover])),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The whole season in one thin bar, with a glowing window marking the stretch shown on the
/// timeline below. Drag or tap the bar to move the window; arrows step a window at a time; the
/// box jumps straight to an episode number.
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.total,
    required this.start,
    required this.size,
    required this.picked,
    required this.goto,
    required this.onMove,
    required this.onStep,
    required this.onJump,
  });
  final int total;
  final int start;
  final int size;
  final int picked;
  final TextEditingController goto;
  final ValueChanged<int> onMove; // dragging the bar: follows the pointer
  final ValueChanged<int> onStep; // the arrows: glides a window along
  final ValueChanged<int> onJump;

  int _clamp(int v) => v.clamp(0, total - size);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            'EPISODI ${start + 1}–${start + size}',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4, color: VyseColors.accent),
          ),
          const SizedBox(width: 8),
          Text('di $total', style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
          const Spacer(),
          _JumpBox(controller: goto, total: total, onJump: onJump),
          const SizedBox(width: 6),
          _StepButton(icon: Icons.chevron_left_rounded, onTap: start == 0 ? null : () => onStep(_clamp(start - size))),
          const SizedBox(width: 4),
          _StepButton(
            icon: Icons.chevron_right_rounded,
            onTap: start + size >= total ? null : () => onStep(_clamp(start + size)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final unit = w / total;
          final winW = math.max(28.0, size * unit);
          final winX = (start * unit).clamp(0.0, w - winW);
          void moveTo(double x) => onMove(_clamp((x / w * total - size / 2).round()));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => moveTo(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => moveTo(d.localPosition.dx),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: SizedBox(
                height: 22,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 8,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(color: VyseColors.ink.withValues(alpha: .07), borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                    // where the chosen episode sits in the whole season
                    Positioned(
                      left: (picked * unit).clamp(0.0, w - 2),
                      top: 6,
                      child: Container(width: 2, height: 10, color: VyseColors.text),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      left: winX,
                      width: winW,
                      top: 2,
                      height: 18,
                      child: Container(
                        decoration: BoxDecoration(
                          color: VyseColors.accent.withValues(alpha: .22),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: VyseColors.accent.withValues(alpha: .85), width: 1.2),
                          boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .35), blurRadius: 12)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: onTap == null ? Colors.transparent : VyseColors.ink.withValues(alpha: hovered ? .16 : .07),
      ),
      child: Icon(icon, size: 18, color: onTap == null ? VyseColors.textFaint : VyseColors.text),
    ),
  );
}

/// "Go to #" box: type an episode number, press Enter.
class _JumpBox extends StatelessWidget {
  const _JumpBox({required this.controller, required this.total, required this.onJump});
  final TextEditingController controller;
  final int total;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 84,
    height: 28,
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.go,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      cursorColor: VyseColors.accent,
      onSubmitted: (v) {
        final k = int.tryParse(v);
        if (k != null && k >= 1 && k <= total) onJump(k - 1);
        controller.clear();
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Vai al n.',
        hintStyle: TextStyle(fontSize: 12, color: VyseColors.textFaint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        filled: true,
        fillColor: VyseColors.ink.withValues(alpha: .06),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: VyseColors.accent),
        ),
      ),
    ),
  );
}

class _Stop extends StatelessWidget {
  const _Stop({
    required this.number,
    required this.picked,
    required this.passed,
    required this.hovered,
    required this.upcoming,
    required this.showNumber,
  });
  final int number;
  final bool picked;
  final bool passed;
  final bool hovered;
  final bool upcoming;
  final bool showNumber;

  @override
  Widget build(BuildContext context) {
    final size = picked ? 16.0 : (hovered ? 12.0 : 8.0);
    return Column(
      children: [
        SizedBox(
          height: 26,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: picked
                    ? VyseColors.accent
                    : upcoming
                        ? Colors.transparent
                        : (passed ? VyseColors.accent.withValues(alpha: .55) : VyseColors.ink.withValues(alpha: hovered ? .9 : .35)),
                border: upcoming && !picked ? Border.all(color: VyseColors.ink.withValues(alpha: .4), width: 1.5) : null,
                boxShadow: picked ? [BoxShadow(color: VyseColors.accent.withValues(alpha: .7), blurRadius: 14)] : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedOpacity(
          opacity: showNumber ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 11,
              fontWeight: picked ? FontWeight.w800 : FontWeight.w600,
              color: picked ? VyseColors.text : VyseColors.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _HoverCard extends StatelessWidget {
  const _HoverCard({required this.episode});
  final ExplorerEpisode episode;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: const Color(0xF2141729),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: VyseColors.ink.withValues(alpha: .1)),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 18, offset: const Offset(0, 8))],
    ),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: SizedBox(
            width: 56,
            height: 32,
            child: episode.thumb == null
                ? ColoredBox(color: VyseColors.surfaceHi)
                : CachedNetworkImage(imageUrl: episode.thumb!, fit: BoxFit.cover, fadeInDuration: Duration.zero),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Episodio ${episode.number}', style: TextStyle(fontSize: 10, color: VyseColors.textFaint)),
              Text(
                episode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
