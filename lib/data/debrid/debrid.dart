import 'package:flutter/foundation.dart';

import '../addons.dart' show AddonStream;
import '../app_settings.dart';
import 'models/debrid_file.dart';
import 'providers/alldebrid_service.dart';
import 'providers/debrid_link_service.dart';
import 'providers/premiumize_service.dart';
import 'providers/real_debrid_service.dart';
import 'providers/torbox_service.dart';
import '../torrent_file_ask.dart';

/// The debrid services Lorewatch can stream torrents through, and where each one gives out its key.
enum DebridProvider {
  realDebrid('real-debrid', 'Real-Debrid', 'https://real-debrid.com/apitoken'),
  torBox('torbox', 'TorBox', 'https://torbox.app/settings'),
  allDebrid('alldebrid', 'AllDebrid', 'https://alldebrid.com/apikeys/'),
  premiumize('premiumize', 'Premiumize', 'https://www.premiumize.me/account'),
  debridLink('debrid-link', 'Debrid-Link', 'https://debrid-link.com/webapp/apikey');

  const DebridProvider(this.id, this.label, this.keyPage);
  final String id;
  final String label;
  final String keyPage;

  static DebridProvider? byId(String id) => values.where((p) => p.id == id).firstOrNull;
}

/// Torrents through a debrid service (Settings → Debrid): the service fetches the torrent on its
/// servers and hands back a plain HTTPS link, so nothing is shared peer to peer from this device.
/// The provider and the on/off switch stay on this device; keys live in the keychain.
class Debrid {
  static final _rd = RealDebridService();
  static final _tb = TorBoxService();
  static final _ad = AllDebridService();
  static final _pm = PremiumizeService();
  static final _dl = DebridLinkService();

  /// Providers with a key saved on this device.
  static final keyed = ValueNotifier<Set<DebridProvider>>(const {});

  static Future<void> initialize() async {
    final have = <DebridProvider>{};
    for (final p in DebridProvider.values) {
      if (await _hasKey(p)) have.add(p);
    }
    keyed.value = have;
  }

  static DebridProvider? get provider => DebridProvider.byId(AppSettings.debridProvider.value);

  /// On, a provider picked, and its key saved: torrents go through it.
  static bool get active {
    final p = provider;
    return AppSettings.debridOn.value && p != null && keyed.value.contains(p);
  }

  static String get name => provider?.label ?? 'Debrid';

  static Future<bool> _hasKey(DebridProvider p) => switch (p) {
    DebridProvider.realDebrid => _rd.hasKey(),
    DebridProvider.torBox => _tb.hasKey(),
    DebridProvider.allDebrid => _ad.hasKey(),
    DebridProvider.premiumize => _pm.hasKey(),
    DebridProvider.debridLink => _dl.hasKey(),
  };

  static Future<String?> keyOf(DebridProvider p) => switch (p) {
    DebridProvider.realDebrid => _rd.getToken(),
    DebridProvider.torBox => _tb.getKey(),
    DebridProvider.allDebrid => _ad.getKey(),
    DebridProvider.premiumize => _pm.getKey(),
    DebridProvider.debridLink => _dl.getKey(),
  };

  /// The account behind [key], or null when the service doesn't accept it.
  static Future<Map<String, dynamic>?> verify(DebridProvider p, String key) => switch (p) {
    DebridProvider.realDebrid => _rd.verifyToken(key),
    DebridProvider.torBox => _tb.verifyKey(key),
    DebridProvider.allDebrid => _ad.verifyKey(key),
    DebridProvider.premiumize => _pm.verifyKey(key),
    DebridProvider.debridLink => _dl.verifyKey(key),
  };

  /// Saves [key] for [p] (empty: forgets it).
  static Future<void> saveKey(DebridProvider p, String key) async {
    switch (p) {
      case DebridProvider.realDebrid:
        await _rd.saveToken(key);
      case DebridProvider.torBox:
        await _tb.saveKey(key);
      case DebridProvider.allDebrid:
        await _ad.saveKey(key);
      case DebridProvider.premiumize:
        await _pm.saveKey(key);
      case DebridProvider.debridLink:
        await _dl.saveKey(key);
    }
    final have = {...keyed.value};
    key.trim().isEmpty ? have.remove(p) : have.add(p);
    keyed.value = have;
  }

  /// A short line about the account the service returned (name, plan), for Settings.
  static String describe(Map<String, dynamic> user) {
    String? s(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
    final name = s(user['username']) ?? s(user['email']) ?? s(user['customer_id']) ?? s(user['pseudo']) ?? s(user['user']?['username']);
    final premium = user['premium'] ?? user['isPremium'] ?? user['plan'] ?? user['premium_until'];
    final plan = premium == null || premium == false || premium == 0 ? null : 'Premium';
    return [name ?? 'Connected', ?plan].join(' · ');
  }

  /// The torrent as a magnet link, with its trackers.
  static String magnet(AddonStream s) {
    final title = s.release ?? s.filename ?? s.name;
    final tr = [for (final t in s.trackers) '&tr=${Uri.encodeComponent(t)}'].join();
    return 'magnet:?xt=urn:btih:${s.infoHash}&dn=${Uri.encodeComponent(title)}$tr';
  }

  /// The service's direct link for [s]'s file (that episode, in a season pack). Throws with the
  /// service's reason when it can't (not cached and too slow, dead torrent, bad key…).
  static Future<DebridFile> resolve(AddonStream s, {int? season, int? episode, String? episodeTitle}) =>
      _resolve(magnet(s), fileIdx: s.fileIdx, filename: s.filename, season: season, episode: episode, episodeTitle: episodeTitle);

  /// The service's direct link for one file of [magnet], a link with nothing to say which:
  /// the torrent's files are put to [ask] and the one picked is fetched. Throws
  /// [TorrentFileNotChosen] when the list is closed, or with the service's reason.
  static Future<DebridFile> resolveMagnet(String magnet, {required AskTorrentFile ask}) => _resolve(magnet, ask: ask);

  static Future<DebridFile> _resolve(String m, {int? fileIdx, String? filename, int? season, int? episode, String? episodeTitle, AskTorrentFile? ask}) async {
    final p = provider;
    if (p == null) throw Exception('Pick a debrid service in Settings first.');
    final files = await switch (p) {
      DebridProvider.realDebrid => _rd.resolveMagnet(m, fileIndex: fileIdx, filename: filename, season: season, episode: episode, episodeTitle: episodeTitle, ask: ask),
      DebridProvider.torBox => _tb.resolveMagnet(m, fileIndex: fileIdx, filename: filename, season: season, episode: episode, episodeTitle: episodeTitle, ask: ask),
      DebridProvider.allDebrid => _ad.resolveMagnet(m, fileIndex: fileIdx, filename: filename, season: season, episode: episode, episodeTitle: episodeTitle, ask: ask),
      DebridProvider.premiumize => _pm.resolveMagnet(m, fileIndex: fileIdx, filename: filename, season: season, episode: episode, episodeTitle: episodeTitle, ask: ask),
      DebridProvider.debridLink => _dl.resolveMagnet(m, fileIndex: fileIdx, filename: filename, season: season, episode: episode, episodeTitle: episodeTitle, ask: ask),
    };
    if (files.isEmpty) throw Exception('${p.label} returned no file for this torrent.');
    return files.first;
  }
}
