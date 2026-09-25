// Long-lived Flutter-engine guest: runs a kernel blob, renders into a ring of
// surfaces shared with a controlling process, and exchanges frames + input with
// it over a Unix domain socket.
//
// The renderer is the one thing that is not the same on every host — Metal
// into IOSurface-backed textures on macOS, GL into a framebuffer read back
// into shared memory elsewhere — and it is confined to the two blocks marked
// `__APPLE__` below plus `surface.m` / `surface_gl.c`. Everything else here —
// the socket loop, resize, capture, window metrics, input — is written once.
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef __APPLE__
#include <EGL/egl.h>
#endif

#include "clipboard.h"
#include "flutter_embedder.h"
#include "input.h"
#include "ipc.h"
#include "surface.h"

static int g_socket = -1;
static FlutterEngine g_engine = NULL;
// generation and frame_id are only touched on the engine raster thread (inside
// the drawable callbacks), and once at startup before the engine runs.
static uint32_t g_generation = 0;
static uint64_t g_frame_id = 0;
static double g_pixel_ratio = 1.0;

// A pending capture request. `--capture-raw` arms one at startup; a kMsgCapture
// message arms another at any time, which is what lets one warm guest be
// screenshotted repeatedly instead of being respawned per frame wanted.
//
// Written on the main thread (argv, socket loop), read and cleared on a
// Metal completion thread, so it is guarded.
static pthread_mutex_t g_capture_lock = PTHREAD_MUTEX_INITIALIZER;
static char* g_capture_path = NULL;

// The interval `OnVsyncRequest` hands back — see it for why.
static const uint64_t kFrameIntervalNanos = 16600000;

// Whether this guest paces itself to a display at all. Off unless
// `--free-vsync` says so, and only a headless render says so.
static bool g_free_vsync = false;

// The engine asks the platform to wait for a vsync and hands over a baton to
// return when the next one lands. With no callback registered it uses its own
// waiter, which on a desktop is the real display link — so a headless render
// drawing as fast as it could was still paced at one frame every 16.6ms.
// Measured: 31 frames took 515ms at 900x700, at iPhone SE and at iPhone 13
// alike — a 4.6x range of pixels for identical wall clock, because the display
// was the only thing being timed. Returning the baton immediately took the
// same render to 118ms.
//
// Registered only for a guest launched to render, and never for one behind a
// preview panel: a panel's guest paced by nothing would burn a core producing
// frames the panel drops, and the engine's own waiter is already right for it.
static void OnVsyncRequest(void* user_data, intptr_t baton) {
  uint64_t now = FlutterEngineGetCurrentTime();
  FlutterEngineOnVsync(g_engine, baton, now, now + kFrameIntervalNanos);
}

// ── The platform thread ─────────────────────────────────────────────────────
//
// The engine runs platform work — every platform message, and the replies to
// them — as tasks on the thread that called `FlutterEngineRun`, and it is the
// embedder's job to run them. Without a custom runner the engine installs its
// own message loop on this thread and waits for somebody to pump it; this
// host's main thread spends its life in a socket read, so nobody did, and a
// platform call from Dart was never answered at all. An app's first plugin call
// hung it forever (`2026-07-26-s1-scenario-in-embedder-findings.md`).
//
// So the engine is handed a runner of ours: tasks go into a list ordered by
// target time, a byte down a pipe wakes the main loop, and the main loop polls
// the socket and the pipe together with a timeout of "until the next task is
// due". Written on any engine thread, drained on the main thread only.

typedef struct PlatformTask {
  FlutterTask task;
  uint64_t target_nanos;
  struct PlatformTask* next;
} PlatformTask;

static pthread_mutex_t g_tasks_lock = PTHREAD_MUTEX_INITIALIZER;
static PlatformTask* g_tasks = NULL;
static int g_wake[2] = {-1, -1};
static pthread_t g_platform_thread;

