import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'account_sync.dart';

/// Lorewatch: keeps phone, tablet and every other device in step through one private GitHub Gist
/// on the user's own account (no server of ours). The Gist holds every item of every kind with
/// the time it last changed; each device merges it with what it has (the newer side wins), then
/// writes back what it changed. Removing something leaves a marker so it's removed everywhere.
///
/// The same file, saved by hand, is the backup: [exportBackup] / [importBackup].
abstract final class GistSync {
  static const fileName = 'lorewatch-sync.json';
  static const _api = 'https://api.github.com';
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static const _tokenKey = 'lw.gist.token', _idKey = 'lw.gist.id', _knownKey = 'lw.gist.known', _lastKey = 'lw.gist.last';

  static final _sources = <String, SyncSource>{};
  static SharedPreferences? _prefs;

  /// Connected to a Gist on this device.
  static final connected = ValueNotifier<bool>(false);

  /// What's happening, for Settings.
  static final status = ValueNotifier<String>('');

  /// When the last sync finished.
  static final lastSync = ValueNotifier<DateTime?>(null);

  static String? _token, _gistId;
  static Map<String, Map<String, _Known>> _known = {};
  static bool _applying = false, _busy = false, _again = false, _dirty = false;
  static Timer? _debounce, _periodic;

  static Future<void> initialize(List<SyncSource> sources) async {
    _prefs = await SharedPreferences.getInstance();
    for (final s in sources) {
      _sources[s.kind] = s;
      s.changes.addListener(_onLocal);
    }
    final last = _prefs!.getInt(_lastKey);
    if (last != null) lastSync.value = DateTime.fromMillisecondsSinceEpoch(last);
    try {
      _token = await _storage.read(key: _tokenKey);
    } catch (_) {}
    _gistId = _prefs!.getString(_idKey);
    _known = _loadKnown();
    WidgetsBinding.instance.addObserver(_Lifecycle());
    if (_token != null && _gistId != null) {
      connected.value = true;
      _startTimers();
      // after AniList has brought its changes in
      Timer(const Duration(seconds: 20), sync);
    }
  }

