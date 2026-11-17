import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/party/dms.dart';
import '../../data/party/friends.dart';
import '../../data/party/party.dart';
import '../../widgets/common.dart';
import 'dm_page.dart';
import 'party_widgets.dart';

enum _Tab { messages, online, all, pending, blocked, add }

/// Friends, requests and blocks, with "Add friend" (by username, or [findPeople]).
class PartyFriendsArea extends StatefulWidget {
  const PartyFriendsArea({super.key, required this.findPeople});
  final Widget findPeople;

  @override
  State<PartyFriendsArea> createState() => _PartyFriendsAreaState();
}

class _PartyFriendsAreaState extends State<PartyFriendsArea> {
  _Tab? _tab; // null until the lists arrive: then Pending if someone's waiting, else Online

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Friends.lists, Dms.threads]),
    builder: (context, _) {
      final l = Friends.lists.value;
      final threads = Dms.threads.value;
      final unread = threads.fold<int>(0, (n, t) => n + t.unread);
      final online = l.friends.where((f) => f.presence != 'offline').toList();
      final tab =
          _tab ??
          (unread > 0
              ? _Tab.messages
              : (l.incoming.isNotEmpty ? _Tab.pending : (threads.isNotEmpty ? _Tab.messages : (l.friends.isEmpty ? _Tab.add : _Tab.online))));
      List<Widget> friendButtons(PartyProfile p) => [
        _RoundButton(icon: Icons.chat_bubble_outline_rounded, tooltip: 'Message', onTap: () => openDm(Navigator.of(context), p)),
        const SizedBox(width: 4),
        _FriendMenu(profile: p),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Friends & messages', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _TabPill(
                  label: 'Messages',
                  count: threads.length,
                  badge: unread,
                  selected: tab == _Tab.messages,
                  onTap: () => setState(() => _tab = _Tab.messages),
                ),
                _TabPill(label: 'Online', count: online.length, selected: tab == _Tab.online, onTap: () => setState(() => _tab = _Tab.online)),
                _TabPill(label: 'All', count: l.friends.length, selected: tab == _Tab.all, onTap: () => setState(() => _tab = _Tab.all)),
                _TabPill(
                  label: 'Pending',
                  count: l.incoming.length + l.outgoing.length,
                  badge: l.incoming.length,
                  selected: tab == _Tab.pending,
                  onTap: () => setState(() => _tab = _Tab.pending),
                ),
                _TabPill(label: 'Blocked', selected: tab == _Tab.blocked, onTap: () => setState(() => _tab = _Tab.blocked)),
                _TabPill(label: 'Add friend', accent: true, selected: tab == _Tab.add, onTap: () => setState(() => _tab = _Tab.add)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(
              key: ValueKey(tab),
              child: switch (tab) {
                _Tab.messages => _Threads(threads: threads),
                _Tab.online => _List(
                  people: online,
                  empty: l.friends.isEmpty ? 'No friends yet. Add someone by their username.' : 'None of your friends are online right now.',
                  trailing: friendButtons,
                ),
                _Tab.all => _List(people: l.friends, empty: 'No friends yet. Add someone by their username.', trailing: friendButtons),
                _Tab.pending => _Pending(lists: l),
                _Tab.blocked => _List(
                  people: l.blocked,
                  empty: "You haven't blocked anyone.",
                  trailing: (p) => [_RowButton(label: 'Unblock', onTap: () => _act(context, () => Friends.unblock(p.id)))],
                ),
                _Tab.add => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [const _AddByUsername(), const SizedBox(height: 26), widget.findPeople],
                ),
              },
            ),
          ),
        ],
      );
    },
  );
}

