import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/layout.dart';
import '../core/nav.dart';
import '../core/theme.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/media_rows.dart';
import '../widgets/page_scrollbar.dart';

/// A person: portrait, bio, facts, socials, Known for, Photos and a filmography by department.
/// Renders immediately from what the caller knows (name, photo) and fills in from TMDB.
class PersonPage extends StatefulWidget {
  const PersonPage({super.key, required this.id, required this.name, this.profilePath, this.heroTag});
  final int id;
  final String name;
  final String? profilePath;
  final String? heroTag;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  final _scroll = ScrollController();
  late Future<PersonDetails> _details = HomeFeed.instance.person(widget.id);

  Person get _seed => Person(widget.id, widget.name, widget.profilePath, '', const [], 0);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _back() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = phone ? 16.0 : 40.0;

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.backspace)) {
          _back();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) _back();
        },
        child: ColoredBox(
          color: VyseColors.bg,
          child: FutureBuilder<PersonDetails>(
            future: _details,
            builder: (context, snap) {
              final d = snap.data;
              final person = d?.person ?? _seed;
              final backdrop = d?.knownFor.where((m) => m.backdropPath != null).firstOrNull;

              return Stack(children: [
                Positioned.fill(child: _Backdrop(media: backdrop, scroll: _scroll)),
                PageScrollbar(
                  controller: _scroll,
                  child: ListView(
                    controller: _scroll,
                    padding: EdgeInsets.only(
                      top: Layout.topChrome(context) + (phone ? 10 : 22),
                      bottom: phone ? 100 + MediaQuery.paddingOf(context).bottom : 56,
                    ),
                    children: [
                      Padding(
                        padding: EdgeInsets.only(left: inset - 8),
                        child: Align(alignment: Alignment.centerLeft, child: _BackButton(onTap: _back)),
                      ),
                      SizedBox(height: phone ? 8 : 14),
                      Padding(
                        padding: EdgeInsets.only(left: inset, right: right),
                        child: _Header(person: person, details: d, heroTag: widget.heroTag),
                      ),
                      SizedBox(height: phone ? 28 : 40),
                      if (snap.hasError)
                        Padding(
                          padding: EdgeInsets.only(left: inset),
                          child: Row(children: [
                            Text("Impossibile caricare questa persona.", style: TextStyle(color: VyseColors.textDim)),
                            TextButton(
                              onPressed: () => setState(() => _details = HomeFeed.instance.person(widget.id)),
                              child: const Text('Riprova'),
                            ),
                          ]),
                        )
                      else if (d == null)
                        Padding(
                          padding: EdgeInsets.only(left: inset, right: right),
                          child: const _RowSkeleton(),
                        )
                      else ...[
                        if (d.knownFor.isNotEmpty)
                          Shelf<Media>(
                            title: 'Conosciuto per',
                            load: () async => d.knownFor,
                            itemWidth: _posterW(context),
                            itemHeight: _posterW(context) * 1.5,
                            itemBuilder: (_, m, _) => PosterCard(media: m, heroTag: 'person/${widget.id}/${m.key}'),
                          ),
                        if (d.photos.length > 1)
                          Shelf<String>(
                            title: 'Foto',
                            load: () async => d.photos,
                            itemWidth: phone ? 100 : 128,
                            itemHeight: (phone ? 100 : 128) * 1.5,
                            itemBuilder: (_, url, i) => _PhotoTile(url: url, onTap: () => _openLightbox(context, d.photos, i)),
                          ),
                        if (d.credits.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(left: inset, right: right),
                            child: _Filmography(credits: d.credits),
                          ),
                      ],
                    ],
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  double _posterW(BuildContext context) => switch (Layout.of(context)) {
        FormFactor.phone => 108.0,
        FormFactor.tablet => 128.0,
        FormFactor.desktop => (MediaQuery.sizeOf(context).width * .1).clamp(136.0, 180.0),
      };
}

// ───────────────────────── Backdrop ─────────────────────────

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.media, required this.scroll});
  final Media? media;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final bg = VyseColors.bg;
    return Stack(fit: StackFit.expand, children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        child: media?.backdrop() == null
            ? const SizedBox.expand(key: ValueKey('none'))
            : CachedNetworkImage(
                key: ValueKey(media!.key),
                imageUrl: media!.backdrop()!,
                fit: BoxFit.cover,
                alignment: const Alignment(.4, -.3),
                fadeInDuration: const Duration(milliseconds: 600),
              ),
      ),
      ColoredBox(color: bg.withValues(alpha: .7)),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [bg.withValues(alpha: .8), bg.withValues(alpha: .25), bg.withValues(alpha: 0)],
            stops: const [0, .5, .85],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [bg, bg.withValues(alpha: .6), bg.withValues(alpha: 0)],
            stops: const [0, .35, .7],
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
    ]);
  }
}

