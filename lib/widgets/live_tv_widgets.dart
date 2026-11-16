import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/iptv/hardcoded_channels.dart';
import 'common.dart';
import 'media_rows.dart';
import 'section_chrome.dart';

const _tileBg = Color(0xFF0D0F18);

/// Hover gradient + caption that slides up, exactly like Discover / Home cards.
class _HoverCaption extends StatelessWidget {
  const _HoverCaption({required this.hovered, required this.title, this.meta});
  final bool hovered;
  final String title;
  final String? meta;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        AnimatedOpacity(
          opacity: hovered ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.center, colors: [Color(0xF0000000), Color(0x00000000)]),
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: 9,
          child: AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: AnimatedSlide(
              offset: Offset(0, hovered ? 0 : .3),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, height: 1.2)),
                if (meta != null && meta!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: VyseColors.textDim)),
                ],
              ]),
            ),
          ),
        ),
      ]);
}

/// A featured channel. With backdrop art it's one of Home's landscape cards (logo at rest,
/// details on hover); without, it's a flat logo tile like Home's studio tiles.
class ChannelTile extends StatelessWidget {
  const ChannelTile({super.key, required this.channel, required this.onTap});
  final HardcodedChannel channel;
  final VoidCallback onTap;

  Widget _name() => Text(channel.name,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: VyseColors.textDim));

  @override
  Widget build(BuildContext context) => OutlineCard(
        label: channel.name,
        onTap: onTap,
        builder: (hovered) => Stack(fit: StackFit.expand, children: [
          if (channel.backdropUrl != null) ...[
            NetImage(url: channel.backdropUrl, fallback: Icons.live_tv_rounded),
            IgnorePointer(
              child: AnimatedContainer(duration: const Duration(milliseconds: 180), color: Colors.black.withValues(alpha: hovered ? 0 : .08)),
            ),
            if (channel.iconUrl != null)
              Positioned(
                left: 12,
                bottom: 10,
                child: AnimatedOpacity(
                  opacity: hovered ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110, maxHeight: 40),
                    child: CachedNetworkImage(imageUrl: channel.iconUrl!, fit: BoxFit.contain, alignment: Alignment.bottomLeft),
                  ),
                ),
              ),
          ] else
            // Logos are drawn for light backgrounds, so they sit on Home's soft studio tile.
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              color: channel.iconUrl == null ? (hovered ? VyseColors.surfaceHi : _tileBg) : (hovered ? Colors.white : const Color(0xFFE6E8EF)),
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
              alignment: Alignment.center,
              child: channel.iconUrl == null
                  ? _name()
                  : AnimatedScale(
                      scale: hovered ? 1.06 : 1,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: CachedNetworkImage(
                        imageUrl: channel.iconUrl!,
                        fit: BoxFit.contain,
                        fadeInDuration: const Duration(milliseconds: 250),
                        errorWidget: (_, _, _) => _name(),
                      ),
                    ),
            ),
          _HoverCaption(hovered: hovered, title: channel.name, meta: channel.category),
        ]),
      );
}

/// Portal / playlist entry. Posters (movies, series) fill the card and reveal their title on
/// hover like Discover; live channels sit on a flat tile like studio logos, name underneath.
class StreamCard extends StatelessWidget {
  const StreamCard({super.key, required this.name, required this.image, required this.onTap, this.poster = false, this.alive});
  final String name;
  final String? image;
  final VoidCallback onTap;
  final bool poster;

  /// Green dot once the alive check has looked at this channel; null hides it.
  final bool? alive;

