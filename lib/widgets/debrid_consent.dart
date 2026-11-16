import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/debrid/debrid.dart';
import '../data/party/rooms.dart';

/// The room this device's owner already said yes for (until the app closes).
String? _allowedRoom;

/// Your room is about to play a torrent through your debrid account: everyone there plays the
/// link the service makes for you. Says what that means and asks, once per room.
/// False: cancelled, and nothing should start.
Future<bool> allowDebridInRoom(BuildContext context) async {
  final room = Rooms.mine.value?.id;
  if (room != null && room == _allowedRoom) return true;
  final name = Debrid.name;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      // phones: narrow margins, and the text scrolls when the screen is short (landscape);
      // the two buttons stack by themselves when they don't fit side by side
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      scrollable: true,
      title: Text('Share your $name link with the room?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 380,
        child: Text(
          'Everyone in your room will play the same link, the one $name makes with your account.\n\n'
          'People in the room could copy that link and use it elsewhere. $name will also see one account '
          'streaming from several places at once, which some services limit or block.\n\n'
          'This can put your account, and with some services your API key, at risk. Only allow it for people you trust.'
          '${Debrid.provider == DebridProvider.torBox ? '\n\nWith TorBox the link has your API key in it, so someone in the room could take the key.' : ''}',
          style: const TextStyle(color: VyseColors.textDim, height: 1.5),
        ),
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  _allowedRoom = room;
  return true;
}
