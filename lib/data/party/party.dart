import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account.dart';
import '../app_settings.dart';

/// What other people see of an account in Party (the server's `profiles`, never the email).
/// Private accounts come without bio, banner, status line and activity (friends get those), and
/// can't be sent friend requests: only they add people.
class PartyProfile {
  const PartyProfile({
    required this.id,
    required this.username,
    required this.name,
    this.avatarUrl = '',
    this.bannerUrl = '',
    this.bio = '',
    this.customStatus = '',
    this.private = false,
    this.presence = 'offline',
    this.activity,
    this.joined,
    this.lastSeen,
    this.role = '',
    this.group = '',
    this.relation = '',
  });

  final String id; // same as the user's id
  final String username;
  final String name;
  final String avatarUrl;
  final String bannerUrl;
  final String bio;
  final String customStatus;
  final bool private;
  final String presence; // online, idle, dnd, offline
  final Map<String, dynamic>? activity;
  final DateTime? joined;
  final DateTime? lastSeen;
  final String role; // role id, '' for none
  final String group; // member list group: a role id, 'online' or 'offline'

  /// How you two are connected: me, none, friends, outgoing, incoming, blocked ('' unknown).
  final String relation;

  /// Bio, banner, status line and activity are hidden from you.
  bool get hidden => private && relation != 'friends' && relation != 'me' && !isMe;

  bool get isMe => Account.user.value?.id == id;

  factory PartyProfile.fromRecord(RecordModel r) {
    final act = r.data['activity'];
    return PartyProfile(
      id: r.id,
      username: r.getStringValue('username'),
      name: r.getStringValue('name'),
      avatarUrl: r.getStringValue('avatarUrl'),
      bannerUrl: r.getStringValue('bannerUrl'),
      bio: r.getStringValue('bio'),
      customStatus: r.getStringValue('customStatus'),
      private: r.getStringValue('visibility') == 'private',
      presence: r.getStringValue('presence').isEmpty ? 'offline' : r.getStringValue('presence'),
      activity: act is Map<String, dynamic> && act.isNotEmpty ? act : null,
      joined: DateTime.tryParse(r.getStringValue('joined')),
      lastSeen: DateTime.tryParse(r.getStringValue('last_seen')),
    );
  }

  /// A row from the member list endpoint.
  factory PartyProfile.fromJson(Map<String, dynamic> j) {
    final act = j['activity'];
    return PartyProfile(
      id: j['id'] as String? ?? '',
      username: j['username'] as String? ?? '',
      name: j['name'] as String? ?? '',
      avatarUrl: j['avatarUrl'] as String? ?? '',
      customStatus: j['customStatus'] as String? ?? '',
      bannerUrl: j['bannerUrl'] as String? ?? '',
      bio: j['bio'] as String? ?? '',
      joined: DateTime.tryParse(j['joined'] as String? ?? ''),
      relation: j['relation'] as String? ?? '',
      private: j['visibility'] == 'private',
      presence: (j['presence'] as String?)?.isNotEmpty == true ? j['presence'] as String : 'offline',
      activity: act is Map<String, dynamic> && act.isNotEmpty ? act : null,
      lastSeen: DateTime.tryParse(j['last_seen'] as String? ?? ''),
      role: j['role'] as String? ?? '',
      group: j['group'] as String? ?? '',
    );
  }

  /// The signed-in account as others would see it with everything showing (settings preview).
  static PartyProfile? mine() {
    final u = Account.user.value;
    if (u == null) return null;
    return PartyProfile(
      id: u.id,
      username: u.username,
      name: AppSettings.displayName.value,
      avatarUrl: AppSettings.avatarUrl.value ?? '',
      bannerUrl: u.bannerUrl,
      bio: u.bio,
      customStatus: u.customStatus,
      private: u.private,
      presence: u.statusMode == 'invisible' ? 'offline' : (u.statusMode == 'online' && PartyPresence.away ? 'idle' : u.statusMode),
      activity: u.private || u.hideActivity ? null : PartyPresence.activity,
      joined: u.created,
    );
  }
}

/// "Severance · S2E3", "Dune: Part Two".
String activityTitle(Map<String, dynamic> a) {
  final title = a['title'] as String? ?? '';
  if (a['kind'] != 'tv' || a['episode'] == null) return title;
  return '$title · S${a['season'] ?? 1}E${a['episode']}';
}

/// One page of the member list, plus the group counts and who's watching something.
class MemberPage {
  const MemberPage({required this.items, required this.groups, required this.activity, required this.totalPages, required this.total});
  final List<PartyProfile> items;
  final List<MemberGroup> groups;
  final List<PartyProfile> activity;
  final int totalPages;
  final int total;

  int get online => groups.where((g) => g.id != 'offline').fold(0, (n, g) => n + g.count);
}

class MemberGroup {
  const MemberGroup({required this.id, required this.name, required this.count, this.color});
  final String id; // role id, 'online' or 'offline'
  final String name;
  final int count;
  final Color? color; // a role's colour

  static Color? _parse(String? hex) {
    final h = (hex ?? '').replaceAll('#', '');
    final v = int.tryParse(h, radix: 16);
    return v == null || h.length != 6 ? null : Color(0xFF000000 | v);
  }
}

class Party {
  static PocketBase get _pb => Account.pb;