static bool RunsOnPlatformThread(void* user_data) {
  (void)user_data;
  return pthread_equal(pthread_self(), g_platform_thread) != 0;
}

static void PostPlatformTask(FlutterTask task, uint64_t target_nanos,
                             void* user_data) {
  (void)user_data;
  PlatformTask* entry = (PlatformTask*)malloc(sizeof(PlatformTask));
  entry->task = task;
  entry->target_nanos = target_nanos;
  pthread_mutex_lock(&g_tasks_lock);
  PlatformTask** at = &g_tasks;
  while (*at && (*at)->target_nanos <= target_nanos) at = &(*at)->next;
  entry->next = *at;
  *at = entry;
  pthread_mutex_unlock(&g_tasks_lock);
  char byte = 1;
  // A full pipe already means "wake up", so a short write is not an error.
  ssize_t ignored = write(g_wake[1], &byte, 1);
  (void)ignored;
}

// Runs every task that is due and answers how long, in milliseconds, until the
// next one is: the timeout the main loop's poll waits for. -1 when nothing is
// queued.
static int RunDuePlatformTasks(void) {
  for (;;) {
    uint64_t now = FlutterEngineGetCurrentTime();
    pthread_mutex_lock(&g_tasks_lock);
    PlatformTask* due = NULL;
    if (g_tasks && g_tasks->target_nanos <= now) {
      due = g_tasks;
      g_tasks = due->next;
    }
    uint64_t next = g_tasks ? g_tasks->target_nanos : 0;
    bool any = g_tasks != NULL;
    pthread_mutex_unlock(&g_tasks_lock);
    if (due) {
      // One at a time, and the list re-read after each: a task may post
      // another that is due at once.
      FlutterEngineRunTask(g_engine, &due->task);
      free(due);
      continue;
    }
    if (!any) return -1;
    uint64_t wait_nanos = next > now ? next - now : 0;
    // Rounded up, so a task due in 0.4ms is not polled for with 0 forever.
    return (int)((wait_nanos + 999999) / 1000000);
  }
}

// Every platform message the app sends, answered empty — but for the
// clipboard's, see clipboard.h — which Dart reads as
// "no implementation" and throws `MissingPluginException` for, the way a test
// or a real app with an unregistered plugin does. A plugin the app has not
// replaced with a fake now fails loudly and at once instead of hanging.
//
// Each channel is named on stdout the first time it is used, so a run says
// which parts of the platform an app reached for.
#define MAX_SEEN_CHANNELS 128
static char* g_seen_channels[MAX_SEEN_CHANNELS];
static int g_seen_count = 0;

static void OnPlatformMessage(const FlutterPlatformMessage* message,
                              void* user_data) {
  (void)user_data;
  uint8_t* reply = NULL;
  size_t reply_length = 0;
  if (strcmp(message->channel, "flutter/platform") == 0 &&
      clipboard_answer(message->message, message->message_size, &reply,
                       &reply_length)) {
    if (message->response_handle) {
      FlutterEngineSendPlatformMessageResponse(
          g_engine, message->response_handle, reply, reply_length);
    }
    free(reply);
    return;
  }
  bool seen = false;
  for (int i = 0; i < g_seen_count; i++) {
    if (strcmp(g_seen_channels[i], message->channel) == 0) {
      seen = true;
      break;
    }
  }
  if (!seen && g_seen_count < MAX_SEEN_CHANNELS) {
    g_seen_channels[g_seen_count++] = strdup(message->channel);
    printf("[platform] unanswered: %s\n", message->channel);
    fflush(stdout);
  }
  if (message->response_handle) {
    FlutterEngineSendPlatformMessageResponse(g_engine, message->response_handle,
                                             NULL, 0);
  }
}

