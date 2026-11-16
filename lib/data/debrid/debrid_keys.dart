import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Debrid API keys, in the system keychain: never in plain settings, never synced to the account.
class DebridKeys {
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static final _cache = <String, String?>{};

  static Future<String?> read(String name) async {
    if (_cache.containsKey(name)) return _cache[name];
    try {
      final v = await _storage.read(key: 'debrid.$name');
      return _cache[name] = (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String name, String value) async {
    _cache[name] = value.isEmpty ? null : value;
    try {
      if (value.isEmpty) {
        await _storage.delete(key: 'debrid.$name');
      } else {
        await _storage.write(key: 'debrid.$name', value: value);
      }
    } catch (_) {}
  }
}
