part of 'details_page.dart';

// An anime's page: the same page as a film's or a show's (backdrop, info, tabs, the episode
// explorer), with everything about the title from AniList. It's part of the details page so the
// two share their pieces and look the same.

/// Opens an anime's page.
Future<void> openAnime(BuildContext context, Anime a, {String? heroTag}) =>
    Navigator.of(context).push(ShellRoute(child: AnimeDetailsPage(anime: a, heroTag: heroTag)));

/// AniList's cover colour ("#e4a15d"), for placeholders and glows.
Color? animeColor(Anime a) {
  final c = a.color;
  if (c == null || c.length != 7 || !c.startsWith('#')) return null;
  final v = int.tryParse(c.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// "2d 4h", "5h 12m", "12m" until [at].
String airsIn(DateTime at) {
  final d = at.difference(DateTime.now());
  if (d.isNegative) return 'now';
  if (d.inDays > 0) return '${d.inDays}g ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes.clamp(1, 59)}m';
}

class AnimeDetailsPage extends StatefulWidget {
  const AnimeDetailsPage({super.key, required this.anime, this.heroTag});

  /// What the card already knew; the rest loads in.
  final Anime anime;
  final String? heroTag;

  @override
  State<AnimeDetailsPage> createState() => _AnimeDetailsPageState();
}

class _AnimeDetailsPageState extends State<AnimeDetailsPage> {
  final _scroll = ScrollController();
  late Future<Anime> _details = AniList.details(widget.anime.id);
  late final Future<AnimeExtras> _extras = AnimeExtras.of(widget.anime.id);
  Future<List<ExplorerEpisode>>? _episodes;
  String? _section;
  double? _blockH;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _back() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Every episode, worked out once the full details are in.
  Future<List<ExplorerEpisode>> _episodesOf(Anime a) => _episodes ??= AnimeExtras.episodesOf(a).then((list) {
        _names = {for (final e in list) if (e.title != 'Episode ${e.number}') e.number: e.title};
        _out = list.where((e) => !e.upcoming).length;
        return [
          for (final e in list) ExplorerEpisode(e.number, e.title, e.overview, e.image, e.image, e.aired, e.runtime, e.rating, notOut: e.upcoming),
        ];
      });
  Map<int, String> _names = const {};
  int? _out; // episodes out, once the list is in

  /// Plays [episode]; the Play button picks up the episode you were on (else the first).
  void _play(Anime a, [int? episode]) => openAnimePlayer(
    context,
    a,
    episode: episode ?? WatchProgress.find(a.media)?.episode ?? 1,
    episodes: _out ?? a.aired ?? a.episodes,
    names: _names,
  );

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = phone ? 16.0 : 40.0;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        // Mouse "back" side button.
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) _back();
        },
        child: ColoredBox(
          color: VyseColors.bg,
          child: Stack(
            children: [
              Positioned.fill(child: _AnimeBackdrop(anime: widget.anime, extras: _extras, scroll: _scroll)),
              PageScrollbar(
                controller: _scroll,
                child: FutureBuilder<Anime>(
                  future: _details,
                  builder: (context, snap) {
                    final d = snap.data;
                    final a = d ?? widget.anime;
                    final top = Layout.topChrome(context) + (phone ? 10 : 22);
                    final bottom = phone ? 100 + MediaQuery.paddingOf(context).bottom : 32.0;
                    final block = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(left: inset, right: right),
                          child: _AnimeHeader(anime: a, loaded: d != null, heroTag: widget.heroTag, onPlay: () => _play(a)),
                        ),
                        SizedBox(height: phone ? 28 : 34),
                        if (snap.hasError)
                          _LoadError(onRetry: () => setState(() => _details = AniList.details(widget.anime.id)))
                        else if (d == null)
                          const _CastSkeleton()
                        else
                          ..._sections(context, d),
                      ],
                    );
                    // Room left on the first screen once the back link and the block are placed.
                    final free = MediaQuery.sizeOf(context).height - top - bottom - 48 - (_blockH ?? 0);
                    return ListView(
                      controller: _scroll,
                      padding: EdgeInsets.only(top: top, bottom: bottom),
                      children: [
                        Padding(
                          padding: EdgeInsets.only(left: inset - 8),
                          child: Align(alignment: Alignment.centerLeft, child: _BackButton(onTap: _back)),
                        ),
                        if (phone) ...[
                          const SizedBox(height: 8),
                          block,
                        ] else ...[
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeOutCubic,
                            height: _blockH == null ? MediaQuery.sizeOf(context).height * .2 : free.clamp(24.0, double.infinity),
                          ),
                          _MeasureSize(
                            onChange: (size) {
                              if (mounted && size.height != _blockH) setState(() => _blockH = size.height);
                            },
                            child: block,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context, Anime a) {
    final ff = Layout.of(context);
    final posterW = switch (ff) {
      FormFactor.phone => 108.0,
      FormFactor.tablet => 128.0,
      FormFactor.desktop => (MediaQuery.sizeOf(context).width * .1).clamp(136.0, 180.0),
    };
    final videoW = ff == FormFactor.phone ? 240.0 : 300.0;
    final inset = Layout.inset(context);
    final right = ff == FormFactor.phone ? 16.0 : 40.0;
    final related = [for (final r in a.relations) if (r.anime.type == 'ANIME') r];

    final tabs = <(String, Widget)>[
      if (!a.isMovie || (a.episodes ?? 0) > 1)
        (
          'Episodi',
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 6, right, 34),
            child: FutureBuilder<AnimeExtras>(
              future: _extras,
              builder: (context, x) => EpisodeExplorer.list(
                episodes: _episodesOf(a),
                backdrop: x.data?.fanart ?? a.banner,
                onPlay: (e) => _play(a, e.number),
              ),
            ),
          ),
        ),
      if (a.characters.isNotEmpty)
        (
          'Personaggi',
          Shelf<AnimeCharacter>(
            title: 'Personaggi e doppiatori giapponesi',
            load: () async => a.characters,
            maxItems: 18,
            itemWidth: 116,
            itemHeight: 212,
            spacing: 14,
            itemBuilder: (_, c, _) => _CharacterTile(character: c),
          ),
        ),
      if (a.trailer != null)
        (
          'Trailer',
          Shelf<Anime>(
            title: '1 video',
            load: () async => [a],
            itemWidth: videoW,
            itemHeight: videoW * 9 / 16,
            spacing: 14,
            itemBuilder: (_, m, _) => _AnimeTrailer(anime: m),
          ),
        ),
      if (related.isNotEmpty)
        (
          'Correlati',
          Shelf<AnimeRelation>(
            title: 'Stagioni, film e storie parallele',
            load: () async => related,
            itemWidth: posterW,
            itemHeight: posterW * 1.5 + 22,
            spacing: 14,
            itemBuilder: (_, r, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: posterW, height: posterW * 1.5, child: AnimeCard(anime: r.anime)),
              const SizedBox(height: 6),
              Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
            ]),
          ),
        ),
      if (a.recommendations.isNotEmpty)
        (
          'Titoli simili',
          Shelf<Anime>(
            title: 'Scelti dai fan di questo titolo su AniList',
            load: () async => a.recommendations,
            itemWidth: posterW,
            itemHeight: posterW * 1.5,
            spacing: 14,
            itemBuilder: (_, m, _) => AnimeCard(anime: m),
          ),
        ),
      (
        'Dettagli',
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 4, right, 30),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: _AnimeFacts(anime: a)),
        ),
      ),
    ];
    final sel = tabs.indexWhere((t) => t.$1 == _section).clamp(0, tabs.length - 1);

    return [
      Padding(
        padding: EdgeInsets.fromLTRB(inset, 0, right, 0),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: VyseColors.ink.withValues(alpha: .08)))),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, t) in tabs.indexed) _SectionTab(label: t.$1, selected: i == sel, onTap: () => setState(() => _section = t.$1)),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 22),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(tabs[sel].$1), child: tabs[sel].$2),
      ),
    ];
  }
}