/// Runs a friends action, telling the user when it fails.
Future<void> _act(BuildContext context, Future<String> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      showToast(
        context,
        Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        icon: Icons.error_outline_rounded,
      );
    }
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({required this.label, required this.selected, required this.onTap, this.count, this.badge = 0, this.accent = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final int badge; // red count, e.g. incoming requests
  final bool accent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: accent
              ? (selected ? VyseColors.accent : VyseColors.accent.withValues(alpha: hovered ? .25 : .15))
              : Colors.white.withValues(alpha: selected ? .14 : (hovered ? .07 : .04)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: accent ? (selected ? Colors.black : VyseColors.accent) : (selected ? VyseColors.text : VyseColors.textDim),
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: const Color(0xFFFF4D4F), borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '$badge',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ] else if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(fontSize: 12, color: VyseColors.textFaint, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _List extends StatelessWidget {
  const _List({required this.people, required this.empty, required this.trailing});
  final List<PartyProfile> people;
  final String empty;
  final List<Widget> Function(PartyProfile) trailing;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return PartyNote(icon: Icons.group_outlined, text: empty);
    return Container(
      decoration: BoxDecoration(
        color: partyCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VyseColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < people.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke),
            PartyPersonRow(profile: people[i], trailing: trailing(people[i])),
          ],
        ],
      ),
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending({required this.lists});
  final FriendLists lists;

  @override
  Widget build(BuildContext context) {
    if (lists.incoming.isEmpty && lists.outgoing.isEmpty) {
      return const PartyNote(icon: Icons.mark_email_read_outlined, text: 'No requests waiting.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lists.incoming.isNotEmpty) ...[
          _Label('Incoming — ${lists.incoming.length}'),
          _List(
            people: lists.incoming,
            empty: '',
            trailing: (p) => [
              _RoundButton(
                icon: Icons.check_rounded,
                tooltip: 'Accept',
                color: const Color(0xFF3DDC97),
                onTap: () => _act(context, () => Friends.accept(p.id)),
              ),
              const SizedBox(width: 6),
              _RoundButton(icon: Icons.close_rounded, tooltip: 'Decline', onTap: () => _act(context, () => Friends.remove(p.id))),
            ],
          ),
          const SizedBox(height: 18),
        ],
        if (lists.outgoing.isNotEmpty) ...[
          _Label('Sent — ${lists.outgoing.length}'),
          _List(
            people: lists.outgoing,
            empty: '',
            trailing: (p) => [_RoundButton(icon: Icons.close_rounded, tooltip: 'Cancel request', onTap: () => _act(context, () => Friends.remove(p.id)))],
          ),
        ],
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: hovered ? .14 : .07),
      ),
      child: Icon(icon, size: 19, color: hovered ? (color ?? VyseColors.text) : VyseColors.textDim),
    ),
  );
}

class _RowButton extends StatelessWidget {
  const _RowButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    child: Text(
      label,
      style: TextStyle(fontWeight: FontWeight.w700, color: VyseColors.accent),
    ),
  );
}

/// ⋯ on a friend: profile, remove, block.
class _FriendMenu extends StatelessWidget {
  const _FriendMenu({required this.profile});
  final PartyProfile profile;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'More',
    color: VyseColors.surfaceHi,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    icon: Icon(Icons.more_horiz_rounded, color: VyseColors.textDim),
    onSelected: (v) async {
      switch (v) {
        case 'profile':
          showPartyProfile(context, profile.id, initial: profile);
        case 'remove':
          await _act(context, () => Friends.remove(profile.id));
        case 'block':
          if (await confirmBlock(context, profile) && context.mounted) await _act(context, () => Friends.block(profile.id));
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'profile', child: Text('View profile')),
      PopupMenuItem(value: 'remove', child: Text('Remove friend')),
      PopupMenuItem(
        value: 'block',
        child: Text('Block', style: TextStyle(color: Color(0xFFFF8A8C))),
      ),
    ],
  );
}

/// "Add friend" by exact username.
class _AddByUsername extends StatefulWidget {
  const _AddByUsername();

  @override
  State<_AddByUsername> createState() => _AddByUsernameState();
}

