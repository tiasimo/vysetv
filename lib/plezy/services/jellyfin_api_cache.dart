// Lorewatch stand-in for Plezy's JellyfinApiCache (drift tables there; memory here).
// Serves Jellyfin and Emby.

import '../media/ids.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import 'api_cache.dart';

class JellyfinApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<JellyfinApiCache>(const {
    MediaBackend.jellyfin,
    MediaBackend.emby,
  }, 'JellyfinApiCache', JellyfinApiCache._);
  static JellyfinApiCache get instance => _singleton.instance;

  JellyfinApiCache._();

  static void initialize([Object? _]) => _singleton.instance;

  static String mediaSegmentsEndpoint(String itemId) => '/MediaSegments/${Uri.encodeComponent(itemId)}';

  @override
  Future<void> deleteForItem(ServerId serverId, String itemId) => deleteForServer(serverId);

  @override
  Future<void> pinForOffline(ServerId serverId, String itemId) => pin(serverId, '/Items/$itemId');

  @override
  Future<MediaItem?> getMetadata(ServerId serverId, String itemId) async => null;

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
