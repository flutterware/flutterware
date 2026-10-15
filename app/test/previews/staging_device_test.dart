import 'package:flutterware/src/device_frames.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the vocabulary an address may use', () {
    test('every offered device has an id, and they are distinct', () {
      var ids = [for (var d in Devices.all) d.id];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, everyElement(matches(RegExp(r'^[a-z0-9-]+$'))));
    });

    test('a phone and a tablet are touched, a window is clicked', () {
      // Both halves of staging a device, and the framework wants both before it
      // will behave like a phone: the platform decides the convention, the
      // pointer kind decides whether a tap outside a field counts as one.
      expect(deviceIsTouched(Devices.iphone16), isTrue);
      expect(deviceIsTouched(Devices.iPad), isTrue);
      expect(deviceIsTouched(Devices.window), isFalse);
      expect(deviceIsTouched(null), isFalse);
    });

    test('the accepted list is the offered list plus fit', () {
      // One list, so the picker and the address cannot disagree about what
      // exists. A vocabulary documented apart from the code that enforces it is
      // a vocabulary that is wrong.
      expect(deviceIds.first, fitDeviceId);
      expect(deviceIds, hasLength(Devices.all.length + 1));
      expect(deviceIds.every(isDeviceId), isTrue);
    });

    test('an id names the device that carries it', () {
      for (var device in Devices.all) {
        expect(deviceById(device.id), same(device), reason: device.id);
      }
      expect(deviceById(fitDeviceId), isNull, reason: 'fit is not a device');
    });
  });

  group('the list is the only source', () {
    test('a tablet with no artwork is drawn from its own numbers', () {
      // The generic half, which only the Android tablets still take:
      // `device_frame` draws no Android tablet. `device_frames_test.dart`
      // covers the other two halves — the borrowed bodies, and the iPhone one
      // we draw ourselves.
      var device = deviceById('android-small-tablet')!;
      expect(namedFrameFor(device.id), isNull, reason: 'no body to borrow');
      var chrome = deviceFrameFor(device)!;

      expect(chrome.screenSize.width, device.width);
      expect(chrome.screenSize.height, device.height);
      expect(chrome.pixelRatio, device.pixelRatio);
      expect(chrome.safeAreas.top, device.insetTop);
      expect(chrome.safeAreas.bottom, device.insetBottom);
      expect(chrome.name, device.label);
    });

    test('a window size gets none, because the panel already is one', () {
      expect(deviceFrameFor(deviceById('window')!), isNull);
      expect(deviceFrameFor(deviceById('window-wide')!), isNull);
    });

    test('the screens the windows replaced still resolve', () {
      // A stored address is the case that matters: `?device=macbook-pro` was
      // written down by somebody who wanted a desktop stage, and a rename that
      // answered "no such device" would read as a broken link rather than as a
      // better name.
      expect(deviceById('macbook-pro')?.id, 'window-wide');
      expect(deviceById('wide-monitor')?.id, 'window-wide');
      expect(deviceById('windows-laptop')?.id, 'windows-window');
      expect(deviceById('linux-laptop')?.id, 'linux-window');
      expect(isDeviceId('macbook-pro'), isTrue);

      // And they are gone from the picker, which is where the rename is meant
      // to be visible: one way to ask for a stage, not two.
      expect(deviceIds, isNot(contains('macbook-pro')));
      expect(deviceById('no-such-machine'), isNull);
    });

    test('every phone and tablet can be drawn', () {
      for (var device in Devices.all) {
        expect(
          deviceFrameFor(device),
          device.kind == DeviceKind.desktop ? isNull : isNotNull,
          reason: device.id,
        );
      }
    });
  });

  group('a viewport built from a device', () {
    test('is physical pixels, but keeps the logical ratio and the notch', () {
      var viewport = CaptureViewport.of(deviceById('iphone-13')!);

      // 390x844 at 3x. The demo must read 390 from MediaQuery, not 1170, so the
      // ratio travels beside the buffer rather than being folded into it.
      expect(viewport.width, 1170);
      expect(viewport.height, 2532);
      expect(viewport.pixelRatio, 3);
      expect(viewport.insetTop, 47);
      expect(viewport.insetBottom, 34);
    });

    test('an explicit size stretches it without flattening it', () {
      // Asking for a taller iPhone is asking for a taller iPhone, not for a
      // slab of glass with no notch.
      var viewport = CaptureViewport.of(deviceById('iphone-13')!)
          .resized(height: 3000);

      expect(viewport.width, 1170);
      expect(viewport.height, 3000);
      expect(viewport.pixelRatio, 3);
      expect(viewport.insetTop, 47);
    });

    test('the panel is the degenerate case', () {
      expect(CaptureViewport.panel.pixelRatio, 1);
      expect(CaptureViewport.panel.insetTop, 0);
    });
  });

  group('a device is derived, never held', () {
    // The bug this replaced: the picker set a field on the staging, the panel
    // copied that into the address a frame later, and the address copied back.
    // Two sources of truth with a copy loop between them — so a pick could be
    // read back from an address that had not caught up, and erased. There is
    // nothing to fall out of step with now.
    test('what the address names', () {
      expect(resolveDevice('iphone-13')?.id, 'iphone-13');
    });

    test('naming nothing is the panel', () {
      // It used to be the entry's turn to speak here, through `formFactor`.
      // With the declaration gone there is one answer and no `??` behind it.
      expect(resolveDevice(null), isNull);
    });

    test('fit is a choice, and reads as one', () {
      // Kept as a value rather than an absent parameter even though the two now
      // resolve alike: an address that says `fit` says somebody chose the panel,
      // and that survives a reload where an absent parameter would not.
      expect(resolveDevice(fitDeviceId), isNull);
      expect(unknownDeviceIn(fitDeviceId), isNull);
    });

    test('an unknown device frames as the panel, and is reported', () {
      // Loudly, because the silent failure is the dangerous one: framing as
      // the panel when the address asked for an iPhone produces a picture that
      // is wrong without looking wrong.
      expect(resolveDevice('iphone-99'), isNull);
      expect(unknownDeviceIn('iphone-99'), 'iphone-99');
    });

    test('and a good one is not', () {
      expect(unknownDeviceIn('ipad'), isNull);
      expect(unknownDeviceIn(fitDeviceId), isNull);
      expect(unknownDeviceIn(null), isNull);
    });
  });
}
