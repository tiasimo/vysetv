import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/iptv/iptv_models.dart';

/// Favorite live channels, kept on this device. A favorite is a portal and a channel id, so the
/// same channel on two portals is two favorites.
class LiveFavorites {
  static const _prefsKey = 'live_tv_favorite_channels';

  /// Replaced (never changed in place) on every toggle, so listeners can compare by identity.
  static final ids = ValueNotifier<Set<String>>(const {});
  static bool _loaded = false;

  static String keyOf(VerifiedPortal p, IptvStream s) => '${p.key}|${s.streamId}';

  static bool has(VerifiedPortal p, IptvStream s) => ids.value.contains(keyOf(p, s));

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // anything starred before the load finished stays
      ids.value = {...?prefs.getStringList(_prefsKey), ...ids.value};
    } catch (_) {}
  }

  static void toggle(VerifiedPortal p, IptvStream s) {
    final key = keyOf(p, s);
    final next = {...ids.value};
    if (!next.remove(key)) next.add(key);
    ids.value = next;
    _save(next);
  }

  static Future<void> _save(Set<String> value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, value.toList());
    } catch (_) {}
  }
}
