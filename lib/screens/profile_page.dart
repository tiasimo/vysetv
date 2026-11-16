import 'package:url_launcher/url_launcher.dart';

import '../data/account_sync.dart';
import '../data/addons.dart';
import '../data/film_sources/film_sources.dart';
import '../data/film_sources/source_settings.dart';
import '../data/account.dart';
import '../data/party/party.dart';
import '../data/party/friends.dart';
import 'party/friends_view.dart';
import 'party/party_widgets.dart';
import 'account_sheet.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/accent.dart';
import '../core/layout.dart';
import '../core/nav_sections.dart';
import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/updater.dart';
import '../widgets/update_dialog.dart';
import '../data/debrid/debrid.dart';
import '../data/subtitle_style.dart';
import '../data/trackers/tracker.dart';
import '../data/trackers/tracker_hub.dart';
import '../widgets/trackers/import_dialog.dart';
import '../widgets/trackers/tracker_signin.dart';
import '../widgets/service_logos.dart';
import '../data/manga_library.dart';
import '../widgets/common.dart';
import '../widgets/page_scrollbar.dart';
import '../widgets/section_chrome.dart';
import 'avatar_picker.dart';

const _card = Color(0xFF0D0F18);
const _danger = Color(0xFFF26B6B);

enum _Tab {
  account('Account', 'Your profile, sign-in and sync.', Icons.person_outline_rounded),
  party('Party profile', 'How everyone in Party sees you.', Icons.public_rounded),
  appearance('Appearance', 'The ambient light behind every page, and what the navbar shows.', Icons.palette_outlined),
  addons('Addons', 'Stremio addons for sources and subtitles. Synced with your account.', Icons.extension_outlined),
  sources('Sources', 'Where films and shows play from, and in what order. Synced with your account.', Icons.dns_outlined),
  debrid('Debrid', 'Stream torrents from a debrid service instead of peer to peer. Saved on this device.', Icons.cloud_download_outlined),
  playback('Playback', 'How videos play by default. Saved on this device.', Icons.play_circle_outline_rounded),
  subtitles('Subtitles', 'Default captions for the player. Saved on this device.', Icons.closed_caption_outlined),
  about('About', 'VyseTV, its version and where to find us.', Icons.info_outline_rounded),
  danger('Danger Zone', "Resets that can't be undone.", Icons.warning_amber_rounded);

  const _Tab(this.label, this.blurb, this.icon);
  final String label;
  final String blurb;
  final IconData icon;
}

/// Profile & settings, opened from the avatar at the bottom of the rail.
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.partyProfile = false, this.addons = false});
  static const route = 'profile';

  /// Open on the Party profile tab.
  final bool partyProfile;

  /// Open on the Addons tab.
  final bool addons;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static _Tab _last = _Tab.account;
  late _Tab _tab = widget.partyProfile ? (_last = _Tab.party) : (widget.addons ? (_last = _Tab.addons) : _last);
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _pick(_Tab t) => setState(() => _tab = _last = t);

  Widget _content() => AnimatedSwitcher(
    duration: const Duration(milliseconds: 220),
    child: KeyedSubtree(
      key: ValueKey(_tab),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_tab.label, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.8)),
          const SizedBox(height: 6),
          Text(_tab.blurb, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
          const SizedBox(height: 26),
          switch (_tab) {
            _Tab.account => const _AccountTab(),
            _Tab.party => const _PartyTab(),
            _Tab.appearance => const _AppearanceTab(),
            _Tab.addons => const _AddonsTab(),
            _Tab.sources => const _SourcesTab(),
            _Tab.debrid => const _DebridTab(),
            _Tab.playback => const _PlaybackTab(),
            _Tab.subtitles => const _SubtitlesTab(),
            _Tab.about => const _AboutTab(),
            _Tab.danger => const _DangerTab(),
          },
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final inset = Layout.inset(context);
    final right = pageRight(context);
    final top = Layout.topChrome(context) + (phone ? 12 : 30);

    return Material(
      color: VyseColors.bg,
      child: Stack(
        children: [
          const Positioned(top: -220, right: -160, child: PageGlow()),
          PageScrollbar(
            controller: _scroll,
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, top, right, 0),
                  sliver: SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (Navigator.of(context).canPop()) ...[
                              Transform.translate(
                                offset: const Offset(-8, 0),
                                child: BackLink(onTap: () => Navigator.of(context).maybePop()),
                              ),
                              const SizedBox(height: 14),
                            ],
                            const _Header(),
                            const SizedBox(height: 34),
                            if (phone) ...[
                              SizedBox(
                                height: 40,
                                child: ListView(
                                  scrollDirection: Axis.horizontal,
                                  children: [
                                    for (final t in _Tab.values)
                                      Padding(
                                        padding: const EdgeInsets.only(right: 6),
                                        child: t == _Tab.danger
                                            ? _DangerPill(selected: _tab == t, onTap: () => _pick(t))
                                            : FilterChipPill(label: t.label, selected: _tab == t, onTap: () => _pick(t)),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                              _content(),
                            ] else
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 220,
                                    child: Column(
                                      children: [for (final t in _Tab.values) _SideItem(tab: t, selected: _tab == t, onTap: () => _pick(t))],
                                    ),
                                  ),
                                  const SizedBox(width: 40),
                                  Expanded(child: _content()),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: SizedBox(height: pageBottom(context))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Header ─────────────────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final phone = Layout.isPhone(context);
    final size = phone ? 84.0 : 116.0;
    final avatar = Pressable(
      tooltip: 'Change avatar',
      onTap: () => showAvatarPicker(context),
      builder: (context, hovered, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: hovered ? 1 : .85), width: 2),
            ),
            child: ProfileAvatar(size: size - 10),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: VyseColors.bg, width: 3),
              ),
              child: const Icon(Icons.edit_rounded, size: 13, color: Colors.black),
            ),
          ),
        ],
      ),
    );

    final info = ListenableBuilder(
      listenable: Listenable.merge([AppSettings.displayName, Account.user]),
      builder: (context, _) {
        final u = Account.user.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppSettings.displayName.value,
              style: TextStyle(fontSize: phone ? 28 : 40, fontWeight: FontWeight.w800, letterSpacing: -1.2, height: 1.05),
            ),
            const SizedBox(height: 8),
            Text(u == null ? 'Local profile  ·  not signed in' : '@${u.username}', style: const TextStyle(fontSize: 14, color: VyseColors.textDim)),
            const SizedBox(height: 3),
            Text(u == null ? 'Sign in to use your profile on every device' : u.email, style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
          ],
        );
      },
    );

    final actions = ValueListenableBuilder<AccountUser?>(
      valueListenable: Account.user,
      builder: (context, u, _) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (u == null) ...[
            _SmallButton(label: 'Create account', onTap: () => showAccountSheet(context, register: true)),
            _SmallButton(label: 'Sign in', onTap: () => showAccountSheet(context), primary: true),
          ] else
            _SmallButton(label: 'Sign out', icon: Icons.logout_rounded, onTap: Account.signOut),
        ],
      ),
    );

    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              avatar,
              const SizedBox(width: 18),
              Expanded(child: info),
            ],
          ),
          const SizedBox(height: 16),
          actions,
        ],
      );
    }
    return Row(
      children: [
        avatar,
        const SizedBox(width: 30),
        Expanded(child: info),
        actions,
      ],
    );
  }
}

/// The chosen character, or the default gradient avatar.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: AppSettings.avatarUrl,
    builder: (context, url, _) {
      final fallback = Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [VyseColors.violet, VyseColors.accentHot]),
        ),
        child: Icon(Icons.person_rounded, size: size * .6, color: Colors.white),
      );
      return SizedBox.square(
        dimension: size,
        child: url == null
            ? fallback
            : ClipOval(
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  fadeInDuration: const Duration(milliseconds: 200),
                  errorWidget: (_, _, _) => fallback,
                ),
              ),
      );
    },
  );
}

// ───────────────────────── Building blocks ─────────────────────────

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.label, required this.onTap, this.icon, this.primary = false, this.danger = false});
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) {
      final fg = primary ? Colors.black : (danger ? _danger : VyseColors.text);
      return AnimatedScale(
        scale: pressed ? .95 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.fromLTRB(icon == null ? 18 : 14, 11, 18, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: primary
                ? (hovered ? Colors.white : const Color(0xFFF1F1F5))
                : danger
                ? _danger.withValues(alpha: hovered ? .2 : .1)
                : Colors.white.withValues(alpha: hovered ? .14 : .07),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 7)],
              Text(
                label,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: fg),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Settings category in the left column: icon + label, a lit bar and tint when selected.
class _SideItem extends StatelessWidget {
  const _SideItem({required this.tab, required this.selected, required this.onTap});
  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final danger = tab == _Tab.danger;
    final fg = danger ? _danger : (selected ? VyseColors.text : VyseColors.textDim);
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: EdgeInsets.only(bottom: 4, top: danger ? 14 : 0),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: selected ? (danger ? _danger.withValues(alpha: .12) : Colors.white.withValues(alpha: .08)) : Colors.white.withValues(alpha: hovered ? .04 : 0),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 3,
              height: selected ? 18 : 0,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(color: danger ? _danger : VyseColors.accent, borderRadius: BorderRadius.circular(2)),
            ),
            Icon(tab.icon, size: 19, color: fg),
            const SizedBox(width: 12),
            Text(
              tab.label,
              style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w700 : FontWeight.w600, color: hovered && !danger ? VyseColors.text : fg),
            ),
          ],
        ),
      ),
    );
  }
}

