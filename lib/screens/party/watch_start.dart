import 'package:flutter/material.dart';

import '../../data/account.dart';
import '../../data/party/party.dart';
import '../../data/party/rooms.dart';
import '../../data/party/watch_party.dart';
import '../../data/tmdb.dart' show Media;
import '../../data/watch_progress.dart';
import '../../widgets/common.dart';
import 'rooms_view.dart' show openRoom;

void _say(BuildContext context, String text, {IconData icon = Icons.groups_rounded}) => showToast(
  context,
  Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  icon: icon,
);

/// "Watch party" on a title: everyone in your room watches it with you. Shows pick up where you
/// left off, or start at episode 1 of [firstSeason].
Future<void> startWatchParty(BuildContext context, Media media, {int? firstSeason}) async {
  if (!Account.signedIn || !Party.joined) return _say(context, 'Sign in and join Party to watch together');
  if (Rooms.mine.value == null) return _say(context, 'Make or join a room in Party first: everyone in it watches with you');
  if (!WatchParty.canControl) return _say(context, "Only the room's host can start a watch party");
  int? season, episode;
  String? name;
  if (media.anime) {
    // numbered straight through: season 0, the episode you were on
    final saved = WatchProgress.find(media);
    season = media.isTv ? 0 : null;
    episode = media.isTv ? (saved?.episode ?? 1) : null;
    name = media.isTv ? saved?.episodeName : null;
  } else if (media.isTv) {
    final saved = WatchProgress.find(media);
    season = saved?.season ?? firstSeason ?? 1;
    episode = saved?.episode ?? 1;
    name = saved?.season == season ? saved?.episodeName : null;
  }
  final nav = Navigator.of(context);
  try {
    await WatchParty.host(media, season: season, episode: episode, episodeName: name, position: WatchProgress.resumeSeconds(media, season: season, episode: episode));
  } catch (e) {
    if (context.mounted) _say(context, Account.describe(e), icon: Icons.error_outline_rounded);
    return;
  }
  // it plays inside the room, like a screen share
  await openRoom(nav, theater: true);
}