// ───────────────────────── Backdrop ─────────────────────────

/// Like a show's backdrop: 16:9 fan art when the anime databases have it, else AniList's banner
/// (or cover), dimmed the same way.
class _AnimeBackdrop extends StatelessWidget {
  const _AnimeBackdrop({required this.anime, required this.extras, required this.scroll});
  final Anime anime;
  final Future<AnimeExtras> extras;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final bg = VyseColors.bg;
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<AnimeExtras>(
          future: extras,
          builder: (context, x) {
            final url = x.data?.fanart ?? (x.connectionState == ConnectionState.done ? anime.banner ?? anime.cover : null);
            if (url == null) return ColoredBox(color: (animeColor(anime) ?? bg).withValues(alpha: .25));
            return TweenAnimationBuilder<double>(
              key: ValueKey(url),
              tween: Tween(begin: 1.06, end: 1.0),
              duration: const Duration(milliseconds: 1600),
              curve: Curves.easeOutCubic,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                alignment: const Alignment(.4, -.3),
                memCacheWidth: screenDecodeWidth(context),
                filterQuality: FilterQuality.low,
                fadeInDuration: const Duration(milliseconds: 500),
                placeholder: (_, _) => ColoredBox(color: bg),
                errorWidget: (_, _, _) => ColoredBox(color: bg),
              ),
            );
          },
        ),
        ColoredBox(color: bg.withValues(alpha: .58)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [bg.withValues(alpha: .75), bg.withValues(alpha: .2), bg.withValues(alpha: 0)],
              stops: const [0, .45, .8],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [bg, bg.withValues(alpha: .6), bg.withValues(alpha: 0)],
              stops: const [0, .3, .65],
            ),
          ),
        ),
        IgnorePointer(
          child: ListenableBuilder(
            listenable: scroll,
            builder: (context, _) {
              final t = scroll.hasClients ? (scroll.offset / 500).clamp(0.0, 1.0) : 0.0;
              return ColoredBox(color: bg.withValues(alpha: .55 * t));
            },
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Header ─────────────────────────

class _AnimeHeader extends StatelessWidget {
  const _AnimeHeader({required this.anime, required this.loaded, required this.heroTag, required this.onPlay});
  final Anime anime;
  final bool loaded; // the full details are in (genres, description)
  final String? heroTag;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    if (Layout.of(context) != FormFactor.phone) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _AnimeTitleBlock(anime: anime),
            const SizedBox(height: 18),
            _AnimeBody(anime: anime, loaded: loaded, onPlay: onPlay),
          ]),
        ),
      );
    }
    final w = MediaQuery.sizeOf(context).width;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _AnimePoster(anime: anime, heroTag: heroTag, width: (w * .56).clamp(170.0, 250.0))),
        const SizedBox(height: 22),
        _AnimeTitleBlock(anime: anime, compact: true, centered: true),
        const SizedBox(height: 16),
        _AnimeBody(anime: anime, loaded: loaded, onPlay: onPlay, compact: true, centered: true),
      ],
    );
  }
}