class _DangerPill extends StatelessWidget {
  const _DangerPill({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: selected ? _danger : _danger.withValues(alpha: hovered ? .14 : 0),
      ),
      child: Text(
        'Danger Zone',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.black : _danger),
      ),
    ),
  );
}

/// Titled group of rows on a flat card.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 34),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
        if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim))],
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: VyseColors.stroke),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke), children[i]],
            ],
          ),
        ),
      ],
    ),
  );
}

/// Title + description on the left, a control on the right (or below, for wide controls).
class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, this.subtitleWidget, this.trailing, this.below, this.leading});
  final String title;

  /// A logo or icon before the title (connected services).
  final Widget? leading;
  final String? subtitle;

  /// Shown instead of [subtitle] when set (e.g. live status).
  final Widget? subtitleWidget;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  if (subtitleWidget != null || subtitle != null) ...[
                    const SizedBox(height: 4),
                    subtitleWidget ?? Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 16), trailing!],
          ],
        ),
        if (below != null) ...[const SizedBox(height: 14), below!],
      ],
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.setting);
  final Setting<bool> setting;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: setting,
    builder: (context, on, _) => _Switch(value: on, onChanged: setting.set),
  );
}

class _Switch extends StatelessWidget {
  const _Switch({required this.value, required this.onChanged, this.color, this.thumb});
  final bool value;
  final ValueChanged<bool> onChanged;

  /// The track and the knob while on, for a control that wears the Appearance theme. Left out:
  /// Vyse's amber with a white knob.
  final Color? color;
  final Color? thumb;

  @override
  Widget build(BuildContext context) {
    final on = value;
    return Pressable(
      onTap: () => onChanged(!on),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: 50,
        height: 28,
        padding: const EdgeInsets.all(3),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: on ? (color ?? VyseColors.accent) : Colors.white.withValues(alpha: hovered ? .2 : .12),
        ),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: on ? (thumb ?? Colors.white) : Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// Row of options in a dark tray, the selected one lifted.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({required this.setting, required this.options, required this.label});
  final Setting<T> setting;
  final List<T> options;
  final String Function(T) label;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<T>(
    valueListenable: setting,
    builder: (context, value, _) => _Choice<T>(value: value, options: options, label: label, onChanged: setting.set),
  );
}

class _Choice<T> extends StatelessWidget {
  const _Choice({required this.value, required this.options, required this.label, required this.onChanged});
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(10)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final o in options)
          Pressable(
            onTap: () => onChanged(o),
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: o == value ? Colors.white.withValues(alpha: .16) : Colors.white.withValues(alpha: hovered ? .06 : 0),
              ),
              child: Text(
                label(o),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: o == value ? VyseColors.text : VyseColors.textDim),
              ),
            ),
          ),
      ],
    ),
  );
}

// ───────────────────────── Tabs ─────────────────────────

class _AccountTab extends StatelessWidget {
  const _AccountTab();

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: AppSettings.displayName.value);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Display name', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLength: 24,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: const InputDecoration(hintText: 'Your name'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (name != null && name.trim().isNotEmpty) AppSettings.displayName.set(name.trim());
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Section(
        title: 'Profile',
        children: [
          ValueListenableBuilder(
            valueListenable: AppSettings.avatarLabel,
            builder: (context, label, _) => _Row(
              title: 'Avatar',
              subtitle: label ?? 'Default',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ProfileAvatar(size: 44),
                  const SizedBox(width: 12),
                  _SmallButton(label: 'Change avatar', onTap: () => showAvatarPicker(context)),
                ],
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: AppSettings.displayName,
            builder: (context, name, _) => _Row(
              title: 'Display name',
              subtitle: name,
              trailing: _SmallButton(label: 'Rename', onTap: () => _rename(context)),
            ),
          ),
        ],
      ),
      ValueListenableBuilder<AccountUser?>(
        valueListenable: Account.user,
        builder: (context, u, _) => _Section(
          title: 'Account',
          subtitle: u == null
              ? 'Sign in to keep My List, history and reading progress on all your devices.'
              : 'Your profile follows this account to every device.',
          children: [
            if (u == null)
              _Row(
                title: 'Not signed in',
                subtitle: 'Everything is saved on this device for now.',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SmallButton(label: 'Create account', onTap: () => showAccountSheet(context, register: true)),
                    const SizedBox(width: 8),
                    _SmallButton(label: 'Sign in', primary: true, onTap: () => showAccountSheet(context)),
                  ],
                ),
              )
            else
              _Row(
                title: '@${u.username}',
                subtitleWidget: ValueListenableBuilder<String>(
                  valueListenable: AccountSync.status,
                  builder: (context, s, _) =>
                      Text(s.isEmpty ? u.email : '${u.email}  ·  $s', style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                ),
                subtitle: u.email,
                trailing: _SmallButton(label: 'Sign out', icon: Icons.logout_rounded, onTap: Account.signOut),
              ),
          ],
        ),
      ),
      ValueListenableBuilder<AccountUser?>(
        valueListenable: Account.user,
        builder: (context, u, _) => _Section(
          title: 'Password',
          children: [
            _Row(
              title: 'Change password',
              subtitle: u == null ? 'Sign in to change your password.' : 'Your other devices get signed out when you change it.',
              trailing: u == null
                  ? _SmallButton(label: 'Sign in', onTap: () => showAccountSheet(context))
                  : _SmallButton(label: 'Change', onTap: () => showAccountSheet(context, changePassword: true)),
            ),
          ],
        ),
      ),
      const _ConnectedServices(),
    ],
  );
}

/// AniList, Simkl and Trakt: what you watch here keeps your lists there up to
/// date. Each sign-in stays on this device.
class _ConnectedServices extends StatelessWidget {
  const _ConnectedServices();

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  static String _status(TrackerState s) {
    if (!s.configured) return 'Not set up yet';
    if (!s.connected) return 'Not connected';
    if (s.reconnect) return 'Sign in again to keep it updated${s.pending > 0 ? ' · ${s.pending} waiting' : ''}';
    return [
      s.userName.isEmpty ? 'Connected' : 'Connected as ${s.userName}',
      if (s.expiresSoon) 'sign-in ends soon',
      if (s.pending > 0) '${s.pending} waiting' else if (s.lastSync != null) 'updated ${_ago(s.lastSync!)}',
      if (s.note != null && s.pending > 0) s.note!,
      if (s.unmatched > 0) '${s.unmatched} not found there',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<TrackerId, TrackerState>>(
    valueListenable: TrackerHub.states,
    builder: (context, states, _) {
      final anime = states[TrackerId.anilist]?.connected ?? false;
      return _Section(
        title: 'Connected services',
        subtitle: 'What you watch in VyseTV keeps your lists there up to date. Signing in stays on this device.',
        children: [
          for (final id in TrackerId.values) ...[
            if (states[id] case final s?) ...[
              _Row(
                leading: ServiceLogo(switch (id) {
                  TrackerId.anilist => Service.anilist,
                  TrackerId.simkl => Service.simkl,
                  TrackerId.trakt => Service.trakt,
                }, size: 38),
                title: id.label,
                subtitle: _status(s),
                trailing: !s.configured
                    ? null
                    : !s.connected
                    ? _SmallButton(label: 'Connect', onTap: () => connectTracker(context, id))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (s.reconnect || s.expiresSoon) ...[
                            _SmallButton(label: 'Reconnect', primary: true, onTap: () => connectTracker(context, id)),
                            const SizedBox(width: 8),
                          ],
                          _SmallButton(label: 'Disconnect', onTap: () => TrackerHub.disconnect(id)),
                        ],
                      ),
              ),
              if (s.connected && !s.reconnect)
                _Row(
                  title: 'Import from ${id.label}',
                  subtitle: 'Your watchlist into My List, what you watched into History',
                  trailing: _SmallButton(label: 'Import', onTap: () => importFromTracker(context, id)),
                ),
              if (s.connected && id == TrackerId.anilist)
                _Row(
                  title: 'Update ${id.label} progress',
                  subtitle: 'Anime episodes you finish here count there',
                  trailing: _Toggle(AppSettings.trackAniList),
                ),
              if (s.connected && id == TrackerId.simkl) ...[
                _Row(title: 'Scrobble what I watch', subtitle: 'Films, shows and anime, as you play them', trailing: _Toggle(AppSettings.simklScrobble)),
                _Row(title: 'Sync My List', subtitle: 'Adding here puts it on your Simkl plan to watch', trailing: _Toggle(AppSettings.simklList)),
                _Row(
                  title: 'History removals reach Simkl',
                  subtitle: 'Removing a title from History here also clears its watch history on Simkl',
                  trailing: _Toggle(AppSettings.simklHistory),
                ),
              ],
              if (s.connected && id == TrackerId.trakt) ...[
                _Row(title: 'Scrobble what I watch', subtitle: 'Films, shows and anime, as you play them', trailing: _Toggle(AppSettings.traktScrobble)),
                _Row(title: 'Sync My List', subtitle: 'Adding here puts it on your Trakt watchlist', trailing: _Toggle(AppSettings.traktList)),
                _Row(
                  title: 'History removals reach Trakt',
                  subtitle: 'Removing a title from History here also removes the plays VyseTV sent to Trakt',
                  trailing: _Toggle(AppSettings.traktHistory),
                ),
              ],
            ],
          ],
          if (anime)
            _Row(
              title: 'Count rewatches',
              subtitle: 'Finishing episode 1 of something you completed starts a rewatch there',
              trailing: _Toggle(AppSettings.trackRewatches),
            ),
        ],
      );
    },
  );
}

