import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart' show ClientException;

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/app_settings.dart';
import '../../data/party/alerts.dart' show PartyMutes;
import '../../data/party/friends.dart';
import '../../data/party/party.dart';
import '../../widgets/common.dart';
import 'dm_page.dart';
import 'profile_library.dart';

const partyCard = Color(0xFF0D0F18);

/// Puts the on-screen keyboard away. Every Party text box takes it as its "tapped outside"
/// handler, so touching the messages, the page or anything else that isn't the box closes the
/// keyboard (an iPhone has no key or gesture of its own for that). A button that should leave
/// it up, like Send, sits in a [TextFieldTapRegion].
void dismissKeyboard([PointerDownEvent? _]) => FocusManager.instance.primaryFocus?.unfocus();

/// Whether typing brings up an on-screen keyboard here (phones and tablets). It has its own
/// Send key, so Enter doesn't have to double as one.
bool get hasSoftKeyboard => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

Color presenceColor(String presence) => switch (presence) {
  'online' => const Color(0xFF3DDC97),
  'idle' => VyseColors.star,
  'dnd' => const Color(0xFFFF5C5C),
  _ => VyseColors.textFaint,
};

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${_months[t.month - 1]} ${t.year}';
}

/// "Watching" block on a profile card: poster, title, episode, for how long.
class _Watching extends StatelessWidget {
  const _Watching({required this.activity});
  final Map<String, dynamic> activity;

