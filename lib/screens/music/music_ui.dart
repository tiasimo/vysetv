import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/accent.dart';
import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/music/music_library.dart';
import '../../data/music/yt_music.dart';
import '../../data/music_player.dart';
import '../../models/music/music_track.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/page_scrollbar.dart';
import '../../widgets/section_chrome.dart';
import 'music_pages.dart';

// ───────────────────────── page frame ─────────────────────────

/// A music page: the artwork blurred and muted under everything, a back link, then [slivers].
class MusicPageFrame extends StatefulWidget {
  const MusicPageFrame({super.key, required this.art, required this.slivers, this.back = true, this.controller});
  final String? art;
  final List<Widget> Function(BuildContext context, ScrollController scroll) slivers;
  final bool back;
  final ScrollController? controller;

  @override
  State<MusicPageFrame> createState() => _MusicPageFrameState();
}

class _MusicPageFrameState extends State<MusicPageFrame> {
  late final _scroll = widget.controller ?? ScrollController();

  @override
  void dispose() {
    if (widget.controller == null) _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    // inside the music frame its top bar has the back button
    final framed = LayoutFrame.of(context) != null;
    final top = framed ? 6.0 : Layout.topChrome(context) + (phone ? 12 : 30);
    return Material(
      color: VyseColors.bg,
      child: Stack(children: [
        Positioned.fill(child: MusicBackdrop(url: widget.art, scroll: _scroll)),
        PageScrollbar(
          controller: _scroll,
          child: CustomScrollView(controller: _scroll, slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset - 8, top, right, 12),
              sliver: SliverToBoxAdapter(
                child: widget.back && !framed ? Align(alignment: Alignment.centerLeft, child: BackLink(onTap: () => Navigator.of(context).maybePop())) : const SizedBox.shrink(),
              ),
            ),
            ...widget.slivers(context, _scroll),
            SliverToBoxAdapter(child: SizedBox(height: pageBottom(context) + 20)),
          ]),
        ),
      ]),
    );
  }
}

/// A page title for music pages (no back link: the frame or the page has one).
class MusicTitle extends StatelessWidget {
  const MusicTitle({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
    Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: Layout.isPhone(context) ? 28 : 36, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.1)),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!, style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
        ],
      ]),
    ),
    ?trailing,
  ]);
}

/// The artwork blurred and muted under the page, fading to the background as you scroll.
class MusicBackdrop extends StatelessWidget {
  const MusicBackdrop({super.key, required this.url, required this.scroll});
  final String? url;
  final ScrollController scroll;

  static const _mute = ColorFilter.matrix([
    .62, .31, .07, 0, 0, //
    .16, .77, .07, 0, 0, //
    .16, .31, .53, 0, 0, //
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final bg = VyseColors.bg;
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        if (url != null && url!.isNotEmpty)
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.clamp),
              child: ColorFiltered(colorFilter: _mute, child: Transform.scale(scale: 1.2, child: NetImage(url: url))),
            ),
          ),
        ColoredBox(color: bg.withValues(alpha: .7)),
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
        ListenableBuilder(
          listenable: scroll,
          builder: (context, _) {
            final t = scroll.hasClients ? (scroll.offset / 500).clamp(0.0, 1.0) : 0.0;
            return ColoredBox(color: bg.withValues(alpha: .55 * t));
          },
        ),
      ]),
    );
  }
}