  static bool get joined => Account.user.value?.termsAt != null;

  /// Accepts the Party rules (13+, be decent) for this account.
  static Future<void> acceptTerms() async {
    await _pb.send('/api/vyse/party/terms', method: 'POST');
    await Account.refresh();
  }

  /// One page (50 people) of the member list: online first, grouped by role.
  static Future<MemberPage> members({int page = 1}) async {
    final j = await _pb.send('/api/vyse/members', query: {'page': page}) as Map<String, dynamic>;
    List<Map<String, dynamic>> list(String k) => ((j[k] as List?) ?? const []).cast<Map<String, dynamic>>();
    return MemberPage(
      items: list('items').map(PartyProfile.fromJson).toList(),
      activity: list('activity').map(PartyProfile.fromJson).toList(),
      groups: [
        for (final g in list('groups'))
          MemberGroup(id: g['id'] as String, name: g['name'] as String, count: (g['count'] as num).toInt(), color: MemberGroup._parse(g['color'] as String?)),
      ],
      totalPages: (j['totalPages'] as num?)?.toInt() ?? 1,
      total: (j['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// One profile as you may see it (friends see private details), with your relation.
  static Future<PartyProfile> profile(String id) async =>
      PartyProfile.fromJson(await _pb.send('/api/vyse/social/profile/${Uri.encodeComponent(id)}') as Map<String, dynamic>);

  /// People whose username or display name contains [query].
  static Future<List<PartyProfile>> search(String query) async {
    final q = query.trim().replaceAll('@', '');
    if (q.isEmpty) return const [];
    final res = await _pb.collection('profiles').getList(perPage: 20, filter: _pb.filter('username ~ {:q} || name ~ {:q}', {'q': q}), sort: 'username');
    return res.items.map(PartyProfile.fromRecord).toList();
  }
}

/// Image links people paste for avatars and banners. Other people's images are loaded through
/// wsrv.nl, so the image's host never sees viewers' addresses, and huge files arrive resized.
class ImageLinks {
  static const maxLength = 500;

  /// Null when [url] can be used, otherwise a short reason.
  static String? problem(String url) {
    final u = url.trim();
    if (u.isEmpty) return null;
    if (u.length > maxLength) return 'That link is too long.';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return 'Image links must start with https://';
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || RegExp(r'^[0-9.]+$').hasMatch(host) || host.contains(':') || RegExp(r'\.(local|internal|lan)$').hasMatch(host)) {
      return "That link can't be used.";
    }
    return null;
  }

  /// A warning for links that work now but break later.
  static String? warning(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    if (host.endsWith('discordapp.com') || host.endsWith('discordapp.net') || host.endsWith('discord.com')) {
      return 'Discord links expire after a while. Imgur or another image host lasts.';
    }
    return null;
  }

  /// Where to load [url] from at about [width]×[height] pixels.
  static String sized(String url, {int? width, int? height}) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    // the app's own avatar sources need no proxy
    if (host == 'image.tmdb.org' || host.endsWith('.nflxso.net')) return url;
    return Uri.https('wsrv.nl', '/', {
      'url': url,
      if (width != null) 'w': '$width',
      if (height != null) 'h': '$height',
      if (width != null && height != null) 'fit': 'cover',
      'output': 'webp',
      'n': '-1', // keep GIFs animated
    }).toString();
  }
}

/// Tells the server when you're away (no input for 10 minutes) and what you're watching. Online
/// and offline come from the live connection the app keeps anyway.
class PartyPresence {
  static const _awayAfter = Duration(minutes: 10);
  static bool away = false;
  static Map<String, dynamic>? activity;
  static DateTime _lastInput = DateTime.now();
  static String? _uid;
  static Timer? _timer;

  static void start() {
    if (_timer != null) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute((_) => _input());
    HardwareKeyboard.instance.addHandler((_) {
      _input();
      return false;
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      // watching something isn't being away
      if (!away && activity == null && DateTime.now().difference(_lastInput) > _awayAfter) {
        away = true;
        _send({'afk': true});
      }
    });
    Account.user.addListener(_signedIn);
    _signedIn();
  }

  /// A fresh sign-in or app start: clear whatever an earlier session left behind.
  static void _signedIn() {
    final id = Account.user.value?.id;
    if (id != null && id != _uid) _send({'afk': away, 'activity': activity});
    _uid = id;
  }

  static void _input() {
    _lastInput = DateTime.now();
    if (away) {
      away = false;
      _send({'afk': false});
    }
  }

  /// Playing something (called repeatedly; only changes are sent).
  static void watching({required String title, required bool tv, int? season, int? episode, String? poster, int? tmdbId}) {
    final a = <String, dynamic>{
      'title': title,
      'kind': tv ? 'tv' : 'movie',
      if (tv && season != null) 'season': season,
      if (tv && episode != null) 'episode': episode,
      'poster': ?poster,
      'tmdbId': ?tmdbId,
    };
    if (mapEquals(a, activity)) return;
    activity = a;
    _send({'activity': a});
  }

  static void stopped() {
    if (activity == null) return;
    activity = null;
    _send({'activity': null});
  }

  static void _send(Map<String, dynamic> body) {
    if (!Account.signedIn) return;
    Account.pb.send('/api/vyse/presence', method: 'POST', body: body).catchError((Object _) => null);
  }
}
