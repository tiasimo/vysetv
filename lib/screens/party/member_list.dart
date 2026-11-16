import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/account.dart';
import '../../data/party/friends.dart';
import '../../data/party/party.dart';
import '../../widgets/common.dart';
import 'party_widgets.dart';

const _panel = Color(0xFF0A0B13);

/// Everyone on Lorewatch, Discord-style: who's watching something, then online people grouped by
/// role, then online, then offline. Loads 50 at a time as you scroll and refreshes every 30 s.
class PartyMemberPanel extends StatefulWidget {
  const PartyMemberPanel({super.key, this.topPadding = 0, this.onCount});
  final double topPadding;
  final ValueChanged<int>? onCount; // how many are online, for a header elsewhere

  @override
  State<PartyMemberPanel> createState() => _PartyMemberPanelState();
}

class _PartyMemberPanelState extends State<PartyMemberPanel> {
  final _scroll = ScrollController();
  final _items = <PartyProfile>[];
  List<MemberGroup> _groups = const [];
  List<PartyProfile> _activity = const [];
  int _pages = 0; // loaded
  int _totalPages = 1;
  bool _loading = false;
  bool _failed = false;
  bool _allActivity = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load(1);
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _more();
    });
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => _reload());
    _wasListing = _listing();
    Account.user.addListener(_mine);
    Friends.lists.addListener(_mine);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    Account.user.removeListener(_mine);
    Friends.lists.removeListener(_mine);
    _scroll.dispose();
    super.dispose();
  }

  // your own row follows your settings right away; the server's copy catches up within 20 s
  (bool, bool)? _wasListing;
  static (bool, bool)? _listing() => switch (Account.user.value) {
    final u? => (u.private, u.onlineListHidden),
    null => null,
  };

  void _mine() {
    if (!mounted) return;
    setState(() {});
    // showing or hiding yourself changes who's listed (and the counts), going private what your
    // row shows: fetch it fresh
    final listing = _listing();
    if (_wasListing != null && listing != null && listing != _wasListing) unawaited(_reload());
    _wasListing = listing;
  }

  Future<MemberPage?> _fetch(int page) async {
    try {
      return await Party.members(page: page);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() => _loading = true);
    final r = await _fetch(page);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r == null) {
        _failed = _items.isEmpty;
        return;
      }
      _failed = false;
      if (page == 1) _items.clear();
      _items.addAll(r.items);
      _pages = page;
      _apply(r);
    });
  }

  void _apply(MemberPage r) {
    _groups = r.groups;
    _activity = r.activity;
    _totalPages = r.totalPages;
    widget.onCount?.call(r.online);
  }

  void _more() {
    if (!_loading && _pages > 0 && _pages < _totalPages) _load(_pages + 1);
  }

  /// Fetches the pages already showing again (up to 4), so scrolled-down lists stay put.
  Future<void> _reload() async {
    if (_loading || !mounted) return;
    final upto = _pages.clamp(1, 4);
    final pages = await Future.wait([for (var p = 1; p <= upto; p++) _fetch(p)]);
    if (!mounted || pages.any((p) => p == null)) return;
    setState(() {
      _items
        ..clear()
        ..addAll(pages.expand((p) => p!.items));
      _pages = upto;
      _apply(pages.first!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = PartyProfile.mine();
    final byId = {for (final g in _groups) g.id: g};
    final rows = <Widget>[];
    String? group;
    final blocked = Friends.lists.value.blockedIds;
    final hideMe = Account.user.value?.onlineListHidden ?? false;
    for (final p0 in _items) {
      if (blocked.contains(p0.id)) continue;
      if (hideMe && me != null && p0.id == me.id) continue; // Online list: Hide
      final p = me != null && p0.id == me.id ? _withMine(p0, me) : p0;
      if (p0.group != group) {
        group = p0.group;
        final g = byId[group];
        rows.add(_Header(text: '${g?.name ?? (group == 'offline' ? 'Offline' : 'Online')} — ${g?.count ?? ''}'));
      }
      rows.add(_MemberRow(profile: p, color: byId[p0.group]?.color, dim: p0.group == 'offline'));
    }
    final acts = _allActivity ? _activity : _activity.take(3).toList();

    return Container(
      color: _panel,
      child: _failed
          ? _Retry(onTap: () => _load(1), top: widget.topPadding)
          : (_items.isEmpty && _loading)
          ? Padding(
              padding: EdgeInsets.only(top: widget.topPadding),
              child: const Center(
                child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim)),
              ),
            )
          : ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(10, widget.topPadding + 10, 10, 30),
              children: [
                if (_activity.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(child: _Header(text: 'Activity — ${_activity.length}')),
                      if (_activity.length > 3)
                        TextButton(
                          onPressed: () => setState(() => _allActivity = !_allActivity),
                          child: Text(_allActivity ? 'Less' : 'All', style: const TextStyle(fontSize: 12, color: VyseColors.textDim)),
                        ),
                    ],
                  ),
                  for (final a in acts) _ActivityCard(profile: a),
                  const SizedBox(height: 6),
                ],
                ...rows,
                if (_loading && _items.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Center(
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textFaint)),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Your row as you are right now, not as the cached list last saw you.
  static PartyProfile _withMine(PartyProfile row, PartyProfile me) => PartyProfile(
    id: row.id,
    username: me.username,
    name: me.name,
    avatarUrl: me.avatarUrl,
    customStatus: me.private ? '' : me.customStatus,
    private: me.private,
    presence: me.presence,
    activity: me.activity,
    role: row.role,
    group: row.group,
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7, color: VyseColors.textDim),
    ),
  );
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.profile, this.color, this.dim = false});
  final PartyProfile profile;
  final Color? color; // role colour
  final bool dim; // offline

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final act = p.activity;
    final line = act != null ? 'Watching ${activityTitle(act)}' : p.customStatus;
    return Pressable(
      onTap: () => showPartyProfile(context, p.id, initial: p),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovered ? .06 : 0),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Opacity(
          opacity: dim && !hovered ? .45 : 1,
          child: Row(
            children: [
              PartyAvatar(url: p.avatarUrl, name: p.name, size: 34, presence: dim ? null : p.presence, ring: _panel),
              const SizedBox(width: 11),
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
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color ?? VyseColors.text),
                          ),
                        ),
                        if (p.private) ...[
                          const SizedBox(width: 5),
                          const Tooltip(
                            message: 'Private profile',
                            child: Icon(Icons.lock_outline_rounded, size: 12, color: VyseColors.textFaint),
                          ),
                        ],
                      ],
                    ),
                    if (line.isNotEmpty && !dim)
                      Row(
                        children: [
                          if (act != null) ...[const Icon(Icons.play_circle_fill_rounded, size: 12, color: Color(0xFF3DDC97)), const SizedBox(width: 4)],
                          Expanded(
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Someone watching something right now, with the poster.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.profile});
  final PartyProfile profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final a = p.activity!;
    final poster = a['poster'] as String?;
    final since = DateTime.fromMillisecondsSinceEpoch((a['since'] as num?)?.toInt() ?? 0);
    final mins = DateTime.now().difference(since).inMinutes;
    return Pressable(
      onTap: () => showPartyProfile(context, p.id, initial: p),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: hovered ? .07 : .04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VyseColors.stroke),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PartyAvatar(url: p.avatarUrl, name: p.name, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: VyseColors.textDim, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    a['title'] as String? ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.play_circle_fill_rounded, size: 12, color: Color(0xFF3DDC97)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          [
                            if (a['kind'] == 'tv' && a['episode'] != null) a['season'] == null ? 'E${a['episode']}' : 'S${a['season']}E${a['episode']}',
                            mins < 1 ? 'just started' : (mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m'),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: VyseColors.textDim),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (poster != null) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(imageUrl: 'https://image.tmdb.org/t/p/w92$poster', width: 38, height: 56, fit: BoxFit.cover),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.onTap, required this.top});
  final VoidCallback onTap;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, top + 30, 20, 20),
    child: Column(
      children: [
        const Icon(Icons.wifi_off_rounded, color: VyseColors.textFaint),
        const SizedBox(height: 10),
        const Text(
          "Couldn't load members.",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: VyseColors.textDim),
        ),
        TextButton(onPressed: onTap, child: const Text('Try again')),
      ],
    ),
  );
}

/// The member list as a sheet (phones).
Future<void> showMemberSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: _panel,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .85,
    child: Column(
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(2)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Members', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          ),
        ),
        const Expanded(child: PartyMemberPanel()),
      ],
    ),
  ),
);
