import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';

/// One kind of data the account keeps in step with this device.
class SyncSource {
  const SyncSource({
    required this.kind,
    required this.snapshot,
    required this.apply,
    required this.changes,
    this.timeOf,
    this.remoteWinsFirst = false,
    this.applyAll,
  });

  /// Lorewatch: puts many items on the device at once (null removes), when that's much cheaper
  /// than one [apply] each.
  final Future<void> Function(Map<String, Map<String, dynamic>?> items)? applyAll;

  /// "progress", "mylist", "settings", …
  final String kind;

  /// Everything of this kind on the device, by key.
  final Future<Map<String, Map<String, dynamic>>> Function() snapshot;

  /// Puts the account's version on the device (null removes it).
  final Future<void> Function(String key, Map<String, dynamic>? data) apply;

  /// Fires whenever this kind changes on the device.
  final Listenable changes;

  /// When the item itself says it last changed (ms), if it knows.
  final int? Function(Map<String, dynamic> data)? timeOf;

  /// On the very first sync with an account, the account's copy beats the device's (settings).
  final bool remoteWinsFirst;
}

class _Known {
  const _Known(this.hash, this.time, this.deleted);
  final int hash;
  final int time;
  final bool deleted;

  List<Object> toJson() => [hash, time, if (deleted) 1];
  static _Known fromJson(List<dynamic> j) => _Known(j[0] as int, j[1] as int, j.length > 2);
}

class _Remote {
  const _Remote(this.id, this.data, this.time, this.deleted);
  final String id;
  final Map<String, dynamic> data;
  final int time;
  final bool deleted;

  static _Remote of(RecordModel r) => _Remote(
    r.id,
    Map<String, dynamic>.from((r.data['data'] as Map?) ?? const {}),
    r.getIntValue('updated_ms'),
    r.getBoolValue('deleted'),
  );
}

/// Keeps the signed-in account and this device identical, both ways, as things happen.
///
/// Every item has a "last changed" time; the newer side wins. Signing in (and starting the app
/// signed in) merges everything: device-only items go up, account-only items come down.
/// After that, every change is pushed at once and other devices' changes arrive live.
/// Removing something leaves a `deleted` row so it's removed everywhere, not brought back.
class AccountSync {
  static final _sources = <String, SyncSource>{};
  static final status = ValueNotifier<String>('');
  static String? _user;
  static Map<String, Map<String, _Known>> _known = {};
  static final _ids = <String, String>{}; // "kind/key" -> record id
  static UnsubscribeFunc? _unsub;
  static final _timers = <String, Timer>{};
  static Future<void>? _merging;
  static SharedPreferences? _prefs;

  static RecordService get _col => Account.pb.collection('user_items');

  static Future<void> initialize(List<SyncSource> sources) async {
    _prefs = await SharedPreferences.getInstance();
    for (final s in sources) {
      _sources[s.kind] = s;
      s.changes.addListener(() => _onLocal(s.kind));
    }
    Account.user.addListener(_onAccount);
    _onAccount();
  }

  static void _onAccount() {
    final id = Account.user.value?.id;
    if (id == _user) return;
    _stop();
    _user = id;
    if (id == null) {
      status.value = '';
      return;
    }
    _known = _loadKnown(id);
    _merging = _merge().whenComplete(() => _merging = null);
  }

  static void _stop() {
    _unsub?.call();
    _unsub = null;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _ids.clear();
  }

  // ── what's known to be on the account, per user ──

  static Map<String, Map<String, _Known>> _loadKnown(String user) {
    try {
      final raw = _prefs?.getString('sync.known.$user');
      if (raw == null) return {};
      return {
        for (final k in (json.decode(raw) as Map<String, dynamic>).entries)
          k.key: {for (final e in (k.value as Map<String, dynamic>).entries) e.key: _Known.fromJson(e.value as List)},
      };
    } catch (_) {
      return {};
    }
  }

