import 'package:flutter/material.dart';

import '../../core/layout.dart';
import '../../core/theme.dart';
import '../../data/party/rooms.dart';
import '../../data/party/voice.dart';
import '../../widgets/common.dart';
import 'party_widgets.dart' show PartyAvatar, showPartyProfile, showReportDialog;

const _red = Color(0xFFFF8A8C);

/// Someone in your room: their volume (just for you), and what you can do about them. A card in
/// the middle on bigger screens, a sheet from the bottom on phones.
Future<void> showMemberMenu(
  BuildContext context,
  RoomMember member, {
  required bool ownerTools,
  required VoidCallback onKick,
  required VoidCallback onOwner,
  required ValueChanged<bool> onSilence,
  required ValueChanged<bool> onControl,
}) {
  final body = _MemberMenu(
    member: member,
    ownerTools: ownerTools,
    onKick: onKick,
    onOwner: onOwner,
    onSilence: onSilence,
    onControl: onControl,
  );
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: SingleChildScrollView(child: body)),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .5),
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: SingleChildScrollView(child: body)),
    ),
  );
}

class _MemberMenu extends StatefulWidget {
  const _MemberMenu({
    required this.member,
    required this.ownerTools,
    required this.onKick,
    required this.onOwner,
    required this.onSilence,
    required this.onControl,
  });
  final RoomMember member;
  final bool ownerTools;
  final VoidCallback onKick;
  final VoidCallback onOwner;
  final ValueChanged<bool> onSilence;
  final ValueChanged<bool> onControl;

  @override
  State<_MemberMenu> createState() => _MemberMenuState();
}

class _MemberMenuState extends State<_MemberMenu> {
  late double _volume = Voice.volumes[widget.member.id] ?? 1.0;
  double _before = 1.0; // what muting goes back to

  void _set(double v) {
    setState(() => _volume = v);
    Voice.setVolume(widget.member.id, v);
  }

  /// Closes the menu, then does [action].
  void _then(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final inCall = Voice.inCall.value.containsKey(m.id);
    final status = [if (m.owner) 'Owner', inCall ? 'In the call' : 'Not in the call', if (m.silenced) 'Muted for everyone'].join(' · ');
    final muted = _volume == 0;
    return Container(
      decoration: BoxDecoration(
        color: VyseColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VyseColors.stroke),
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // who
          Row(
            children: [
              PartyAvatar(url: m.avatarUrl, name: m.name, size: 48, presence: m.presence, ring: VyseColors.surface),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Profile',
                onPressed: () => _then(() => showPartyProfile(context, m.id)),
                icon: const Icon(Icons.person_outline_rounded, size: 21, color: VyseColors.textDim),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // their volume, for you only
          Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .04), borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                IconButton(
                  tooltip: muted ? 'Unmute for you' : 'Mute for you',
                  onPressed: () {
                    if (muted) {
                      _set(_before == 0 ? 1 : _before);
                    } else {
                      _before = _volume;
                      _set(0);
                    }
                  },
                  icon: Icon(
                    muted ? Icons.volume_off_rounded : (_volume < .6 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                    size: 21,
                    color: muted ? _red : VyseColors.text,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      activeTrackColor: VyseColors.accent,
                      inactiveTrackColor: Colors.white.withValues(alpha: .12),
                      thumbColor: Colors.white,
                      overlayColor: VyseColors.accent.withValues(alpha: .15),
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(value: _volume.clamp(0, 2), max: 2, onChanged: _set),
                  ),
                ),
                Pressable(
                  tooltip: 'Back to 100%',
                  onTap: () => _set(1),
                  builder: (context, hovered, _) => SizedBox(
                    width: 44,
                    child: Text(
                      '${(_volume * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: hovered ? VyseColors.accent : VyseColors.textDim,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (widget.ownerTools) ...[
            m.silenced
                ? _Action(icon: Icons.mic_rounded, label: 'Let them talk', onTap: () => _then(() => widget.onSilence(false)))
                : _Action(icon: Icons.mic_off_rounded, label: 'Mute for everyone', onTap: () => _then(() => widget.onSilence(true))),
            m.controls
                ? _Action(icon: Icons.smart_display_outlined, label: 'Take back play/pause', onTap: () => _then(() => widget.onControl(false)))
                : _Action(icon: Icons.smart_display_rounded, label: 'Let them play/pause', onTap: () => _then(() => widget.onControl(true))),
            _Action(icon: Icons.workspace_premium_rounded, label: 'Make owner', onTap: () => _then(widget.onOwner)),
            const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, color: VyseColors.stroke)),
            _Action(icon: Icons.person_remove_rounded, label: 'Remove from room', danger: true, onTap: () => _then(widget.onKick)),
          ],
          _Action(
            icon: Icons.flag_outlined,
            label: 'Report',
            danger: true,
            onTap: () => _then(() => showReportDialog(context, userId: m.id, name: m.name, kind: 'voice', ref: Rooms.mine.value?.id)),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.danger = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? _red : VyseColors.text;
    return Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: hovered ? (danger ? _red.withValues(alpha: .08) : Colors.white.withValues(alpha: .06)) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: danger ? _red : VyseColors.textDim),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color))),
          ],
        ),
      ),
    );
  }
}
