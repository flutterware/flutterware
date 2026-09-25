#ifndef EMBEDDER_CLIPBOARD_H
#define EMBEDDER_CLIPBOARD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The guest's clipboard: the framework's clipboard calls on `flutter/platform`
// — `Clipboard.setData`, `Clipboard.getData`, `Clipboard.hasStrings` — answered
// from the host's own pasteboard.
//
// A guest is a real process on the machine, so the machine's clipboard is the
// honest answer, and it is what makes copy and paste cross between a guest,
// the studio and every other app with nothing in between. Without it a paste
// asked the platform, got the empty answer every unhandled call gets, and put
// nothing in the field.
//
// Takes the message as the framework sent it (JSON). Returns true and sets
// *reply to a malloc'd JSON reply the caller frees when the message was one of
// the three; false for anything else, which the caller answers as before.
bool clipboard_answer(const uint8_t* message, size_t length, uint8_t** reply,
                      size_t* reply_length);

#endif
