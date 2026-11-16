// epoxy must come before any other GL header.
#include <epoxy/egl.h>
#include <epoxy/gl.h>

#include "vyse_texture_fallback.h"

#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <system_error>
#include <utility>

// Last: the X11 headers define short macros (None, Status, Bool, ...).
#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

// ── the Flutter texture: uploads the newest finished frame when Flutter draws ──

G_DECLARE_FINAL_TYPE(VyseMpvTexture, vyse_mpv_texture, VYSE, MPV_TEXTURE, FlTextureGL)

struct _VyseMpvTexture {
  FlTextureGL parent_instance;

  GMutex lock;
  // Newest frame from the render thread (under lock).
  uint8_t* pending;
  size_t pending_capacity;
  uint32_t pending_width;
  uint32_t pending_height;
  gboolean has_pending;

  // The frame on screen (Flutter's raster thread only). Tightly packed RGBA,
  // top row first.
  uint8_t* front;
  size_t front_capacity;
  uint32_t front_width;
  uint32_t front_height;
  // What this object last put into the GL texture.
  uint32_t uploaded_width;
  uint32_t uploaded_height;
};

G_DEFINE_TYPE(VyseMpvTexture, vyse_mpv_texture, fl_texture_gl_get_type())

// The GL texture Flutter samples. It lives in Flutter's own context, which is
// only ever current inside populate(), so it cannot be deleted from anywhere
// else; one name is kept for the life of the app and reused by every player.
static GLuint g_flutter_texture = 0;

static gboolean vyse_mpv_texture_populate(FlTextureGL* texture, uint32_t* target, uint32_t* name, uint32_t* width,
                                          uint32_t* height, GError** error) {
  (void)error;
  VyseMpvTexture* self = VYSE_MPV_TEXTURE(texture);

  gboolean fresh = FALSE;
  g_mutex_lock(&self->lock);
  if (self->has_pending) {
    std::swap(self->front, self->pending);
    std::swap(self->front_capacity, self->pending_capacity);
    std::swap(self->front_width, self->pending_width);
    std::swap(self->front_height, self->pending_height);
    self->has_pending = FALSE;
    fresh = TRUE;
  }
  g_mutex_unlock(&self->lock);

  if (g_flutter_texture == 0) {
    glGenTextures(1, &g_flutter_texture);
    glBindTexture(GL_TEXTURE_2D, g_flutter_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  } else {
    glBindTexture(GL_TEXTURE_2D, g_flutter_texture);
  }

  const bool same_size = self->uploaded_width == self->front_width && self->uploaded_height == self->front_height;
  if (!same_size) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, static_cast<GLsizei>(self->front_width),
                 static_cast<GLsizei>(self->front_height), 0, GL_RGBA, GL_UNSIGNED_BYTE, self->front);
    self->uploaded_width = self->front_width;
    self->uploaded_height = self->front_height;
  } else if (fresh) {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(self->front_width),
                    static_cast<GLsizei>(self->front_height), GL_RGBA, GL_UNSIGNED_BYTE, self->front);
  }

  *target = GL_TEXTURE_2D;
  *name = g_flutter_texture;
  *width = self->front_width;
  *height = self->front_height;
  return TRUE;
}

static void vyse_mpv_texture_finalize(GObject* object) {
  VyseMpvTexture* self = VYSE_MPV_TEXTURE(object);
  g_free(self->pending);
  g_free(self->front);
  g_mutex_clear(&self->lock);
  G_OBJECT_CLASS(vyse_mpv_texture_parent_class)->finalize(object);
}

static void vyse_mpv_texture_class_init(VyseMpvTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = vyse_mpv_texture_populate;
  G_OBJECT_CLASS(klass)->finalize = vyse_mpv_texture_finalize;
}

static void vyse_mpv_texture_init(VyseMpvTexture* self) {
  g_mutex_init(&self->lock);
  self->pending = nullptr;
  self->pending_capacity = 0;
  self->pending_width = 0;
  self->pending_height = 0;
  self->has_pending = FALSE;
  // One opaque black pixel until the first frame, so populate() never fails
  // (a failure is logged by the engine on every frame Flutter draws).
  self->front = static_cast<uint8_t*>(g_malloc(4));
  self->front[0] = 0;
  self->front[1] = 0;
  self->front[2] = 0;
  self->front[3] = 255;
  self->front_capacity = 4;
  self->front_width = 1;
  self->front_height = 1;
  self->uploaded_width = 0;
  self->uploaded_height = 0;
}

