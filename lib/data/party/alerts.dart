import 'dart:async';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

import '../account.dart';
import '../app_settings.dart';
import 'dms.dart';
import 'rooms.dart';

/// Party's sounds: one family of soft mallet tones (assets/sounds). Rising means arriving,
/// falling means leaving; yours are three notes, everyone else's two.
enum PartySound {
  message,
  join, // someone came into your room
  leave, // someone left it
  connect, // you joined a room
  disconnect; // you left it

}

/// People whose messages don't make a sound, a notification or a taskbar flash (their messages
/// still arrive). Kept in the synced settings, so it follows your account.
class PartyMutes {
  static Set<String> get ids => {for (final s in AppSettings.partyMuted.value.split(',')) if (s.isNotEmpty) s};
  static bool has(String id) => ids.contains(id);

  static void toggle(String id) {
    final s = ids;
    if (!s.remove(id)) s.add(id);
    AppSettings.partyMuted.set(s.join(','));
  }
}

/// What Party does to get your attention while VyseTV is running: sounds for people coming and
/// going and for messages; a system notification (and, on Windows, a flashing taskbar button)
/// for a message when you're not looking at the app; and the unread count as a red badge on the
/// taskbar button, like Discord. Nothing for muted people, or while you're on Do not disturb.
class PartyAlerts {
  static final _notes = FlutterLocalNotificationsPlugin();
  static bool _notesReady = false;
  static const _taskbar = MethodChannel('vyse/taskbar');
  static final _players = <PartySound, ap.AudioPlayer>{};

  /// The shell opens what a tapped notification points at: `dm:<user id>` or `room`.
  static void Function(String target)? onOpen;

  /// Room chats on screen right now (their messages make no sound).
  static int roomChatsOpen = 0;

  static PartyRoom? _room;
  static int _badge = -1;
  static final _notified = <String>{}; // senders with a notification up