// Tells the engine which locales the "device" prefers: `FW_GUEST_LOCALES`,
// comma-separated (`en-US,fr-FR`), else `en-US`.
//
// An embedder that says nothing leaves the app with the undetermined locale
// `und`, and an app that resolves its localizations from the platform then
// finds none: a real app's first frame was the red error screen, a failed cast
// to `WidgetsLocalizations`. Previews never noticed, because the catalog host
// supplies its own localizations. Written once, at start; nothing changes it.
static void SendLocales(void) {
  const char* configured = getenv("FW_GUEST_LOCALES");
  char* list = strdup(configured && configured[0] ? configured : "en-US");
  FlutterLocale storage[16];
  const FlutterLocale* locales[16];
  size_t count = 0;
  for (char* tag = strtok(list, ","); tag && count < 16;
       tag = strtok(NULL, ",")) {
    char* separator = strpbrk(tag, "-_");
    if (separator) *separator = '\0';
    storage[count] = (FlutterLocale){
        .struct_size = sizeof(FlutterLocale),
        .language_code = tag,
        .country_code = separator ? separator + 1 : NULL,
    };
    locales[count] = &storage[count];
    count++;
  }
  FlutterEngineUpdateLocales(g_engine, locales, count);
  free(list);
}

// Receives engine log output, including Dart print(). Kept on stdout so the
// control socket carries only protocol traffic.
static void OnLogMessage(const char* tag, const char* message,
                         void* user_data) {
  (void)user_data;
  if (tag && tag[0]) {
    printf("[%s] %s\n", tag, message);
  } else {
    printf("%s\n", message ? message : "");
  }
  fflush(stdout);
}

// Writes a raw frame file: a 16-byte LE header (width, height, row_bytes,
// pixel order) then the pixels read back from ring slot `slot`.
//
// The order is in the header rather than agreed in advance because it differs
// per host — see `surface_ring_pixel_order`.
static void WriteRawCapture(const char* path, int slot) {
  const void* base = surface_lock(slot);
  if (!base) return;
  size_t row_bytes = surface_ring_row_bytes();
  size_t height = (size_t)surface_ring_height();
  FILE* f = fopen(path, "wb");
  if (f) {
    uint32_t header[4] = {(uint32_t)surface_ring_width(), (uint32_t)height,
                          (uint32_t)row_bytes, surface_ring_pixel_order()};
    fwrite(header, sizeof(uint32_t), 4, f);
    fwrite(base, 1, row_bytes * height, f);
    fclose(f);
  }
  surface_unlock(slot);
}

// Announces the ring: its size, and how the GUI is to find each slot.
//
// The handles are length-prefixed strings rather than the fixed-width ids this
// used to send, because what a slot *is* differs per host — an IOSurfaceID
// there, a shared-memory name here — and one shape both can say is worth more
// than four bytes.
static void SendSurfacesAllocated(void) {
  // 5 header words, then a length and a name per slot. 256 is well past the
  // longest handle either host produces (an IOSurfaceID in decimal, or
  // "/flutterware-<pid>-<serial>-<slot>").
  uint8_t payload[5 * 4 + SURFACE_RING_COUNT * (4 + 256)];
  uint32_t generation = g_generation;
  uint32_t count = SURFACE_RING_COUNT;
  uint32_t width = (uint32_t)surface_ring_width();
  uint32_t height = (uint32_t)surface_ring_height();
  uint32_t row_bytes = (uint32_t)surface_ring_row_bytes();
  memcpy(payload + 0, &generation, 4);
  memcpy(payload + 4, &count, 4);
  memcpy(payload + 8, &width, 4);
  memcpy(payload + 12, &height, 4);
  memcpy(payload + 16, &row_bytes, 4);
  size_t at = 20;
  for (int i = 0; i < SURFACE_RING_COUNT; i++) {
    const char* handle = surface_ring_handle(i);
    if (handle == NULL) handle = "";
    uint32_t len = (uint32_t)strlen(handle);
    if (len > 256) len = 256;
    memcpy(payload + at, &len, 4);
    memcpy(payload + at + 4, handle, len);
    at += 4 + len;
  }
  ipc_send(g_socket, kMsgSurfacesAllocated, payload, at);
}

