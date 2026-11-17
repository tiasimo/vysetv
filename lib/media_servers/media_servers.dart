// Your own Plex, Jellyfin and Emby servers, on top of Plezy's server engine (lib/plezy).
//
// Accounts live in the system keychain (flutter_secure_storage) and never leave the device.
// A Plex account brings every server it can reach (and its Plex Home profiles); a Jellyfin or
// Emby sign-in is one server. Clients are made on first use and kept for the session.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../plezy/connection/connection.dart';
import '../plezy/exceptions/media_server_exceptions.dart';
import '../plezy/media/ids.dart';
import '../plezy/media/media_backend.dart';
import '../plezy/media/media_browser_dialect.dart';
import '../plezy/media/media_server_client.dart';
import '../plezy/models/plex/plex_config.dart';
import '../plezy/models/plex/plex_home_user.dart';
import '../plezy/services/jellyfin_auth_header.dart';
import '../plezy/services/jellyfin_auth_service.dart';
import '../plezy/services/jellyfin_client.dart';
import '../plezy/services/jellyfin_endpoint_discovery.dart';
import '../plezy/services/jellyfin_lan_discovery_service.dart';
import '../plezy/services/plex_auth_service.dart';
import '../plezy/services/plex_client.dart';
import '../plezy/utils/active_client_scope.dart';
import '../plezy/utils/device_identity.dart';

export '../plezy/media/media_backend.dart' show MediaBackend;
export '../plezy/media/media_browser_dialect.dart' show MediaBrowserDialect;
export '../plezy/models/plex/plex_home_user.dart' show PlexHomeUser;
export '../plezy/services/jellyfin_lan_discovery_service.dart' show DiscoveredJellyfinServer;

// ───────────────────────── Accounts ─────────────────────────

/// One sign-in: a Plex account (any number of servers) or one Jellyfin / Emby server.
sealed class ServerAccount {
  String get id;
  MediaBackend get backend;
  DateTime get createdAt;

  /// The person signed in ("Ayman", or the Plex Home profile in use).
  String get who;

  /// Their picture, when the server has one.
  String? get avatar;

  Map<String, Object?> toJson();

  static ServerAccount? fromJson(Map<String, Object?> j) {
    final id = j['id'] as String?;
    final backend = MediaBackend.values.where((b) => b.name == j['backend']).firstOrNull;
    final config = j['config'];
    if (id == null || backend == null || config is! Map) return null;
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now();
    final json = config.cast<String, Object?>();
    if (backend == MediaBackend.plex) {
      return PlexAccount(
        PlexAccountConnection.fromConfigJson(id: id, json: json, createdAt: created),
        profileToken: j['profileToken'] as String?,
        avatar: j['avatar'] as String?,
        userId: j['userId'] as String?,
      );
    }
    return JellyfinAccount(
      JellyfinConnection.fromConfigJson(
        id: id,
        json: json,
        createdAt: created,
        dialect: backend == MediaBackend.emby ? MediaBrowserDialect.emby : MediaBrowserDialect.jellyfin,
      ),
    );
  }
}

class PlexAccount extends ServerAccount {
  PlexAccount(this.conn, {this.profileToken, this.avatar, this.userId});
  final PlexAccountConnection conn;

  /// Who the account is on plex.tv. Every sign-in gets a new token, so this is how signing in
  /// to the same account again is recognised. Null on a sign-in from before Lorewatch kept it,
  /// until the next sign-in asks ([MediaServers._identifyPlex]).
  String? userId;

  /// The id in plex.tv's answer about a user.
  static String? userIdIn(Map<String, dynamic> info) => switch (info['uuid'] ?? info['id']) {
    final String v when v.trim().isNotEmpty => v.trim(),
    final num v => '$v',
    _ => null,
  };

  /// The Plex Home profile's own token, while one is picked.
  final String? profileToken;

  @override
  final String? avatar;

  @override
  String get id => conn.id;
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  DateTime get createdAt => conn.createdAt;
  @override
  String get who => conn.activeProfile?.displayName ?? conn.accountLabel;

  /// The token everything runs as: the profile's when one is picked.
  String get token => profileToken ?? conn.accountToken;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'backend': backend.name,
    'createdAt': createdAt.toIso8601String(),
    'config': conn.toConfigJson(),
    'profileToken': ?profileToken,
    'avatar': ?avatar,
    'userId': ?userId,
  };
}

