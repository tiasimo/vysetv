import 'dart:async';

import 'package:flutter/foundation.dart';

/// One thing plays at a time. Music, audiobooks and Live TV call [claim] before they start;
/// whoever held focus before is told to pause. [owner] tells the shell which mini player to show.
class AudioFocus {
  static final owner = ValueNotifier<Object?>(null);
  static VoidCallback? _pause;

  static void claim(Object who, VoidCallback pause) {
    if (owner.value != null && !identical(owner.value, who)) _pause?.call();
    owner.value = who;
    _pause = pause;
  }

  /// Safe to call from dispose(): listeners hear about it after the tree is unlocked.
  static void release(Object who) {
    if (!identical(owner.value, who)) return;
    _pause = null;
    scheduleMicrotask(() {
      if (identical(owner.value, who)) owner.value = null;
    });
  }
}
