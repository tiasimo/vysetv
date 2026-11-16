import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'net.dart';
import 'server_config.dart';

// The account server's address is this build's own and is not in the repository:
// see server_config.example.dart.
export 'server_config.dart' show accountServer;

class AccountUser {
  const AccountUser({
    required this.id,
    required this.email,
    required this.username,
    required this.name,
    required this.verified,
    this.bio = '',
    this.bannerUrl = '',
    this.private = false,
    this.dmsOff = false,
    this.hideActivity = false,
    this.onlineListHidden = false,
    this.statusMode = 'online',
    this.customStatus = '',
    this.termsAt,
    this.created,
    this.partyBanned = false,
  });
  final String id;
  final String email;
  final String username;
  final String name;
  final bool verified;

  // Party profile
  final String bio;
  final String bannerUrl;
  final bool private; // nobody else can add me; only friends see bio, banner, status line and activity
  final bool dmsOff; // nobody can message (otherwise friends can)
  final bool hideActivity; // don't show what I'm watching
  final bool onlineListHidden; // left out of Party's online list (private or not)
  final String statusMode; // online, idle, dnd, invisible
  final String customStatus;
  final DateTime? termsAt; // Party rules accepted
  final DateTime? created;
  final bool partyBanned; // removed from Party by an admin
}

