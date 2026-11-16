// VyseTV: hand the stream to another player app. Windows looks for the usual
// players where they install; Android asks the system (Plezy's
// ExternalPlayerChannel.kt, com.plezy/external_player). The stream URL is
// whatever VyseTV is playing — for torrents that's VyseTV's own local stream,
// so VyseTV has to stay open (paused) while the other app plays.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ExternalPlayer {
  const ExternalPlayer(this.name, this.exe, this._args);
  final String name;
  final String? exe; // Windows: the program; null on Android (system chooser)
  final List<String> Function(String url, Duration start, String? title, Map<String, String> headers) _args;

  static const _android = MethodChannel('com.plezy/external_player');

  /// The players this device has.
  static Future<List<ExternalPlayer>> available() async {
    if (kIsWeb) return const [];
    if (Platform.isAndroid) return [ExternalPlayer('Another app', null, (_, _, _, _) => const [])];
    if (!Platform.isWindows) return const [];
    final env = Platform.environment;
    final pf = env['ProgramFiles'] ?? r'C:\Program Files';
    final pf86 = env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    String? first(List<String> paths) {
      for (final p in paths) {
        if (p.isNotEmpty && File(p).existsSync()) return p;
      }
      return null;
    }

    final found = <ExternalPlayer>[];
    final vlc = first(['$pf\\VideoLAN\\VLC\\vlc.exe', '$pf86\\VideoLAN\\VLC\\vlc.exe']);
    if (vlc != null) {
      found.add(ExternalPlayer('VLC', vlc, (url, start, title, h) => [
        url,
        if (start > Duration.zero) '--start-time=${start.inSeconds}',
        if (title != null) '--meta-title=$title',
        if (h['User-Agent'] != null) '--http-user-agent=${h['User-Agent']}',
        if (h['Referer'] != null) '--http-referrer=${h['Referer']}',
      ]));
    }
    // No entry for a separate mpv: VyseTV's own player is mpv. The player's menu has
    // "Copy link" instead (player_page.dart), which works with any app.
    final mpc = first(['$pf\\MPC-HC\\mpc-hc64.exe', '$pf86\\MPC-HC\\mpc-hc.exe', '$pf\\MPC-BE x64\\mpc-be64.exe', '$pf\\MPC-BE\\mpc-be64.exe']);
    if (mpc != null) {
      found.add(ExternalPlayer(mpc.contains('MPC-BE') ? 'MPC-BE' : 'MPC-HC', mpc, (url, start, _, _) => [
        url,
        if (start > Duration.zero) ...['/start', '${start.inMilliseconds}'],
      ]));
    }
    final pot = first(['$pf\\DAUM\\PotPlayer\\PotPlayerMini64.exe', '$pf86\\DAUM\\PotPlayer\\PotPlayerMini.exe']);
    if (pot != null) {
      found.add(ExternalPlayer('PotPlayer', pot, (url, start, _, _) {
        String two(int n) => n.toString().padLeft(2, '0');
        return [url, if (start > Duration.zero) '/seek=${two(start.inHours)}:${two(start.inMinutes % 60)}:${two(start.inSeconds % 60)}'];
      }));
    }
    return found;
  }

  /// Opens [url] in this player. Returns null on success, otherwise what went wrong.
  Future<String?> open(String url, {Duration start = Duration.zero, String? title, Map<String, String> headers = const {}}) async {
    try {
      if (exe == null) {
        // Android answers only when the other app closes; an error (no app) comes at once.
        final call = _android.invokeMethod('openVideo', {'filePath': url, 'title': title, 'startPositionMs': start.inMilliseconds});
        try {
          await call.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          unawaited(call.catchError((Object _) => null));
        }
        return null;
      }
      await Process.start(exe!, _args(url, start, title, headers), mode: ProcessStartMode.detached);
      return null;
    } on PlatformException catch (e) {
      return e.code == 'APP_NOT_FOUND' ? 'No app on this device can play it' : "Couldn't open $name";
    } catch (_) {
      return "Couldn't open $name";
    }
  }
}
