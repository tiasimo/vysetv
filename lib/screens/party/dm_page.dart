import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/party/alerts.dart' show PartyMutes;
import '../../data/account.dart';
import '../../data/party/dms.dart';
import '../../data/party/friends.dart';
import '../../data/party/party.dart';
import '../../widgets/common.dart';
import '../../widgets/section_chrome.dart';
import 'party_widgets.dart';

/// Opens the conversation with [partner] in the current tab.
void openDm(NavigatorState nav, PartyProfile partner) {
  if (MiniChat.now.value?.partner.id == partner.id) MiniChat.close(); // its page takes over
  nav.push(
    ShellRoute(
      settings: RouteSettings(name: 'dm/${partner.id}'),
      child: DmPage(partner: partner),
    ),
  );
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// A conversation that floats over every page, opened from a message's pop-up: a small chat
/// window, or just the friend's face while it's put away (the floating layer places and drags
/// both). One at a time: opening another friend's replaces it.
class MiniChat {
  /// Who it's with, and whether the window is open (false: only their face shows).
  static final now = ValueNotifier<({PartyProfile partner, bool open})?>(null);

  static void open(PartyProfile partner) {
    // their conversation's own page is on screen already
    if (Dms.openWith == partner.id && now.value?.partner.id != partner.id) return;
    now.value = (partner: partner, open: true);
  }

  /// Window ↔ face.
  static void toggle() {
    final c = now.value;
    if (c != null) now.value = (partner: c.partner, open: !c.open);
  }

  static void close() => now.value = null;
}

/// The floating chat's window: the conversation itself, small. [handle] wraps its header, the
/// part it's dragged by.
class MiniChatPanel extends StatelessWidget {
  const MiniChatPanel({super.key, required this.partner, required this.size, required this.handle});
  final PartyProfile partner;
  final Size size;
  final Widget Function(Widget header) handle;

  @override
  Widget build(BuildContext context) => Container(
    width: size.width,
    height: size.height,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      boxShadow: const [BoxShadow(color: Color(0xB3000000), blurRadius: 34, offset: Offset(0, 14))],
    ),
    foregroundDecoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withValues(alpha: .12)),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      // it lays out as the narrow page it is, with no screen edges or keyboard of its own
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero, viewInsets: EdgeInsets.zero),
        child: DmPage(key: ValueKey('mini/${partner.id}'), partner: partner, floating: true, handle: handle),
      ),
    ),
  );
}

/// The floating chat put away: the friend's face, with how many of their messages are unread.
class MiniChatBubble extends StatelessWidget {
  const MiniChatBubble({super.key, required this.partner});
  final PartyProfile partner;

  static const size = 58.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Dms.threads, Friends.lists]),
    builder: (context, _) {
      final unread = Dms.threads.value.where((t) => t.partner.id == partner.id).firstOrNull?.unread ?? 0;
      final live = Friends.lists.value.friends.where((f) => f.id == partner.id).firstOrNull ?? partner;
      // its own Material: it sits straight in the app's overlay, outside every page's
      return Material(
        type: MaterialType.transparency,
        child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Tooltip(
                  message: 'Chat with ${partner.name}',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: VyseColors.surfaceHi,
                      border: Border.all(color: Colors.white.withValues(alpha: .16)),
                      boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 18, offset: Offset(0, 6))],
                    ),
                    child: Center(child: PartyAvatar(url: live.avatarUrl, name: live.name, size: size - 14)),
                  ),
                ),
              ),
            ),
            if (unread > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFFF23F43), borderRadius: BorderRadius.circular(10), border: Border.all(color: VyseColors.bg, width: 2)),
                  child: Text(unread > 9 ? '9+' : '$unread', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
                ),
              ),
            Positioned(
              left: 0,
              top: 0,
              child: Pressable(
                tooltip: 'Close this chat',
                onTap: MiniChat.close,
                builder: (context, hovered, _) => Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: hovered ? const Color(0xFF3A3C4A) : const Color(0xFF22232D), border: Border.all(color: VyseColors.bg, width: 2)),
                  child: const Icon(Icons.close_rounded, size: 12, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
        ),
      );
    },
  );
}

/// A conversation with a friend. Messages vanish 24 hours after they're sent.
class DmPage extends StatefulWidget {
  const DmPage({super.key, required this.partner, this.floating = false, this.handle});
  final PartyProfile partner;

