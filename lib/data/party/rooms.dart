import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../account.dart';

class RoomMember {
  const RoomMember({
    required this.id,
    required this.username,
    required this.name,
    this.avatarUrl = '',
    this.presence = 'offline',
    this.owner = false,
    this.silenced = false,
    this.controls = false,
  });
  final String id; // user id
  final String username;
  final String name;
  final String avatarUrl;
  final String presence;
  final bool owner;
  final bool silenced; // the owner muted them for everyone
  final bool controls; // the owner lets them play, pause and seek the watch party

  bool get isMe => Account.user.value?.id == id;

  factory RoomMember.fromJson(Map<String, dynamic> j) => RoomMember(
    id: j['id'] as String? ?? '',
    username: j['username'] as String? ?? '',
    name: j['name'] as String? ?? '',
    avatarUrl: j['avatarUrl'] as String? ?? '',
    presence: j['presence'] as String? ?? 'offline',
    owner: j['role'] == 'owner',
    silenced: j['silenced'] == true,
    controls: j['controls'] == true,
  );
}

/// A room of up to 6: public (listed), or private (join with its invite code). Being in it means
/// being in its voice call and its chat.
class PartyRoom {
  const PartyRoom({
    required this.id,
    required this.name,
    this.topic = '',
    this.private = false,
    this.owner = '',
    this.code = '',
    this.everyoneControls = false,
    this.limit = 6,
    this.watch,
    this.members = const [],
  });
  final String id;
  final String name;
  final String topic;
  final bool private;
  final String owner; // user id
  final String code; // only filled for members of a private room
  final bool everyoneControls; // watch party: anyone can play/pause
  final int limit; // how many people it takes, set by its owner (2 to [capacity])
  final Map<String, dynamic>? watch;
  final List<RoomMember> members;

  static const capacity = 10; // the most a room can take
  int get size => members.length;
  bool get full => size >= limit;
  bool get iOwn => owner == Account.user.value?.id;
  bool get imIn => members.any((m) => m.isMe);

  factory PartyRoom.fromJson(Map<String, dynamic> j) => PartyRoom(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    topic: j['topic'] as String? ?? '',
    private: j['visibility'] == 'private',
    owner: j['owner'] as String? ?? '',
    code: j['code'] as String? ?? '',
    everyoneControls: j['controls'] == 'everyone',
    limit: ((j['limit'] as num?)?.toInt() ?? 6).clamp(2, capacity),
    watch: j['watch'] is Map<String, dynamic> ? j['watch'] as Map<String, dynamic> : null,
    members: [for (final m in ((j['members'] as List?) ?? const []).cast<Map<String, dynamic>>()) RoomMember.fromJson(m)],
  );
}

class RoomMessage {
  const RoomMessage({required this.id, required this.user, required this.name, required this.body, required this.created, this.avatarUrl = ''});
  final String id;
  final String user;
  final String name;
  final String avatarUrl;
  final String body;
  final DateTime created;

  bool get mine => user == Account.user.value?.id;

  factory RoomMessage.fromJson(Map<String, dynamic> j) => RoomMessage(
    id: j['id'] as String? ?? '',
    user: j['user'] as String? ?? '',
    name: j['name'] as String? ?? '',
    avatarUrl: j['avatarUrl'] as String? ?? '',
    body: j['body'] as String? ?? '',
    created: DateTime.tryParse(j['created'] as String? ?? '')?.toLocal() ?? DateTime.now(),
  );

  factory RoomMessage.fromRecord(RecordModel r) => RoomMessage.fromJson({...r.data, 'id': r.id});
}

/// The room you're in (live) and the public rooms (refreshed every 15 s).
class Rooms {
  static final mine = ValueNotifier<PartyRoom?>(null);
  static final public = ValueNotifier<List<PartyRoom>>(const []);

  /// Chat messages arriving in your room.
  static Stream<RoomMessage> get messages => _messages.stream;
  static final _messages = StreamController<RoomMessage>.broadcast();

  static final _unsubs = <UnsubscribeFunc>[];
  static String? _uid;
  static String? _watching; // room id the live updates are for
  static Timer? _poll;
  static Timer? _debounce;

