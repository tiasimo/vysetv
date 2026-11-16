import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/party/friends.dart';
import '../../data/party/rooms.dart';
import '../../widgets/common.dart';
import 'party_widgets.dart';
import 'room_page.dart';

/// Opens your room in the current tab (or goes back to it when it's open there already). Being in
/// a room means being in its voice call, so the page connects it. [theater]: the watch party
/// fills the window.
Future<void> openRoom(NavigatorState nav, {bool theater = false}) async {
  if (theater) RoomPage.theater.value = true;
  if (RoomPage.isOpenIn(nav)) {
    nav.popUntil((r) => r.settings.name == 'room');
    return;
  }
  await nav.push(
    ShellRoute(
      settings: const RouteSettings(name: 'room'),
      child: const RoomPage(),
    ),
  );
}

void _error(BuildContext context, Object e) => showToast(
  context,
  Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  icon: Icons.error_outline_rounded,
);

/// The rooms, Discord-style: one line per room (its name, who's in it underneath), yours on top.
/// A panel beside the page on wide screens ([panel]), a plain list in the page otherwise.
class PartyRoomsPanel extends StatelessWidget {
  const PartyRoomsPanel({super.key, this.panel = false, this.topPadding = 0});
  final bool panel;
  final double topPadding;

  static const _bg = Color(0xFF0A0B13);

  Future<void> _join(BuildContext context, PartyRoom r) async {
    final nav = Navigator.of(context);
    if (r.imIn) return openRoom(nav);
    try {
      if (await Rooms.join(r.id) != null) await openRoom(nav);
    } catch (e) {
      if (context.mounted) _error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Rooms.mine, Rooms.public, Friends.lists]),
    builder: (context, _) {
      final mine = Rooms.mine.value;
      final blocked = Friends.lists.value.blockedIds;
      final rooms = [
        ?mine,
        ...Rooms.public.value.where((r) => r.id != mine?.id && !blocked.contains(r.owner)),
      ];
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 0, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'ROOMS — ${rooms.length}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim),
              ),
            ),
            IconButton(
              tooltip: 'Join with an invite code',
              visualDensity: VisualDensity.compact,
              onPressed: () => showJoinCodeDialog(context),
              icon: const Icon(Icons.vpn_key_outlined, size: 18, color: VyseColors.textDim),
            ),
            IconButton(
              tooltip: 'Create a room',
              visualDensity: VisualDensity.compact,
              onPressed: () => showCreateRoomDialog(context),
              icon: const Icon(Icons.add_rounded, size: 22, color: VyseColors.text),
            ),
          ],
        ),
      );
      final rows = [
        for (final r in rooms) _RoomRow(room: r, onTap: () => _join(context, r)),
        if (rooms.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Text(
              'No rooms right now. Make one with + and your friends can hop in: voice, chat and watching together.',
              style: TextStyle(fontSize: 12.5, height: 1.4, color: VyseColors.textFaint),
            ),
          ),
      ];
      if (!panel) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...rows]);
      }
      return Container(
        color: _bg,
        child: ListView(
          padding: EdgeInsets.fromLTRB(10, topPadding + 10, 10, 30),
          children: [header, ...rows],
        ),
      );
    },
  );
}

