import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net.dart';

/// The gold set (djgenesis/badges): the one template Lorewatch uses for the badges under a source.
const defaultBadgesUrl = 'https://raw.githubusercontent.com/djgenesis/badges/refs/heads/main/gold_badges_complete.json';

/// One badge from a template: when its pattern matches a stream's text, its image (or its name,
/// as a text tag) shows under the stream.
@immutable
class SourceBadge {
  const SourceBadge({required this.id, required this.group, required this.name, required this.pattern, this.image, this.tag, this.text, this.border});
  final String id;
  final String group;
  final String name;
  final RegExp pattern;
  final String? image;
  final int? tag; // text badges: fill, text and border colours (ARGB)
  final int? text;
  final int? border;
}

/// A group of badges ("Resolution", "Sound Formats"…). In some only the first match counts:
/// a stream has one resolution, one source, one codec.
class BadgeGroup {
  const BadgeGroup(this.id, this.name, this.exclusive);
  final String id;
  final String name;
  final bool exclusive;
}

/// SourceBadge templates in the Nuvio / Fusion format (what Badger, nintle.github.io/Badger, makes):
/// `{groups: [...], filters: [{id, groupId, name, pattern, imageURL, …}]}`. The template is kept
/// on the device, so badges show offline; its address is a synced setting.
class Badges {
  static final groups = ValueNotifier<List<BadgeGroup>>(const []);
  static final list = ValueNotifier<List<SourceBadge>>(const []);
  static const _cacheKey = 'badges.cache';
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    unawaited(_init());
  }

  static Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    final cached = p.getString(_cacheKey);
    if (cached != null) {
      try {
        final j = json.decode(cached) as Map<String, dynamic>;
        if (j['url'] == _url) _apply(j['data'] as Map<String, dynamic>);
      } catch (_) {}
    }
    await _refresh();
  }

  static const _url = defaultBadgesUrl;

  /// Fetches the template again on start, so the set stays current.
  static Future<void> _refresh() async {
    final url = _url;
    try {
      final r = await netClient.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return;
      final data = json.decode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      _apply(data);
      final p = await SharedPreferences.getInstance();
      await p.setString(_cacheKey, json.encode({'url': url, 'data': data}));
    } catch (_) {
      // offline, or not a template: keep what we have
    }
  }

  static int? _color(Object? v) {
    final s = '${v ?? ''}'.replaceFirst('#', '');
    if (s.length != 6 && s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    if (n == null) return null;
    // #RRGGBBAA in these templates
    return s.length == 6 ? 0xFF000000 | n : ((n & 0xFF) << 24) | (n >> 8);
  }

  static (List<BadgeGroup>, List<SourceBadge>) _parse(Map<String, dynamic> j) {
    final gs = [
      for (final g in ((j['groups'] as List?) ?? const []).whereType<Map>())
        BadgeGroup(
          '${g['id']}',
          '${g['name'] ?? ''}',
          RegExp(r'resolution|source|channel|streaming|encoder|codec|depth|quality', caseSensitive: false).hasMatch('${g['name'] ?? ''}'),
        ),
    ];
    final bs = <SourceBadge>[];
    for (final f in ((j['filters'] as List?) ?? const []).whereType<Map>()) {
      if (f['isEnabled'] == false) continue;
      var p = '${f['pattern'] ?? ''}';
      if (p.isEmpty) continue;
      // Dart has no inline flags: "(?i)" becomes case-insensitive matching
      final insensitive = p.startsWith('(?i)');
      if (insensitive) p = p.substring(4);
      try {
        final image = '${f['imageURL'] ?? ''}';
        bs.add(SourceBadge(
          id: '${f['id']}',
          group: '${f['groupId'] ?? ''}',
          name: '${f['name'] ?? ''}',
          pattern: RegExp(p, caseSensitive: !insensitive, unicode: true),
          image: image.startsWith('http') ? Uri.encodeFull(Uri.decodeFull(image)) : null,
          tag: _color(f['tagColor']),
          text: _color(f['textColor']),
          border: _color(f['borderColor']),
        ));
      } catch (_) {
        // a pattern Dart can't read: skip that badge
      }
    }
    return (gs, bs);
  }

  static void _apply(Map<String, dynamic> j) {
    final (gs, bs) = _parse(j);
    groups.value = gs;
    list.value = bs;
    _memo.clear();
  }

  static final _memo = <String, List<SourceBadge>>{};

  /// The badges [text] earns, in the template's order; in "one per stream" groups, only the first.
  static List<SourceBadge> of(String text) => _memo[text] ??= () {
    final exclusive = {for (final g in groups.value) if (g.exclusive) g.id};
    final taken = <String>{};
    final out = <SourceBadge>[];
    for (final b in list.value) {
      if (exclusive.contains(b.group) && taken.contains(b.group)) continue;
      if (!b.pattern.hasMatch(text)) continue;
      out.add(b);
      taken.add(b.group);
    }
    return out;
  }();

  /// The language badges among [badges] (their group is named "Language").
  static Iterable<SourceBadge> languages(List<SourceBadge> badges) {
    final ids = {for (final g in groups.value) if (g.name.toLowerCase().contains('lang')) g.id};
    return badges.where((b) => ids.contains(b.group));
  }
}