class JellyfinAccount extends ServerAccount {
  JellyfinAccount(this.conn);
  final JellyfinConnection conn;

  @override
  String get id => conn.id;
  @override
  MediaBackend get backend => conn.kind;
  @override
  DateTime get createdAt => conn.createdAt;
  @override
  String get who => conn.userName;
  @override
  String? get avatar {
    final tag = conn.primaryImageTag;
    if (tag == null) return null;
    final prefix = conn.dialect == MediaBrowserDialect.emby ? '/emby' : '';
    return '${conn.baseUrl}$prefix/Users/${conn.userId}/Images/Primary?tag=$tag&quality=90&maxWidth=200';
  }

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'backend': backend.name,
    'createdAt': createdAt.toIso8601String(),
    'config': conn.toConfigJson(),
  };
}

/// One server you can browse: a Plex server of an account, or a Jellyfin / Emby server.
class MediaServer {
  MediaServer._(this.account, this.serverId, this.name, {this.plex});
  final ServerAccount account;
  final ServerId serverId;
  final String name;

  /// The Plex server, for Plex.
  final PlexServer? plex;

  MediaBackend get backend => account.backend;

  /// Unique across accounts (two people can sign in to the same server).
  String get key => '${account.id}/$serverId';

  /// "Plex", "Jellyfin" or "Emby".
  String get product => switch (backend) {
    MediaBackend.plex => 'Plex',
    MediaBackend.emby => 'Emby',
    _ => 'Jellyfin',
  };

  /// Shared with you, rather than your own (Plex).
  bool get shared => plex != null && !plex!.owned;
}

// ───────────────────────── The manager ─────────────────────────

class MediaServers extends ChangeNotifier {
  MediaServers._();
  static final instance = MediaServers._();

  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static const _key = 'vyse.mediaServers.v1';

  final List<ServerAccount> _accounts = [];
  List<ServerAccount> get accounts => List.unmodifiable(_accounts);

  /// Every server, Plex ones grouped under their account, in the order they were added.
  List<MediaServer> get servers => [
    for (final a in _accounts)
      ...switch (a) {
        PlexAccount() => [
          for (final s in a.conn.servers) MediaServer._(a, ServerId(s.clientIdentifier), s.name, plex: s),
        ],
        JellyfinAccount() => [
          MediaServer._(a, ServerId(a.conn.serverMachineId.isEmpty ? a.conn.id : a.conn.serverMachineId), a.conn.serverName),
        ],
      },
  ];

  String? _selectedKey;

  /// The server the section shows. The first one until you pick another.
  MediaServer? get selected {
    final all = servers;
    return all.where((s) => s.key == _selectedKey).firstOrNull ?? all.firstOrNull;
  }

  void select(MediaServer s) {
    if (s.key == _selectedKey) return;
    _selectedKey = s.key;
    notifyListeners();
    unawaited(_save());
  }

  bool _loaded = false;
  bool get loaded => _loaded;
  Future<void>? _loading;

