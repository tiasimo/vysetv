import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, EditableText, FocusManager;
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:shared_preferences/shared_preferences.dart';

import '../account.dart';
import '../net.dart';
import 'rooms.dart';
import 'voice_background.dart';

enum VoiceState { off, connecting, on }

/// Voice in your Party room: LiveKit over WebRTC, through our own LiveKit server (the token
/// comes from PocketBase, only for members of the room). One call at a time; leaving the room
/// ends it.
class Voice {
  static final state = ValueNotifier<VoiceState>(VoiceState.off);
  static final micOn = ValueNotifier<bool>(true);
  static final deafened = ValueNotifier<bool>(false);

  /// Who's talking right now (user ids).
  static final speaking = ValueNotifier<Set<String>>(const {});

  /// Everyone in the call (user id → their mic is on), you included.
  static final inCall = ValueNotifier<Map<String, bool>>(const {});

  /// Per-person volume you chose (user id → 0..2), kept across calls.
  static final volumes = <String, double>{};

  // Microphone clean-up (WebRTC's own), saved on this device. Turning noise suppression off
  // sounds more natural on a good mic; on means less background noise but can sound muffled.
  static final noiseSuppression = ValueNotifier<bool>(true);
  static final echoCancellation = ValueNotifier<bool>(true);
  static final autoGain = ValueNotifier<bool>(true);

  /// Push to talk: the mic stays muted except while [pttKey] (desktop) or the talk button (phones)
  /// is held. Handy without headphones during a watch party.
  static final pushToTalk = ValueNotifier<bool>(false);
  static final pttKey = ValueNotifier<LogicalKeyboardKey>(LogicalKeyboardKey.backquote);

  /// The push-to-talk key or button is held right now.
  static final talking = ValueNotifier<bool>(false);

  /// Opus at 64 kbps, sent continuously: no DTX, which clips the first and last syllables, and
  /// enough bitrate that voices don't sound underwater. RED adds a backup copy against loss.
  static const _publish = lk.AudioPublishOptions(dtx: false, red: true, encoding: lk.AudioEncoding(maxBitrate: 64000));

  static lk.AudioCaptureOptions get _capture => lk.AudioCaptureOptions(
    deviceId: lk.Hardware.instance.selectedAudioInput?.deviceId,
    noiseSuppression: noiseSuppression.value,
    echoCancellation: echoCancellation.value,
    autoGainControl: autoGain.value,
    highPassFilter: true,
    voiceIsolation: noiseSuppression.value,
    typingNoiseDetection: false, // it gates your voice while you type
    // push to talk mutes and unmutes constantly: keep the mic open so the first word isn't lost
    stopAudioCaptureOnMute: !pushToTalk.value,
  );

  /// Whether your mic should be sending right now.
  static bool get _sending => canTalk && !deafened.value && (pushToTalk.value ? talking.value : micOn.value);

  static Future<void> _applyMic() async {
    await _room?.localParticipant?.setMicrophoneEnabled(_sending);
    _refresh();
  }

  static lk.Room? _room;
  static lk.EventsListener<lk.RoomEvent>? _events;
  static String? _roomId;

  static bool get canTalk => _room?.localParticipant?.permissions.canPublish ?? true;

