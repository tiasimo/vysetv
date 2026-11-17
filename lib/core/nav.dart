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

/// Lorewatch: a manga from My List (AniList) is looked up by title in the Manga library picked
/// on the Manga page, and its first match opens.
Future<void> openMangaFromList(BuildContext context, Media media) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final found = await mangaService.searchManga(media.title);
    if (!context.mounted) return;
    if (found.isEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text('"${media.title}" non è in ${MangaLibraryChoice.current.label}. Prova un\'altra fonte nella pagina Manga.')));
      return;
    }
    unawaited(MangaChapters.link(found.first.id, media.id)); // reading it here moves AniList's count
    await Navigator.of(context).push(ShellRoute(child: MangaDetailsPage(manga: found.first)));
  } catch (_) {
    messenger?.showSnackBar(const SnackBar(content: Text('Impossibile cercare il manga ora.')));
  }
}
