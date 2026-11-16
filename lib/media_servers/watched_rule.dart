import '../plezy/media/watch_progress.dart';

/// Who marks a film or episode watched once you're past the server's "watched" point: the
/// server by itself, or VyseTV by asking.
///
/// Plex, Jellyfin and Emby mark a title watched on their own when the reports they receive in
/// one sitting go from before that point to at or past it. Asking on top counts the watch twice
/// on Plex (a second Play History row, a view count of 2). So VyseTV only asks when the server
/// never saw that happen: you resumed already past the point, or no report from before it got
/// through. This is Plezy's rule (its #1740).
class WatchedRule {
  WatchedRule(this.threshold);

  /// The server's "watched" point as a share of the runtime (Plex: the owner's setting;
  /// Jellyfin and Emby: 0.9).
  final double threshold;

  bool _before = false; // a report from before the point reached the server
  bool _crossed = false; // ...and later one from at or past it

  bool isWatched(Duration position, Duration duration) =>
      isWatchedProgress(positionMs: position.inMilliseconds, durationMs: duration.inMilliseconds, threshold: threshold);

  /// A report at [position] reached the server (start, progress or stop).
  void delivered(Duration position, Duration duration) {
    if (duration <= Duration.zero) return; // unknown length says nothing either way
    if (isWatched(position, duration)) {
      if (_before) _crossed = true;
    } else if (position > Duration.zero) {
      // zero is the session opening, not progress: the server has nothing to cross from
      _before = true;
    }
  }

  /// The server saw you cross its watched point, so it has marked the title itself.
  bool get serverMarked => _crossed;
}
