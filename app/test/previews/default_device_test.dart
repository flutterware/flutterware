import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// What a preview is framed as when nobody says.
///
/// The default was 900 × 700 — landscape, desktop-shaped — with no way through
/// it from the project. That is the bad kind of wrong: a phone screen laid out
/// in a 900-wide frame does not overflow and does not wrap, so the picture
/// looks fine and the bug you opened the preview to find is the one thing it
/// cannot show. Reported by a consumer whose catalog is 90 phone screens and
/// nothing else, who caught it because a human looked at the aspect ratio.
///
/// The precedence below is the whole of the fix, and it is the part worth
/// pinning: a project says what it is once, and every surface that renders
/// without being told agrees with it.
void main() {
  PreviewsCore coreWith(Map<String, Object?> package) => PreviewsCore(
    PluginHost(
      id: uiCatalogPluginId,
      label: 'Previews',
      worktree: const Worktree(path: '/project'),
      workspace: Workspace(
        root: '/project',
        declared: const [Pkg('.')],
        discovered: const ['.'],
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/flutter'),
      ),
      config: {
        'packages': [
          {'path': '.', ...package},
        ],
      },
    ),
  );

  group('what the package declares', () {
    test('reaches the core as a device and an orientation', () {
      var core = coreWith({'device': 'ipad', 'orientation': 'landscape'});

      var framing = core.defaultFramingFor('.');
      expect(framing.device?.id, 'ipad');
      expect(framing.orientation, ScreenOrientation.landscape);
    });

    test('a package that declares nothing still answers', () {
      expect(coreWith(const {}).defaultFramingFor('.').device, isNull);
      expect(coreWith(const {}).defaultFramingFor('.').orientation, isNull);
    });

    test('a device this build never heard of is ignored, not thrown', () {
      // Read on the way to drawing something rather than while checking a
      // command line. A typo that blanked the panel would be a worse report
      // than one that renders the rectangle it always used to.
      expect(
        coreWith({'device': 'iphone-99'}).defaultFramingFor('.').device,
        isNull,
      );
    });
  });

  /// One package, two form factors — a phone app and a desktop dashboard
  /// sharing a theme and a widget library. There is one canvas per package and
  /// no way to subdivide it, so whichever is declared frames half the catalog
  /// on the wrong screen. Declaring the package twice is what everybody tries
  /// and is refused a layer up: the path is the identity of the entry, so the
  /// second declaration is not something anything downstream could name.
  group('a canvas per subtree', () {
    var canvases = {
      'canvases': [
        {
          'prefix': 'demo/mobile',
          'devices': ['iphone-16', 'iphone-se'],
        },
        {
          'prefix': 'demo/desktop',
          'devices': ['window-wide'],
        },
      ],
    };

    test('each subtree is framed as its own', () {
      var core = coreWith(canvases);

      expect(
        core.defaultFramingFor('.', entry: 'demo/mobile/tile.dart').device?.id,
        'iphone-16',
      );
      // Fit, not the declared window — see the group below.
      expect(
        core.defaultFramingFor('.', entry: 'demo/desktop/bar.dart').device,
        isNull,
      );
    });

    test('the head of the list is the default', () {
      // The rest of it is the offered set — the picker's, and what a sweep
      // would cross. `ScenarioProfile` says this in the same words one tool
      // over, deliberately.
      expect(
        coreWith(canvases).canvasesFor('.').first.devices.map((d) => d.id),
        ['iphone-16', 'iphone-se'],
      );
    });

    test('an entry under no canvas gets the plain rectangle', () {
      expect(
        coreWith(canvases).defaultFramingFor('.', entry: 'demo/shared/x.dart'),
        (device: null, orientation: null, keyboard: null),
      );
    });

    group('a window size', () {
      // **Offered, never staged.** A phone's screen is the constraint the
      // layout has to survive, so staging it is the point; a desktop window has
      // no true size, because the person using it drags the corner — and the
      // stage that behaves that way is the plain rectangle, which is also the
      // only one shown at 1:1. A 1600-wide window in a 490-wide pane is drawn
      // at 30%, where nothing about type or spacing can be judged.
      test('is not what the subtree opens on', () {
        expect(
          coreWith(canvases)
              .defaultFramingFor('.', entry: 'demo/desktop/bar.dart')
              .device,
          isNull,
        );
      });

      test('is still declared, so the picker can offer it', () {
        // The declaration is not ignored — only the staging is. Losing the list
        // as well would leave a desktop subtree with no way to say which widths
        // it cares about.
        var canvas = coreWith(canvases)
            .canvasesFor('.')
            .firstWhere((c) => c.root == 'demo/desktop');
        expect(canvas.devices.map((d) => d.id), ['window-wide']);
      });

      test('does not suppress a phone declared beside it', () {
        // The rule is about the head being a desktop size, not about the list
        // holding one.
        var core = coreWith({
          'canvases': [
            {
              'prefix': 'demo/both',
              'devices': ['iphone-16', 'window-wide'],
            },
          ],
        });

        expect(
          core.defaultFramingFor('.', entry: 'demo/both/x.dart').device?.id,
          'iphone-16',
        );
      });
    });

    test('the longest prefix wins, whatever order they are declared in', () {
      var core = coreWith({
        'canvases': [
          {
            'prefix': 'demo/mobile/wide',
            'devices': ['ipad'],
          },
          {
            'prefix': 'demo/mobile',
            'devices': ['iphone-16'],
          },
        ],
      });

      expect(
        core.defaultFramingFor('.', entry: 'demo/mobile/tile.dart').device?.id,
        'iphone-16',
      );
      expect(
        core
            .defaultFramingFor('.', entry: 'demo/mobile/wide/grid.dart')
            .device
            ?.id,
        'ipad',
      );
    });

    test('a prefix matches on segments, not on text', () {
      // `demo/mobile` must not swallow `demo/mobile_legacy`, which is the one
      // failure a raw `startsWith` would produce and the one nobody would
      // suspect from the picture.
      expect(
        coreWith(canvases)
            .defaultFramingFor('.', entry: 'demo/mobile_legacy/tile.dart')
            .device,
        isNull,
      );
    });

    test('`device:` is the canvas with no prefix', () {
      // One mechanism underneath, rather than a package default and a set of
      // subtree ones with a precedence rule between them.
      var core = coreWith({'device': 'ipad', 'orientation': 'landscape'});

      expect(core.canvasesFor('.').single.root, isEmpty);
      var framing = core.defaultFramingFor('.', entry: 'anywhere/at/all.dart');
      expect(framing.device?.id, 'ipad');
      expect(framing.orientation, ScreenOrientation.landscape);
    });

    test('a subtree overrides the `device:` above it', () {
      var core = coreWith({
        'device': 'iphone-16',
        'canvases': [
          {
            'prefix': 'demo/tablet',
            'devices': ['ipad'],
          },
        ],
      });

      expect(
        core.defaultFramingFor('.', entry: 'demo/mobile/tile.dart').device?.id,
        'iphone-16',
      );
      expect(
        core.defaultFramingFor('.', entry: 'demo/tablet/bar.dart').device?.id,
        'ipad',
      );
    });

    test('and a desktop subtree overrides it by opening on nothing', () {
      // The same rule, with the answer the window rule gives: the package says
      // phone, this subtree says window, and a window opens on the rectangle.
      var core = coreWith({
        'device': 'iphone-16',
        'canvases': [
          {
            'prefix': 'demo/desktop',
            'devices': ['window-wide'],
          },
        ],
      });

      expect(
        core.defaultFramingFor('.', entry: 'demo/desktop/bar.dart').device,
        isNull,
      );
    });

    test('an explicit whole-package canvas is the one that stands', () {
      // Both spellings of the same rule. Merging them would be inventing a
      // third, and the explicit one is the more specific spelling.
      var core = coreWith({
        'device': 'iphone-16',
        'canvases': [
          {
            'prefix': '',
            'devices': ['ipad'],
          },
        ],
      });

      expect(core.defaultFramingFor('.', entry: 'x.dart').device?.id, 'ipad');
    });

    test('a device this build never heard of drops out of the list', () {
      // The config is written against the flutterware the *project* pins, which
      // can run ahead of the GUI reading its manifest. Fewer devices, never a
      // panel that will not open.
      var core = coreWith({
        'canvases': [
          {
            'prefix': 'demo',
            'devices': ['iphone-99', 'iphone-16'],
          },
        ],
      });

      expect(
        core.defaultFramingFor('.', entry: 'demo/tile.dart').device?.id,
        'iphone-16',
      );
    });
  });

  group('precedence', () {
    var phone = deviceById('iphone-16')!;
    var tablet = deviceById('ipad')!;

    test('an undeclared package still gets the plain rectangle', () {
      var (deviceId, orientationId, viewport) = PreviewsCore.framingFor(
        const {},
      );
      expect(deviceId, isNull);
      expect(orientationId, isNull);
      expect(viewport.width, CaptureViewport.panel.width);
    });

    test('the declaration frames a call that names no device', () {
      var (deviceId, _, viewport) = PreviewsCore.framingFor(
        const {},
        fallback: (device: phone, orientation: null, keyboard: null),
      );
      expect(deviceId, 'iphone-16');
      // On the address as well as in the pixels: a picture framed as a phone
      // whose address says nothing is a picture nobody can ask for again.
      expect(viewport.width, CaptureViewport.of(phone).width);
    });

    test('a call that names a device wins', () {
      var (deviceId, _, viewport) = PreviewsCore.framingFor(
        const {'device': 'ipad'},
        fallback: (device: phone, orientation: null, keyboard: null),
      );
      expect(deviceId, 'ipad');
      expect(viewport.width, CaptureViewport.of(tablet).width);
    });

    test('`fit` is an answer, not an absence', () {
      // The one that would break if the fallback were applied to anything
      // falsy: `fit` is how a single call asks for the plain rectangle back,
      // so the default it is countermanding must not win.
      var (deviceId, _, viewport) = PreviewsCore.framingFor(
        const {'device': fitDeviceId},
        fallback: (device: phone, orientation: null, keyboard: null),
      );
      expect(deviceId, fitDeviceId);
      expect(viewport.width, CaptureViewport.panel.width);
    });

    test('a declared orientation turns the declared device', () {
      var (deviceId, orientationId, viewport) = PreviewsCore.framingFor(
        const {},
        fallback: (
          device: tablet,
          orientation: ScreenOrientation.landscape,
          keyboard: null,
        ),
      );
      expect(deviceId, 'ipad');
      expect(orientationId, 'landscape');
      expect(
        viewport.width,
        greaterThan(viewport.height),
        reason: 'the declared landscape never reached the viewport',
      );
    });

    test('it does not turn a device the call picked instead', () {
      // An orientation belongs to the device it was declared for. Inheriting
      // the tablet's landscape onto a phone somebody just asked for would be a
      // picture nobody chose.
      var (_, orientationId, viewport) = PreviewsCore.framingFor(
        const {'device': 'iphone-16'},
        fallback: (
          device: tablet,
          orientation: ScreenOrientation.landscape,
          keyboard: null,
        ),
      );
      expect(orientationId, isNull);
      expect(viewport.height, greaterThan(viewport.width));
    });

    test('width and height still override the declaration', () {
      var (deviceId, _, viewport) = PreviewsCore.framingFor(
        const {'width': 400, 'height': 800},
        fallback: (device: phone, orientation: null, keyboard: null),
      );
      expect(deviceId, 'iphone-16', reason: 'the device is still on record');
      expect(viewport.width, 400);
      expect(viewport.height, 800);
    });
  });

  group('the keyboard', () {
    var phone = deviceById('iphone-16')!;
    var window = deviceById('window')!;

    test('a device brings its own measured height', () {
      var (_, _, viewport) = PreviewsCore.framingFor(const {
        'device': 'iphone-16',
      });
      expect(viewport.keyboard, 335);
      // The mode is what a caller chooses; the height is not.
      expect(viewport.keyboardMode, KeyboardMode.auto);
    });

    test('and the turned device brings the turned one', () {
      var (_, _, viewport) = PreviewsCore.framingFor(const {
        'device': 'iphone-16',
        'orientation': 'landscape',
      });
      // 209, not 335: a phone's landscape keyboard is shorter, and this is the
      // number that says the rotation reached the measurement rather than only
      // the geometry.
      expect(viewport.keyboard, 209);
    });

    test('a window has none, so `up` raises nothing', () {
      var (_, _, viewport) = PreviewsCore.framingFor(const {
        'device': 'window',
        'keyboard': 'up',
      });
      expect(viewport.keyboard, 0);
      expect(window.keyboard, 0);
      // The mode still travels: the guest reports what was asked for rather
      // than pretending nobody asked.
      expect(viewport.keyboardMode, KeyboardMode.up);
    });

    test('a mode this build does not know is refused, not approximated', () {
      expect(
        () => PreviewsCore.framingFor(const {'keyboard': 'floating'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a declared keyboard applies to the declared device', () {
      var (_, _, viewport) = PreviewsCore.framingFor(
        const {},
        fallback: (device: phone, orientation: null, keyboard: KeyboardMode.up),
      );
      expect(viewport.keyboardMode, KeyboardMode.up);
    });

    test('and not to a device the call picked instead', () {
      var (_, _, viewport) = PreviewsCore.framingFor(
        const {'device': 'ipad'},
        fallback: (device: phone, orientation: null, keyboard: KeyboardMode.up),
      );
      expect(viewport.keyboardMode, KeyboardMode.auto);
    });

    test('it is part of what makes two pictures two pictures', () {
      var up = CaptureViewport.of(phone).withKeyboard(KeyboardMode.up);
      expect(up, isNot(CaptureViewport.of(phone)));
      expect(up.withKeyboard(KeyboardMode.auto), CaptureViewport.of(phone));
    });
  });
}
