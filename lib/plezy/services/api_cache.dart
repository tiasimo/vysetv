// VyseTV stand-in for Plezy's drift-backed ApiCache: the same API, kept in memory.
// Request caching works for the session (faster revisits, fewer server round trips);
// offline pinning (Plezy's downloads) is not part of VyseTV, so pin/metadata reads
// keep only what was put this session.

import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';

class ApiCacheSingleton<T extends ApiCache> {
  ApiCacheSingleton(this.backends, this.typeName, this._create);
  final Set<MediaBackend> backends;
  final String typeName;
  final T Function() _create;
  T? _instance;

  /// Created on first use: there is no database to initialise first.
  T get instance {
    final existing = _instance;
    if (existing != null) return existing;
    final created = _create();
    install(created);
    return created;
  }

  void install(T instance) {
    _instance = instance;
    ApiCache.registerInstance(instance, backends);
  }
}

abstract class ApiCache {
  static final Map<MediaBackend, ApiCache> _byBackend = {};

  static void registerInstance(ApiCache instance, Set<MediaBackend> backends) {
    for (final backend in backends) {
      _byBackend[backend] = instance;
    }
  }

  static ApiCache forBackend(MediaBackend? backend) {
    final picked = _byBackend[backend ?? MediaBackend.plex] ?? _byBackend[MediaBackend.plex];
    if (picked == null) throw StateError('No ApiCache registered for backend $backend');
    return picked;
  }

  static Future<void> clearRegisteredVolatile() async {
    for (final cache in _byBackend.values.toSet()) {
      await cache.clearVolatile();
    }
  }

  final Map<String, ({Map<String, dynamic> data, DateTime at})> _rows = {};
  final Set<String> _pinned = {};

  String _key(ServerId serverId, String endpoint) => '$serverId:$endpoint';

  Future<Map<String, dynamic>?> get(ServerId serverId, String endpoint) async => _rows[_key(serverId, endpoint)]?.data;

  Future<Map<String, dynamic>?> getIfFresh(ServerId serverId, String endpoint, {required Duration maxAge}) async {
    final row = _rows[_key(serverId, endpoint)];
    if (row == null || DateTime.now().difference(row.at) > maxAge) return null;
    return row.data;
  }

  Future<void> put(ServerId serverId, String endpoint, Map<String, dynamic> data) async {
    _rows[_key(serverId, endpoint)] = (data: data, at: DateTime.now());
  }

  Future<void> deleteForServer(ServerId serverId) async {
    final prefix = '$serverId:';
    _rows.removeWhere((k, _) => k.startsWith(prefix));
    _pinned.removeWhere((k) => k.startsWith(prefix));
  }

  Future<void> pin(ServerId serverId, String endpoint) async => _pinned.add(_key(serverId, endpoint));

  Future<bool> isPinned(ServerId serverId, String endpoint) async => _pinned.contains(_key(serverId, endpoint));

  Future<void> clearAll() async {
    _rows.clear();
    _pinned.clear();
  }

  Future<void> clearVolatile() async => _rows.removeWhere((k, _) => !_pinned.contains(k));

  Future<Set<String>> extractPinnedIds(ServerId serverId, RegExp keyPattern) async {
    final prefix = '$serverId:';
    final ids = <String>{};
    for (final key in _pinned) {
      if (!key.startsWith(prefix)) continue;
      final m = keyPattern.firstMatch(key.substring(prefix.length));
      if (m != null && m.groupCount >= 1 && m.group(1) != null) ids.add(m.group(1)!);
    }
    return ids;
  }

  Future<List<({ServerId serverId, String id, String data})>> listPinnedRowsByPattern(RegExp keyPattern) async => const [];

  Future<MediaItem?> getMetadata(ServerId serverId, String itemId);

  Future<void> pinForOffline(ServerId serverId, String itemId);

  Future<void> deleteForItem(ServerId serverId, String itemId);

  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  });

  Future<Map<String, MediaItem>> getAllPinnedMetadata({Set<ServerId>? cacheServerIds});
}