  /// Reads your saved sign-ins (once).
  Future<void> load() => _loading ??= () async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final a in (j['accounts'] as List? ?? const [])) {
          if (a is! Map) continue;
          final acc = ServerAccount.fromJson(a.cast<String, Object?>());
          if (acc != null) _accounts.add(acc);
        }
        _selectedKey = j['selected'] as String?;
        _deviceId = j['deviceId'] as String?;
      }
    } catch (e) {
      debugPrint('MediaServers: could not read saved servers: $e');
    }
    _loaded = true;
    notifyListeners();
  }();

  Future<void> _save() async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({'accounts': [for (final a in _accounts) a.toJson()], 'selected': _selectedKey, 'deviceId': ?_deviceId}),
      );
    } catch (e) {
      debugPrint('MediaServers: could not save servers: $e');
    }
  }

  String? _deviceId;

  /// This device's id for Plex and Jellyfin / Emby (they list it under devices). Made once.
  Future<String> deviceId() async {
    await load();
    final existing = _deviceId;
    if (existing != null) return existing;
    final id = _deviceId = const Uuid().v4();
    await _save();
    return id;
  }

  /// Adds (or refreshes) an account and shows its first server.
  Future<void> add(ServerAccount account) async {
    final i = _accounts.indexWhere((a) => a.id == account.id || _sameLogin(a, account));
    if (i >= 0) {
      _forget(_accounts[i]);
      _accounts[i] = account;
    } else {
      _accounts.add(account);
    }
    final first = servers.where((s) => s.account.id == account.id).firstOrNull;
    if (first != null) _selectedKey = first.key;
    notifyListeners();
    await _save();
  }

  bool _sameLogin(ServerAccount a, ServerAccount b) => switch ((a, b)) {
    // the same person, not the same token: plex.tv hands out a new token at every sign-in
    (PlexAccount a, PlexAccount b) => a.conn.accountToken == b.conn.accountToken || (a.userId != null && a.userId == b.userId),
    (JellyfinAccount a, JellyfinAccount b) => a.conn.serverMachineId == b.conn.serverMachineId && a.conn.userId == b.conn.userId,
    _ => false,
  };

  /// Signs out of [account]: it leaves the list and its connections are closed.
  Future<void> remove(ServerAccount account) async {
    final clients = [
      for (final e in _clients.entries)
        if (e.key.startsWith('${account.id}/')) e.value,
    ];
    _forget(account);
    _accounts.removeWhere((a) => a.id == account.id);
    notifyListeners();
    await _save();
    // Only here, not when an account is refreshed or signed in to again: a page or a player
    // that's open may still be using the client it was given.
    for (final f in clients) {
      unawaited(f.then<void>((c) async {
        if (c case final GracefullyCloseable g) {
          await g.closeGracefully();
        } else {
          c.close();
        }
      }).catchError((Object _) {}));
    }
  }

  /// Sign-ins from before Lorewatch kept the Plex user id are asked who they are, so that
  /// [fresh], a sign-in to the same account, takes the old one's place instead of sitting
  /// next to it. One whose token no longer works can't be asked: it counts as the same
  /// account when the name on it is the same.
  Future<void> _identifyPlex(PlexAuthService auth, PlexAccount fresh) async {
    if (fresh.userId == null) return;
    for (final a in _accounts.whereType<PlexAccount>().where((a) => a.userId == null).toList()) {
      try {
        a.userId = PlexAccount.userIdIn(await auth.getUserInfo(a.conn.accountToken));
      } catch (_) {
        if (a.conn.accountLabel == fresh.conn.accountLabel && a.conn.accountLabel != PlexSignIn.noName) a.userId = fresh.userId;
      }
    }
  }

  // ── clients ──

  final Map<String, Future<MediaServerClient>> _clients = {};

  /// The server's client, connected on first use. A failed connection is tried again next time.
  Future<MediaServerClient> client(MediaServer s) {
    final f = _clients[s.key] ??= _connect(s);
    f.catchError((Object _) {
      if (identical(_clients[s.key], f)) _clients.remove(s.key);
      return f;
    }).ignore();
    return f;
  }

  /// Drops a server's client so the next look connects afresh.
  void reconnect(MediaServer s) => _clients.remove(s.key);

  void _forget(ServerAccount a) => _clients.removeWhere((k, _) => k.startsWith('${a.id}/'));

  Future<MediaServerClient> _connect(MediaServer s) async {
    final a = s.account;
    switch (a) {
      case JellyfinAccount():
        return JellyfinClient.create(a.conn);
      case PlexAccount():
        final server = s.plex!;
        final clientId = a.conn.clientIdentifier;
        final PlexConnection best;
        try {
          best = await server.findBestWorkingConnection(clientIdentifier: clientId).first.timeout(const Duration(seconds: 30));
        } on StateError {
          throw const MediaServerUrlException("Impossibile raggiungere questo server. È acceso?");
        } on TimeoutException {
          throw const MediaServerUrlException("Impossibile raggiungere questo server. È acceso?");
        }
        final config = await PlexConfig.create(
          baseUrl: best.uri,
          token: server.accessToken,
          clientIdentifier: clientId,
          languageCode: 'en',
        );
        final client = await PlexClient.create(
          config,
          serverId: s.serverId,
          profileScopeId: buildPlexProfileScopeId(serverId: s.serverId, profileId: a.conn.activeProfile?.uuid ?? 'main'),
          serverName: server.name,
          prioritizedEndpoints: server.prioritizedEndpointUrls(preferredFirst: best.uri),
        );
        client
          ..plexAccountId = a.id
          ..plexAccountToken = a.token;
        return client;
    }
  }

  // ── Plex Home ──

  /// The profiles in the account's Plex Home (empty when it has none).
  Future<List<PlexHomeUser>> plexProfiles(PlexAccount a) async {
    final auth = await PlexAuthService.create(clientIdentifier: a.conn.clientIdentifier);
    try {
      return (await auth.getHomeUsers(a.conn.accountToken)).users;
    } on MediaServerException {
      return const [];
    }
  }

  /// Switches the account to [user] ([pin] for a protected profile).
  Future<void> switchPlexProfile(PlexAccount a, PlexHomeUser user, {String? pin}) async {
    final auth = await PlexAuthService.create(clientIdentifier: a.conn.clientIdentifier);
    final token = await auth.switchToUser(user.uuid, a.conn.accountToken, pin: pin);
    final servers = await auth.fetchServers(token);
    await add(
      PlexAccount(
        a.conn.copyWith(activeProfile: user, servers: servers, lastAuthenticatedAt: DateTime.now()),
        profileToken: token,
        avatar: user.thumb.isEmpty ? a.avatar : user.thumb,
        userId: a.userId,
      ),
    );
  }

  /// Looks for servers again (new ones shared with you, a server that moved).
  Future<void> refreshPlex(PlexAccount a) async {
    final auth = await PlexAuthService.create(clientIdentifier: a.conn.clientIdentifier);
    final servers = await auth.fetchServers(a.token);
    await add(PlexAccount(a.conn.copyWith(servers: servers), profileToken: a.profileToken, avatar: a.avatar, userId: a.userId));
  }
}