class _AnimePoster extends StatelessWidget {
  const _AnimePoster({required this.anime, required this.heroTag, required this.width});
  final Anime anime;
  final String? heroTag;
  final double width;

  @override
  Widget build(BuildContext context) {
    final small = anime.coverSmall;
    final poster = Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        color: animeColor(anime) ?? VyseColors.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
      ),
      clipBehavior: Clip.antiAlias,
      child: anime.cover == null
          ? Icon(Icons.movie_outlined, color: VyseColors.textFaint)
          : CachedNetworkImage(
              imageUrl: anime.cover!,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              placeholder: (_, _) => small == null ? const SizedBox() : Image(image: CachedNetworkImageProvider(small), fit: BoxFit.cover),
            ),
    );
    if (heroTag == null) return FadeSlideIn(offset: 14, child: poster);
    return Hero(tag: heroTag!, child: poster);
  }
}

class _AnimeTitleBlock extends StatelessWidget {
  const _AnimeTitleBlock({required this.anime, this.compact = false, this.centered = false});
  final Anime anime;
  final bool compact;
  final bool centered;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      FadeSlideIn(
        delay: const Duration(milliseconds: 60),
        offset: 12,
        child: Text(
          anime.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontSize: compact ? 26 : 34,
            height: 1.08,
            fontWeight: FontWeight.w800,
            letterSpacing: compact ? -.6 : -1,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 20)],
          ),
        ),
      ),
      const SizedBox(height: 10),
      FadeSlideIn(delay: const Duration(milliseconds: 110), offset: 10, child: _AnimeMetaLine(anime: anime, centered: centered)),
      const SizedBox(height: 12),
      AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: centered ? Alignment.topCenter : Alignment.topLeft,
        child: anime.genres.isEmpty
            ? const SizedBox(width: double.infinity)
            : FadeSlideIn(
                offset: 6,
                child: Wrap(
                  alignment: centered ? WrapAlignment.center : WrapAlignment.start,
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final g in anime.genres) _AnimeGenreChip(label: g)],
                ),
              ),
      ),
    ],
  );
}

