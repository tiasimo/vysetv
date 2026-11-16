import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/app_settings.dart';
import '../../data/party/friends.dart';
import '../../data/party/party.dart';
import '../../widgets/common.dart';
import '../../widgets/page_scrollbar.dart';
import '../../widgets/section_chrome.dart';
import '../account_sheet.dart';
import '../profile_page.dart';
import 'friends_view.dart';
import 'member_list.dart';
import 'rooms_view.dart';
import 'party_widgets.dart';

/// Party: one Lorewatch-wide hangout. Guests are asked to sign in, new members accept the rules
/// once, then land here.
class PartyPage extends StatelessWidget {
  const PartyPage({super.key});

  @override
  Widget build(BuildContext context) => Material(
    color: VyseColors.bg,
    child: ValueListenableBuilder<AccountUser?>(
      valueListenable: Account.user,
      builder: (context, u, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: u == null
            ? const _Guest(key: ValueKey('guest'))
            : u.partyBanned
            ? const _Removed(key: ValueKey('removed'))
            : (u.termsAt == null ? const _Rules(key: ValueKey('rules')) : const _Home(key: ValueKey('home'))),
      ),
    ),
  );
}

/// Scrolling page with the app's usual margins.
class _Frame extends StatefulWidget {
  const _Frame({required this.child, this.maxWidth = 1080, this.center = false, this.left});
  final Widget child;
  final double maxWidth;
  final bool center;
  final double? left; // when something else (the rooms panel) already clears the rail

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final top = Layout.windowChrome(context) + (phone ? 12 : 24);
    return Stack(
      children: [
        const Positioned(top: -220, right: -160, child: PageGlow()),
        LayoutBuilder(
          builder: (context, c) => PageScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(widget.left ?? (phone ? 16 : Layout.inset(context)), top, pageRight(context), pageBottom(context)),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: widget.center ? c.maxHeight - top - pageBottom(context) : 0),
                child: Align(
                  alignment: widget.center ? Alignment.center : Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Art extends StatelessWidget {
  const _Art({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 84,
    height: 84,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: const LinearGradient(colors: [VyseColors.accent, VyseColors.violet], begin: Alignment.topLeft, end: Alignment.bottomRight),
      boxShadow: [BoxShadow(color: VyseColors.violet.withValues(alpha: .4), blurRadius: 40, offset: const Offset(0, 12))],
    ),
    child: Icon(icon, size: 40, color: Colors.white),
  );
}

// ───────────────────────── Removed by an admin ─────────────────────────

class _Removed extends StatelessWidget {
  const _Removed({super.key});

  @override
  Widget build(BuildContext context) => const _Frame(
    maxWidth: 520,
    center: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Art(icon: Icons.gavel_rounded),
        SizedBox(height: 26),
        Text(
          "You've been removed from Party",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -.6),
        ),
        SizedBox(height: 10),
        Text(
          "After a report, your access to Party (rooms, voice, messages and friends) was turned off. Everything else in Lorewatch works as usual.",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, height: 1.5, color: VyseColors.textDim),
        ),
      ],
    ),
  );
}

// ───────────────────────── Not signed in ─────────────────────────

class _Guest extends StatelessWidget {
  const _Guest({super.key});

  @override
  Widget build(BuildContext context) => _Frame(
    maxWidth: 520,
    center: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Art(icon: Icons.celebration_rounded),
        const SizedBox(height: 26),
        const Text('Party', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: -1)),
        const SizedBox(height: 10),
        const Text(
          'Hang out with everyone on Lorewatch. Profiles, friends, rooms, voice chat and watch parties, all in one place.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, height: 1.5, color: VyseColors.textDim),
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            PillButton(label: 'Create account', icon: Icons.person_add_alt_1_rounded, primary: true, onTap: () => showAccountSheet(context, register: true)),
            PillButton(label: 'Sign in', icon: Icons.login_rounded, onTap: () => showAccountSheet(context)),
          ],
        ),
      ],
    ),
  );
}