class _PartyTab extends StatelessWidget {
  const _PartyTab();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AccountUser?>(
    valueListenable: Account.user,
    builder: (context, u, _) {
      if (u == null) {
        return _Section(
          title: 'Your Party profile',
          subtitle: 'Bio, banner, privacy and status belong to your account.',
          children: [
            _Row(
              title: 'Not signed in',
              subtitle: 'Sign in to set up how others see you.',
              trailing: _SmallButton(label: 'Sign in', primary: true, onTap: () => showAccountSheet(context)),
            ),
          ],
        );
      }
      final phone = Layout.isPhone(context);
      final preview = ListenableBuilder(
        listenable: Listenable.merge([AppSettings.displayName, AppSettings.avatarUrl]),
        builder: (context, _) => PartyProfileCard(profile: PartyProfile.mine()!, preview: true),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PREVIEW',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8, color: VyseColors.textDim),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: phone ? double.infinity : 380),
            child: preview,
          ),
          const SizedBox(height: 34),
          _Section(
            title: 'Look',
            children: [
              ValueListenableBuilder(
                valueListenable: AppSettings.avatarLabel,
                builder: (context, label, _) => _Row(
                  title: 'Avatar',
                  subtitle: label ?? 'Default',
                  trailing: _SmallButton(label: 'Change', onTap: () => showAvatarPicker(context)),
                ),
              ),
              _Row(
                title: 'Banner',
                subtitle: u.bannerUrl.isEmpty ? 'None yet. A colour from your username shows instead.' : 'Shown across the top of your profile.',
                trailing: _SmallButton(label: u.bannerUrl.isEmpty ? 'Add' : 'Change', onTap: () => showBannerDialog(context)),
              ),
              _Row(
                title: 'Bio',
                subtitle: u.bio.isEmpty ? 'A few words about you.' : u.bio,
                trailing: _SmallButton(
                  label: 'Edit',
                  onTap: () async {
                    final v = await showTextEditDialog(context, title: 'Bio', initial: u.bio, maxLength: 190, maxLines: 4, hint: 'Movies, shows, vibes…');
                    if (v != null && v != u.bio && context.mounted) await saveProfile(context, {'bio': v});
                  },
                ),
              ),
              _Row(
                title: 'Status line',
                subtitle: u.customStatus.isEmpty ? 'Shows under your name, e.g. "rewatching Dark".' : u.customStatus,
                trailing: _SmallButton(
                  label: 'Edit',
                  onTap: () async {
                    final v = await showTextEditDialog(context, title: 'Status line', initial: u.customStatus, maxLength: 80, hint: 'What are you up to?');
                    if (v != null && v != u.customStatus && context.mounted) await saveProfile(context, {'customStatus': v});
                  },
                ),
              ),
            ],
          ),
          _Section(
            title: 'Privacy',
            children: [
              _Row(
                title: 'Profile',
                subtitle: u.private
                    ? "Private. Nobody can add you or message you, and only friends see your bio, banner, status line and what you watch. You can still add people, and once you're friends it works both ways."
                    : 'Public. Anyone can add you and see your profile and what you watch. Friends can message you.',
                below: _Choice<bool>(
                  value: u.private,
                  options: const [false, true],
                  label: (v) => v ? 'Private' : 'Public',
                  onChanged: (v) => saveProfile(context, {'visibility': v ? 'private' : 'public'}),
                ),
              ),
              _Row(
                title: 'Online list',
                subtitle: u.onlineListHidden
                    ? "Hidden. You never appear in Party's online list, but your profile still shows when you're online. To look offline everywhere, set Status to Invisible."
                    : u.private
                    ? "Shown. You appear in Party's online list with your name and avatar; your status line and what you watch stay with friends."
                    : "Shown. You appear in Party's online list, with what you're watching.",
                below: _Choice<bool>(
                  value: u.onlineListHidden,
                  options: const [false, true],
                  label: (v) => v ? 'Hide' : 'Show',
                  onChanged: (v) => saveProfile(context, {'onlineList': v ? 'hide' : 'show'}),
                ),
              ),
              _Row(
                title: 'Who can message me',
                subtitle: 'Messages disappear 24 hours after they are sent.',
                below: _Choice<bool>(
                  value: u.dmsOff,
                  options: const [false, true],
                  label: (v) => v ? 'Nobody' : 'Friends',
                  onChanged: (v) => saveProfile(context, {'dmPolicy': v ? 'nobody' : 'friends'}),
                ),
              ),
              _Row(
                title: "Show what I'm watching",
                subtitle: u.private
                    ? 'Only your friends see the title you have playing while your profile is private.'
                    : 'Your profile and the online list show the title you have playing.',
                trailing: _Switch(value: !u.hideActivity, onChanged: (v) => saveProfile(context, {'hideActivity': !v})),
              ),
              _Row(
                title: 'Show my library',
                subtitle: u.private
                    ? 'Friends can open your My List, liked songs, public playlists and the artists you follow from your profile.'
                    : 'People can open your My List, liked songs, public playlists and the artists you follow from your profile.',
                trailing: _Toggle(AppSettings.partyLibrary),
              ),
              _Row(
                title: 'Music autoplay',
                subtitle: 'When your queue runs out, keep playing songs like the last one.',
                trailing: _Toggle(AppSettings.musicAutoplay),
              ),
              ValueListenableBuilder<FriendLists>(
                valueListenable: Friends.lists,
                builder: (context, l, _) => _Row(
                  title: 'Blocked people',
                  subtitle: l.blocked.isEmpty
                      ? "Nobody. Blocked people can't add you, message you or see your profile."
                      : '${l.blocked.length} blocked. They can\'t add you, message you or see your profile.',
                  trailing: _SmallButton(label: 'Manage', onTap: () => showBlockedDialog(context)),
                ),
              ),
              _Row(
                title: 'Party rules',
                subtitle: switch (u.termsAt) {
                  final d? => 'You accepted these on ${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.year}.',
                  null => 'What everyone in Party agrees to.',
                },
                trailing: _SmallButton(label: 'Read', onTap: () => showPartyRules(context)),
              ),
            ],
          ),
          _Section(
            title: 'Status',
            children: [
              _Row(
                title: 'Show me as',
                subtitle: switch (u.statusMode) {
                  'idle' => 'Idle: you look away from keyboard.',
                  'dnd' => 'Do not disturb: no message pop-ups.',
                  'invisible' => 'Invisible: you appear offline but can use everything.',
                  _ => 'Online: everyone sees when you are around.',
                },
                below: SingleChildScrollView(
                  scrollDirection: Axis.horizontal, // four options don't fit a phone's width
                  child: _Choice<String>(
                    value: u.statusMode,
                    options: const ['online', 'idle', 'dnd', 'invisible'],
                    label: (v) => switch (v) {
                      'idle' => 'Idle',
                      'dnd' => 'Do not disturb',
                      'invisible' => 'Invisible',
                      _ => 'Online',
                    },
                    onChanged: (v) => saveProfile(context, {'statusMode': v}),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _AppearanceTab extends StatelessWidget {
  const _AppearanceTab();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 34),
        child: ValueListenableBuilder(
          valueListenable: AppSettings.themeId,
          builder: (context, id, _) => LayoutBuilder(
            builder: (context, c) {
              const gap = 14.0;
              final cols = c.maxWidth > 760 ? 3 : (c.maxWidth > 460 ? 2 : 1);
              final w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final t in appThemes)
                    SizedBox(
                      width: w,
                      child: _ThemeCard(theme: t, selected: t.id == id, onTap: () => AppSettings.themeId.set(t.id)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
      const _Navigation(),
    ],
  );
}

/// Settings → Appearance: the navbar's sections in your order, each with a switch. Drag a row by
/// its handle or use the arrows; the rail and the phone's bar follow at once (the shell listens
/// to [NavLayout.changes]). Profile and settings aren't in the list: they can't be hidden.
class _Navigation extends StatelessWidget {
  const _Navigation();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: NavLayout.changes,
    builder: (context, _) {
      final list = NavLayout.all;
      final shown = NavLayout.visible;
      final accent = accentOf(context);
      void move(int from, int to) {
        final next = [...list];
        next.insert(to, next.removeAt(from));
        NavLayout.setOrder(next);
      }

      return _Section(
        title: 'Navigation',
        subtitle: 'The sections in the navbar, in order: top to bottom on the rail, left to right on a phone. '
            'Drag a row or use the arrows to move it; switch one off to hide it. '
            'VyseTV opens on the first one showing, and Back returns to it. Profile and settings are always there.',
        children: [
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: move,
            proxyDecorator: (child, _, _) => Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: VyseColors.surfaceHi,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: .35)),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
                ),
                child: child,
              ),
            ),
            itemBuilder: (context, i) {
              final on = shown.contains(list[i]);
              return _NavRow(
                key: ValueKey(list[i].id),
                item: list[i],
                index: i,
                count: list.length,
                on: on,
                first: list[i] == shown.first,
                // the last one showing stays: an empty navbar leads nowhere
                locked: on && shown.length == 1,
                onMove: (d) => move(i, i + d),
              );
            },
          ),
          _Row(
            title: 'Default order',
            subtitle: 'Home first and every section showing',
            trailing: _SmallButton(label: 'Reset', icon: Icons.restart_alt_rounded, onTap: NavLayout.reset),
          ),
        ],
      );
    },
  );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.item,
    required this.index,
    required this.count,
    required this.on,
    required this.first,
    required this.locked,
    required this.onMove,
  });
  final NavItem item;
  final int index;
  final int count;
  final bool on;

