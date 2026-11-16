import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../media_servers/media_servers.dart';
import '../../widgets/common.dart';
import 'server_widgets.dart';

/// Connect a server: pick Plex, Jellyfin or Emby (or a server found on your network), then
/// sign in. A dialog on wide screens, a sheet on phones. True when a server was added.
Future<bool> showServerSignIn(BuildContext context, {MediaBackend? backend, DiscoveredJellyfinServer? found}) async {
  final body = _SignIn(backend: found == null ? backend : found.dialect.backend, found: found);
  final bool? added;
  if (Layout.isPhone(context)) {
    added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B0D16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(child: body),
      ),
    );
  } else {
    added = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .65),
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0B0D16),
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: VyseColors.stroke)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: SingleChildScrollView(child: body)),
      ),
    );
  }
  return added ?? false;
}

enum _Step { choose, plex, address, login, quickConnect, done }

class _SignIn extends StatefulWidget {
  const _SignIn({this.backend, this.found});
  final MediaBackend? backend;
  final DiscoveredJellyfinServer? found;

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  late _Step _step = switch (widget.backend) {
    null => _Step.choose,
    MediaBackend.plex => _Step.plex,
    _ => _Step.address,
  };
  MediaBackend _backend = MediaBackend.jellyfin;
  bool _busy = false;
  String? _error;
  bool _closed = false;

  // Plex
  PlexSignIn? _plex;

  // Jellyfin / Emby
  JellyfinSignIn? _jelly;
  final _address = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _showPass = false;
  String? _code;
  int _qcAttempt = 0;

  // what's around
  Future<List<DiscoveredJellyfinServer>>? _nearby;