// ───────────────────────── Header ─────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.person, required this.details, required this.heroTag});
  final Person person;
  final PersonDetails? details;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final ff = Layout.of(context);
    final info = _Info(person: person, details: details);
    final facts = _Facts(details: details);
    switch (ff) {
      case FormFactor.desktop:
        final w = MediaQuery.sizeOf(context).width;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Portrait(person: person, heroTag: heroTag, width: (w * .15).clamp(190.0, 250.0)),
          const SizedBox(width: 32),
          Expanded(child: info),
          const SizedBox(width: 32),
          SizedBox(width: (w * .23).clamp(270.0, 340.0), child: facts),
        ]);
      case FormFactor.tablet:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Portrait(person: person, heroTag: heroTag, width: 170),
            const SizedBox(width: 26),
            Expanded(child: info),
          ]),
          const SizedBox(height: 26),
          facts,
        ]);
      case FormFactor.phone:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _Portrait(person: person, heroTag: heroTag, width: 118),
            const SizedBox(width: 16),
            Expanded(child: _NameBlock(person: person, details: details, compact: true)),
          ]),
          const SizedBox(height: 16),
          _Bio(details: details),
          const SizedBox(height: 16),
          _Links(person: person, details: details),
          const SizedBox(height: 22),
          facts,
        ]);
    }
  }
}

class _Portrait extends StatelessWidget {
  const _Portrait({required this.person, required this.heroTag, required this.width});
  final Person person;
  final String? heroTag;
  final double width;

  @override
  Widget build(BuildContext context) {
    final small = person.photo;
    final portrait = Container(
      width: width,
      height: width * 1.5,
      decoration: BoxDecoration(
        color: VyseColors.surfaceHi,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
      ),
      clipBehavior: Clip.antiAlias,
      child: person.photoLarge == null
          ? Icon(Icons.person_rounded, size: width * .4, color: VyseColors.textFaint)
          : CachedNetworkImage(
              imageUrl: person.photoLarge!,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              // the search / cast tile already cached the small copy
              placeholder: (_, _) =>
                  small == null ? const SizedBox() : Image(image: CachedNetworkImageProvider(small), fit: BoxFit.cover),
            ),
    );
    if (heroTag == null) return FadeSlideIn(offset: 14, child: portrait);
    return Hero(tag: heroTag!, child: portrait);
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.person, required this.details});
  final Person person;
  final PersonDetails? details;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _NameBlock(person: person, details: details),
        const SizedBox(height: 18),
        _Bio(details: details),
        const SizedBox(height: 20),
        _Links(person: person, details: details),
      ]);
}

class _NameBlock extends StatelessWidget {
  const _NameBlock({required this.person, required this.details, this.compact = false});
  final Person person;
  final PersonDetails? details;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final d = details;
    const dim = TextStyle(color: Color(0xFFC3C7D4), fontSize: 13);
    final bits = <String>[
      if (d != null && d.person.department.isNotEmpty) d.person.department,
      if (d?.age != null) d!.deathday != null ? '${d.birthday!.year} – ${d.deathday!.year} (${d.age})' : '${d.age} anni',
      if (d?.birthplace != null && !compact) d!.birthplace!,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      FadeSlideIn(
        delay: const Duration(milliseconds: 60),
        offset: 12,
        child: Text(person.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 26 : 38,
              height: 1.05,
              fontWeight: FontWeight.w800,
              letterSpacing: compact ? -.6 : -1.2,
              shadows: const [Shadow(color: Colors.black45, blurRadius: 20)],
            )),
      ),
      const SizedBox(height: 10),
      AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: bits.isEmpty
            ? const SizedBox(width: double.infinity, height: 18)
            : FadeSlideIn(
                offset: 8,
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  for (var i = 0; i < bits.length; i++) ...[
                    if (i > 0) Text('·', style: TextStyle(color: VyseColors.textFaint, fontSize: 13)),
                    Text(bits[i], style: dim),
                  ],
                ]),
              ),
      ),
      if (d != null) ...[
        const SizedBox(height: 12),
        FadeSlideIn(
          offset: 6,
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            _Stat(icon: Icons.movie_filter_outlined, label: '${d.creditCount} crediti'),
            if (d.knownFor.isNotEmpty) _Stat(icon: Icons.local_fire_department_outlined, label: d.knownFor.first.title),
          ]),
        ),
      ],
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: VyseColors.ink.withValues(alpha: .08)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: VyseColors.accent),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
          ),
        ]),
      );
}

