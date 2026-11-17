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
import '../data/playback_prefs.dart';
import '../data/updater.dart';
import '../widgets/refract_import_dialog.dart';
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

Color get _card => VyseColors.pick(0xFF0D0F18, 0xFFF7F8FC);
const _danger = Color(0xFFF26B6B);

enum _Tab {
  account('Profilo', 'Il tuo nome, l\'avatar e AniList.', Icons.person_outline_rounded),
  party('Profilo Party', 'Come ti vedono tutti nel Party.', Icons.public_rounded),
  appearance('Aspetto', 'La luce d\'ambiente dietro ogni pagina, e cosa mostra la barra di navigazione.', Icons.palette_outlined),
  addons('Addon', 'Addon Stremio per sorgenti e sottotitoli. Sincronizzati con il tuo account.', Icons.extension_outlined),
  sources('Sorgenti', 'Da dove partono film e serie, e in che ordine. Sincronizzato con il tuo account.', Icons.dns_outlined),
  debrid('Debrid', 'Riproduci i torrent tramite un servizio debrid invece che peer to peer. Salvato su questo dispositivo.', Icons.cloud_download_outlined),
  playback('Riproduzione', 'Come si riproducono i video. Salvato su questo dispositivo.', Icons.play_circle_outline_rounded),
  subtitles('Lingue e sottotitoli', 'Lingue di audio e sottotitoli per film, serie TV e anime, e aspetto dei sottotitoli. Salvato su questo dispositivo.', Icons.closed_caption_outlined),
  about('Informazioni', 'Lorewatch e la sua versione.', Icons.info_outline_rounded),
  danger('Zona pericolosa', "Azzeramenti che non si possono annullare.", Icons.warning_amber_rounded);

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
          Text(_tab.blurb, style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
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
                                    for (final t in _Tab.values.where((t) => t != _Tab.party))
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
                                      children: [for (final t in _Tab.values.where((t) => t != _Tab.party)) _SideItem(tab: t, selected: _tab == t, onTap: () => _pick(t))],
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
      tooltip: 'Cambia avatar',
      onTap: () => showAvatarPicker(context),
      builder: (context, hovered, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: VyseColors.ink.withValues(alpha: hovered ? 1 : .85), width: 2),
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
            Text('Profilo locale', style: TextStyle(fontSize: 14, color: VyseColors.textDim)),
            const SizedBox(height: 3),
            Text('Nome, avatar e liste restano su questo dispositivo', style: TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
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
          _SmallButton(label: 'Cambia avatar', onTap: () => showAvatarPicker(context)),
          _SmallButton(label: 'Rinomina', primary: true, onTap: () => _AccountTab._rename(context)),
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
        decoration: BoxDecoration(
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
      final fg = primary ? VyseColors.onStrong : (danger ? _danger : VyseColors.text);
      return AnimatedScale(
        scale: pressed ? .95 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.fromLTRB(icon == null ? 18 : 14, 11, 18, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: primary
                ? (hovered ? VyseColors.strong : VyseColors.pick(0xFFF1F1F5, 0xFF1C1E28))
                : danger
                ? _danger.withValues(alpha: hovered ? .2 : .1)
                : VyseColors.ink.withValues(alpha: hovered ? .14 : .07),
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
          color: selected ? (danger ? _danger.withValues(alpha: .12) : VyseColors.ink.withValues(alpha: .08)) : VyseColors.ink.withValues(alpha: hovered ? .04 : 0),
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
        'Zona pericolosa',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? VyseColors.onStrong : _danger),
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
        if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle!, style: TextStyle(fontSize: 13, color: VyseColors.textDim))],
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
              for (var i = 0; i < children.length; i++) ...[if (i > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke), children[i]],
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
                    subtitleWidget ?? Text(subtitle!, style: TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35)),
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
          color: on ? (color ?? VyseColors.accent) : VyseColors.ink.withValues(alpha: hovered ? .2 : .12),
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
    decoration: BoxDecoration(color: VyseColors.ink.withValues(alpha: .05), borderRadius: BorderRadius.circular(10)),
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
                color: o == value ? VyseColors.ink.withValues(alpha: .16) : VyseColors.ink.withValues(alpha: hovered ? .06 : 0),
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

  static Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: AppSettings.displayName.value);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Nome visualizzato', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLength: 24,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: const InputDecoration(hintText: 'Il tuo nome'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Salva')),
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
        title: 'Profilo',
        children: [
          ValueListenableBuilder(
            valueListenable: AppSettings.avatarLabel,
            builder: (context, label, _) => _Row(
              title: 'Avatar',
              subtitle: label ?? 'Predefinito',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ProfileAvatar(size: 44),
                  const SizedBox(width: 12),
                  _SmallButton(label: 'Cambia avatar', onTap: () => showAvatarPicker(context)),
                ],
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: AppSettings.displayName,
            builder: (context, name, _) => _Row(
              title: 'Nome visualizzato',
              subtitle: name,
              trailing: _SmallButton(label: 'Rinomina', onTap: () => _rename(context)),
            ),
          ),
        ],
      ),
      // Lorewatch: no accounts (there's no server for them): name and avatar stay on this device.
      _Section(
        title: 'Importa',
        subtitle: 'Porta qui quello che hai segnato in altre app.',
        children: [
          _Row(
            title: 'Da Refract',
            subtitle: 'Scegli il backup esportato da Refract (il file .zip): film e serie finiscono in La mia lista, ciascuno nel suo stato, e quello che hai già visto nella Cronologia.',
            trailing: _SmallButton(label: 'Scegli file', onTap: () => importFromRefract(context)),
          ),
        ],
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
    if (d.inMinutes < 1) return 'adesso';
    if (d.inHours < 1) return '${d.inMinutes} min fa';
    if (d.inDays < 1) return '${d.inHours} h fa';
    return '${d.inDays} g fa';
  }

  static String _status(TrackerState s) {
    if (!s.configured) return 'Non ancora configurato';
    if (!s.connected) return 'Non collegato';
    if (s.reconnect) return 'Accedi di nuovo per tenerlo aggiornato${s.pending > 0 ? ' · ${s.pending} in attesa' : ''}';
    return [
      s.userName.isEmpty ? 'Collegato' : 'Collegato come ${s.userName}',
      if (s.expiresSoon) 'l\'accesso scade presto',
      if (s.pending > 0) '${s.pending} in attesa' else if (s.lastSync != null) 'aggiornato ${_ago(s.lastSync!)}',
      if (s.note != null && s.pending > 0) s.note!,
      if (s.unmatched > 0) '${s.unmatched} non trovati lì',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<TrackerId, TrackerState>>(
    valueListenable: TrackerHub.states,
    builder: (context, states, _) {
      final anime = states[TrackerId.anilist]?.connected ?? false;
      return _Section(
        title: 'Servizi collegati',
        subtitle: 'Quello che guardi in Lorewatch tiene aggiornate le tue liste. L\'accesso resta su questo dispositivo.',
        children: [
          for (final id in const [TrackerId.anilist]) ...[ // Lorewatch: only AniList (Simkl and Trakt are switched off)
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
                    ? _SmallButton(label: 'Collega', onTap: () => connectTracker(context, id))
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (s.reconnect || s.expiresSoon) ...[
                            _SmallButton(label: 'Ricollega', primary: true, onTap: () => connectTracker(context, id)),
                            const SizedBox(width: 8),
                          ],
                          _SmallButton(label: 'Scollega', onTap: () => TrackerHub.disconnect(id)),
                        ],
                      ),
              ),
              if (s.connected && !s.reconnect)
                _Row(
                  title: 'Importa da ${id.label}',
                  subtitle: 'La tua watchlist in La mia lista, quello che hai visto nella Cronologia',
                  trailing: _SmallButton(label: 'Importa', onTap: () => importFromTracker(context, id)),
                ),
              if (s.connected && id == TrackerId.anilist)
                _Row(
                  title: 'Aggiorna i progressi su ${id.label}',
                  subtitle: 'Gli episodi di anime che finisci qui contano anche lì',
                  trailing: _Toggle(AppSettings.trackAniList),
                ),
              if (s.connected && id == TrackerId.simkl) ...[
                _Row(title: 'Registra quello che guardo', subtitle: 'Film, serie e anime, mentre li guardi', trailing: _Toggle(AppSettings.simklScrobble)),
                _Row(title: 'Sincronizza La mia lista', subtitle: 'Aggiungere qui lo mette tra i Plan to watch di Simkl', trailing: _Toggle(AppSettings.simklList)),
                _Row(
                  title: 'Le rimozioni dalla cronologia arrivano a Simkl',
                  subtitle: 'Togliere un titolo dalla Cronologia qui cancella anche la sua cronologia su Simkl',
                  trailing: _Toggle(AppSettings.simklHistory),
                ),
              ],
              if (s.connected && id == TrackerId.trakt) ...[
                _Row(title: 'Registra quello che guardo', subtitle: 'Film, serie e anime, mentre li guardi', trailing: _Toggle(AppSettings.traktScrobble)),
                _Row(title: 'Sincronizza La mia lista', subtitle: 'Aggiungere qui lo mette nella tua watchlist di Trakt', trailing: _Toggle(AppSettings.traktList)),
                _Row(
                  title: 'Le rimozioni dalla cronologia arrivano a Trakt',
                  subtitle: 'Togliere un titolo dalla Cronologia qui rimuove anche le visioni che Lorewatch ha inviato a Trakt',
                  trailing: _Toggle(AppSettings.traktHistory),
                ),
              ],
            ],
          ],
          if (anime)
            _Row(
              title: 'Conta le riviste',
              subtitle: 'Finire l\'episodio 1 di qualcosa che hai completato fa partire una nuova visione',
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
          title: 'Il tuo profilo Party',
          subtitle: 'Bio, banner, privacy e stato appartengono al tuo account.',
          children: [
            _Row(
              title: 'Accesso non eseguito',
              subtitle: 'Accedi per scegliere come ti vedono gli altri.',
              trailing: _SmallButton(label: 'Accedi', primary: true, onTap: () => showAccountSheet(context)),
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
          Text(
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
            title: 'Aspetto',
            children: [
              ValueListenableBuilder(
                valueListenable: AppSettings.avatarLabel,
                builder: (context, label, _) => _Row(
                  title: 'Avatar',
                  subtitle: label ?? 'Predefinito',
                  trailing: _SmallButton(label: 'Cambia', onTap: () => showAvatarPicker(context)),
                ),
              ),
              _Row(
                title: 'Banner',
                subtitle: u.bannerUrl.isEmpty ? 'Ancora nessuno. Al suo posto c\'è un colore dal tuo nome utente.' : 'Mostrato in cima al tuo profilo.',
                trailing: _SmallButton(label: u.bannerUrl.isEmpty ? 'Aggiungi' : 'Cambia', onTap: () => showBannerDialog(context)),
              ),
              _Row(
                title: 'Bio',
                subtitle: u.bio.isEmpty ? 'Qualche parola su di te.' : u.bio,
                trailing: _SmallButton(
                  label: 'Modifica',
                  onTap: () async {
                    final v = await showTextEditDialog(context, title: 'Bio', initial: u.bio, maxLength: 190, maxLines: 4, hint: 'Film, serie, atmosfere…');
                    if (v != null && v != u.bio && context.mounted) await saveProfile(context, {'bio': v});
                  },
                ),
              ),
              _Row(
                title: 'Stato',
                subtitle: u.customStatus.isEmpty ? 'Compare sotto il tuo nome, es. "rivedo Dark".' : u.customStatus,
                trailing: _SmallButton(
                  label: 'Modifica',
                  onTap: () async {
                    final v = await showTextEditDialog(context, title: 'Stato', initial: u.customStatus, maxLength: 80, hint: 'Cosa stai facendo?');
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
                title: 'Profilo',
                subtitle: u.private
                    ? "Privato. Nessuno può aggiungerti o scriverti, e solo gli amici vedono bio, banner, stato e cosa guardi. Puoi comunque aggiungere persone, e una volta amici vale in entrambi i sensi."
                    : 'Pubblico. Chiunque può aggiungerti e vedere il tuo profilo e cosa guardi. Gli amici possono scriverti.',
                below: _Choice<bool>(
                  value: u.private,
                  options: const [false, true],
                  label: (v) => v ? 'Privato' : 'Pubblico',
                  onChanged: (v) => saveProfile(context, {'visibility': v ? 'private' : 'public'}),
                ),
              ),
              _Row(
                title: 'Lista online',
                subtitle: u.onlineListHidden
                    ? "Nascosto. Non compari mai nella lista online del Party, ma il profilo mostra comunque quando sei online. Per sembrare offline ovunque, imposta lo stato su Invisibile."
                    : u.private
                    ? "Visibile. Compari nella lista online del Party con nome e avatar; stato e cosa guardi restano agli amici."
                    : "Visibile. Compari nella lista online del Party, con quello che stai guardando.",
                below: _Choice<bool>(
                  value: u.onlineListHidden,
                  options: const [false, true],
                  label: (v) => v ? 'Nascondi' : 'Mostra',
                  onChanged: (v) => saveProfile(context, {'onlineList': v ? 'hide' : 'show'}),
                ),
              ),
              _Row(
                title: 'Chi può scrivermi',
                subtitle: 'I messaggi spariscono 24 ore dopo l\'invio.',
                below: _Choice<bool>(
                  value: u.dmsOff,
                  options: const [false, true],
                  label: (v) => v ? 'Nessuno' : 'Amici',
                  onChanged: (v) => saveProfile(context, {'dmPolicy': v ? 'nobody' : 'friends'}),
                ),
              ),
              _Row(
                title: "Mostra cosa sto guardando",
                subtitle: u.private
                    ? 'Solo gli amici vedono il titolo in riproduzione finché il profilo è privato.'
                    : 'Il profilo e la lista online mostrano il titolo in riproduzione.',
                trailing: _Switch(value: !u.hideActivity, onChanged: (v) => saveProfile(context, {'hideActivity': !v})),
              ),
              _Row(
                title: 'Mostra la mia libreria',
                subtitle: u.private
                    ? 'Gli amici possono aprire dal tuo profilo La mia lista, i brani preferiti, le playlist pubbliche e gli artisti che segui.'
                    : 'Chiunque può aprire dal tuo profilo La mia lista, i brani preferiti, le playlist pubbliche e gli artisti che segui.',
                trailing: _Toggle(AppSettings.partyLibrary),
              ),
              _Row(
                title: 'Riproduzione automatica musica',
                subtitle: 'Quando la coda finisce, continua con brani simili all\'ultimo.',
                trailing: _Toggle(AppSettings.musicAutoplay),
              ),
              ValueListenableBuilder<FriendLists>(
                valueListenable: Friends.lists,
                builder: (context, l, _) => _Row(
                  title: 'Persone bloccate',
                  subtitle: l.blocked.isEmpty
                      ? "Nessuno. Le persone bloccate non possono aggiungerti, scriverti o vedere il tuo profilo."
                      : '${l.blocked.length} bloccati. Non possono aggiungerti, scriverti o vedere il tuo profilo.',
                  trailing: _SmallButton(label: 'Gestisci', onTap: () => showBlockedDialog(context)),
                ),
              ),
              _Row(
                title: 'Regole del Party',
                subtitle: switch (u.termsAt) {
                  final d? => 'You accepted these on ${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dec'][d.month - 1]} ${d.year}.',
                  null => 'Quello che tutti nel Party accettano.',
                },
                trailing: _SmallButton(label: 'Leggi', onTap: () => showPartyRules(context)),
              ),
            ],
          ),
          _Section(
            title: 'Stato',
            children: [
              _Row(
                title: 'Mostrami come',
                subtitle: switch (u.statusMode) {
                  'idle' => 'Inattivo: sembri lontano dalla tastiera.',
                  'dnd' => 'Non disturbare: nessun popup di messaggi.',
                  'invisible' => 'Invisibile: sembri offline ma puoi usare tutto.',
                  _ => 'Online: tutti vedono quando ci sei.',
                },
                below: SingleChildScrollView(
                  scrollDirection: Axis.horizontal, // four options don't fit a phone's width
                  child: _Choice<String>(
                    value: u.statusMode,
                    options: const ['online', 'idle', 'dnd', 'invisible'],
                    label: (v) => switch (v) {
                      'idle' => 'Inattivo',
                      'dnd' => 'Non disturbare',
                      'invisible' => 'Invisibile',
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
      // Lorewatch: day, night or as the system is set
      _Section(
        title: 'Modalità',
        subtitle: 'Giorno, notte, o come è impostato il dispositivo.',
        children: [
          _Row(
            title: 'Aspetto dell\'app',
            below: _Segmented<String>(
              setting: AppSettings.themeMode,
              options: const ['system', 'light', 'dark'],
              label: (v) => switch (v) { 'system' => 'Sistema', 'light' => 'Giorno', _ => 'Notte' },
            ),
          ),
        ],
      ),
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
        title: 'Navigazione',
        subtitle: 'Le sezioni della barra di navigazione, in ordine: dall\'alto in basso sulla barra laterale, da sinistra a destra sul telefono. '
            'Trascina una riga o usa le frecce per spostarla; spegnine una per nasconderla. '
            'Lorewatch si apre sulla prima visibile, e Indietro ci riporta lì. Profilo e impostazioni ci sono sempre.',
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
            title: 'Ordine predefinito',
            subtitle: 'Prima la Home e tutte le sezioni visibili',
            trailing: _SmallButton(label: 'Ripristina', icon: Icons.restart_alt_rounded, onTap: NavLayout.reset),
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
      child: MouseRegion(
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
        color: on ? accent.withValues(alpha: .16) : VyseColors.ink.withValues(alpha: .06),
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
        if (first) const _Kind('Si apre per prima', Icons.flag_rounded),
        if (!on) const _Kind('Nascosta', Icons.visibility_off_outlined),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Sposta su', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Sposta giù', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 8),
        Tooltip(
          message: locked ? 'Almeno una sezione resta attiva' : (on ? 'Nascondi questa sezione' : 'Mostra questa sezione'),
          child: _Switch(value: on, color: accent, thumb: onAccentOf(context), onChanged: (v) => NavLayout.setOn(item, v)),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke),
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
          color: selected ? theme.color : VyseColors.ink.withValues(alpha: hovered ? .2 : .06),
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
              border: Border.all(color: VyseColors.ink.withValues(alpha: .15)),
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
                  style: TextStyle(fontSize: 12.5, color: VyseColors.textDim),
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
            title: 'Modalità streaming',
            subtitle: "Attiva: i video partono subito dai server integrati. Disattiva: scegli prima una sorgente dai tuoi addon",
            trailing: _Toggle(AppSettings.streamingMode),
          ),
          _Row(
            title: 'Riproduci automaticamente la sorgente migliore',
            subtitle: 'Con la modalità streaming disattivata: il pulsante Prossimo episodio riproduce la sorgente migliore dei tuoi addon. '
                'Niente parte da solo, e aprire un titolo mostra comunque prima le sorgenti. '
                'Cosa conta come migliore lo decidi tu: l\'ordine qui sotto',
            trailing: _Toggle(AppSettings.autoplayBest),
          ),
          _Row(
            title: 'Streaming P2P',
            subtitle: 'Riproduci sorgenti torrent. Ti colleghi direttamente ad altre persone, che possono vedere il tuo indirizzo IP',
            trailing: _Toggle(AppSettings.p2pStreaming),
          ),
          _Row(title: 'Episodio successivo automatico', subtitle: 'Riproduci il prossimo episodio quando uno finisce', trailing: _Toggle(AppSettings.autoNext)),
          ValueListenableBuilder(
            valueListenable: AppSettings.seekSeconds,
            builder: (context, s, _) => _Row(
              title: 'Salto',
              subtitle: '${s}s per salto (← → nel player)',
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
        title: 'Ordine della riproduzione automatica',
        subtitle: 'Cosa cerca "Riproduci automaticamente la sorgente migliore", dall\'alto in basso: parte il primo passo per cui i tuoi addon hanno una sorgente, '
            "e se quella non parte, tocca al successivo. Lascia un campo su Qualsiasi per prendere quello che c'è. "
            'Dolby Digital include anche Dolby Digital+, e DTS include DTS-HD.',
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
            title: steps.isEmpty ? 'Ancora nessun passo' : 'Un altro passo',
            subtitle: steps.isEmpty ? 'La riproduzione automatica decide da sola: prima il 4K, poi l\'audio migliore' : 'Va in fondo: impostalo, poi spostalo dove deve stare',
            trailing: _SmallButton(label: 'Aggiungi un passo', icon: Icons.add_rounded, primary: steps.isEmpty, onTap: () => AutoplayOrder.save([...steps, const AutoplayStep()])),
          ),
          if (steps.isEmpty)
            _Row(
              title: 'Parti da un esempio',
              subtitle: '4K, poi 1080p con Atmos 7.1, poi con Dolby Digital 7.1, poi con 5.1, poi qualsiasi 1080p',
              trailing: _SmallButton(label: 'Usalo', icon: Icons.auto_awesome_rounded, onTap: () => AutoplayOrder.save(_example)),
            )
          else ...[
            _Row(
              title: 'Quando nessun passo ha una sorgente',
              subtitle: 'Attivo: riproduci la migliore disponibile. Disattivo: apri la lista delle sorgenti',
              trailing: _Toggle(AppSettings.autoplayRest),
            ),
            _Row(
              title: 'Cancella l\'ordine',
              subtitle: 'Torna a decidere da solo',
              trailing: _SmallButton(label: 'Cancella', icon: Icons.restart_alt_rounded, onTap: () => AutoplayOrder.save(const [])),
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
      child: MouseRegion(
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
      child: Text('${index + 1}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: VyseColors.accent)),
    );
    final picks = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StepPick(
          any: 'Qualsiasi qualità',
          value: s.quality,
          options: AutoplayStep.qualities,
          onPick: (v) => onChange(AutoplayStep(quality: v, audio: s.audio, channels: s.channels)),
        ),
        _StepPick(
          any: 'Qualsiasi audio',
          value: s.audio,
          options: AutoplayStep.audios,
          label: (a) => a == 'Atmos' ? 'Dolby Atmos' : a,
          onPick: (v) => onChange(AutoplayStep(quality: s.quality, audio: v, channels: s.channels)),
        ),
        _StepPick(
          any: 'Qualsiasi canale',
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
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Provalo prima', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Provalo dopo', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 4),
        _IconAction(icon: Icons.close_rounded, tooltip: 'Rimuovi questo passo', danger: true, onTap: onRemove),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke),
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
        color: value == null ? VyseColors.ink.withValues(alpha: .06) : VyseColors.accent.withValues(alpha: .16),
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
          Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
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
/// Anime audio: the original, or a dub the anime servers offer.
const _animeAudioLanguages = ['', 'English', 'Italian', 'Spanish', 'Portuguese', 'French', 'German', 'Hindi'];

/// Italian names for the languages in the pickers (the stored value stays the English name).
const _langIt = {
  '': 'Originale',
  'Off': 'Nessuno',
  'English': 'Inglese',
  'Arabic': 'Arabo',
  'French': 'Francese',
  'Spanish': 'Spagnolo',
  'German': 'Tedesco',
  'Italian': 'Italiano',
  'Portuguese': 'Portoghese',
  'Turkish': 'Turco',
  'Dutch': 'Olandese',
  'Russian': 'Russo',
  'Japanese': 'Giapponese',
  'Korean': 'Coreano',
  'Chinese': 'Cinese',
  'Hindi': 'Hindi',
  'Indonesian': 'Indonesiano',
  'Polish': 'Polacco',
  'Swedish': 'Svedese',
};

String _langLabel(String v) => _langIt[v] ?? v;

/// A language menu bound to one setting (Settings → Subtitles, per kind of video).
class _LangPicker extends StatelessWidget {
  const _LangPicker({required this.setting, required this.options});
  final Setting<String> setting;
  final List<String> options;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: setting,
    builder: (context, lang, _) => PopupMenuButton<String>(
      tooltip: '',
      color: VyseColors.surfaceHi,
      initialValue: lang,
      onSelected: setting.set,
      itemBuilder: (_) => [for (final l in options) PopupMenuItem(value: l, height: 38, child: Text(_langLabel(l)))],
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        decoration: BoxDecoration(color: VyseColors.ink.withValues(alpha: .07), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_langLabel(lang), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
          ],
        ),
      ),
    ),
  );
}

const _captionColors = captionColors;

class _SubtitlesTab extends StatelessWidget {
  const _SubtitlesTab();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final k in PlayKind.values)
        _Section(
          title: 'Lingue: ${k.label}',
          subtitle: k == PlayKind.anime
              ? "Valgono solo per gli anime. L'audio sceglie tra originale (sottotitolato) e doppiato quando un server li offre."
              : 'Valgono solo per ${k == PlayKind.movie ? 'i film' : 'le serie TV'}, senza toccare le altre impostazioni.',
          children: [
            _Row(
              title: 'Lingua audio',
              subtitle: k == PlayKind.anime
                  ? 'Originale = giapponese con sottotitoli'
                  : 'Se il video ha più tracce audio, parte con questa',
              trailing: _LangPicker(setting: PlaybackPrefs.audio(k), options: k == PlayKind.anime ? _animeAudioLanguages : ['', ..._languages]),
            ),
            _Row(
              title: 'Lingua dei sottotitoli',
              subtitle: 'Nessuno = i sottotitoli restano spenti. Se un video non li ha in questa lingua, non ne carica nessuno',
              trailing: _LangPicker(setting: PlaybackPrefs.subtitles(k), options: [PlaybackPrefs.none, ..._languages]),
            ),
            _Row(
              title: 'Attiva i sottotitoli da soli',
              subtitle: 'Accende i sottotitoli nella lingua scelta quando parte un video',
              trailing: _Toggle(PlaybackPrefs.autoSubtitles(k)),
            ),
          ],
        ),
      _Section(
        title: 'Stile dei sottotitoli',
        subtitle: "Disegnati dal motore sottotitoli del player (libass), quindi l'anteprima è simile ma non identica.",
        children: [
          const Padding(padding: EdgeInsets.only(top: 18, bottom: 4), child: _SubtitlePreview()),
          _Row(
            title: 'Carattere',
            subtitle: 'Go Noto copre ogni lingua. Gli altri caratteri ripiegano su di esso per le lettere che mancano.',
            trailing: const _FontButton(),
          ),
          _Row(title: 'Grassetto', trailing: _Toggle(AppSettings.subtitleBold)),
          _Row(title: 'Corsivo', trailing: _Toggle(AppSettings.subtitleItalic)),
          ValueListenableBuilder(
            valueListenable: AppSettings.subtitleSize,
            builder: (context, size, _) => _Row(
              title: 'Dimensione del testo',
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
          _Row(title: 'Colore del testo', trailing: _Swatches(setting: AppSettings.subtitleColor, colors: _captionColors)),
          _Row(
            title: 'Spaziatura delle lettere',
            trailing: _Stepper(setting: AppSettings.subtitleSpacing, min: -20, max: 50, step: 5, label: (v) => v == 0 ? 'Normale' : _tenths(v)),
          ),
        ],
      ),
      _Section(
        title: 'Riquadro di sfondo',
        children: [
          _Row(
            title: 'Riquadro',
            subtitle: 'Un riquadro dietro al testo. Senza riquadro si usano contorno e ombra qui sotto.',
            below: _Segmented<int>(setting: AppSettings.subtitleBackground, options: captionBoxLevels, label: (v) => v == 0 ? 'Nessuno' : '$v%'),
          ),
          _Row(title: 'Colore del riquadro', trailing: _Swatches(setting: AppSettings.subtitleBackColor, colors: _boxColors)),
        ],
      ),
      ValueListenableBuilder(
        valueListenable: AppSettings.subtitleBackground,
        builder: (context, back, _) => _Section(
          title: 'Contorno e ombra',
          subtitle: back > 0 ? 'Disattiva il riquadro di sfondo per usare queste opzioni.' : null,
          children: [
            _Row(
              title: 'Contorno',
              trailing: _Stepper(setting: AppSettings.subtitleOutline, min: 0, max: 80, step: 5, label: (v) => v == 0 ? 'Nessuno' : _tenths(v)),
            ),
            _Row(title: 'Colore del contorno', trailing: _Swatches(setting: AppSettings.subtitleOutlineColor, colors: _outlineColors)),
            _Row(
              title: 'Ombra',
              trailing: _Stepper(setting: AppSettings.subtitleShadow, min: 0, max: 60, step: 5, label: (v) => v == 0 ? 'Nessuno' : _tenths(v)),
            ),
            _Row(
              title: 'Intensità dell\'ombra',
              below: _Segmented<int>(
                setting: AppSettings.subtitleShadowColor,
                options: const [0x60000000, 0xA0000000, 0xFF000000],
                label: (v) => switch (v) { 0x60000000 => 'Leggera', 0xA0000000 => 'Media', _ => 'Forte' },
              ),
            ),
            _Row(
              title: 'Bordi morbidi',
              subtitle: 'Sfuma un po\' il contorno',
              trailing: _Stepper(setting: AppSettings.subtitleBlur, min: 0, max: 30, step: 5, label: (v) => v == 0 ? 'Off' : _tenths(v)),
            ),
          ],
        ),
      ),
      _Section(
        title: 'Posizione',
        children: [
          _Row(
            title: 'Posizione',
            trailing: _Segmented<bool>(setting: AppSettings.subtitleTop, options: const [false, true], label: (v) => v ? 'In alto' : 'In basso'),
          ),
          _Row(
            title: 'Distanza dal bordo',
            subtitle: "Dell'altezza dello schermo. I sottotitoli in basso salgono comunque quando ci sono i controlli.",
            trailing: _Stepper(setting: AppSettings.subtitleLift, min: 0, max: 45, step: 1, label: (v) => v == 0 ? 'Bordo' : '$v%'),
          ),
          _Row(
            title: 'Tieni sull\'immagine',
            subtitle: "Non mettere mai i sottotitoli nelle bande nere",
            trailing: _Toggle(AppSettings.subtitleOnPicture),
          ),
        ],
      ),
      ValueListenableBuilder(
        valueListenable: AppSettings.subtitleAss,
        builder: (context, mode, _) => _Section(
          title: 'Sottotitoli con stile',
          subtitle: 'I fansub degli anime (ASS/SSA) spesso hanno caratteri, colori, cartelli e karaoke propri.',
          children: [
            _Row(
              title: 'Mostrali',
              subtitle: switch (mode) {
                'force' => 'Il tuo carattere e i tuoi colori su tutto. Cartelli e karaoke possono sembrare sbagliati.',
                'strip' => 'Testo semplice nel tuo stile: niente cartelli, karaoke o posizioni.',
                _ => 'Come li hanno fatti i loro autori, solo adattati allo schermo.',
              },
              below: _Segmented<String>(
                setting: AppSettings.subtitleAss,
                options: const ['scale', 'force', 'strip'],
                label: (v) => switch (v) { 'force' => 'Usa il mio stile', 'strip' => 'Semplice', _ => 'Lascia com\'è' },
              ),
            ),
          ],
        ),
      ),
      _Section(
        title: 'Ripristina',
        children: [
          _Row(
            title: 'Stile dei sottotitoli',
            subtitle: 'Torna a come Lorewatch disegna i sottotitoli di base',
            trailing: _SmallButton(label: 'Ripristina', icon: Icons.restart_alt_rounded, onTap: _resetCaptionStyle),
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
                  color: c == value ? VyseColors.accent : VyseColors.ink.withValues(alpha: hovered ? .5 : .14),
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
      const sample = 'Ecco come appariranno i sottotitoli';
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
          decoration: BoxDecoration(color: VyseColors.ink.withValues(alpha: hovered ? .11 : .07), borderRadius: BorderRadius.circular(10)),
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
              Icon(Icons.expand_more_rounded, size: 18, color: VyseColors.textDim),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: VyseColors.stroke)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Carattere dei sottotitoli', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Cerca caratteri',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  filled: true,
                  fillColor: VyseColors.ink.withValues(alpha: .06),
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
                              color: on ? VyseColors.accent.withValues(alpha: .14) : VyseColors.ink.withValues(alpha: hovered ? .06 : 0),
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
                                if (on) Icon(Icons.check_rounded, size: 18, color: VyseColors.accent),
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
        color: VyseColors.ink.withValues(alpha: onTap == null ? .03 : (hovered ? .16 : .08)),
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
            title: 'Lorewatch',
            children: [
              _Row(
                title: 'Versione',
                trailing: Text(
                  up.current.isEmpty ? '…' : up.current,
                  style: TextStyle(fontWeight: FontWeight.w700, color: VyseColors.textDim),
                ),
              ),
              _Row(
                title: 'Aggiornamenti',
                subtitle: switch (up.stage) {
                  UpdateStage.checking => 'Controllo…',
                  UpdateStage.failed => up.error ?? "Impossibile controllare gli aggiornamenti.",
                  _ when newer != null => 'La versione ${newer.version} è pronta',
                  UpdateStage.upToDate => "Hai la versione più recente",
                  _ => 'Non ancora controllato',
                },
                trailing: _SmallButton(
                  label: newer != null ? 'Aggiorna' : 'Controlla ora',
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
                title: 'Controlla automaticamente',
                subtitle: 'Cerca una nuova versione all\'avvio di Lorewatch, e te lo dice',
                trailing: _Toggle(AppSettings.updateAuto),
              ),
              const _Row(title: 'Film, musica, manga, audiolibri e TV in diretta', subtitle: 'Tutto quello che guardi, leggi e ascolti in un unico posto.'),
            ],
          );
        },
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
          content: Text(body, style: TextStyle(color: VyseColors.textDim)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
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
        title: 'Ripristina',
        children: [
          _Row(
            title: 'Ripristina le preferenze',
            subtitle: 'Aspetto, home, riproduzione, sottotitoli e sincronizzazione tornano ai valori predefiniti. Nome, avatar e addon restano.',
            trailing: _SmallButton(
              label: 'Ripristina',
              danger: true,
              onTap: () async {
                if (!await _confirm(context, 'Ripristinare le preferenze?', 'Ogni impostazione torna al valore predefinito. Nome, avatar e addon restano.', 'Ripristina')) return;
                AppSettings.resetPreferences();
                if (context.mounted) _done(context, 'Preferenze ripristinate', Icons.restart_alt_rounded);
              },
            ),
          ),
          _Row(
            title: 'Cancella la cronologia di lettura manga',
            subtitle: 'Svuota Continua a leggere e dimentica ogni pagina salvata.',
            trailing: _SmallButton(
              label: 'Cancella',
              danger: true,
              onTap: () async {
                final all = await MangaHistory.load();
                if (!context.mounted) return;
                if (all.isEmpty) return _done(context, 'Nessuna cronologia di lettura da cancellare', Icons.menu_book_rounded);
                if (!await _confirm(context, 'Cancellare la cronologia di lettura?', 'Continue reading will be empty (${all.length} ${all.length == 1 ? 'titolo' : 'titoli'}).', 'Clear')) return;
                for (final p in all) {
                  await MangaHistory.remove(p.manga);
                }
                if (context.mounted) _done(context, 'Cronologia di lettura cancellata', Icons.menu_book_rounded);
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
                    title: 'Elimina account',
                    subtitle: 'Elimina @${u.username} con profilo, amici, messaggi e dati sincronizzati. Non si può annullare.',
                    trailing: _SmallButton(
                      label: 'Elimina',
                      danger: true,
                      onTap: () async {
                        final gone = await showDialog<bool>(context: context, builder: (_) => const _DeleteAccountDialog());
                        if (gone == true && context.mounted) _done(context, 'Account eliminato', Icons.person_off_rounded);
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
    title: const Text('Eliminare il tuo account?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Profilo, amici, messaggi e tutto ciò che è sincronizzato vengono eliminati dal server. Quello salvato su questo dispositivo resta.",
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
              hintText: 'La tua password',
              hintStyle: TextStyle(color: VyseColors.textFaint, fontSize: 14),
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Annulla')),
      TextButton(
        onPressed: _busy || _password.text.isEmpty ? null : _delete,
        child: Text(
          _busy ? 'Eliminazione…' : 'Elimina per sempre',
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
        title: 'Aggiungi un addon',
        subtitle: 'Incolla il link di un addon Stremio. Gli addon di stream riempiono la schermata sorgenti (modalità streaming disattivata in Riproduzione); '
            'gli addon di sottotitoli aggiungono i loro file a ogni video.',
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
                          hintStyle: TextStyle(color: VyseColors.textFaint),
                          isDense: true,
                          filled: true,
                          fillColor: VyseColors.ink.withValues(alpha: .05),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          prefixIcon: Icon(Icons.link_rounded, size: 18, color: VyseColors.textDim),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.stroke)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.stroke)),
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
                        : _SmallButton(label: 'Installa', icon: Icons.add_rounded, primary: true, onTap: _install),
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
          title: 'I tuoi addon',
          subtitle: list.isEmpty
              ? null
              : 'Le sorgenti sono elencate in quest\'ordine. I torrent partono con lo streaming P2P (Riproduzione) o con il tuo servizio debrid (Debrid).',
          children: list.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text('Ancora nessun addon. Incollane uno qui sopra.', style: TextStyle(fontSize: 13.5, color: VyseColors.textDim)),
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
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Sposta su', onTap: first ? null : () => Addons.move(a, -1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Sposta giù', onTap: last ? null : () => Addons.move(a, 1)),
        if (a.configureUrl != null)
          _IconAction(
            icon: Icons.tune_rounded,
            tooltip: 'Configura (poi incolla qui sopra il nuovo link)',
            onTap: () => launchUrl(Uri.parse(a.configureUrl!), mode: LaunchMode.externalApplication),
          ),
        // a built-in addon is part of the app: it is turned off, not removed
        if (!a.builtIn) _IconAction(icon: Icons.delete_outline_rounded, tooltip: 'Rimuovi', danger: true, onTap: () => Addons.remove(a)),
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
            if (a.version.isNotEmpty) Text('v${a.version}', style: TextStyle(fontSize: 12, color: VyseColors.textFaint)),
            if (a.builtIn) const _Kind('Built in', Icons.verified_outlined),
            if (a.streams) const _Kind('Sorgenti', Icons.play_circle_outline_rounded),
            if (a.subtitles) const _Kind('Sottotitoli', Icons.closed_caption_outlined),
          ],
        ),
        if (a.description.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(a.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
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
    decoration: BoxDecoration(color: VyseColors.ink.withValues(alpha: .07), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: VyseColors.textDim),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
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
          color: onTap != null && hovered ? (danger ? _danger.withValues(alpha: .14) : VyseColors.ink.withValues(alpha: .08)) : Colors.transparent,
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
        title: 'Sorgenti per film e serie TV',
        subtitle: 'Quando parte un film o un episodio vengono interrogate dall\'alto in basso, e parte la prima che risponde. '
            'Trascina una riga o usa le frecce per cambiare l\'ordine; spegnine una per saltarla. Gli anime hanno i loro server.',
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
            title: 'Ordine predefinito',
            subtitle: 'Prima Movy e tutte le sorgenti attive',
            trailing: _SmallButton(
              label: 'Ripristina',
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
      child: MouseRegion(
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
        color: on ? VyseColors.accent.withValues(alpha: .16) : VyseColors.ink.withValues(alpha: .06),
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
            if (first) const _Kind('Interrogata per prima', Icons.bolt_rounded),
            if (s.filmsOnly) const _Kind('Solo film', Icons.movie_outlined),
            if (s.showsOnly) const _Kind('Solo serie', Icons.live_tv_rounded),
            if (!on) const _Kind('Off', Icons.block_rounded),
          ],
        ),
        const SizedBox(height: 4),
        Text(s.note, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Sposta su', onTap: index == 0 ? null : () => onMove(-1)),
        _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Sposta giù', onTap: index == count - 1 ? null : () => onMove(1)),
        const SizedBox(width: 8),
        Tooltip(
          message: locked ? 'Almeno una sorgente resta attiva' : (on ? 'Salta questa sorgente' : 'Usa questa sorgente'),
          child: _Switch(value: on, onChanged: (v) => locked ? null : setFilmSourceOn(s, v)),
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (index > 0) Divider(height: 1, thickness: 1, color: VyseColors.stroke),
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
      _message = user == null ? "${p.label} non ha accettato la chiave salvata. Incollane una nuova." : null;
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
      _message = 'Chiave rimossa.';
    } else {
      final user = await Debrid.verify(p, k);
      if (user == null) {
        _failed = true;
        _message = "${p.label} non ha accettato la chiave. Controlla di averla copiata tutta.";
      } else {
        await Debrid.saveKey(p, k);
        _failed = false;
        _account = Debrid.describe(user);
        _message = 'Collegato a ${p.label}.';
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
            title: 'Servizio',
            subtitle: 'Un servizio debrid scarica il torrent sui propri server e te lo trasmette in HTTPS. Dal tuo dispositivo non viene condiviso niente in peer to peer.',
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
                              color: on ? VyseColors.ink.withValues(alpha: .16) : VyseColors.ink.withValues(alpha: hovered ? .08 : .04),
                              border: Border.all(color: on ? VyseColors.accent.withValues(alpha: .6) : VyseColors.stroke),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(o?.label ?? 'Nessuno', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim)),
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
              title: 'Chiave ${p.label}',
              subtitle: "Conservata nel portachiavi del dispositivo. Non va mai al tuo account Lorewatch.",
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
                                hintText: 'Incolla la tua chiave API di ${p.label}',
                                hintStyle: TextStyle(color: VyseColors.textFaint),
                                isDense: true,
                                filled: true,
                                fillColor: VyseColors.ink.withValues(alpha: .05),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                                prefixIcon: Icon(Icons.key_rounded, size: 18, color: VyseColors.textDim),
                                suffixIcon: IconButton(
                                  tooltip: _show ? 'Nascondi' : 'Mostra',
                                  iconSize: 18,
                                  color: VyseColors.textDim,
                                  onPressed: () => setState(() => _show = !_show),
                                  icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                                ),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.stroke)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.stroke)),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7))),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _busy
                              ? const SizedBox(width: 92, child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))))
                              : _SmallButton(
                                  label: _key.text.trim().isEmpty && Debrid.keyed.value.contains(p) ? 'Rimuovi' : 'Salva',
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
                            'Prendi la chiave da ${p.label} ↗',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: hovered ? VyseColors.text : VyseColors.accent),
                          ),
                        ),
                        const Spacer(),
                        if (_account != null)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF3DDC97)),
                            const SizedBox(width: 6),
                            Text(_account!, style: TextStyle(fontSize: 13, color: VyseColors.textDim)),
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
                title: 'Riproduci i torrent tramite debrid',
                subtitle: Debrid.active
                    ? 'Attivo: i torrent partono da ${Debrid.name} invece che in peer to peer.'
                    : p == null
                    ? 'Prima scegli un servizio e salva la sua chiave.'
                    : !Debrid.keyed.value.contains(p)
                    ? 'Prima salva la chiave di ${p.label}.'
                    : 'Disattivo: i torrent partono in peer to peer (se lo streaming P2P è consentito in Riproduzione).',
                trailing: _Toggle(AppSettings.debridOn),
              ),
            ],
          ),
        ],
      );
    },
  );
}
