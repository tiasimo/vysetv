import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../media_servers/media_servers.dart';
import '../../media_servers/server_playback.dart';
import '../../plezy/media/media_item.dart';
import '../../plezy/media/media_kind.dart';
import '../../plezy/media/media_library.dart';
import '../../plezy/media/media_server_client.dart';
import '../../widgets/common.dart';
import '../../widgets/media_rows.dart' show OutlineCard;
import '../../widgets/service_logos.dart';
import '../player_page.dart';

// ───────────────────────── Brands ─────────────────────────

List<Color> brandColors(MediaBackend b) => switch (b) {
  MediaBackend.plex => const [Color(0xFFEBAF00), Color(0xFFCC7B19)],
  MediaBackend.emby => const [Color(0xFF52B54B), Color(0xFF2F8F3A)],
  _ => const [Color(0xFFAA5CC3), Color(0xFF00A4DC)],
};

String brandName(MediaBackend b) => switch (b) {
  MediaBackend.plex => 'Plex',
  MediaBackend.emby => 'Emby',
  _ => 'Jellyfin',
};

Service serviceOf(MediaBackend b) => switch (b) {
  MediaBackend.plex => Service.plex,
  MediaBackend.emby => Service.emby,
  _ => Service.jellyfin,
};

/// The server's own logo on a rounded tile.
class BrandMark extends StatelessWidget {
  const BrandMark(this.backend, {super.key, this.size = 28});
  final MediaBackend backend;
  final double size;

  @override
  Widget build(BuildContext context) => ServiceLogo(serviceOf(backend), size: size);
}

/// The signed-in person's picture, or their initial.
class ServerAvatar extends StatelessWidget {
  const ServerAvatar({super.key, required this.name, this.url, this.size = 34, this.ring});
  final String name;
  final String? url;
  final double size;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = Container(
      alignment: Alignment.center,
      color: VyseColors.surfaceHi,
      child: Text(initial, style: TextStyle(fontSize: size * .42, fontWeight: FontWeight.w800, color: VyseColors.textDim)),
    );
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ring == null ? 0 : 2),
      decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
      child: ClipOval(
        child: url == null || url!.isEmpty
            ? fallback
            : CachedNetworkImage(imageUrl: url!, fit: BoxFit.cover, errorWidget: (_, _, _) => fallback, placeholder: (_, _) => fallback),
      ),
    );
  }
}

// ───────────────────────── Artwork ─────────────────────────

const cardRadius = 7.0;

Widget serverImage(String? url, {Alignment alignment = Alignment.center, BoxFit fit = BoxFit.cover, IconData icon = Icons.movie_outlined}) =>
    url == null || url.isEmpty
        ? ColoredBox(
            color: VyseColors.surface,
            child: Center(child: Icon(icon, color: VyseColors.textFaint, size: 22)),
          )
        : CachedNetworkImage(
            imageUrl: url,
            fit: fit,
            alignment: alignment,
            fadeInDuration: const Duration(milliseconds: 300),
            placeholder: (_, _) => const ColoredBox(color: VyseColors.surface),
            errorWidget: (_, _, _) => ColoredBox(
              color: VyseColors.surface,
              child: Center(child: Icon(icon, color: VyseColors.textFaint, size: 22)),
            ),
          );

extension ServerArt on MediaServerClient {
  String? art(String? path, {int width = 400}) => path == null || path.isEmpty ? null : thumbnailUrl(path, width: width);

  /// A poster for anything: the show's for its episodes, the show's for a season without one.
  String? posterOf(MediaItem m, {int width = 400}) => art(switch (m.kind) {
    MediaKind.episode => m.grandparentThumbPath ?? m.parentThumbPath ?? m.thumbPath,
    MediaKind.season => m.thumbPath ?? m.parentThumbPath,
    _ => m.thumbPath,
  }, width: width);

  /// A 16:9 picture: the episode's still, or the title's backdrop.
  String? wideOf(MediaItem m, {int width = 780}) => art(switch (m.kind) {
    MediaKind.episode => m.thumbPath ?? m.grandparentArtPath ?? m.artPath,
    _ => m.artPath ?? m.grandparentArtPath ?? m.thumbPath,
  }, width: width);

  /// The backdrop behind a details page.
  String? backdropOf(MediaItem m) => art(m.artPath ?? m.grandparentArtPath ?? m.thumbPath, width: 1920);
}

/// Progress through a title, 0..1, or null when it isn't started.
double? progressOf(MediaItem m) {
  if (!m.hasActiveProgress) return null;
  return (m.viewOffsetMs! / m.durationMs!).clamp(0.0, 1.0);
}

String _minutes(int ms) {
  final m = (ms / 60000).round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h${m % 60 == 0 ? '' : ' ${m % 60}m'}';
}

