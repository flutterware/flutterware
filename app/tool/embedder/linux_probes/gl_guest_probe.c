// What the Linux guest is going to be, with nothing else in the way: the
// Flutter engine on a *surfaceless* EGL context, drawing through the embedder's
// OpenGL renderer, read back frame by frame.
//
// It answers three questions the port rests on — does Impeller come up on GLES
// here, does any of it need a display or a GPU, and what does the readback that
// replaces macOS's zero-copy IOSurface actually cost.
//
//   cc gl_guest_probe.c -I<engine-dir> -L<engine-dir> -lflutter_engine \
//      -lEGL -lGLESv2 -lpthread -Wl,-rpath,<engine-dir> -o gl_guest_probe
//   ./gl_guest_probe <assets-dir> <icudtl.dat> [out.ppm|-] [engine args...]
//
// <engine-dir> is what `ensureEmbedderEngine` unpacks — `~/.flutterware/engine/
// <revision>/`. The assets directory is any with a `kernel_blob.bin` in it;
// `tool/embedder/build_guest.dart` writes one. W= and H= override the size.
// Pass `--enable-impeller --impeller-backend=opengles --enable-flutter-gpu` to
// draw the way the guest does; `LIBGL_ALWAYS_SOFTWARE=1` forces llvmpipe.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "flutter_embedder.h"

static EGLDisplay g_dpy = EGL_NO_DISPLAY;
static EGLContext g_ctx = EGL_NO_CONTEXT;
static EGLContext g_resource_ctx = EGL_NO_CONTEXT;
static GLuint g_fbo = 0, g_tex = 0;
static int g_width = 800, g_height = 600;
static const char* g_out = NULL;
static volatile int g_frames = 0;

static void die(const char* m) { fprintf(stderr, "FATAL: %s\n", m); exit(1); }

static bool init_egl(void) {
  PFNEGLGETPLATFORMDISPLAYEXTPROC get_dpy =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
          "eglGetPlatformDisplayEXT");
  if (get_dpy) {
    g_dpy = get_dpy(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
  }
  if (g_dpy == EGL_NO_DISPLAY) g_dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_dpy == EGL_NO_DISPLAY) return false;
  EGLint major, minor;
  if (!eglInitialize(g_dpy, &major, &minor)) return false;
  fprintf(stderr, "[egl] %d.%d vendor=%s\n", major, minor,
          eglQueryString(g_dpy, EGL_VENDOR));
  fprintf(stderr, "[egl] ext=%s\n", eglQueryString(g_dpy, EGL_EXTENSIONS));
  fprintf(stderr, "[egl] clientext=%s\n",
          eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS));
  if (!eglBindAPI(EGL_OPENGL_ES_API)) return false;
  EGLint cfg_attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(g_dpy, cfg_attrs, &cfg, 1, &n) || n < 1) return false;
  EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  g_ctx = eglCreateContext(g_dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
  if (g_ctx == EGL_NO_CONTEXT) return false;
  g_resource_ctx = eglCreateContext(g_dpy, cfg, g_ctx, ctx_attrs);
  if (g_resource_ctx == EGL_NO_CONTEXT) return false;
  return true;
}

static bool make_current(void* d) {
  (void)d;
  if (!eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g_ctx)) {
    fprintf(stderr, "[egl] makeCurrent failed 0x%x\n", eglGetError());
    return false;
  }
  if (g_fbo == 0) {
    fprintf(stderr, "[gl] renderer=%s version=%s\n", glGetString(GL_RENDERER),
            glGetString(GL_VERSION));
    glGenTextures(1, &g_tex);
    glBindTexture(GL_TEXTURE_2D, g_tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, g_width, g_height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glGenFramebuffers(1, &g_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           g_tex, 0);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    fprintf(stderr, "[gl] fbo=%u status=0x%x\n", g_fbo, st);
  }
  return true;
}

static bool make_resource_current(void* d) {
  (void)d;
  return eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g_resource_ctx);
}