  // done
  String _doneTitle = '';
  String _doneBody = '';

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? MediaBackend.jellyfin;
    if (widget.found != null) _address.text = widget.found!.address;
    switch (_step) {
      case _Step.plex:
        _startPlex();
      case _Step.choose || _Step.address:
        _nearby = JellyfinSignIn.discover();
        if (widget.found != null) WidgetsBinding.instance.addPostFrameCallback((_) => _find());
      default:
    }
  }

  @override
  void dispose() {
    _closed = true;
    _address.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _go(_Step s) => setState(() {
    _step = s;
    _error = null;
    _busy = false;
  });

  void _pick(MediaBackend b) {
    _backend = b;
    if (b == MediaBackend.plex) {
      _go(_Step.plex);
      _startPlex();
    } else {
      _jelly = null;
      _go(_Step.address);
    }
  }

  // ── Plex ──

  Future<void> _startPlex() async {
    setState(() {
      _busy = true;
      _error = null;
      _plex = null;
    });
    try {
      final flow = await PlexSignIn.start();
      if (_closed) return;
      setState(() {
        _plex = flow;
        _busy = false;
      });
      unawaited(launchUrl(Uri.parse(flow.url), mode: LaunchMode.externalApplication).catchError((Object _) => false));
      final account = await flow.wait(cancelled: () => _closed || _plex != flow);
      if (_closed || _plex != flow) return;
      if (account == null) {
        setState(() => _error = 'That took a while, so the link expired. Try again.');
        return;
      }
      final n = account.conn.servers.length;
      _finish(
        "You're in, ${account.who}",
        n == 0
            ? 'No servers on this account yet. Ones shared with you later will show up here.'
            : (n == 1 ? 'Found ${account.conn.servers.first.name}.' : 'Found $n servers.'),
      );
    } catch (e) {
      if (_closed) return;
      setState(() {
        _busy = false;
        _error = serverError(e);
      });
    }
  }

  // ── Jellyfin / Emby ──

  JellyfinSignIn get _flow => _jelly ??= JellyfinSignIn(
    _backend == MediaBackend.emby ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin,
  );

  Future<void> _find() async {
    if (_address.text.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    _jelly = null;
    try {
      await _flow.find(_address.text);
      if (_closed) return;
      _backend = _flow.dialect.backend;
      _go(_Step.login);
    } catch (e) {
      if (_closed) return;
      setState(() {
        _busy = false;
        _error = serverError(e);
      });
    }
  }

  Future<void> _login() async {
    if (_user.text.trim().isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final a = await _flow.login(_user.text, _pass.text);
      if (_closed) return;
      _finish('Welcome, ${a.who}', 'Connected to ${a.conn.serverName}.');
    } catch (e) {
      if (_closed) return;
      setState(() {
        _busy = false;
        _error = serverError(e);
      });
    }
  }

  Future<void> _quickConnect() async {
    final attempt = ++_qcAttempt;
    setState(() {
      _step = _Step.quickConnect;
      _code = null;
      _error = null;
      _busy = true;
    });
    try {
      final qc = await _flow.startQuickConnect();
      if (_closed || attempt != _qcAttempt) return;
      setState(() {
        _code = qc.code;
        _busy = false;
      });
      final a = await _flow.waitQuickConnect(qc.secret, cancelled: () => _closed || attempt != _qcAttempt);
      if (_closed || attempt != _qcAttempt) return;
      if (a == null) {
        setState(() => _error = 'The code expired. Get a new one.');
        return;
      }
      _finish('Welcome, ${a.who}', 'Connected to ${a.conn.serverName}.');
    } catch (e) {
      if (_closed || attempt != _qcAttempt) return;
      setState(() {
        _busy = false;
        _error = serverError(e);
      });
    }
  }

  void _finish(String title, String body) {
    HapticFeedback.mediumImpact();
    setState(() {
      _doneTitle = title;
      _doneBody = body;
      _step = _Step.done;
      _busy = false;
      _error = null;
    });
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (!_closed && mounted) Navigator.of(context).pop(true);
    });
  }

  // ── layout ──

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(26, 22, 26, 26),
    child: AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(.04, 0), end: Offset.zero).animate(a), child: child),
        ),
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(_step), child: _body()),
      ),
    ),
  );

  Widget _body() => switch (_step) {
    _Step.choose => _chooseView(),
    _Step.plex => _plexView(),
    _Step.address => _addressView(),
    _Step.login => _loginView(),
    _Step.quickConnect => _quickConnectView(),
    _Step.done => _doneView(),
  };

  Widget _header({required String title, required String body, Widget? leading, bool back = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        if (back)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: GlassIconButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              size: 34,
              onTap: () => _go(_step == _Step.login || _step == _Step.quickConnect
                  ? _Step.address
                  : (widget.backend == null ? _Step.choose : _step)),
            ),
          ),
        ?leading,
        const Spacer(),
        GlassIconButton(icon: Icons.close_rounded, label: 'Close', size: 34, onTap: () => Navigator.of(context).pop(false)),
      ]),
      const SizedBox(height: 16),
      Text(title, style: const TextStyle(fontSize: 24, height: 1.15, fontWeight: FontWeight.w900, letterSpacing: -.3)),
      const SizedBox(height: 6),
      Text(body, style: const TextStyle(fontSize: 13.5, height: 1.45, color: VyseColors.textDim)),
      const SizedBox(height: 20),
    ],
  );

  Widget _errorLine() => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: _error == null
        ? const SizedBox(width: double.infinity)
        : Container(
            key: ValueKey(_error),
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFF5F6D).withValues(alpha: .1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFF5F6D).withValues(alpha: .3)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.error_outline_rounded, size: 17, color: Color(0xFFFF8A93)),
              const SizedBox(width: 9),
              Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12.5, height: 1.4, color: Color(0xFFFFC2C7)))),
            ]),
          ),
  );

  // choose

  Widget _chooseView() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _header(title: 'Connect a server', body: 'Watch your own library with Lorewatch. Pick what your server runs.'),
      for (final (i, b) in const [MediaBackend.plex, MediaBackend.jellyfin, MediaBackend.emby].indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FadeSlideIn(
            delay: Duration(milliseconds: 40 * i),
            offset: 8,
            child: _ProviderRow(
              backend: b,
              blurb: switch (b) {
                MediaBackend.plex => 'Sign in with your Plex account',
                MediaBackend.emby => 'Your server address and login',
                _ => 'Your server address, login or Quick Connect',
              },
              onTap: () => _pick(b),
            ),
          ),
        ),
      _Nearby(
        future: _nearby,
        onPick: (s) {
          _backend = s.dialect.backend;
          _address.text = s.address;
          _jelly = null;
          _go(_Step.address);
          _find();
        },
      ),
    ],
  );

  // Plex

  Widget _plexView() {
    final flow = _plex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          leading: const BrandMark(MediaBackend.plex, size: 34),
          back: widget.backend == null,
          title: 'Sign in with Plex',
          body: 'We opened plex.tv in your browser. Sign in there and press Allow, and Lorewatch picks it up by itself.',
        ),
        _errorLine(),
        if (_error != null)
          _Submit(label: 'Try again', busy: false, onTap: _startPlex)
        else ...[
          _Waiting(label: flow == null ? 'Getting a sign-in link…' : 'Waiting for you to press Allow…', colors: brandColors(MediaBackend.plex)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: PillButton(
                label: 'Open plex.tv',
                icon: Icons.open_in_new_rounded,
                expand: true,
                onTap: flow == null ? () {} : () => launchUrl(Uri.parse(flow.url), mode: LaunchMode.externalApplication),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PillButton(
                label: 'Copy link',
                icon: Icons.link_rounded,
                expand: true,
                onTap: flow == null
                    ? () {}
                    : () {
                        Clipboard.setData(ClipboardData(text: flow.url));
                        showToast(context, const Text('Link copied. Open it on any device.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.link_rounded);
                      },
              ),
            ),
          ]),
        ],
        const SizedBox(height: 16),
        const _Note(icon: Icons.lock_outline_rounded, text: 'Lorewatch never sees your Plex password. Your sign-in stays on this device.'),
      ],
    );
  }

  // Jellyfin / Emby: address

  Widget _addressView() {
    final name = brandName(_backend);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          leading: BrandMark(_backend, size: 34),
          back: widget.backend == null,
          title: 'Find your $name server',
          body: 'Its address, like 192.168.1.20 or ${name.toLowerCase()}.example.com. The port is optional.',
        ),
        _Field(
          controller: _address,
          label: 'Server address',
          hint: '192.168.1.20:${_backend == MediaBackend.emby ? 8096 : 8096}',
          icon: Icons.dns_outlined,
          autofocus: widget.found == null,
          keyboard: TextInputType.url,
          onSubmit: _find,
        ),
        const SizedBox(height: 16),
        _errorLine(),
        ListenableBuilder(
          listenable: _address,
          builder: (context, _) => _Submit(label: 'Continue', busy: _busy, enabled: _address.text.trim().isNotEmpty, onTap: _find),
        ),
        _Nearby(
          future: _nearby,
          only: _backend,
          onPick: (s) {
            _backend = s.dialect.backend;
            _address.text = s.address;
            _jelly = null;
            _find();
          },
        ),
      ],
    );
  }

  // Jellyfin / Emby: login

  Widget _loginView() {
    final info = _flow.server;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          leading: BrandMark(_backend, size: 34),
          back: true,
          title: info?.serverName ?? brandName(_backend),
          body: 'Sign in with your ${brandName(_backend)} username and password.',
        ),
        _Field(controller: _user, label: 'Username', hint: 'Your name on the server', icon: Icons.person_outline_rounded, autofocus: true, onSubmit: _login),
        const SizedBox(height: 14),
        _Field(
          controller: _pass,
          label: 'Password',
          hint: 'Leave empty if there is none',
          icon: Icons.lock_outline_rounded,
          obscure: !_showPass,
          onSubmit: _login,
          trailing: IconButton(
            tooltip: _showPass ? 'Hide' : 'Show',
            icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 19, color: VyseColors.textFaint),
            onPressed: () => setState(() => _showPass = !_showPass),
          ),
        ),
        const SizedBox(height: 18),
        _errorLine(),
        ListenableBuilder(
          listenable: _user,
          builder: (context, _) => _Submit(label: 'Sign in', busy: _busy, enabled: _user.text.trim().isNotEmpty, onTap: _login),
        ),
        if (_flow.quickConnect) ...[
          const SizedBox(height: 12),
          Center(
            child: Pressable(
              onTap: _busy ? null : _quickConnect,
              builder: (context, hovered, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bolt_rounded, size: 17, color: hovered ? VyseColors.accent : VyseColors.textDim),
                  const SizedBox(width: 6),
                  Text(
                    'Use Quick Connect instead',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: hovered ? VyseColors.accent : VyseColors.textDim),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // Jellyfin: Quick Connect

  Widget _quickConnectView() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _header(
        leading: BrandMark(_backend, size: 34),
        back: true,
        title: 'Quick Connect',
        body: 'On a device that is already signed in, open your profile, then Quick Connect, and enter this code.',
      ),
      _errorLine(),
      Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _code == null
              ? const SizedBox(height: 76, child: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: VyseColors.accent)))
              : Row(
                  key: ValueKey(_code),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, ch) in _code!.split('').indexed)
                      FadeSlideIn(
                        delay: Duration(milliseconds: 50 * i),
                        offset: 8,
                        child: Container(
                          width: 46,
                          height: 62,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
                          ),
                          child: Text(ch, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()])),
                        ),
                      ),
                  ],
                ),
        ),
      ),
      const SizedBox(height: 22),
      if (_error != null)
        _Submit(label: 'Get a new code', busy: false, onTap: _quickConnect)
      else
        _Waiting(label: 'Waiting for the server…', colors: brandColors(_backend)),
    ],
  );

  // done

  Widget _doneView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26),
    child: Column(children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 620),
        curve: Curves.elasticOut,
        builder: (context, v, child) => Transform.scale(scale: .4 + .6 * v, child: child),
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: brandColors(_backend)),
            boxShadow: [BoxShadow(color: brandColors(_backend).last.withValues(alpha: .5), blurRadius: 30)],
          ),
          child: const Icon(Icons.check_rounded, size: 44, color: Colors.white),
        ),
      ),
      const SizedBox(height: 20),
      Text(_doneTitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
      const SizedBox(height: 6),
      Text(_doneBody, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
    ]),
  );
}