// `insets` is top, right, bottom, left in physical pixels — a device's safe
// areas, which only the GUI knows because it is the one that picked the
// device. The frame around the screen is drawn in that other process, so
// without this the guest has no way to learn that it is behind a notch.
static void SendWindowMetrics(int width, int height, double pixel_ratio,
                              const double insets[4]) {
  FlutterWindowMetricsEvent metrics = {0};
  metrics.struct_size = sizeof(FlutterWindowMetricsEvent);
  metrics.width = (size_t)width;
  metrics.height = (size_t)height;
  metrics.pixel_ratio = pixel_ratio;
  metrics.physical_view_inset_top = insets[0];
  metrics.physical_view_inset_right = insets[1];
  metrics.physical_view_inset_bottom = insets[2];
  metrics.physical_view_inset_left = insets[3];
  FlutterEngineSendWindowMetricsEvent(g_engine, &metrics);
}

// Carries the identity of a presented frame to the GPU completion handler.
typedef struct {
  uint32_t ring_index;
  uint64_t frame_id;
  uint32_t generation;
} PresentedFrame;

// Runs on a Metal-internal thread once the engine's render for this frame has
// finished on the GPU. The surface is fully written by now, so it is safe to
// read it back and to tell the GUI the frame is ready.
static void OnFramePresented(void* user_data) {
  PresentedFrame* frame = (PresentedFrame*)user_data;

  // Take the pending request, if any, and clear it under the lock so a second
  // request cannot be lost or double-written.
  pthread_mutex_lock(&g_capture_lock);
  char* capture_path = g_capture_path;
  g_capture_path = NULL;
  pthread_mutex_unlock(&g_capture_lock);

  if (capture_path) {
    WriteRawCapture(capture_path, (int)frame->ring_index);
    // Tell the caller the file is complete; without this it can only guess
    // when the bytes have landed.
    ipc_send(g_socket, kMsgCaptured, (const uint8_t*)capture_path,
             strlen(capture_path));
    free(capture_path);
  }

  uint8_t payload[16];
  memcpy(payload + 0, &frame->ring_index, 4);
  memcpy(payload + 4, &frame->frame_id, 8);
  memcpy(payload + 12, &frame->generation, 4);
  ipc_send(g_socket, kMsgFrameReady, payload, sizeof(payload));
  free(frame);
}

// Reallocates the ring when the engine asks for a size it is not, and tells the
// GUI when it did. Called from the engine's raster thread on every frame, on
// both hosts — at that point the engine holds no drawable, so freeing the old
// ring is safe and no cross-thread locking is needed.
static void ResizeRingIfNeeded(const FlutterFrameInfo* frame_info) {
  int width = (int)frame_info->size.width;
  int height = (int)frame_info->size.height;
  if (width == surface_ring_width() && height == surface_ring_height()) return;
  if (surface_ring_init(width, height)) {
    g_generation++;
    SendSurfacesAllocated();
  }
}

#ifdef __APPLE__

// Engine raster thread: hands the engine the next ring slot's Metal texture.
// If the engine asks for a size different from the current ring (a resize),
// the ring is reallocated here — at this point the engine holds no texture, so
// freeing the old ring is safe and no cross-thread locking is needed.
static FlutterMetalTexture GetNextDrawable(
    void* user_data, const FlutterFrameInfo* frame_info) {
  (void)user_data;
  ResizeRingIfNeeded(frame_info);
  int slot = surface_ring_acquire();
  FlutterMetalTexture texture = {0};
  texture.struct_size = sizeof(FlutterMetalTexture);
  texture.texture_id = slot;
  texture.texture = surface_ring_texture(slot);
  texture.user_data = NULL;
  texture.destruction_callback = NULL;  // the guest owns the ring.
  return texture;
}

