import '../player_native.dart';
import '../video_rect_support.dart';

/// Lorewatch addition: Plezy's Android mpv backend, plus [VideoRectSupport].
///
/// Plezy only plays full screen, so its Android video container always fills
/// the window. Lorewatch also shows video inside watch-party tiles, so the
/// container is moved to the [Video] widget's bounds (`setVideoRect` in
/// MpvPlayerCore.kt / MpvPlayerPlugin.kt, marked "Lorewatch").
class PlayerAndroidMpv extends PlayerNative with VideoRectSupport {
  PlayerAndroidMpv({super.hardwareDecoding});
}
