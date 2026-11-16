import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account.dart';
import 'party.dart';

/// Your friends, requests both ways, and who you blocked.
class FriendLists {
  const FriendLists({this.friends = const [], this.incoming = const [], this.outgoing = const [], this.blocked = const []});
  final List<PartyProfile> friends; // online first
  final List<PartyProfile> incoming;
  final List<PartyProfile> outgoing;
  final List<PartyProfile> blocked;

  static const empty = FriendLists();

  Set<String> get blockedIds => {for (final b in blocked) b.id};
}

/// Friends and blocks for the signed-in account (once they've joined Party): kept current by
/// live updates on requests and blocks, and a 30 s refresh for friends' status.
class Friends {
  static final lists = ValueNotifier<FriendLists>(FriendLists.empty);
  static final _unsubs = <UnsubscribeFunc>[];
  static String? _uid;
  static Timer? _poll;
  static Timer? _debounce;
  static bool _loading = false;
  static bool _again = false;

  static void start() {
    Account.user.addListener(_userChanged);
    _userChanged();
  }

  static void _userChanged() {
    final u = Account.user.value;
    final id = u != null && u.termsAt != null ? u.id : null;
    if (id == _uid) return;
    _uid = id;
    _stop();
    if (id == null) {
      lists.value = FriendLists.empty;
      return;
    }
    refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    for (final c in ['friendships', 'blocks']) {
      Account.pb.collection(c).subscribe('*', (_) => _soon()).then(_unsubs.add, onError: (Object _) {});
    }
  }

  static void _stop() {
    _poll?.cancel();
    _poll = null;
    for (final u in _unsubs) {
      u().catchError((Object _) {});
    }
    _unsubs.clear();
  }

  static void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), refresh);
  }

  static Future<void> refresh() async {
    if (_uid == null) return;
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      final j = await Account.pb.send('/api/vyse/social/friends') as Map<String, dynamic>;
      List<PartyProfile> list(String k) => ((j[k] as List?) ?? const []).cast<Map<String, dynamic>>().map(PartyProfile.fromJson).toList();
      final friends = list('friends')..sort(_onlineFirst);
      lists.value = FriendLists(friends: friends, incoming: list('incoming'), outgoing: list('outgoing'), blocked: list('blocked'));
    } catch (_) {
      // keep what's showing; the next refresh tries again
    } finally {
      _loading = false;
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    }
  }

  static int _onlineFirst(PartyProfile a, PartyProfile b) {
    final ao = a.presence != 'offline', bo = b.presence != 'offline';
    if (ao != bo) return ao ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Sends a request (or accepts theirs). [user] is an id or a username. Returns the new
  /// relation: "outgoing" or "friends".
  static Future<String> request(String user) => _act('request', user);
  static Future<String> accept(String user) => _act('accept', user);

  /// Declines, cancels or unfriends.
  static Future<String> remove(String user) => _act('remove', user);
  static Future<String> block(String user) => _act('block', user);
  static Future<String> unblock(String user) => _act('unblock', user);

  static Future<String> _act(String what, String user) async {
    final j = await Account.pb.send('/api/vyse/social/$what', method: 'POST', body: {'user': user}) as Map<String, dynamic>;
    await refresh();
    return j['status'] as String? ?? '';
  }
}
