import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/party/friends.dart';
import '../../data/party/rooms.dart';
import '../../data/party/voice.dart';
import '../../widgets/common.dart';
import 'party_widgets.dart' show PartyAvatar, dismissKeyboard;

const _green = Color(0xFF3DDC97);
const _glass = Color(0xD10B0C13);

/// The room, inside the player: who's in the call and who's talking, the room's chat as it comes
/// in, and a way to answer. Full screen shouldn't cut you off from the people you're watching with.
class PartyStrip extends StatefulWidget {
  const PartyStrip({super.key, required this.controlsUp, this.touch = false, this.compact = false, this.onDone, this.messages});
  final bool controlsUp; // the faces show with the player's controls; messages show regardless
  final bool touch; // no key to hold: a talk button stays on screen
  final bool compact;
  final VoidCallback? onDone; // finished typing: the keyboard goes back to the player
  final Stream<RoomMessage>? messages;

  @override
  State<PartyStrip> createState() => _PartyStripState();
}

class _PartyStripState extends State<PartyStrip> {
  static const _keep = Duration(seconds: 8);
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _shown = <RoomMessage>[];
  final _timers = <Timer>[];
  StreamSubscription<RoomMessage>? _sub;
  bool _chatting = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _sub = (widget.messages ?? Rooms.messages).listen(_arrived);
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final t in _timers) {
      t.cancel();
    }
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  /// A message for the corner: everyone's, yours included, so you see that it went.
  void _arrived(RoomMessage m) {
    if (!mounted || Friends.lists.value.blockedIds.contains(m.user) || _shown.any((x) => x.id == m.id)) return;
    setState(() {
      _shown.add(m);
      if (_shown.length > 3) _shown.removeAt(0);
    });
    _timers.add(Timer(_keep, () {
      if (mounted) setState(() => _shown.remove(m));
    }));
  }

  void _focusChanged() {
    if (!_focus.hasFocus && _chatting && _input.text.trim().isEmpty) setState(() => _chatting = false);
  }

  void _openChat() {
    setState(() => _chatting = !_chatting);
    if (_chatting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    } else {
      widget.onDone?.call();
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _sending = true;
    try {
      final m = await Rooms.send(text);
      _input.clear();
      // it shows with the rest, and the box stays open for the next one (× or Esc closes it)
      _arrived(m);
      if (mounted) _focus.requestFocus();
    } catch (e) {
      if (mounted) showToast(context, Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
    } finally {
      _sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final up = widget.controlsUp || _chatting;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.compact ? 260 : 330),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IgnorePointer(
            ignoring: !up,
            child: AnimatedOpacity(
              opacity: up ? 1 : 0,
              duration: Duration(milliseconds: up ? 110 : 280),
              child: _people(),
            ),
          ),
          if (widget.touch)
            ValueListenableBuilder<bool>(
              valueListenable: Voice.pushToTalk,
              builder: (context, on, _) => !on
                  ? const SizedBox.shrink()
                  : const Padding(padding: EdgeInsets.only(top: 8), child: HoldToTalk()),
            ),
          for (final m in _shown) _Bubble(key: ValueKey(m.id), message: m),
          if (_chatting) _box(),
          const MicLeakPrompt(),
        ],
      ),
    );
  }

  Widget _people() => ListenableBuilder(
    listenable: Listenable.merge([Rooms.mine, Voice.speaking, Voice.inCall]),
    builder: (context, _) {
      final size = widget.compact ? 28.0 : 32.0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in Rooms.mine.value?.members ?? const <RoomMember>[])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Face(member: m, size: size, speaking: Voice.speaking.value.contains(m.id), mic: Voice.inCall.value[m.id]),
            ),
          Pressable(
            tooltip: 'Room chat',
            onTap: _openChat,
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: size + 4,
              height: size + 4,
              decoration: BoxDecoration(shape: BoxShape.circle, color: _chatting ? VyseColors.accent.withValues(alpha: .24) : (hovered ? const Color(0xE62A2C38) : _glass)),
              child: Icon(_chatting ? Icons.close_rounded : Icons.chat_bubble_outline_rounded, size: size * .52, color: _chatting ? VyseColors.accent : Colors.white),
            ),
          ),
        ],
      );
    },
  );

  Widget _box() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Container(
      height: 40,
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(color: _glass, borderRadius: BorderRadius.circular(13), border: Border.all(color: const Color(0x1FFFFFFF))),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              onTapOutside: dismissKeyboard,
              controller: _input,
              focusNode: _focus,
              maxLength: 1000,
              textInputAction: TextInputAction.send,
              // sending keeps the keyboard here: by default it would leave, and an empty box closes
              onEditingComplete: () {},
              onSubmitted: (_) => _send(),
              style: const TextStyle(fontSize: 13.5),
              cursorColor: VyseColors.accent,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                border: InputBorder.none,
                hintText: 'Message the room',
                hintStyle: TextStyle(fontSize: 13.5, color: VyseColors.textFaint),
              ),
            ),
          ),
          Pressable(
            tooltip: 'Send',
            onTap: _send,
            builder: (context, hovered, _) => SizedBox.square(
              dimension: 34,
              child: Icon(Icons.send_rounded, size: 18, color: hovered ? Colors.white : VyseColors.accent),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The call can't cancel out the movie or the music (they come from the player), so on speakers
/// they reach your mic. Asked once per device: Windows calls many headsets "Speakers", so this
/// suggests rather than switching anyone's mic off behind their back.
class MicLeakPrompt extends StatefulWidget {
  const MicLeakPrompt({super.key});

  @override
  State<MicLeakPrompt> createState() => _MicLeakPromptState();
}

class _MicLeakPromptState extends State<MicLeakPrompt> {
  Timer? _timer;
  bool _show = false;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    Voice.state.addListener(_check);
    _check();
  }

  @override
  void dispose() {
    Voice.state.removeListener(_check);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checked || Voice.state.value != VoiceState.on) return;
    _checked = true;
    if (Voice.pushToTalk.value) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('voice.leakAsked') == true) return;
    } catch (_) {}
    if (await Voice.onHeadphones() || !mounted) return;
    setState(() => _show = true);
    _timer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _show = false);
    });
  }

  Future<void> _answer({required bool pushToTalk}) async {
    _timer?.cancel();
    setState(() => _show = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('voice.leakAsked', true);
    } catch (_) {}
    if (pushToTalk) await Voice.setPushToTalk(true);
  }

  @override
  Widget build(BuildContext context) => !_show
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
            decoration: BoxDecoration(color: const Color(0xEB0B0C13), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0x1FFFFFFF))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('On speakers?', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text('What you\'re playing can reach your mic and everyone hears it. Headphones stop that, or use push-to-talk.', style: TextStyle(fontSize: 12, height: 1.35, color: VyseColors.textDim)),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Choice(label: 'Use push-to-talk', strong: true, onTap: () => _answer(pushToTalk: true)),
                    _Choice(label: 'I have headphones', onTap: () => _answer(pushToTalk: false)),
                  ],
                ),
              ],
            ),
          ),
        );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.onTap, this.strong = false});
  final String label;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: strong ? Colors.white : Colors.white.withValues(alpha: hovered ? .16 : .09),
      ),
      child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: strong ? Colors.black : Colors.white)),
    ),
  );
}

