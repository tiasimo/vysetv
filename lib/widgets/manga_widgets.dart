import 'package:flutter/material.dart';

import '../core/layout.dart';

import '../core/theme.dart';
import '../data/manga_library.dart';
import '../models/manga/manga.dart';
import 'common.dart';
import 'media_rows.dart';
import 'section_chrome.dart';

/// Cover with its title and type underneath. [heroTag] flies the cover into the details page.
class MangaCard extends StatelessWidget {
  const MangaCard({super.key, required this.manga, required this.heroTag, required this.onTap, this.caption, this.onRemove});
  final Manga manga;
  final String heroTag;
  final VoidCallback onTap;

  /// Shows an × on hover (always on phones) that calls this, e.g. to drop it from Continue reading.
  final VoidCallback? onRemove;

  /// Replaces the type / year line (e.g. "Chapter 12" on Continue reading).
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final meta = caption ?? [manga.type, manga.year].nonNulls.where((s) => s.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: OutlineCard(
          label: manga.title,
          onTap: onTap,
          builder: (hovered) => Stack(fit: StackFit.expand, children: [
            Hero(tag: heroTag, child: NetImage(url: manga.cover, fallback: Icons.menu_book_rounded)),
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                color: Colors.black.withValues(alpha: hovered ? 0 : .08),
              ),
            ),
            if (MangaFavorites.has(manga))
              Positioned(
                top: 6,
                right: 6,
                child: Icon(Icons.favorite_rounded, size: 16, color: VyseColors.accent, shadows: [Shadow(blurRadius: 8)]),
              ),
            if (onRemove != null)
              Positioned(
                top: 6,
                left: 6,
                child: AnimatedOpacity(
                  opacity: hovered || Layout.isPhone(context) ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Tooltip(
                    message: 'Rimuovi',
                    child: Pressable(
                      onTap: onRemove,
                      builder: (context, h, _) => AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: h ? Colors.white : Colors.black.withValues(alpha: .72),
                        ),
                        child: Icon(Icons.close_rounded, size: 16, color: h ? Colors.black : Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 7),
      Text(manga.title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 1),
      Text(meta.isEmpty ? '—' : meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: caption != null ? VyseColors.accent : VyseColors.textFaint)),
    ]);
  }
}

/// Small rounded tag pill used on the details page.
class TagPill extends StatelessWidget {
  const TagPill(this.label, {super.key, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: VyseColors.ink.withValues(alpha: hovered && onTap != null ? .12 : .05),
          ),
          child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFC3C7D4))),
        ),
      );
}