/// The top of an album, playlist or artist page: artwork, what it is, its name, a line about it,
/// and its buttons.
class MusicHero extends StatelessWidget {
  const MusicHero({super.key, required this.art, required this.kind, required this.title, this.lines = const [], this.actions = const [], this.round = false});
  final Widget art;
  final String kind;
  final String title;
  final List<Widget> lines;
  final List<Widget> actions;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final size = phone ? 190.0 : 228.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 26),
      child: Flex(
        direction: phone ? Axis.vertical : Axis.horizontal,
        crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.end,
        children: [
          FadeSlideIn(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: round ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: round ? null : BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .55), blurRadius: 34, offset: const Offset(0, 16))],
              ),
              clipBehavior: Clip.antiAlias,
              child: art,
            ),
          ),
          SizedBox(width: 28, height: phone ? 18 : 0),
          Flexible(
            fit: phone ? FlexFit.loose : FlexFit.tight,
            child: FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              offset: 12,
              child: Column(
                crossAxisAlignment: phone ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                children: [
                  Text(kind.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: accentOf(context))),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    textAlign: phone ? TextAlign.center : TextAlign.start,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: phone ? 26 : (title.length > 28 ? 32 : 42), fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.05),
                  ),
                  for (final l in lines) Padding(padding: const EdgeInsets.only(top: 8), child: l),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Wrap(spacing: 10, runSpacing: 10, alignment: phone ? WrapAlignment.center : WrapAlignment.start, children: actions),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quiet line under a title; the linked parts open what they name.
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.parts, this.center = false});
  final List<(String, VoidCallback?)> parts;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final shown = parts.where((p) => p.$1.trim().isNotEmpty).toList();
    return Wrap(
      alignment: center || Layout.isPhone(context) ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) Text('  ·  ', style: TextStyle(fontSize: 13, color: VyseColors.textFaint)),
          shown[i].$2 == null
              ? Text(shown[i].$1, style: TextStyle(fontSize: 13, color: VyseColors.pick(0xFFC3C7D4, 0xFF454A60)))
              : Pressable(
                  onTap: shown[i].$2,
                  builder: (context, hovered, _) => Text(
                    shown[i].$1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: hovered ? accentOf(context) : VyseColors.text,
                      decoration: hovered ? TextDecoration.underline : null,
                      decorationColor: accentOf(context),
                    ),
                  ),
                ),
        ],
      ],
    );
  }
}

/// A round icon button beside the pills (save, add to playlist, more).
class RoundAction extends StatelessWidget {
  const RoundAction({super.key, required this.icon, required this.tooltip, required this.onTap, this.on = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool on;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    tooltip: tooltip,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .92 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? accentOf(context).withValues(alpha: .16) : VyseColors.ink.withValues(alpha: hovered ? .14 : .08),
          border: Border.all(color: on ? accentOf(context).withValues(alpha: .5) : VyseColors.stroke),
        ),
        child: Icon(icon, size: 20, color: on ? accentOf(context) : VyseColors.text),
      ),
    ),
  );
}

/// A row of filter chips (Songs 110, Albums 4…) with one lit.
class MusicChips<T> extends StatelessWidget {
  const MusicChips({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (v, label) in options)
        Pressable(
          onTap: () => onChanged(v),
          builder: (context, hovered, _) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              color: v == value ? accentOf(context) : VyseColors.ink.withValues(alpha: hovered ? .12 : .07),
              border: Border.all(color: v == value ? accentOf(context) : VyseColors.stroke),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: v == value ? onAccentOf(context) : VyseColors.text),
            ),
          ),
        ),
    ],
  );
}

// ───────────────────────── likes and playlists ─────────────────────────