  /// The first one showing: where the app opens and where Back ends up.
  final bool first;

  /// The only one showing: its switch stays on.
  final bool locked;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final accent = accentOf(context);
    final phone = Layout.isPhone(context);
    final handle = ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Padding(
          padding: EdgeInsets.only(right: 10),
          child: Icon(Icons.drag_indicator_rounded, size: 20, color: VyseColors.textFaint),
        ),
      ),
    );
    final tint = on ? accent : VyseColors.textFaint;
    final badge = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: on ? accent.withValues(alpha: .16) : Colors.white.withValues(alpha: .06),
      ),
      child: item.glyph != null
          ? Text(item.glyph!, style: TextStyle(fontSize: 16, height: 1, fontWeight: FontWeight.w700, color: tint))
          : Icon(on ? item.activeIcon : item.icon, size: 18, color: tint),
    );
    final info = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(item.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim)),
        if (first) const _Kind('Opens first', Icons.flag_rounded),
        if (!on) const _Kind('Hidden', Icons.visibility_off_outlined),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Move up', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Move down', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 8),
        Tooltip(
          message: locked ? 'At least one section stays on' : (on ? 'Hide this section' : 'Show this section'),
          child: _Switch(value: on, color: accent, thumb: onAccentOf(context), onChanged: (v) => NavLayout.setOn(item, v)),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [handle, badge, const SizedBox(width: 14), Expanded(child: info)]),
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerRight, child: controls),
                  ],
                )
              : Row(children: [handle, badge, const SizedBox(width: 16), Expanded(child: info), const SizedBox(width: 16), controls]),
        ),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.theme, required this.selected, required this.onTap});
  final AppTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? theme.color : Colors.white.withValues(alpha: hovered ? .2 : .06),
          width: selected ? 1.5 : 1,
        ),
        boxShadow: selected ? [BoxShadow(color: theme.color.withValues(alpha: .25), blurRadius: 24, spreadRadius: -6)] : null,
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(colors: [theme.color, theme.color.withValues(alpha: .35), VyseColors.bg, theme.color]),
              border: Border.all(color: Colors.white.withValues(alpha: .15)),
            ),
            child: selected ? const Icon(Icons.check_rounded, size: 20, color: Colors.white) : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(theme.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(
                  theme.blurb,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlaybackTab extends StatelessWidget {
  const _PlaybackTab();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Section(
        title: 'Player',
        children: [
          _Row(
            title: 'Streaming mode',
            subtitle: "On: videos play right away from VyseTV's servers. Off: pick a source from your addons first",
            trailing: _Toggle(AppSettings.streamingMode),
          ),
          _Row(
            title: 'Autoplay the best source',
            subtitle: 'With streaming mode off: the Next episode button plays the best match from your addons. '
                'Nothing starts by itself, and opening a title still shows its sources first. '
                'What counts as best is yours to set: the Autoplay order below',
            trailing: _Toggle(AppSettings.autoplayBest),
          ),
          _Row(
            title: 'P2P streaming',
            subtitle: 'Play torrent sources. You connect directly to other people, who can see your IP address',
            trailing: _Toggle(AppSettings.p2pStreaming),
          ),
          _Row(title: 'Auto next episode', subtitle: 'Play the next episode when one ends', trailing: _Toggle(AppSettings.autoNext)),
          _Row(title: 'Auto-enable subtitles', subtitle: 'Turn on captions in your language when a video starts', trailing: _Toggle(AppSettings.autoSubtitles)),
          ValueListenableBuilder(
            valueListenable: AppSettings.seekSeconds,
            builder: (context, s, _) => _Row(
              title: 'Seek amount',
              subtitle: '${s}s per skip (← → in the player)',
              below: _Segmented<int>(setting: AppSettings.seekSeconds, options: const [5, 10, 15, 30], label: (v) => '${v}s'),
            ),
          ),
        ],
      ),
      const _AutoplayOrder(),
    ],
  );
}

/// Settings → Playback: your own order for "Autoplay the best source". Each step says what a
/// source has to be (a quality, a sound format, its channels; any of them left open), and the
/// first step your addons have something for is what plays.
class _AutoplayOrder extends StatelessWidget {
  const _AutoplayOrder();

  static const _example = [
    AutoplayStep(quality: '4K'),
    AutoplayStep(quality: '1080p', audio: 'Atmos', channels: '7.1'),
    AutoplayStep(quality: '1080p', audio: 'Dolby Digital', channels: '7.1'),
    AutoplayStep(quality: '1080p', channels: '5.1'),
    AutoplayStep(quality: '1080p'),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.autoplayOrder, AppSettings.autoplayRest]),
    builder: (context, _) {
      final steps = AutoplayOrder.steps;
      void move(int from, int to) {
        final next = [...steps];
        next.insert(to, next.removeAt(from));
        AutoplayOrder.save(next);
      }

      return _Section(
        title: 'Autoplay order',
        subtitle: 'What "Autoplay the best source" goes for, from the top down: the first step your addons have a source for plays, '
            "and if that one doesn't play, the next one down does. Leave a box on Any to take whatever it is. "
            'Dolby Digital also takes Dolby Digital+, and DTS takes DTS-HD.',
        children: [
          if (steps.isNotEmpty)
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: steps.length,
              onReorderItem: move,
              proxyDecorator: (child, _, _) => Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF151826),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
                    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
                  ),
                  child: child,
                ),
              ),
              itemBuilder: (context, i) => _StepRow(
                key: ValueKey('$i ${steps[i].label}'),
                step: steps[i],
                index: i,
                count: steps.length,
                onChange: (s) => AutoplayOrder.save([...steps]..[i] = s),
                onMove: (d) => move(i, i + d),
                onRemove: () => AutoplayOrder.save([...steps]..removeAt(i)),
              ),
            ),
          _Row(
            title: steps.isEmpty ? 'No steps yet' : 'Another step',
            subtitle: steps.isEmpty ? 'Autoplay decides by itself: 4K first, then the best sound' : 'It goes at the bottom: set it, then move it to where it belongs',
            trailing: _SmallButton(label: 'Add a step', icon: Icons.add_rounded, primary: steps.isEmpty, onTap: () => AutoplayOrder.save([...steps, const AutoplayStep()])),
          ),
          if (steps.isEmpty)
            _Row(
              title: 'Start from an example',
              subtitle: '4K, then 1080p with Atmos 7.1, then with Dolby Digital 7.1, then with 5.1, then any 1080p',
              trailing: _SmallButton(label: 'Use it', icon: Icons.auto_awesome_rounded, onTap: () => AutoplayOrder.save(_example)),
            )
          else ...[
            _Row(
              title: 'When no step has a source',
              subtitle: 'On: play the best of what there is. Off: open the sources list to pick from',
              trailing: _Toggle(AppSettings.autoplayRest),
            ),
            _Row(
              title: 'Clear the order',
              subtitle: 'Back to deciding by itself',
              trailing: _SmallButton(label: 'Clear', icon: Icons.restart_alt_rounded, onTap: () => AutoplayOrder.save(const [])),
            ),
          ],
        ],
      );
    },
  );
}

