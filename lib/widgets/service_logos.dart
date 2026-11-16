import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Services VyseTV works with, drawn with their own marks (assets/logos, from Plezy).
enum Service {
  plex('plex_chevron', tile: [Color(0xFF2A2B30), Color(0xFF141518)], mark: [Color(0xFFEBAF00)], pad: .24),
  jellyfin('jellyfin_icon', tile: [Color(0xFF221D33), Color(0xFF0F1220)], mark: [Color(0xFFAA5CC3), Color(0xFF00A4DC)], pad: .2),
  emby('emby_icon', tile: [Color(0xFF1C2A1E), Color(0xFF0E1510)], mark: [Color(0xFF52B54B)], pad: .2),
  trakt('trakt_circlemark', tile: [Color(0xFFED2224), Color(0xFFB0122A)], mark: [Colors.white], pad: .18),
  simkl('simkl_mark', tile: [Color(0xFF1E2024), Color(0xFF0B0C0E)], mark: [Colors.white], pad: .24),
  anilist('anilist_mark', tile: [Color(0xFF1F2A3A), Color(0xFF0B1622)], mark: [Colors.white], pad: .2),
  mal('mal_mark', tile: [Color(0xFF3360C4), Color(0xFF223D7A)], mark: [Colors.white], pad: .14);

  const Service(this.file, {required this.tile, required this.mark, required this.pad});
  final String file;

  /// The tile behind the mark, top-left to bottom-right.
  final List<Color> tile;

  /// The mark's colour, or its gradient when there are two.
  final List<Color> mark;

  /// Space around the mark, as a share of the tile.
  final double pad;

  String get asset => 'assets/logos/$file.svg';

  /// The colour the service is known by, for glows and borders.
  Color get accent => this == Service.anilist ? const Color(0xFF02A9FF) : (mark.first == Colors.white ? tile.first : mark.first);
}

/// A service's mark on a rounded tile, like an app icon.
class ServiceLogo extends StatelessWidget {
  const ServiceLogo(this.service, {super.key, this.size = 32, this.glow = true});
  final Service service;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final s = service;
    Widget mark = SvgPicture.asset(
      s.asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      theme: SvgTheme(currentColor: s.mark.first),
    );
    if (s.mark.length > 1) {
      mark = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: s.mark).createShader(r),
        child: mark,
      );
    }
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * s.pad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .28),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: s.tile),
        border: Border.all(color: Colors.white.withValues(alpha: .09), width: size > 30 ? 1 : .6),
        boxShadow: [
          if (glow) BoxShadow(color: s.accent.withValues(alpha: .32), blurRadius: size * .45, offset: Offset(0, size * .1)),
        ],
      ),
      child: mark,
    );
  }
}
