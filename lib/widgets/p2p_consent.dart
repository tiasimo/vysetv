import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/party/rooms.dart';
import '../data/party/watch_party.dart';

/// Before a torrent source plays with P2P streaming off: says what it means and asks.
/// Allow turns P2P streaming on (it can be turned off again in the Playback settings).
/// [who]: the room's host asking everyone, in a watch party.
Future<bool> allowP2p(BuildContext context, {String? who}) async {
  if (AppSettings.p2pStreaming.value) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Consentire lo streaming P2P?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 380,
        child: Text(
          '${who == null ? 'This source' : '$who wants to watch a source together that'} streams peer to peer, so you connect '
          'direttamente ad altre persone che lo condividono. Possono vedere il tuo indirizzo IP e il tuo provider.\n\n'
          'Consentire attiva lo streaming P2P. Puoi disattivarlo quando vuoi nelle impostazioni di Riproduzione.',
          style: TextStyle(color: VyseColors.textDim, height: 1.5),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Consenti', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  AppSettings.p2pStreaming.set(true);
  return true;
}

/// The host of a watch party picked a torrent: everyone else in the room is asked, and it only
/// plays once they've all allowed P2P streaming. False: cancelled.
Future<bool> allowP2pTogether(BuildContext context) async {
  List<RoomMember> others() => [for (final m in Rooms.mine.value?.members ?? const <RoomMember>[]) if (!m.isMe) m];
  if (others().isEmpty) return true;
  try {
    await WatchParty.askP2p();
  } catch (_) {
    return false;
  }
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _Waiting(others: others),
  );
  return ok == true;
}

class _Waiting extends StatefulWidget {
  const _Waiting({required this.others});
  final List<RoomMember> Function() others;

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> {
  final _all = Listenable.merge([WatchParty.p2pReplies, Rooms.mine]);

  @override
  void initState() {
    super.initState();
    _all.addListener(_check);
  }

  @override
  void dispose() {
    _all.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final r = WatchParty.p2pReplies.value;
    if (mounted && widget.others().every((m) => r[m.id] == true)) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _all,
    builder: (context, _) {
      final r = WatchParty.p2pReplies.value;
      return AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('In attesa di tutti', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This source streams peer to peer, so everyone in the room needs P2P streaming on first. '
                "It starts once they've all allowed it.",
                style: TextStyle(color: VyseColors.textDim, height: 1.5),
              ),
              const SizedBox(height: 14),
              for (final m in widget.others())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(m.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(
                        switch (r[m.id]) { true => 'Consentito', false => 'Ha detto no', null => 'In attesa…' },
                        style: TextStyle(color: r[m.id] == true ? VyseColors.accent : VyseColors.textDim, fontSize: 13),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla'))],
      );
    },
  );
}
