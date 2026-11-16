// Lorewatch stand-in for Plezy's `utils/app_logger.dart`, which the copied
// player imports. Same call shape (`appLogger.d/i/w/e(message, error:,
// stackTrace:)`), printed through debugPrint so release builds stay quiet.

import 'package:flutter/foundation.dart';

class PlayerLogger {
  const PlayerLogger._();

  void d(Object? message, {Object? error, StackTrace? stackTrace}) => _log('D', message, error, stackTrace);
  void i(Object? message, {Object? error, StackTrace? stackTrace}) => _log('I', message, error, stackTrace);
  void w(Object? message, {Object? error, StackTrace? stackTrace}) => _log('W', message, error, stackTrace);
  void e(Object? message, {Object? error, StackTrace? stackTrace}) => _log('E', message, error, stackTrace);

  void _log(String level, Object? message, Object? error, StackTrace? stackTrace) {
    if (!kDebugMode && level != 'E' && level != 'W') return;
    debugPrint('[mpv $level] $message${error != null ? ' ($error)' : ''}');
    if (stackTrace != null && level == 'E') debugPrint(stackTrace.toString());
  }
}

const appLogger = PlayerLogger._();