  @override
  Widget build(BuildContext context) {
    final a = activity;
    final poster = a['poster'] as String?;
    final since = DateTime.fromMillisecondsSinceEpoch((a['since'] as num?)?.toInt() ?? 0);
    final mins = DateTime.now().difference(since).inMinutes;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF3DDC97).withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3DDC97).withValues(alpha: .18)),
      ),
      child: Row(
        children: [
          if (poster != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedNetworkImage(imageUrl: 'https://image.tmdb.org/t/p/w92$poster', width: 40, height: 60, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WATCHING',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: .8, color: Color(0xFF3DDC97)),
                ),
                const SizedBox(height: 3),
                Text(
                  a['title'] as String? ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (a['kind'] == 'tv' && a['episode'] != null) 'Season ${a['season'] ?? 1} · Episode ${a['episode']}',
                    mins < 1 ? 'just started' : 'for ${mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m'}',
                  ].join('  ·  '),
                  style: TextStyle(fontSize: 12, color: VyseColors.textDim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String presenceLabel(String presence) => switch (presence) {
  'online' => 'Online',
  'idle' => 'Idle',
  'dnd' => 'Do not disturb',
  'invisible' => 'Invisible',
  _ => 'Offline',
};

/// Two colours picked from a name, for avatars and banners without an image.
(Color, Color) nameColors(String seed) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  return (HSLColor.fromAHSL(1, hue, .55, .42).toColor(), HSLColor.fromAHSL(1, (hue + 40) % 360, .6, .26).toColor());
}

/// An image someone linked (avatar or banner), loaded at about its shown size through the
/// image proxy; [fallback] while it loads or when it can't.
class PartyImage extends StatelessWidget {
  const PartyImage({super.key, required this.url, required this.width, required this.height, required this.fallback});
  final String url;
  final double width;
  final double height;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return CachedNetworkImage(
      imageUrl: ImageLinks.sized(url, width: (width * dpr).round(), height: (height * dpr).round()),
      width: width,
      height: height,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 160),
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// Round avatar with initials when there's no image, and an optional status dot.
class PartyAvatar extends StatelessWidget {
  const PartyAvatar({super.key, required this.url, required this.name, this.size = 40, this.presence, this.ring = partyCard});
  final String url;
  final String name;
  final double size;
  final String? presence;
  final Color ring; // the dot's outline, matching what's behind the avatar

  @override
  Widget build(BuildContext context) {
    final (a, b) = nameColors(name);
    final initials = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [a, b], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: size * .42, fontWeight: FontWeight.w900, color: Colors.white),
      ),
    );
    final dot = size * .3;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipOval(
            child: PartyImage(url: url, width: size, height: size, fallback: initials),
          ),
          if (presence != null)
            Positioned(
              right: -dot * .08,
              bottom: -dot * .08,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: presenceColor(presence!),
                  border: Border.all(color: ring, width: dot * .22),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A profile as others see it: banner, avatar, names, status line, bio.
class PartyProfileCard extends StatelessWidget {
  const PartyProfileCard({super.key, required this.profile, this.actions = const [], this.preview = false});
  final PartyProfile profile;
  final List<Widget> actions;

  /// The owner's own preview: private details still show, with a note.
  final bool preview;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      final bannerH = (w / 2.5).clamp(96.0, 150.0);
      const avatar = 86.0;
      final p = profile;
      final hidden = !preview && p.hidden;
      final (a, b) = nameColors(p.username);
      final banner = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [a, b], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
      );
      return Container(
        decoration: BoxDecoration(
          color: partyCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VyseColors.stroke),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .35), blurRadius: 30, offset: const Offset(0, 14))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: bannerH + avatar / 2,
              child: Stack(
                children: [
                  SizedBox(
                    width: w,
                    height: bannerH,
                    child: PartyImage(url: p.bannerUrl, width: w, height: bannerH, fallback: banner),
                  ),
                  Positioned(
                    left: 18,
                    top: bannerH - avatar / 2,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(color: partyCard, shape: BoxShape.circle),
                      child: PartyAvatar(url: p.avatarUrl, name: p.name, size: avatar, presence: p.presence),
                    ),
                  ),
                  if (p.private)
                    Positioned(
                      right: 12,
                      top: bannerH + 8,
                      child: _Badge(icon: Icons.lock_rounded, label: 'Private'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -.4),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@${p.username}',
                    style: TextStyle(fontSize: 13, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: presenceColor(p.presence), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        p.presence == 'offline' && p.lastSeen != null && !p.isMe ? 'Last seen ${_ago(p.lastSeen!)}' : presenceLabel(p.presence),
                        style: TextStyle(fontSize: 12, color: VyseColors.textDim),
                      ),
                    ],
                  ),
                  if (!hidden && p.customStatus.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(p.customStatus, style: TextStyle(fontSize: 13.5, color: VyseColors.text)),
                  ],
                  if (!hidden && p.activity != null) ...[const SizedBox(height: 12), _Watching(activity: p.activity!)],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .04), borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hidden)
                          Row(
                            children: [
                              Icon(Icons.lock_outline_rounded, size: 16, color: VyseColors.textDim),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "This profile is private. Only they can send friend requests, and only their friends can message them or see what they're watching.",
                                  style: TextStyle(fontSize: 13, height: 1.35, color: VyseColors.textDim),
                                ),
                              ),
                            ],
                          )
                        else ...[
                          Text(
                            'ABOUT ME',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8, color: VyseColors.textDim),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            p.bio.isEmpty ? (p.isMe ? 'Add a bio in Settings.' : 'Nothing here yet.') : p.bio,
                            style: TextStyle(fontSize: 13.5, height: 1.4, color: p.bio.isEmpty ? VyseColors.textFaint : VyseColors.text),
                          ),
                          if (preview && p.private) ...[
                            const SizedBox(height: 10),
                            Text(
                              "Your profile is private: nobody else can add or message you, and only friends see your bio, banner, status line and what you watch.",
                              style: TextStyle(fontSize: 12, color: VyseColors.textFaint),
                            ),
                          ],
                        ],
                        if (p.joined != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'MEMBER SINCE',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8, color: VyseColors.textDim),
                          ),
                          const SizedBox(height: 4),
                          Text('${_months[p.joined!.month - 1]} ${p.joined!.day}, ${p.joined!.year}', style: const TextStyle(fontSize: 13)),
                        ],
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty) ...[const SizedBox(height: 14), Wrap(spacing: 8, runSpacing: 8, children: actions)],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .07), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: VyseColors.textDim),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: VyseColors.textDim),
        ),
      ],
    ),
  );
}