  static Timer? _saveKnownTimer;
  static void _saveKnown() {
    final user = _user;
    if (user == null) return;
    _saveKnownTimer?.cancel();
    _saveKnownTimer = Timer(const Duration(milliseconds: 500), () {
      _prefs?.setString(
        'sync.known.$user',
        json.encode({for (final k in _known.entries) k.key: {for (final e in k.value.entries) e.key: e.value.toJson()}}),
      );
    });
  }

  // ── the full merge ──

  static Future<void> _merge() async {
    final user = _user;
    if (user == null) return;
    status.value = 'Syncing…';
    try {
      final rows = await _col.getFullList(batch: 500);
      if (_user != user) return;
      final remote = <String, Map<String, _Remote>>{};
      for (final r in rows) {
        final kind = r.getStringValue('kind'), key = r.getStringValue('key');
        _ids['$kind/$key'] = r.id;
        (remote[kind] ??= {})[key] = _Remote.of(r);
      }

      final ups = <(String, String, Map<String, dynamic>?, int)>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final src in _sources.values) {
        final local = await src.snapshot();
        final known = _known[src.kind] ??= {};
        final first = known.isEmpty;
        final theirs = remote[src.kind] ?? const {};
        for (final key in {...local.keys, ...known.keys, ...theirs.keys}) {
          final l = local[key], k = known[key], r = theirs[key];
          // when the device's copy last changed
          int? tL;
          var goneHere = false;
          if (l != null) {
            final h = _hash(l);
            tL = src.timeOf?.call(l) ?? (k != null && !k.deleted && k.hash == h ? k.time : (first && src.remoteWinsFirst ? 0 : now));
          } else if (k != null) {
            goneHere = true;
            tL = k.deleted ? k.time : now;
          }

          if (r == null) {
            if (l != null) {
              ups.add((src.kind, key, l, tL!));
            } else if (goneHere) {
              known[key] = _Known(0, tL!, true);
            }
            continue;
          }
          if (l == null && !goneHere) {
            await _applyRemote(src, key, r);
            continue;
          }
          if (tL! > r.time) {
            ups.add((src.kind, key, goneHere ? null : l, tL));
          } else if (r.time > tL || (l != null && _hash(l) != _hash(r.data))) {
            await _applyRemote(src, key, r);
          } else {
            known[key] = _Known(goneHere ? 0 : _hash(l!), tL, goneHere);
          }
        }
      }
      await _pushMany(ups);
      _saveKnown();
      if (_user != user) return;
      await _subscribe();
      status.value = 'Synced';
    } catch (e) {
      if (_user == user) status.value = _offline(e) ? 'Offline · will sync when back' : 'Sync paused';
    }
  }

  static bool _offline(Object e) => e is ClientException && e.statusCode == 0;

  static Future<void> _applyRemote(SyncSource src, String key, _Remote r) async {
    final known = _known[src.kind] ??= {};
    // record it first, so the change this causes isn't sent straight back
    known[key] = _Known(r.deleted ? 0 : _hash(r.data), r.time, r.deleted);
    try {
      await src.apply(key, r.deleted ? null : r.data);
    } catch (_) {}
    _saveKnown();
  }

  // ── live updates from other devices ──

  static Future<void> _subscribe() async {
    _unsub?.call();
    _unsub = await _col.subscribe('*', (e) {
      final r = e.record;
      if (r == null || _user == null) return;
      final kind = r.getStringValue('kind'), key = r.getStringValue('key');
      final src = _sources[kind];
      if (src == null) return;
      if (e.action == 'delete') {
        _ids.remove('$kind/$key');
        return;
      }
      _ids['$kind/$key'] = r.id;
      final remote = _Remote.of(r);
      final k = _known[kind]?[key];
      final same = k != null && k.deleted == remote.deleted && (remote.deleted || k.hash == _hash(remote.data));
      if (same) return; // our own change coming back
      if (k != null && remote.time < k.time) return; // older than what we have
      _applyRemote(src, key, remote);
    });
  }

  // ── changes made on this device ──

  static void _onLocal(String kind) {
    if (_user == null) return;
    _timers[kind]?.cancel();
    _timers[kind] = Timer(const Duration(milliseconds: 300), () => _pushChanges(kind));
  }

  static Future<void> _pushChanges(String kind) async {
    await _merging; // never race the full merge
    final src = _sources[kind];
    if (src == null || _user == null) return;
    final local = await src.snapshot();
    final known = _known[kind] ??= {};
    final now = DateTime.now().millisecondsSinceEpoch;
    final ups = <(String, String, Map<String, dynamic>?, int)>[];
    local.forEach((key, data) {
      final k = known[key];
      if (k == null || k.deleted || k.hash != _hash(data)) ups.add((kind, key, data, src.timeOf?.call(data) ?? now));
    });
    for (final e in known.entries) {
      if (!e.value.deleted && !local.containsKey(e.key)) ups.add((kind, e.key, null, now));
    }
    if (ups.isEmpty) return;
    try {
      await _pushMany(ups);
      _saveKnown();
      status.value = 'Synced';
    } catch (e) {
      status.value = _offline(e) ? 'Offline · will sync when back' : 'Sync paused';
    }
  }

  /// Creates or updates the account's row for each item (deleted = data null).
  static Future<void> _pushMany(List<(String, String, Map<String, dynamic>?, int)> ups) async {
    final user = _user;
    if (user == null || ups.isEmpty) return;
    Map<String, dynamic> body(String kind, String key, Map<String, dynamic>? data, int t) => {
      'user': user,
      'kind': kind,
      'key': key,
      'data': data ?? const {},
      'updated_ms': t,
      'deleted': data == null,
    };

    void remember(String kind, String key, Map<String, dynamic>? data, int t) {
      (_known[kind] ??= {})[key] = _Known(data == null ? 0 : _hash(data), t, data == null);
    }

    // Many at once (the first sync): batches of 100.
    if (ups.length > 3) {
      for (var i = 0; i < ups.length; i += 100) {
        final chunk = ups.skip(i).take(100).toList();
        final batch = Account.pb.createBatch();
        for (final (kind, key, data, t) in chunk) {
          final id = _ids['$kind/$key'];
          if (id != null) {
            batch.collection('user_items').update(id, body: body(kind, key, data, t));
          } else {
            batch.collection('user_items').create(body: body(kind, key, data, t));
          }
        }
        try {
          final results = await batch.send();
          for (var j = 0; j < chunk.length && j < results.length; j++) {
            final (kind, key, data, t) = chunk[j];
            final b = results[j].body;
            if (b is Map && b['id'] is String) _ids['$kind/$key'] = b['id'] as String;
            remember(kind, key, data, t);
          }
        } on ClientException catch (e) {
          if (_offline(e)) rethrow;
          // a row may already exist (another device); fall back to one at a time
          for (final (kind, key, data, t) in chunk) {
            await _pushOne(body(kind, key, data, t), kind, key);
            remember(kind, key, data, t);
          }
        }
      }
      return;
    }
    for (final (kind, key, data, t) in ups) {
      await _pushOne(body(kind, key, data, t), kind, key);
      remember(kind, key, data, t);
    }
  }

  static Future<void> _pushOne(Map<String, dynamic> body, String kind, String key) async {
    final id = _ids['$kind/$key'];
    try {
      final rec = id != null ? await _col.update(id, body: body) : await _col.create(body: body);
      _ids['$kind/$key'] = rec.id;
    } on ClientException catch (e) {
      if (_offline(e)) rethrow;
      // already there (made elsewhere) or gone: find the row by its key and update it
      final existing = await _col
          .getFirstListItem(Account.pb.filter('kind = {:k} && key = {:key}', {'k': kind, 'key': key}))
          .then<RecordModel?>((r) => r, onError: (Object _) => null);
      final rec = existing != null ? await _col.update(existing.id, body: body) : await _col.create(body: body);
      _ids['$kind/$key'] = rec.id;
    }
  }

  // ── stable fingerprint of an item (key order doesn't matter) ──

  static int _hash(Map<String, dynamic> data) {
    final s = json.encode(_canon(data));
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  static Object? _canon(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _canon(v[k])};
    }
    if (v is List) return v.map(_canon).toList();
    if (v is double && v == v.roundToDouble() && v.abs() < 1e15) return v.toInt();
    return v;
  }
}
