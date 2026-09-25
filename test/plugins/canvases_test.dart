import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

/// The half of the canvas that a project can hold itself.
///
/// [PreviewCanvas] and [canvasFor] are pure Dart and exported by `plugins.dart`,
/// `devices.dart` and `flutter_test.dart` alike, so the list can live in the
/// project's own package and be handed to `tool/flutterware.dart` and to a
/// plain `flutter test` both. That is the point of the type: a rule applied
/// twice is a rule that eventually differs, and the value of writing the shape
/// of a repository down is that everything looking at it agrees.
void main() {
  const app = Pkg('app');

  group('the prefix', () {
    test('the empty one covers everything', () {
      expect(const PreviewCanvas('').covers('anything/at/all.dart'), isTrue);
      expect(const PreviewCanvas('').covers(''), isTrue);
    });

    test('slashes and a lone dot are tidied to the same rule', () {
      for (var written in ['demo', '/demo', 'demo/', ' demo ']) {
        expect(PreviewCanvas(written).root, 'demo', reason: written);
      }
      for (var written in ['', '.', '/', '  ']) {
        expect(PreviewCanvas(written).root, isEmpty, reason: '"$written"');
      }
    });

    test('it matches on segments, never as text', () {
      var canvas = const PreviewCanvas('src/mobile');

      expect(canvas.covers('src/mobile/tile.dart'), isTrue);
      expect(canvas.covers('src/mobile'), isTrue);
      expect(canvas.covers('src/mobile_legacy/tile.dart'), isFalse);
      expect(canvas.covers('src/desktop/bar.dart'), isFalse);
    });

    test('a prefix may name a file, which is how one entry differs', () {
      // Supported, not incidental. It falls out of matching on segments — the
      // last one is a file — and the documentation used to say "a directory",
      // which left somebody who tried it unable to tell whether it was
      // something they could depend on.
      var canvas = const PreviewCanvas('src/mobile/tile.dart');

      expect(canvas.covers('src/mobile/tile.dart'), isTrue);
      expect(canvas.covers('src/mobile/other.dart'), isFalse);
      // And it beats the directory it sits in, by the longest-prefix rule.
      expect(
        canvasFor(const [
          PreviewCanvas('src/mobile', devices: [Devices.iphone16]),
          PreviewCanvas('src/mobile/tile.dart', devices: [Devices.iPad]),
        ], 'src/mobile/tile.dart')?.defaultDevice,
        Devices.iPad,
      );
    });
  });

  group('canvasFor', () {
    const mobile = PreviewCanvas('src/mobile', devices: [Devices.iphone16]);
    const wide = PreviewCanvas('src/mobile/wide', devices: [Devices.iPad]);
    const whole = PreviewCanvas('', devices: [Devices.wideWindow]);

    test('the longest prefix wins, in either declaration order', () {
      for (var canvases in [
        [mobile, wide],
        [wide, mobile],
      ]) {
        expect(canvasFor(canvases, 'src/mobile/tile.dart'), same(mobile));
        expect(canvasFor(canvases, 'src/mobile/wide/grid.dart'), same(wide));
      }
    });

    test('a subtree beats the whole package', () {
      expect(canvasFor([whole, mobile], 'src/mobile/tile.dart'), same(mobile));
      expect(canvasFor([whole, mobile], 'src/other.dart'), same(whole));
    });

    test('nothing covering the path is no canvas, not the first one', () {
      expect(canvasFor([mobile], 'src/desktop/bar.dart'), isNull);
      expect(canvasFor(const [], 'anything.dart'), isNull);
    });

    test('the head is the default and the list is the offered set', () {
      const both = PreviewCanvas(
        'src/mobile',
        devices: [Devices.iphone16, Devices.iphoneSe],
        orientations: [ScreenOrientation.landscape],
        keyboards: [KeyboardMode.up],
      );

      expect(both.defaultDevice, Devices.iphone16);
      expect(both.defaultOrientation, ScreenOrientation.landscape);
      expect(both.defaultKeyboard, KeyboardMode.up);
      expect(both.devices, hasLength(2));
    });

    test('a canvas that says nothing about the keyboard says auto', () {
      // Absence is not `down`: an entry under a canvas with no `keyboards:`
      // still raises one when it focuses a field, because that is what a
      // phone does and what `auto` means.
      expect(const PreviewCanvas('src/x').defaultKeyboard, isNull);
    });

    test('an empty canvas is a subtree opting out of the one above it', () {
      const plain = PreviewCanvas('src/raw');

      expect(
        canvasFor([whole, plain], 'src/raw/x.dart')?.defaultDevice,
        isNull,
      );
    });
  });

  group('over the wire', () {
    test('it survives being printed and read back', () {
      var read = PreviewCanvas.fromJson(
        const PreviewCanvas(
          'demo/mobile/',
          devices: [Devices.iphone16, Devices.iphoneSe],
          orientations: [ScreenOrientation.landscape],
          keyboards: [KeyboardMode.up, KeyboardMode.auto],
        ).toJson(),
      );

      // Normalised on the way out, so the two sides compare one spelling.
      expect(read?.root, 'demo/mobile');
      expect(read?.devices.map((d) => d.id), ['iphone-16', 'iphone-se']);
      expect(read?.orientations, [ScreenOrientation.landscape]);
      expect(read?.keyboards, [KeyboardMode.up, KeyboardMode.auto]);
    });

    test('a device the reader has no entry for drops out', () {
      // The config is written against the flutterware the project pins, which
      // can run ahead of the GUI reading its manifest. Fewer devices, never a
      // canvas that refuses to resolve.
      var read = PreviewCanvas.fromJson(const {
        'prefix': 'demo',
        'devices': ['iphone-99', 'iphone-16'],
      });

      expect(read?.devices.map((d) => d.id), ['iphone-16']);
    });

    test('a shape this is not is null rather than a throw', () {
      expect(PreviewCanvas.fromJson('demo'), isNull);
      expect(PreviewCanvas.fromJson(const {'devices': []}), isNull);
    });
  });

  group('the declaration', () {
    test('canvases ride the manifest', () {
      late String emitted;
      Flutterware.configure((fw) {
        fw.use(
          Previews(
            packages: [
              PreviewsPackage(
                app,
                directory: 'demo',
                canvases: const [
                  PreviewCanvas('demo/mobile', devices: [Devices.iphone16]),
                  PreviewCanvas('demo/desktop', devices: [Devices.wideWindow]),
                ],
              ),
            ],
          ),
        );
      }, emit: (line) => emitted = line);

      expect(PluginManifest.parse(emitted).plugins.single.config['packages'], [
        {
          'path': 'app',
          'directory': 'demo',
          'canvases': [
            {
              'prefix': 'demo/mobile',
              'devices': ['iphone-16'],
            },
            {
              'prefix': 'demo/desktop',
              'devices': ['window-wide'],
            },
          ],
        },
      ]);
    });

    test('one prefix declared twice is refused', () {
      // Longest prefix wins, so two of one prefix is one rule written twice and
      // either resolution drops an answer somebody wrote down — the same
      // reasoning that refuses a package declared twice, one level up.
      expect(
        () => Flutterware.configure(
          (fw) => fw.use(
            Previews(
              packages: [
                PreviewsPackage(
                  app,
                  canvases: const [
                    PreviewCanvas('demo/', devices: [Devices.iphone16]),
                    PreviewCanvas('demo', devices: [Devices.iPad]),
                  ],
                ),
              ],
            ),
          ),
          emit: (_) {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('"demo"'),
          ),
        ),
      );
    });

    test('a device that is not in the table is refused', () {
      // A canvas crosses to the renderer as ids. This one would resolve to
      // nothing there, and its entries would render on the plain rectangle
      // with no word about why.
      const artwork = Device(
        'artwork',
        'Artwork',
        kind: DeviceKind.desktop,
        platform: DevicePlatform.android,
        group: 'Store',
        width: 1024,
        height: 500,
        pixelRatio: 1,
      );
      // And a table id on another screen would resolve to the table's.
      var turned = Devices.iphone16.rotated();

      for (var package in [
        PreviewsPackage(
          app,
          canvases: const [
            PreviewCanvas('demo/store', devices: [artwork]),
          ],
        ),
        PreviewsPackage(
          app,
          canvases: [
            PreviewCanvas('demo', devices: [Devices.iphoneSe, turned]),
          ],
        ),
        PreviewsPackage(app, device: artwork),
      ]) {
        expect(
          () => Flutterware.configure(
            (fw) => fw.use(Previews(packages: [package])),
            emit: (_) {},
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('Devices'), contains('width')),
            ),
          ),
        );
      }
    });

    test('every device of the table is accepted, renamed ones too', () {
      expect(
        () => Flutterware.configure(
          (fw) => fw.use(
            Previews(
              packages: [
                PreviewsPackage(
                  app,
                  device: Devices.iphone16,
                  canvases: const [
                    PreviewCanvas('demo', devices: Devices.all),
                    // ignore: deprecated_member_use_from_same_package
                    PreviewCanvas('old', devices: [Devices.macbookPro]),
                  ],
                ),
              ],
            ),
          ),
          emit: (_) {},
        ),
        returnsNormally,
      );
    });

    test('a package declaring none says nothing about them', () {
      late String emitted;
      Flutterware.configure(
        (fw) => fw.use(Previews(packages: [PreviewsPackage(app)])),
        emit: (line) => emitted = line,
      );

      expect(PluginManifest.parse(emitted).plugins.single.config['packages'], [
        {'path': 'app'},
      ]);
    });
  });
}
