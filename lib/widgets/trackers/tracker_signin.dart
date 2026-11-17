import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/trackers/loopback_auth.dart';
import '../../data/trackers/tracker.dart';
import '../../data/trackers/tracker_hub.dart';
import '../../data/trackers/tracker_keys.dart';
import '../common.dart';
import '../service_logos.dart';
import 'import_dialog.dart';

/// Lorewatch: the browser sign-in works on phones and tablets too (the browser comes back to a
/// tiny server inside the app on this same device), so every platform but the web uses it.
bool get _native => !kIsWeb;

/// Connects AniList. It signs in through the browser and comes back by itself, on a computer,
/// a phone or a tablet; AniList can also take a pasted token.
Future<void> connectTracker(BuildContext context, TrackerId id) async {
  if (id == TrackerId.simkl || id == TrackerId.trakt) return _connectByCode(context, id);
  final browser = _native && TrackerKeys.anilistClientId.isNotEmpty;
  final paste = id == TrackerId.anilist && TrackerKeys.anilistPinClientId.isNotEmpty;
  if (!browser && !paste) {
    showToast(
      context,
      Text('Per ora collega ${id.label} da Lorewatch su un computer', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      icon: Icons.computer_rounded,
    );
    return;
  }
  final name = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SignIn(id: id, browser: browser, paste: paste),
  );
  if (name == null || !context.mounted) return;
  _connected(context, id, name);
}

/// Says so, then offers to bring in what's already there.
void _connected(BuildContext context, TrackerId id, String name) {
  showToast(
    context,
    Text(name.isEmpty ? '${id.label} collegato' : '${id.label} collegato come $name', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    icon: Icons.check_circle_rounded,
  );
  importFromTracker(context, id);
}

class _SignIn extends StatefulWidget {
  const _SignIn({required this.id, required this.browser, required this.paste});
  final TrackerId id;
  final bool browser; // sign in through the browser, coming back by itself
  final bool paste; // AniList: paste a token instead

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  final _token = TextEditingController();
  late bool _pasting = !widget.browser;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.browser) _viaBrowser();
  }

  @override
  void dispose() {
    TrackerHub.cancelSignIn();
    _token.dispose();
    super.dispose();
  }

  Future<void> _viaBrowser() async {
    setState(() => _error = null);
    try {
      final name = await TrackerHub.connectAniList();
      if (mounted) Navigator.pop(context, name);
    } on LoopbackException catch (e) {
      if (!e.cancelled && mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _usePasted() async {
    final t = _token.text.trim();
    if (t.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await TrackerHub.connectAniListToken(t);
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (mounted) setState(() => _error = "Quel token non ha funzionato. Copialo tutto e riprova.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _switchToPaste() {
    TrackerHub.cancelSignIn();
    setState(() {
      _pasting = true;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: VyseColors.textDim, height: 1.5);
    return AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: _title(widget.id),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_pasting) ...[
              Text('Completa l\'accesso nel browser, poi torna in Lorewatch: lo rileva da solo.', style: dim),
              if (_error == null) ...[
                const SizedBox(height: 16),
                SizedBox(height: 3, child: LinearProgressIndicator(color: VyseColors.accent, backgroundColor: VyseColors.ink.withValues(alpha: .10))),
              ],
              if (widget.paste) ...[
                const SizedBox(height: 10),
                TextButton(onPressed: _switchToPaste, child: const Text('Incolla invece un token')),
              ],
            ] else ...[
              Text('Apri AniList, approva Lorewatch, poi copia il token che mostra e incollalo qui.', style: dim),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => TrackerHub.openAniListTokenPage().catchError((Object _) {}),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Apri AniList'),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _token,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Incolla il token', isDense: true),
                onSubmitted: (_) => _usePasted(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF8A8C), fontSize: 13, height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        if (!_pasting && _error != null) TextButton(onPressed: _viaBrowser, child: const Text('Riprova')),
        if (_pasting)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
            onPressed: _busy ? null : _usePasted,
            child: const Text('Collega', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
      ],
    );
  }
}

/// Simkl and Trakt: a short code to enter on their site (the button opens the page).
Future<void> _connectByCode(BuildContext context, TrackerId id) async {
  final name = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => _DeviceCodeDialog(id: id));
  if (name == null || !context.mounted) return;
  _connected(context, id, name);
}

class _DeviceCodeDialog extends StatefulWidget {
  const _DeviceCodeDialog({required this.id});
  final TrackerId id;

  @override
  State<_DeviceCodeDialog> createState() => _DeviceCodeDialogState();
}

class _DeviceCodeDialogState extends State<_DeviceCodeDialog> {
  DeviceCode? _code;
  String? _error;
  bool _closed = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _code != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _closed = true;
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final connect = widget.id == TrackerId.trakt ? TrackerHub.connectTrakt : TrackerHub.connectSimkl;
      final name = await connect(
        onCode: (c) {
          if (mounted) setState(() => _code = c);
        },
        cancelled: () => _closed,
      );
      if (mounted) Navigator.pop(context, name);
    } catch (e) {
      if (!_closed && mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = TextStyle(color: VyseColors.textDim, height: 1.5);
    final c = _code;
    final left = c == null ? Duration.zero : c.expiresAt.difference(DateTime.now());
    final mins = left.inMinutes, secs = left.inSeconds % 60;
    return AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: _title(widget.id),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Color(0xFFFF8A8C), fontSize: 13, height: 1.4))
            else if (c == null)
              SizedBox(height: 3, child: LinearProgressIndicator(color: VyseColors.accent, backgroundColor: VyseColors.ink.withValues(alpha: .10)))
            else ...[
              Text('Vai su ${c.site} e inserisci questo codice. Lorewatch si collega appena lo approvi.', style: dim),
              const SizedBox(height: 16),
              Center(
                child: SelectableText(
                  c.userCode,
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 3, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  left > Duration.zero ? 'Expires in $mins:${secs.toString().padLeft(2, '0')}' : 'Expired',
                  style: TextStyle(color: VyseColors.textDim, fontSize: 12.5),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => TrackerHub.openPage(c.url).catchError((Object _) {}),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text('Apri ${c.site}'),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: c.userCode));
                      showToast(context, const Text('Codice copiato', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.copy_rounded);
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copia codice'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
        if (_error != null) TextButton(onPressed: _start, child: const Text('Riprova')),
      ],
    );
  }
}

/// "Connect Trakt" with the service's logo.
Widget _title(TrackerId id) => Row(children: [
  ServiceLogo(switch (id) {
    TrackerId.anilist => Service.anilist,
    TrackerId.simkl => Service.simkl,
    TrackerId.trakt => Service.trakt,
  }, size: 34),
  const SizedBox(width: 12),
  Expanded(child: Text('Collega ${id.label}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
]);