/// Sign-up, sign-in and sign-out. The session is kept on the device; the profile (display
/// name, avatar) follows the account.
class Account {
  static late final PocketBase pb;
  static final user = ValueNotifier<AccountUser?>(null);
  static const _key = 'vyse.auth';
  static bool _pulling = false;
  static Timer? _pushTimer;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    pb = PocketBase(
      accountServer,
      // gets through even where the local DNS won't answer for the server's name
      httpClientFactory: resilientClient,
      authStore: AsyncAuthStore(
        save: (data) => prefs.setString(_key, data),
        initial: prefs.getString(_key),
        clear: () => prefs.remove(_key),
      ),
    );
    _fromStore();
    pb.authStore.onChange.listen((_) => _fromStore());
    for (final s in [AppSettings.displayName, AppSettings.avatarUrl, AppSettings.avatarLabel]) {
      s.addListener(_schedulePush);
    }
    // Refresh the saved session; only a real "no longer valid" signs out, not being offline.
    if (pb.authStore.isValid) {
      unawaited(
        pb.collection('users').authRefresh().then((_) {}, onError: (Object e) {
          if (e is ClientException && (e.statusCode == 401 || e.statusCode == 403 || e.statusCode == 404)) pb.authStore.clear();
        }),
      );
    }
  }

  static bool get signedIn => user.value != null;

  static void _fromStore() {
    final r = pb.authStore.isValid ? pb.authStore.record : null;
    if (r == null) {
      user.value = null;
      return;
    }
    user.value = AccountUser(
      id: r.id,
      email: r.getStringValue('email'),
      username: r.getStringValue('username'),
      name: r.getStringValue('name'),
      verified: r.getBoolValue('verified'),
      bio: r.getStringValue('bio'),
      bannerUrl: r.getStringValue('bannerUrl'),
      private: r.getStringValue('visibility') == 'private',
      dmsOff: r.getStringValue('dmPolicy') == 'nobody',
      hideActivity: r.getBoolValue('hideActivity'),
      onlineListHidden: r.getStringValue('onlineList') == 'hide',
      statusMode: r.getStringValue('statusMode').isEmpty ? 'online' : r.getStringValue('statusMode'),
      customStatus: r.getStringValue('customStatus'),
      termsAt: DateTime.tryParse(r.getStringValue('termsAt')),
      created: DateTime.tryParse(r.getStringValue('created')),
      partyBanned: r.getBoolValue('partyBanned'),
    );
    // the account's profile is the one shown in the app
    _pulling = true;
    final name = r.getStringValue('name');
    final avatar = r.getStringValue('avatarUrl');
    final label = r.getStringValue('avatarLabel');
    if (name.isNotEmpty) AppSettings.displayName.set(name);
    if (avatar.isNotEmpty) {
      AppSettings.avatarUrl.set(avatar);
      AppSettings.avatarLabel.set(label.isEmpty ? null : label);
    }
    _pulling = false;
  }

  /// Profile edits made in the app go up to the account.
  static void _schedulePush() {
    if (_pulling || !signedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 600), () async {
      final u = user.value;
      if (u == null) return;
      try {
        final r = await pb.collection('users').update(u.id, body: {
          'name': AppSettings.displayName.value,
          'avatarUrl': AppSettings.avatarUrl.value ?? '',
          'avatarLabel': AppSettings.avatarLabel.value ?? '',
        });
        pb.authStore.save(pb.authStore.token, r);
      } catch (_) {}
    });
  }

  static Future<void> signIn(String identity, String password) =>
      pb.collection('users').authWithPassword(identity.trim().toLowerCase(), password);

  /// Creates the account with the profile already set up on this device, then signs in.
  static Future<void> register({required String email, required String username, required String name, required String password}) async {
    final local = AppSettings.displayName.value;
    await pb.collection('users').create(body: {
      'email': email.trim().toLowerCase(),
      'username': username.trim().toLowerCase(),
      'name': name.trim().isNotEmpty ? name.trim() : (local == 'Guest' ? username.trim() : local),
      'password': password,
      'passwordConfirm': password,
      'emailVisibility': false,
      'avatarUrl': AppSettings.avatarUrl.value ?? '',
      'avatarLabel': AppSettings.avatarLabel.value ?? '',
    });
    await signIn(email, password);
  }

  /// Saves Party profile fields (bio, bannerUrl, visibility, dmPolicy, hideActivity, onlineList, statusMode,
  /// customStatus, avatarUrl) on the account. Throws when the server refuses, e.g. a bad image link.
  static Future<void> updateProfile(Map<String, dynamic> body) async {
    final u = user.value;
    if (u == null) return;
    final r = await pb.collection('users').update(u.id, body: body);
    pb.authStore.save(pb.authStore.token, r);
  }

  /// Fetches the account again (after the server changed something on it).
  static Future<void> refresh() async {
    if (pb.authStore.isValid) await pb.collection('users').authRefresh();
  }

  /// Forgot password, step 1: emails a 6-digit code if the email or username has an account.
  static Future<void> requestPasswordReset(String identity) =>
      pb.send('/api/vyse/reset/request', method: 'POST', body: {'login': identity.trim().toLowerCase()});

  /// Step 2: sets the new password with the emailed code, then signs in with it.
  static Future<void> resetPassword(String identity, String code, String password) async {
    await pb.send('/api/vyse/reset/confirm', method: 'POST', body: {'login': identity.trim().toLowerCase(), 'code': code.trim(), 'password': password});
    await signIn(identity, password);
  }

  /// Changes the password (other devices get signed out), then signs in again here.
  static Future<void> changePassword(String current, String next) async {
    final u = user.value;
    if (u == null) return;
    await pb.collection('users').update(u.id, body: {'oldPassword': current, 'password': next, 'passwordConfirm': next});
    await signIn(u.email, next);
  }

  /// Deletes the account for good once the password checks out. Leaves any party room first (a
  /// room's owner can't be deleted while it's theirs; it passes to the next member, or closes).
  /// Friends, messages, synced data and the party profile go with the account on the server.
  /// Null once it's gone; otherwise why not.
  static Future<String?> deleteAccount(String password) async {
    final u = user.value;
    if (u == null) return null;
    try {
      await pb.collection('users').authWithPassword(u.email.isNotEmpty ? u.email : u.username, password);
    } catch (e) {
      return e is ClientException && e.statusCode == 400 ? "That password isn't right." : describe(e);
    }
    try {
      await pb.send('/api/vyse/rooms/leave', method: 'POST');
    } catch (_) {}
    try {
      await pb.collection('users').delete(u.id);
    } catch (e) {
      return describe(e);
    }
    signOut();
    return null;
  }

  /// Back to a guest profile on this device.
  static void signOut() {
    pb.authStore.clear();
    _pulling = true;
    AppSettings.displayName.set('Guest');
    AppSettings.avatarUrl.set(null);
    AppSettings.avatarLabel.set(null);
    _pulling = false;
  }

  /// Null when the username can be taken; otherwise why not ("taken", "reserved", "invalid").
  static Future<String?> usernameProblem(String name) async {
    final n = name.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_.]{3,20}$').hasMatch(n)) return 'invalid';
    try {
      final r = await netClient.get(Uri.parse('$accountServer/api/vyse/username/${Uri.encodeComponent(n)}')).timeout(const Duration(seconds: 15));
      final j = json.decode(r.body) as Map<String, dynamic>;
      return j['available'] == true ? null : (j['reason'] as String? ?? 'taken');
    } catch (_) {
      return 'unknown'; // can't check right now; the server still refuses duplicates on sign-up
    }
  }

  /// A plain-language message for a failed request.
  static String describe(Object e, {bool signingIn = false}) {
    if (e is! ClientException) return 'Something went wrong. Try again.';
    if (e.statusCode == 0) return "Can't reach the server. Check your connection.";
    if (e.statusCode == 429) return 'Too many attempts. Wait a minute and try again.';
    final data = (e.response['data'] as Map?) ?? const {};
    String? code(String field) => ((data[field] as Map?)?['code']) as String?;
    switch (code('username')) {
      case 'validation_not_unique':
        return 'That username is taken.';
      case 'validation_reserved':
        return "That username isn't available.";
      case null:
        break;
      default:
        return 'Usernames are 3–20 characters: letters, numbers, _ and .';
    }
    switch (code('email')) {
      case 'validation_not_unique':
        return 'An account already uses that email.';
      case null:
        break;
      default:
        return 'Enter a valid email address.';
    }
    if (code('oldPassword') != null) return 'Your current password is wrong.';
    if (code('password') != null) return 'Passwords need at least 8 characters.';
    if (signingIn && e.statusCode == 400) return 'Wrong email, username or password.';
    final msg = e.response['message'];
    return msg is String && msg.isNotEmpty ? msg : 'Something went wrong. Try again.';
  }
}