/// Opens someone's profile card: a dialog on wide screens, a sheet on phones.
Future<void> showPartyProfile(BuildContext context, String id, {PartyProfile? initial}) {
  // "Message" opens the chat in the tab this was opened from, not over the whole app
  final body = _ProfileLoader(id: id, initial: initial, nav: Navigator.of(context));
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      // over the whole app: opened inside the tab, the navbar covered the card's last buttons
      // (Block, Mute, Report)
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheet) => Padding(
        // clear of the system's gesture bar too
        padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + MediaQuery.viewPaddingOf(sheet).bottom),
        child: SingleChildScrollView(child: body),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .55),
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(child: body),
      ),
    ),
  );
}

class _ProfileLoader extends StatefulWidget {
  const _ProfileLoader({required this.id, required this.nav, this.initial});
  final String id;
  final NavigatorState nav;
  final PartyProfile? initial;

  @override
  State<_ProfileLoader> createState() => _ProfileLoaderState();
}

class _ProfileLoaderState extends State<_ProfileLoader> {
  late PartyProfile? _p = widget.initial;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await Party.profile(widget.id);
      if (mounted) setState(() => _p = p);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _do(Future<String> Function(String user) action) async {
    setState(() => _busy = true);
    try {
      await action(widget.id);
      await _load();
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _block(PartyProfile p) async {
    if (await confirmBlock(context, p) && mounted) await _do(Friends.block);
  }

  Future<void> _unfriend(PartyProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101118),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Remove ${p.name}?', style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Text("You'll stop being friends. You can add each other again later.", style: TextStyle(color: VyseColors.textDim, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: VyseColors.text)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _do(Friends.remove);
  }

  List<Widget> _actions(PartyProfile p) {
    final actions = _relationActions(p);
    // their library (My List and music), where the server would show it
    final open = p.relation != 'blocked' && (!p.private || p.relation == 'friends' || p.isMe);
    final library = PartyChipButton(
      icon: Icons.video_library_rounded,
      label: p.isMe ? 'Your library' : 'Library',
      onTap: () {
        Navigator.pop(context);
        openProfileLibrary(widget.nav, p);
      },
    );
    if (p.relation.isEmpty || p.relation == 'me') return [if (open) library, ...actions];
    return [
      ...actions.take(1),
      if (open) library,
      ...actions.skip(1),
      if (p.relation != 'blocked')
        ValueListenableBuilder<String>(
          valueListenable: AppSettings.partyMuted,
          builder: (context, _, _) {
            final muted = PartyMutes.has(p.id);
            return PartyChipButton(
              icon: muted ? Icons.notifications_off_rounded : Icons.notifications_none_rounded,
              label: muted ? 'Unmute' : 'Mute',
              onTap: () => PartyMutes.toggle(p.id),
            );
          },
        ),
      PartyChipButton(
        icon: Icons.flag_outlined,
        label: 'Report',
        onTap: () => showReportDialog(context, userId: p.id, name: p.name, kind: 'profile'),
      ),
    ];
  }

  List<Widget> _relationActions(PartyProfile p) {
    final block = PartyChipButton(icon: Icons.block_rounded, label: 'Block', danger: true, onTap: _busy ? null : () => _block(p));
    return switch (p.relation) {
      // private profiles can't be added (the server refuses too); they can add you
      'none' when p.private => [
        PartyChipButton(
          icon: Icons.lock_outline_rounded,
          label: 'Private profile',
          onTap: () => showToast(
            context,
            const Text('This profile is private. Only they can send friend requests.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            icon: Icons.lock_outline_rounded,
          ),
        ),
        block,
      ],
      'none' => [
        PartyChipButton(icon: Icons.person_add_alt_1_rounded, label: 'Add friend', primary: true, busy: _busy, onTap: () => _do(Friends.request)),
        block,
      ],
      'outgoing' => [PartyChipButton(icon: Icons.schedule_rounded, label: 'Request sent · Cancel', busy: _busy, onTap: () => _do(Friends.remove)), block],
      'incoming' => [
        PartyChipButton(icon: Icons.check_rounded, label: 'Accept', primary: true, busy: _busy, onTap: () => _do(Friends.accept)),
        PartyChipButton(icon: Icons.close_rounded, label: 'Decline', onTap: _busy ? null : () => _do(Friends.remove)),
        block,
      ],
      'friends' => [
        PartyChipButton(
          icon: Icons.chat_bubble_rounded,
          label: 'Message',
          primary: true,
          onTap: () {
            Navigator.pop(context);
            openDm(widget.nav, p);
          },
        ),
        PartyChipButton(icon: Icons.how_to_reg_rounded, label: 'Friends', busy: _busy, onTap: () => _unfriend(p)),
        block,
      ],
      'blocked' => [PartyChipButton(icon: Icons.lock_open_rounded, label: 'Unblock', busy: _busy, onTap: () => _do(Friends.unblock))],
      _ => const [],
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return Container(
        height: 280,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: partyCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VyseColors.stroke),
        ),
        child: _failed
            ? Text("Couldn't load this profile.", style: TextStyle(color: VyseColors.textDim))
            : SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)),
      );
    }
    return PartyProfileCard(profile: p, actions: _actions(p));
  }
}