// ───────────────────────── Rules, once ─────────────────────────

class _Rules extends StatefulWidget {
  const _Rules({super.key});

  @override
  State<_Rules> createState() => _RulesState();
}

class _RulesState extends State<_Rules> {
  bool _agree = false;
  bool _busy = false;
  String? _error;

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Party.acceptTerms();
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Frame(
    maxWidth: 560,
    center: true,
    child: Container(
      padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
      decoration: BoxDecoration(
        color: partyCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VyseColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Art(icon: Icons.celebration_rounded),
          const SizedBox(height: 22),
          const Text('Before you join', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -.6)),
          const SizedBox(height: 6),
          const Text('Party is shared by everyone on Lorewatch. A few ground rules:', style: TextStyle(fontSize: 14, color: VyseColors.textDim)),
          const SizedBox(height: 20),
          for (final (icon, title, body) in partyRules)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .06), borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, size: 18, color: VyseColors.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(body, style: const TextStyle(fontSize: 13, height: 1.35, color: VyseColors.textDim)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Pressable(
            onTap: () => setState(() => _agree = !_agree),
            builder: (context, hovered, _) => Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: _agree ? VyseColors.accent : Colors.transparent,
                    border: Border.all(color: _agree ? VyseColors.accent : (hovered ? VyseColors.strokeHi : VyseColors.textFaint), width: 1.6),
                  ),
                  child: _agree ? const Icon(Icons.check_rounded, size: 16, color: Colors.black) : null,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text("I'm 13 or older and I agree to these rules.", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A8C), fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white.withValues(alpha: .1),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _agree && !_busy ? _join : null,
              child: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.black))
                  : const Text('Join the party', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    ),
  );
}

// ───────────────────────── Home ─────────────────────────

class _Home extends StatefulWidget {
  const _Home({super.key});

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _online = ValueNotifier<int?>(null);

  @override
  void initState() {
    super.initState();
    AppSettings.partyMembers.addListener(_relayout); // also changes from your other devices
  }

