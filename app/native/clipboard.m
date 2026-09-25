// macOS: the general pasteboard. See clipboard.h.
#import <AppKit/AppKit.h>

#include "clipboard.h"

static bool Reply(id result, uint8_t** reply, size_t* reply_length) {
  // JSONMethodCodec's success envelope: the result, alone in an array.
  NSData* data = [NSJSONSerialization dataWithJSONObject:@[ result ?: [NSNull null] ]
                                                 options:0
                                                   error:nil];
  if (data == nil) return false;
  *reply_length = data.length;
  *reply = (uint8_t*)malloc(data.length);
  memcpy(*reply, data.bytes, data.length);
  return true;
}

bool clipboard_answer(const uint8_t* message, size_t length, uint8_t** reply,
                      size_t* reply_length) {
  @autoreleasepool {
    NSData* data = [NSData dataWithBytes:message length:length];
    id call = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![call isKindOfClass:[NSDictionary class]]) return false;
    NSString* method = call[@"method"];
    id args = call[@"args"];
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if ([method isEqualToString:@"Clipboard.setData"]) {
      id text = [args isKindOfClass:[NSDictionary class]] ? args[@"text"] : nil;
      [pasteboard clearContents];
      if ([text isKindOfClass:[NSString class]]) {
        [pasteboard setString:text forType:NSPasteboardTypeString];
      }
      return Reply(nil, reply, reply_length);
    }
    if ([method isEqualToString:@"Clipboard.getData"]) {
      NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
      return Reply(text ? @{@"text" : text} : nil, reply, reply_length);
    }
    if ([method isEqualToString:@"Clipboard.hasStrings"]) {
      BOOL has = [pasteboard stringForType:NSPasteboardTypeString] != nil;
      return Reply(@{@"value" : @(has)}, reply, reply_length);
    }
    return false;
  }
}