// Render thread: hands over a finished frame and takes a spare buffer back.
static void vyse_mpv_texture_publish(VyseMpvTexture* self, uint8_t** data, size_t* capacity, uint32_t width,
                                     uint32_t height) {
  g_mutex_lock(&self->lock);
  std::swap(self->pending, *data);
  std::swap(self->pending_capacity, *capacity);
  self->pending_width = width;
  self->pending_height = height;
  self->has_pending = TRUE;
  g_mutex_unlock(&self->lock);
}

// ── EGL ──

// Flutter on Linux draws with EGL (OpenGL ES) on X11 and on Wayland.
static void* vyse_get_proc_address(void* ctx, const char* name) {
  (void)ctx;
  return reinterpret_cast<void*>(eglGetProcAddress(name));
}

// The EGL display of this session: the same one the Flutter engine uses (EGL
// hands back the same display for the same native display). The engine
// initialised it long ago and owns it, so it is never terminated here.
static EGLDisplay vyse_session_egl_display(GtkWidget* view) {
  GdkDisplay* display = view != nullptr ? gtk_widget_get_display(view) : gdk_display_get_default();
  if (display == nullptr) return EGL_NO_DISPLAY;
  EGLDisplay egl = EGL_NO_DISPLAY;
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) {
    egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_EXT, gdk_x11_display_get_xdisplay(display), nullptr);
  }
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (egl == EGL_NO_DISPLAY && GDK_IS_WAYLAND_DISPLAY(display)) {
    egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_WAYLAND_EXT, gdk_wayland_display_get_wl_display(display), nullptr);
  }
#endif
  if (egl == EGL_NO_DISPLAY) return EGL_NO_DISPLAY;
  if (!eglInitialize(egl, nullptr, nullptr)) return EGL_NO_DISPLAY;
  return egl;
}

namespace vyse {

// mpv renders at most this many pixels; Flutter scales the texture the rest of
// the way. Every frame is read back and uploaded again, which is cheap at
// 1440p and not at 4K. VYSE_X11_FULL_RES lifts the cap.
static const double kMaxPixels = 2560.0 * 1440.0;

TextureFallback::~TextureFallback() { Stop(); }

bool TextureFallback::Supported(GtkWidget* view) {
  if (view == nullptr) return false;
  GdkDisplay* display = gtk_widget_get_display(view);
  (void)display;
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) return true;
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(display)) return true;
#endif
  return false;
}

bool TextureFallback::Start(FlPluginRegistrar* registrar, GtkWidget* view, mpv_handle* mpv, std::string* error) {
  if (mpv == nullptr) {
    *error = "mpv is not running";
    return false;
  }
  if (thread_.joinable() || texture_ != nullptr) {
    *error = "The video texture is already running";
    return false;
  }
  const EGLDisplay display = vyse_session_egl_display(view);
  if (display == EGL_NO_DISPLAY) {
    *error = "This session has no EGL display to draw video with";
    return false;
  }
  egl_display_ = display;
  // Escape hatch if a driver hands the picture over upside down.
  flip_ = g_getenv("VYSE_X11_FLIP") != nullptr;
  full_resolution_ = g_getenv("VYSE_X11_FULL_RES") != nullptr;

  registrar_ = fl_plugin_registrar_get_texture_registrar(registrar);
  texture_ = VYSE_MPV_TEXTURE(g_object_new(vyse_mpv_texture_get_type(), nullptr));
  if (registrar_ == nullptr || !fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_))) {
    *error = "Flutter refused the video texture";
    g_object_unref(texture_);
    texture_ = nullptr;
    registrar_ = nullptr;
    egl_display_ = nullptr;
    return false;
  }
  texture_id_ = fl_texture_get_id(FL_TEXTURE(texture_));

  {
    std::lock_guard<std::mutex> guard(lock_);
    stop_ = false;
    wake_ = false;
    redraw_ = true;
    started_ = false;
    start_ok_ = false;
    start_error_.clear();
  }
  try {
    thread_ = std::thread([this, mpv]() { RenderThread(mpv); });
  } catch (const std::system_error&) {
    *error = "Could not start the video render thread";
    Stop();
    return false;
  }

  // mpv's video output looks for the render context the moment a file opens,
  // so wait until the thread has made it.
  bool ok = false;
  {
    std::unique_lock<std::mutex> guard(lock_);
    start_cv_.wait(guard, [this] { return started_; });
    ok = start_ok_;
    if (!ok) *error = start_error_;
  }
  if (!ok) {
    Stop();
    return false;
  }
  g_message("VyseTV: video drawn into a Flutter texture (texture %" G_GINT64_FORMAT ")", texture_id_);
  return true;
}