/// A heart that likes [track] (your Liked songs, synced). Filled when liked.
class LikeButton extends StatelessWidget {
  const LikeButton({super.key, required this.track, this.size = 20, this.dim = false});
  final MusicTrack track;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: MusicLibrary.likesListenable,
    builder: (context, _, _) {
      final on = MusicLibrary.isLiked(track.id);
      return Pressable(
        tooltip: on ? 'Rimuovi dai brani preferiti' : 'Mi piace',
        onTap: () => MusicLibrary.toggleLike(track),
        builder: (context, hovered, pressed) => AnimatedScale(
          scale: pressed ? .8 : (hovered ? 1.12 : 1),
          duration: const Duration(milliseconds: 160),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
              child: Icon(
                on ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                key: ValueKey(on),
                size: size,
                color: on ? const Color(0xFFFF4D6A) : (dim && !hovered ? VyseColors.textFaint : VyseColors.textDim),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Four covers in a square, or a single one, for a playlist you made.
class PlaylistArt extends StatelessWidget {
  const PlaylistArt({super.key, required this.covers, this.cover, this.size, this.radius = 10});
  final List<String> covers;
  final String? cover;
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (cover != null && cover!.isNotEmpty) {
      child = NetImage(url: cover, fallback: Icons.queue_music_rounded);
    } else if (covers.length >= 4) {
      child = GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [for (final c in covers.take(4)) NetImage(url: c, fallback: Icons.music_note_rounded)],
      );
    } else if (covers.isNotEmpty) {
      child = NetImage(url: covers.first, fallback: Icons.queue_music_rounded);
    } else {
      child = DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF2B2F52), Color(0xFF151829)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: Center(child: Icon(Icons.queue_music_rounded, size: 40, color: VyseColors.textDim)),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), color: VyseColors.surface),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// The Liked songs cover: a warm gradient with a heart.
class LikedArt extends StatelessWidget {
  const LikedArt({super.key, this.size, this.radius = 10});
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: const LinearGradient(colors: [Color(0xFFFF4D6A), Color(0xFFFF8A3D), Color(0xFFFFC23A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
    ),
    child: LayoutBuilder(builder: (context, c) => Icon(Icons.favorite_rounded, color: Colors.white, size: (c.maxWidth.isFinite ? c.maxWidth : 60) * .42)),
  );
}

/// Picks one of your playlists for [tracks] (or makes a new one).
Future<void> showAddToPlaylist(BuildContext context, List<MusicTrack> tracks) async {
  if (tracks.isEmpty) return;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => _PlaylistPicker(count: tracks.length),
  );
  if (picked == null || !context.mounted) return;
  if (picked == '+') {
    final id = await showPlaylistEditor(context, tracks: tracks);
    if (id != null && context.mounted) {
      showToast(context, Text('Made a playlist with ${tracks.length == 1 ? tracks.first.title : '${tracks.length} songs'}', maxLines: 1, overflow: TextOverflow.ellipsis), icon: Icons.playlist_add_check_rounded);
    }
    return;
  }
  final added = MusicLibrary.addToPlaylist(picked, tracks);
  final name = MusicLibrary.playlist(picked)?.name ?? 'playlist';
  showToast(
    context,
    Text(added == 0 ? 'Già in $name' : 'Added ${added == 1 ? '1 song' : '$added brani'} to $name', maxLines: 1, overflow: TextOverflow.ellipsis),
    icon: added == 0 ? Icons.info_outline_rounded : Icons.playlist_add_check_rounded,
  );
}

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final lists = MusicLibrary.playlists;
    return Dialog(
      backgroundColor: VyseColors.pick(0xFF101118, 0xFFF2F3F8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: VyseColors.stroke)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
              child: Text(count == 1 ? 'Aggiungi a una playlist' : 'Aggiungi $count brani a una playlist', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 12),
              child: Text('Le tue playlist si sincronizzano con il tuo account', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
            ),
            _PickRow(
              leading: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: accentOf(context).withValues(alpha: .15), border: Border.all(color: accentOf(context).withValues(alpha: .4))),
                child: Icon(Icons.add_rounded, color: accentOf(context)),
              ),
              title: 'Nuova playlist',
              subtitle: 'Dalle un nome, e questi entrano per primi',
              onTap: () => Navigator.pop(context, '+'),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 14),
                children: [
                  for (final p in lists)
                    _PickRow(
                      leading: PlaylistArt(covers: p.covers, cover: p.cover, size: 46, radius: 9),
                      title: p.name,
                      subtitle: '${p.tracks.length} ${p.tracks.length == 1 ? 'song' : 'songs'}${p.public ? '' : '  ·  Privata'}',
                      onTap: () => Navigator.pop(context, p.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({required this.leading, required this.title, required this.subtitle, required this.onTap});
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: VyseColors.ink.withValues(alpha: hovered ? .07 : 0)),
      child: Row(children: [
        leading,
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: VyseColors.textDim)),
          ]),
        ),
      ]),
    ),
  );
}

/// Makes a playlist ([existing] null) or edits one: name, description, who sees it. The new id.
Future<String?> showPlaylistEditor(BuildContext context, {MyPlaylist? existing, List<MusicTrack> tracks = const []}) => showDialog<String>(
  context: context,
  builder: (ctx) => _PlaylistEditor(existing: existing, tracks: tracks),
);

class _PlaylistEditor extends StatefulWidget {
  const _PlaylistEditor({this.existing, this.tracks = const []});
  final MyPlaylist? existing;
  final List<MusicTrack> tracks;