/// Biography clamped to a few lines, with a smooth Read more.
class _Bio extends StatefulWidget {
  const _Bio({required this.details});
  final PersonDetails? details;

  @override
  State<_Bio> createState() => _BioState();
}

class _BioState extends State<_Bio> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.details;
    if (d == null) {
      return Shimmer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final w in const [1.0, .96, .9, .7])
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: FractionallySizedBox(widthFactor: w, child: const SkeletonBox(width: double.infinity, height: 11, radius: 4)),
            ),
        ]),
      );
    }
    final text = d.biography.isEmpty ? 'Ancora nessuna biografia.' : d.biography;
    const style = TextStyle(color: Color(0xFFC3C7D4), fontSize: 14, height: 1.65);
    return FadeSlideIn(
      offset: 10,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: LayoutBuilder(builder: (context, c) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            maxLines: 5,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: c.maxWidth);
          final long = painter.didExceedMaxLines;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topLeft,
              child: Text(text, style: style, maxLines: _open ? null : 5, overflow: _open ? null : TextOverflow.fade),
            ),
            if (long)
              Pressable(
                onTap: () => setState(() => _open = !_open),
                builder: (context, hovered, _) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_open ? 'Mostra meno' : 'Leggi di più',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : VyseColors.accent)),
                    AnimatedRotation(
                      turns: _open ? .5 : 0,
                      duration: const Duration(milliseconds: 300),
                      child: Icon(Icons.expand_more_rounded, size: 18, color: hovered ? VyseColors.text : VyseColors.accent),
                    ),
                  ]),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class _Links extends StatelessWidget {
  const _Links({required this.person, required this.details});
  final Person person;
  final PersonDetails? details;

  @override
  Widget build(BuildContext context) {
    final d = details;
    return FadeSlideIn(
      delay: const Duration(milliseconds: 160),
      offset: 8,
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        if (d?.imdbId != null) _LinkPill(label: 'IMDb', icon: Icons.open_in_new_rounded, url: 'https://www.imdb.com/name/${d!.imdbId}'),
        if (d?.instagram != null)
          _LinkPill(label: 'Instagram', icon: Icons.camera_alt_outlined, url: 'https://instagram.com/${d!.instagram}'),
        if (d?.twitter != null) _LinkPill(label: 'X', icon: Icons.alternate_email_rounded, url: 'https://x.com/${d!.twitter}'),
        if (d?.tiktok != null) _LinkPill(label: 'TikTok', icon: Icons.music_note_rounded, url: 'https://www.tiktok.com/@${d!.tiktok}'),
        _LinkPill(
          label: 'Condividi',
          icon: Icons.ios_share_rounded,
          onTap: () {
            Clipboard.setData(ClipboardData(text: person.tmdbUrl));
            showToast(context, const Text('Link copiato negli appunti', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                icon: Icons.link_rounded);
          },
        ),
      ]),
    );
  }
}

class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.label, required this.icon, this.url, this.onTap});
  final String label;
  final IconData icon;
  final String? url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap ?? () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .95 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: VyseColors.ink.withValues(alpha: hovered ? .14 : .06),
              border: Border.all(color: VyseColors.ink.withValues(alpha: hovered ? .22 : .08)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: VyseColors.text),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
            ]),
          ),
        ),
      );
}

class _Facts extends StatelessWidget {
  const _Facts({required this.details});
  final PersonDetails? details;