class _StepRow extends StatelessWidget {
  const _StepRow({super.key, required this.step, required this.index, required this.count, required this.onChange, required this.onMove, required this.onRemove});
  final AutoplayStep step;
  final int index;
  final int count;
  final ValueChanged<AutoplayStep> onChange;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = step;
    final phone = Layout.isPhone(context);
    final handle = ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Padding(
          padding: EdgeInsets.only(right: 10),
          child: Icon(Icons.drag_indicator_rounded, size: 20, color: VyseColors.textFaint),
        ),
      ),
    );
    final badge = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: VyseColors.accent.withValues(alpha: .16)),
      child: Text('${index + 1}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: VyseColors.accent)),
    );
    final picks = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StepPick(
          any: 'Any quality',
          value: s.quality,
          options: AutoplayStep.qualities,
          onPick: (v) => onChange(AutoplayStep(quality: v, audio: s.audio, channels: s.channels)),
        ),
        _StepPick(
          any: 'Any sound',
          value: s.audio,
          options: AutoplayStep.audios,
          label: (a) => a == 'Atmos' ? 'Dolby Atmos' : a,
          onPick: (v) => onChange(AutoplayStep(quality: s.quality, audio: v, channels: s.channels)),
        ),
        _StepPick(
          any: 'Any channels',
          value: s.channels,
          options: AutoplayStep.layouts,
          label: (c) => c == '2.0' ? 'Stereo' : c,
          onPick: (v) => onChange(AutoplayStep(quality: s.quality, audio: s.audio, channels: v)),
        ),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Try it sooner', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Try it later', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 4),
        _IconAction(icon: Icons.close_rounded, tooltip: 'Remove this step', danger: true, onTap: onRemove),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [handle, badge, const SizedBox(width: 14), Expanded(child: picks)]),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: controls),
                  ],
                )
              : Row(children: [handle, badge, const SizedBox(width: 16), Expanded(child: picks), const SizedBox(width: 16), controls]),
        ),
      ],
    );
  }
}

/// One part of a step: a menu of what it can ask for, with "Any" on top.
class _StepPick extends StatelessWidget {
  const _StepPick({required this.any, required this.value, required this.options, required this.onPick, this.label});
  final String any;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onPick;
  final String Function(String)? label;

  String _name(String o) => label?.call(o) ?? o;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '',
    color: VyseColors.surfaceHi,
    initialValue: value ?? '',
    onSelected: (v) => onPick(v.isEmpty ? null : v),
    itemBuilder: (_) => [
      PopupMenuItem(value: '', height: 38, child: Text(any)),
      for (final o in options) PopupMenuItem(value: o, height: 38, child: Text(_name(o))),
    ],
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      decoration: BoxDecoration(
        color: value == null ? Colors.white.withValues(alpha: .06) : VyseColors.accent.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value == null ? any : _name(value!),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: value == null ? VyseColors.textDim : VyseColors.text),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
        ],
      ),
    ),
  );
}

const _languages = [
  'English',
  'Arabic',
  'French',
  'Spanish',
  'German',
  'Italian',
  'Portuguese',
  'Turkish',
  'Dutch',
  'Russian',
  'Japanese',
  'Korean',
  'Chinese',
  'Hindi',
  'Indonesian',
  'Polish',
  'Swedish',
];
const _captionColors = captionColors;

class _SubtitlesTab extends StatelessWidget {
  const _SubtitlesTab();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Section(
        title: 'Language',
        children: [
          _Row(
            title: 'Default language',
            subtitle: "If a video doesn't have it, no subtitles are loaded.",
            trailing: ValueListenableBuilder(
              valueListenable: AppSettings.subtitleLanguage,
              builder: (context, lang, _) => PopupMenuButton<String>(
                tooltip: '',
                color: VyseColors.surfaceHi,
                initialValue: lang,
                onSelected: AppSettings.subtitleLanguage.set,
                itemBuilder: (_) => [for (final l in _languages) PopupMenuItem(value: l, height: 38, child: Text(l))],
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: .07), borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(lang, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 6),
                      const Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      _Section(
        title: 'Caption style',
        subtitle: "Drawn by the player's subtitle engine (libass), so the preview is close but not exact.",
        children: [
          const Padding(padding: EdgeInsets.only(top: 18, bottom: 4), child: _SubtitlePreview()),
          _Row(
            title: 'Font',
            subtitle: 'Go Noto covers every language. Other fonts fall back to it for letters they lack.',
            trailing: const _FontButton(),
          ),
          _Row(title: 'Bold', trailing: _Toggle(AppSettings.subtitleBold)),
          _Row(title: 'Italic', trailing: _Toggle(AppSettings.subtitleItalic)),
          ValueListenableBuilder(
            valueListenable: AppSettings.subtitleSize,
            builder: (context, size, _) => _Row(
              title: 'Text size',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RoundIcon(icon: Icons.remove_rounded, onTap: size > captionSizeMin ? () => AppSettings.subtitleSize.set(size - captionSizeStep) : null),
                  SizedBox(
                    width: 62,
                    child: Text(
                      '${size}px',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _RoundIcon(icon: Icons.add_rounded, onTap: size < captionSizeMax ? () => AppSettings.subtitleSize.set(size + captionSizeStep) : null),
                ],
              ),
            ),
          ),
          _Row(title: 'Text colour', trailing: _Swatches(setting: AppSettings.subtitleColor, colors: _captionColors)),
          _Row(
            title: 'Letter spacing',
            trailing: _Stepper(setting: AppSettings.subtitleSpacing, min: -20, max: 50, step: 5, label: (v) => v == 0 ? 'Normal' : _tenths(v)),
          ),
        ],
      ),
      _Section(
        title: 'Background box',
        children: [
          _Row(
            title: 'Box',
            subtitle: 'A box behind the text. With no box, the outline and shadow below are used.',
            below: _Segmented<int>(setting: AppSettings.subtitleBackground, options: captionBoxLevels, label: (v) => v == 0 ? 'None' : '$v%'),
          ),
          _Row(title: 'Box colour', trailing: _Swatches(setting: AppSettings.subtitleBackColor, colors: _boxColors)),
        ],
      ),
      ValueListenableBuilder(
        valueListenable: AppSettings.subtitleBackground,
        builder: (context, back, _) => _Section(
          title: 'Outline & shadow',
          subtitle: back > 0 ? 'Turn the background box off to use these.' : null,
          children: [
            _Row(
              title: 'Outline',
              trailing: _Stepper(setting: AppSettings.subtitleOutline, min: 0, max: 80, step: 5, label: (v) => v == 0 ? 'None' : _tenths(v)),
            ),
            _Row(title: 'Outline colour', trailing: _Swatches(setting: AppSettings.subtitleOutlineColor, colors: _outlineColors)),
            _Row(
              title: 'Shadow',
              trailing: _Stepper(setting: AppSettings.subtitleShadow, min: 0, max: 60, step: 5, label: (v) => v == 0 ? 'None' : _tenths(v)),
            ),
            _Row(
              title: 'Shadow strength',
              below: _Segmented<int>(
                setting: AppSettings.subtitleShadowColor,
                options: const [0x60000000, 0xA0000000, 0xFF000000],
                label: (v) => switch (v) { 0x60000000 => 'Soft', 0xA0000000 => 'Medium', _ => 'Strong' },
              ),
            ),
            _Row(
              title: 'Soft edges',
              subtitle: 'Blurs the outline a little',
              trailing: _Stepper(setting: AppSettings.subtitleBlur, min: 0, max: 30, step: 5, label: (v) => v == 0 ? 'Off' : _tenths(v)),
            ),
          ],
        ),
      ),
      _Section(
        title: 'Position',
        children: [
          _Row(
            title: 'Place at',
            trailing: _Segmented<bool>(setting: AppSettings.subtitleTop, options: const [false, true], label: (v) => v ? 'Top' : 'Bottom'),
          ),
          _Row(
            title: 'Distance from the edge',
            subtitle: "Of the screen's height. Bottom subtitles still move up while the controls show.",
            trailing: _Stepper(setting: AppSettings.subtitleLift, min: 0, max: 45, step: 1, label: (v) => v == 0 ? 'Edge' : '$v%'),
          ),
          _Row(
            title: 'Keep on the picture',
            subtitle: "Never put subtitles in a film's black bars",
            trailing: _Toggle(AppSettings.subtitleOnPicture),
          ),
        ],
      ),
      ValueListenableBuilder(
        valueListenable: AppSettings.subtitleAss,
        builder: (context, mode, _) => _Section(
          title: 'Styled subtitles',
          subtitle: 'Anime fansubs (ASS/SSA) often bring their own fonts, colours, signs and karaoke.',
          children: [
            _Row(
              title: 'Show them',
              subtitle: switch (mode) {
                'force' => 'Your font and colours on everything. Signs and karaoke can look wrong.',
                'strip' => 'Plain text in your style: no signs, karaoke or positions.',
                _ => 'As their makers styled them, only scaled to the screen.',
              },
              below: _Segmented<String>(
                setting: AppSettings.subtitleAss,
                options: const ['scale', 'force', 'strip'],
                label: (v) => switch (v) { 'force' => 'Use my style', 'strip' => 'Plain', _ => 'Keep as made' },
              ),
            ),
          ],
        ),
      ),
      _Section(
        title: 'Reset',
        children: [
          _Row(
            title: 'Caption style',
            subtitle: 'Back to how VyseTV draws subtitles out of the box',
            trailing: _SmallButton(label: 'Reset', icon: Icons.restart_alt_rounded, onTap: _resetCaptionStyle),
          ),
        ],
      ),
    ],
  );
}

String _tenths(int v) => (v / 10).toStringAsFixed(v % 10 == 0 ? 0 : 1);

const _boxColors = [0xFF000000, 0xFF14161F, 0xFF1A2440, 0xFF3A3A3A, 0xFF3D1A1A];
const _outlineColors = [0xFF000000, 0xFF1A2440, 0xFF3D1A1A, 0xFF5B4600, 0xFFFFFFFF];

void _resetCaptionStyle() {
  AppSettings.subtitleSize.set(AppSettings.subtitleSize.fallback);
  AppSettings.subtitleColor.set(AppSettings.subtitleColor.fallback);
  AppSettings.subtitleBackground.set(AppSettings.subtitleBackground.fallback);
  AppSettings.subtitleFont.set(AppSettings.subtitleFont.fallback);
  AppSettings.subtitleBold.set(AppSettings.subtitleBold.fallback);
  AppSettings.subtitleItalic.set(AppSettings.subtitleItalic.fallback);
  AppSettings.subtitleBackColor.set(AppSettings.subtitleBackColor.fallback);
  AppSettings.subtitleOutline.set(AppSettings.subtitleOutline.fallback);
  AppSettings.subtitleOutlineColor.set(AppSettings.subtitleOutlineColor.fallback);
  AppSettings.subtitleShadow.set(AppSettings.subtitleShadow.fallback);
  AppSettings.subtitleShadowColor.set(AppSettings.subtitleShadowColor.fallback);
  AppSettings.subtitleBlur.set(AppSettings.subtitleBlur.fallback);
  AppSettings.subtitleSpacing.set(AppSettings.subtitleSpacing.fallback);
  AppSettings.subtitleTop.set(AppSettings.subtitleTop.fallback);
  AppSettings.subtitleLift.set(AppSettings.subtitleLift.fallback);
  AppSettings.subtitleOnPicture.set(AppSettings.subtitleOnPicture.fallback);
  AppSettings.subtitleAss.set(AppSettings.subtitleAss.fallback);
}

/// A row of colour dots for a colour setting.
class _Swatches extends StatelessWidget {
  const _Swatches({required this.setting, required this.colors});
  final Setting<int> setting;
  final List<int> colors;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: setting,
    builder: (context, value, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in colors)
          Pressable(
            onTap: () => setting.set(c),
            builder: (context, hovered, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(left: 8),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: c == value ? VyseColors.accent : Colors.white.withValues(alpha: hovered ? .5 : .14),
                  width: c == value ? 3 : 1.5,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// − value + for an int setting.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.setting, required this.min, required this.max, required this.step, required this.label});
  final Setting<int> setting;
  final int min, max, step;
  final String Function(int) label;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: setting,
    builder: (context, v, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundIcon(icon: Icons.remove_rounded, onTap: v > min ? () => setting.set((v - step).clamp(min, max)) : null),
        SizedBox(
          width: 70,
          child: Text(label(v), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        _RoundIcon(icon: Icons.add_rounded, onTap: v < max ? () => setting.set((v + step).clamp(min, max)) : null),
      ],
    ),
  );
}

/// How the subtitles will look, drawn by Flutter from the same settings libass gets.
class _SubtitlePreview extends StatelessWidget {
  const _SubtitlePreview();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(SubtitleStyle.settings),
    builder: (context, _) {
      const h = 190.0;
      final size = AppSettings.subtitleSize.value * .8;
      final back = AppSettings.subtitleBackground.value;
      final box = back > 0;
      final top = AppSettings.subtitleTop.value;
      final edge = 14 + AppSettings.subtitleLift.value / 100 * h;
      final outline = box ? 0.0 : AppSettings.subtitleOutline.value / 10 * 1.2;
      final shadow = box ? 0.0 : AppSettings.subtitleShadow.value / 10 * 1.2;
      final blur = AppSettings.subtitleBlur.value / 10 * 1.5;
      final base = TextStyle(
        fontFamily: SubtitleStyle.choiceFor(AppSettings.subtitleFont.value).preview,
        fontSize: size,
        height: 1.25,
        fontWeight: AppSettings.subtitleBold.value ? FontWeight.w700 : FontWeight.w400,
        fontStyle: AppSettings.subtitleItalic.value ? FontStyle.italic : FontStyle.normal,
        letterSpacing: AppSettings.subtitleSpacing.value / 10 * 1.2,
      );
      const sample = 'This is how subtitles will look';
      Widget text = Stack(
        children: [
          if (outline > 0)
            Text(
              sample,
              textAlign: TextAlign.center,
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = outline * 2
                  ..strokeJoin = StrokeJoin.round
                  ..color = Color(AppSettings.subtitleOutlineColor.value)
                  ..maskFilter = blur > 0 ? MaskFilter.blur(BlurStyle.normal, blur) : null,
              ),
            ),
          Text(
            sample,
            textAlign: TextAlign.center,
            style: base.copyWith(
              color: Color(AppSettings.subtitleColor.value),
              shadows: shadow > 0 ? [Shadow(offset: Offset(shadow, shadow), blurRadius: blur, color: Color(AppSettings.subtitleShadowColor.value))] : null,
            ),
          ),
        ],
      );
      if (box) {
        text = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Color(AppSettings.subtitleBackColor.value).withValues(alpha: back / 100),
            borderRadius: BorderRadius.circular(6),
          ),
          child: text,
        );
      }
      return Container(
        height: h,
        alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
        padding: EdgeInsets.only(top: top ? edge : 0, bottom: top ? 0 : edge, left: 16, right: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(colors: [Color(0xFF2A1F3D), Color(0xFF16263A), Color(0xFF3A1F1F)]),
        ),
        child: text,
      );
    },
  );
}

