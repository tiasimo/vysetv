// Lorewatch additions to Plezy's player (not upstream).
//
// Lorewatch's player page reads two things Plezy's streams don't carry: the
// current subtitle line as text (the subtitle sync panel and the optional
// Flutter subtitle overlay) and the displayed video size. Both come from
// plain mpv properties observed next to Plezy's own (`sub-text`,
// `dwidth`/`dheight`). Kept in this one file so upstream merges of Plezy's
// player only ever touch the three hook lines marked "Lorewatch" in
// player_base.dart.

import 'dart:async';

mixin VyseExtrasMixin {
  final _subTextController = StreamController<String>.broadcast();
  final _videoSizeController = StreamController<(int, int)>.broadcast();

  String _subText = '';
  int _videoWidth = 0;
  int _videoHeight = 0;

  /// The subtitle line mpv is showing right now ('' when none).
  String get currentSubText => _subText;

  /// Every change of [currentSubText].
  Stream<String> get subText => _subTextController.stream;

  /// Displayed video size in pixels (after aspect correction), (0, 0) before
  /// the first frame.
  (int, int) get currentVideoSize => (_videoWidth, _videoHeight);

  /// Every change of [currentVideoSize].
  Stream<(int, int)> get videoSize => _videoSizeController.stream;

  /// mpv properties these streams need, registered with the core ones.
  static const List<(String, String)> vyseObservations = [
    ('sub-text', 'string'),
    ('dwidth', 'int64'),
    ('dheight', 'int64'),
  ];

  /// Returns true when [name] was one of ours (the caller can stop there).
  bool vyseHandleProperty(String name, dynamic value) {
    switch (name) {
      case 'sub-text':
        final text = value is String ? value : '';
        if (text != _subText) {
          _subText = text;
          if (!_subTextController.isClosed) _subTextController.add(text);
        }
        return true;
      case 'dwidth':
      case 'dheight':
        final v = value is num ? value.toInt() : 0;
        final w = name == 'dwidth' ? v : _videoWidth;
        final h = name == 'dheight' ? v : _videoHeight;
        if (w != _videoWidth || h != _videoHeight) {
          _videoWidth = w;
          _videoHeight = h;
          if (!_videoSizeController.isClosed) _videoSizeController.add((w, h));
        }
        return true;
    }
    return false;
  }

  /// Clears per-file values when a new source opens.
  void vyseResetForNewFile() {
    _subText = '';
    if (!_subTextController.isClosed) _subTextController.add('');
  }

  Future<void> closeVyseExtras() async {
    await _subTextController.close();
    await _videoSizeController.close();
  }
}