  static void _startTimers() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => sync());
  }

  // ── connecting ──

  /// Checks [token], finds the Lorewatch Gist on that account (or makes a private one), and syncs.
  /// Returns an error message, or null when it worked.
  static Future<String?> connect(String token) async {
    token = token.trim();
    if (token.isEmpty) return 'Incolla il token.';
    try {
      final me = await http.get(Uri.parse('$_api/user'), headers: _headers(token));
      if (me.statusCode == 401) return 'Token non valido o scaduto.';
      if (me.statusCode != 200) return 'GitHub ha risposto ${me.statusCode}.';
      final scopes = me.headers['x-oauth-scopes'];
      if (scopes != null && scopes.isNotEmpty && !scopes.split(',').map((s) => s.trim()).contains('gist')) {
        return 'Al token manca il permesso "gist".';
      }
      String? id;
      for (var page = 1; page <= 10 && id == null; page++) {
        final r = await http.get(Uri.parse('$_api/gists?per_page=100&page=$page'), headers: _headers(token));
        if (r.statusCode == 403 || r.statusCode == 404) return 'Al token manca il permesso "gist".';
        if (r.statusCode != 200) return 'GitHub ha risposto ${r.statusCode}.';
        final list = (json.decode(r.body) as List).cast<Map<String, dynamic>>();
        for (final g in list) {
          if ((g['files'] as Map?)?.containsKey(fileName) ?? false) {
            id = g['id'] as String;
            break;
          }
        }
        if (list.length < 100) break;
      }
      if (id == null) {
        final r = await http.post(
          Uri.parse('$_api/gists'),
          headers: _headers(token),
          body: json.encode({
            'description': 'Lorewatch · sincronizzazione tra dispositivi',
            'public': false,
            'files': {
              fileName: {'content': _encode({})},
            },
          }),
        );
        if (r.statusCode != 201) return 'Non riesco a creare il Gist (${r.statusCode}).';
        id = (json.decode(r.body) as Map)['id'] as String;
      }
      _token = token;
      _gistId = id;
      await _storage.write(key: _tokenKey, value: token);
      await _prefs?.setString(_idKey, id);
      _known = {};
      _saveKnown();
      connected.value = true;
      _startTimers();
      await sync();
      return null;
    } catch (e) {
      return 'Connessione non riuscita: controlla la rete.';
    }
  }

  static Future<void> disconnect() async {
    _periodic?.cancel();
    _debounce?.cancel();
    _token = null;
    _gistId = null;
    _known = {};
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
    await _prefs?.remove(_idKey);
    await _prefs?.remove(_knownKey);
    await _prefs?.remove(_lastKey);
    connected.value = false;
    lastSync.value = null;
    status.value = '';
  }

  // ── syncing ──

  static void _onLocal() {
    if (_applying || !connected.value) return;
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 10), sync);
  }

  static void _onLifecycle(AppLifecycleState s) {
    if (!connected.value) return;
    if (s == AppLifecycleState.resumed) {
      final last = lastSync.value;
      if (last == null || DateTime.now().difference(last) > const Duration(seconds: 30)) sync();
    } else if ((s == AppLifecycleState.paused || s == AppLifecycleState.hidden) && _dirty) {
      _debounce?.cancel();
      sync();
    }
  }

  /// Brings the Gist in, merges, and writes back what changed here.
  static Future<void> sync() async {
    final token = _token, id = _gistId;
    if (token == null || id == null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    _dirty = false;
    status.value = 'Sincronizzazione…';
    try {
      final r = await http.get(Uri.parse('$_api/gists/$id'), headers: _headers(token));
      if (r.statusCode == 404) {
        status.value = 'Gist non trovato: ricollega';
        return;
      }
      if (r.statusCode == 401) {
        status.value = 'Token non più valido: ricollega';
        return;
      }
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      final file = ((json.decode(r.body) as Map)['files'] as Map?)?[fileName] as Map?;
      var content = file?['content'] as String? ?? '';
      if (file?['truncated'] == true && file?['raw_url'] is String) {
        final raw = await http.get(Uri.parse(file!['raw_url'] as String), headers: {'Authorization': 'Bearer $token'});
        if (raw.statusCode != 200) throw 'HTTP ${raw.statusCode}';
        content = utf8.decode(raw.bodyBytes);
      }
      final remote = _decode(content);
      final changed = await _merge(remote, _known);
      _saveKnown();
      if (changed) {
        final w = await http.patch(
          Uri.parse('$_api/gists/$id'),
          headers: _headers(token),
          body: json.encode({
            'files': {
              fileName: {'content': _encode(remote)},
            },
          }),
        );
        if (w.statusCode != 200) throw 'HTTP ${w.statusCode}';
      }
      final now = DateTime.now();
      lastSync.value = now;
      await _prefs?.setInt(_lastKey, now.millisecondsSinceEpoch);
      status.value = 'Sincronizzato';
    } catch (e) {
      debugPrint('[GistSync] $e');
      status.value = 'Non sincronizzato · riprovo più tardi';
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(sync());
      }
    }
  }

  /// Merges [remote] (kind → key → [time, data or null]) with this device, using [known] (what
  /// was there last time). Brings newer remote items in and puts newer local ones into [remote].
  /// True when [remote] changed.
  static Future<bool> _merge(Map<String, Map<String, List<dynamic>>> remote, Map<String, Map<String, _Known>> known) async {
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final src in _sources.values) {
      final local = await src.snapshot();
      final kn = known[src.kind] ??= {};
      final theirs = remote[src.kind] ??= {};
      final toApply = <String, Map<String, dynamic>?>{};
      final times = <String, int>{};
      for (final key in {...local.keys, ...kn.keys, ...theirs.keys}) {
        final l = local[key], k = kn[key], r = theirs[key];
        int tL;
        var goneHere = false;
        if (l != null) {
          final h = _hash(l);
          if (k != null && !k.deleted && k.hash == h) {
            tL = k.time;
          } else if (k == null) {
            tL = src.timeOf?.call(l) ?? (src.remoteWinsFirst ? 0 : now);
          } else {
            tL = now;
          }
        } else if (k != null) {
          goneHere = true;
          tL = k.deleted ? k.time : now;
        } else {
          tL = 0;
        }

        if (r == null) {
          if (l != null) {
            theirs[key] = [tL, l];
            kn[key] = _Known(_hash(l), tL, false);
            changed = true;
          } else if (goneHere && !k!.deleted) {
            theirs[key] = [tL, null];
            kn[key] = _Known(0, tL, true);
            changed = true;
          }
          continue;
        }
        final rt = (r[0] as num).toInt();
        final rd = r.length > 1 && r[1] is Map ? Map<String, dynamic>.from(r[1] as Map) : null;
        if (l == null && !goneHere) {
          if (rd != null) {
            toApply[key] = rd;
            times[key] = rt;
          }
          kn[key] = _Known(rd == null ? 0 : _hash(rd), rt, rd == null);
          continue;
        }
        if (tL > rt) {
          theirs[key] = [tL, goneHere ? null : l];
          kn[key] = _Known(goneHere ? 0 : _hash(l!), tL, goneHere);
          changed = true;
        } else if (rt > tL || (l != null && (rd == null || _hash(l) != _hash(rd)))) {
          if (rd != null || l != null) toApply[key] = rd;
          times[key] = rt;
          kn[key] = _Known(rd == null ? 0 : _hash(rd), rt, rd == null);
        } else {
          kn[key] = _Known(goneHere ? 0 : _hash(l!), tL, goneHere);
        }
      }
      if (toApply.isEmpty) continue;
      _applying = true;
      try {
        if (src.applyAll != null) {
          await src.applyAll!(toApply);
        } else {
          for (final e in toApply.entries) {
            try {
              await src.apply(e.key, e.value);
            } catch (_) {}
          }
        }
      } catch (e) {
        debugPrint('[GistSync] apply ${src.kind}: $e');
      } finally {
        _applying = false;
      }
      // what the device keeps may differ slightly from what came in (rounding, defaults):
      // remember that, so it isn't taken for a change made here
      final after = await src.snapshot();
      for (final e in times.entries) {
        final a = after[e.key];
        if (a != null) kn[e.key] = _Known(_hash(a), e.value, false);
      }
    }
    return changed;
  }

  // ── backup by hand ──

  /// Everything, in the Gist's format, ready to save as a file.
  static Future<Uint8List> exportBackup() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final doc = <String, Map<String, List<dynamic>>>{};
    for (final src in _sources.values) {
      final local = await src.snapshot();
      final kn = _known[src.kind] ?? const {};
      doc[src.kind] = {
        for (final e in local.entries)
          e.key: [
            kn[e.key] != null && !kn[e.key]!.deleted && kn[e.key]!.hash == _hash(e.value) ? kn[e.key]!.time : (src.timeOf?.call(e.value) ?? now),
            e.value,
          ],
      };
    }
    return Uint8List.fromList(utf8.encode(_encode(doc)));
  }

  /// Merges a file made by [exportBackup] into this device. Returns how many items came in,
  /// or null when the file isn't a Lorewatch backup.
  static Future<int?> importBackup(List<int> bytes) async {
    final Map<String, Map<String, List<dynamic>>> doc;
    try {
      final text = utf8.decode(bytes);
      if (!text.contains('lorewatch-sync')) return null;
      doc = _decode(text);
    } catch (_) {
      return null;
    }
    var count = 0;
    for (final kind in doc.keys) {
      count += doc[kind]!.length;
    }
    await _merge(doc, {});
    if (connected.value) {
      _dirty = true;
      unawaited(sync());
    }
    return count;
  }

  // ── the file ──

  static String _encode(Map<String, Map<String, List<dynamic>>> doc) => json.encode({
    'format': 'lorewatch-sync',
    'v': 1,
    'gz': base64.encode(gzip.encode(utf8.encode(json.encode(doc)))),
  });

  static Map<String, Map<String, List<dynamic>>> _decode(String content) {
    if (content.trim().isEmpty) return {};
    final outer = json.decode(content) as Map;
    final gz = outer['gz'] as String?;
    if (gz == null) return {};
    final inner = json.decode(utf8.decode(gzip.decode(base64.decode(gz)))) as Map;
    return {
      for (final k in inner.entries)
        '${k.key}': {for (final e in (k.value as Map).entries) '${e.key}': List<dynamic>.from(e.value as List)},
    };
  }

  static Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'Content-Type': 'application/json',
  };

  // ── what was in step last time ──

  static Map<String, Map<String, _Known>> _loadKnown() {
    try {
      final raw = _prefs?.getString(_knownKey);
      if (raw == null) return {};
      return {
        for (final k in (json.decode(raw) as Map<String, dynamic>).entries)
          k.key: {for (final e in (k.value as Map<String, dynamic>).entries) e.key: _Known.fromJson(e.value as List)},
      };
    } catch (_) {
      return {};
    }
  }

  static void _saveKnown() {
    _prefs?.setString(
      _knownKey,
      json.encode({for (final k in _known.entries) k.key: {for (final e in k.value.entries) e.key: e.value.toJson()}}),
    );
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

class _Known {
  const _Known(this.hash, this.time, this.deleted);
  final int hash;
  final int time;
  final bool deleted;

  List<Object> toJson() => [hash, time, if (deleted) 1];
  static _Known fromJson(List<dynamic> j) => _Known((j[0] as num).toInt(), (j[1] as num).toInt(), j.length > 2);
}

class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => GistSync._onLifecycle(state);
}