/// The current font; opens the font list.
class _FontButton extends StatelessWidget {
  const _FontButton();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: AppSettings.subtitleFont,
    builder: (context, family, _) {
      final choice = SubtitleStyle.choiceFor(family);
      return Pressable(
        onTap: () => _pickFont(context),
        builder: (context, hovered, _) => Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .11 : .07), borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  choice.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: choice.preview, fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
            ],
          ),
        ),
      );
    },
  );

  static Future<void> _pickFont(BuildContext context) async {
    final picked = await showDialog<String>(context: context, builder: (_) => const _FontDialog());
    if (picked == null) return;
    AppSettings.subtitleFont.set(picked == SubtitleStyle.defaultFamily ? '' : picked);
  }
}

class _FontDialog extends StatefulWidget {
  const _FontDialog();

  @override
  State<_FontDialog> createState() => _FontDialogState();
}

class _FontDialogState extends State<_FontDialog> {
  final _search = TextEditingController();
  late final Future<List<SubtitleFontChoice>> _fonts = SubtitleStyle.available();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = SubtitleStyle.family;
    return Dialog(
      backgroundColor: VyseColors.surfaceHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: VyseColors.stroke)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Subtitle font', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search fonts',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: .06),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: FutureBuilder<List<SubtitleFontChoice>>(
                  future: _fonts,
                  builder: (context, snap) {
                    final q = _search.text.trim().toLowerCase();
                    final list = [for (final f in snap.data ?? const <SubtitleFontChoice>[]) if (q.isEmpty || f.name.toLowerCase().contains(q)) f];
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                    return ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final f = list[i];
                        final on = f.family == current;
                        return Pressable(
                          onTap: () => Navigator.of(context).pop(f.family),
                          builder: (context, hovered, _) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                            decoration: BoxDecoration(
                              color: on ? VyseColors.accent.withValues(alpha: .14) : Colors.white.withValues(alpha: hovered ? .06 : 0),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    f.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontFamily: f.preview, fontSize: 15, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                                  ),
                                ),
                                if (on) const Icon(Icons.check_rounded, size: 18, color: VyseColors.accent),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: onTap == null ? .03 : (hovered ? .16 : .08)),
      ),
      child: Icon(icon, size: 18, color: onTap == null ? VyseColors.textFaint : VyseColors.text),
    ),
  );
}

