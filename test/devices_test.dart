import 'package:flutterware/devices.dart';
import 'package:test/test.dart';

/// Orientation as an axis over the table: what turning a device does to its
/// numbers, and which devices decline.
void main() {
  test('a tablet is swap-only — the insets stay where they are', () {
    var landscape = Devices.iPad.oriented(ScreenOrientation.landscape);

    expect(landscape.width, Devices.iPad.height);
    expect(landscape.height, Devices.iPad.width);
    // An iPad keeps its status bar across the top in landscape, which is why
    // nothing is declared for it and the default is right.
    expect(landscape.insetTop, Devices.iPad.insetTop);
    expect(landscape.insetLeft, 0);
  });

  test('a notched phone reads its declared landscape insets, not a rotation of '
      'the portrait four', () {
    var landscape = Devices.iphone13.oriented(ScreenOrientation.landscape);

    // The status bar is *gone*, not moved to a side — the whole reason these
    // are declared rather than permuted.
    expect(landscape.insetTop, 0);
    expect(landscape.insetLeft, 47);
    expect(landscape.insetRight, 47);
    // The home indicator stays at the interface bottom, and shrinks — to 20 on
    // iOS 26, a point less than iOS 18 gave it.
    expect(landscape.insetBottom, 20);
  });

  test('turning a device turns its keyboard too', () {
    // The one number downstream reads is `keyboard`, so `rotated()` has to put
    // the landscape one there — the same trick the landscape insets play.
    expect(Devices.iphone13.keyboard, 335);
    expect(
      Devices.iphone13.oriented(ScreenOrientation.landscape).keyboard,
      209,
    );
    // And the declaration survives the turn, or turning twice would lose it.
    expect(
      Devices.iphone13.oriented(ScreenOrientation.landscape).landscapeKeyboard,
      209,
    );
  });

  test(
    'every screen a finger touches declares a keyboard, and no window does',
    () {
      for (var device in Devices.all) {
        var reason = device.id;
        if (device.kind == DeviceKind.desktop) {
          expect(device.keyboard, 0, reason: reason);
          expect(device.landscapeKeyboard, isNull, reason: reason);
        } else {
          expect(device.keyboard, greaterThan(0), reason: reason);
          expect(device.landscapeKeyboard, isNotNull, reason: reason);
          // **A phone's keyboard shrinks when it turns; a tablet's does not.**
          // Measured, and it caught the version of this test that assumed one
          // rule for both: a phone in landscape has almost no height to spare
          // and the rows are squashed, where a tablet has room either way — an
          // iPad's landscape keyboard is *taller* (bigger keys across a wider
          // screen) and Gboard's is the same 320 in both.
          expect(
            device.landscapeKeyboard,
            device.kind == DeviceKind.phone
                ? lessThan(device.keyboard)
                : greaterThanOrEqualTo(device.keyboard),
            reason: reason,
          );
        }
      }
    },
  );

  test('turning keeps the identity: a rotated iPad is still `ipad`', () {
    var landscape = Devices.iPad.oriented(ScreenOrientation.landscape);

    expect(landscape.id, 'ipad');
    expect(landscape.label, Devices.iPad.label);
    expect(landscape.pixelRatio, Devices.iPad.pixelRatio);
  });

  test('a desktop does not turn, and says so', () {
    expect(Devices.macbookPro.canRotate, isFalse);
    expect(Devices.iPad.canRotate, isTrue);
    expect(Devices.iphone16.canRotate, isTrue);

    var asked = Devices.macbookPro.oriented(ScreenOrientation.landscape);

    expect(asked.width, Devices.macbookPro.width);
    expect(asked.height, Devices.macbookPro.height);
  });

  test('portrait and null are the same device, untouched', () {
    expect(
      Devices.iphone16.oriented(ScreenOrientation.portrait),
      same(Devices.iphone16),
    );
    expect(Devices.iphone16.oriented(null), same(Devices.iphone16));
  });

  test('a dropped phone still answers its id, with the phone that replaced '
      'it', () {
    // A saved address or a scenario config that names one goes on working;
    // the picker, which is where the change is meant to show, no longer
    // offers it.
    expect(deviceById('iphone-13-mini'), same(Devices.iphone13));
    expect(deviceById('android-medium'), same(Devices.androidTall));
    expect(deviceIds, isNot(contains('iphone-13-mini')));
    expect(deviceIds, isNot(contains('android-medium')));
  });

  test('the vocabulary is one list, portrait first', () {
    expect(orientationIds, ['portrait', 'landscape']);
    expect(orientationById('landscape'), ScreenOrientation.landscape);
    expect(orientationById('sideways'), isNull);
    expect(isOrientationId('portrait'), isTrue);
    expect(isOrientationId('upside-down'), isFalse);
  });
}