  bool get _hasImage => image != null && image!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (poster) {
      return OutlineCard(
        label: name,
        onTap: onTap,
        builder: (hovered) => Stack(fit: StackFit.expand, children: [
          if (_hasImage)
            NetImage(url: image, fallback: Icons.movie_outlined)
          else
            Container(
              color: VyseColors.surfaceHi,
              padding: const EdgeInsets.all(12),
              alignment: Alignment.center,
              child: Text(name,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: VyseColors.textDim)),
            ),
          _HoverCaption(hovered: hovered, title: name),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: OutlineCard(
          label: name,
          radius: 10,
          onTap: onTap,
          builder: (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: hovered ? VyseColors.surfaceHi : _tileBg,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            alignment: Alignment.center,
            child: _hasImage
                ? AnimatedScale(
                    scale: hovered ? 1.06 : 1,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: CachedNetworkImage(
                      imageUrl: image!,
                      fit: BoxFit.contain,
                      fadeInDuration: const Duration(milliseconds: 250),
                      errorWidget: (_, _, _) => _initials(),
                    ),
                  )
                : _initials(),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Row(children: [
        if (alive != null) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: alive! ? const Color(0xFF2BD67B) : VyseColors.textFaint),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      ]),
    ]);
  }

  Widget _initials() => Text(name,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: VyseColors.textDim));
}

/// Flat info tile (portals, playlists): studio-tile base with the white hover outline.
class InfoTile extends StatelessWidget {
  const InfoTile({super.key, required this.title, required this.lines, required this.onTap, this.trailing, this.selected = false});
  final String title;
  final List<String> lines;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) => OutlineCard(
        label: title,
        radius: 10,
        onTap: onTap,
        builder: (hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: selected || hovered ? VyseColors.surfaceHi : _tileBg,
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                for (final (i, l) in lines.where((l) => l.isNotEmpty).indexed) ...[
                  const SizedBox(height: 3),
                  Text(l,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: i == 0 ? VyseColors.textFaint : VyseColors.textDim)),
                ],
              ]),
            ),
            ?trailing,
          ]),
        ),
      );
}

/// Quiet working line: spinner, message, optional Stop.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.text, this.busy = true, this.onStop});
  final String text;
  final bool busy;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) => Row(children: [
        if (busy) ...[
          const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)),
          const SizedBox(width: 10),
        ] else ...[
          const Icon(Icons.info_outline_rounded, size: 15, color: VyseColors.textFaint),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim))),
        if (onStop != null) TextButton(onPressed: onStop, child: const Text('Stop')),
      ]);
}

/// Toolbar action in the sort-pill style: bare icon + label, lifts on hover.
class ToolButton extends StatelessWidget {
  const ToolButton({super.key, required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, pressed) {
          final fg = onTap == null
              ? VyseColors.textFaint
              : danger
                  ? const Color(0xFFFF7A7C)
                  : (hovered ? VyseColors.text : VyseColors.textDim);
          return AnimatedScale(
            scale: pressed ? .94 : 1,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.fromLTRB(11, 8, 14, 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white.withValues(alpha: hovered && onTap != null ? .1 : 0),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
              ]),
            ),
          );
        },
      );
}

// A glass dialog with text fields. Returns the values, or null if cancelled.
Future<List<String>?> showFieldsDialog(
  BuildContext context, {
  required String title,
  required List<(String label, String hint, {bool multiline, bool obscure})> fields,
  required String confirm,
  String? message,
}) {
  final controllers = [for (final _ in fields) TextEditingController()];
  return showDialog<List<String>>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Glass(
          radius: 20,
          opacity: .92,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.4)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
            ],
            const SizedBox(height: 16),
            for (final (i, f) in fields.indexed) ...[
              Text(f.$1, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: VyseColors.textDim)),
              const SizedBox(height: 6),
              TextField(
                controller: controllers[i],
                autofocus: i == 0,
                obscureText: f.obscure,
                minLines: f.multiline ? 6 : 1,
                maxLines: f.multiline ? 10 : 1,
                cursorColor: VyseColors.accent,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: f.$2,
                  hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 13.5),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .05),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VyseColors.stroke)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VyseColors.stroke)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .6), width: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: VyseColors.textDim))),
              const SizedBox(width: 8),
              PillButton(
                primary: true,
                icon: Icons.check_rounded,
                label: confirm,
                onTap: () => Navigator.pop(ctx, [for (final c in controllers) c.text.trim()]),
              ),
            ]),
          ]),
        ),
      ),
    ),
  ).whenComplete(() {
    for (final c in controllers) {
      c.dispose();
    }
  });
}
