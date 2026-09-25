// Hosts with no clipboard answer yet: every clipboard call is left to the
// empty answer, as before. See clipboard.h.
#include "clipboard.h"

bool clipboard_answer(const uint8_t* message, size_t length, uint8_t** reply,
                      size_t* reply_length) {
  (void)message;
  (void)length;
  (void)reply;
  (void)reply_length;
  return false;
}