// ───────────────────────── Pieces ─────────────────────────

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.backend, required this.blurb, required this.onTap});
  final MediaBackend backend;
  final String blurb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = brandColors(backend);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, pressed) => AnimatedScale(
        scale: pressed ? .98 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withValues(alpha: hovered ? .07 : .04),
            border: Border.all(color: hovered ? c.first.withValues(alpha: .55) : Colors.white.withValues(alpha: .07)),
            boxShadow: [if (hovered) BoxShadow(color: c.last.withValues(alpha: .18), blurRadius: 24)],
          ),
          child: Row(children: [
            BrandMark(backend, size: 42),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(brandName(backend), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 2),
                Text(blurb, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
              ]),
            ),
            AnimatedSlide(
              offset: Offset(hovered ? .15 : 0, 0),
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.arrow_forward_rounded, size: 20, color: hovered ? c.first : VyseColors.textFaint),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Jellyfin and Emby servers answering on your network, one tap to connect.
class _Nearby extends StatelessWidget {
  const _Nearby({required this.future, required this.onPick, this.only});
  final Future<List<DiscoveredJellyfinServer>>? future;
  final ValueChanged<DiscoveredJellyfinServer> onPick;
  final MediaBackend? only;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DiscoveredJellyfinServer>>(
    future: future,
    builder: (context, snap) {
      if (future == null) return const SizedBox.shrink();
      final list = (snap.data ?? const []).where((s) => only == null || s.dialect.backend == only).toList();
      final searching = snap.connectionState != ConnectionState.done;
      if (!searching && list.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.wifi_tethering_rounded, size: 15, color: VyseColors.textFaint),
            const SizedBox(width: 7),
            Text(
              searching ? 'Looking around your network…' : 'On your network',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: VyseColors.textFaint, letterSpacing: .3),
            ),
            if (searching) ...[
              const SizedBox(width: 8),
              const SizedBox.square(dimension: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: VyseColors.textFaint)),
            ],
          ]),
          const SizedBox(height: 10),
          for (final (i, s) in list.indexed)
            FadeSlideIn(
              delay: Duration(milliseconds: 50 * i),
              offset: 6,
              child: Pressable(
                onTap: () => onPick(s),
                builder: (context, hovered, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white.withValues(alpha: hovered ? .07 : .035),
                    border: Border.all(color: Colors.white.withValues(alpha: hovered ? .14 : .06)),
                  ),
                  child: Row(children: [
                    BrandMark(s.dialect.backend, size: 26),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                        Text(s.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: VyseColors.textFaint)),
                      ]),
                    ),
                    Text('Connect', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: hovered ? VyseColors.accent : VyseColors.textDim)),
                  ]),
                ),
              ),
            ),
        ]),
      );
    },
  );
}

