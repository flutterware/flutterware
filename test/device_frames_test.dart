import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware/src/device_frames.dart';

/// What gets drawn around a device: `device_frame`'s artwork for the glass and
/// the outline, our table for everything the layout reads.
void main() {
  EdgeInsets insetsOf(Device device) => EdgeInsets.fromLTRB(
    device.insetLeft,
    device.insetTop,
    device.insetRight,
    device.insetBottom,
  );

  test('every phone the table offers wears a hand-drawn body, and so does '
      'every iPad', () {
    // The Android tablets are the exception, and the only one: `device_frame`
    // draws no Android tablet.
    var bodiless = [
      for (var device in Devices.all)
        if (device.kind != DeviceKind.desktop &&
            namedFrameFor(device.id) == null)
          device.id,
    ];
    expect(bodiless, ['android-small-tablet', 'android-medium-tablet']);
  });

  test('every body fits the glass of the row that wears it', () {
    // A body is drawn around one screen. A row whose size or ratio disagreed
    // with its body's would stretch every picture inside the frame — which is
    // the one thing the table may not change without changing the body too.
    for (var device in Devices.all) {
      var named = namedFrameFor(device.id);
      if (named == null) continue;
      expect(
        named.screenSize,
        Size(device.width, device.height),
        reason: device.id,
      );
      expect(named.pixelRatio, device.pixelRatio, reason: device.id);
    }
  });

  test('the frame is drawn with the body and laid out with the table', () {
    // The body's own safe areas are its author's snapshot of one OS. Ours are
    // what ships now, so the frame carries ours — portrait and turned — and
    // the AppBar lands where the table says, on glass the artwork drew.
    for (var device in Devices.all) {
      var named = namedFrameFor(device.id);
      if (named == null) continue;
      var frame = deviceFrameFor(device)!;

      expect(frame.framePainter, same(named.framePainter), reason: device.id);
      expect(frame.screenPath, same(named.screenPath), reason: device.id);
      expect(frame.safeAreas, insetsOf(device), reason: device.id);
      expect(
        frame.rotatedSafeAreas,
        insetsOf(device.rotated()),
        reason: device.id,
      );
      expect(frame.name, device.label, reason: device.id);
    }
  });

  test('a body the table has moved away from is visible here', () {
    // The case the rule above exists for: the artwork's iPhone 12 Pro Max
    // says 44 where iOS 26 says 47, and its 16s say 21 at the bottom in
    // landscape where iOS 26 says 20.
    expect(namedFrameFor('iphone-12-pro-max')!.safeAreas.top, 44);
    expect(deviceFrameFor(Devices.iphone12ProMax)!.safeAreas.top, 47);
    expect(namedFrameFor('iphone-16')!.rotatedSafeAreas!.bottom, 21);
    expect(deviceFrameFor(Devices.iphone16)!.rotatedSafeAreas!.bottom, 20);
  });

  test('a screen its body does not fit is drawn rather than squeezed', () {
    // A project can declare a device under a table id with a size of its
    // own. The body for that id would stretch it, so it gets the silhouette
    // its numbers build instead.
    var resized = Device(
      'iphone-16',
      'iPhone 16',
      kind: DeviceKind.phone,
      platform: DevicePlatform.ios,
      group: 'iOS',
      width: 400,
      height: 860,
      pixelRatio: 3,
      insetTop: 59,
      insetBottom: 34,
    );
    var frame = deviceFrameFor(resized)!;

    expect(frame.framePainter, isA<IslandPhoneFramePainter>());
    expect(frame.screenSize, const Size(400, 860));
  });

  group('an iPhone with no artwork', () {
    // A project can declare one, and the next model will be one until the
    // artwork catches up.
    var air = Device(
      'iphone-air',
      'iPhone Air',
      kind: DeviceKind.phone,
      platform: DevicePlatform.ios,
      group: 'iOS',
      width: 420,
      height: 912,
      pixelRatio: 3,
      insetTop: 68,
      insetBottom: 34,
      landscape: DeviceInsets(left: 68, right: 68, bottom: 20),
    );

    test('gets our island body rather than the generic lozenge', () {
      // The bug this half exists for: `iphone-16` once had no artwork, so it
      // drew as `DeviceInfo.genericPhone` — an 80pt forehead and a camera dot
      // above the glass, which is a generic Android and reads as one.
      expect(namedFrameFor(air.id), isNull);
      expect(deviceFrameFor(air)!.framePainter, isA<IslandPhoneFramePainter>());
    });

    test('whose island is a hole in the screen, not a pill drawn over it', () {
      // Which is what makes it black without anything rendering there, and
      // what stops a demo from painting over the top of it.
      var path = deviceFrameFor(air)!.screenPath;
      var glass = path.getBounds();

      expect(
        path.contains(Offset(glass.center.dx, glass.top + 25)),
        isFalse,
        reason: 'the middle of the island is not screen',
      );
      expect(
        path.contains(Offset(glass.left + 90, glass.top + 25)),
        isTrue,
        reason: 'the glass beside it is',
      );
    });

    test('built from its own numbers, so it says what it looks like turned', () {
      // `rotatedSafeAreas` left to its default is zero rather than null, and a
      // body like that claims it rotates and then draws landscape with no
      // island and no home indicator at all.
      var frame = deviceFrameFor(air)!;
      var turned = air.rotated();

      expect(frame.screenSize, Size(air.width, air.height));
      expect(frame.pixelRatio, air.pixelRatio);
      expect(frame.safeAreas, insetsOf(air));
      expect(frame.rotatedSafeAreas, insetsOf(turned));
      expect(frame.name, air.label);
      // The frame is bigger than the glass, and the glass sits inside it — a
      // painter drawing to the wrong box would put the screen off the body.
      expect(frame.frameSize.width, greaterThan(air.width));
      expect(frame.frameSize.height, greaterThan(air.height));
      expect(frame.screenPath.getBounds().size, Size(air.width, air.height));
    });
  });

  test('a generic silhouette can be turned, and knows what it looks like '
      'turned', () {
    // `rotatedSafeAreas` defaults to zero rather than null, and `canRotate` is
    // `!= null` — so a body built without it claims it rotates and then draws
    // landscape with no status bar and no gesture bar at all.
    var frame = deviceFrameFor(Devices.androidSmallTablet)!;

    expect(frame.rotatedSafeAreas, isNotNull);
    expect(frame.rotatedSafeAreas, insetsOf(Devices.androidSmallTablet));
  });

  test('a desktop gets no silhouette to turn', () {
    expect(deviceFrameFor(Devices.wideWindow), isNull);
  });

  test('asking whether a device has a body agrees with drawing one', () {
    // The frame toggle asks the cheap question every build; the canvas asks the
    // expensive one when it draws. A disagreement is a switch that is live for
    // a picture it cannot change, which is what it used to be for a window.
    for (var device in Devices.all) {
      expect(
        canBeFramed(device),
        deviceFrameFor(device) != null,
        reason: device.id,
      );
    }
  });

  test('no named frame for an id outside the table', () {
    expect(namedFrameFor('android-medium'), isNull);
    expect(namedFrameFor('iphone-13-mini'), isNull);
    expect(namedFrameFor('macbook-pro'), isNull);
    expect(namedFrameFor('nonsense'), isNull);
  });
}
