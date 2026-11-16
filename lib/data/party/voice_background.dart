import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void _voiceTask() => FlutterForegroundTask.setTaskHandler(_VoiceTask());

/// Nothing to do in the background itself: the service only has to exist so Android keeps the
/// microphone and the call running while the app is out of sight.
class _VoiceTask extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Android: a "You're in a voice call" notification (a microphone foreground service) while in
/// voice, so switching apps or locking the phone doesn't cut the call.
class VoiceBackground {
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> start() async {
    if (!_android) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'vyse_voice',
          channelName: 'Voice chat',
          channelDescription: 'Keeps Party voice going while Lorewatch is in the background',
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), allowWakeLock: true, allowWifiLock: true),
      );
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 717,
        serviceTypes: [ForegroundServiceTypes.microphone],
        notificationTitle: 'Lorewatch voice',
        notificationText: "You're in a voice call",
        callback: _voiceTask,
      );
    } catch (_) {
      // no notification permission or an older Android quirk: voice still works in the foreground
    }
  }

  static Future<void> stop() async {
    if (!_android) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