static bool clear_current(void* d) {
  (void)d;
  return eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

static uint32_t fbo_callback(void* d) { (void)d; return g_fbo; }

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static uint8_t* g_pixels = NULL;

// One readback per frame, timed — this is the cost the copy path adds, so it
// is the number worth printing. The capture reuses the same buffer rather than
// reading twice.
static bool present(void* d) {
  (void)d;
  g_frames++;
  size_t n = (size_t)g_width * g_height * 4;
  if (!g_pixels) g_pixels = malloc(n);
  double t0 = now_ms();
  glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
  glReadPixels(0, 0, g_width, g_height, GL_RGBA, GL_UNSIGNED_BYTE, g_pixels);
  double t1 = now_ms();
  fprintf(stderr, "[readback] frame=%d %.2fms (%dx%d)\n", g_frames, t1 - t0,
          g_width, g_height);

  // Not the first frame: the scene animates, and frame 1 is whatever it looked
  // like before anything had moved.
  if (g_out && g_frames == 3) {
    FILE* f = fopen(g_out, "wb");
    fprintf(f, "P6\n%d %d\n255\n", g_width, g_height);
    // GL's origin is bottom-left and a PPM's is top-left, so this walks up.
    for (int y = g_height - 1; y >= 0; y--) {
      for (int x = 0; x < g_width; x++) {
        fwrite(g_pixels + ((size_t)y * g_width + x) * 4, 1, 3, f);
      }
    }
    fclose(f);
    fprintf(stderr, "[capture] wrote %s\n", g_out);
  }
  return true;
}

static void* gl_proc(void* d, const char* name) {
  (void)d;
  return (void*)eglGetProcAddress(name);
}

static void on_log(const char* tag, const char* message, void* d) {
  (void)d;
  printf("[%s] %s\n", tag ? tag : "", message ? message : "");
  fflush(stdout);
}

int main(int argc, char** argv) {
  if (argc < 3) die("usage: host <assets> <icu> [out.ppm] [engine args...]");
  const char* assets = argv[1];
  const char* icu = argv[2];
  g_out = (argc > 3 && strcmp(argv[3], "-") != 0) ? argv[3] : NULL;
  if (getenv("W")) g_width = atoi(getenv("W"));
  if (getenv("H")) g_height = atoi(getenv("H"));

  if (!init_egl()) die("EGL init failed");

  FlutterRendererConfig cfg = {0};
  cfg.type = kOpenGL;
  cfg.open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig);
  cfg.open_gl.make_current = make_current;
  cfg.open_gl.clear_current = clear_current;
  cfg.open_gl.present = present;
  cfg.open_gl.fbo_callback = fbo_callback;
  cfg.open_gl.make_resource_current = make_resource_current;
  cfg.open_gl.fbo_reset_after_present = false;
  cfg.open_gl.gl_proc_resolver = gl_proc;

  const char* engine_argv[16];
  int engine_argc = 0;
  engine_argv[engine_argc++] = "flutterware_guest";
  for (int i = 4; i < argc && engine_argc < 16; i++) {
    engine_argv[engine_argc++] = argv[i];
  }

  FlutterProjectArgs args = {0};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets;
  args.icu_data_path = icu;
  args.log_message_callback = on_log;
  args.log_tag = "guest";
  args.command_line_argc = engine_argc;
  args.command_line_argv = engine_argv;

  FlutterEngine engine = NULL;
  FlutterEngineResult r =
      FlutterEngineRun(FLUTTER_ENGINE_VERSION, &cfg, &args, NULL, &engine);
  if (r != kSuccess || !engine) {
    fprintf(stderr, "FlutterEngineRun failed: %d\n", (int)r);
    return 1;
  }
  fprintf(stderr, "[engine] running\n");

  FlutterWindowMetricsEvent m = {0};
  m.struct_size = sizeof(m);
  m.width = g_width;
  m.height = g_height;
  m.pixel_ratio = 1.0;
  FlutterEngineSendWindowMetricsEvent(engine, &m);

  for (int i = 0; i < 60 && g_frames < 40; i++) usleep(50000);
  fprintf(stderr, "[engine] frames=%d\n", g_frames);
  return g_frames > 0 ? 0 : 3;
}
