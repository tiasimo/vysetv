import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/downloads.dart';
import '../data/outside_play.dart';
import '../data/stream_proxy.dart';
import '../widgets/common.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import '../widgets/torrent_file_dialog.dart' show bytesLabel;
import 'open_link.dart';

/// Downloads: what you saved from the player's More menu. What's still coming shows how far it
/// is; what's finished plays in the player, with or without the internet.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    Downloads.instance.initialize();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _play(DownloadItem d) async {
    final String url;
    if (d.isFolder) {
      // a saved stream opens as a stream does, from this device
      url = '${await StreamProxy.instance.serveFolder(d.path)}/index.m3u8';
    } else {
      url = d.path;
    }
    if (!mounted) return;
    final at = Duration(milliseconds: d.positionMs);
    final resume = d.positionMs > 5000 && (d.durationMs == 0 || d.positionMs < d.durationMs * .95) ? at : null;
    await playDirect(
      context,
      DirectPlayback(
        title: [d.title, if (d.detail.isNotEmpty) d.detail.split(' · ').first].join(' · '),
        url: url,
        hls: d.isFolder,
        label: 'Scaricato',
        note: 'Su questo dispositivo',
        resumeAt: resume,
        downloadable: false,
        poster: d.poster,
        onProgress: (p, dur) => Downloads.instance.remember(d, p, dur),
      ),
    );
  }

  /// Shows the file in the system's file manager, or says where it is where there's none to open.
  Future<void> _reveal(String path, {required bool folder}) async {
    final dir = folder ? path : File(path).parent.path;
    var ok = false;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', folder ? [path] : ['/select,', path]);
        ok = true;
      } else if (Platform.isMacOS || Platform.isLinux) {
        ok = await launchUrl(Uri.directory(dir));
      }
    } catch (_) {}
    if (ok || !mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Dov\'è', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(width: 380, child: SelectableText(path, style: TextStyle(color: VyseColors.textDim, height: 1.45, fontSize: 13))),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              Navigator.pop(ctx);
            },
            child: const Text('Copia'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi')),
        ],
      ),
    );
  }

  Future<void> _remove(DownloadItem d) async {
    final done = d.state == DownloadState.done;
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(done ? 'Eliminare questo download?' : 'Fermare e rimuovere questo download?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 380,
          child: Text(
            done ? '${d.title} viene eliminato da questo dispositivo.' : "Quello che è stato scaricato finora di ${d.title} verrà eliminato.",
            style: TextStyle(color: VyseColors.textDim, height: 1.45),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Tienilo')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(done ? 'Elimina' : 'Rimuovi', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok == true) await Downloads.instance.remove(d);
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final side = phone ? 16.0 : Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.windowChrome(context) + (phone ? 12 : 24);
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    return ColoredBox(
      color: VyseColors.bg,
      child: ListenableBuilder(
        listenable: Downloads.instance,
        builder: (context, _) {
          final all = Downloads.instance.items;
          final coming = all.where((d) => d.state == DownloadState.running || d.state == DownloadState.queued).length;
          final done = all.where((d) => d.state == DownloadState.done).length;
          return PageScrollbar(
            controller: _scroll,
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, top, right, 0),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Scarica', style: TextStyle(fontSize: phone ? 26 : 34, fontWeight: FontWeight.w900, letterSpacing: -.8)),
                                  const SizedBox(height: 6),
                                  Text(
                                    all.isEmpty
                                        ? 'Quello che scarichi dal player compare qui'
                                        : [
                                            if (done > 0) '$done pronti da guardare',
                                            if (coming > 0) '$coming in download',
                                            if (all.length - done - coming > 0) '${all.length - done - coming} fermati',
                                          ].join('  ·  '),
                                    style: TextStyle(fontSize: phone ? 12.5 : 14, color: VyseColors.textDim, fontWeight: FontWeight.w500),
                                  ),
                                ],
                              ),
                            ),
                            if (desktop)
                              _Action(
                                icon: Icons.folder_open_rounded,
                                label: phone ? null : 'Apri cartella',
                                tooltip: 'Apri la cartella dei download',
                                onTap: () async => _reveal((await Downloads.instance.root()).path, folder: true),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (all.isEmpty)
                  const SliverToBoxAdapter(
                    child: EmptyState(
                      icon: Icons.download_outlined,
                      title: 'Ancora nessun download',
                      body: "Mentre un video è in riproduzione, apri il menu Altro del player e scegli Scarica.",
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(side, phone ? 18 : 26, right, 0),
                    sliver: SliverList.separated(
                      itemCount: all.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1080),
                          child: _DownloadCard(
                            key: ValueKey(all[i].id),
                            item: all[i],
                            phone: phone,
                            onPlay: () => _play(all[i]),
                            onReveal: () => _reveal(all[i].path, folder: all[i].isFolder),
                            onRemove: () => _remove(all[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _clock(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
}

String _left(int seconds) {
  if (seconds < 60) return 'meno di un minuto';
  if (seconds < 3600) return '${(seconds / 60).round()} min rimanenti';
  final h = seconds ~/ 3600, m = ((seconds % 3600) / 60).round();
  return m == 0 ? '$h h rimanenti' : '$h h $m min rimanenti';
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({super.key, required this.item, required this.phone, required this.onPlay, required this.onReveal, required this.onRemove});
  final DownloadItem item;
  final bool phone;
  final VoidCallback onPlay;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  String get _status {
    final d = item;
    final got = bytesLabel(d.received), size = bytesLabel(d.expected);
    final pct = d.progress == null ? null : '${(d.progress! * 100).floor()}%';
    return switch (d.state) {
      DownloadState.queued => 'In attesa del suo turno',
      DownloadState.running => [
        if (got.isEmpty) (d.kind == DownloadKind.torrent ? 'Ricerca di peer…' : 'Avvio…') else size.isEmpty ? got : '$got di $size',
        ?pct,
        if (d.speed >= 1024) '${bytesLabel(d.speed.round())}/s' else if (d.kind == DownloadKind.torrent && got.isNotEmpty) 'in attesa di peer',
        if (d.secondsLeft case final s?) _left(s),
      ].join('  ·  '),
      DownloadState.paused => ['Paused', ?pct, if (got.isNotEmpty) got].join('  ·  '),
      DownloadState.failed => d.error ?? "Non è stato possibile scaricarlo.",
      DownloadState.done => [
        if (bytesLabel(d.total).isNotEmpty) bytesLabel(d.total),
        if (d.positionMs > 5000 && (d.durationMs == 0 || d.positionMs < d.durationMs * .95)) 'fermato a ${_clock(d.positionMs ~/ 1000)}' else 'Pronto da guardare',
      ].join('  ·  '),
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = item;
    final done = d.state == DownloadState.done;
    final failed = d.state == DownloadState.failed;
    final live = d.state == DownloadState.running || d.state == DownloadState.queued;
    final mobile = Platform.isAndroid || Platform.isIOS;

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: phone ? 52 : 60,
        height: phone ? 78 : 90,
        child: d.poster == null
            ? ColoredBox(color: VyseColors.surfaceHi, child: Icon(Icons.movie_outlined, color: VyseColors.textFaint, size: 22))
            : NetImage(url: d.poster!),
      ),
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: phone ? 14.5 : 16, fontWeight: FontWeight.w800, height: 1.2)),
        if (d.detail.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(d.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
        ],
        const SizedBox(height: 8),
        if (!done) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              // null while there's nothing to measure against: the bar runs back and forth
              value: d.state == DownloadState.running && d.progress == null ? null : (d.progress ?? 0),
              minHeight: 5,
              backgroundColor: VyseColors.ink.withValues(alpha: .08),
              color: failed ? const Color(0xFFFF6B6B) : (d.state == DownloadState.paused ? VyseColors.textFaint : VyseColors.accent),
            ),
          ),
          const SizedBox(height: 7),
        ],
        Text(
          _status,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 1.35,
            color: failed ? const Color(0xFFFF9C9C) : VyseColors.textDim,
            fontWeight: FontWeight.w500,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    final actions = <Widget>[
      if (done) _Action(icon: Icons.play_arrow_rounded, label: 'Riproduci', primary: true, onTap: onPlay),
      if (live) _Action(icon: Icons.pause_rounded, label: phone ? null : 'Pausa', tooltip: 'Pausa', onTap: () => Downloads.instance.pause(d)),
      if (d.state == DownloadState.paused) _Action(icon: Icons.play_arrow_rounded, label: 'Riprendi', onTap: () => Downloads.instance.resume(d)),
      if (failed) _Action(icon: Icons.refresh_rounded, label: 'Riprova', onTap: () => Downloads.instance.resume(d)),
      if (done)
        _Action(
          icon: mobile ? Icons.info_outline_rounded : Icons.folder_open_rounded,
          label: phone ? null : (mobile ? 'Dov\'è' : 'Apri cartella'),
          tooltip: mobile ? 'Dov\'è' : 'Apri cartella',
          onTap: onReveal,
        ),
      _Action(icon: Icons.delete_outline_rounded, tooltip: done ? 'Elimina' : 'Rimuovi', danger: true, onTap: onRemove),
    ];

    return Container(
      padding: EdgeInsets.all(phone ? 12 : 14),
      decoration: BoxDecoration(
        color: VyseColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VyseColors.stroke),
      ),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(width: 12), Expanded(child: text)]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: actions),
              ],
            )
          : Row(
              children: [
                poster,
                const SizedBox(width: 16),
                Expanded(child: text),
                const SizedBox(width: 16),
                Wrap(spacing: 8, children: actions),
              ],
            ),
    );
  }
}

/// A small button: an icon, and a word when there's room.
class _Action extends StatelessWidget {
  const _Action({required this.icon, this.label, this.tooltip, required this.onTap, this.primary = false, this.danger = false});
  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip ?? label,
    onTap: onTap,
    builder: (context, hovered, pressed) {
      final fg = primary ? VyseColors.onStrong : (danger && hovered ? const Color(0xFFFF8A8C) : VyseColors.text);
      return AnimatedScale(
        scale: pressed ? .96 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 38,
          padding: EdgeInsets.symmetric(horizontal: label == null ? 10 : 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            color: primary
                ? (hovered ? VyseColors.strong : VyseColors.pick(0xFFF1F1F5, 0xFF1C1E28))
                : danger && hovered
                ? const Color(0xFFFF4D4F).withValues(alpha: .16)
                : VyseColors.ink.withValues(alpha: hovered ? .14 : .07),
            border: primary ? null : Border.all(color: VyseColors.ink.withValues(alpha: .08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              if (label != null) ...[
                const SizedBox(width: 7),
                Text(label!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
              ],
            ],
          ),
        ),
      );
    },
  );
}
