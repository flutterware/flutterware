import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';

/// The sizes two stores publish, asserted rather than believed.
///
/// This file is the reason the store plugin has no validator. Every number a
/// listing can produce is fixed at declaration time, so the place to be sure of
/// them is here, once, at build time — not in a panel that inspects the output
/// afterwards and tells somebody their upload will bounce.
///
/// It is also the guard on the device table. `iphone-16-pro-max`,
/// `iphone-12-pro-max` and `ipad-pro-13` land on Apple's sizes *exactly*, and
/// that is a coincidence of numbers rather than a thing either file promises
/// the other. A well-meant edit to a pixel ratio would move a store size and
/// nothing else would notice.
void main() {
  group('the App Store', () {
    test('gets its sizes out of the device table', () {
      expect(AppStoreClass.iphone69.canvas.label, '1320×2868');
      expect(AppStoreClass.iphone65.canvas.label, '1284×2778');
      expect(AppStoreClass.ipad13.canvas.label, '2048×2732');
    });

    test('composes nothing, because its canvases are its devices', () {
      for (var target in const AppStoreListing(
        locales: {'en': 'en-US'},
      ).targets) {
        expect(
          target.needsComposition,
          isFalse,
          reason: '${target.id} would need a frame to be legal',
        );
      }
    });
  });

  group('Google Play', () {
    test('puts the phone on the tallest canvas it allows', () {
      // 2:1 exactly. Any taller is refused; any shorter throws away room the
      // composition can use.
      expect(PlayClass.phone.canvas.label, '1080×2160');
      expect(PlayClass.tablet10.canvas.label, '1600×2560');
    });

    test('renders the phone on a real Pixel and composes onto the canvas', () {
      // The distinction the whole design turns on: what the app renders as is
      // 20:9, which Play would refuse, so the two numbers differ *here* and
      // nowhere in the App Store listing.
      expect(PlayClass.phone.device.id, 'android-tall');
      expect(
        PlayClass.phone.canvas,
        isNot(StoreCanvas.of(PlayClass.phone.device)),
      );
      expect(PlayClass.phone.canvas.width, lessThan(1082));
    });

    test('needs a frame for the phone and none for the tablet', () {
      var targets = {
        for (var t in const PlayListing(locales: {'en': 'en-US'}).targets)
          t.id: t,
      };
      expect(targets['phone']!.needsComposition, isTrue);
      expect(
        targets['tablet-10']!.needsComposition,
        isFalse,
        reason: "1600×2560 is Play's own recommendation, natively",
      );
    });

    test('never declares a canvas Play would refuse', () {
      for (var c in PlayClass.values) {
        var short = c.canvas.width < c.canvas.height
            ? c.canvas.width
            : c.canvas.height;
        var long = c.canvas.width < c.canvas.height
            ? c.canvas.height
            : c.canvas.width;
        expect(short, greaterThanOrEqualTo(320), reason: '${c.id} too small');
        expect(long, lessThanOrEqualTo(3840), reason: '${c.id} too big');
        expect(
          long,
          lessThanOrEqualTo(short * 2),
          reason:
              '${c.id} is ${(long / short).toStringAsFixed(3)}:1, and Play '
              'refuses anything past 2:1',
        );
        expect(
          short,
          greaterThanOrEqualTo(1080),
          reason:
              '${c.id} is under the short side Play wants for prominent '
              'placement',
        );
      }
    });
  });

  group('a declaration', () {
    test('survives the trip to the GUI and back', () {
      var listings = <Listing>[
        const Listing.appStore(
          locales: {'en': 'en-US', 'fr': 'fr-FR'},
          classes: [AppStoreClass.iphone69],
        ),
        const Listing.play(locales: {'en': 'en-US'}),
      ];
      var read = [for (var l in listings) Listing.fromJson(l.toJson())!];
      expect(read[0].store, 'app-store');
      expect(read[0].locales, {'en': 'en-US', 'fr': 'fr-FR'});
      expect([for (var t in read[0].targets) t.id], ['iphone-6-9']);
      expect(read[1].store, 'play');
      expect([for (var t in read[1].targets) t.id], ['phone', 'tablet-10']);
    });

    test('reads back a store this build does not know as null, not as a '
        'guess', () {
      // A project pinning a newer flutterware than the studio opening it. The
      // alternative is reading an unknown store as one of the two we have and
      // exporting the wrong sizes under the right name.
      expect(
        Listing.fromJson({'store': 'galaxy-store', 'locales': {}}),
        isNull,
      );
    });

    test('carries the app through the config whole', () {
      var app = const StoreShotsApp(
        Pkg('fixtures/probe_app'),
        name: 'shop',
        listings: [
          Listing.appStore(locales: {'en': 'en-US'}),
        ],
        file: 'test/store/listing_test.dart',
      );
      var read = StoreShotsApp.fromJson(app.toJson());
      expect(read.path, 'fixtures/probe_app');
      expect(read.name, 'shop');
      expect(read.file, 'test/store/listing_test.dart');
      expect(read.layout, StoreLayout.fastlane);
      expect(read.listings.single.store, 'app-store');
    });
  });
}