void TextureFallback::Stop() {
  {
    std::lock_guard<std::mutex> guard(lock_);
    stop_ = true;
    if (idle_ != 0) {
      g_source_remove(idle_);
      idle_ = 0;
    }
  }
  wake_cv_.notify_all();
  // The thread frees mpv's render context with its GL context current, then ends.
  if (thread_.joinable()) thread_.join();

  if (texture_ != nullptr) {
    if (registrar_ != nullptr && texture_id_ >= 0) {
      fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
    }
    g_object_unref(texture_);
    texture_ = nullptr;
  }
  g_free(back_);
  back_ = nullptr;
  back_capacity_ = 0;
  texture_id_ = -1;
  registrar_ = nullptr;
  egl_display_ = nullptr;
}

void TextureFallback::SetSize(int width, int height) {
  double w = std::max(16, std::min(width, 8192));
  double h = std::max(16, std::min(height, 8192));
  if (!full_resolution_ && w * h > kMaxPixels) {
    const double scale = std::sqrt(kMaxPixels / (w * h));
    w *= scale;
    h *= scale;
  }
  const int target_w = std::max(16, static_cast<int>(std::lround(w)));
  const int target_h = std::max(16, static_cast<int>(std::lround(h)));
  {
    std::lock_guard<std::mutex> guard(lock_);
    if (target_w == want_w_ && target_h == want_h_) return;
    want_w_ = target_w;
    want_h_ = target_h;
    redraw_ = true;
  }
  wake_cv_.notify_all();
}

void TextureFallback::Redraw() {
  {
    std::lock_guard<std::mutex> guard(lock_);
    redraw_ = true;
  }
  wake_cv_.notify_all();
}

// mpv thread. No mpv call may be made from here.
void TextureFallback::OnMpvUpdate(void* ctx) {
  auto* self = static_cast<TextureFallback*>(ctx);
  {
    std::lock_guard<std::mutex> guard(self->lock_);
    self->wake_ = true;
  }
  self->wake_cv_.notify_all();
}

// Main thread: tells Flutter there is a new frame to draw.
gboolean TextureFallback::NotifyIdle(gpointer data) {
  auto* self = static_cast<TextureFallback*>(data);
  {
    std::lock_guard<std::mutex> guard(self->lock_);
    self->idle_ = 0;
    if (self->stop_) return G_SOURCE_REMOVE;
  }
  if (self->registrar_ != nullptr && self->texture_ != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->registrar_, FL_TEXTURE(self->texture_));
  }
  return G_SOURCE_REMOVE;
}

