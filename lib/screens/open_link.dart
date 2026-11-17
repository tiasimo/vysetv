import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/debrid/debrid.dart';
import '../data/outside_play.dart';
import '../data/torrent_file_ask.dart';
import '../data/torrents.dart';
import '../widgets/common.dart';
import '../widgets/p2p_consent.dart';
import '../widgets/torrent_file_dialog.dart';
import 'player_page.dart';

/// Something pasted into Search that isn't a search: a link to a video, or a magnet link.
class PastedLink {
  const PastedLink.web(String this.url) : magnet = null;
  const PastedLink.torrent(MagnetLink this.magnet) : url = null;

  final String? url;
  final MagnetLink? magnet;

  bool get isMagnet => magnet != null;

  /// Null when [text] is ordinary words.
  static PastedLink? parse(String text) {
    final t = text.trim();
    if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;
    final m = MagnetLink.parse(t);
    if (m != null) return PastedLink.torrent(m);
    final uri = Uri.tryParse(t);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.contains('.') && uri.host.length > 3) {
      return PastedLink.web(t);
    }
    return null;
  }

  /// What plays, in a few words.
  String get what => isMagnet ? (magnet!.name ?? 'Torrent ${magnet!.hash.substring(0, 8)}…') : titleOfLink(url!);

  /// How it will play.
  String get how {
    if (!isMagnet) return Uri.tryParse(url!)?.host ?? 'Un link';
    if (Debrid.active) return 'Tramite ${Debrid.name}';
    return 'Peer to peer';
  }
}

/// Opens the player on [playback]: a link, a magnet's file, or a download.
Future<void> playDirect(BuildContext context, DirectPlayback playback) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => PlayerPage(media: playback.media, server: playback),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// Plays a pasted link. A magnet link goes through your debrid service when one is on,
/// otherwise peer to peer (asking first, if P2P streaming hasn't been allowed); either way its
/// files are listed and the one you pick plays.
Future<void> playPastedLink(BuildContext context, PastedLink link) async {
  if (!link.isMagnet) {
    return playDirect(context, DirectPlayback(title: titleOfLink(link.url!), url: link.url!));
  }
  final m = link.magnet!;
  final root = Navigator.of(context, rootNavigator: true);
  var calledOff = false;
  Future<int?> ask(List<TorrentFileChoice> files, String via) =>
      root.mounted && !calledOff ? askTorrentFile(root.context, files, torrent: m.name, via: via) : Future.value(null);

  void failed(Object e) {
    if (!root.mounted) return;
    final text = switch (e) {
      TimeoutException() => 'Nessun peer ha risposto per questo torrent.',
      StateError(:final message) => message,
      _ => e.toString().replaceFirst(RegExp(r'^(Exception|Error): ?'), ''),
    };
    showToast(root.context, Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
  }

  if (Debrid.active) {
    final name = Debrid.name;
    try {
      final file = await _busy(root, 'Chiedo a $name questo torrent…', () => Debrid.resolveMagnet(m.uri, ask: (files) => ask(files, 'Tramite $name')), onCancel: () => calledOff = true);
      if (file == null || !root.mounted) return;
      await playDirect(
        root.context,
        DirectPlayback(title: _titleOf(file.filename, m), url: file.downloadUrl, hls: false, label: name, note: 'Dal tuo link magnet'),
      );
    } on TorrentFileNotChosen {
      return;
    } catch (e) {
      failed(e);
    }
    return;
  }

  if (!Torrents.supported) {
    showToast(context, const Text("Questo dispositivo non può riprodurre torrent. Attiva un servizio debrid nelle Impostazioni per i link magnet.", style: TextStyle(fontSize: 13)), icon: Icons.error_outline_rounded);
    return;
  }
  if (!await allowP2p(context)) return; // asks only when P2P streaming is off
  if (!root.mounted) return;
  String? chosen;
  var opened = false;
  try {
    final url = await _busy(
      root,
      'Ricerca di peer…',
      () => Torrents.open(
        m.hash,
        trackers: m.trackers,
        title: m.name,
        ask: (files) async {
          final i = await ask(files, 'Peer to peer');
          if (i != null) chosen = files[i].name;
          return i;
        },
      ),
      onCancel: () => calledOff = true,
    );
    if (url == null || !root.mounted) {
      unawaited(Torrents.release(m.hash)); // called off while it was still looking
      return;
    }
    opened = true;
    await playDirect(
      root.context,
      DirectPlayback(
        title: _titleOf(chosen ?? m.name ?? '', m),
        url: url,
        hls: false,
        label: 'Torrent',
        note: 'Peer to peer, dal tuo link magnet',
        onClose: () => Torrents.release(m.hash),
      ),
    );
  } on TorrentFileNotChosen {
    unawaited(Torrents.release(m.hash));
  } catch (e) {
    if (!opened) unawaited(Torrents.release(m.hash));
    failed(e);
  }
}

/// The file's own name without its folders or ending, or the torrent's.
String _titleOf(String file, MagnetLink m) {
  final base = file.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
  final name = base.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '').replaceAll(RegExp(r'[._]+'), ' ').trim();
  return name.isNotEmpty ? name : (m.name ?? 'Torrent');
}

/// A small "working on it" box over the app while [work] runs, with a way to call it off.
/// Null when it was called off (the work's answer is then dropped).
Future<T?> _busy<T>(NavigatorState root, String text, Future<T> Function() work, {VoidCallback? onCancel}) async {
  var open = true;
  Object? error;
  StackTrace? trace;
  final dialog = showDialog<T>(
    context: root.context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: .5),
    builder: (ctx) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          color: VyseColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: VyseColors.stroke)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 10, 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent)),
                const SizedBox(width: 14),
                Flexible(child: Text(text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    if (open) {
                      open = false;
                      onCancel?.call();
                      Navigator.of(ctx, rootNavigator: true).pop();
                    }
                  },
                  child: const Text('Annulla'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  unawaited(work().then<void>(
    (value) {
      if (open && root.mounted) {
        open = false;
        root.pop(value);
      }
    },
    onError: (Object e, StackTrace s) {
      error = e;
      trace = s;
      if (open && root.mounted) {
        open = false;
        root.pop();
      }
    },
  ));
  final result = await dialog;
  if (error != null) Error.throwWithStackTrace(error!, trace ?? StackTrace.current);
  return result;
}
