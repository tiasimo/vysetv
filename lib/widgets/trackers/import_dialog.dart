import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/trackers/library_import.dart';
import '../../data/trackers/tracker.dart';
import '../common.dart';

/// Reads what's on [id] and, once you say so, brings it into VyseTV.
Future<void> importFromTracker(BuildContext context, TrackerId id) async {
  final n = await showDialog<int>(context: context, barrierDismissible: false, builder: (_) => _ImportDialog(id: id));
  if (n == null || !context.mounted) return;
  showToast(
    context,
    Text(n == 0 ? 'Nothing new from ${id.label}' : 'Brought in $n from ${id.label}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    icon: Icons.download_done_rounded,
  );
}

String _watchlist(TrackerId id) => switch (id) {
  TrackerId.trakt => 'watchlist',
  TrackerId.simkl => 'plan to watch',
  TrackerId.anilist => 'Planning list',
};

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.id});
  final TrackerId id;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  ImportPlan? _plan;
  String? _error;
  bool _busy = false, _list = true, _watched = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _plan = null;
      _error = null;
    });
    try {
      final p = await LibraryImport.plan(widget.id);
      if (mounted) setState(() => _plan = p);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't read your ${widget.id.label} lists: $e");
    }
  }

  Future<void> _import() async {
    final p = _plan;
    if (p == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final n = await LibraryImport.apply(p, list: _list, watched: _watched);
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      if (mounted) setState(() => _error = 'The import stopped part-way: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _choice(String title, String subtitle, bool value, ValueChanged<bool> onChanged) => CheckboxListTile(
    value: value,
    onChanged: _busy ? null : (v) => setState(() => onChanged(v ?? false)),
    activeColor: VyseColors.accent,
    checkColor: Colors.black,
    contentPadding: EdgeInsets.zero,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle, style: const TextStyle(color: VyseColors.textDim, fontSize: 12.5)),
  );

  @override
  Widget build(BuildContext context) {
    const dim = TextStyle(color: VyseColors.textDim, height: 1.5);
    final p = _plan, label = widget.id.label;
    final nothing = p != null && p.isEmpty;
    return AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Import from $label', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p == null && _error == null) ...[
              Text('Reading your $label lists…', style: dim),
              const SizedBox(height: 16),
              const SizedBox(height: 3, child: LinearProgressIndicator(color: VyseColors.accent, backgroundColor: Colors.white10)),
            ] else if (nothing)
              Text('Everything on $label is already in VyseTV.', style: dim)
            else if (p != null) ...[
              Text('Found ${p.found} titles on $label. Nothing there changes.', style: dim),
              const SizedBox(height: 8),
              if (p.list.isNotEmpty)
                _choice(
                  'My List',
                  '${p.list.length} from your ${_watchlist(widget.id)}. New ones there keep coming in.',
                  _list,
                  (v) => _list = v,
                ),
              if (p.history.isNotEmpty || p.resume.isNotEmpty)
                _choice(
                  'History and Continue watching',
                  [
                    if (p.history.isNotEmpty) '${p.history.length} watched${p.history.length == LibraryImport.historyCap ? ' (the newest)' : ''}',
                    if (p.resume.isNotEmpty) '${p.resume.length} to pick up where you left off',
                  ].join(', '),
                  _watched,
                  (v) => _watched = v,
                ),
              if (_busy) ...[
                const SizedBox(height: 12),
                const SizedBox(height: 3, child: LinearProgressIndicator(color: VyseColors.accent, backgroundColor: Colors.white10)),
              ],
            ],
            if (_error != null) ...[
              if (p != null) const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF8A8C), fontSize: 13, height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  // all caught up: still follow the watchlist from here on
                  if (nothing) LibraryImport.apply(p, list: true, watched: false).ignore();
                  Navigator.pop(context);
                },
          child: Text(nothing ? 'Close' : 'Cancel'),
        ),
        if (_error != null && p == null) TextButton(onPressed: _load, child: const Text('Try again')),
        if (p != null && !nothing)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
            onPressed: _busy || !(_list && p.list.isNotEmpty || _watched && (p.history.isNotEmpty || p.resume.isNotEmpty)) ? null : _import,
            child: const Text('Import', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
      ],
    );
  }
}
