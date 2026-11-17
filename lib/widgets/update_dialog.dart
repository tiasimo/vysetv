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
            title = stage == UpdateStage.verifying ? 'Controllo il download' : 'Downloading Lorewatch ${u?.version ?? ''}';
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
                    ? 'Controllo che sia esattamente la versione pubblicata.'
                    : [
                        if (total > 0) '${bytesLabel(up.received)} di ${bytesLabel(total)}' else bytesLabel(up.received),
                        if (up.progress != null) '${(up.progress! * 100).floor()}%',
                      ].where((s) => s.isNotEmpty).join('  ·  '),
                style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ];
            actions = [if (stage == UpdateStage.downloading) TextButton(onPressed: up.cancel, child: const Text('Annulla'))];
          case UpdateStage.installing:
            title = Platform.isWindows || Platform.isLinux ? 'Riavvio di Lorewatch' : 'Installazione';
            body = [
              const Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: VyseColors.accent)),
                  SizedBox(width: 14),
                  Expanded(child: Text('Metto al suo posto la nuova versione. Lorewatch si chiude e si riapre da solo.', style: TextStyle(color: VyseColors.textDim, height: 1.45))),
                ],
              ),
            ];
            actions = const [];
          case UpdateStage.handedOver:
            title = 'Ci siamo quasi';
            body = [
              Text(
                Platform.isAndroid
                    ? 'Android chiede se installare l\'aggiornamento. Tocca Installa. Se prima chiede di consentire le installazioni da Lorewatch, consentile e torna qui.'
                    : Platform.isMacOS
                    ? 'L\'immagine disco è aperta. Chiudi Lorewatch, trascina il nuovo Lorewatch in Applicazioni, poi riaprilo.'
                    : 'Il download si è aperto nel browser. Installalo da lì.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [_primary('Fatto', close)];
          case UpdateStage.failed:
            title = "L'aggiornamento non è andato a buon fine";
            body = [Text(up.error ?? 'Qualcosa è andato storto.', style: const TextStyle(color: VyseColors.textDim, height: 1.5))];
            actions = [
              TextButton(onPressed: close, child: const Text('Chiudi')),
              if (up.newer != null) _primary('Riprova', up.update),
            ];
          case UpdateStage.available when u != null:
            title = 'Lorewatch ${u.version} è pronto';
            body = [
              Text(
                ['You have ${up.current}', if (u.date.isNotEmpty) 'pubblicato il ${u.date}', if ((up.file?.size ?? 0) > 0) bytesLabel(up.file!.size)].join('  ·  '),
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
                child: const Text('Salta questa versione'),
              ),
              TextButton(onPressed: close, child: const Text('Più tardi')),
              _primary('Aggiorna', up.update),
            ];
          default:
            title = up.stage == UpdateStage.checking ? 'Controllo aggiornamenti' : "Sei aggiornato";
            body = [
              Text(
                up.stage == UpdateStage.checking ? 'Un momento.' : 'Lorewatch ${up.current} è la versione più recente.',
                style: const TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
            ];
            actions = [TextButton(onPressed: close, child: const Text('Chiudi'))];
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