/// Asks before blocking someone.
Future<bool> confirmBlock(BuildContext context, PartyProfile p) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101118),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Block ${p.name}?', style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Text(
          "They won't be able to add you, message you or see your profile, and you'll stop being friends. They aren't told.",
          style: TextStyle(color: VyseColors.textDim, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: VyseColors.text)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    ) ==
    true;

/// Small pill button for profile cards and friend rows.
class PartyChipButton extends StatelessWidget {
  const PartyChipButton({super.key, required this.icon, required this.label, this.onTap, this.primary = false, this.danger = false, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.black : (danger ? const Color(0xFFFF8A8C) : VyseColors.text);
    return Pressable(
      onTap: busy ? null : onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: primary
              ? (hovered ? Colors.white : const Color(0xFFF1F1F5))
              : (danger ? const Color(0xFFFF4D4F).withValues(alpha: hovered ? .2 : .1) : Colors.white.withValues(alpha: hovered ? .14 : .08)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy ? SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: fg)) : Icon(icon, size: 16, color: fg),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Image links ─────────────────────────

/// Paste an image link and see it as it will appear: checked locally, then loaded through the
/// same proxy everyone else sees it through. [onValid] gets the link once it loads, null otherwise.
class ImageLinkEditor extends StatefulWidget {
  const ImageLinkEditor({super.key, this.initial = '', this.circle = false, required this.onValid});
  final String initial;
  final bool circle; // avatar; otherwise a 5:2 banner
  final ValueChanged<String?> onValid;

  @override
  State<ImageLinkEditor> createState() => _ImageLinkEditorState();
}

enum _Check { empty, checking, ok, bad }

class _ImageLinkEditorState extends State<ImageLinkEditor> {
  late final _c = TextEditingController(text: widget.initial);
  Timer? _debounce;
  _Check _state = _Check.empty;
  String? _note;
  String _loaded = '';
  ImageStream? _stream;
  ImageStreamListener? _listener;

  Size get _size => widget.circle ? const Size(128, 128) : const Size(600, 240);

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    if (widget.initial.isNotEmpty) _check(widget.initial);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _stopListening();
    _c.dispose();
    super.dispose();
  }

  void _stopListening() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  void _changed() {
    _debounce?.cancel();
    final url = _c.text.trim();
    if (url == _loaded && _state == _Check.ok) return;
    widget.onValid(null);
    if (url.isEmpty) {
      _stopListening();
      setState(() {
        _state = _Check.empty;
        _note = null;
      });
      return;
    }
    final problem = ImageLinks.problem(url);
    if (problem != null) {
      _stopListening();
      setState(() {
        _state = _Check.bad;
        _note = problem;
      });
      return;
    }
    setState(() {
      _state = _Check.checking;
      _note = null;
    });
    _debounce = Timer(const Duration(milliseconds: 500), () => _check(url));
  }

  void _check(String url) {
    _stopListening();
    final provider = CachedNetworkImageProvider(ImageLinks.sized(url, width: _size.width.round(), height: _size.height.round()));
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (_, _) {
        if (!mounted || _c.text.trim() != url) return;
        setState(() {
          _state = _Check.ok;
          _loaded = url;
          _note = ImageLinks.warning(url);
        });
        widget.onValid(url);
      },
      onError: (_, _) {
        if (!mounted || _c.text.trim() != url) return;
        setState(() {
          _state = _Check.bad;
          _note = "That link doesn't open as an image.";
        });
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.circle ? 112.0 : 340.0;
    final h = widget.circle ? 112.0 : 136.0;
    final frame = Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .05),
        shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circle ? null : BorderRadius.circular(14),
        border: Border.all(color: _state == _Check.bad ? const Color(0xFFFF8A8C).withValues(alpha: .5) : VyseColors.stroke),
      ),
      child: switch (_state) {
        _Check.checking => SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)),
        _Check.bad => const Icon(Icons.broken_image_outlined, color: Color(0xFFFF8A8C)),
        _Check.empty => Icon(Icons.image_outlined, color: VyseColors.textFaint),
        _Check.ok => const SizedBox.shrink(),
      },
    );
    final preview = _state == _Check.ok
        ? ClipRRect(
            borderRadius: BorderRadius.circular(widget.circle ? w : 14),
            child: PartyImage(url: _loaded, width: w, height: h, fallback: frame),
          )
        : frame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(key: ValueKey('$_state$_loaded'), child: preview),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          onTapOutside: dismissKeyboard,
          controller: _c,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          maxLength: ImageLinks.maxLength,
          style: const TextStyle(fontSize: 14),
          cursorColor: VyseColors.accent,
          decoration: InputDecoration(
            counterText: '',
            hintText: 'https://i.imgur.com/….png',
            hintStyle: TextStyle(color: VyseColors.textFaint),
            prefixIcon: Icon(Icons.link_rounded, size: 19, color: VyseColors.textFaint),
            filled: true,
            fillColor: Colors.white.withValues(alpha: .05),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
        const SizedBox(height: 8),
        Text(
          _note ??
              switch (_state) {
                _Check.ok => 'Looks good. This is how others will see it.',
                _Check.checking => 'Checking the link…',
                _ => 'Paste a direct link to a JPG, PNG, GIF or WebP. GIFs stay animated.',
              },
          style: TextStyle(
            fontSize: 12.5,
            color: _state == _Check.bad
                ? const Color(0xFFFF8A8C)
                : (_note != null ? VyseColors.star : (_state == _Check.ok ? const Color(0xFF3DDC97) : VyseColors.textDim)),
          ),
        ),
      ],
    );
  }
}