  void _relayout() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSettings.partyMembers.removeListener(_relayout);
    _online.dispose();
    super.dispose();
  }

  void _editProfile() => Navigator.of(context).push(
    ShellRoute(
      settings: const RouteSettings(name: ProfilePage.route),
      child: const ProfilePage(partyProfile: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    // the member list sits on the right when there's room, otherwise it opens as a sheet
    final panel = MediaQuery.sizeOf(context).width >= 1100;
    final members = AppSettings.partyMembers.value; // shown beside the page (synced with the account)
    final card = ListenableBuilder(
      listenable: Listenable.merge([Account.user, AppSettings.displayName, AppSettings.avatarUrl]),
      builder: (context, _) {
        final me = PartyProfile.mine();
        if (me == null) return const SizedBox.shrink();
        return PartyProfileCard(
          profile: me,
          preview: true,
          actions: [_ActionChip(icon: Icons.edit_rounded, label: 'Edit profile', onTap: _editProfile)],
        );
      },
    );
    const people = PartyFriendsArea(findPeople: _FindPeople());
    final main = _Frame(
      left: panel ? 32 : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Party',
                      style: TextStyle(fontSize: phone ? 26 : 34, fontWeight: FontWeight.w900, letterSpacing: -.8),
                    ),
                    const SizedBox(height: 6),
                    ValueListenableBuilder<int?>(
                      valueListenable: _online,
                      builder: (context, n, _) => Row(
                        children: [
                          if (n != null) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: presenceColor('online'), shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 7),
                          ],
                          Flexible(
                            child: Text(
                              n == null ? 'Your profile and the people of Lorewatch.' : '$n online now',
                              style: TextStyle(fontSize: phone ? 12.5 : 14, color: VyseColors.textDim, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Party's sounds (joins, leaves, messages), synced with the account
              ValueListenableBuilder<bool>(
                valueListenable: AppSettings.partySounds,
                builder: (context, on, _) => Tooltip(
                  message: on ? 'Turn Party sounds off' : 'Turn Party sounds on',
                  child: _ActionChip(
                    icon: on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                    // a phone: the speaker says it, and the title keeps its line
                    label: phone ? null : (on ? 'Sounds' : 'Sounds off'),
                    onTap: () => AppSettings.partySounds.set(!on),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!panel)
                _ActionChip(icon: Icons.groups_rounded, label: 'Members', onTap: () => showMemberSheet(context))
              else
                // the member list beside the page: hide it for more room, bring it back here
                _ActionChip(
                  icon: members ? Icons.chevron_right_rounded : Icons.groups_rounded,
                  label: members ? 'Hide members' : 'Show members',
                  onTap: () => AppSettings.partyMembers.set(!members),
                ),
            ],
          ),
          const SizedBox(height: 26),
          if (!panel) ...[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: partyCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: VyseColors.stroke),
              ),
              child: const PartyRoomsPanel(),
            ),
            const SizedBox(height: 34),
          ],
          // Side by side when both have room, the profile card giving way first; below that they
          // stack (a phone, a narrow window, or the page squeezed between the two side panels).
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: card),
                    ),
                    const SizedBox(height: 28),
                    people,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: (c.maxWidth * .42).clamp(250.0, 360.0), child: card),
                  SizedBox(width: c.maxWidth < 700 ? 24 : 36),
                  const Expanded(child: people),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (!panel) return main;
    // Discord-style: rooms on the left, people on the right
    return Row(
      children: [
        Container(
          width: 270,
          margin: const EdgeInsets.only(left: Layout.railCollapsed),
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: VyseColors.stroke)),
          ),
          child: PartyRoomsPanel(panel: true, topPadding: Layout.windowChrome(context)),
        ),
        Expanded(child: main),
        if (members)
          Container(
            width: 290,
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: VyseColors.stroke)),
            ),
            child: PartyMemberPanel(topPadding: Layout.windowChrome(context), onCount: (n) => _online.value = n),
          ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String? label; // none: just the icon
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.symmetric(horizontal: label == null ? 11 : 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: hovered ? .14 : .08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: label == null ? 18 : 16, color: VyseColors.text),
          if (label != null) ...[
            const SizedBox(width: 7),
            Text(label!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ],
      ),
    ),
  );
}

/// Look people up by username or name and open their profile.
class _FindPeople extends StatefulWidget {
  const _FindPeople();

  @override
  State<_FindPeople> createState() => _FindPeopleState();
}

class _FindPeopleState extends State<_FindPeople> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<PartyProfile>? _results;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _run);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _search.text.trim();
    if (q == _query) return;
    _query = q;
    if (q.isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Party.search(q);
      if (mounted && q == _query) {
        setState(() {
          _results = r;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && q == _query) setState(() => _failed = true);
    } finally {
      if (mounted && q == _query) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = Friends.lists.value.blockedIds;
    final results = _results?.where((r) => !blocked.contains(r.id)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Find people', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
        const SizedBox(height: 12),
        VyseSearchField(controller: _search, hint: 'Search by username or name…', busy: _busy),
        const SizedBox(height: 14),
        if (_failed)
          const PartyNote(icon: Icons.wifi_off_rounded, text: "Couldn't search right now. Check your connection.")
        else if (results == null)
          const PartyNote(icon: Icons.person_search_rounded, text: 'Type a username to see their profile.')
        else if (results.isEmpty)
          PartyNote(icon: Icons.search_off_rounded, text: 'Nobody matches "$_query".')
        else
          Container(
            decoration: BoxDecoration(
              color: partyCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: VyseColors.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < results.length; i++) ...[
                  if (i > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
                  PartyPersonRow(profile: results[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