  @override
  State<_PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<_PlaylistEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late final _cover = TextEditingController(text: widget.existing?.cover ?? '');
  late bool _public = widget.existing?.public ?? true;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _cover.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final cover = _cover.text.trim();
    final e = widget.existing;
    if (e == null) {
      final id = MusicLibrary.createPlaylist(name, description: _desc.text.trim(), public: _public, tracks: widget.tracks);
      if (cover.startsWith('http')) MusicLibrary.savePlaylist(MusicLibrary.playlist(id)!.copyWith(cover: cover));
      Navigator.pop(context, id);
    } else {
      MusicLibrary.savePlaylist(e.copyWith(
        name: name.isEmpty ? e.name : name,
        description: _desc.text.trim(),
        public: _public,
        cover: cover.startsWith('http') ? cover : null,
        clearCover: !cover.startsWith('http'),
      ));
      Navigator.pop(context, e.id);
    }
  }

  InputDecoration _field(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: VyseColors.textFaint),
    filled: true,
    fillColor: VyseColors.ink.withValues(alpha: .05),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: VyseColors.stroke)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: VyseColors.stroke)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: accentOf(context))),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: VyseColors.pick(0xFF101118, 0xFFF2F3F8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: VyseColors.stroke)),
    title: Text(widget.existing == null ? 'Nuova playlist' : 'Modifica playlist', style: const TextStyle(fontWeight: FontWeight.w800)),
    content: SizedBox(
      width: 400,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: _name, autofocus: true, maxLength: 80, decoration: _field('Name'), onSubmitted: (_) => _save()),
        const SizedBox(height: 4),
        TextField(controller: _desc, maxLines: 3, minLines: 2, maxLength: 300, decoration: _field('Descrizione (facoltativa)')),
        const SizedBox(height: 4),
        TextField(controller: _cover, decoration: _field('Link all\'immagine di copertina (facoltativo)')),
        const SizedBox(height: 14),
        Pressable(
          onTap: () => setState(() => _public = !_public),
          builder: (context, hovered, _) => Row(children: [
            Icon(_public ? Icons.public_rounded : Icons.lock_outline_rounded, size: 20, color: VyseColors.textDim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_public ? 'Pubblico' : 'Privato', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  _public ? 'Visibile sul tuo profilo' : 'Solo tu la vedi',
                  style: TextStyle(fontSize: 12, color: VyseColors.textDim),
                ),
              ]),
            ),
            Switch(value: _public, activeThumbColor: accentOf(context), onChanged: (v) => setState(() => _public = v)),
          ]),
        ),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text('Annulla', style: TextStyle(color: VyseColors.text))),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: accentOf(context), foregroundColor: onAccentOf(context)),
        onPressed: _save,
        child: Text(widget.existing == null ? 'Crea' : 'Salva', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    ],
  );
}

// ───────────────────────── tiles ─────────────────────────

double musicTileW(BuildContext context) => switch (Layout.of(context)) {
  FormFactor.phone => 140.0,
  FormFactor.tablet => 160.0,
  FormFactor.desktop => (MediaQuery.sizeOf(context).width * .11).clamp(170.0, 210.0),
};

/// Plays what an album, playlist or artist card stands for.
Future<void> playYtItem(BuildContext context, YtItem i, {bool shuffled = false}) async {
  final p = MusicPlayer.instance;
  try {
    switch (i.kind) {
      case YtKind.song || YtKind.video:
        await p.playQueue([ytTrack(i)]);
      case YtKind.album:
        final a = await YtMusic.instance.album(i.id);
        await p.playQueue(ytTracks(a.tracks), shuffled: shuffled);
      case YtKind.playlist:
        if (i.id.startsWith('RD')) {
          await p.playWatchPlaylist(i.id);
        } else {
          final pl = await YtMusic.instance.playlist(i.id, limit: 200);
          await p.playQueue(ytTracks(pl.tracks), shuffled: shuffled);
        }
      case YtKind.artist:
        final a = await YtMusic.instance.artist(i.id);
        await p.playQueue(ytTracks(a.songs), shuffled: shuffled);
      case YtKind.unknown:
        break;
    }
  } catch (_) {
    if (context.mounted) showToast(context, const Text("Impossibile caricarlo ora"), icon: Icons.wifi_off_rounded);
  }
}

/// Opens what a card stands for.
void openYtItem(BuildContext context, YtItem i, {List<YtItem>? queue}) {
  switch (i.kind) {
    case YtKind.song || YtKind.video:
      final list = queue?.where((x) => x.playable).toList() ?? [i];
      final at = list.indexWhere((x) => x.id == i.id);
      MusicPlayer.instance.playQueue(ytTracks(list), start: at < 0 ? 0 : at);
    case YtKind.album:
      openYtAlbum(context, i.id, title: i.title, art: i.thumb);
    case YtKind.playlist:
      openYtPlaylist(context, i.id, title: i.title, art: i.thumb);
    case YtKind.artist:
      openYtArtist(context, i.id, name: i.title, art: i.thumb);
    case YtKind.unknown:
      break;
  }
}

/// A card for anything on a YouTube Music page.
class YtCard extends StatelessWidget {
  const YtCard({super.key, required this.item, this.queue});
  final YtItem item;
  final List<YtItem>? queue;