/// Change or remove the profile banner.
Future<void> showBannerDialog(BuildContext context) =>
    showDialog<void>(context: context, barrierColor: Colors.black.withValues(alpha: .6), builder: (_) => const _BannerDialog());

class _BannerDialog extends StatefulWidget {
  const _BannerDialog();

  @override
  State<_BannerDialog> createState() => _BannerDialogState();
}

class _BannerDialogState extends State<_BannerDialog> {
  final _current = Account.user.value?.bannerUrl ?? '';
  String? _valid;
  bool _busy = false;
  String? _error;

  Future<void> _save(String url) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Account.updateProfile({'bannerUrl': url});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF0B0D16),
    insetPadding: const EdgeInsets.all(20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: VyseColors.stroke),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Profile banner', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('Shown across the top of your profile. Wide images (5:2) fit best.', style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
            const SizedBox(height: 18),
            ImageLinkEditor(initial: _current, onValid: (v) => setState(() => _valid = v)),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFFF8A8C), fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (_current.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : () => _save(''),
                    child: const Text(
                      'Remove',
                      style: TextStyle(color: Color(0xFFFF8A8C), fontWeight: FontWeight.w700),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel', style: TextStyle(color: VyseColors.textDim)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                  onPressed: _busy || _valid == null || _valid == _current ? null : () => _save(_valid!),
                  child: _busy
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// One-field text editor (bio, status line). Returns the new text, or null when cancelled.
Future<String?> showTextEditDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required int maxLength,
  String? hint,
  int maxLines = 1,
}) async {
  final c = TextEditingController(text: initial);
  final out = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: VyseColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      content: SizedBox(
        width: 400,
        child: TextField(
          onTapOutside: dismissKeyboard,
          controller: c,
          autofocus: true,
          maxLength: maxLength,
          maxLines: maxLines,
          minLines: 1,
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
          decoration: InputDecoration(hintText: hint),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
      ],
    ),
  );
  c.dispose();
  return out?.trim();
}