/// One person: a green ring while they talk, dimmed if they're not in the call.
class _Face extends StatelessWidget {
  const _Face({required this.member, required this.size, required this.speaking, required this.mic});
  final RoomMember member;
  final double size;
  final bool speaking;
  final bool? mic; // null: not in the call

  @override
  Widget build(BuildContext context) => Tooltip(
    message: member.name,
    child: Opacity(
      opacity: mic == null ? .5 : 1,
      child: SizedBox.square(
        dimension: size + 4,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: speaking ? _green : Colors.transparent, width: 2)),
              child: Center(child: PartyAvatar(url: member.avatarUrl, name: member.name, size: size - 4)),
            ),
            if (mic == false || member.silenced)
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: const BoxDecoration(color: Color(0xFF14151D), shape: BoxShape.circle),
                  child: const Icon(Icons.mic_off_rounded, size: 10, color: Color(0xFFFF8A8C)),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.message});
  final RoomMessage message;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
    builder: (context, v, child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(-10 * (1 - v), 0), child: child),
    ),
    child: Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 7),
        decoration: BoxDecoration(color: _glass, borderRadius: BorderRadius.circular(13)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PartyAvatar(url: message.avatarUrl, name: message.name, size: 20),
            const SizedBox(width: 7),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${message.name}  ', style: const TextStyle(fontWeight: FontWeight.w800)),
                    TextSpan(text: message.body.replaceAll('\n', ' '), style: const TextStyle(color: Color(0xE6FFFFFF))),
                  ],
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Push to talk: hold to send your voice (mouse or finger).
class HoldToTalk extends StatelessWidget {
  const HoldToTalk({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: Voice.talking,
    builder: (context, on, _) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // holding this isn't a tap on the picture
      child: Listener(
        onPointerDown: (_) => Voice.setTalking(true),
        onPointerUp: (_) => Voice.setTalking(false),
        onPointerCancel: (_) => Voice.setTalking(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: on ? const Color(0xE80E2A20) : const Color(0xD11A1C26), // dark enough to read over a bright picture
            border: Border.all(color: on ? _green : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center, // when it's given a whole row (a phone's voice bar)
            children: [
              Icon(on ? Icons.mic_rounded : Icons.mic_none_rounded, size: 20, color: on ? _green : VyseColors.text),
              const SizedBox(width: 7),
              Text(
                on ? 'Talking' : 'Hold to talk',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? _green : VyseColors.text),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
