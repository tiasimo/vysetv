import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/theme.dart';
import '../widgets/common.dart';

class SyncCue {
  const SyncCue(this.start, this.end, this.text);
  final double start;
  final double end;
  final String text;
}

/// Cues from an SRT or WebVTT file, tags stripped.
List<SyncCue> parseCues(String text) {
  final time = RegExp(r'((?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})');
  double secs(String t) {
    final p = t.replaceAll(',', '.').split(':').map(double.parse).toList();
    return p.length == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1];
  }

  final out = <SyncCue>[];
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = time.firstMatch(lines[i]);
    if (m == null) continue;
    final body = <String>[];
    while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty && !time.hasMatch(lines[i + 1])) {
      final clean = lines[++i].replaceAll(RegExp(r'<[^>]*>|\{\\[^}]*\}'), '').trim();
      if (clean.isNotEmpty) body.add(clean);
    }
    if (body.isEmpty) continue;
    try {
      out.add(SyncCue(secs(m[1]!), secs(m[2]!), body.join('\n')));
    } catch (_) {}
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

String _stamp(double s) {
  final v = s < 0 ? 0.0 : s;
  final m = v ~/ 60;
  final sec = v - m * 60;
  return '${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(1).padLeft(4, '0')}';
}

String _signed(double s) => '${s >= 0 ? '+' : '−'}${s.abs().toStringAsFixed(1)}s';

/// Right-hand panel for lining subtitles up with the dialogue: play, listen, then tap the line
/// you just heard and the offset is set so that line starts now. Styled after the side rail: a
/// dark fade from the edge with the gliding lit capsule on the line being spoken.
class SubtitleSyncPanel extends StatefulWidget {
  const SubtitleSyncPanel({
    super.key,
    required this.cues,
    required this.position,
    required this.duration,
    required this.playing,
    required this.onPlayPause,
    required this.onSeekBy,
    required this.offset,
    required this.onOffset,
    required this.onClose,
  });

  /// Lines of the subtitle file in use; empty when none is picked.
  final List<SyncCue> cues;
  final ValueListenable<Duration> position;
  final ValueListenable<Duration> duration;
  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<double> onSeekBy;

  /// Seconds added to every cue's time.
  final double offset;
  final ValueChanged<double> onOffset;
  final VoidCallback onClose;

  @override
  State<SubtitleSyncPanel> createState() => _SubtitleSyncPanelState();
}

class _SubtitleSyncPanelState extends State<SubtitleSyncPanel> {
  double _rowExtent = 84; // less on a phone
  bool _finding = false; // a phone keeps the search box behind a button
  final _query = TextEditingController();
  final _scroll = ScrollController();
  bool _follow = true;
  int _active = -1;
  String? _flash; // "Synced" confirmation

