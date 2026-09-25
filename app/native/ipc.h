#ifndef EMBEDDER_IPC_H
#define EMBEDDER_IPC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Wire message type tags. Must match MessageType in protocol.dart.
enum {
  kMsgReady = 1,
  kMsgSurfacesAllocated = 2,
  kMsgFrameReady = 3,
  kMsgError = 4,
  kMsgResize = 5,
  kMsgPointerEvent = 6,
  kMsgKeyEvent = 7,
  kMsgShutdown = 8,
  kMsgCapture = 9,
  kMsgCaptured = 10,
  // Forwarded platform traffic, when the guest was started with
  // FW_FORWARD_PLATFORM=1 — see ForwardPlatformMessage in host.c.
  kMsgPlatformMessage = 11,  // guest → GUI: [u32 id][u32 n][channel][bytes]
  kMsgPlatformReply = 12,    // GUI → guest: [u32 id][bytes]
  kMsgPlatformSend = 13,     // GUI → guest: [u32 n][channel][bytes]
};

// Connects to the GUI's Unix domain socket. Returns the fd, or -1 on failure.
int ipc_connect(const char* socket_path);

// Sends one framed message: [uint32 len][uint8 type][payload]. Thread-safe.
bool ipc_send(int fd, uint8_t type, const uint8_t* payload, size_t len);

// Reads exactly one framed message. On success returns the type tag and sets
// *payload (malloc'd, caller frees; NULL if empty) and *len. Returns -1 on
// EOF or error.
int ipc_read(int fd, uint8_t** payload, size_t* len);

#endif  // EMBEDDER_IPC_H