class _AnimeMetaLine extends StatelessWidget {
  const _AnimeMetaLine({required this.anime, this.centered = false});
  final Anime anime;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: VyseColors.pick(0xFFC3C7D4, 0xFF454A60), fontSize: 13);
    final a = anime;
    final count = a.isMovie ? null : (a.episodes ?? a.aired);
    final parts = <Widget>[
      if (a.year != null) Text('${a.year}', style: dim),
      Text(a.formatLabel, style: dim),
      if (a.duration != null) Text(fmtRuntime(a.duration!, perEpisode: !a.isMovie), style: dim),
      if (count != null && count > 0) Text('$count episode${count == 1 ? '' : 's'}', style: dim),
      if (a.nextEpisode != null && a.nextEpisodeAt != null)
        Text('EP ${a.nextEpisode} tra ${airsIn(a.nextEpisodeAt!)}', style: dim.copyWith(color: VyseColors.accent, fontWeight: FontWeight.w700)),
    ];
    return Wrap(
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) Text('·', style: TextStyle(color: VyseColors.textFaint, fontSize: 13)),
          parts[i],
        ],
        if (a.score != null) ...[
          const SizedBox(width: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.star_rounded, color: VyseColors.star, size: 15),
            const SizedBox(width: 3),
            Text((a.score! / 10).toStringAsFixed(1), style: const TextStyle(color: VyseColors.star, fontWeight: FontWeight.w700, fontSize: 13)),
            if (a.popularity > 0) ...[
              const SizedBox(width: 4),
              Text('(${fmtCompact(a.popularity)})', style: TextStyle(color: VyseColors.textFaint, fontSize: 12)),
            ],
          ]),
        ],
        if (a.status.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: VyseColors.ink.withValues(alpha: .3))),
            child: Text(
              (animeStatuses[a.status] ?? a.status).toUpperCase(),
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: VyseColors.pick(0xFFC3C7D4, 0xFF454A60)),
            ),
          ),
      ],
    );
  }
}

/// A genre opens the Anime catalogue filtered to it.
class _AnimeGenreChip extends StatelessWidget {
  const _AnimeGenreChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => Navigator.of(context).push(ShellRoute(child: AnimePage(title: label, initial: AnimeQuery(genres: {label})))),
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: VyseColors.ink.withValues(alpha: hovered ? .16 : .08)),
      child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim)),
    ),
  );
}

