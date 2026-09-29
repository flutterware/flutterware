#include "input.h"

#include <stdbool.h>
#include <string.h>

static uint32_t rd_u32(const uint8_t* p, size_t off) {
  uint32_t v;
  memcpy(&v, p + off, 4);
  return v;
}

static uint64_t rd_u64(const uint8_t* p, size_t off) {
  uint64_t v;
  memcpy(&v, p + off, 8);
  return v;
}

static double rd_f64(const uint8_t* p, size_t off) {
  double v;
  memcpy(&v, p + off, 8);
  return v;
}

void input_handle_pointer(FlutterEngine engine, const uint8_t* p, size_t len) {
  if (len < 48) return;
  FlutterPointerEvent ev = {0};
  ev.struct_size = sizeof(FlutterPointerEvent);
  // protocol PointerPhase order matches FlutterPointerPhase.
  ev.phase = (FlutterPointerPhase)rd_u32(p, 0);
  ev.x = rd_f64(p, 4);
  ev.y = rd_f64(p, 12);
  ev.buttons = (int64_t)rd_u32(p, 20);
  double scroll_dx = rd_f64(p, 24);
  double scroll_dy = rd_f64(p, 32);
  ev.timestamp = (size_t)rd_u64(p, 40);
  // Pan/zoom fields arrived with trackpad support; a 48-byte frame is from a
  // GUI that predates them.
  if (len >= 80) {
    ev.pan_x = rd_f64(p, 48);
    ev.pan_y = rd_f64(p, 56);
    ev.scale = rd_f64(p, 64);
    ev.rotation = rd_f64(p, 72);
  } else {
    ev.scale = 1.0;
  }
  // The framework only routes the panZoom phases to scrollables when they come
  // from a trackpad; a mouse is not a device that pans.
  bool pan_zoom = ev.phase >= kPanZoomStart;
  // Whether the GUI is standing in for a finger — it says so because it is the
  // one that picked the device. Appended after the pan/zoom block, so a frame
  // that stops short of it is a host that predates staging and means a mouse.
  //
  // A separate device id, not only a separate kind: the engine keeps one state
  // per device, and a device that changed kind mid-stream would be a mouse and
  // a finger wearing the same name. The wheel still arrives as the mouse.
  //
  // The trackpad is a third. Sharing the mouse's, a pointer that left the
  // guest mid-swipe — a stage sliding the phone out from under a cursor that
  // never moved — removed the device the swipe was open on: the engine
  // renumbered its end, the framework never delivered it, and the page the
  // swipe was dragging stayed where it was, as did every later swipe's.
  bool touch = !pan_zoom && len >= 81 && p[80] != 0;
  ev.device = pan_zoom ? 2 : touch ? 1 : 0;
  ev.device_kind = pan_zoom  ? kFlutterPointerDeviceKindTrackpad
                   : touch   ? kFlutterPointerDeviceKindTouch
                             : kFlutterPointerDeviceKindMouse;
  if (!pan_zoom && (scroll_dx != 0.0 || scroll_dy != 0.0)) {
    ev.signal_kind = kFlutterPointerSignalKindScroll;
    ev.scroll_delta_x = scroll_dx;
    ev.scroll_delta_y = scroll_dy;
  }
  FlutterEngineSendPointerEvent(engine, &ev, 1);
}

void input_handle_key(FlutterEngine engine, const uint8_t* p, size_t len) {
  if (len < 32) return;
  FlutterKeyEvent ev = {0};
  ev.struct_size = sizeof(FlutterKeyEvent);
  uint32_t kind = rd_u32(p, 0);  // 0 down, 1 up, 2 repeat
  ev.type = kind == 1   ? kFlutterKeyEventTypeUp
            : kind == 2 ? kFlutterKeyEventTypeRepeat
                        : kFlutterKeyEventTypeDown;
  ev.physical = rd_u64(p, 4);
  ev.logical = rd_u64(p, 12);
  // modifiers (offset 20, u32) are not part of FlutterKeyEvent; ignored in 3a.
  ev.timestamp = (double)rd_u64(p, 24);
  ev.character = NULL;
  // The character the host's layout produced, as u32 length + UTF-8; a
  // 32-byte frame is from a GUI that predates it. One keystroke's text — a
  // grapheme at most — so a small stack buffer holds any real one, and the
  // engine copies during the send. Ignored for up events per the embedder API.
  char character[16];
  if (len >= 36 && ev.type != kFlutterKeyEventTypeUp) {
    uint32_t char_len = rd_u32(p, 32);
    if (char_len > 0 && char_len < sizeof(character) && 36 + char_len <= len) {
      memcpy(character, p + 36, char_len);
      character[char_len] = '\0';
      ev.character = character;
    }
  }
  ev.synthesized = false;
  // device_type has no zero enumerator; the engine rejects an unset value.
  ev.device_type = kFlutterKeyEventDeviceTypeKeyboard;
  FlutterEngineSendKeyEvent(engine, &ev, NULL, NULL);
}
