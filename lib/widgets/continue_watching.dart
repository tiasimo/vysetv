import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../data/watch_progress.dart';
import '../screens/player_page.dart';
import 'common.dart';
import 'media_rows.dart' show ShelfHeader;

/// "Continue watching": what's half watched, newest first. Hidden when there's nothing.
class ContinueWatchingRow extends StatefulWidget {
  const ContinueWatchingRow({super.key});

  @override
  State<ContinueWatchingRow> createState() => _ContinueWatchingRowState();
}

class _ContinueWatchingRowState extends State<ContinueWatchingRow> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = (p.pixels + dir * p.viewportDimension * .8).clamp(0.0, p.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 600), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<WatchEntry>>(
    valueListenable: WatchProgress.entries,
    builder: (context, all, _) {
      final entries = all.where((e) => e.inContinue).toList();
      if (entries.isEmpty) return const SizedBox.shrink();
      final phone = Layout.isPhone(context);
      final w = phone ? 256.0 : 336.0;
      final h = w * 9 / 16;
      return Padding(
        padding: EdgeInsets.only(bottom: phone ? 22 : 30),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ShelfHeader(
            title: 'Continua a guardare',
            onPrev: phone || entries.length < 3 ? null : () => _page(-1),
            onNext: phone || entries.length < 3 ? null : () => _page(1),
          ),
          SizedBox(
            height: h + 8,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus},
              ),
              child: ListView.separated(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(Layout.inset(context), 4, phone ? 16 : 40, 4),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => SizedBox(
                  width: w,
                  child: FadeSlideIn(
                    key: ValueKey(entries[i].media.key),
                    delay: Duration(milliseconds: 35 * (i < 8 ? i : 8)),
                    offset: 10,
                    child: _ResumeCard(entry: entries[i], phone: phone),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
    },
  );
}

String _left(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  if (m <= 1) return 'Quasi finito';
  if (m < 60) return '$m min rimanenti';
  final rest = m % 60;
  return rest == 0 ? '${m ~/ 60} h rimanenti' : '${m ~/ 60} h $rest min rimanenti';
}

/// Backdrop and logo; a ring-shaped play button that shows how far in you are, and a glowing
/// line along the bottom. Hover (or long-press on touch) offers to drop it from the row.
class _ResumeCard extends StatefulWidget {
  const _ResumeCard({required this.entry, required this.phone});
  final WatchEntry entry;
  final bool phone;

  @override
  State<_ResumeCard> createState() => _ResumeCardState();
}

class _ResumeCardState extends State<_ResumeCard> {
  late final Future<String?> _logo = HomeFeed.instance.logo(widget.entry.media);

  void _play() {
    final e = widget.entry;
    openPlayer(
      context,
      e.media,
      episode: e.season != null && e.episode != null ? PlayerEpisode(season: e.season!, number: e.episode!, name: e.episodeName) : null,
    );
  }

  // off this row only; it stays in History
  void _remove() => WatchProgress.dismiss(widget.entry.media);

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final phone = widget.phone;
    final sub = e.season != null && e.episode != null
        ? '${episodeLabel(e.season, e.episode ?? 0)}${e.episodeName == null ? '' : '  ${e.episodeName}'}'
        : (e.media.year ?? e.media.kind);
    return GestureDetector(
      onLongPress: _remove,
      child: Pressable(
        onTap: _play,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .98 : (hovered ? 1.02 : 1),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: VyseColors.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                if (hovered) BoxShadow(color: VyseColors.accent.withValues(alpha: .22), blurRadius: 22, offset: const Offset(0, 6)),
              ],
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hovered ? VyseColors.ink.withValues(alpha: .9) : VyseColors.ink.withValues(alpha: .06), width: hovered ? 1.5 : 1),
            ),
            child: Stack(fit: StackFit.expand, children: [
              // backdrop, drifting in a touch on hover
              AnimatedScale(
                scale: hovered ? 1.06 : 1,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                // anime without a banner: their cover
                child: (e.media.backdrop('w780') ?? (e.media.anime ? e.media.poster() : null)) == null
                    ? ColoredBox(color: VyseColors.surface)
                    : CachedNetworkImage(
                        imageUrl: (e.media.backdrop('w780') ?? e.media.poster())!,
                        fit: BoxFit.cover,
                        fadeInDuration: const Duration(milliseconds: 300),
                        placeholder: (_, _) => ColoredBox(color: VyseColors.surface),
                        errorWidget: (_, _, _) => ColoredBox(color: VyseColors.surface),
                      ),
              ),
              // shade for the text
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xF2000000), Color(0x99000000), Color(0x00000000)],
                    stops: [0, .38, .75],
                  ),
                ),
              ),
              // title art and where you are
              Positioned(
                left: 14,
                right: phone ? 58 : 14,
                bottom: 14,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  FutureBuilder<String?>(
                    future: _logo,
                    builder: (context, snap) => snap.data == null
                        ? Text(
                            e.media.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: phone ? 15 : 17, fontWeight: FontWeight.w800, letterSpacing: -.2),
                          )
                        : ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: phone ? 130 : 170, maxHeight: phone ? 30 : 38),
                            child: CachedNetworkImage(
                              imageUrl: snap.data!,
                              fit: BoxFit.contain,
                              alignment: Alignment.bottomLeft,
                              fadeInDuration: const Duration(milliseconds: 250),
                              errorWidget: (_, _, _) => Text(e.media.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                          ),
                  ),
                  const SizedBox(height: 7),
                  Row(children: [
                    Flexible(
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFD5D7E2)),
                      ),
                    ),
                    Container(
                      width: 3,
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(color: VyseColors.textFaint, shape: BoxShape.circle),
                    ),
                    Text(_left(e.left), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: VyseColors.accent)),
                  ]),
                ]),
              ),
              // play: a ring that fills with progress. Centre on hover; always there on touch.
              if (phone)
                Positioned(right: 12, bottom: 14, child: _Ring(fraction: e.fraction, size: 38))
              else
                Center(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: AnimatedScale(
                      scale: hovered ? 1 : .8,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: _Ring(fraction: e.fraction, size: 58),
                    ),
                  ),
                ),
              // remove (desktop hover)
              if (!phone)
                Positioned(
                  top: 8,
                  right: 8,
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(
                      ignoring: !hovered,
                      child: Pressable(
                        tooltip: 'Rimuovi da Continua a guardare',
                        onTap: _remove,
                        builder: (context, h, _) => Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withValues(alpha: h ? .8 : .55),
                            border: Border.all(color: VyseColors.ink.withValues(alpha: h ? .5 : .2)),
                          ),
                          child: const Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                    ),
                  ),
                ),
              // progress along the bottom edge
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Stack(children: [
                  Container(height: 3, color: VyseColors.ink.withValues(alpha: .16)),
                  FractionallySizedBox(
                    widthFactor: e.fraction,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: VyseColors.accent,
                        boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .7), blurRadius: 8)],
                      ),
                    ),
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

class _Ring extends StatelessWidget {
  const _Ring({required this.fraction, required this.size});
  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(alignment: Alignment.center, children: [
      Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: .55),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 12)],
        ),
      ),
      SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          value: fraction,
          strokeWidth: size > 50 ? 3 : 2.5,
          strokeCap: StrokeCap.round,
          color: VyseColors.accent,
          backgroundColor: VyseColors.ink.withValues(alpha: .18),
        ),
      ),
      Icon(Icons.play_arrow_rounded, size: size * .5, color: Colors.white),
    ]),
  );
}