class _AnimeBody extends StatelessWidget {
  const _AnimeBody({required this.anime, required this.loaded, required this.onPlay, this.compact = false, this.centered = false});
  final Anime anime;
  final bool loaded;
  final VoidCallback onPlay;
  final bool compact;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final a = anime;
    final align = centered ? TextAlign.center : TextAlign.start;
    final other = a.english.isNotEmpty && a.romaji.isNotEmpty && a.romaji != a.title ? a.romaji : (a.native.isNotEmpty ? a.native : null);
    final link = a.siteUrl ?? 'https://anilist.co/anime/${a.id}';
    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        if (other != null) ...[
          FadeSlideIn(
            offset: 8,
            child: Text(other, textAlign: align, style: TextStyle(color: VyseColors.textDim, fontSize: 13.5, fontStyle: FontStyle.italic)),
          ),
          const SizedBox(height: 10),
        ],
        FadeSlideIn(
          delay: const Duration(milliseconds: 170),
          offset: 10,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Text(
              a.description.isNotEmpty ? a.description : (loaded ? 'Ancora nessuna trama.' : ''),
              textAlign: align,
              style: TextStyle(color: VyseColors.pick(0xFFC3C7D4, 0xFF454A60), fontSize: compact ? 13.5 : 14, height: 1.65),
            ),
          ),
        ),
        const SizedBox(height: 22),
        FadeSlideIn(
          delay: const Duration(milliseconds: 230),
          offset: 10,
          child: Wrap(
            alignment: centered ? WrapAlignment.center : WrapAlignment.start,
            spacing: 8,
            runSpacing: 8,
            children: [
              _Pill(icon: Icons.play_arrow_rounded, label: 'Riproduci', primary: true, onTap: onPlay),
              if (!a.isAdult) const _AudioToggle(),
              _SaveButton(media: a.media),
              _RoundAction(icon: Icons.open_in_new_rounded, tooltip: 'Apri su AniList', onTap: () => _open(context, link)),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Sections ─────────────────────────

/// Studios, dates, source and the other names, in the same grid as a show's details.
class _AnimeFacts extends StatelessWidget {
  const _AnimeFacts({required this.anime});
  final Anime anime;

  @override
  Widget build(BuildContext context) {
    final a = anime;
    String? date(DateTime? d) => d == null ? null : fmtDate(d);
    final rows = <(String, String?)>[
      ('Stato', animeStatuses[a.status] ?? a.status),
      (a.isMovie ? 'Released' : 'Prima messa in onda', date(a.started)),
      if (!a.isMovie && a.status == 'FINISHED') ('Ultima messa in onda', date(a.ended)),
      ('Format', a.formatLabel),
      if (!a.isMovie) ('Episodi', a.episodes?.toString()),
      ('Durata', a.duration == null ? null : fmtRuntime(a.duration!, perEpisode: !a.isMovie)),
      ('Stagione', a.season != null && a.year != null ? '${animeSeasons[a.season] ?? a.season} ${a.year}' : null),
      ('Studio', a.studios.isEmpty ? null : a.studios.join(', ')),
      ('Sorgente', a.source == null ? null : animeSources[a.source] ?? a.source),
      ('Country', a.country == null ? null : animeCountries[a.country] ?? a.country),
      ('Titolo originale', a.native.isEmpty ? null : a.native),
      ('Romaji', a.english.isEmpty || a.romaji.isEmpty ? null : a.romaji),
      ('Conosciuto anche come', a.synonyms.isEmpty ? null : a.synonyms.take(4).join(', ')),
      ('Tra i preferiti di', a.favourites > 0 ? fmtThousands(a.favourites) : null),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth > 900 ? 4 : (c.maxWidth > 520 ? 3 : 2);
        final cellW = (c.maxWidth / cols).floorToDouble();
        return Wrap(
          children: [
            for (final (i, (label, value)) in rows.where((r) => r.$2 != null && r.$2!.isNotEmpty).indexed)
              FadeSlideIn(
                delay: Duration(milliseconds: 30 * i),
                offset: 6,
                child: Container(
                  width: cellW,
                  padding: const EdgeInsets.fromLTRB(0, 13, 18, 13),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: VyseColors.ink.withValues(alpha: .08)))),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                      const SizedBox(height: 4),
                      Text(value!, maxLines: 2, overflow: TextOverflow.ellipsis, style: _FactsPanel._value),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Like a cast member's tile: the character, then who voices them.
class _CharacterTile extends StatelessWidget {
  const _CharacterTile({required this.character});
  final AnimeCharacter character;

  @override
  Widget build(BuildContext context) {
    final c = character;
    return Pressable(
      onTap: c.url == null ? null : () => _open(context, c.url!),
      builder: (context, hovered, pressed) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedScale(
            scale: pressed ? .95 : (hovered ? 1.03 : 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 104,
              height: 140,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: VyseColors.surfaceHi,
                border: Border.all(color: VyseColors.ink.withValues(alpha: hovered ? .4 : .06)),
              ),
              clipBehavior: Clip.antiAlias,
              child: c.image == null
                  ? Icon(Icons.person_rounded, color: VyseColors.textFaint, size: 32)
                  : CachedNetworkImage(
                      imageUrl: c.image!,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      fadeInDuration: const Duration(milliseconds: 250),
                      placeholder: (_, _) => const SizedBox(),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            c.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.pick(0xFFDADCE6, 0xFF2A2D3B)),
          ),
          const SizedBox(height: 2),
          Text(
            c.actor ?? c.roleLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: VyseColors.textFaint),
          ),
        ],
      ),
    );
  }
}

/// The trailer, as a show's trailers look.
class _AnimeTrailer extends StatelessWidget {
  const _AnimeTrailer({required this.anime});
  final Anime anime;

  @override
  Widget build(BuildContext context) => _VideoCard(video: Video(anime.trailer!, 'Trailer di ${anime.title}', 'Trailer', true));
}

/// Sub or dub: which version Play and the episode list start on. Every server that has the dub
/// is tried first; with none, it plays the original. The player's Sources list (and its Audio
/// tab) can still switch either way, and that choice comes back here.
class _AudioToggle extends StatelessWidget {
  const _AudioToggle();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: AppSettings.animeAudio,
    builder: (context, audio, _) {
      final dub = audio.isNotEmpty;
      Widget side(String label, bool on, VoidCallback pick) => Pressable(
        onTap: on ? () {} : pick,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: on ? VyseColors.strong : VyseColors.ink.withValues(alpha: hovered ? .08 : 0),
          ),
          child: Text(
            label,
            style: TextStyle(color: on ? VyseColors.onStrong : (hovered ? VyseColors.text : VyseColors.textDim), fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ),
      );
      return Tooltip(
        message: dub ? 'Doppiaggio $audio se c\'è' : 'Audio giapponese con sottotitoli',
        child: Container(
          height: 38,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: VyseColors.ink.withValues(alpha: .06),
            border: Border.all(color: VyseColors.ink.withValues(alpha: .08)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            side('Sub', !dub, () => AppSettings.animeAudio.set('')),
            side('Dub', dub, () => AppSettings.animeAudio.set('English')),
          ]),
        ),
      );
    },
  );
}