/// Saves profile fields, telling the user when the server says no.
Future<void> saveProfile(BuildContext context, Map<String, dynamic> body) async {
  try {
    await Account.updateProfile(body);
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

/// A quiet one-line message in a box (empty lists, hints).
class PartyNote extends StatelessWidget {
  const PartyNote({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: VyseColors.stroke),
    ),
    child: Row(
      children: [
        Icon(icon, size: 20, color: VyseColors.textFaint),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
        ),
      ],
    ),
  );
}

/// A person in a list: avatar with status, name, what they're up to. Opens their profile.
class PartyPersonRow extends StatelessWidget {
  const PartyPersonRow({super.key, required this.profile, this.trailing = const []});
  final PartyProfile profile;
  final List<Widget> trailing; // buttons; a chevron when empty

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final act = p.activity;
    final line = act != null
        ? 'Watching ${activityTitle(act)}'
        : (p.customStatus.isNotEmpty ? p.customStatus : (p.presence == 'offline' && p.lastSeen != null ? 'Last seen ${_ago(p.lastSeen!)}' : '@${p.username}'));
    return Pressable(
      onTap: () => showPartyProfile(context, p.id, initial: p),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        color: Colors.white.withValues(alpha: hovered ? .05 : 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            PartyAvatar(url: p.avatarUrl, name: p.name, size: 42, presence: p.presence),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (p.isMe) ...[
                        const SizedBox(width: 6),
                        Text(
                          'you',
                          style: TextStyle(fontSize: 11.5, color: VyseColors.accent, fontWeight: FontWeight.w800),
                        ),
                      ],
                      if (p.private) ...[const SizedBox(width: 6), Icon(Icons.lock_outline_rounded, size: 13, color: VyseColors.textFaint)],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (act != null) ...[const Icon(Icons.play_circle_fill_rounded, size: 12, color: Color(0xFF3DDC97)), const SizedBox(width: 4)],
                      Expanded(
                        child: Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (trailing.isEmpty) Icon(Icons.chevron_right_rounded, color: VyseColors.textFaint) else ...trailing,
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Reports ─────────────────────────

const _reasons = [
  ('harassment', 'Harassment or bullying'),
  ('hate', 'Hate or slurs'),
  ('sexual', 'Sexual or shocking content'),
  ('violence', 'Threats or violence'),
  ('spam', 'Spam or scams'),
  ('impersonation', 'Pretending to be someone else'),
  ('other', 'Something else'),
];

/// Reports someone: their profile, a message ([ref] = its id) or what happened in a room. The
/// server keeps a copy of the evidence, so it still counts after messages disappear.
Future<void> showReportDialog(BuildContext context, {required String userId, required String name, required String kind, String? ref}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: .6),
  builder: (_) => _ReportDialog(userId: userId, name: name, kind: kind, ref: ref),
);

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.userId, required this.name, required this.kind, this.ref});
  final String userId;
  final String name;
  final String kind;
  final String? ref;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String? _reason;
  final _details = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    if (_reason == null) {
      setState(() => _error = "Pick what's wrong first.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Account.pb.send(
        '/api/vyse/report',
        method: 'POST',
        body: {'target': widget.userId, 'kind': widget.kind, 'reason': _reason, 'details': _details.text.trim(), 'ref': ?widget.ref},
      );
      if (!mounted) return;
      Navigator.pop(context);
      showToast(
        context,
        const Text("Thanks. We'll take a look.", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        icon: Icons.flag_rounded,
      );
    } catch (e) {
      // the server says exactly why ("That message is gone."): show that, not a generic line
      final said = e is ClientException && e.statusCode >= 400 && e.statusCode < 500 && e.statusCode != 429 ? e.response['message'] as String? : null;
      if (mounted) setState(() => _error = said != null && said.isNotEmpty ? said : Account.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF0B0D16),
    insetPadding: const EdgeInsets.all(20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: VyseColors.stroke),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.kind == 'profile' ? 'Report ${widget.name}' : (widget.kind == 'voice' ? 'Report ${widget.name} in this room' : 'Report this message'),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text("They won't know who reported them.", style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
            const SizedBox(height: 14),
            for (final (id, label) in _reasons)
              Pressable(
                onTap: () => setState(() {
                  _reason = id;
                  _error = null;
                }),
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: _reason == id ? .1 : (hovered ? .05 : .03)),
                    border: Border.all(color: _reason == id ? VyseColors.accent.withValues(alpha: .7) : VyseColors.stroke),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _reason == id ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        size: 18,
                        color: _reason == id ? VyseColors.accent : VyseColors.textFaint,
                      ),
                      const SizedBox(width: 10),
                      Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              onTapOutside: dismissKeyboard,
              controller: _details,
              maxLength: 500,
              maxLines: 3,
              minLines: 2,
              style: const TextStyle(fontSize: 14),
              cursorColor: VyseColors.accent,
              decoration: InputDecoration(
                hintText: 'Anything else we should know? (optional)',
                hintStyle: TextStyle(color: VyseColors.textFaint),
                filled: true,
                fillColor: Colors.white.withValues(alpha: .05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A8C), fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel', style: TextStyle(color: VyseColors.textDim)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D4F), foregroundColor: Colors.white),
                  onPressed: _busy ? null : _send,
                  child: _busy
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Send report', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

const partyRules = [
  (Icons.favorite_outline_rounded, 'Be kind', 'No harassment, hate, threats or bullying.'),
  (Icons.image_not_supported_outlined, 'Keep it clean', 'No nudity, gore or shock images in avatars, banners, bios or messages.'),
  (Icons.block_rounded, 'No spam or scams', 'No advertising, phishing links or pretending to be someone else.'),
  (Icons.lock_outline_rounded, 'Respect privacy', "Don't share other people's messages or personal details."),
  (Icons.gavel_rounded, 'Reports are reviewed', 'Breaking the rules can get you removed from Party.'),
];

/// The rules you accepted, to read again from settings.
Future<void> showPartyRules(BuildContext context) => showDialog<void>(
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
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Party rules', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
            const SizedBox(height: 16),
            for (final (icon, title, body) in partyRules)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20, color: VyseColors.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(body, style: TextStyle(fontSize: 13, height: 1.35, color: VyseColors.textDim)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ),
          ],
        ),
      ),
    ),
  ),
);