  static Future<void> start() async {
    Rooms.mine.addListener(_roomChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    // a key released while another window had focus never arrives: let go when we lose focus
    AppLifecycleListener(onInactive: () => setTalking(false), onHide: () => setTalking(false));
    try {
      final prefs = await SharedPreferences.getInstance();
      noiseSuppression.value = prefs.getBool('voice.ns') ?? true;
      echoCancellation.value = prefs.getBool('voice.ec') ?? true;
      autoGain.value = prefs.getBool('voice.agc') ?? true;
      pushToTalk.value = prefs.getBool('voice.ptt') ?? false;
      final key = LogicalKeyboardKey.findKeyByKeyId(prefs.getInt('voice.pttKey') ?? -1);
      if (key != null) pttKey.value = key;
    } catch (_) {}
  }

  /// Push-to-talk key, held anywhere in the app (except while typing in a text box).
  static bool _onKey(KeyEvent e) {
    if (!pushToTalk.value || state.value != VoiceState.on || e.logicalKey != pttKey.value) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null && focus.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    if (e is KeyDownEvent) setTalking(true);
    if (e is KeyUpEvent) setTalking(false);
    return true;
  }

  static void setTalking(bool on) {
    if (talking.value == on) return;
    talking.value = on;
    if (pushToTalk.value) unawaited(_applyMic());
  }

  static Future<void> setPushToTalk(bool on, {LogicalKeyboardKey? key}) async {
    pushToTalk.value = on;
    if (key != null) pttKey.value = key;
    talking.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('voice.ptt', on);
      await prefs.setInt('voice.pttKey', pttKey.value.keyId);
    } catch (_) {}
    // the mic restarts with the right capture mode (kept open for push to talk)
    final lp = _room?.localParticipant;
    if (lp == null) return;
    for (final pub in [...lp.audioTrackPublications]) {
      await lp.removePublishedTrack(pub.sid);
    }
    await lp.setMicrophoneEnabled(_sending, audioCaptureOptions: _capture);
    _refresh();
  }