  @override
  Widget build(BuildContext context) {
    final d = details;
    final rows = d == null
        ? const <(String, String)>[]
        : [
            if (d.person.department.isNotEmpty) ('Conosciuto per', d.person.department),
            if (d.birthday != null) ('Nascita', fmtDate(d.birthday!)),
            if (d.deathday != null) ('Morte', fmtDate(d.deathday!)),
            if (d.birthplace != null) ('Luogo di nascita', d.birthplace!),
            ('Crediti', '${d.creditCount}'),
            if (d.alsoKnownAs.isNotEmpty) ('Conosciuto anche come', d.alsoKnownAs.join(', ')),
          ];
    return FadeSlideIn(
      delay: const Duration(milliseconds: 150),
      offset: 0,
      dx: Layout.of(context) == FormFactor.desktop ? 24 : 0,
      child: Glass(
        radius: 14,
        opacity: .5,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: d == null
              ? Shimmer(
                  child: Column(children: [
                    for (var i = 0; i < 5; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(children: [
                          const SkeletonBox(width: 60, height: 10, radius: 4),
                          const Spacer(),
                          SkeletonBox(width: 80.0 + (i % 3) * 20, height: 10, radius: 4),
                        ]),
                      ),
                  ]),
                )
              : Column(children: [
                  for (final (i, row) in rows.indexed)
                    FadeSlideIn(
                      delay: Duration(milliseconds: 25 * i),
                      offset: 6,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.5),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(
                            width: 96,
                            child: Text(row.$1, style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                          ),
                          Expanded(
                            child: Text(row.$2,
                                textAlign: TextAlign.right,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          ),
                        ]),
                      ),
                    ),
                ]),
        ),
      ),
    );
  }
}

// ───────────────────────── Photos ─────────────────────────

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.url, required this.onTap});
  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlineCard(
        label: 'Photo',
        onTap: onTap,
        builder: (hovered) => AnimatedScale(
          scale: hovered ? 1.05 : 1,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 300),
            placeholder: (_, _) => ColoredBox(color: VyseColors.surface),
          ),
        ),
      );
}

void _openLightbox(BuildContext context, List<String> photos, int start) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Chiudi',
    barrierColor: Colors.black.withValues(alpha: .88),
    transitionDuration: const Duration(milliseconds: 320),
    transitionBuilder: (_, a, _, child) {
      final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: t,
        child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(t), child: child),
      );
    },
    pageBuilder: (_, _, _) => _Lightbox(photos: photos, start: start),
  );
}

class _Lightbox extends StatefulWidget {
  const _Lightbox({required this.photos, required this.start});
  final List<String> photos;
  final int start;

  @override
  State<_Lightbox> createState() => _LightboxState();
}

class _LightboxState extends State<_Lightbox> {
  late final _pages = PageController(initialPage: widget.start);
  late int _index = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i < 0 || i >= widget.photos.length) return;
    _pages.animateToPage(i, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(_index + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(_index - 1),
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
        },
        child: Focus(
          autofocus: true,
          child: Stack(children: [
            PageView.builder(
              controller: _pages,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 70),
                  child: Center(
                    child: GestureDetector(
                      onTap: () {}, // taps on the photo itself don't close
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(imageUrl: widget.photos[i], fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: Layout.topChrome(context) + 14,
              right: 18,
              child: _RoundButton(icon: Icons.close_rounded, onTap: () => Navigator.pop(context)),
            ),
            Positioned(
              left: 14,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _index > 0 ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: _RoundButton(icon: Icons.chevron_left_rounded, onTap: () => _go(_index - 1)),
                ),
              ),
            ),
            Positioned(
              right: 14,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _index < widget.photos.length - 1 ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: _RoundButton(icon: Icons.chevron_right_rounded, onTap: () => _go(_index + 1)),
                ),
              ),
            ),
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: Text('${_index + 1} / ${widget.photos.length}',
                    style: TextStyle(color: VyseColors.textDim, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .9 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hovered ? Colors.white : VyseColors.ink.withValues(alpha: .12),
            ),
            child: Icon(icon, color: hovered ? Colors.black : Colors.white, size: 24),
          ),
        ),
      );
}

// ───────────────────────── Filmography ─────────────────────────

class _Filmography extends StatefulWidget {
  const _Filmography({required this.credits});
  final Map<String, List<Credit>> credits;

  @override
  State<_Filmography> createState() => _FilmographyState();
}

