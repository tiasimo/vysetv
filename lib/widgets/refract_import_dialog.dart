import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/refract_import.dart';
import '../data/tmdb.dart' show WatchStatus;
import 'common.dart';

/// Lorewatch: asks for a Refract backup, shows what's in it, then brings it into My List and
/// History with a progress bar.
Future<void> importFromRefract(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
  final file = picked?.files.firstOrNull;
  if (file == null || !context.mounted) return;
  Uint8List? bytes = file.bytes;
  if (bytes == null) {
    showToast(context, const Text('Impossibile leggere il file scelto.'), icon: Icons.error_outline_rounded);
    return;
  }
  List<RefractTitle> titles;
  try {
    titles = RefractImport.read(bytes, name: file.name);
  } on FormatException catch (e) {
    showToast(context, Text(e.message), icon: Icons.error_outline_rounded);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _RefractDialog(titles: titles));
}

class _RefractDialog extends StatefulWidget {
  const _RefractDialog({required this.titles});
  final List<RefractTitle> titles;

  @override
  State<_RefractDialog> createState() => _RefractDialogState();
}

class _RefractDialogState extends State<_RefractDialog> {
  int? _done; // null: not started
  int? _result;
  String? _error;

  int _count(bool tv) => widget.titles.where((t) => t.tv == tv).length;
  int _status(WatchStatus s) => widget.titles.where((t) => t.status == s).length;

  Future<void> _go() async {
    setState(() => _done = 0);
    try {
      final n = await RefractImport.apply(widget.titles, onProgress: (d, _) {
        if (mounted) setState(() => _done = d);
      });
      if (mounted) setState(() => _result = n);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: VyseColors.textDim, height: 1.5);
    final total = widget.titles.length;
    final running = _done != null && _result == null && _error == null;
    return AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Importa da Refract', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_result != null)
            Text('Fatto: $_result titoli sono in La mia lista, e quello che avevi già visto è nella Cronologia.', style: dim)
          else if (_error != null)
            Text('L\'importazione si è fermata: $_error', style: const TextStyle(color: Color(0xFFFF8A8C)))
          else if (running) ...[
            Text('Recupero i dettagli da TMDB: ${_done!} di $total…', style: dim),
            const SizedBox(height: 14),
            LinearProgressIndicator(value: total == 0 ? null : _done! / total, color: VyseColors.accent, backgroundColor: VyseColors.ink.withValues(alpha: .1)),
          ] else ...[
            Text('Nel backup ci sono $total titoli: ${_count(false)} film e ${_count(true)} serie.', style: dim),
            const SizedBox(height: 10),
            for (final s in WatchStatus.values)
              Text('•  ${s.label}: ${_status(s)}', style: dim),
            const SizedBox(height: 10),
            Text(
              'Finiscono in La mia lista, ciascuno nel suo stato. I film visti e gli episodi già visti vanno nella Cronologia. '
              'Quelli che hai già qui restano, e prendono lo stato di Refract.',
              style: dim,
            ),
          ],
        ]),
      ),
      actions: [
        if (_done == null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        if (_done == null)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
            onPressed: _go,
            child: const Text('Importa', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        if (_result != null || _error != null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Chiudi')),
      ],
    );
  }
}