/// "S2 · E5" for an episode.
String? episodeCode(MediaItem m) {
  if (m.kind != MediaKind.episode) return null;
  final s = m.parentIndex, e = m.index;
  if (s == null && e == null) return null;
  return [if (s != null) 'S$s', if (e != null) 'E$e'].join(' · ');
}

/// "1h 12m left", "45m", "8 episodes"…
String? lengthNote(MediaItem m) {
  final d = m.durationMs;
  if (m.hasActiveProgress && d != null) return '${_minutes(d - m.viewOffsetMs!)} left';
  if (d != null && d > 0) return _minutes(d);
  final n = m.leafCount ?? m.childCount;
  if (n != null && n > 0) return m.kind == MediaKind.show ? (n == 1 ? '1 episode' : '$n episodes') : null;
  return null;
}

class ThinProgress extends StatelessWidget {
  const ThinProgress(this.value, {super.key, this.height = 3});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    color: Colors.white.withValues(alpha: .18),
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: value,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [VyseColors.accent, VyseColors.accentHot]),
          boxShadow: [BoxShadow(color: VyseColors.accent.withValues(alpha: .6), blurRadius: 6)],
        ),
      ),
    ),
  );
}

Widget _dimmer(bool hovered) => IgnorePointer(
  child: AnimatedContainer(duration: const Duration(milliseconds: 180), color: Colors.black.withValues(alpha: hovered ? 0 : .08)),
);

/// Watched tick, or how many episodes are left.
Widget? _corner(MediaItem m) {
  final left = m.unwatchedCount;
  if (left != null && left > 0 && m.kind != MediaKind.episode && m.kind != MediaKind.movie) {
    return _Pill(child: Text('$left', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.black)));
  }
  if (m.isWatched) return const _Pill(child: Icon(Icons.check_rounded, size: 13, color: Colors.black));
  return null;
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 22),
    height: 22,
    padding: const EdgeInsets.symmetric(horizontal: 6),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: VyseColors.accent,
      borderRadius: BorderRadius.circular(11),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .4), blurRadius: 8)],
    ),
    child: child,
  );
}

// ───────────────────────── Cards ─────────────────────────

/// A poster: watched tick or episodes left in the corner, progress along the bottom.
class ServerPoster extends StatelessWidget {
  const ServerPoster({super.key, required this.client, required this.item, required this.onTap, this.heroTag});
  final MediaServerClient client;
  final MediaItem item;
  final VoidCallback onTap;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final p = progressOf(item);
    final corner = _corner(item);
    final image = serverImage(client.posterOf(item));
    return OutlineCard(
      label: item.displayTitle,
      onTap: onTap,
      builder: (hovered) => Stack(
        fit: StackFit.expand,
        children: [
          heroTag == null ? image : Hero(tag: heroTag!, child: image),
          _dimmer(hovered),
          if (corner != null) Positioned(top: 7, right: 7, child: corner),
          if (p != null) Positioned(left: 0, right: 0, bottom: 0, child: ThinProgress(p)),
        ],
      ),
    );
  }
}

/// A poster with its title and year underneath, for grids.
class CaptionedPoster extends StatelessWidget {
  const CaptionedPoster({super.key, required this.client, required this.item, required this.onTap});
  final MediaServerClient client;
  final MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: ServerPoster(client: client, item: item, onTap: onTap)),
      const SizedBox(height: 7),
      Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 1),
      Text(
        [?item.year?.toString(), ?episodeCode(item)].join(' · '),
        maxLines: 1,
        style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

/// Continue watching: the episode still or backdrop, what it is, how long is left. Plays on tap.
class ServerWideCard extends StatelessWidget {
  const ServerWideCard({super.key, required this.client, required this.item, required this.onTap, this.onLongPress});
  final MediaServerClient client;
  final MediaItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final p = progressOf(item);
    final code = episodeCode(item);
    final sub = [?code, if (item.kind == MediaKind.episode) ?item.title, ?lengthNote(item)].join(' · ');
    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: OutlineCard(
        label: item.displayTitle,
        onTap: onTap,
        builder: (hovered) => Stack(
          fit: StackFit.expand,
          children: [
            AnimatedScale(
              scale: hovered ? 1.04 : 1,
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              child: serverImage(client.wideOf(item)),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [.35, 1],
                  colors: [Colors.transparent, Color(0xE6000000)],
                ),
              ),
            ),
            Center(
              child: AnimatedOpacity(
                opacity: hovered ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: AnimatedScale(
                  scale: hovered ? 1 : .8,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: .92),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .4), blurRadius: 18)],
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 32),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: p == null ? 10 : 13,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, shadows: [Shadow(blurRadius: 8)]),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: .75)),
                    ),
                ],
              ),
            ),
            if (p != null) Positioned(left: 0, right: 0, bottom: 0, child: ThinProgress(p, height: 3.5)),
          ],
        ),
      ),
    );
  }
}

