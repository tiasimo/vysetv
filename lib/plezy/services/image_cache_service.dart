// VyseTV stand-in for Plezy's artwork cache, which is built on the
// cached_network_image_ce fork's HTTP hooks. VyseTV uses the regular
// cached_network_image; this keeps the one thing the lifted code needs: a cache
// manager for server artwork and trickplay sheets.

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Server artwork (posters, backdrops, trickplay sheets): kept two weeks.
class PlexImageCacheManager extends CacheManager with ImageCacheManager {
  PlexImageCacheManager._() : super(Config('vyseMediaServerArtwork', stalePeriod: const Duration(days: 14), maxNrOfCacheObjects: 3000));

  static final PlexImageCacheManager instance = PlexImageCacheManager._();
}

/// Strips credentials (Plex tokens, Jellyfin api keys) from an artwork URL before logging it.
String redactArtworkUrl(String url) =>
    url.replaceAllMapped(RegExp(r'([?&](?:X-Plex-Token|api_key|ApiKey|X-Emby-Token)=)[^&]+', caseSensitive: false), (m) => '${m[1]}REDACTED');
