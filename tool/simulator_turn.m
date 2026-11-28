// Turns a booted iOS simulator, with no Simulator window open:
//
//   simulator_turn <udid> portrait|landscape
//
// `tool/measure_devices.dart` builds it with clang when an iPad has to be
// turned: from iPadOS 27 an app that asks for landscape turns alone, and the
// keyboard and the insets stay with the upright device. `simctl` has no way to
// turn a device, so this sends what Simulator sends when its window is turned:
// a "device orientation changed" event on the simulator's PurpleWorkspacePort,
// found through CoreSimulator.
//
// Both are private, and either can change with an Xcode. When this fails the
// measuring tool says so and asks for the simulator to be turned by hand.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/message.h>

static const char *kCoreSimulator =
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";

// A GraphicsServices event record after its mach header: the type, and at
// 0x48 the size of the event's own data, which follows at 0x4C. The host bit
// marks an event from the machine running the simulator.
static const uint32_t kDeviceOrientationChanged = 50;
static const uint32_t kFromHost = 0x20000;

// UIDeviceOrientation's values.
static const uint32_t kPortrait = 1;
static const uint32_t kLandscapeLeft = 3;

static int fail(NSString *message) {
  fprintf(stderr, "%s\n", message.UTF8String);
  return 1;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3) return fail(@"usage: simulator_turn <udid> portrait|landscape");
    NSUUID *udid = [[NSUUID alloc] initWithUUIDString:@(argv[1])];
    NSString *way = @(argv[2]);
    uint32_t orientation;
    if ([way isEqualToString:@"portrait"]) {
      orientation = kPortrait;
    } else if ([way isEqualToString:@"landscape"]) {
      orientation = kLandscapeLeft;
    } else {
      return fail([NSString stringWithFormat:@"no such orientation: %@", way]);
    }
    if (!udid) return fail(@"not a device UDID");

    if (!dlopen(kCoreSimulator, RTLD_NOW)) return fail(@(dlerror()));
    NSString *developer = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (developer.length == 0) {
      NSTask *select = [NSTask new];
      NSPipe *out = [NSPipe pipe];
      select.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
      select.arguments = @[ @"-p" ];
      select.standardOutput = out;
      [select launchAndReturnError:nil];
      [select waitUntilExit];
      developer = [[[NSString alloc]
          initWithData:[out.fileHandleForReading readDataToEndOfFile]
              encoding:NSUTF8StringEncoding]
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }

    NSError *error = nil;
    id context = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
        NSClassFromString(@"SimServiceContext"),
        NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), developer, &error);
    if (!context) return fail(error.localizedDescription ?: @"no CoreSimulator service");
    id set = ((id(*)(id, SEL, NSError **))objc_msgSend)(
        context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
    if (!set) return fail(error.localizedDescription ?: @"no device set");
    NSDictionary *devices =
        ((id(*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(@"devicesByUDID"));
    id device = devices[udid];
    if (!device) return fail(@"no simulator with that UDID");
    mach_port_t port = ((mach_port_t(*)(id, SEL, id, NSError **))objc_msgSend)(
        device, NSSelectorFromString(@"lookup:error:"), @"PurpleWorkspacePort", &error);
    if (port == MACH_PORT_NULL) {
      return fail(error.localizedDescription ?: @"the simulator has no event port; is it booted?");
    }

    uint8_t message[0x70] = {0};
    mach_msg_header_t *header = (mach_msg_header_t *)message;
    header->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    header->msgh_size = sizeof(message);
    header->msgh_remote_port = port;
    header->msgh_id = 0x7B;
    *(uint32_t *)(message + 0x18) = kDeviceOrientationChanged | kFromHost;
    *(uint32_t *)(message + 0x48) = sizeof(uint32_t);
    *(uint32_t *)(message + 0x4C) = orientation;
    kern_return_t sent = mach_msg(header, MACH_SEND_MSG, header->msgh_size, 0, MACH_PORT_NULL,
                                  MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (sent != KERN_SUCCESS) {
      return fail([NSString stringWithFormat:@"the event was not sent (%d)", sent]);
    }
  }
  return 0;
}
