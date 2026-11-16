/// The list and tracking services VyseTV can keep up to date.
enum TrackerId {
  anilist('AniList'),
  simkl('Simkl'),
  trakt('Trakt');

  const TrackerId(this.label);
  final String label;
}

/// A code to enter on the service's site while VyseTV waits (Simkl, Trakt).
class DeviceCode {
  const DeviceCode({required this.deviceCode, required this.userCode, required this.url, required this.expiresAt, required this.interval});
  final String deviceCode;
  final String userCode;
  final Uri url; // the page to enter it on (with it filled in, where the site allows)
  final DateTime expiresAt;
  final Duration interval; // how often to ask

  /// "simkl.com/pin"
  String get site => '${url.host.replaceFirst('www.', '')}${url.path == '/' ? '' : url.path}';
}

/// What a service's row in Settings shows.
class TrackerState {
  const TrackerState({
    this.configured = false,
    this.connected = false,
    this.userName = '',
    this.reconnect = false,
    this.pending = 0,
    this.unmatched = 0,
    this.lastSync,
    this.note,
    this.expiresSoon = false,
  });

  final bool configured; // VyseTV has a client id for it
  final bool connected;
  final String userName;
  final bool reconnect; // the sign-in stopped working: updates wait until you sign in again
  final int pending; // updates waiting to be sent
  final int unmatched; // titles this service has no entry for (this session)
  final DateTime? lastSync;
  final String? note; // e.g. "unavailable, will retry"
  final bool expiresSoon; // AniList: the year-long sign-in ends within two weeks

  TrackerState copyWith({
    bool? configured,
    bool? connected,
    String? userName,
    bool? reconnect,
    int? pending,
    int? unmatched,
    DateTime? lastSync,
    String? note,
    bool clearNote = false,
    bool? expiresSoon,
  }) => TrackerState(
    configured: configured ?? this.configured,
    connected: connected ?? this.connected,
    userName: userName ?? this.userName,
    reconnect: reconnect ?? this.reconnect,
    pending: pending ?? this.pending,
    unmatched: unmatched ?? this.unmatched,
    lastSync: lastSync ?? this.lastSync,
    note: clearNote ? null : (note ?? this.note),
    expiresSoon: expiresSoon ?? this.expiresSoon,
  );
}

/// The sign-in no longer works (expired, revoked): keep the update, ask to sign in again.
class TrackerAuthException implements Exception {
  const TrackerAuthException([this.message = 'Sign-in expired']);
  final String message;
  @override
  String toString() => message;
}

/// Worth trying again later (offline, rate limited, the service is down).
class TrackerRetryException implements Exception {
  const TrackerRetryException(this.message, {this.after});
  final String message;
  final Duration? after; // when the service said to come back
  @override
  String toString() => message;
}

/// This update can never go through (no such entry there, rejected values): drop it.
class TrackerSkipException implements Exception {
  const TrackerSkipException(this.message, {this.unmatched = false});
  final String message;
  final bool unmatched; // the title isn't on that service
  @override
  String toString() => message;
}