void TextureFallback::RenderThread(mpv_handle* mpv) {
  const EGLDisplay display = static_cast<EGLDisplay>(egl_display_);
  EGLContext context = EGL_NO_CONTEXT;
  mpv_render_context* render = nullptr;
  std::string error;

  if (!eglBindAPI(EGL_OPENGL_ES_API)) error = "EGL has no OpenGL ES here";

  EGLConfig config = nullptr;
  if (error.empty()) {
    EGLint count = 0;
    const EGLint es3[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8,
                          EGL_BLUE_SIZE,       8,                  EGL_ALPHA_SIZE, 8, EGL_NONE};
    const EGLint es2[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8,
                          EGL_BLUE_SIZE,       8,                  EGL_ALPHA_SIZE, 8, EGL_NONE};
    if (!eglChooseConfig(display, es3, &config, 1, &count) || count < 1) {
      count = 0;
      if (!eglChooseConfig(display, es2, &config, 1, &count) || count < 1) {
        error = "The GPU driver offered no OpenGL ES configuration for video";
      }
    }
  }

  if (error.empty()) {
    // Nothing is shared with Flutter, so take ES 3 where the driver has it.
    for (const EGLint version : {3, 2}) {
      const EGLint attribs[] = {EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE};
      context = eglCreateContext(display, config, EGL_NO_CONTEXT, attribs);
      if (context != EGL_NO_CONTEXT) break;
    }
    if (context == EGL_NO_CONTEXT) error = "The GPU driver would not create an OpenGL ES context for video";
  }

  // Surfaceless, like the engine's own contexts: mpv only ever draws into a
  // framebuffer object here.
  if (error.empty() && !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
    error = "The video OpenGL ES context could not be made current";
  }

  if (error.empty()) {
    mpv_opengl_init_params gl_init{};
    gl_init.get_proc_address = vyse_get_proc_address;
    gl_init.get_proc_address_ctx = nullptr;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    const int rc = mpv_render_context_create(&render, mpv, params);
    if (rc < 0 || render == nullptr) {
      error = std::string("mpv could not render into OpenGL: ") + mpv_error_string(rc);
      render = nullptr;
    }
  }

  if (error.empty()) {
    const GLubyte* renderer = glGetString(GL_RENDERER);
    const GLubyte* version = glGetString(GL_VERSION);
    g_message(
        "VyseTV video texture: GL_VERSION='%s' GL_RENDERER='%s'",
        version != nullptr ? reinterpret_cast<const char*>(version) : "(null)",
        renderer != nullptr ? reinterpret_cast<const char*>(renderer) : "(null)");
    mpv_render_context_set_update_callback(render, &TextureFallback::OnMpvUpdate, this);
  }

  {
    std::lock_guard<std::mutex> guard(lock_);
    started_ = true;
    start_ok_ = error.empty();
    start_error_ = error;
  }
  start_cv_.notify_all();

  if (error.empty()) {
    for (;;) {
      int width = 0;
      int height = 0;
      bool forced = false;
      {
        std::unique_lock<std::mutex> guard(lock_);
        wake_cv_.wait(guard, [this] { return stop_ || wake_ || redraw_; });
        if (stop_) break;
        forced = redraw_;
        wake_ = false;
        redraw_ = false;
        width = want_w_;
        height = want_h_;
      }
      const uint64_t flags = mpv_render_context_update(render);
      if ((flags & MPV_RENDER_UPDATE_FRAME) == 0 && !forced) continue;
      RenderFrame(render, width, height);
    }

    mpv_render_context_set_update_callback(render, nullptr, nullptr);
    mpv_render_context_free(render);
    ReleaseTarget();
  }

  if (context != EGL_NO_CONTEXT) {
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
  }
  eglReleaseThread();
}

bool TextureFallback::EnsureTarget(int width, int height) {
  if (tex_ != 0 && fbo_ != 0 && target_w_ == width && target_h_ == height) return true;
  ReleaseTarget();
  glGenTextures(1, &tex_);
  glBindTexture(GL_TEXTURE_2D, tex_);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex_, 0);
  const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (!complete) {
    ReleaseTarget();
    return false;
  }
  target_w_ = width;
  target_h_ = height;
  return true;
}

void TextureFallback::ReleaseTarget() {
  if (fbo_ != 0) glDeleteFramebuffers(1, &fbo_);
  if (tex_ != 0) glDeleteTextures(1, &tex_);
  fbo_ = 0;
  tex_ = 0;
  target_w_ = 0;
  target_h_ = 0;
}

void TextureFallback::RenderFrame(void* render_context, int width, int height) {
  auto* render = static_cast<mpv_render_context*>(render_context);
  if (!EnsureTarget(width, height)) return;

  mpv_opengl_fbo target{};
  target.fbo = static_cast<int>(fbo_);
  target.w = width;
  target.h = height;
  target.internal_format = 0;
  // Unflipped, mpv puts the top of the picture in the first row of a
  // framebuffer object, which is the order the readback below hands to Flutter.
  int flip = flip_ ? 1 : 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &target},
      {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  // Blocks until the frame is due (mpv's own pacing), which is why this is not
  // the GTK main thread.
  mpv_render_context_render(render, params);

  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  // Flutter blends the texture, so make every pixel opaque: only alpha is written.
  glDisable(GL_SCISSOR_TEST);
  glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE);
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

  const size_t bytes = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (back_capacity_ < bytes) {
    back_ = static_cast<uint8_t*>(g_realloc(back_, bytes));
    back_capacity_ = bytes;
  }
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, back_);
  glPixelStorei(GL_PACK_ALIGNMENT, 4);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);

  vyse_mpv_texture_publish(texture_, &back_, &back_capacity_, static_cast<uint32_t>(width),
                           static_cast<uint32_t>(height));
  mpv_render_context_report_swap(render);

  std::lock_guard<std::mutex> guard(lock_);
  if (!stop_ && idle_ == 0) {
    idle_ = g_idle_add_full(G_PRIORITY_DEFAULT, &TextureFallback::NotifyIdle, this, nullptr);
  }
}

}  // namespace vyse