  static PocketBase get _pb => Account.pb;

  /// True while your own join, create or leave is being applied (so it gets its sound, and the
  /// app finding you already in a room as it starts doesn't).
  static bool acting = false;

  static void start() {
    Account.user.addListener(_userChanged);
    _userChanged();
  }

  static void _userChanged() {
    final u = Account.user.value;
    final id = u != null && u.termsAt != null ? u.id : null;
    if (id == _uid) return;
    _uid = id;
    _poll?.cancel();
    _setMine(null);
    public.value = const [];
    if (id == null) return;
    refresh();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
  }

  static Future<void> refresh() async {
    if (_uid == null) return;
    try {
      final j = await _pb.send('/api/vyse/rooms') as Map<String, dynamic>;
      public.value = [for (final r in ((j['rooms'] as List?) ?? const []).cast<Map<String, dynamic>>()) PartyRoom.fromJson(r)];
      _setMine(j['mine'] is Map<String, dynamic> ? PartyRoom.fromJson(j['mine'] as Map<String, dynamic>) : null);
    } catch (_) {}
  }

  static void _setMine(PartyRoom? room) {
    mine.value = room;
    if (room?.id == _watching) return;
    for (final u in _unsubs) {
      u().catchError((Object _) {});
    }
    _unsubs.clear();
    _watching = room?.id;
    if (room == null) return;
    final id = room.id;
    // who's in it, its settings, and its chat, live
    _pb.collection('room_members').subscribe('*', (_) => _soon(), filter: 'room = "$id"').then(_unsubs.add, onError: (Object _) {});
    _pb.collection('rooms').subscribe(id, (e) => e.action == 'delete' ? _setMine(null) : _soon()).then(_unsubs.add, onError: (Object _) {});
    _pb
        .collection('room_messages')
        .subscribe('*', (e) {
          if (e.action == 'create' && e.record != null) _messages.add(RoomMessage.fromRecord(e.record!));
        }, filter: 'room = "$id"')
        .then(_unsubs.add, onError: (Object _) {});
  }

  static void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), refresh);
  }

  static Future<PartyRoom?> _room(String path, Map<String, dynamic> body) async {
    final j = await _pb.send('/api/vyse/rooms/$path', method: 'POST', body: body);
    final room = j is Map<String, dynamic> ? PartyRoom.fromJson(j) : null;
    acting = true;
    try {
      _setMine(room != null && room.imIn ? room : null);
    } finally {
      acting = false;
    }
    unawaited(refresh());
    return room;
  }

  /// Makes a room and puts you in it (you leave the one you're in).
  static Future<PartyRoom?> create({required String name, String topic = '', bool private = false, int limit = 6}) =>
      _room('create', {'name': name, 'topic': topic, 'visibility': private ? 'private' : 'public', 'limit': limit});

  static Future<PartyRoom?> join(String roomId) => _room('join', {'room': roomId});
  static Future<PartyRoom?> joinCode(String code) => _room('join', {'code': code.trim().toUpperCase()});

  static Future<void> leave() async {
    await _pb.send('/api/vyse/rooms/leave', method: 'POST');
    _setMine(null);
    unawaited(refresh());
  }

  /// Owner only: name, topic, visibility ("public"/"private"), newCode, kick, owner, mute/unmute,
  /// allow/disallow (watch party playback control), limit (how many people, 2 to 10).
  static Future<PartyRoom?> manage(Map<String, dynamic> body) => _room('manage', body);

  static Future<RoomMessage> send(String body) async =>
      RoomMessage.fromJson(await _pb.send('/api/vyse/rooms/message', method: 'POST', body: {'body': body}) as Map<String, dynamic>);

  /// The room's chat, oldest first (the last 100).
  static Future<List<RoomMessage>> history(String roomId) async {
    final res = await _pb.collection('room_messages').getList(perPage: 100, filter: _pb.filter('room = {:r}', {'r': roomId}), sort: '-created');
    return res.items.map(RoomMessage.fromRecord).toList().reversed.toList();
  }
}
