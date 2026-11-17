import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/audiobook_player.dart';
import '../data/music_player.dart' show fmtClock;
import '../models/audiobook/audiobook_model.dart';
import '../widgets/audiobook_widgets.dart';
import '../widgets/common.dart';
import '../widgets/music_widgets.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'audiobook_player_page.dart';

/// A book: cover, author, Listen / Resume, and its chapter list.
class AudiobookDetailsPage extends StatefulWidget {
  const AudiobookDetailsPage({super.key, required this.book});
  final Audiobook book;

  @override
  State<AudiobookDetailsPage> createState() => _AudiobookDetailsPageState();
}

class _AudiobookDetailsPageState extends State<AudiobookDetailsPage> {
  final _scroll = ScrollController();
  final _p = AudiobookPlayer.instance;
  late Future<List<AudiobookChapter>> _chapters = audiobookService.getChapters(widget.book);

  Audiobook get b => widget.book;
  bool get _isLoaded => _p.book?.uuid == b.uuid;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _play(List<AudiobookChapter> chapters, {int? index}) async {
    if (_isLoaded && (index == null || index == _p.chapter)) {
      if (!_p.playing) await _p.toggle();
    } else {
      await _p.play(b, chapters, chapterIndex: index);
    }
    if (mounted) openAudiobookPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);

    return ColoredBox(
      color: VyseColors.bg,
      child: Stack(children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: phone ? 380 : 480,
          child: IgnorePointer(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Colors.transparent],
              ).createShader(r),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                child: Opacity(opacity: .45, child: NetImage(url: b.coverImage)),
              ),
            ),
          ),
        ),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset - 8, top, right, 12),
              sliver: SliverToBoxAdapter(
                child: Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, right, 30),
              sliver: SliverToBoxAdapter(
                child: Flex(
                  direction: phone ? Axis.vertical : Axis.horizontal,
                  crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.end,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
                      ),
                      child: Hero(tag: 'book/${b.uuid}', child: Artwork(url: b.coverImage, size: phone ? 200 : 236, radius: 12)),
                    ),
                    SizedBox(width: 30, height: phone ? 20 : 0),
                    Flexible(
                      fit: phone ? FlexFit.loose : FlexFit.tight,
                      child: FadeSlideIn(
                        offset: 12,
                        child: Column(crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
                          SourceBadge(b.source),
                          const SizedBox(height: 10),
                          Text(b.title,
                              textAlign: phone ? TextAlign.center : TextAlign.start,
                              style: TextStyle(fontSize: phone ? 26 : 38, fontWeight: FontWeight.w800, letterSpacing: -1.1, height: 1.08)),
                          if (b.author != null && b.author!.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(b.author!, style: TextStyle(color: VyseColors.accent, fontWeight: FontWeight.w600, fontSize: 14)),
                          ],
                          const SizedBox(height: 20),
                          _actions(),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(padding: EdgeInsets.fromLTRB(inset, 0, right, 0), sliver: SliverToBoxAdapter(child: _chapterList())),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
          ]),
        ),
      ]),
    );
  }

  Widget _actions() => FutureBuilder<List<AudiobookChapter>>(
        future: _chapters,
        builder: (context, snap) => ListenableBuilder(
          listenable: _p,
          builder: (context, _) {
            final chapters = snap.data ?? const <AudiobookChapter>[];
            final saved = _p.progressFor(b);
            final label = chapters.isEmpty
                ? (snap.hasError ? 'Non disponibile' : 'Caricamento…')
                : _isLoaded && _p.playing
                    ? 'In riproduzione'
                    : saved != null
                        ? 'Riprendi'
                        : 'Ascolta';
            return Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              PillButton(
                primary: true,
                icon: _isLoaded && _p.playing ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                label: label,
                onTap: chapters.isEmpty ? () {} : () => _play(chapters),
              ),
              if (saved != null && chapters.isNotEmpty)
                Text(
                  '${saved.chapterTitle ?? 'Chapter ${saved.chapter + 1}'} · ${fmtClock(saved.position)}',
                  style: TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                ),
            ]);
          },
        ),
      );

  Widget _chapterList() => FutureBuilder<List<AudiobookChapter>>(
        future: _chapters,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.wifi_off_rounded,
              title: "Impossibile caricare i capitoli",
              body: 'Questa fonte potrebbe non funzionare. Riprova o scegli un altro risultato.',
              action: ('Riprova', () => setState(() { _chapters = audiobookService.getChapters(b); })),
            );
          }
          final chapters = snap.data;
          if (chapters == null) {
            return Shimmer(
              child: Column(children: [
                for (var i = 0; i < 8; i++)
                  const Padding(padding: EdgeInsets.only(bottom: 6), child: SkeletonBox(width: double.infinity, height: 50, radius: 12)),
              ]),
            );
          }
          if (chapters.isEmpty) {
            return const EmptyState(icon: Icons.headphones_rounded, title: 'Nessun capitolo trovato', body: 'Prova un altro risultato per questo libro.');
          }
          return ListenableBuilder(
            listenable: _p,
            builder: (context, _) {
              final current = _isLoaded ? _p.chapter : _p.progressFor(b)?.chapter;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${chapters.length} capitoli', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                for (var i = 0; i < chapters.length; i++)
                  _ChapterTile(
                    number: i + 1,
                    title: chapters[i].title,
                    current: i == current,
                    playing: i == current && _isLoaded && _p.playing,
                    onTap: () => _play(chapters, index: i),
                  ),
              ]);
            },
          );
        },
      );
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({required this.number, required this.title, required this.current, required this.playing, required this.onTap});
  final int number;
  final String title;
  final bool current;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Pressable(
          onTap: onTap,
          builder: (context, hovered, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: VyseColors.ink.withValues(alpha: current ? .08 : (hovered ? .06 : 0)),
            ),
            child: Row(children: [
              SizedBox(
                width: 30,
                child: playing
                    ? const Equalizer(active: true)
                    : Text('$number', style: TextStyle(fontSize: 12.5, color: current ? VyseColors.accent : VyseColors.textFaint)),
              ),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: current ? VyseColors.text : VyseColors.pick(0xFFDADCE6, 0xFF2A2D3B))),
              ),
              Icon(hovered ? Icons.play_arrow_rounded : Icons.headphones_rounded, size: 18, color: hovered ? VyseColors.text : VyseColors.textFaint),
            ]),
          ),
        ),
      );
}