class _AboutTab extends StatelessWidget {
  const _AboutTab();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListenableBuilder(
        listenable: Updater.instance,
        builder: (context, _) {
          final up = Updater.instance;
          final newer = up.newer;
          return _Section(
            title: 'VyseTV',
            children: [
              _Row(
                title: 'Version',
                trailing: Text(
                  up.current.isEmpty ? '…' : up.current,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: VyseColors.textDim),
                ),
              ),
              _Row(
                title: 'Updates',
                subtitle: switch (up.stage) {
                  UpdateStage.checking => 'Checking…',
                  UpdateStage.failed => up.error ?? "Couldn't check for updates.",
                  _ when newer != null => 'Version ${newer.version} is ready',
                  UpdateStage.upToDate => "You're on the newest version",
                  _ => 'Not checked yet',
                },
                trailing: _SmallButton(
                  label: newer != null ? 'Update' : 'Check now',
                  icon: newer != null ? Icons.system_update_alt_rounded : Icons.refresh_rounded,
                  primary: newer != null,
                  onTap: () async {
                    if (up.busy) return;
                    if (up.newer == null) await up.check();
                    if (up.newer != null && context.mounted) await showUpdateDialog(context);
                  },
                ),
              ),
              _Row(
                title: 'Check automatically',
                subtitle: 'Looks for a new version when VyseTV starts, and tells you',
                trailing: _Toggle(AppSettings.updateAuto),
              ),
              const _Row(title: 'Movies, Music, Manga, Audiobooks and Live TV', subtitle: 'Everything you watch, read and listen to in one place.'),
            ],
          );
        },
      ),
      _Section(
        title: 'Community',
        children: [
          _Row(
            title: 'Discord',
            subtitle: 'News, help and a place to say what you want next.',
            trailing: _SmallButton(label: 'Join', icon: Icons.open_in_new_rounded, onTap: () => openDiscord(context)),
          ),
        ],
      ),
    ],
  );
}

class _DangerTab extends StatelessWidget {
  const _DangerTab();

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: VyseColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          content: Text(body, style: const TextStyle(color: VyseColors.textDim)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action, style: const TextStyle(color: _danger, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ) ??
      false;

  static void _done(BuildContext context, String message, IconData icon) {
    if (context.mounted) showToast(context, Text(message, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: icon);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Section(
        title: 'Reset',
        children: [
          _Row(
            title: 'Reset preferences',
            subtitle: 'Appearance, home, playback, subtitle and sync settings go back to defaults. Your name, avatar and addons stay.',
            trailing: _SmallButton(
              label: 'Reset',
              danger: true,
              onTap: () async {
                if (!await _confirm(context, 'Reset preferences?', 'Every setting goes back to its default. Your name, avatar and addons stay.', 'Reset')) return;
                AppSettings.resetPreferences();
                if (context.mounted) _done(context, 'Preferences reset', Icons.restart_alt_rounded);
              },
            ),
          ),
          _Row(
            title: 'Clear manga reading history',
            subtitle: 'Empties Continue reading and forgets every saved page.',
            trailing: _SmallButton(
              label: 'Clear',
              danger: true,
              onTap: () async {
                final all = await MangaHistory.load();
                if (!context.mounted) return;
                if (all.isEmpty) return _done(context, 'No reading history to clear', Icons.menu_book_rounded);
                if (!await _confirm(context, 'Clear reading history?', 'Continue reading will be empty (${all.length} ${all.length == 1 ? 'title' : 'titles'}).', 'Clear')) return;
                for (final p in all) {
                  await MangaHistory.remove(p.manga);
                }
                if (context.mounted) _done(context, 'Reading history cleared', Icons.menu_book_rounded);
              },
            ),
          ),
        ],
      ),
      ValueListenableBuilder(
        valueListenable: Account.user,
        builder: (context, u, _) => u == null
            ? const SizedBox.shrink()
            : _Section(
                title: 'Account',
                children: [
                  _Row(
                    title: 'Delete account',
                    subtitle: 'Deletes @${u.username} with your profile, friends, messages and synced data. This can\'t be undone.',
                    trailing: _SmallButton(
                      label: 'Delete',
                      danger: true,
                      onTap: () async {
                        final gone = await showDialog<bool>(context: context, builder: (_) => const _DeleteAccountDialog());
                        if (gone == true && context.mounted) _done(context, 'Account deleted', Icons.person_off_rounded);
                      },
                    ),
                  ),
                ],
              ),
      ),
    ],
  );
}

/// Asks for the password before the account is deleted for good.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await Account.deleteAccount(_password.text);
    if (!mounted) return;
    if (problem == null) return Navigator.pop(context, true);
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: VyseColors.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: const Text('Delete your account?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Your profile, friends, messages and everything synced to your account are deleted from the server. What's saved on this device stays.",
            style: TextStyle(color: VyseColors.textDim, height: 1.35),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _delete(),
            cursorColor: VyseColors.accent,
            decoration: InputDecoration(
              hintText: 'Your password',
              hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 14),
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
      TextButton(
        onPressed: _busy || _password.text.isEmpty ? null : _delete,
        child: Text(
          _busy ? 'Deleting…' : 'Delete for good',
          style: TextStyle(color: _busy || _password.text.isEmpty ? VyseColors.textFaint : _danger, fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

// ───────────────────────── Addons ─────────────────────────

class _AddonsTab extends StatefulWidget {
  const _AddonsTab();

  @override
  State<_AddonsTab> createState() => _AddonsTabState();
}

class _AddonsTabState extends State<_AddonsTab> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    Addons.start();
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final text = _link.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final a = await Addons.install(text);
      _link.clear();
      _failed = false;
      _message = '${a.name} is installed${a.streams && a.subtitles ? ' (sources and subtitles)' : a.streams ? ' (sources)' : ' (subtitles)'}.';
    } catch (e) {
      _failed = true;
      _message = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _Section(
        title: 'Add an addon',
        subtitle: 'Paste a Stremio addon link. Stream addons fill the sources screen (Streaming mode off in Playback); '
            'subtitle addons add their files to every video.',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _link,
                        enabled: !_busy,
                        onSubmitted: (_) => _install(),
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'https://…/manifest.json  or  stremio://…',
                          hintStyle: const TextStyle(color: VyseColors.textFaint),
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .05),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          prefixIcon: const Icon(Icons.link_rounded, size: 18, color: VyseColors.textDim),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: VyseColors.stroke)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: VyseColors.stroke)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _busy
                        ? const SizedBox(width: 92, child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))))
                        : _SmallButton(label: 'Install', icon: Icons.add_rounded, primary: true, onTap: _install),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_failed ? Icons.error_outline_rounded : Icons.check_circle_rounded, size: 16, color: _failed ? _danger : const Color(0xFF3DDC97)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_message!, style: TextStyle(fontSize: 13, color: _failed ? _danger : VyseColors.textDim, height: 1.35))),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      ValueListenableBuilder<List<Addon>>(
        valueListenable: Addons.list,
        builder: (context, list, _) => _Section(
          title: 'Your addons',
          subtitle: list.isEmpty
              ? null
              : 'Sources are listed in this order. Torrent results play with P2P streaming (Playback) or your debrid service (Debrid).',
          children: list.isEmpty
              ? const [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text('No addons yet. Paste one above.', style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
                  ),
                ]
              : [for (final (i, a) in list.indexed) _AddonRow(addon: a, first: i == 0, last: i == list.length - 1)],
        ),
      ),
    ],
  );
}

class _AddonRow extends StatelessWidget {
  const _AddonRow({required this.addon, required this.first, required this.last});
  final Addon addon;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final a = addon;
    final phone = Layout.isPhone(context);
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: SizedBox.square(
        dimension: 46,
        child: a.logo == null
            ? _Initial(a.name)
            : CachedNetworkImage(imageUrl: a.logo!, fit: BoxFit.cover, errorWidget: (_, _, _) => _Initial(a.name)),
      ),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Move up', onTap: first ? null : () => Addons.move(a, -1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Move down', onTap: last ? null : () => Addons.move(a, 1)),
        if (a.configureUrl != null)
          _IconAction(
            icon: Icons.tune_rounded,
            tooltip: 'Configure (then paste the new link above)',
            onTap: () => launchUrl(Uri.parse(a.configureUrl!), mode: LaunchMode.externalApplication),
          ),
        // a built-in addon is part of the app: it is turned off, not removed
        if (!a.builtIn) _IconAction(icon: Icons.delete_outline_rounded, tooltip: 'Remove', danger: true, onTap: () => Addons.remove(a)),
        const SizedBox(width: 8),
        _Switch(value: a.enabled, onChanged: (on) => Addons.setEnabled(a, on)),
      ],
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(a.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: a.enabled ? VyseColors.text : VyseColors.textDim)),
            if (a.version.isNotEmpty) Text('v${a.version}', style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
            if (a.builtIn) const _Kind('Built in', Icons.verified_outlined),
            if (a.streams) const _Kind('Sources', Icons.play_circle_outline_rounded),
            if (a.subtitles) const _Kind('Subtitles', Icons.closed_caption_outlined),
          ],
        ),
        if (a.description.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(a.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [logo, const SizedBox(width: 14), Expanded(child: info)]),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: controls),
              ],
            )
          : Row(
              children: [
                logo,
                const SizedBox(width: 16),
                Expanded(child: info),
                const SizedBox(width: 16),
                controls,
              ],
            ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: VyseColors.accent.withValues(alpha: .18),
    child: Center(
      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
    ),
  );
}

class _Kind extends StatelessWidget {
  const _Kind(this.label, this.icon);
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: .07), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: VyseColors.textDim),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
      ],
    ),
  );
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.tooltip, required this.onTap, this.danger = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Pressable(
      onTap: onTap ?? () {},
      builder: (context, hovered, _) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: onTap != null && hovered ? (danger ? _danger.withValues(alpha: .14) : Colors.white.withValues(alpha: .08)) : Colors.transparent,
        ),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null ? VyseColors.textFaint.withValues(alpha: .4) : (danger && hovered ? _danger : VyseColors.textDim),
        ),
      ),
    ),
  );
}