IconData libraryIcon(MediaKind k) => switch (k) {
  MediaKind.movie => Icons.movie_creation_rounded,
  MediaKind.show => Icons.tv_rounded,
  MediaKind.artist || MediaKind.album || MediaKind.track => Icons.music_note_rounded,
  MediaKind.photo => Icons.photo_library_rounded,
  _ => Icons.video_library_rounded,
};

List<Color> _libraryColors(MediaKind k, int i) {
  const sets = [
    [Color(0xFFFF8A3D), Color(0xFFB8327A)],
    [Color(0xFF7A5CFF), Color(0xFF2C7BE5)],
    [Color(0xFF13B5A6), Color(0xFF2C5BE5)],
    [Color(0xFFFF5F6D), Color(0xFFFFA53A)],
    [Color(0xFF9D50BB), Color(0xFF6E48AA)],
  ];
  return sets[(k == MediaKind.show ? 1 : (k == MediaKind.movie ? 0 : 2) + i) % sets.length];
}

/// A library: a lit gradient tile with its icon.
class LibraryTile extends StatelessWidget {
  const LibraryTile({super.key, required this.library, required this.index, required this.onTap});
  final MediaLibrary library;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = _libraryColors(library.kind, index);
    return OutlineCard(
      label: library.title,
      radius: 12,
      onTap: onTap,
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: hovered ? Alignment.topRight : Alignment.topLeft,
            end: hovered ? Alignment.bottomLeft : Alignment.bottomRight,
            colors: [c.first.withValues(alpha: .9), c.last.withValues(alpha: .75)],
          ),
        ),
        child: Stack(children: [
          Positioned(
            right: -14,
            bottom: -18,
            child: AnimatedRotation(
              turns: hovered ? -.03 : 0,
              duration: const Duration(milliseconds: 320),
              child: Icon(libraryIcon(library.kind), size: 96, color: Colors.white.withValues(alpha: .16)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(libraryIcon(library.kind), size: 20, color: Colors.white),
                const Spacer(),
                Text(
                  library.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, height: 1.15, fontWeight: FontWeight.w900, color: Colors.white),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── Playing ─────────────────────────

/// Plays [item] from [server] in VyseTV's player: a film or episode as it is, a show from the
/// next episode to watch. [fromStart] ignores where you left off.
Future<void> playFromServer(BuildContext context, MediaServer server, MediaItem item, {bool fromStart = false}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  final busy = _BusyNote.show(context, item.kind == MediaKind.show ? 'Finding your next episode…' : 'Getting it ready…');
  final ServerPlayback playback;
  try {
    playback = await ServerPlayback.prepare(server, item, fromStart: fromStart);
  } catch (e) {
    busy.remove();
    if (context.mounted) {
      showToast(context, Text(serverError(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
    }
    return;
  }
  busy.remove();
  await nav.push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => PlayerPage(media: playback.media, episode: playback.episode, server: playback),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// A small "getting it ready" pill while the server answers.
class _BusyNote {
  _BusyNote._(this._entry);
  final OverlayEntry _entry;
  bool _gone = false;

  static _BusyNote show(BuildContext context, String text) {
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        bottom: 40 + MediaQuery.paddingOf(context).bottom,
        child: IgnorePointer(
          child: Center(
            child: FadeSlideIn(
              offset: 12,
              child: Glass(
                radius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent)),
                  const SizedBox(width: 12),
                  Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, decoration: TextDecoration.none, color: VyseColors.text)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return _BusyNote._(entry);
  }

  void remove() {
    if (_gone) return;
    _gone = true;
    _entry.remove();
  }
}

/// Card sizes, the same as Home's shelves.
({double poster, double wide}) shelfSizes(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return switch (Layout.of(context)) {
    FormFactor.phone => (poster: 108.0, wide: 250.0),
    FormFactor.tablet => (poster: 128.0, wide: 270.0),
    FormFactor.desktop => (poster: (w * .106).clamp(140.0, 200.0), wide: (w * .2).clamp(270.0, 380.0)),
  };
}

/// Keeps a future's result through rebuilds; used by pages that load once.
class Once<T> {
  Once(this._make);
  final Future<T> Function() _make;
  Future<T>? _f;
  Future<T> get future => _f ??= _make();
  void reset() => _f = null;
}

/// Runs [f] and toasts a failure.
Future<bool> tryServer(BuildContext context, Future<void> Function() f) async {
  try {
    await f();
    return true;
  } catch (e) {
    if (context.mounted) {
      showToast(context, Text(serverError(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
    }
    return false;
  }
}

/// Fire and forget, for refreshes nobody waits on.
void later(Future<void> f) => unawaited(f.catchError((Object _) {}));
