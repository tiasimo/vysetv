import 'dart:async';

import 'package:flutter/material.dart';

import '../data/anilist.dart';
import '../data/discover.dart';
import '../data/tmdb.dart';
import '../data/list_status.dart' show MangaChapters;
import '../data/manga_library.dart' show mangaService;
import '../services/manga/manga_service.dart' show MangaLibraryChoice;
import '../screens/manga_details_page.dart';
import '../screens/details_page.dart';
import '../screens/discover_page.dart';
import '../screens/person_page.dart';
import '../models/manga/manga.dart';
import 'theme.dart';

/// The app's own navigator, under every tab's: full-screen pages (the player) open here, and
/// what floats over every page (the mini player, the mini chat) sits in its overlay.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Pages inside the shell crossfade with a little depth: the incoming page settles from 1.02,
/// the outgoing one sinks to 0.97 and fades. The sidebar never moves.
Widget _depth(Animation<double> a, Animation<double> secondary, Widget child) {
  final inT = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  final outT = CurvedAnimation(parent: secondary, curve: Curves.easeInOutCubic);
  return FadeTransition(
    opacity: Tween(begin: 1.0, end: 0.0).animate(outT),
    child: ScaleTransition(
      scale: Tween(begin: 1.0, end: .97).animate(outT),
      child: FadeTransition(
        opacity: inT,
        child: ScaleTransition(scale: Tween(begin: 1.02, end: 1.0).animate(inT), child: child),
      ),
    ),
  );
}

class ShellRoute<T> extends PageRouteBuilder<T> {
  ShellRoute({required Widget child, super.settings})
      : super(
          transitionDuration: const Duration(milliseconds: 560),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (_, _, _) => child,
          transitionsBuilder: (_, a, s, child) => _depth(a, s, child),
        );
}

/// Opens a Discover grid pre-filtered by [query] (genre tiles, platform tiles, genre chips).
Future<void> openDiscover(
  BuildContext context, {
  required String title,
  String subtitle = 'Film e serie TV',
  required DiscoverQuery query,
}) =>
    Navigator.of(context).push(ShellRoute(child: DiscoverPage(title: title, subtitle: subtitle, initial: query)));

Future<void> openPerson(BuildContext context, {required int id, required String name, String? profilePath, String? heroTag}) =>
    Navigator.of(context).push(ShellRoute(
      child: PersonPage(id: id, name: name, profilePath: profilePath, heroTag: heroTag),
    ));

/// A studio or network page: its logo over an endless, filterable grid of everything it made.
Future<void> openStudio(BuildContext context, Studio s) => Navigator.of(context).push(ShellRoute(
      child: DiscoverPage(
        title: s.name,
        subtitle: [s.kind, ?s.country].join(' · '),
        logo: s.logo,
        initial: s.isNetwork
            ? DiscoverQuery(type: MediaType.tv, networks: {s.id})
            : DiscoverQuery(companies: {s.id}),
      ),
    ));

/// Opens the details page for [media]. Pass [heroTag] (the tag on the card's poster) to fly the
/// poster into place.
Future<void> openDetails(BuildContext context, Media media, {String? heroTag}) => media.manga
    ? openMangaFromList(context, media)
    : media.anime
    ? openAnime(context, Anime.fromMedia(media), heroTag: heroTag)
    : Navigator.of(context).push(ShellRoute(child: DetailsPage(media: media, heroTag: heroTag)));

/// Lorewatch: a manga from My List (AniList): pick where to read it. Each library is searched by
/// title, with how many chapters it has of it.
Future<void> openMangaFromList(BuildContext context, Media media) async {
  final picked = await showModalBottomSheet<Manga>(
    context: context,
    backgroundColor: VyseColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _MangaSourceSheet(media: media),
  );
  if (picked == null || !context.mounted) return;
  unawaited(MangaChapters.link(picked.id, media.id)); // reading it here moves AniList's count
  await Navigator.of(context).push(ShellRoute(child: MangaDetailsPage(manga: picked)));
}

class _MangaSourceSheet extends StatelessWidget {
  const _MangaSourceSheet({required this.media});
  final Media media;

  static Future<({Manga manga, int chapters})?> _find(String library, String title) async {
    final found = await mangaService.searchIn(library, title);
    if (found.isEmpty) return null;
    // the closest title, else the library's first answer
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final want = norm(title);
    final best = found.firstWhere((m) => norm(m.title) == want, orElse: () => found.first);
    var n = 0;
    try {
      n = (await mangaService.getChapters(best.id)).length;
    } catch (_) {}
    return (manga: best, chapters: n);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dove vuoi leggerlo?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: VyseColors.text)),
          const SizedBox(height: 4),
          Text(media.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
          const SizedBox(height: 14),
          for (final lib in MangaLibraryChoice.all)
            FutureBuilder<({Manga manga, int chapters})?>(
              future: _find(lib.id, media.title),
              builder: (context, snap) {
                final r = snap.data;
                final waiting = snap.connectionState != ConnectionState.done;
                final sub = waiting
                    ? 'Cerco…'
                    : r == null
                    ? 'Non trovato'
                    : r.chapters > 0
                    ? '${r.chapters} capitoli · ${r.manga.title}'
                    : r.manga.title;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: VyseColors.surfaceHi,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: r == null ? null : () => Navigator.pop(context, r.manga),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(children: [
                          Icon(Icons.menu_book_rounded, size: 20, color: r == null && !waiting ? VyseColors.textFaint : VyseColors.accent),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(lib.label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: r == null && !waiting ? VyseColors.textFaint : VyseColors.text)),
                              const SizedBox(height: 2),
                              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                            ]),
                          ),
                          if (waiting)
                            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          else if (r != null)
                            Icon(Icons.chevron_right_rounded, color: VyseColors.textDim),
                        ]),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
  );
}
}