// ── Sources ──

/// Settings → Sources: the film and TV sources in the order the player asks them, each with a
/// switch. Drag a row by its handle or use the arrows; the order is saved and synced.
class _SourcesTab extends StatelessWidget {
  const _SourcesTab();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.sourceOrder, AppSettings.sourcesOff]),
    builder: (context, _) {
      final list = orderedFilmSources();
      final firstOn = list.indexWhere(filmSourceOn);
      final onCount = list.where(filmSourceOn).length;
      void save(int from, int to) {
        final next = [...list];
        next.insert(to, next.removeAt(from));
        setFilmSourceOrder(next);
      }

      return _Section(
        title: 'Film and TV sources',
        subtitle: 'When a film or episode starts these are asked from the top down, and the first to answer plays. '
            'Drag a row or use the arrows to change the order; switch one off to skip it. Anime has servers of its own.',
        children: [
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: save,
            proxyDecorator: (child, _, _) => Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF151826),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
                ),
                child: child,
              ),
            ),
            itemBuilder: (context, i) => _SourceRow(
              key: ValueKey(list[i].id),
              source: list[i],
              index: i,
              count: list.length,
              first: i == firstOn,
              // the last one on stays on: with none, nothing would play
              locked: onCount == 1 && filmSourceOn(list[i]),
              onMove: (d) => save(i, i + d),
            ),
          ),
          _Row(
            title: 'Default order',
            subtitle: 'Movy first and every source on',
            trailing: _SmallButton(
              label: 'Reset',
              icon: Icons.restart_alt_rounded,
              onTap: () {
                AppSettings.sourceOrder.set('');
                AppSettings.sourcesOff.set('');
              },
            ),
          ),
        ],
      );
    },
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.source,
    required this.index,
    required this.count,
    required this.first,
    required this.locked,
    required this.onMove,
  });
  final FilmSource source;
  final int index;
  final int count;
  final bool first;
  final bool locked;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final s = source;
    final on = filmSourceOn(s);
    final phone = Layout.isPhone(context);
    final handle = ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Padding(
          padding: EdgeInsets.only(right: 10),
          child: Icon(Icons.drag_indicator_rounded, size: 20, color: VyseColors.textFaint),
        ),
      ),
    );
    final badge = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: on ? VyseColors.accent.withValues(alpha: .16) : Colors.white.withValues(alpha: .06),
      ),
      child: Text(
        '${index + 1}',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: on ? VyseColors.accent : VyseColors.textFaint),
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(s.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim)),
            if (first) const _Kind('Asked first', Icons.bolt_rounded),
            if (s.filmsOnly) const _Kind('Films only', Icons.movie_outlined),
            if (s.showsOnly) const _Kind('Shows only', Icons.live_tv_rounded),
            if (!on) const _Kind('Off', Icons.block_rounded),
          ],
        ),
        const SizedBox(height: 4),
        Text(s.note, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Move up', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Move down', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 8),
        Tooltip(
          message: locked ? 'At least one source stays on' : (on ? 'Skip this source' : 'Use this source'),
          child: _Switch(value: on, onChanged: (v) => locked ? null : setFilmSourceOn(s, v)),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: phone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [handle, badge, const SizedBox(width: 14), Expanded(child: info)]),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: controls),
                  ],
                )
              : Row(children: [handle, badge, const SizedBox(width: 16), Expanded(child: info), const SizedBox(width: 16), controls]),
        ),
      ],
    );
  }
}

// ───────────────────────── Debrid ─────────────────────────

/// Settings → Debrid: pick a service, paste its key (checked with the service, kept in the
/// keychain), and torrents play from its servers instead of peer to peer.
class _DebridTab extends StatefulWidget {
  const _DebridTab();

  @override
  State<_DebridTab> createState() => _DebridTabState();
}

class _DebridTabState extends State<_DebridTab> {
  final _key = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _message;
  bool _failed = false;
  String? _account; // who the saved key belongs to

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = Debrid.provider;
    _key.clear();
    _account = null;
    _message = null;
    if (p == null) {
      if (mounted) setState(() {});
      return;
    }
    final k = await Debrid.keyOf(p) ?? '';
    if (!mounted || Debrid.provider != p) return;
    setState(() => _key.text = k);
    if (k.isEmpty) return;
    final user = await Debrid.verify(p, k);
    if (!mounted || Debrid.provider != p) return;
    setState(() {
      _account = user == null ? null : Debrid.describe(user);
      _failed = user == null;
      _message = user == null ? "${p.label} didn't accept the saved key. Paste a new one." : null;
    });
  }

  void _pick(DebridProvider? p) {
    AppSettings.debridProvider.set(p?.id ?? '');
    _load();
  }

  Future<void> _save() async {
    final p = Debrid.provider;
    final k = _key.text.trim();
    if (p == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    if (k.isEmpty) {
      await Debrid.saveKey(p, '');
      _account = null;
      _failed = false;
      _message = 'Key removed.';
    } else {
      final user = await Debrid.verify(p, k);
      if (user == null) {
        _failed = true;
        _message = "${p.label} didn't accept that key. Check you copied all of it.";
      } else {
        await Debrid.saveKey(p, k);
        _failed = false;
        _account = Debrid.describe(user);
        _message = 'Connected to ${p.label}.';
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppSettings.debridProvider, AppSettings.debridOn, Debrid.keyed]),
    builder: (context, _) {
      final p = Debrid.provider;
      return Column(
        children: [
          _Section(
            title: 'Service',
            subtitle: 'A debrid service downloads the torrent on its own servers and streams it to you over HTTPS. Nothing is shared peer to peer from your device.',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in <DebridProvider?>[null, ...DebridProvider.values])
                      Pressable(
                        onTap: () => _pick(o),
                        builder: (context, hovered, _) {
                          final on = o == p;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: on ? Colors.white.withValues(alpha: .16) : Colors.white.withValues(alpha: hovered ? .08 : .04),
                              border: Border.all(color: on ? VyseColors.accent.withValues(alpha: .6) : VyseColors.stroke),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(o?.label ?? 'None', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim)),
                              if (o != null && Debrid.keyed.value.contains(o)) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.check_circle_rounded, size: 15, color: Color(0xFF3DDC97)),
                              ],
                            ]),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (p != null)
            _Section(
              title: '${p.label} key',
              subtitle: "Kept in this device's keychain. It never goes to your VyseTV account.",
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _key,
                              enabled: !_busy,
                              obscureText: !_show,
                              onSubmitted: (_) => _save(),
                              onChanged: (_) => setState(() {}),
                              style: const TextStyle(fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'Paste your ${p.label} API key',
                                hintStyle: const TextStyle(color: VyseColors.textFaint),
                                isDense: true,
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: .05),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                                prefixIcon: const Icon(Icons.key_rounded, size: 18, color: VyseColors.textDim),
                                suffixIcon: IconButton(
                                  tooltip: _show ? 'Hide' : 'Show',
                                  iconSize: 18,
                                  color: VyseColors.textDim,
                                  onPressed: () => setState(() => _show = !_show),
                                  icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                                ),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: VyseColors.stroke)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: VyseColors.stroke)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7))),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _busy
                              ? const SizedBox(width: 92, child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))))
                              : _SmallButton(
                                  label: _key.text.trim().isEmpty && Debrid.keyed.value.contains(p) ? 'Remove' : 'Save',
                                  icon: Icons.check_rounded,
                                  primary: true,
                                  onTap: _save,
                                ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(children: [
                        Pressable(
                          onTap: () => launchUrl(Uri.parse(p.keyPage), mode: LaunchMode.externalApplication),
                          builder: (context, hovered, _) => Text(
                            'Get your key from ${p.label} ↗',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : VyseColors.accent),
                          ),
                        ),
                        const Spacer(),
                        if (_account != null)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF3DDC97)),
                            const SizedBox(width: 6),
                            Text(_account!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
                          ]),
                      ]),
                      if (_message != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(_failed ? Icons.error_outline_rounded : Icons.check_circle_rounded, size: 16, color: _failed ? _danger : const Color(0xFF3DDC97)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(_message!, style: TextStyle(fontSize: 13, color: _failed ? _danger : VyseColors.textDim, height: 1.35))),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          _Section(
            title: 'Streaming',
            children: [
              _Row(
                title: 'Play torrents through debrid',
                subtitle: Debrid.active
                    ? 'On: torrents play from ${Debrid.name} instead of peer to peer. In a watch party you host, everyone streams your link.'
                    : p == null
                    ? 'Pick a service and save its key first.'
                    : !Debrid.keyed.value.contains(p)
                    ? 'Save your ${p.label} key first.'
                    : 'Off: torrents play peer to peer (when P2P streaming is allowed in Playback).',
                trailing: _Toggle(AppSettings.debridOn),
              ),
            ],
          ),
        ],
      );
    },
  );
}