class _FilmographyState extends State<_Filmography> {
  static const _preview = 25;
  late String _dept = widget.credits.keys.first;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final list = widget.credits[_dept]!;
    final shown = _all ? list : list.take(_preview).toList();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 980),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Filmografia', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -.2)),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final e in widget.credits.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Pressable(
                  onTap: () => setState(() {
                    _dept = e.key;
                    _all = false;
                  }),
                  builder: (context, hovered, _) {
                    final on = e.key == _dept;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        color: on ? Colors.white : VyseColors.ink.withValues(alpha: hovered ? .1 : .04),
                      ),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: e.key),
                          TextSpan(
                            text: '  ${e.value.length}',
                            style: TextStyle(color: on ? Colors.black54 : VyseColors.textFaint, fontWeight: FontWeight.w500),
                          ),
                        ]),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: on ? Colors.black : (hovered ? VyseColors.text : VyseColors.textDim),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: Container(
            key: ValueKey(_dept),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: VyseColors.ink.withValues(alpha: .025),
              border: Border.all(color: VyseColors.stroke),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: Column(children: [
                for (final (i, c) in shown.indexed)
                  FadeSlideIn(
                    key: ValueKey('$_dept/${c.media.key}'),
                    delay: Duration(milliseconds: 18 * (i % _preview).clamp(0, 14)),
                    offset: 8,
                    child: _CreditRow(
                      credit: c,
                      showYear: i == 0 || _year(shown[i - 1]) != _year(c),
                      divider: i > 0 && _year(shown[i - 1]) != _year(c),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        if (list.length > _preview) ...[
          const SizedBox(height: 12),
          Center(
            child: Pressable(
              onTap: () => setState(() => _all = !_all),
              builder: (context, hovered, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: VyseColors.ink.withValues(alpha: hovered ? .14 : .06),
                ),
                child: Text(_all ? 'Mostra meno' : 'Mostra tutti i ${list.length}',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  static String _year(Credit c) => c.media.year ?? 'In uscita';
}

class _CreditRow extends StatelessWidget {
  const _CreditRow({required this.credit, required this.showYear, required this.divider});
  final Credit credit;
  final bool showYear;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final m = credit.media;
    final phone = Layout.isPhone(context);
    final role = [
      if (credit.role.isNotEmpty) credit.role,
      if (credit.episodes > 0) '${credit.episodes} ep${credit.episodes == 1 ? '' : 's'}',
    ].join('  ·  ');

    return Column(children: [
      if (divider) Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 14), color: VyseColors.stroke),
      Pressable(
        onTap: () => openDetails(context, m),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: hovered ? VyseColors.ink.withValues(alpha: .06) : Colors.transparent,
          ),
          child: Row(children: [
            SizedBox(
              width: phone ? 44 : 64,
              child: Text(showYear ? (m.year ?? '—') : '',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: m.year == null ? VyseColors.accent : VyseColors.textDim,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            Container(
              width: 34,
              height: 51,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: VyseColors.surfaceHi),
              clipBehavior: Clip.antiAlias,
              child: m.poster('w92') == null
                  ? Icon(Icons.movie_outlined, size: 14, color: VyseColors.textFaint)
                  : CachedNetworkImage(imageUrl: m.poster('w92')!, fit: BoxFit.cover, placeholder: (_, _) => const SizedBox()),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : const Color(0xFFE2E4EC))),
                if (role.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                ],
              ]),
            ),
            if (!phone) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: VyseColors.ink.withValues(alpha: .18)),
                ),
                child: Text(m.kind, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
              ),
            ],
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: m.rating > 0
                  ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      const Icon(Icons.star_rounded, size: 13, color: VyseColors.star),
                      const SizedBox(width: 2),
                      Text(m.rating.toStringAsFixed(1), style: TextStyle(fontSize: 12, color: VyseColors.textDim)),
                    ])
                  : null,
            ),
            AnimatedOpacity(
              opacity: hovered ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: VyseColors.textDim),
              ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SkeletonBox(width: 80, height: 14, radius: 4),
          const SizedBox(height: 14),
          Row(children: [
            for (var i = 0; i < 7; i++) ...[
              const SkeletonBox(width: 130, height: 195, radius: 7),
              const SizedBox(width: 10),
            ],
          ]),
        ]),
      );
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        tooltip: 'Indietro (Esc)',
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: hovered ? VyseColors.ink.withValues(alpha: .1) : Colors.transparent,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chevron_left_rounded, size: 20, color: hovered ? VyseColors.text : VyseColors.textDim),
            Text('Indietro',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.textDim)),
          ]),
        ),
      );
}