/// Three dots breathing in the brand's colours, with what we're waiting on.
class _Waiting extends StatefulWidget {
  const _Waiting({required this.label, required this.colors});
  final String label;
  final List<Color> colors;

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: Colors.white.withValues(alpha: .04),
      border: Border.all(color: Colors.white.withValues(alpha: .06)),
    ),
    child: Row(children: [
      AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(children: [
          for (var i = 0; i < 3; i++)
            () {
              final t = ((_c.value - i * .18) % 1.0);
              final s = .55 + .45 * (t < .5 ? t * 2 : (1 - t) * 2);
              return Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 6),
                transform: Matrix4.diagonal3Values(s, s, 1),
                transformAlignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Color.lerp(widget.colors.first, widget.colors.last, i / 2)!.withValues(alpha: s)),
              );
            }(),
        ]),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(widget.label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: VyseColors.textDim))),
    ]),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, size: 14, color: VyseColors.textFaint),
    const SizedBox(width: 7),
    Expanded(child: Text(text, style: const TextStyle(fontSize: 11.5, height: 1.4, color: VyseColors.textFaint))),
  ]);
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.onSubmit,
    this.obscure = false,
    this.keyboard,
    this.trailing,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback onSubmit;
  final bool obscure;
  final TextInputType? keyboard;
  final Widget? trailing;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
      ),
      TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        autofocus: autofocus,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => onSubmit(),
        style: const TextStyle(fontSize: 14.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 14),
          prefixIcon: Icon(icon, size: 19, color: VyseColors.textFaint),
          suffixIcon: trailing == null ? null : Padding(padding: const EdgeInsets.only(right: 6), child: Center(widthFactor: 1, child: trailing)),
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
    ],
  );
}

class _Submit extends StatelessWidget {
  const _Submit({required this.label, required this.busy, required this.onTap, this.enabled = true});
  final String label;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: enabled && !busy ? onTap : null,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed && enabled ? .98 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: enabled || busy ? (hovered ? Colors.white : Colors.white.withValues(alpha: .93)) : Colors.white.withValues(alpha: .1),
          boxShadow: [if (enabled && hovered) BoxShadow(color: Colors.white.withValues(alpha: .2), blurRadius: 18)],
        ),
        child: busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black))
            : Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: enabled ? Colors.black : VyseColors.textFaint)),
      ),
    ),
  );
}
