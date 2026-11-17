import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/torrent_file_ask.dart';
import 'common.dart';

/// "1.4 GB", "730 MB".
String bytesLabel(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble(), u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v >= 100 || u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}

/// Lists a torrent's files and answers the place of the one picked, or null when it's closed.
/// Sits over the whole app (navbar included) and fits a phone as well as a desktop window.
Future<int?> askTorrentFile(BuildContext context, List<TorrentFileChoice> files, {String? torrent, String? via}) {
  return showDialog<int>(
    context: context,
    useRootNavigator: true,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        backgroundColor: VyseColors.surface,
        insetPadding: EdgeInsets.symmetric(horizontal: size.width < 520 ? 14 : 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: VyseColors.stroke)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * .78),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(files.length == 1 ? 'Riprodurre questo file?' : 'Quale file?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (torrent != null && torrent.isNotEmpty) torrent,
                              files.length == 1 ? '1 file' : '${files.length} file',
                              ?via,
                            ].join('  ·  '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Annulla',
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(Icons.close_rounded, size: 20, color: VyseColors.textDim),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: VyseColors.stroke),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 20), color: VyseColors.stroke),
                  itemBuilder: (_, i) => _FileRow(file: files[i], autofocus: i == 0, onTap: () => Navigator.pop(ctx, i)),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.onTap, this.autofocus = false});
  final TorrentFileChoice file;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // the file's own name, with the folders it sits in underneath
    final parts = file.name.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
    final name = parts.isEmpty ? file.name : parts.last;
    final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join(' / ') : '';
    final size = bytesLabel(file.size);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => ColoredBox(
        color: hovered ? VyseColors.ink.withValues(alpha: .06) : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 11, 14, 11),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline_rounded, size: 20, color: hovered ? VyseColors.accent : VyseColors.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3)),
                    if (folder.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
                    ],
                  ],
                ),
              ),
              if (size.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(size, style: TextStyle(fontSize: 12, color: VyseColors.textDim, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