  /// Inside the floating chat window ([MiniChatPanel]) instead of on a page of its own.
  final bool floating;
  final Widget Function(Widget header)? handle;

  @override
  State<DmPage> createState() => _DmPageState();
}

class _DmPageState extends State<DmPage> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _messages = <DmMessage>[]; // newest first
  StreamSubscription<(String, DmMessage)>? _sub;
  Timer? _prune;
  bool _loading = true;
  bool _older = true; // more history to load
  bool _sending = false;

  String get _partner => widget.partner.id;

  @override
  void initState() {
    super.initState();
    Dms.openWith = _partner;
    if (widget.floating) {
      // over a page that already has the keyboard, autofocus alone wouldn't take it
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    } else {
      hideBottomBar.value++; // phones: the chat gets the whole screen
    }
    _load();
    _sub = Dms.events.listen(_event);
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _loadOlder();
    });
    _prune = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_messages.any((m) => m.expired)) setState(() => _messages.removeWhere((m) => m.expired));
    });
    _input.addListener(() {
      if (_input.text.trim().isNotEmpty) Dms.typingTo(_partner);
    });
  }

  @override
  void dispose() {
    if (Dms.openWith == _partner) Dms.openWith = null;
    if (!widget.floating) hideBottomBar.value--;
    _sub?.cancel();
    _prune?.cancel();
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await Dms.history(_partner);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(list);
        _older = list.length >= 50;
        _loading = false;
      });
      Dms.markRead(_partner);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _loadingOlder = false;
  Future<void> _loadOlder() async {
    if (!_older || _loadingOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    try {
      final list = await Dms.history(_partner, before: _messages.last.created);
      if (!mounted) return;
      setState(() {
        final ids = {for (final m in _messages) m.id};
        _messages.addAll(list.where((m) => !ids.contains(m.id)));
        _older = list.length >= 50;
      });
    } catch (_) {
    } finally {
      _loadingOlder = false;
    }
  }

  void _event((String, DmMessage) ev) {
    final (action, m) = ev;
    if (m.partner != _partner) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.id == m.id);
      switch (action) {
        case 'create':
          if (i < 0) _messages.insert(0, m);
        case 'update':
          if (i >= 0) _messages[i] = m;
        case 'delete':
          if (i >= 0) _messages.removeAt(i);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await Dms.send(_partner, text);
      if (!mounted) return;
      _input.clear();
      setState(() {
        if (!_messages.any((x) => x.id == m.id)) _messages.insert(0, m);
      });
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _focus.requestFocus();
    }
  }

  Future<void> _menu(DmMessage m, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      color: VyseColors.surfaceHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        if (m.mine)
          const PopupMenuItem(
            value: 'unsend',
            child: Text('Unsend', style: TextStyle(color: Color(0xFFFF8A8C))),
          ),
        if (!m.mine)
          const PopupMenuItem(
            value: 'report',
            child: Text('Report', style: TextStyle(color: Color(0xFFFF8A8C))),
          ),
      ],
    );
    if (v == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.body));
    } else if (v == 'report') {
      if (mounted) await showReportDialog(context, userId: m.sender, name: widget.partner.name, kind: 'dm', ref: m.id);
    } else if (v == 'unsend') {
      try {
        await Dms.unsend(m.id);
        if (mounted) setState(() => _messages.removeWhere((x) => x.id == m.id));
      } catch (_) {}
    }
  }

  /// The floating window's header: who it's with, put away (–) and close (×).
  Widget _floatingHeader(PartyProfile p) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
    decoration: const BoxDecoration(
      color: VyseColors.surface,
      border: Border(bottom: BorderSide(color: VyseColors.stroke)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Pressable(
            onTap: () => showPartyProfile(context, p.id, initial: p),
            builder: (context, hovered, _) => Row(
              children: [
                ValueListenableBuilder<FriendLists>(
                  valueListenable: Friends.lists,
                  builder: (context, l, _) {
                    final live = l.friends.where((f) => f.id == p.id).firstOrNull ?? p;
                    return PartyAvatar(url: live.avatarUrl, name: live.name, size: 32, presence: live.presence, ring: VyseColors.surface);
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, decoration: hovered ? TextDecoration.underline : null),
                      ),
                      ValueListenableBuilder<Map<String, DateTime>>(
                        valueListenable: Dms.typing,
                        builder: (context, t, _) => t.containsKey(p.id)
                            ? const Text('typing…', style: TextStyle(fontSize: 11.5, color: Color(0xFF3DDC97), fontWeight: FontWeight.w600))
                            : Text('@${p.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Put away',
          visualDensity: VisualDensity.compact,
          onPressed: MiniChat.toggle,
          icon: const Icon(Icons.remove_rounded, size: 20, color: VyseColors.textDim),
        ),
        IconButton(
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          onPressed: MiniChat.close,
          icon: const Icon(Icons.close_rounded, size: 20, color: VyseColors.textDim),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final floating = widget.floating;
    final phone = floating || Layout.isPhone(context);
    final side = phone ? 12.0 : Layout.inset(context);
    final right = floating ? 12.0 : pageRight(context);
    // a real keyboard: Enter sends and Shift+Enter is a new line; a phone's has its own Send key
    final softKeys = hasSoftKeyboard || (!floating && phone);
    final p = widget.partner;
    return Material(
      color: VyseColors.bg,
      child: LayoutBuilder(
        builder: (context, page) => Column(
        children: [
          // header (left out when there's hardly any height: a phone on its side with the keyboard up)
          if (floating)
            (widget.handle ?? (Widget h) => h)(_floatingHeader(p))
          else if (page.maxHeight >= 200)
          Container(
            padding: EdgeInsets.fromLTRB(side - 8, Layout.windowChrome(context) + (phone ? 6 : 14), right, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: VyseColors.stroke)),
            ),
            child: Row(
              children: [
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded, color: VyseColors.textDim),
                  ),
                const SizedBox(width: 4),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Pressable(
                      onTap: () => showPartyProfile(context, p.id, initial: p),
                      builder: (context, hovered, _) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ValueListenableBuilder<FriendLists>(
                            valueListenable: Friends.lists,
                            builder: (context, l, _) {
                              final live = l.friends.where((f) => f.id == p.id).firstOrNull ?? p;
                              return PartyAvatar(url: live.avatarUrl, name: live.name, size: 40, presence: live.presence, ring: VyseColors.bg);
                            },
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, decoration: hovered ? TextDecoration.underline : null),
                                ),
                                ValueListenableBuilder<Map<String, DateTime>>(
                                  valueListenable: Dms.typing,
                                  builder: (context, t, _) => t.containsKey(p.id)
                                      ? const Text(
                                          'typing…',
                                          style: TextStyle(fontSize: 12.5, color: Color(0xFF3DDC97), fontWeight: FontWeight.w600),
                                        )
                                      : Text(
                                          '@${p.username}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // mute: their messages stop making sounds and notifications (they still arrive)
                ValueListenableBuilder<String>(
                  valueListenable: AppSettings.partyMuted,
                  builder: (context, _, _) {
                    final muted = PartyMutes.has(p.id);
                    return IconButton(
                      tooltip: muted ? 'Unmute ${p.name}' : 'Mute ${p.name}',
                      onPressed: () => PartyMutes.toggle(p.id),
                      icon: Icon(
                        muted ? Icons.notifications_off_rounded : Icons.notifications_none_rounded,
                        color: muted ? VyseColors.accent : VyseColors.textDim,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          // messages
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)),
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(side, 16, right, 12),
                    itemCount: _messages.length + 1,
                    itemBuilder: (context, i) {
                      if (i == _messages.length) return _Intro(partner: p, empty: _messages.isEmpty);
                      final m = _messages[i];
                      final older = i + 1 < _messages.length ? _messages[i + 1] : null;
                      final newer = i > 0 ? _messages[i - 1] : null;
                      final gap = older == null || m.created.difference(older.created) > const Duration(minutes: 15);
                      final firstOfRun = gap || older.sender != m.sender;
                      final lastOfRun = newer == null || newer.sender != m.sender || newer.created.difference(m.created) > const Duration(minutes: 15);
                      // "Seen" / "Sent" under your newest message
                      final status = i == _messages.indexWhere((x) => x.mine) ? (m.readAt != null ? 'Seen ${_clock(m.readAt!)}' : 'Sent') : null;
                      // full width, so each bubble can sit on its side: yours right, theirs left
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (gap) _TimeDivider(time: m.created),
                          _Bubble(message: m, top: firstOfRun, bottom: lastOfRun, status: status, onMenu: (at) => _menu(m, at)),
                        ],
                      );
                    },
                  ),
          ),
          // composer
          Padding(
            padding: floating ? const EdgeInsets.fromLTRB(8, 4, 8, 8) : EdgeInsets.fromLTRB(side, 6, right, (phone ? 10 : 18) + MediaQuery.paddingOf(context).bottom),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
              decoration: BoxDecoration(
                color: partyCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VyseColors.stroke),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: CallbackShortcuts(
                      // Enter sends, Shift+Enter is a new line
                      bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        autofocus: !hasSoftKeyboard && (floating || !phone),
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 2000,
                        textInputAction: softKeys ? TextInputAction.send : TextInputAction.newline,
                        // sending keeps the keyboard up for the next message
                        onEditingComplete: softKeys ? () {} : null,
                        onSubmitted: softKeys ? (_) => _send() : null,
                        onTapOutside: dismissKeyboard,
                        style: const TextStyle(fontSize: 14.5, height: 1.35),
                        cursorColor: VyseColors.accent,
                        decoration: InputDecoration(
                          counterText: '',
                          border: InputBorder.none,
                          hintText: 'Message ${p.name}',
                          hintMaxLines: 1,
                          hintStyle: const TextStyle(color: VyseColors.textFaint),
                        ),
                      ),
                    ),
                  ),
                  // part of the text box as far as taps go: pressing Send leaves the keyboard up
                  TextFieldTapRegion(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: IconButton(
                        tooltip: 'Send',
                        onPressed: _sending ? null : _send,
                        icon: _sending
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim))
                            : const Icon(Icons.send_rounded, color: VyseColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// Top of the conversation: who it's with and the 24-hour rule.
class _Intro extends StatelessWidget {
  const _Intro({required this.partner, required this.empty});
  final PartyProfile partner;
  final bool empty;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24, top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PartyAvatar(url: partner.avatarUrl, name: partner.name, size: 72),
        const SizedBox(height: 12),
        Text(partner.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -.5)),
        Text('@${partner.username}', style: const TextStyle(fontSize: 14, color: VyseColors.textDim)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(10)),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_outlined, size: 16, color: VyseColors.textDim),
              SizedBox(width: 8),
              Flexible(
                child: Text('Messages disappear 24 hours after they are sent.', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ),
            ],
          ),
        ),
        if (empty) ...[const SizedBox(height: 14), Text('Say hi to ${partner.name}.', style: const TextStyle(fontSize: 13.5, color: VyseColors.textFaint))],
      ],
    ),
  );
}

class _TimeDivider extends StatelessWidget {
  const _TimeDivider({required this.time});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = time.year == now.year && time.month == now.month && time.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const Expanded(child: Divider(color: VyseColors.stroke)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${today ? 'Today' : 'Yesterday'} ${_clock(time)}',
              style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
            ),
          ),
          const Expanded(child: Divider(color: VyseColors.stroke)),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.top, required this.bottom, required this.onMenu, this.status});
  final DmMessage message;
  final bool top; // first of a run from the same person
  final bool bottom; // last of the run
  final String? status;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.mine;
    const r = Radius.circular(18);
    const tight = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: mine || top ? r : tight,
      bottomLeft: mine || bottom ? r : tight,
      topRight: !mine || top ? r : tight,
      bottomRight: !mine || bottom ? r : tight,
    );
    final maxW = (MediaQuery.sizeOf(context).width * .62).clamp(220.0, 520.0);
    return Padding(
      padding: EdgeInsets.only(top: top ? 6 : 2),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onSecondaryTapDown: (d) => onMenu(d.globalPosition),
            onLongPressStart: (d) => onMenu(d.globalPosition),
            child: Tooltip(
              message: _clock(m.created),
              waitDuration: const Duration(milliseconds: 600),
              child: Container(
                constraints: BoxConstraints(maxWidth: maxW),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient: mine ? const LinearGradient(colors: [VyseColors.accent, VyseColors.accentHot]) : null,
                  color: mine ? null : VyseColors.surfaceHi,
                ),
                child: Text(
                  m.body,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    color: mine ? Colors.black : VyseColors.text,
                    fontWeight: mine ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Text(
                status!,
                style: const TextStyle(fontSize: 11, color: VyseColors.textFaint, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