  double get _clock => widget.position.value.inMilliseconds / 1000;

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_onClock);
    _query.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(SubtitleSyncPanel old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_onClock);
      widget.position.addListener(_onClock);
    }
    if (old.cues != widget.cues || old.offset != widget.offset) {
      _active = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _onClock());
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onClock);
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onClock() {
    if (!mounted) return;
    final t = _clock - widget.offset;
    final cues = widget.cues;
    // binary search for the last cue starting at or before t
    var lo = 0, hi = cues.length - 1, a = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= t) {
        a = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (a >= 0 && t >= cues[a].end) a = -1;
    if (a == _active) return;
    setState(() => _active = a);
    if (a >= 0 && _follow && _query.text.isEmpty && _scroll.hasClients) {
      final target = (a * _rowExtent - _scroll.position.viewportDimension * .3).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(target, duration: const Duration(milliseconds: 360), curve: Curves.easeOutCubic);
    }
  }

  void _setOffset(double v) {
    widget.onOffset(double.parse(v.toStringAsFixed(1)));
  }

  void _syncTo(SyncCue c) {
    _setOffset(_clock - c.start);
    setState(() => _flash = 'Synced to “${c.text.split('\n').first}”');
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  Widget _hint(List<SyncCue> cues, double size, {bool left = false}) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: Align(
      key: ValueKey(_flash),
      alignment: left ? Alignment.centerLeft : Alignment.center,
      heightFactor: 1,
      child: Text(
        _flash ?? (cues.isEmpty ? 'Prima scegli un sottotitolo, poi allinealo qui.' : 'Fai partire, ascolta, poi tocca la riga che hai appena sentito.'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: size, color: _flash == null ? VyseColors.textDim : VyseColors.accent),
      ),
    ),
  );

  Widget _playKey(double size) => Pressable(
    tooltip: widget.playing ? 'Pausa' : 'Riproduci',
    onTap: widget.onPlayPause,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .92 : 1,
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: hovered ? Colors.white : const Color(0xFFF1F1F5)),
        child: Icon(widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: size * .5834, color: Colors.black),
      ),
    ),
  );

  Widget _time(double size, {bool total = true}) => ValueListenableBuilder<Duration>(
    valueListenable: widget.position,
    builder: (context, p, _) => Text.rich(
      TextSpan(children: [
        TextSpan(text: _stamp(p.inMilliseconds / 1000), style: TextStyle(fontSize: size, fontWeight: FontWeight.w800)),
        if (total)
          TextSpan(
            text: '  /  ${_stamp(widget.duration.value.inMilliseconds / 1000).split('.').first}',
            style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint),
          ),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    ),
  );

  Widget _offsetValue() => AnimatedDefaultTextStyle(
    duration: const Duration(milliseconds: 200),
    style: DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w800,
        color: widget.offset == 0 ? VyseColors.text : VyseColors.accent,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    child: Text(_signed(widget.offset)),
  );

  List<Widget> _nudges() => [
    for (final d in const [-.5, -.1, .1, .5])
      _Nudge(label: d < 0 ? '−${d.abs()}' : '+$d', onTap: () => _setOffset(widget.offset + d)),
    _Nudge(label: 'Ripristina', onTap: widget.offset == 0 ? null : () => _setOffset(0)),
  ];

  Widget _findBox({bool autofocus = false}) => TextField(
    controller: _query,
    autofocus: autofocus,
    style: const TextStyle(fontSize: 13.5),
    cursorColor: VyseColors.accent,
    decoration: InputDecoration(
      isDense: true,
      hintText: 'Trova una riga',
      hintStyle: const TextStyle(fontSize: 13.5, color: VyseColors.textFaint),
      prefixIcon: const Icon(Icons.search_rounded, size: 19, color: VyseColors.textFaint),
      contentPadding: const EdgeInsets.symmetric(vertical: 11),
      filled: true,
      fillColor: Colors.white.withValues(alpha: .06),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
    ),
  );

  Widget _lines(List<SyncCue> cues, List<int> shown, bool compact) => cues.isEmpty
      ? const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Attiva un sottotitolo dalla scheda Sottotitoli e le sue righe compariranno qui.',
              textAlign: TextAlign.center,
              style: TextStyle(color: VyseColors.textFaint, height: 1.4),
            ),
          ),
        )
      : shown.isEmpty
      ? const Center(child: Text('Nessuna riga corrisponde', style: TextStyle(color: VyseColors.textFaint)))
      : ListView.builder(
          controller: _scroll,
          itemExtent: _rowExtent,
          padding: EdgeInsets.only(bottom: compact ? 14 : 40),
          itemCount: shown.length,
          itemBuilder: (context, k) {
            final i = shown[k];
            return ValueListenableBuilder<Duration>(
              valueListenable: widget.position,
              builder: (context, p, _) {
                final t = p.inMilliseconds / 1000;
                return _CueRow(
                  cue: cues[i],
                  offset: widget.offset,
                  active: i == _active,
                  past: cues[i].end + widget.offset <= t,
                  delta: t - cues[i].start,
                  compact: compact,
                  onSync: () => _syncTo(cues[i]),
                );
              },
            );
          },
        );

  /// Everything a phone needs in two slim rows, so the lines get the screen.
  List<Widget> _phone(List<SyncCue> cues, List<int> shown, {required bool narrow}) => [
    Row(children: [
      _RoundBtn(icon: Icons.replay_5_rounded, tooltip: 'Indietro 5s', size: 36, onTap: () => widget.onSeekBy(-5)),
      const SizedBox(width: 4),
      _playKey(40),
      const SizedBox(width: 4),
      _RoundBtn(icon: Icons.forward_5_rounded, tooltip: 'Avanti 5s', size: 36, onTap: () => widget.onSeekBy(5)),
      const SizedBox(width: 10),
      Expanded(child: _time(14.5, total: !narrow)),
      const SizedBox(width: 6),
      _RoundBtn(
        icon: _finding ? Icons.search_off_rounded : Icons.search_rounded,
        tooltip: 'Trova una riga',
        size: 36,
        on: _finding,
        onTap: () => setState(() {
          _finding = !_finding;
          if (!_finding) _query.clear();
        }),
      ),
      const SizedBox(width: 4),
      _RoundBtn(icon: Icons.my_location_rounded, tooltip: 'Tieni in vista la riga pronunciata', size: 36, on: _follow, onTap: () => setState(() => _follow = !_follow)),
      const SizedBox(width: 4),
      _RoundBtn(icon: Icons.close_rounded, tooltip: 'Chiudi', size: 36, onTap: widget.onClose),
    ]),
    const SizedBox(height: 6),
    SizedBox(
      height: 32,
      child: _finding
          ? _findBox(autofocus: true)
          : Row(children: [
              const SizedBox(width: 4),
              _offsetValue(),
              const Spacer(),
              ..._nudges(),
            ]),
    ),
    const SizedBox(height: 4),
    SizedBox(height: 17, child: _hint(cues, 11.5, left: true)),
    const SizedBox(height: 3),
    Expanded(child: _lines(cues, shown, true)),
  ];

  List<Widget> _roomy(List<SyncCue> cues, List<int> shown) => [
    // Header
    Row(children: [
      const Icon(Icons.subtitles_outlined, size: 26, color: VyseColors.accent),
      const SizedBox(width: 12),
      const Expanded(
        child: Text('Sincronizzazione sottotitoli', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -.3)),
      ),
      _RoundBtn(icon: Icons.close_rounded, tooltip: 'Chiudi', onTap: widget.onClose),
    ]),
    const SizedBox(height: 6),
    _hint(cues, 13),
    const SizedBox(height: 20),
    // Transport
    Row(children: [
      _RoundBtn(icon: Icons.replay_5_rounded, tooltip: 'Indietro 5s', onTap: () => widget.onSeekBy(-5)),
      const SizedBox(width: 6),
      _playKey(48),
      const SizedBox(width: 6),
      _RoundBtn(icon: Icons.forward_5_rounded, tooltip: 'Avanti 5s', onTap: () => widget.onSeekBy(5)),
      const SizedBox(width: 14),
      Expanded(child: _time(17)),
    ]),
    const SizedBox(height: 16),
    // Offset
    Row(children: [
      const Text('OFFSET', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.3, color: VyseColors.textFaint)),
      const SizedBox(width: 10),
      _offsetValue(),
      const Spacer(),
      ..._nudges(),
    ]),
    const SizedBox(height: 16),
    // Search + follow
    Row(children: [
      Expanded(child: SizedBox(height: 40, child: _findBox())),
      const SizedBox(width: 8),
      Pressable(
        tooltip: 'Tieni in vista la riga pronunciata',
        onTap: () => setState(() => _follow = !_follow),
        builder: (context, hovered, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: _follow ? VyseColors.accent.withValues(alpha: .16) : Colors.white.withValues(alpha: hovered ? .1 : .06),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.my_location_rounded, size: 16, color: _follow ? VyseColors.accent : VyseColors.textDim),
            const SizedBox(width: 6),
            Text(
              'Segui',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _follow ? VyseColors.accent : VyseColors.textDim),
            ),
          ]),
        ),
      ),
    ]),
    const SizedBox(height: 12),
    // Lines
    Expanded(child: _lines(cues, shown, false)),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final top = Layout.windowChrome(context);
      final safe = MediaQuery.paddingOf(context);
      final screen = MediaQuery.sizeOf(context);
      final short = screen.height < 520; // a phone on its side
      final compact = short || box.maxWidth < 470;
      final full = box.maxWidth >= screen.width - 1; // the whole screen: no fade at its edge
      _rowExtent = compact ? 54 : 84;
      final q = _query.text.trim().toLowerCase();
      final cues = widget.cues;
      final shown = [
        for (var i = 0; i < cues.length; i++)
          if (q.isEmpty || cues[i].text.toLowerCase().contains(q)) i,
      ];
      return DecoratedBox(
        decoration: BoxDecoration(
          color: full ? const Color(0xF705070D) : null,
          gradient: full
              ? null
              : LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: const [Color(0xF705070D), Color(0xEB05070D), Color(0x0005070D)],
                  stops: compact ? const [0, .92, 1] : const [0, .78, 1],
                ),
        ),
        child: GestureDetector(
          behavior: compact ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
          onTap: () {}, // taps in the panel shouldn't reach the player behind
          child: Padding(
            padding: compact
                ? EdgeInsets.fromLTRB(full ? 12 + safe.left : 30, top + 8, 12 + safe.right, 4 + safe.bottom)
                : EdgeInsets.fromLTRB(56, top + 18, 22, 18 + safe.bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: compact ? _phone(cues, shown, narrow: box.maxWidth < 420) : _roomy(cues, shown)),
          ),
        ),
      );
    },
  );
}

