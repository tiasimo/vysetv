import 'package:flutter/material.dart';

import '../data/app_settings.dart';

/// One section of the navbar: the rail on a desktop or tablet, the bottom bar on a phone.
class NavItem {
  const NavItem(this.id, this.label, this.icon, this.activeIcon, {this.glyph});

  /// What the saved order and the hidden list know a section by. The label and the place in
  /// [navItems] can change between versions; this never does, and is never reused.
  final String id;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Text glyph used instead of an icon (Anime gets ヴ, the V in Vyse).
  final String? glyph;
}

/// Every section, in the default order.
const navItems = [
  NavItem('home', 'Home', Icons.home_outlined, Icons.home_rounded),
  NavItem('discover', 'Discover', Icons.explore_outlined, Icons.explore_rounded),
  NavItem('search', 'Search', Icons.search_rounded, Icons.search_rounded),
  NavItem('movies', 'Movies', Icons.movie_creation_outlined, Icons.movie_creation_rounded),
  NavItem('tv', 'TV Shows', Icons.tv_outlined, Icons.tv_rounded),
  NavItem('anime', 'Anime', Icons.circle, Icons.circle, glyph: 'ヴ'),
  NavItem('top', 'Top Rated', Icons.star_border_rounded, Icons.star_rounded),
  NavItem('party', 'Party', Icons.celebration_outlined, Icons.celebration_rounded),
  NavItem('list', 'My List', Icons.bookmark_border_rounded, Icons.bookmark_rounded),
  NavItem('downloads', 'Downloads', Icons.download_outlined, Icons.download_rounded),
  NavItem('history', 'History', Icons.history_rounded, Icons.history_rounded),
  NavItem('servers', 'Servers', Icons.dns_outlined, Icons.dns_rounded),
  NavItem('manga', 'Manga', Icons.menu_book_outlined, Icons.menu_book_rounded),
  NavItem('music', 'Music', Icons.music_note_outlined, Icons.music_note_rounded),
  NavItem('audiobooks', 'Audiobooks', Icons.headphones_outlined, Icons.headphones_rounded),
  NavItem('live', 'Live TV', Icons.live_tv_outlined, Icons.live_tv_rounded),
];

NavItem navItem(String id) => navItems.firstWhere((s) => s.id == id, orElse: () => navItems.first);

/// Settings → Appearance → Navigation: your order for the navbar, and the sections you hid.
/// Saved as ids, so a section keeps its place and its switch when a later version adds, removes
/// or renames others.
abstract final class NavLayout {
  /// Fires when the order or a switch changes, here or from another device through the account.
  static final Listenable changes = Listenable.merge([AppSettings.navOrder, AppSettings.navOff]);

  static List<String> _ids(String raw) => [for (final s in raw.split(',')) if (s.trim().isNotEmpty) s.trim()];

  /// Every section in your order, hidden ones included. Ids this version doesn't have are left
  /// out; a section the saved order doesn't know yet (added by an update) goes right after the
  /// one it follows by default.
  static List<NavItem> get all {
    final byId = {for (final s in navItems) s.id: s};
    final out = <NavItem>[];
    for (final id in _ids(AppSettings.navOrder.value)) {
      final s = byId[id];
      if (s != null && !out.contains(s)) out.add(s);
    }
    for (var i = 0; i < navItems.length; i++) {
      if (out.contains(navItems[i])) continue;
      var at = 0;
      for (var j = i - 1; j >= 0; j--) {
        final k = out.indexOf(navItems[j]);
        if (k >= 0) {
          at = k + 1;
          break;
        }
      }
      out.insert(at, navItems[i]);
    }
    return out;
  }

  /// What the navbar shows, in order. Never empty: if the saved value hides everything this
  /// version has, the first section shows anyway.
  static List<NavItem> get visible {
    final list = all, off = _ids(AppSettings.navOff.value).toSet();
    final on = [for (final s in list) if (!off.contains(s.id)) s];
    return on.isEmpty ? [list.first] : on;
  }

  static bool shows(String id) => visible.any((s) => s.id == id);

  static void setOrder(List<NavItem> order) {
    final ids = [for (final s in order) s.id].join(',');
    AppSettings.navOrder.set(ids == [for (final s in navItems) s.id].join(',') ? '' : ids);
  }

  /// Shows or hides [s]. The last one showing stays: a navbar with nothing in it leads nowhere.
  static void setOn(NavItem s, bool on) {
    final shown = visible;
    if (on == shown.contains(s)) return;
    if (!on && shown.length == 1) return;
    // ids from a newer version stay in the list, so they're still hidden there
    final off = _ids(AppSettings.navOff.value)..remove(s.id);
    if (!on) off.add(s.id);
    AppSettings.navOff.set(off.join(','));
  }

  static bool get isDefault => AppSettings.navOrder.value.isEmpty && AppSettings.navOff.value.isEmpty;

  /// The default order, everything showing.
  static void reset() {
    AppSettings.navOrder.set('');
    AppSettings.navOff.set('');
  }
}