  static bool get _windows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _desktop =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);

  static Future<void> start() async {
    _room = Rooms.mine.value;
    Rooms.mine.addListener(_roomChanged);
    Dms.events.listen(_dm);
    Rooms.messages.listen(_roomMessage);
    Dms.threads.addListener(_unreadChanged);
    Dms.badge.addListener(_unreadChanged);
    AppSettings.partyMuted.addListener(_unreadChanged);
    await _initNotifications();
  }

  // ── sounds ──

  static Future<void> play(PartySound s) async {
    if (!AppSettings.partySounds.value) return;
    try {
      // Short bundled tones: audioplayers, so they never take one of the mpv cores
      // the video and music players use.
      final p = _players[s] ??= ap.AudioPlayer(playerId: 'party-${s.name}');
      await p.stop();
      await p.play(ap.AssetSource('sounds/${s.name}.wav'), volume: .8);
    } catch (_) {}
  }

  static bool get _quiet => Account.user.value?.statusMode == 'dnd';

  /// You joined or left; people came or went from the room you're in.
  static void _roomChanged() {
    final was = _room, now = Rooms.mine.value;
    _room = now;
    if (Account.user.value == null || _quiet) return;
    if (now == null) {
      if (was != null) play(PartySound.disconnect);
      return;
    }
    if (was == null || was.id != now.id) {
      // only when you joined (not when the app finds you already in a room as it starts)
      if (Rooms.acting) play(PartySound.connect);
      return;
    }
    final before = {for (final m in was.members) if (!m.isMe) m.id};
    final after = {for (final m in now.members) if (!m.isMe) m.id};
    if (after.difference(before).isNotEmpty) {
      play(PartySound.join);
    } else if (before.difference(after).isNotEmpty) {
      play(PartySound.leave);
    }
  }

  // ── messages ──

  /// Whether VyseTV is the window you're using.
  static Future<bool> _focused() async {
    if (_desktop) {
      try {
        return await windowManager.isFocused() && await windowManager.isVisible() && !await windowManager.isMinimized();
      } catch (_) {}
    }
    return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  static Future<void> _dm((String, DmMessage) ev) async {
    final (action, m) = ev;
    if (action != 'create' || m.mine || _quiet || PartyMutes.has(m.sender)) return;
    final focused = await _focused();
    if (focused && Dms.openWith == m.sender) return; // you're reading it
    final who = Dms.threads.value.where((t) => t.partner.id == m.sender).firstOrNull?.partner.name ?? 'A friend';
    if (focused) {
      play(PartySound.message); // the shell shows it in the app
      return;
    }
    // Android's notification plays the same sound itself (and respects silent mode)
    if (!_android || !_notesReady) play(PartySound.message);
    _notified.add(m.sender);
    await _notify(m.sender.hashCode & 0x7fffffff, who, m.body, 'dm:${m.sender}');
    _flash();
  }

  static Future<void> _roomMessage(RoomMessage m) async {
    if (m.mine || _quiet || PartyMutes.has(m.user)) return;
    final focused = await _focused();
    if (focused && roomChatsOpen > 0) return; // you're in the chat
    if (focused) {
      play(PartySound.message);
      return;
    }
    if (!_android || !_notesReady) play(PartySound.message);
    final room = Rooms.mine.value?.name ?? 'your room';
    await _notify('room'.hashCode & 0x7fffffff, '${m.name} in $room', m.body, 'room');
    _flash();
  }

  // ── system notifications ──

  static Future<void> _initNotifications() async {
    try {
      await _notes.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
          windows: WindowsInitializationSettings(appName: 'VyseTV', appUserModelId: 'Vyse.VyseTV', guid: '6f1d3c2a-8b4e-4f7a-9c5d-2e8b1a7f3d64'),
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
          macOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
          // Linux: without this the plugin refuses to start and there are no notifications at all
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (r) => _open(r.payload),
      );
      _notesReady = true;
      if (_android && Account.signedIn) {
        await _notes.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      }
      // iPhone, iPad and Mac show nothing until asked once (the same moment Android asks)
      if (!kIsWeb && Account.signedIn) {
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          await _notes.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true);
        } else if (defaultTargetPlatform == TargetPlatform.macOS) {
          await _notes.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true);
        }
      }
    } catch (_) {
      // no notifications on this system: sounds and the in-app pop-up still work
    }
  }

  static Future<void> _notify(int id, String title, String body, String payload) async {
    if (!_notesReady) return;
    try {
      await _notes.show(
        id: id,
        title: title,
        body: body.replaceAll('\n', ' '),
        payload: payload,
        notificationDetails: NotificationDetails(
          android: const AndroidNotificationDetails(
            'vyse_messages',
            'Messages',
            channelDescription: 'Direct messages and room chat in Party',
            importance: Importance.high,
            priority: Priority.high,
            icon: 'ic_notification',
            color: Color(0xFF7C5CFF),
            sound: RawResourceAndroidNotificationSound('vyse_message'),
            category: AndroidNotificationCategory.message,
          ),
          windows: WindowsNotificationDetails(audio: WindowsNotificationAudio.silent()),
          iOS: const DarwinNotificationDetails(presentSound: false),
          macOS: const DarwinNotificationDetails(presentSound: false),
        ),
      );
    } catch (_) {}
  }

  static Future<void> _open(String? payload) async {
    if (payload == null) return;
    if (_desktop) {
      try {
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
    onOpen?.call(payload);
  }

  // ── Windows taskbar ──

  /// The taskbar button flashes until you switch to VyseTV.
  static void _flash() {
    if (_windows) _taskbar.invokeMethod<void>('flash').catchError((Object _) {});
  }

  /// Unread messages from people you haven't muted, plus friend requests.
  static int get unread {
    final muted = PartyMutes.ids;
    final mutedUnread = Dms.threads.value.where((t) => muted.contains(t.partner.id)).fold<int>(0, (n, t) => n + t.unread);
    return (Dms.badge.value - mutedUnread).clamp(0, 1 << 20);
  }

  static void _unreadChanged() {
    // read conversations take their notification with them
    for (final t in Dms.threads.value) {
      if (t.unread == 0 && _notified.remove(t.partner.id)) {
        _notes.cancel(id: t.partner.id.hashCode & 0x7fffffff).catchError((Object _) {});
      }
    }
    _setBadge(unread);
  }

  /// A red dot with the count on the taskbar button (cleared at 0).
  static Future<void> _setBadge(int n) async {
    if (!_windows || n == _badge) return;
    _badge = n;
    try {
      if (n <= 0) return await _taskbar.invokeMethod<void>('badge');
      const size = 32;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawCircle(const Offset(size / 2, size / 2), size / 2, Paint()..color = const Color(0xFFF23F43));
      final tp = TextPainter(
        text: TextSpan(
          text: n > 9 ? '9+' : '$n',
          style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: n > 9 ? 16 : 21, fontWeight: FontWeight.w800, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset((size - tp.width) / 2, (size - tp.height) / 2));
      final img = await rec.endRecording().toImage(size, size);
      final px = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      img.dispose();
      if (px == null || _badge != n) return;
      await _taskbar.invokeMethod<void>('badge', {'w': size, 'h': size, 'rgba': px.buffer.asUint8List(), 'label': '$n unread'});
    } catch (_) {}
  }
}
