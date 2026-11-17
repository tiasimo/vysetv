import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/match_finder.dart';
import '../data/sports_schedule.dart';
import 'media_rows.dart';

const _tileBg = Color(0xFF0D0F18);

String hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Red LIVE pill with the clock, as on the player.
class LivePill extends StatelessWidget {
  const LivePill(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xFFE5383B), borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.circle, size: 6, color: Colors.white),
          const SizedBox(width: 4),
          Text(text.isEmpty ? 'IN DIRETTA' : 'IN DIRETTA  $text',
              style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: .4, color: Colors.white)),
        ]),
      );
}

class TeamBadge extends StatelessWidget {
  const TeamBadge({super.key, required this.url, this.size = 40});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: url == null
            ? Icon(Icons.shield_outlined, size: size * .7, color: VyseColors.textFaint)
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.contain,
                fadeInDuration: const Duration(milliseconds: 250),
                errorWidget: (_, _, _) => Icon(Icons.shield_outlined, size: size * .7, color: VyseColors.textFaint),
              ),
      );
}

/// A fixture as a flat card: league and kick-off up top, the two crests face to face, and where
/// it's on along the bottom. White outline on hover like every other card.
class MatchCard extends StatelessWidget {
  const MatchCard({super.key, required this.match, required this.onTap});
  final Match match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = match;
    final live = m.state == MatchState.live;
    return OutlineCard(
      label: m.name,
      radius: 10,
      onTap: onTap,
      builder: (hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        color: hovered ? VyseColors.surfaceHi : _tileBg,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (m.leagueLogo != null) ...[TeamBadge(url: m.leagueLogo, size: 16), const SizedBox(width: 7)],
            Expanded(
              child: Text(m.league.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
            ),
            if (live)
              LivePill(m.status)
            else
              Text(m.state == MatchState.finished ? m.status : hhmm(m.start),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: m.state == MatchState.finished ? VyseColors.textFaint : VyseColors.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
          ]),
          const Spacer(),
          if (m.hasTeams)
            Row(children: [
              Expanded(child: _Side(team: m.home!)),
              SizedBox(
                width: 64,
                child: Text(
                  m.state == MatchState.upcoming ? 'vs' : '${m.home!.score ?? '-'}  ${m.away!.score ?? '-'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: m.state == MatchState.upcoming ? 13 : 20,
                    fontWeight: FontWeight.w800,
                    color: m.state == MatchState.upcoming ? VyseColors.textFaint : VyseColors.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(child: _Side(team: m.away!)),
            ])
          else
            Row(children: [
              TeamBadge(url: m.leagueLogo, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(m.name,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.2)),
              ),
            ]),
          const Spacer(),
          Row(children: [
            Icon(Icons.live_tv_rounded, size: 13, color: hovered ? VyseColors.accent : VyseColors.textFaint),
            const SizedBox(width: 6),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: MatchFinder.found,
                builder: (context, found, _) {
                  // Exact feeds first once known ("beIN Sports 2 · AR"), else the channel names.
                  final exact = found[m.id] ?? const {};
                  final channels = m.channels.take(3).map((c) => exact[c.id]?.firstOrNull ?? c.name).join('   ');
                  return Text(channels.isEmpty ? 'Cerca nei tuoi portali' : channels,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: hovered ? VyseColors.textDim : VyseColors.textFaint));
                },
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.team});
  final Team team;

  @override
  Widget build(BuildContext context) => Column(children: [
        TeamBadge(url: team.logo, size: 38),
        const SizedBox(height: 6),
        Text(team.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]);
}
