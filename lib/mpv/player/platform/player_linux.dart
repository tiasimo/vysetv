import '../player_native.dart';
import '../video_rect_support.dart';

/// Uses libmpv on a native Wayland video plane — Linux's only render path.
///
/// Video goes to a `wl_subsurface` stacked below the Flutter surface, the same
/// shape Windows gets from a child HWND: geometry arrives via
/// [VideoRectSupport.setVideoRect] and Flutter never composites the frames.
/// A session that cannot host the plane fails `initialize` outright rather than
/// degrading, so the user sees the reason instead of a black rectangle.
///
/// Lorewatch: on X11, where the plane can't exist, the native side draws mpv into
/// a Flutter texture instead (linux/runner/mpv/vyse_texture_fallback.h);
/// [vyseTextureId] says which, and `VyseVideo` shows it.
class PlayerLinux extends PlayerNative with VideoRectSupport {
  /// The Flutter texture the X11 fallback draws into, or null on the Wayland plane
  /// (or before the player has started).
  Future<int?> vyseTextureId() async {
    try {
      return await invoke<int>('vyseTextureId');
    } catch (_) {
      return null;
    }
  }
}
