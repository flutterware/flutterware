#ifndef EMBEDDER_SURFACE_H
#define EMBEDDER_SURFACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// A ring of three surfaces shared with the GUI process. The guest renders into
// one slot at a time; the GUI reads whichever slot FrameReady names.
//
// What a surface *is* differs per host, and that is the only thing that does.
// On macOS each slot is an IOSurface that also backs a Metal texture the engine
// renders into directly — zero-copy, no per-frame copy at all. Elsewhere each
// slot is a shared-memory mapping the engine's GL framebuffer is read back
// into: one copy per frame, measured at ~2ms for an 800x600 panel and ~4.5ms at
// 1600x1200. The GL host cannot do better yet because a dmabuf is the only
// zero-copy way across a process boundary there, and exporting one is a Mesa
// extension that not every driver has.
//
// Everything above the two blocks at the bottom of this header is common, so
// `host.c` reallocates, captures, locks and advances the ring the same way on
// both.
#define SURFACE_RING_COUNT 3

// Creates whatever the host needs on the first call — a Metal device and
// queue, or an EGL display and its contexts — then a fresh ring sized
// width x height, releasing any previous ring. Returns false on device or
// allocation failure.
//
// Called at startup on the main thread and thereafter only from the engine's
// raster thread, on the frame that notices the size changed.
bool surface_ring_init(int width, int height);

// Releases the ring.
void surface_ring_destroy(void);

// The slot index the engine should render into next. Does not advance.
int surface_ring_acquire(void);

// Advances to the next ring slot. Called once the engine has presented.
void surface_ring_advance(void);

// Maps a ring slot for CPU readback, for --capture-raw and kMsgCapture.
// surface_lock returns the slot's base address, or NULL.
const void* surface_lock(int slot);
void surface_unlock(int slot);

// How the GUI process finds ring slot `slot`, as a NUL-terminated string it can
// resolve on its own: an IOSurfaceID in decimal on macOS, the shared memory
// object's name elsewhere. NULL if the slot is out of range or unallocated.
//
// A string rather than the number it used to be because a name is what the
// other hosts have, and one wire shape for both beats a message that means
// something different depending on who sent it.
const char* surface_ring_handle(int slot);

int surface_ring_width(void);
int surface_ring_height(void);
size_t surface_ring_row_bytes(void);

// Which byte order a slot's pixels are in. It is not the same on both hosts and
// there is no talking either of them out of it: an IOSurface feeding a
// CVPixelBuffer is BGRA, and a GL readback feeding an FlPixelBufferTexture is
// RGBA. Both readers of a slot — the GUI's texture and `decodeRawFrame` —
// are told rather than made to assume, which is why the raw frame header
// carries this word.
enum {
  kSurfaceOrderBgra = 0,
  kSurfaceOrderRgba = 1,
};
uint32_t surface_ring_pixel_order(void);

#ifdef __APPLE__

// The MTLDevice handle (id<MTLDevice>) for FlutterMetalRendererConfig.device.
// NULL before the first successful surface_ring_init.
const void* surface_metal_device(void);

// The MTLCommandQueue handle (id<MTLCommandQueue>) for
// FlutterMetalRendererConfig.present_command_queue.
const void* surface_metal_queue(void);

// The MTLTexture handle (id<MTLTexture>) backing ring slot `slot`, handed to
// the engine from get_next_drawable_callback. NULL if slot is out of range.
const void* surface_ring_texture(int slot);

// Commits an empty command buffer on the present command queue and invokes
// `on_complete(user_data)` from its completion handler. Because the engine
// submits its render on the same in-order queue, the handler runs only after
// the GPU has finished writing the frame.
void surface_present_fence(void (*on_complete)(void* user_data),
                           void* user_data);

#else

// The FlutterOpenGLRendererConfig callbacks, in the order the engine uses them.
// All four run on the engine's own threads: make_resource_current on an
// internal upload thread, the rest on the raster thread.
bool surface_gl_make_current(void);
bool surface_gl_clear_current(void);
bool surface_gl_make_resource_current(void);

// The framebuffer object the engine renders this frame into, creating or
// resizing it to the current ring size first. Zero if that fails. Must be
// called with the render context current, which the engine guarantees by
// calling make_current before it asks.
uint32_t surface_gl_fbo(void);

// Reads the framebuffer back into ring slot `slot`. This is the copy the Metal
// path does not have, and it is synchronous: when it returns, the slot holds
// the frame and the GUI may be told about it.
void surface_gl_readback(int slot);

#endif  // __APPLE__

#endif  // EMBEDDER_SURFACE_H