/// A readable reason for a failed sign-in or request.
String serverError(Object e) {
  if (e is MediaServerException) return e.display ?? e.message;
  if (e is TimeoutException) return 'Il server ha impiegato troppo a rispondere';
  if (e is StateError) return e.message;
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Connection refused') || s.contains('host lookup')) {
    return "Impossibile raggiungere il server";
  }
  return s.replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error): ?'), '');
}

// ───────────────────────── Signing in ─────────────────────────

/// Plex: you approve Lorewatch on plex.tv in your browser, Lorewatch waits for it.
class PlexSignIn {
  PlexSignIn._(this._auth, this._pinId, this.url);
  final PlexAuthService _auth;
  final int _pinId;

  /// Where you sign in and allow Lorewatch.
  final String url;

  /// What an account is called when plex.tv didn't say who it is.
  static const noName = 'Plex';

  static Future<PlexSignIn> start() async {
    final auth = await PlexAuthService.create(clientIdentifier: await MediaServers.instance.deviceId());
    final pin = await auth.createPin();
    return PlexSignIn._(auth, (pin['id'] as num).toInt(), auth.getAuthUrl(pin['code'] as String));
  }

  /// Waits (up to 10 minutes) for you to allow Lorewatch, then adds the account. Null when it
  /// was [cancelled] or ran out of time.
  Future<PlexAccount?> wait({bool Function()? cancelled}) async {
    final token = await _auth.pollPinUntilClaimed(_pinId, timeout: const Duration(minutes: 10), shouldCancel: cancelled);
    if (token == null || (cancelled?.call() ?? false)) return null;
    final results = await Future.wait([
      _auth.fetchServers(token),
      _auth.getUserInfo(token).catchError((Object _) => <String, dynamic>{}),
    ]);
    final servers = results[0] as List<PlexServer>;
    final info = results[1] as Map<String, dynamic>;
    String? pick(String k) => switch (info[k]) {
      final String v when v.trim().isNotEmpty => v.trim(),
      _ => null,
    };
    final account = PlexAccount(
      PlexAccountConnection(
        id: const Uuid().v4(),
        accountToken: token,
        clientIdentifier: _auth.clientIdentifier,
        accountLabel: pick('friendlyName') ?? pick('title') ?? pick('username') ?? noName,
        servers: servers,
        createdAt: DateTime.now(),
        lastAuthenticatedAt: DateTime.now(),
      ),
      avatar: pick('thumb'),
      userId: PlexAccount.userIdIn(info),
    );
    await MediaServers.instance._identifyPlex(_auth, account);
    await MediaServers.instance.add(account);
    return account;
  }
}