  /// Changes the mic clean-up; during a call the mic restarts with it (a short blip).
  static Future<void> setProcessing({bool? noise, bool? echo, bool? gain}) async {
    if (noise != null) noiseSuppression.value = noise;
    if (echo != null) echoCancellation.value = echo;
    if (gain != null) autoGain.value = gain;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('voice.ns', noiseSuppression.value);
      await prefs.setBool('voice.ec', echoCancellation.value);
      await prefs.setBool('voice.agc', autoGain.value);
    } catch (_) {}
    final lp = _room?.localParticipant;
    if (lp == null) return;
    for (final pub in [...lp.audioTrackPublications]) {
      await lp.removePublishedTrack(pub.sid);
    }
    await lp.setMicrophoneEnabled(_sending, audioCaptureOptions: _capture);
    _refresh();
  }

  // leaving (or being removed from) the room hangs up
  static void _roomChanged() {
    if (_roomId != null && Rooms.mine.value?.id != _roomId) unawaited(leave());
  }

  /// Joins the voice call of the room you're in.
  static Future<void> join() async {
    final r = Rooms.mine.value;
    if (r == null || state.value != VoiceState.off) return;
    state.value = VoiceState.connecting;
    try {
      final j = await Account.pb.send('/api/vyse/rooms/voice', method: 'POST') as Map<String, dynamic>;
      final room = lk.Room(
        roomOptions: lk.RoomOptions(adaptiveStream: false, dynacast: false, defaultAudioCaptureOptions: _capture, defaultAudioPublishOptions: _publish),
      );
      _room = room;
      _roomId = r.id;
      _events = room.createListener()
        ..on<lk.RoomDisconnectedEvent>((_) => unawaited(_ended()))
        ..on<lk.ActiveSpeakersChangedEvent>((e) => speaking.value = {for (final p in e.speakers) p.identity})
        ..on<lk.ParticipantConnectedEvent>((_) => _refresh())
        ..on<lk.ParticipantDisconnectedEvent>((_) => _refresh())
        ..on<lk.TrackMutedEvent>((_) => _refresh())
        ..on<lk.TrackUnmutedEvent>((_) => _refresh())
        ..on<lk.LocalTrackPublishedEvent>((_) => _refresh())
        ..on<lk.TrackSubscribedEvent>((e) {
          final t = e.track;
          if (t is lk.RemoteAudioTrack) unawaited(_applyListening(e.participant.identity, t));
          _refresh();
        })
        ..on<lk.ParticipantPermissionsUpdatedEvent>((e) async {
          // the owner muted or unmuted you
          if (e.participant is lk.LocalParticipant) await room.localParticipant?.setMicrophoneEnabled(_sending);
          _refresh();
        });
      // the call's signalling goes to the same server: through the same DNS workaround
      await withResilientHttp(() => room.connect(j['url'] as String, j['token'] as String));
      // the first publish always sets up the mic (muted straight away for push to talk)
      await room.localParticipant?.setMicrophoneEnabled(canTalk && !deafened.value, audioCaptureOptions: _capture);
      if (!_sending) await room.localParticipant?.setMicrophoneEnabled(false);
      state.value = VoiceState.on;
      _refresh();
      unawaited(VoiceBackground.start());
    } catch (e) {
      await _cleanup();
      rethrow;
    }
  }

  static Future<void> leave() async {
    final room = _room;
    await _cleanup();
    await room?.disconnect();
  }

  static Future<void> _ended() => _cleanup();

  static Future<void> _cleanup() async {
    final room = _room, events = _events;
    _room = null;
    _events = null;
    _roomId = null;
    talking.value = false;
    state.value = VoiceState.off;
    unawaited(VoiceBackground.stop());
    speaking.value = const {};
    inCall.value = const {};
    await events?.dispose();
    await room?.dispose();
  }

  static Future<void> toggleMic() async {
    if (deafened.value) return toggleDeafen(); // talking again also means hearing again
    micOn.value = !micOn.value;
    await _applyMic();
  }

  /// Deafened: you hear nobody and your mic is off.
  static Future<void> toggleDeafen() async {
    deafened.value = !deafened.value;
    if (deafened.value) micOn.value = false;
    final room = _room;
    if (room == null) return;
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.audioTrackPublications) {
        final t = pub.track;
        if (t != null) await _applyListening(p.identity, t);
      }
    }
    if (!deafened.value) micOn.value = true;
    await _applyMic();
  }

  /// How loud someone is for you (0 to 2; 1 is normal).
  static Future<void> setVolume(String user, double volume) async {
    volumes[user] = volume;
    final p = _room?.remoteParticipants[user];
    if (p == null) return;
    for (final pub in p.audioTrackPublications) {
      final t = pub.track;
      if (t != null) await _applyListening(user, t);
    }
  }

  static Future<void> _applyListening(String user, lk.RemoteAudioTrack t) async {
    if (deafened.value) {
      await t.disable();
      return;
    }
    await t.enable();
    final v = volumes[user];
    if (v != null && !kIsWeb) await Helper.setVolume(v, t.mediaStreamTrack);
  }

  static void _refresh() {
    final room = _room;
    if (room == null) {
      inCall.value = const {};
      return;
    }
    inCall.value = {
      if (room.localParticipant != null) room.localParticipant!.identity: room.localParticipant!.isMicrophoneEnabled(),
      for (final p in room.remoteParticipants.values) p.identity: p.isMicrophoneEnabled(),
    };
  }

  // ── devices (desktop) ──

  static Future<List<lk.MediaDevice>> inputs() => lk.Hardware.instance.audioInputs();
  static Future<List<lk.MediaDevice>> outputs() => lk.Hardware.instance.audioOutputs();

  /// Whether sound looks to be going to headphones, going by the output's name. A hint only:
  /// Windows often calls a plugged-in headset "Speakers".
  static Future<bool> onHeadphones() async {
    try {
      final all = await outputs();
      final now = lk.Hardware.instance.selectedAudioOutput ?? (all.isEmpty ? null : all.first);
      return now != null && RegExp(r'head(phone|set)|ear(phone|bud)|airpods|\bbuds\b|bluetooth|wired', caseSensitive: false).hasMatch(now.label);
    } catch (_) {
      return false;
    }
  }

  static String? get inputId => lk.Hardware.instance.selectedAudioInput?.deviceId;
  static String? get outputId => lk.Hardware.instance.selectedAudioOutput?.deviceId;

  static Future<void> useInput(lk.MediaDevice d) async {
    final room = _room;
    room == null ? await lk.Hardware.instance.selectAudioInput(d) : await room.setAudioInputDevice(d);
  }

  static Future<void> useOutput(lk.MediaDevice d) async {
    final room = _room;
    room == null ? await lk.Hardware.instance.selectAudioOutput(d) : await room.setAudioOutputDevice(d);
  }
}
