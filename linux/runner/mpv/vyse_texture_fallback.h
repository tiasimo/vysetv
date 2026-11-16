#ifndef VYSE_TEXTURE_FALLBACK_H_
#define VYSE_TEXTURE_FALLBACK_H_

// VyseTV addition (not upstream Plezy).
//
// Plezy plays video only on a native Wayland plane under the Flutter window and
// refuses every other session. Where the plane cannot come up (X11, or a
// Wayland compositor that turns it down) VyseTV falls back to a Flutter
// texture: SDR only and two extra copies per frame, but it plays.
//
// How a frame travels:
//   1. mpv renders with its normal GPU renderer, on a thread of its own, into
//      an OpenGL ES context of its own (EGL, surfaceless, on the display
//      Flutter already uses).
//   2. The finished picture is read back into memory (glReadPixels).
//   3. Flutter's raster thread uploads it into a texture in Flutter's own
//      context when it next draws (FlTextureGL::populate).
//
// Nothing is shared between the two GL contexts, on purpose. Since Flutter 3.3x
// the Linux embedder draws with EGL contexts it creates itself, which are not
// in GDK's share group (on X11 GDK uses GLX), so a texture made in a
// gdk_window_create_gl_context() context is not visible to Flutter at all.
// Going through memory needs nothing beyond what Flutter itself needs to run.

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <mpv/client.h>

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

typedef struct _VyseMpvTexture VyseMpvTexture;

namespace vyse {

class TextureFallback {
 public:
  TextureFallback() = default;
  ~TextureFallback();
  TextureFallback(const TextureFallback&) = delete;
  TextureFallback& operator=(const TextureFallback&) = delete;

  // True where the fallback can run: an X11 or Wayland display.
  static bool Supported(GtkWidget* view);

  // Registers the Flutter texture and starts the render thread, which creates
  // mpv's render context (mpv's vo must be libmpv). Returns once that context
  // exists, so a file opened right afterwards finds a video output. On failure
  // |error| says why. Main thread.
  bool Start(FlPluginRegistrar* registrar, GtkWidget* view, mpv_handle* mpv, std::string* error);

  // Stops the render thread, which frees mpv's render context, then drops the
  // texture. Must run before the mpv core is destroyed; safe to call twice.
  // Main thread.
  void Stop();

  int64_t texture_id() const { return texture_id_; }

  // Physical pixel size of the Video widget; mpv renders at this size (capped,
  // see the .cc) and letterboxes itself. Main thread.
  void SetSize(int width, int height);

  // Draws again although mpv has no new frame (the picture on screen is stale).
  void Redraw();

 private:
  static void OnMpvUpdate(void* ctx);
  static gboolean NotifyIdle(gpointer data);
  void RenderThread(mpv_handle* mpv);
  bool EnsureTarget(int width, int height);
  void ReleaseTarget();
  void RenderFrame(void* render_context, int width, int height);

  // Main thread.
  FlTextureRegistrar* registrar_ = nullptr;
  VyseMpvTexture* texture_ = nullptr;
  int64_t texture_id_ = -1;
  std::thread thread_;

  // Set before the thread starts, read-only afterwards.
  void* egl_display_ = nullptr;  // EGLDisplay
  bool flip_ = false;
  bool full_resolution_ = false;

  // Shared, under lock_. mpv's update callback runs on an mpv thread and only
  // ever sets wake_.
  std::mutex lock_;
  std::condition_variable wake_cv_;
  std::condition_variable start_cv_;
  bool stop_ = false;
  bool wake_ = false;
  bool redraw_ = false;
  bool started_ = false;
  bool start_ok_ = false;
  std::string start_error_;
  int want_w_ = 1280;
  int want_h_ = 720;
  guint idle_ = 0;

  // Render thread only.
  unsigned int fbo_ = 0;
  unsigned int tex_ = 0;
  int target_w_ = 0;
  int target_h_ = 0;
  uint8_t* back_ = nullptr;
  size_t back_capacity_ = 0;
};

}  // namespace vyse

#endif  // VYSE_TEXTURE_FALLBACK_H_
