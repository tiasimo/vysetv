import '../player_native.dart';
import '../video_rect_support.dart';

/// Lorewatch addition: Plezy's iOS/macOS mpv backend, plus [VideoRectSupport].
///
/// Plezy's Apple video layer always fills the window; Lorewatch also shows video
/// inside watch-party tiles, so the layer follows the [Video] widget's bounds
/// (`setVideoRect` / `vyseSetVideoRect` in Runner/MpvPlayer, marked "Lorewatch").
class PlayerAppleMpv extends PlayerNative with VideoRectSupport {
  PlayerAppleMpv();
}
