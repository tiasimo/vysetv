import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/updater.dart';
import 'torrent_file_dialog.dart' show bytesLabel;

/// The update box: what's new, then the download and what happens after it. Sits over the whole
/// app and fits a phone as well as a desktop window.
///
/// There is only ever one: asked for while it's already up (Settings' own button and the
/// automatic check can both want it at the same moment), the second request does nothing.
Future<void> showUpdateDialog(BuildContext context) async {
  if (_open) return;
  _open = true;
  Updater.instance.shownThisRun = true;
  try {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: .6),
      builder: (_) => const _UpdateDialog(),
    );
  } finally {
    _open = false;
  }
}

bool _open = false;

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return ListenableBuilder(
      listenable: Updater.instance,
      builder: (context, _) {
        final up = Updater.instance;
        final u = up.info;
        final stage = up.stage;
        void close() => Navigator.of(context, rootNavigator: true).pop();

        final String title;
        final List<Widget> body;
        final List<Widget> actions;
        switch (stage) {
          case UpdateStage.downloading || UpdateStage.verifying:
            title = stage == UpdateStage.verifying ? 'Checking the download' : 'Downloading VyseTV ${u?.version ?? ''}';
            final total = up.file?.size ?? 0;
            body = [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: stage == UpdateStage.verifying ? null : up.progress,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: .08),
                  color: VyseColors.accent,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                stage == UpdateStage.verifying
                    ? 'Making sure it is exactly the release.'
                    : [
                        if (total > 0) '${bytesLabel(up.received)} of ${bytesLabel(total)}' else bytesLabel(up.received),
                        if (up.progress != null) '${(up.progress! * 100).floor()}%',
                      ].where((s) => s.isNotEmpty).join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ];
            actions = [if (stage == UpdateStage.downloading) TextButton(onPressed: up.cancel, child: const Text('Cancel'))];
          case UpdateStage.installing:
            title = Platform.isWindows || Platform.isLinux ? 'Restarting VyseTV' : 'Installing';
            body = [
              const Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent)),
                  SizedBox(width: 14),
                  Expanded(child: Text('Putting the new version in place. VyseTV closes and opens again by itself.', style: TextStyle(color: VyseColors.textDim, height: 1.45))),
                ],
              ),
            ];
            actions = const [];
          case UpdateStage.handedOver:
            title = 'Almost there';
            body = [
              Text(
                Platform.isAndroid
                    ? 'Android is asking whether to install the update. Tap Install there. If it asks to allow installs from VyseTV first, allow it and come back.'
                    : Platform.isMacOS
                    ? 'The disk image is open. Close VyseTV, drag the new VyseTV to Applications, then open it again.'
                    : 'The download opened in your browser. Install it from there.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [_primary('Done', close)];
          case UpdateStage.failed:
            title = "The update didn't go through";
            body = [Text(up.error ?? 'Something went wrong.', style: const TextStyle(color: VyseColors.textDim, height: 1.5))];
            actions = [
              TextButton(onPressed: close, child: const Text('Close')),
              if (up.newer != null) _primary('Try again', up.update),
            ];
          case UpdateStage.available when u != null:
            title = 'VyseTV ${u.version} is ready';
            body = [
              Text(
                ['You have ${up.current}', if (u.date.isNotEmpty) 'released ${u.date}', if ((up.file?.size ?? 0) > 0) bytesLabel(up.file!.size)].join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
              ),
              if (u.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(maxHeight: (size.height * .34).clamp(90, 280)),
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .04), borderRadius: BorderRadius.circular(10)),
                    child: SingleChildScrollView(
                      child: Text(u.notes, style: const TextStyle(fontSize: 13.5, height: 1.5, color: Color(0xFFD5D8E6))),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text('${up.how}.', style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
            ];
            actions = [
              TextButton(
                onPressed: () {
                  up.skip(u.version);
                  close();
                },
                child: const Text('Skip this version'),
              ),
              TextButton(onPressed: close, child: const Text('Later')),
              _primary('Update', up.update),
            ];
          default:
            title = up.stage == UpdateStage.checking ? 'Checking for updates' : "You're up to date";
            body = [
              Text(
                up.stage == UpdateStage.checking ? 'One moment.' : 'VyseTV ${up.current} is the newest version.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [TextButton(onPressed: close, child: const Text('Close'))];
        }

        return PopScope(
          // while it's fetching or installing there's nothing behind the box to go back to
          canPop: !up.busy || stage == UpdateStage.checking,
          child: Dialog(
            backgroundColor: VyseColors.surface,
            insetPadding: EdgeInsets.symmetric(horizontal: size.width < 520 ? 16 : 24, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: VyseColors.stroke)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.accent.withValues(alpha: .14)),
                          child: Icon(stage == UpdateStage.failed ? Icons.error_outline_rounded : Icons.system_update_alt_rounded, color: VyseColors.accent, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.2))),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ...body,
                    const SizedBox(height: 14),
                    if (actions.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: actions),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _primary(String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: FilledButton(
      style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    ),
  );
}
