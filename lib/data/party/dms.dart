import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account.dart';
import 'friends.dart';
import 'party.dart';

/// Messages last a day.
const dmLifetime = Duration(hours: 24);

String dmPair(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';

class DmMessage {
  const DmMessage({required this.id, required this.sender, required this.receiver, required this.body, required this.created, this.readAt});
  final String id;
  final String sender;
  final String receiver;
  final String body;
  final DateTime created;
  final DateTime? readAt;

  bool get mine => sender == Account.user.value?.id;
  String get partner => mine ? receiver : sender;
  bool get expired => DateTime.now().difference(created) > dmLifetime;

  factory DmMessage.fromJson(Map<String, dynamic> j) => DmMessage(
    id: j['id'] as String? ?? '',
    sender: j['sender'] as String? ?? '',
    receiver: j['receiver'] as String? ?? '',
    body: j['body'] as String? ?? '',
    created: DateTime.tryParse(j['created'] as String? ?? '')?.toLocal() ?? DateTime.now(),
    readAt: DateTime.tryParse(j['readAt'] as String? ?? '')?.toLocal(),
  );

  factory DmMessage.fromRecord(RecordModel r) => DmMessage.fromJson({...r.data, 'id': r.id});
}

/// A conversation. It stays in the list; its messages are deleted 24 hours after they're sent.
class DmThread {
  const DmThread({required this.partner, required this.last, required this.unread, this.lastAt});
  final PartyProfile partner;
  final DmMessage? last; // null once every message has expired
  final int unread;
  final DateTime? lastAt; // when the newest message was sent, even if it's gone

  DmThread copyWith({DmMessage? last, bool clearLast = false, int? unread}) =>
      DmThread(partner: partner, last: clearLast ? null : (last ?? this.last), unread: unread ?? this.unread, lastAt: last?.created ?? lastAt);
}

/// DMs for the signed-in account: the conversation list, live new messages, "seen" and typing.
class Dms {
  static final threads = ValueNotifier<List<DmThread>>(const []);

  /// Partner id → when their "typing…" stops showing.
  static final typing = ValueNotifier<Map<String, DateTime>>(const {});

  /// Unread DMs plus incoming friend requests: the dot on the Party tab.
  static final badge = ValueNotifier<int>(0);

  /// Every new, changed (seen) or removed message, as (action, message).
  static Stream<(String, DmMessage)> get events => _events.stream;
  static final _events = StreamController<(String, DmMessage)>.broadcast();

  /// The partner whose conversation is open (their messages arrive read).
  static String? openWith;

  static final _unsubs = <UnsubscribeFunc>[];
  static String? _uid;
  static Timer? _tick;
  static final _typingSent = <String, DateTime>{};

  static void start() {
    Account.user.addListener(_userChanged);
    Friends.lists.addListener(_updateBadge);
    _userChanged();
  }

  static void _userChanged() {
    final u = Account.user.value;
    final id = u != null && u.termsAt != null ? u.id : null;
    if (id == _uid) return;
    _uid = id;
    for (final u in _unsubs) {
      u().catchError((Object _) {});
    }
    _unsubs.clear();
    _tick?.cancel();
    threads.value = const [];
    typing.value = const {};
    _updateBadge();
    if (id == null) return;
    refresh();
    Account.pb
        .collection('dm_messages')
        .subscribe('*', (e) {
          final r = e.record;
          if (r != null) _apply(e.action, DmMessage.fromRecord(r));
        })
        .then(_unsubs.add, onError: (Object _) {});
    Account.pb.realtime
        .subscribe('vyse_typing', (e) {
          try {
            final from = (jsonDecode(e.data) as Map<String, dynamic>)['from'] as String;
            typing.value = {...typing.value, from: DateTime.now().add(const Duration(seconds: 6))};
          } catch (_) {}
        })
        .then(_unsubs.add, onError: (Object _) {});
    // typing fades; day-old conversations drop off
    _tick = Timer.periodic(const Duration(seconds: 2), (t) {
      final now = DateTime.now();
      if (typing.value.values.any((until) => until.isBefore(now))) {
        typing.value = {
          for (final e in typing.value.entries)
            if (e.value.isAfter(now)) e.key: e.value,
        };
      }
      // expired messages leave; the conversation stays
      if (t.tick % 30 == 0 && threads.value.any((th) => th.last?.expired ?? false)) {
        threads.value = [for (final th in threads.value) (th.last?.expired ?? false) ? th.copyWith(clearLast: true, unread: 0) : th];
        _updateBadge();
      }
    });
  }

  static void _updateBadge() => badge.value = threads.value.fold<int>(0, (n, t) => n + t.unread) + Friends.lists.value.incoming.length;

  static void _apply(String action, DmMessage m) {
    _events.add((action, m));
    final list = [...threads.value];
    final i = list.indexWhere((t) => t.partner.id == m.partner);
    switch (action) {
      case 'create':
        if (!m.mine) typing.value = {...typing.value}..remove(m.sender);
        if (i < 0) {
          refresh(); // a new conversation: fetch who it's with
          return;
        }
        final open = openWith == m.partner;
        final t = list.removeAt(i);
        list.insert(0, t.copyWith(last: m, unread: m.mine || open ? 0 : t.unread + 1));
        if (open && !m.mine) markRead(m.partner);
      case 'update':
        if (i >= 0 && list[i].last?.id == m.id) list[i] = list[i].copyWith(last: m);
      case 'delete':
        if (i >= 0 && list[i].last?.id == m.id) {
          refresh();
          return;
        }
    }
    threads.value = list;
    _updateBadge();
  }

  static Future<void> refresh() async {
    if (_uid == null) return;
    try {
      final j = await Account.pb.send('/api/vyse/dm/threads') as Map<String, dynamic>;
      threads.value = [
        for (final t in ((j['threads'] as List?) ?? const []).cast<Map<String, dynamic>>())
          DmThread(
            partner: PartyProfile.fromJson(t['partner'] as Map<String, dynamic>),
            last: t['last'] is Map<String, dynamic> ? DmMessage.fromJson(t['last'] as Map<String, dynamic>) : null,
            unread: (t['unread'] as num?)?.toInt() ?? 0,
            lastAt: DateTime.tryParse(t['lastAt'] as String? ?? '')?.toLocal(),
          ),
      ];
      _updateBadge();
    } catch (_) {}
  }

  /// The conversation with [partner], newest first, 50 at a time (older than [before]).
  static Future<List<DmMessage>> history(String partner, {DateTime? before}) async {
    final me = Account.user.value?.id;
    if (me == null) return const [];
    final cut = DateTime.now().toUtc().subtract(dmLifetime).toIso8601String().replaceFirst('T', ' ');
    final pb = Account.pb;
    final filter = before == null
        ? pb.filter('pair = {:p} && created > {:cut}', {'p': dmPair(me, partner), 'cut': cut})
        : pb.filter('pair = {:p} && created > {:cut} && created < {:before}', {
            'p': dmPair(me, partner),
            'cut': cut,
            'before': before.toUtc().toIso8601String().replaceFirst('T', ' '),
          });
    final res = await pb.collection('dm_messages').getList(perPage: 50, filter: filter, sort: '-created');
    return res.items.map(DmMessage.fromRecord).toList();
  }

  static Future<DmMessage> send(String to, String body) async {
    final j = await Account.pb.send('/api/vyse/dm/send', method: 'POST', body: {'to': to, 'body': body}) as Map<String, dynamic>;
    return DmMessage.fromJson(j);
  }

  static Future<void> markRead(String partner) async {
    final i = threads.value.indexWhere((t) => t.partner.id == partner);
    if (i >= 0 && threads.value[i].unread > 0) {
      threads.value = [...threads.value]..[i] = threads.value[i].copyWith(unread: 0);
      _updateBadge();
    }
    try {
      await Account.pb.send('/api/vyse/dm/read', method: 'POST', body: {'with': partner});
    } catch (_) {}
  }

  /// "typing…" for [partner], at most every 2.5 s.
  static void typingTo(String partner) {
    final now = DateTime.now();
    final last = _typingSent[partner];
    if (last != null && now.difference(last) < const Duration(milliseconds: 2500)) return;
    _typingSent[partner] = now;
    Account.pb.send('/api/vyse/dm/typing', method: 'POST', body: {'to': partner}).catchError((Object _) => null);
  }

  /// Takes back one of your messages, for both of you.
  static Future<void> unsend(String id) => Account.pb.collection('dm_messages').delete(id);
}