class _AddByUsernameState extends State<_AddByUsername> {
  final _c = TextEditingController();
  bool _busy = false;
  String? _note;
  bool _ok = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final name = _c.text.trim().replaceAll('@', '').toLowerCase();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final status = await Friends.request(name);
      if (!mounted) return;
      setState(() {
        _ok = true;
        _note = status == 'friends' ? "You and @$name are now friends." : 'Request sent to @$name.';
        _c.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _note = Account.describe(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: BoxDecoration(
          color: partyCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: VyseColors.stroke),
        ),
        child: Row(
          children: [
            Icon(Icons.alternate_email_rounded, size: 19, color: VyseColors.textFaint),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                onTapOutside: dismissKeyboard,
                controller: _c,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _send(),
                style: const TextStyle(fontSize: 14.5),
                cursorColor: VyseColors.accent,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Add a friend by their username',
                  hintStyle: TextStyle(color: VyseColors.textFaint),
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _busy ? null : _send,
              child: _busy
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Send request', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
      if (_note != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            _note!,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ok ? const Color(0xFF3DDC97) : const Color(0xFFFF8A8C)),
          ),
        ),
    ],
  );
}

/// Blocked people, from Settings.
Future<void> showBlockedDialog(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: .6),
  builder: (context) => Dialog(
    backgroundColor: const Color(0xFF0B0D16),
    insetPadding: const EdgeInsets.all(20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: VyseColors.stroke),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Blocked people', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close_rounded, color: VyseColors.textDim),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: ValueListenableBuilder<FriendLists>(
                  valueListenable: Friends.lists,
                  builder: (context, l, _) => _List(
                    people: l.blocked,
                    empty: "You haven't blocked anyone.",
                    trailing: (p) => [_RowButton(label: 'Unblock', onTap: () => _act(context, () => Friends.unblock(p.id)))],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// Conversations from the last 24 hours, newest first.
class _Threads extends StatelessWidget {
  const _Threads({required this.threads});
  final List<DmThread> threads;

  @override
  Widget build(BuildContext context) {
    if (threads.isEmpty) {
      return const PartyNote(
        icon: Icons.chat_bubble_outline_rounded,
        text: 'No conversations yet. Message a friend from their profile or the Online tab. Messages disappear after 24 hours; the conversation stays.',
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: partyCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VyseColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < threads.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke),
            _ThreadRow(thread: threads[i]),
          ],
        ],
      ),
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({required this.thread});
  final DmThread thread;

  @override
  Widget build(BuildContext context) {
    final t = thread;
    final p = t.partner;
    final last = t.last;
    final at = last?.created ?? t.lastAt;
    final d = at == null ? null : DateTime.now().difference(at);
    final when = d == null ? '' : (d.inMinutes < 1 ? 'now' : (d.inHours < 1 ? '${d.inMinutes}m' : (d.inDays < 1 ? '${d.inHours}h' : '${d.inDays}d')));
    final live = Friends.lists.value.friends.where((f) => f.id == p.id).firstOrNull ?? p;
    return Pressable(
      onTap: () => openDm(Navigator.of(context), live),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        color: Colors.white.withValues(alpha: hovered ? .05 : 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            PartyAvatar(url: live.avatarUrl, name: live.name, size: 44, presence: live.presence),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    live.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: t.unread > 0 ? FontWeight.w900 : FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  ValueListenableBuilder<Map<String, DateTime>>(
                    valueListenable: Dms.typing,
                    builder: (context, typing, _) => Text(
                      typing.containsKey(p.id)
                          ? 'typing…'
                          : (last == null ? 'Messages from the last 24 hours show here' : '${last.mine ? 'You: ' : ''}${last.body.replaceAll('\n', ' ')}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: typing.containsKey(p.id) ? const Color(0xFF3DDC97) : (t.unread > 0 ? VyseColors.text : VyseColors.textDim),
                        fontWeight: t.unread > 0 ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  when,
                  style: TextStyle(fontSize: 11.5, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                if (t.unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFFF4D4F), borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      '${t.unread}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  )
                else if (last != null && last.mine && last.readAt != null)
                  Text('Seen', style: TextStyle(fontSize: 11, color: VyseColors.textFaint)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
