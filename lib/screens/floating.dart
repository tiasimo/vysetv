import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/nav.dart' show rootNavigatorKey;
import 'party/dm_page.dart' show MiniChat, MiniChatBubble, MiniChatPanel;
import 'party/room_page.dart' show RoomMiniPlayer;
import 'player_page.dart' show MiniPlayer;

/// What stays over every page while you use the app: the minimized player ([MiniPlayer]) and
/// the floating chat ([MiniChat]). One layer in the app navigator's overlay. Pages come and go
/// underneath it (an overlay keeps what isn't a page on top), so both follow you everywhere,
/// and both can be dragged to wherever they're out of the way.
class FloatingLayer {
  static OverlayEntry? _entry;

  /// Puts the layer up (the shell does, once it's on screen).
  static void attach() {
    if (_entry != null) return;
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return;
    overlay.insert(_entry = OverlayEntry(builder: (_) => const _Floating()));
  }

  static void detach() {
    _entry?.remove();
    _entry = null;
  }
}

class _Floating extends StatefulWidget {
  const _Floating();

  @override
  State<_Floating> createState() => _FloatingState();
}

class _FloatingState extends State<_Floating> {
  // Where each one sits, as an alignment within the space it can move in: it keeps its corner
  // when the window is resized or the screen turns. The video starts top right, clear of the
  // text box and your own messages; the chat bottom right.
  static Alignment _playerAt = const Alignment(1, -.86);
  static Alignment _chatAt = const Alignment(1, .78);

  late final _all = Listenable.merge([MiniPlayer.session, MiniPlayer.room, MiniChat.now]);

  @override
  void initState() {
    super.initState();
    _all.addListener(_changed);
  }

  @override
  void dispose() {
    _all.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  static Alignment _dragged(Alignment at, Offset by, Size area, Size size) {
    final w = area.width - size.width, h = area.height - size.height;
    return Alignment(
      w <= 0 ? at.x : (at.x + 2 * by.dx / w).clamp(-1.0, 1.0),
      h <= 0 ? at.y : (at.y + 2 * by.dy / h).clamp(-1.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = MiniPlayer.session.value;
    final room = MiniPlayer.room.value;
    final chat = MiniChat.now.value;
    if (session == null && !room && chat == null) return const SizedBox.shrink();

    final mq = MediaQuery.of(context);
    final phone = mq.size.width < 640;
    final edge = phone ? 8.0 : 20.0;
    // clear of the window's own bar and the screen's edges, and above the keyboard while typing
    final margin = EdgeInsets.fromLTRB(
      mq.padding.left + edge,
      Layout.windowChrome(context) + edge,
      mq.padding.right + edge,
      mq.viewInsets.bottom > 0 ? mq.viewInsets.bottom + 8 : mq.padding.bottom + edge,
    );
    final area = Size(math.max(0, mq.size.width - margin.horizontal), math.max(0, mq.size.height - margin.vertical));

    Widget place(Alignment at, Widget child) => Positioned.fill(
      child: Padding(
        padding: margin,
        child: Align(alignment: at, child: child),
      ),
    );

    Widget? player;
    if (session != null || room) {
      final w = math.min(area.width, phone ? math.min(250.0, area.width * .62) : (mq.size.width < 1100 ? 320.0 : 400.0));
      final size = Size(w, w * 9 / 16);
      player = GestureDetector(
        onPanUpdate: (d) => setState(() => _playerAt = _dragged(_playerAt, d.delta, area, size)),
        child: Container(
          width: size.width,
          height: size.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(color: Color(0xB3000000), blurRadius: 28, offset: Offset(0, 10))],
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: .14)),
          ),
          // No fades or blurs from here down to the video: it is a hole cut through to mpv's
          // surface behind the window, and those would paint over it (see VyseVideo). Built
          // afresh every time this layer builds, so the video reports where it has moved to.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: session != null ? session.view(mini: true) : RoomMiniPlayer(),
          ),
        ),
      );
    }

    Widget? talk;
    if (chat != null) {
      final size = chat.open
          ? Size(phone ? area.width : math.min(340.0, area.width), math.min(phone ? 440.0 : 480.0, area.height))
          : const Size.square(MiniChatBubble.size);
      void drag(DragUpdateDetails d) => setState(() => _chatAt = _dragged(_chatAt, d.delta, area, size));
      talk = chat.open
          ? MiniChatPanel(
              partner: chat.partner,
              size: size,
              // dragged by its header; the messages underneath scroll as usual
              handle: (header) => GestureDetector(onPanUpdate: drag, child: header),
            )
          : GestureDetector(
              onTap: MiniChat.toggle,
              onPanUpdate: drag,
              child: MiniChatBubble(partner: chat.partner),
            );
    }

    // Only the two themselves take taps: everywhere else goes through to the page underneath.
    return Stack(
      children: [
        if (player != null) place(_playerAt, player),
        if (talk != null) place(_chatAt, talk),
      ],
    );
  }
}