/// A room's line: speaker (or lock), name, how full; what's on; then the people in it.
class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.room, required this.onTap});
  final PartyRoom room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = room;
    final mine = r.imIn;
    final full = r.full && !mine;
    final media = r.watch?['media'];
    final watching = media is Map ? media['title'] as String? : null;
    final music = media is Map && media['music'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        onTap: full ? null : onTap,
        tooltip: full ? 'This room is full' : (mine ? 'Open your room' : 'Join: voice and chat'),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          decoration: BoxDecoration(
            color: mine ? VyseColors.accent.withValues(alpha: hovered ? .2 : .14) : Colors.white.withValues(alpha: hovered ? .06 : 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Opacity(
            opacity: full ? .5 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(r.private ? Icons.lock_rounded : Icons.volume_up_rounded, size: 17, color: mine ? VyseColors.accent : VyseColors.textDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${r.size}/${r.limit}',
                      style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                if (watching != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 25, top: 3),
                    child: Row(
                      children: [
                        Icon(music ? Icons.music_note_rounded : Icons.live_tv_rounded, size: 12, color: const Color(0xFF3DDC97)),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            watching,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF3DDC97), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final m in r.members)
                  Padding(
                    padding: const EdgeInsets.only(left: 25, top: 5),
                    child: Row(
                      children: [
                        PartyAvatar(url: m.avatarUrl, name: m.name, size: 20),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (m.owner) ...[const SizedBox(width: 4), const Icon(Icons.workspace_premium_rounded, size: 12, color: VyseColors.star)],
                        if (m.silenced) ...[const SizedBox(width: 4), const Icon(Icons.mic_off_rounded, size: 12, color: Color(0xFFFF8A8C))],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Create / join ─────────────────────────

Future<void> showCreateRoomDialog(BuildContext context) async {
  final nav = Navigator.of(context);
  final created = await showDialog<bool>(context: context, barrierColor: Colors.black.withValues(alpha: .6), builder: (_) => const _CreateRoom());
  if (created == true) await openRoom(nav);
}

class _CreateRoom extends StatefulWidget {
  const _CreateRoom();

  @override
  State<_CreateRoom> createState() => _CreateRoomState();
}

class _CreateRoomState extends State<_CreateRoom> {
  final _name = TextEditingController();
  final _topic = TextEditingController();
  bool _private = false;
  int _limit = 6;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Rooms.create(name: _name.text.trim(), topic: _topic.text.trim(), private: _private, limit: _limit);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Sheet(
    title: 'Create a room',
    subtitle: Rooms.mine.value != null ? "You'll leave ${Rooms.mine.value!.name}." : 'You can change all of this later.',
    error: _error,
    action: 'Create room',
    busy: _busy,
    enabled: _name.text.trim().isNotEmpty,
    onAction: _create,
    children: [
      _Input(controller: _name, label: 'Name', hint: 'Movie night', maxLength: 40, autofocus: true, onSubmit: _create),
      const SizedBox(height: 12),
      _Input(controller: _topic, label: 'Topic (optional)', hint: 'Dune, then Dune Part Two', maxLength: 120, onSubmit: _create),
      const SizedBox(height: 16),
      Row(
        children: [
          for (final (priv, icon, title, body) in const [
            (false, Icons.public_rounded, 'Public', 'Listed for everyone'),
            (true, Icons.lock_rounded, 'Private', 'Join with an invite code'),
          ]) ...[
            Expanded(
              child: Pressable(
                onTap: () => setState(() => _private = priv),
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: _private == priv ? .1 : (hovered ? .05 : .03)),
                    border: Border.all(
                      color: _private == priv ? VyseColors.accent.withValues(alpha: .7) : VyseColors.stroke,
                      width: _private == priv ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 20, color: _private == priv ? VyseColors.accent : VyseColors.textDim),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                            Text(body, style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!priv) const SizedBox(width: 10),
          ],
        ],
      ),
      const SizedBox(height: 16),
      RoomSizeStepper(value: _limit, onChanged: (n) => setState(() => _limit = n)),
    ],
  );
}

/// How many people a room takes: 2 to 10.
class RoomSizeStepper extends StatelessWidget {
  const RoomSizeStepper({super.key, required this.value, required this.onChanged, this.least = 2});
  final int value;
  final ValueChanged<int> onChanged;
  final int least; // who's already in it

  @override
  Widget build(BuildContext context) {
    final low = least.clamp(2, PartyRoom.capacity);
    Widget step(IconData icon, int to, bool ok) => IconButton(
      onPressed: ok ? () => onChanged(to) : null,
      icon: Icon(icon, size: 20),
      color: VyseColors.text,
      disabledColor: VyseColors.textDim.withValues(alpha: .4),
    );
    return Row(
      children: [
        const Expanded(child: Text('People', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800))),
        step(Icons.remove_rounded, value - 1, value > low),
        SizedBox(width: 64, child: Text('Up to $value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
        step(Icons.add_rounded, value + 1, value < PartyRoom.capacity),
      ],
    );
  }
}

/// The owner changes how many people their room takes. Null: cancelled.
Future<int?> showRoomSizeDialog(BuildContext context, PartyRoom room) {
  var n = room.limit;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Room size', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(width: 340, child: RoomSizeStepper(value: n, least: room.size, onChanged: (v) => set(() => n = v))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, n),
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    ),
  );
}

Future<void> showJoinCodeDialog(BuildContext context) async {
  final nav = Navigator.of(context);
  final joined = await showDialog<bool>(context: context, barrierColor: Colors.black.withValues(alpha: .6), builder: (_) => const _JoinCode());
  if (joined == true) await openRoom(nav);
}

class _JoinCode extends StatefulWidget {
  const _JoinCode();

  @override
  State<_JoinCode> createState() => _JoinCodeState();
}

class _JoinCodeState extends State<_JoinCode> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_code.text.trim().length < 8 || _busy) return;
    setState(() => _busy = true);
    try {
      await Rooms.joinCode(_code.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Sheet(
    title: 'Join with a code',
    subtitle: 'Private rooms share an 8-character invite code.',
    error: _error,
    action: 'Join room',
    busy: _busy,
    enabled: _code.text.trim().length >= 8,
    onAction: _join,
    children: [
      _Input(
        controller: _code,
        label: 'Invite code',
        hint: 'ABCD2345',
        maxLength: 8,
        autofocus: true,
        onSubmit: _join,
        formatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), _Upper()],
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 4),
      ),
    ],
  );
}

class _Upper extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) => newValue.copyWith(text: newValue.text.toUpperCase());
}

/// A small dialog: title, fields, error, and one main button.
class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.title,
    required this.subtitle,
    required this.children,
    required this.action,
    required this.onAction,
    required this.busy,
    required this.enabled,
    this.error,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;
  final String action;
  final VoidCallback onAction;
  final bool busy;
  final bool enabled;
  final String? error;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF0B0D16),
    insetPadding: const EdgeInsets.all(20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: VyseColors.stroke),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
            const SizedBox(height: 18),
            ...children,
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A8C), fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: VyseColors.textDim)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                  onPressed: enabled && !busy ? onAction : null,
                  child: busy
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : Text(action, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Input extends StatelessWidget {
  const _Input({
    required this.controller,
    required this.label,
    required this.hint,
    required this.maxLength,
    required this.onSubmit,
    this.autofocus = false,
    this.formatters,
    this.style,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLength;
  final VoidCallback onSubmit;
  final bool autofocus;
  final List<TextInputFormatter>? formatters;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textDim),
        ),
      ),
      TextField(
        onTapOutside: dismissKeyboard,
        controller: controller,
        autofocus: autofocus,
        maxLength: maxLength,
        inputFormatters: formatters,
        onSubmitted: (_) => onSubmit(),
        style: style ?? const TextStyle(fontSize: 14.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          counterText: '',
          hintText: hint,
          hintStyle: const TextStyle(color: VyseColors.textFaint),
          filled: true,
          fillColor: Colors.white.withValues(alpha: .05),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: .06)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7), width: 1.5),
          ),
        ),
      ),
    ],
  );
}