class _CueRow extends StatelessWidget {
  const _CueRow({required this.cue, required this.offset, required this.active, required this.past, required this.delta, required this.onSync, this.compact = false});
  final SyncCue cue;
  final double offset;
  final bool active;
  final bool past;

  /// The offset tapping this line would set.
  final double delta;
  final VoidCallback onSync;
  final bool compact; // a phone: one tight row, and nothing that needs a mouse to show

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onSync,
    builder: (context, hovered, pressed) {
      final sound = cue.text.startsWith('[');
      final color = active || hovered ? VyseColors.text : (past ? const Color(0xFF6E7389) : const Color(0xFF8B90A3));
      return AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        margin: EdgeInsets.symmetric(vertical: compact ? 1 : 2),
        padding: compact ? const EdgeInsets.fromLTRB(10, 4, 8, 4) : const EdgeInsets.fromLTRB(16, 11, 12, 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          // the rail's lit capsule on the spoken line
          gradient: active
              ? LinearGradient(colors: [VyseColors.accent.withValues(alpha: .2), VyseColors.accent.withValues(alpha: .04)])
              : null,
          color: active ? null : Colors.white.withValues(alpha: hovered ? .05 : 0),
          border: Border.all(color: active ? VyseColors.accent.withValues(alpha: .25) : Colors.transparent),
        ),
        child: Row(children: [
          if (compact) ...[
            SizedBox(
              width: 50,
              child: Text(
                _stamp(cue.start + offset),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: active ? VyseColors.accent : VyseColors.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: Text(
                cue.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.28,
                  color: color,
                  fontStyle: sound ? FontStyle.italic : FontStyle.normal,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ] else
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                _stamp(cue.start + offset),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: active ? VyseColors.accent : VyseColors.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                cue.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  color: color,
                  fontStyle: sound ? FontStyle.italic : FontStyle.normal,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ]),
          ),
          if (!compact || active) ...[
          const SizedBox(width: 10),
          AnimatedOpacity(
            opacity: hovered || compact ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            child: AnimatedScale(
              scale: pressed ? .92 : 1,
              duration: const Duration(milliseconds: 120),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Text(
                  'Sincronia  ${_signed(delta)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          ],
        ]),
      );
    },
  );
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.tooltip, required this.onTap, this.size = 40, this.on = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool on;

  @override
  Widget build(BuildContext context) => Pressable(
    tooltip: tooltip,
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .9 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? VyseColors.accent.withValues(alpha: .18) : Colors.white.withValues(alpha: hovered ? .12 : .05),
        ),
        child: Icon(icon, size: size * .525, color: on ? VyseColors.accent : VyseColors.text),
      ),
    ),
  );
}

class _Nudge extends StatelessWidget {
  const _Nudge({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withValues(alpha: onTap == null ? .02 : (hovered ? .12 : .06)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: onTap == null ? VyseColors.textFaint : VyseColors.text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ),
  );
}
