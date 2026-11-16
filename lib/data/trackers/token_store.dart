import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'tracker.dart';

/// One service's sign-in on this device. It never goes to the account server: refreshing a
/// shared token on two devices would sign both out (Trakt revokes the old one), and a
/// server full of other sites' tokens is a target.
class TrackerToken {
  const TrackerToken({
    required this.access,
    required this.userId,
    required this.userName,
    required this.clientId,
    required this.createdAt,
    this.refresh,
    this.expiresAt,
  });

  final String access;
  final String? refresh;
  final DateTime? expiresAt;
  final String userId;
  final String userName;
  final String clientId; // a token only works with the app it was issued to
  final DateTime createdAt;

  bool expiresWithin(Duration d) => expiresAt != null && expiresAt!.isBefore(DateTime.now().add(d));

  Map<String, dynamic> toJson() => {
    'access': access,
    'refresh': ?refresh,
    'expiresAt': ?expiresAt?.millisecondsSinceEpoch,
    'userId': userId,
    'userName': userName,
    'clientId': clientId,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static TrackerToken fromJson(Map<String, dynamic> j) => TrackerToken(
    access: j['access'] as String,
    refresh: j['refresh'] as String?,
    expiresAt: j['expiresAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt()),
    userId: '${j['userId']}',
    userName: '${j['userName'] ?? ''}',
    clientId: '${j['clientId'] ?? ''}',
    createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num).toInt()),
  );
}

/// Sign-ins kept in the system's secure store (Credential Manager on Windows, the Keychain on
/// Apple devices, the Keystore on Android). Anything unreadable counts as signed out.
class TokenStore {
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  static String _key(TrackerId id) => 'tracker.${id.name}';

  static Future<TrackerToken?> read(TrackerId id) async {
    try {
      final raw = await _storage.read(key: _key(id));
      if (raw == null) return null;
      return TrackerToken.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(TrackerId id, TrackerToken t) => _storage.write(key: _key(id), value: json.encode(t.toJson()));

  static Future<void> delete(TrackerId id) async {
    try {
      await _storage.delete(key: _key(id));
    } catch (_) {}
  }
}