// Engine raster thread: the engine has submitted its render into this slot's
// texture. Advance the ring and fence the GPU; FrameReady is sent from the
// fence's completion handler so the GUI never reads a half-rendered surface.
static bool PresentDrawable(void* user_data,
                            const FlutterMetalTexture* texture) {
  (void)user_data;
  PresentedFrame* frame = (PresentedFrame*)malloc(sizeof(PresentedFrame));
  frame->ring_index = (uint32_t)texture->texture_id;
  frame->frame_id = ++g_frame_id;
  frame->generation = g_generation;
  surface_ring_advance();
  surface_present_fence(OnFramePresented, frame);
  return true;
}

#else  // __APPLE__

// The engine's OpenGL renderer, in four callbacks it invokes on its own
// threads. Everything they do lives in `surface_gl.c`; these exist because the
// engine's signatures carry a user_data the surface unit has no use for.
static bool GlMakeCurrent(void* user_data) {
  (void)user_data;
  return surface_gl_make_current();
}

static bool GlClearCurrent(void* user_data) {
  (void)user_data;
  return surface_gl_clear_current();
}

static bool GlMakeResourceCurrent(void* user_data) {
  (void)user_data;
  return surface_gl_make_resource_current();
}

// Engine raster thread, once per frame — `fbo_reset_after_present` is what
// makes it once per frame rather than once per run, and that is what gives the
// GL host the resize hook `get_next_drawable` is on Metal.
static uint32_t GlFbo(void* user_data, const FlutterFrameInfo* frame_info) {
  (void)user_data;
  ResizeRingIfNeeded(frame_info);
  return surface_gl_fbo();
}

// Engine raster thread: the frame is in the framebuffer, so copy it into the
// ring and say so.
//
// There is no fence here and nothing to wait for. `surface_gl_readback` ends in
// a `glReadPixels`, which is synchronous by definition — it cannot return
// before the GPU has finished writing what it reads — so by the time this
// line is reached the frame is in the slot and OnFramePresented can be called
// outright, where the Metal path has to wait for a command buffer to complete.
// Note for whoever profiles this: on the Metal path `OnFramePresented` runs
// from a command-buffer completion handler, off the raster thread. Here it runs
// inline, so an armed capture does its `fwrite` — 7.7MB at 1600x1200 — and its
// blocking `ipc_send` inside the engine's present callback, stalling the
// guest's raster thread for the length of a disk write. Only a capture pays it,
// and a capture is already a stop-and-photograph, but a guest that captured
// every frame would be paced by the filesystem.
static bool GlPresent(void* user_data) {
  (void)user_data;
  int slot = surface_ring_acquire();
  surface_gl_readback(slot);
  PresentedFrame* frame = (PresentedFrame*)malloc(sizeof(PresentedFrame));
  frame->ring_index = (uint32_t)slot;
  frame->frame_id = ++g_frame_id;
  frame->generation = g_generation;
  surface_ring_advance();
  OnFramePresented(frame);
  return true;
}

static void* GlProcResolver(void* user_data, const char* name) {
  (void)user_data;
  return (void*)eglGetProcAddress(name);
}

#endif  // __APPLE__

