// VyseTV stand-in for Plezy's PlexApiCache (drift tables there; memory here).

import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import 'api_cache.dart';

class PlexApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<PlexApiCache>(const {MediaBackend.plex}, 'PlexApiCache', PlexApiCache._);
  static PlexApiCache get instance => _singleton.instance;

  PlexApiCache._();

  static void initialize([Object? _]) => _singleton.instance;

  static final RegExp _metadataKeyPattern = RegExp(r'/library/metadata/([^/]+)$');

  @override
  Future<void> deleteForItem(ServerId serverId, String ratingKey) =>
      deleteForServer(serverId).then((_) {}); // no per-item index in memory: drop the server's cache

  Future<void> deleteAllProfileRowsForItem(ServerId publicServerId, String ratingKey) => deleteForItem(publicServerId, ratingKey);

  @override
  Future<void> pinForOffline(ServerId serverId, String ratingKey) => pin(serverId, '/library/metadata/$ratingKey');

  Future<Set<String>> getPinnedKeys(ServerId serverId) => extractPinnedIds(serverId, _metadataKeyPattern);

  Future<bool> copyPinnedMetadata({
    required ServerId sourceServerId,
    required ServerId destinationServerId,
    required String ratingKey,
  }) async => false;

  @override
  Future<MediaItem?> getMetadata(ServerId serverId, String ratingKey) async => null;

  @override
  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  }) async {}

  @override
  Future<Map<String, MediaItem>> getAllPinnedMetadata({Set<ServerId>? cacheServerIds}) async => const {};
}