  @override
  Widget build(BuildContext context) {
    final i = item;
    if (i.kind == YtKind.artist) return YtArtistCard(item: i);
    if (i.playable) {
      final list = queue?.where((x) => x.playable).toList() ?? [i];
      final tracks = ytTracks(list);
      final at = list.indexWhere((x) => x.id == i.id);
      return TrackCard(track: ytTrack(i), queue: tracks, index: at < 0 ? 0 : at);
    }
    final sub = i.kind == YtKind.album
        ? [i.albumType ?? 'Album', if (i.artistNames.isNotEmpty) i.artistNames, ?i.year].join(' · ')
        : (i.subtitle.isNotEmpty ? i.subtitle : (i.artistNames.isNotEmpty ? i.artistNames : 'Playlist'));
    return CoverTile(
      title: i.title,
      subtitle: sub,
      cover: sizedArt(i.thumb, 400),
      onTap: () => openYtItem(context, i),
      onPlay: () => playYtItem(context, i),
    );
  }
}

class YtArtistCard extends StatelessWidget {
  const YtArtistCard({super.key, required this.item});
  final YtItem item;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => openYtArtist(context, item.id, name: item.title, art: item.thumb),
    builder: (context, hovered, pressed) => Column(children: [
      Flexible(
        child: AnimatedScale(
          scale: pressed ? .95 : (hovered ? 1.05 : 1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AspectRatio(
            aspectRatio: 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: hovered ? VyseColors.strong : VyseColors.ink.withValues(alpha: .06), width: hovered ? 2 : 1),
              ),
              child: Artwork(url: sizedArt(item.thumb, 400), circle: true),
            ),
          ),
        ),
      ),
      const SizedBox(height: 9),
      Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: hovered ? VyseColors.text : VyseColors.pick(0xFFDADCE6, 0xFF2A2D3B)),
      ),
      Text(
        item.subtitle.replaceFirst(RegExp(r'^Artist · '), '').isEmpty ? 'Artist' : item.subtitle.replaceFirst(RegExp(r'^Artist · '), ''),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 10.5, color: VyseColors.textFaint),
      ),
    ]),
  );
}

/// One YouTube Music shelf: cards in a row, or for songs, rows in a few columns you swipe.
class YtShelfView extends StatelessWidget {
  const YtShelfView({super.key, required this.shelf});
  final YtShelf shelf;

  @override
  Widget build(BuildContext context) {
    final items = shelf.items;
    final allSongs = items.every((i) => i.playable) && items.any((i) => i.thumb != null && !i.thumb!.contains('ytimg.com/vi/'));
    if (allSongs && items.length >= 6) return SongColumns(title: shelf.title, items: items);
    final w = musicTileW(context);
    final artists = items.every((i) => i.kind == YtKind.artist);
    final aw = Layout.isPhone(context) ? 120.0 : 150.0;
    return Shelf<YtItem>(
      title: shelf.title,
      load: () async => items,
      maxItems: 40,
      itemWidth: artists ? aw : w,
      itemHeight: (artists ? aw : w) + 46,
      itemBuilder: (context, i, _) => YtCard(item: i, queue: items),
    );
  }
}

/// Songs as compact rows, four to a column, the columns side by side (Quick picks).
class SongColumns extends StatelessWidget {
  const SongColumns({super.key, required this.title, required this.items, this.perColumn = 4});
  final String title;
  final List<YtItem> items;
  final int perColumn;

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final colW = phone ? MediaQuery.sizeOf(context).width * .82 : 360.0;
    final cols = (items.length / perColumn).ceil();
    final tracks = ytTracks(items);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ShelfHeader(title: title),
      SizedBox(
        height: perColumn * 60.0,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(Layout.inset(context) - 10, 0, pageRight(context), 0),
          itemCount: cols,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, c) => SizedBox(
            width: colW,
            child: Column(children: [
              for (var r = 0; r < perColumn && c * perColumn + r < tracks.length; r++)
                TrackRow(track: tracks[c * perColumn + r], queue: tracks, index: c * perColumn + r),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 26),
    ]);
  }
}

/// A loading placeholder: a few rows.
class RowsSkeleton extends StatelessWidget {
  const RowsSkeleton({super.key, this.rows = 8});
  final int rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(Layout.inset(context), 0, pageRight(context), 0),
    child: Shimmer(
      child: Column(children: [
        for (var i = 0; i < rows; i++) const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(width: double.infinity, height: 50, radius: 10)),
      ]),
    ),
  );
}

String songCount(int n) => '$n ${n == 1 ? 'song' : 'songs'}';

String totalTime(int seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}
