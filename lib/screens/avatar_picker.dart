import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/layout.dart';
import '../core/theme.dart';
import '../data/account.dart';
import '../data/app_settings.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/section_chrome.dart';
import 'party/party_widgets.dart';
import 'profile_page.dart';

const _img = 'https://image.tmdb.org/t/p/w185';

class _Show {
  const _Show(this.id, this.title, this.tv);
  final int id;
  final String title;
  final bool tv;
}

class _Character {
  const _Character(this.name, this.photo);
  final String name;
  final String photo;
}

/// A show's Netflix profile icons (bundled list).
class _NetflixSet {
  const _NetflixSet(this.title, this.icons);
  final String title;
  final List<_Character> icons;
}

/// Pick an avatar: Netflix's profile icons, a character from a show via TMDB, or any image link.
Future<void> showAvatarPicker(BuildContext context) =>
    showDialog<void>(context: context, barrierColor: Colors.black.withValues(alpha: .6), builder: (_) => const _AvatarPicker());

class _AvatarPicker extends StatefulWidget {
  const _AvatarPicker();

  @override
  State<_AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<_AvatarPicker> {
  static Future<List<_Show>>? _popular;
  static final _casts = <String, Future<List<_Character>>>{};
  static Future<List<_NetflixSet>>? _netflixSets;

  int _source = 0; // 0 Netflix, 1 TMDB, 2 image link
  bool get _netflix => _source == 0;
  String? _link; // a link that loaded, ready to use
  bool _saving = false;
  late final Future<List<_NetflixSet>> _netflixAll = _netflixSets ??= _loadNetflix();

  static Future<List<_NetflixSet>> _loadNetflix() async {
    final raw = json.decode(await rootBundle.loadString('assets/avatars/netflix.json')) as List;
    return [
      for (final g in raw.cast<Map<String, dynamic>>())
        _NetflixSet(g['s'] as String, [for (final i in (g['i'] as List).cast<List>()) _Character(i[0] as String, i[1] as String)]),
    ];
  }

  /// A show title match keeps the whole set; otherwise only the matching characters.
  List<_NetflixSet> _filterNetflix(List<_NetflixSet> all) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final s in all)
        if (s.title.toLowerCase().contains(q))
          s
        else if (s.icons.where((c) => c.name.toLowerCase().contains(q)).toList() case final hits when hits.isNotEmpty)
          _NetflixSet(s.title, hits),
    ];
  }

  void _chooseNetflix(_Character c, _NetflixSet s) {
    AppSettings.avatarUrl.set(c.photo);
    AppSettings.avatarLabel.set('${c.name}  ·  ${s.title}');
    Navigator.pop(context);
  }

  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  late Future<List<_Show>> _shows = _popular ??= _loadPopular();

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), () {
        final q = _search.text.trim();
        if (q == _query || !mounted) return;
        setState(() {
          _query = q;
          _shows = q.isEmpty ? (_popular ??= _loadPopular()) : _searchShows(q);
        });
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  static List<_Show> _parse(Map<String, dynamic> json, {bool? tv}) => [
    for (final r in (json['results'] as List).cast<Map<String, dynamic>>())
      if (tv != null || r['media_type'] == 'tv' || r['media_type'] == 'movie')
        _Show(r['id'] as int, (r['name'] ?? r['title'] ?? '') as String, tv ?? r['media_type'] == 'tv'),
  ];

  static Future<List<_Show>> _loadPopular() async {
    final res = await Future.wait([Tmdb.get('/trending/tv/week'), Tmdb.get('/trending/movie/week')]);
    final tv = _parse(res[0], tv: true), movies = _parse(res[1], tv: false);
    // Interleave: two shows, one film.
    final out = <_Show>[];
    for (var i = 0; out.length < 18 && (i < tv.length || i < movies.length); i++) {
      if (i < tv.length) out.add(tv[i]);
      if (i % 2 == 1 && i ~/ 2 < movies.length) out.add(movies[i ~/ 2]);
    }
    return out;
  }

  static Future<List<_Show>> _searchShows(String q) async => _parse(await Tmdb.get('/search/multi', {'query': q, 'include_adult': 'false'})).take(10).toList();

  static Future<List<_Character>> _cast(_Show s) => _casts.putIfAbsent('${s.tv}/${s.id}', () async {
    final json = await Tmdb.get('/${s.tv ? 'tv' : 'movie'}/${s.id}/credits');
    return [
      for (final c in (json['cast'] as List).cast<Map<String, dynamic>>())
        if (c['profile_path'] != null) _Character(_characterName(c), '$_img${c['profile_path']}'),
    ].take(16).toList();
  });

  /// "Wednesday Addams / Narrator" -> "Wednesday Addams"; the actor's name when TMDB has no role.
  static String _characterName(Map<String, dynamic> c) {
    final role = (c['character'] as String? ?? '').split('/').first.trim();
    return role.isEmpty ? c['name'] as String : role;
  }

  void _choose(_Character c, _Show s) {
    AppSettings.avatarUrl.set(c.photo);
    AppSettings.avatarLabel.set('${c.name}  ·  ${s.title}');
    Navigator.pop(context);
  }

  Future<void> _useLink(String url) async {
    setState(() => _saving = true);
    try {
      // signed in: the server checks it first, so a bad link never half-saves
      if (Account.signedIn) await Account.updateProfile({'avatarUrl': url, 'avatarLabel': 'Image link'});
      AppSettings.avatarUrl.set(url);
      AppSettings.avatarLabel.set('Image link');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(
          context,
          Text(Account.describe(e), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          icon: Icons.error_outline_rounded,
        );
      }
    }
  }

  Widget _linkTab() {
    final current = AppSettings.avatarUrl.value ?? '';
    final host = Uri.tryParse(current)?.host ?? '';
    final custom = current.isNotEmpty && host != 'image.tmdb.org' && !host.endsWith('.nflxso.net');
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ImageLinkEditor(circle: true, initial: custom ? current : '', onValid: (v) => setState(() => _link = v)),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                  onPressed: _link == null || _saving ? null : () => _useLink(_link!),
                  child: _saving
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Use this image', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: const Color(0xFF0B0D16),
      insetPadding: EdgeInsets.all(phone ? 12 : 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: VyseColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 820,
        height: size.height * .82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 14, 0),
              child: Row(
                children: [
                  const ProfileAvatar(size: 44),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text('Choose avatar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      AppSettings.avatarUrl.set(null);
                      AppSettings.avatarLabel.set(null);
                    },
                    icon: const Icon(Icons.restart_alt_rounded, size: 18, color: VyseColors.textDim),
                    label: const Text(
                      'Reset',
                      style: TextStyle(color: VyseColors.textDim, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: VyseColors.textDim),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              child: _SourceSwitch(source: _source, onChanged: (v) => setState(() => _source = v)),
            ),
            if (_source == 2)
              Expanded(child: _linkTab())
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                child: VyseSearchField(
                  controller: _search,
                  hint: _netflix ? 'Search Netflix shows or characters…' : 'Search characters or shows…',
                  autofocus: !phone,
                ),
              ),
              if (_netflix)
                Expanded(
                  child: FutureBuilder<List<_NetflixSet>>(
                    future: _netflixAll,
                    builder: (context, snap) {
                      final all = snap.data;
                      if (all == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim));
                      final sets = _filterNetflix(all);
                      if (sets.isEmpty) {
                        return EmptyState(icon: Icons.search_off_rounded, title: 'Nothing found', body: 'No Netflix avatars match "$_query".');
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                        itemCount: sets.length,
                        itemBuilder: (context, i) => _AvatarGroup(
                          key: ValueKey('nf/${sets[i].title}/${sets[i].icons.length}'),
                          title: sets[i].title,
                          icons: sets[i].icons,
                          rounded: 8,
                          onPick: (c) => _chooseNetflix(c, sets[i]),
                        ),
                      );
                    },
                  ),
                )
              else
                Expanded(
                  child: FutureBuilder<List<_Show>>(
                    future: _shows,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return const EmptyState(icon: Icons.wifi_off_rounded, title: "Couldn't load shows", body: 'Check your connection and try again.');
                      }
                      final shows = snap.data;
                      if (shows == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.textDim));
                      if (shows.isEmpty) {
                        return EmptyState(icon: Icons.search_off_rounded, title: 'Nothing found', body: 'No shows match "$_query".');
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                        itemCount: shows.length,
                        itemBuilder: (context, i) => _ShowCast(
                          key: ValueKey('${shows[i].tv}/${shows[i].id}'),
                          show: shows[i],
                          cast: _cast(shows[i]),
                          onPick: (c) => _choose(c, shows[i]),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShowCast extends StatelessWidget {
  const _ShowCast({super.key, required this.show, required this.cast, required this.onPick});
  final _Show show;
  final Future<List<_Character>> cast;
  final ValueChanged<_Character> onPick;

  @override
  Widget build(BuildContext context) {
    final tile = Layout.isPhone(context) ? 74.0 : 86.0;
    return FutureBuilder<List<_Character>>(
      future: cast,
      builder: (context, snap) {
        final list = snap.data;
        if (list != null && list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                show.title,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: VyseColors.textDim),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (list == null)
                    for (var i = 0; i < 8; i++)
                      Shimmer(
                        child: SkeletonBox(width: tile, height: tile, radius: 10),
                      )
                  else
                    for (final c in list)
                      Pressable(
                        tooltip: c.name,
                        onTap: () => onPick(c),
                        builder: (context, hovered, pressed) => AnimatedScale(
                          scale: pressed ? .94 : (hovered ? 1.05 : 1),
                          duration: const Duration(milliseconds: 160),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: tile,
                            height: tile,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: VyseColors.surfaceHi,
                              border: Border.all(color: hovered ? Colors.white : Colors.transparent, width: 2),
                            ),
                            child: CachedNetworkImage(
                              imageUrl: c.photo,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              fadeInDuration: const Duration(milliseconds: 200),
                              errorWidget: (_, _, _) => const Icon(Icons.person_rounded, color: VyseColors.textFaint),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Netflix | TMDB | Link.
class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({required this.source, required this.onChanged});
  final int source;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label, sub, dot) in const [
            (0, 'Netflix', 'Profile icons', Color(0xFFE50914)),
            (1, 'TMDB', 'Cast photos', Color(0xFF01B4E4)),
            (2, 'Link', 'Any image URL', VyseColors.accent),
          ])
            Pressable(
              onTap: () => onChanged(v),
              builder: (context, hovered, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 170),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: source == v ? Colors.white.withValues(alpha: .14) : (hovered ? Colors.white.withValues(alpha: .05) : Colors.transparent),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 7),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                        ),
                        Text(
                          label,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: source == v ? Colors.white : VyseColors.textDim),
                        ),
                      ],
                    ),
                    Text(sub, style: const TextStyle(fontSize: 10.5, color: VyseColors.textFaint)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A titled set of avatar tiles.
class _AvatarGroup extends StatelessWidget {
  const _AvatarGroup({super.key, required this.title, required this.icons, required this.onPick, this.rounded = 10});
  final String title;
  final List<_Character> icons;
  final ValueChanged<_Character> onPick;
  final double rounded;

  @override
  Widget build(BuildContext context) {
    final tile = Layout.isPhone(context) ? 74.0 : 86.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: VyseColors.textDim),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in icons)
                Pressable(
                  tooltip: c.name,
                  onTap: () => onPick(c),
                  builder: (context, hovered, pressed) => AnimatedScale(
                    scale: pressed ? .94 : (hovered ? 1.06 : 1),
                    duration: const Duration(milliseconds: 160),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: tile,
                      height: tile,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(rounded),
                        color: VyseColors.surfaceHi,
                        border: Border.all(color: hovered ? Colors.white : Colors.transparent, width: 2),
                      ),
                      child: CachedNetworkImage(
                        imageUrl: c.photo,
                        fit: BoxFit.cover,
                        memCacheWidth: 220,
                        fadeInDuration: const Duration(milliseconds: 200),
                        errorWidget: (_, _, _) => const Icon(Icons.person_rounded, color: VyseColors.textFaint),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