/// Jellyfin and Emby: the server's address, then your login or Quick Connect.
class JellyfinSignIn {
  JellyfinSignIn(this.dialect);

  /// Jellyfin or Emby: what you picked, corrected by what the server says it is.
  MediaBrowserDialect dialect;

  JellyfinEndpointRaceResult? _endpoint;
  JellyfinServerInfo? get server => _endpoint?.serverInfo;
  bool quickConnect = false;

  Future<JellyfinConnectionAuthService> _auth() async {
    final identity = await DeviceIdentityService.resolve();
    final version = await PackageInfo.fromPlatform().then((p) => p.version, onError: (Object _) => '1.0.0');
    return JellyfinConnectionAuthService(
      clientName: jellyfinClientName(identity),
      clientVersion: version,
      deviceName: jellyfinDeviceName(identity),
      dialect: dialect,
    );
  }

  Future<String> _deviceId() => MediaServers.instance.deviceId();

  /// Finds the server at [address] ("192.168.1.20", "jellyfin.example.com"…).
  Future<JellyfinServerInfo> find(String address) async {
    final input = JellyfinEndpointDiscovery.buildUserInputCandidates([address.trim()], dialect: dialect);
    if (input.probeBaseUrls.isEmpty) throw const MediaServerUrlException("Non sembra l'indirizzo di un server");
    final auth = await _auth();
    final endpoint = await auth.raceEndpoints(
      input.probeBaseUrls,
      baseUrlsToPersist: input.explicitBaseUrls,
      baseUrlValidationGroups: input.validationBaseUrlGroups,
    );
    _endpoint = endpoint;
    dialect = endpoint.serverInfo.dialect ?? dialect;
    quickConnect = dialect.supportsQuickConnect && await (await _auth()).isQuickConnectEnabled(endpoint.activeBaseUrl);
    return endpoint.serverInfo;
  }

  Future<JellyfinAccount> login(String username, String password) async {
    final endpoint = _endpoint!;
    final conn = await (await _auth()).authenticateByName(
      baseUrl: endpoint.activeBaseUrl,
      baseUrls: endpoint.baseUrls,
      username: username.trim(),
      password: password,
      deviceId: await _deviceId(),
      serverInfo: endpoint.serverInfo,
    );
    final account = JellyfinAccount(conn);
    await MediaServers.instance.add(account);
    return account;
  }

  /// Starts Quick Connect: the code to enter on the server (Settings → Quick Connect, or the
  /// Quick Connect button on a signed-in device), then [waitQuickConnect].
  Future<({String code, String secret})> startQuickConnect() async {
    final i = await (await _auth()).initiateQuickConnect(baseUrl: _endpoint!.activeBaseUrl, deviceId: await _deviceId());
    return (code: i.code, secret: i.secret);
  }

  Future<JellyfinAccount?> waitQuickConnect(String secret, {bool Function()? cancelled}) async {
    final endpoint = _endpoint!;
    final conn = await (await _auth()).authenticateByQuickConnect(
      baseUrl: endpoint.activeBaseUrl,
      baseUrls: endpoint.baseUrls,
      secret: secret,
      deviceId: await _deviceId(),
      serverInfo: endpoint.serverInfo,
      shouldCancel: cancelled,
    );
    if (conn == null) return null;
    final account = JellyfinAccount(conn);
    await MediaServers.instance.add(account);
    return account;
  }

  /// Jellyfin and Emby servers answering on your network.
  static Future<List<DiscoveredJellyfinServer>> discover() async {
    final service = JellyfinLanDiscoveryService();
    final found = await Future.wait([
      for (final d in MediaBrowserDialect.values)
        service.discover(dialect: d, responseWindow: const Duration(milliseconds: 1500)).catchError((Object _) => <DiscoveredJellyfinServer>[]),
    ]);
    final seen = <String>{};
    return [for (final list in found) ...list.where((s) => seen.add(s.id))];
  }
}
