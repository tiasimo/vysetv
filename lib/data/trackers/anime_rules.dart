/// An anime list entry's status on AniList.
enum ListStatus { current, planning, completed, dropped, paused, repeating }

/// What the service has for this anime right now.
class RemoteEntry {
  const RemoteEntry({required this.status, required this.progress, this.repeat = 0, this.started = false});
  final ListStatus status;
  final int progress;
  final int repeat; // times rewatched
  final bool started; // has a start date
}

/// One change to send. Nulls are left as they are.
class AnimeWrite {
  const AnimeWrite({this.status, this.progress, this.repeat, this.setStarted = false, this.setCompleted = false});
  final ListStatus? status;
  final int? progress;
  final int? repeat;
  final bool setStarted; // start date: today
  final bool setCompleted; // finish date: today
}

/// What to send when episode [n] of an anime (out of [total], null or 0 while unknown) has just
/// been watched to the end, given what the service has ([remote], null when it isn't on the
/// list). The same rules every mature tracker uses:
/// - progress only ever goes up; an episode at or below it changes nothing;
/// - the first episode starts it (Watching, start date today), the last one completes it;
/// - it's never completed while the episode count is unknown (still airing);
/// - Dropped entries are left alone, and Completed ones too unless rewatches are counted.
/// AniList needs a rewatch started in two steps (it resets progress if both go together), so
/// that case returns two writes.
List<AnimeWrite> planUpdate(RemoteEntry? remote, int n, int? total, {bool countRewatches = false}) {
  if (n <= 0) return const [];
  final t = total != null && total > 0 ? total : null;
  bool done(int x) => t != null && x >= t;
  int clamp(int x) => t == null ? x : (x > t ? t : x);

  if (remote == null) {
    if (done(n)) return [AnimeWrite(status: ListStatus.completed, progress: t, setStarted: true, setCompleted: true)];
    return [AnimeWrite(status: ListStatus.current, progress: n, setStarted: true)];
  }
  switch (remote.status) {
    case ListStatus.dropped:
      return const [];
    case ListStatus.completed:
      if (!countRewatches || n != 1) return const [];
      if (done(1)) return [AnimeWrite(status: ListStatus.completed, repeat: remote.repeat + 1, setCompleted: true)];
      return const [AnimeWrite(status: ListStatus.repeating), AnimeWrite(progress: 1)];
    case ListStatus.repeating:
      if (n <= remote.progress) return const [];
      if (done(n)) return [AnimeWrite(status: ListStatus.completed, progress: t, repeat: remote.repeat + 1, setCompleted: true)];
      return [AnimeWrite(progress: n)];
    case ListStatus.current:
    case ListStatus.planning:
    case ListStatus.paused:
      if (n <= remote.progress) return const [];
      if (done(n)) {
        return [AnimeWrite(status: ListStatus.completed, progress: clamp(n), setStarted: !remote.started, setCompleted: true)];
      }
      return [
        AnimeWrite(
          status: remote.status == ListStatus.current ? null : ListStatus.current,
          progress: clamp(n),
          setStarted: !remote.started,
        ),
      ];
  }
}