int main(int argc, char** argv) {
  if (argc < 6) {
    fprintf(stderr,
            "usage: %s <assets_dir> <icu_data_path> <socket_path> "
            "<width> <height> [--capture-raw <path>] [--free-vsync]\n",
            argv[0]);
    return 2;
  }
  const char* assets_path = argv[1];
  const char* icu_data_path = argv[2];
  const char* socket_path = argv[3];
  int width = atoi(argv[4]);
  int height = atoi(argv[5]);
  // One argument at a time, and the ones that take a value say so. The
  // previous loop stepped in pairs, which silently swallowed any flag that
  // stands alone: `--free-vsync` as the last argument left `i + 1 < argc`
  // false and the loop never ran at all.
  for (int i = 6; i < argc; i++) {
    if (strcmp(argv[i], "--free-vsync") == 0) {
      g_free_vsync = true;
    } else if (strcmp(argv[i], "--capture-raw") == 0 && i + 1 < argc) {
      g_capture_path = strdup(argv[++i]);
    }
  }

  g_socket = ipc_connect(socket_path);
  if (g_socket < 0) {
    fprintf(stderr, "Cannot connect to socket: %s\n", socket_path);
    return 1;
  }

  if (!surface_ring_init(width, height)) {
    const char* msg = "surface allocation failed";
    ipc_send(g_socket, kMsgError, (const uint8_t*)msg, strlen(msg));
    return 1;
  }

  FlutterRendererConfig renderer = {0};
#ifdef __APPLE__
  renderer.type = kMetal;
  renderer.metal.struct_size = sizeof(FlutterMetalRendererConfig);
  renderer.metal.device = surface_metal_device();
  renderer.metal.present_command_queue = surface_metal_queue();
  renderer.metal.get_next_drawable_callback = GetNextDrawable;
  renderer.metal.present_drawable_callback = PresentDrawable;
#else
  renderer.type = kOpenGL;
  renderer.open_gl.struct_size = sizeof(FlutterOpenGLRendererConfig);
  renderer.open_gl.make_current = GlMakeCurrent;
  renderer.open_gl.clear_current = GlClearCurrent;
  renderer.open_gl.make_resource_current = GlMakeResourceCurrent;
  renderer.open_gl.present = GlPresent;
  renderer.open_gl.fbo_with_frame_info_callback = GlFbo;
  renderer.open_gl.fbo_reset_after_present = true;
  renderer.open_gl.gl_proc_resolver = GlProcResolver;
#endif

  if (pipe(g_wake) != 0) {
    const char* msg = "wake pipe failed";
    ipc_send(g_socket, kMsgError, (const uint8_t*)msg, strlen(msg));
    return 1;
  }
  // Both ends non-blocking: a poster must never wait on a full pipe, and the
  // drain must stop when it is empty.
  fcntl(g_wake[0], F_SETFL, O_NONBLOCK);
  fcntl(g_wake[1], F_SETFL, O_NONBLOCK);
  g_platform_thread = pthread_self();
  FlutterTaskRunnerDescription platform_runner = {0};
  platform_runner.struct_size = sizeof(FlutterTaskRunnerDescription);
  platform_runner.runs_task_on_current_thread_callback = RunsOnPlatformThread;
  platform_runner.post_task_callback = PostPlatformTask;
  platform_runner.identifier = 1;
  FlutterCustomTaskRunners task_runners = {0};
  task_runners.struct_size = sizeof(FlutterCustomTaskRunners);
  task_runners.platform_task_runner = &platform_runner;

  FlutterProjectArgs args = {0};
  args.struct_size = sizeof(FlutterProjectArgs);
  args.assets_path = assets_path;
  args.icu_data_path = icu_data_path;
  args.log_message_callback = OnLogMessage;
  args.log_tag = "embedder";
  args.custom_task_runners = &task_runners;
  args.platform_message_callback = OnPlatformMessage;
  if (g_free_vsync) args.vsync_callback = OnVsyncRequest;

  // Impeller, unless the escape hatch says otherwise. Two reasons it is not
  // optional: Flutter GPU needs it and refuses without it, and the tester the
  // audit runs on now draws with it — a guest still on Skia would mean a
  // `screenshot` and an `audit` of one entry were rasterized differently.
  //
  // `Settings::enable_impeller` defaults to true only on Android and iOS, so
  // every desktop embedder has to ask. The name below is
  // `softwareRenderingKey` in `app/lib/src/constants.dart`; the two halves
  // have to agree.
  //
  // The GL host names its backend and the Metal one does not, which is not an
  // inconsistency: an unqualified `--enable-impeller` falls through to the
  // engine's Vulkan branch, and on Linux there is a Vulkan driver for it to
  // fall through *to* — a renderer config saying `kOpenGL` and a rasterizer
  // that came up on Vulkan. Naming `opengles` is what holds the two together.
  // Nothing is named on macOS because nothing has needed to be; the Metal
  // config has always been enough there, and a flag added on a host this
  // cannot be run on is a change made blind.
  const char* engine_argv[] = {"flutterware_guest", "--enable-impeller",
#ifndef __APPLE__
                               "--impeller-backend=opengles",
#endif
                               "--enable-flutter-gpu"};
  const char* software = getenv("FW_SOFTWARE_RENDERING");
  if (software == NULL || strcmp(software, "1") != 0) {
    args.command_line_argc =
        (int)(sizeof(engine_argv) / sizeof(engine_argv[0]));
    args.command_line_argv = engine_argv;
  }

  FlutterEngineResult result = FlutterEngineRun(
      FLUTTER_ENGINE_VERSION, &renderer, &args, NULL, &g_engine);
  if (result != kSuccess || g_engine == NULL) {
    char msg[64];
    snprintf(msg, sizeof(msg), "FlutterEngineRun failed: %d", (int)result);
    ipc_send(g_socket, kMsgError, (const uint8_t*)msg, strlen(msg));
    return 1;
  }

  SendLocales();
  ipc_send(g_socket, kMsgReady, NULL, 0);
  SendSurfacesAllocated();
  const double no_insets[4] = {0, 0, 0, 0};
  SendWindowMetrics(width, height, g_pixel_ratio, no_insets);

  // The main thread's loop: platform tasks when they are due, a socket message
  // when one arrives, and a wake-up whenever an engine thread posts a task.
  for (;;) {
    int timeout_ms = RunDuePlatformTasks();
    struct pollfd fds[2] = {
        {.fd = g_socket, .events = POLLIN},
        {.fd = g_wake[0], .events = POLLIN},
    };
    if (poll(fds, 2, timeout_ms) < 0) continue;  // EINTR: go round again.
    if (fds[1].revents & POLLIN) {
      char drain[64];
      ssize_t ignored = read(g_wake[0], drain, sizeof(drain));
      (void)ignored;
    }
    if (!(fds[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;

    uint8_t* payload = NULL;
    size_t len = 0;
    int type = ipc_read(g_socket, &payload, &len);
    if (type < 0) break;  // GUI closed the socket.
    if (type == kMsgResize && len >= 16) {
      uint32_t new_width;
      uint32_t new_height;
      double pixel_ratio;
      double insets[4] = {0, 0, 0, 0};
      memcpy(&new_width, payload + 0, 4);
      memcpy(&new_height, payload + 4, 4);
      memcpy(&pixel_ratio, payload + 8, 8);
      // Optional, so a client built before the insets existed still resizes.
      if (len >= 48) memcpy(insets, payload + 16, 32);
      g_pixel_ratio = pixel_ratio;
      // The ring is reallocated inside GetNextDrawable on the raster thread;
      // here we only nudge the engine to render at the new size.
      SendWindowMetrics((int)new_width, (int)new_height, pixel_ratio, insets);
    } else if (type == kMsgPointerEvent) {
      input_handle_pointer(g_engine, payload, len);
    } else if (type == kMsgKeyEvent) {
      input_handle_key(g_engine, payload, len);
    } else if (type == kMsgCapture) {
      // Arm a capture and force a frame: the engine renders nothing when
      // nothing changed, so without this a request on a static scene would
      // wait forever.
      char* path = (char*)malloc(len + 1);
      memcpy(path, payload, len);
      path[len] = '\0';
      pthread_mutex_lock(&g_capture_lock);
      free(g_capture_path);
      g_capture_path = path;
      pthread_mutex_unlock(&g_capture_lock);
      FlutterEngineScheduleFrame(g_engine);
    } else if (type == kMsgShutdown) {
      free(payload);
      break;
    }
    free(payload);
  }

  // Just release the surfaces and let the OS reclaim the rest.
  surface_ring_destroy();
  return 0;
}
