import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/launcher_icon/model/role.dart';
import 'package:flutterware_app/src/launcher_icon/model/scan.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Discovery, and the findings that come out of it.
///
/// The fixtures are written as a project would look, not as any one generator
/// writes them — the point of the scan is that it reads the same whoever put
/// the files there, and a fixture shaped like `icons_launcher`'s output would
/// not prove that.
void main() {
  late Directory root;

  String path(String relative) => p.join(root.path, relative);

  void write(String relative, String content) {
    var file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writePng(String relative, int size, {bool alpha = true}) {
    var file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      img.encodePng(
        img.Image(width: size, height: size, numChannels: alpha ? 4 : 3),
      ),
    );
  }

  /// The adaptive icon XML, with the layers named.
  void writeAdaptive({
    String? background = '@mipmap/ic_launcher_background',
    String? foreground = '@mipmap/ic_launcher_foreground',
    String? monochrome,
  }) {
    write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
${background == null ? '' : '  <background android:drawable="$background"/>'}
${foreground == null ? '' : '  <foreground android:drawable="$foreground"/>'}
${monochrome == null ? '' : '  <monochrome android:drawable="$monochrome"/>'}
</adaptive-icon>
''');
  }

  void writeManifest({String icon = '@mipmap/ic_launcher', String? roundIcon}) {
    write('android/app/src/main/AndroidManifest.xml', '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="sample"
        android:icon="$icon"
        ${roundIcon == null ? '' : 'android:roundIcon="$roundIcon"'}>
        <activity android:name=".MainActivity" android:icon="@mipmap/other"/>
    </application>
</manifest>
''');
  }

  IconScan scan({String? flavor}) =>
      scanIcons(packageRoot: root.path, packagePath: '.', flavor: flavor);

  setUp(() {
    root = Directory.systemTemp.createTempSync('launcher_icon_scan_test');
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('android discovery', () {
    test('classifies the launcher bitmap across densities', () {
      writeManifest();
      for (var (dir, size) in [
        ('mipmap-mdpi', 48),
        ('mipmap-hdpi', 72),
        ('mipmap-xxxhdpi', 192),
      ]) {
        writePng('android/app/src/main/res/$dir/ic_launcher.png', size);
      }

      var legacy = scan().forRole(IconRole.androidLegacy)!;
      expect(legacy.files, hasLength(3));
      expect(legacy.referenced, isTrue);
      // Sorted smallest first, so the largest is the one worth drawing.
      expect(legacy.largest!.width, 192);
      expect(legacy.files.first.density, 'mdpi');
    });

    test('follows the manifest rather than the naming convention', () {
      // A project that never ran a generator and named its icon itself.
      writeManifest(icon: '@mipmap/brand_mark');
      writePng('android/app/src/main/res/mipmap-hdpi/brand_mark.png', 72);

      var legacy = scan().forRole(IconRole.androidLegacy)!;
      expect(legacy.files, hasLength(1));
      expect(legacy.files.single.name, 'brand_mark');
    });

    test('reads android:icon from <application>, not from an <activity>', () {
      // The manifest fixture gives the activity `@mipmap/other`. Matching any
      // line carrying the attribute — which is what the generators do — would
      // classify `other.png` as the launcher icon.
      writeManifest(icon: '@mipmap/ic_launcher');
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
      writePng('android/app/src/main/res/mipmap-hdpi/other.png', 72);

      var result = scan();
      expect(result.android!.manifestIcon, '@mipmap/ic_launcher');
      expect(
        result.forRole(IconRole.androidLegacy)!.files.single.name,
        'ic_launcher',
      );
    });

    test('separates adaptive layers and reads a colour background', () {
      writeManifest();
      writeAdaptive(background: '@color/ic_launcher_background');
      write('android/app/src/main/res/values/colors.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <color name="ic_launcher_background">#FF102030</color>
</resources>
''');
      writePng(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png',
        162,
      );

      var result = scan();
      expect(
        result.forRole(IconRole.androidAdaptiveForeground)!.files,
        hasLength(1),
      );
      var background = result.forRole(IconRole.androidAdaptiveBackground)!;
      expect(background.files, isEmpty);
      expect(background.color, '#FF102030');
    });

    test('classifies an adaptive foreground written under drawable', () {
      // What `flutter_launcher_icons` writes by default: the XML points at
      // `@drawable/…` and the densities land in `drawable-<dpi>/`. Classifying
      // by name under `mipmap*` alone found none of them, and then said the
      // XML pointed at an image that was not on disk — five times over.
      writeManifest();
      writeAdaptive(
        background: '@color/ic_launcher_background',
        foreground: '@drawable/ic_launcher_foreground',
      );
      for (var dpi in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        writePng(
          'android/app/src/main/res/drawable-$dpi/ic_launcher_foreground.png',
          162,
        );
      }

      var result = scan();
      var foreground = result.forRole(IconRole.androidAdaptiveForeground)!;
      expect(foreground.files, hasLength(5));
      expect(foreground.referenced, isTrue);
      expect(result.findings.where((f) => f.tone == Tone.error), isEmpty);
    });

    test('a reference resolves by the type it names, not by name alone', () {
      // The name matches and the file is real, but `@mipmap/…` does not reach
      // into `drawable-hdpi/`. Both halves of that are worth saying: nothing
      // points at the file, and the resource the XML names is missing.
      writeManifest();
      writeAdaptive(
        background: '@color/ic_launcher_background',
        foreground: '@mipmap/ic_launcher_foreground',
      );
      writePng(
        'android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png',
        162,
      );

      var result = scan();
      expect(
        result.forRole(IconRole.androidAdaptiveForeground)!.referenced,
        isFalse,
      );
      expect(
        result.findings.where((f) => f.tone == Tone.error).single.message,
        contains('@mipmap/ic_launcher_foreground'),
      );
    });

    test('finds notification icons in drawable folders', () {
      writeManifest();
      writePng(
        'android/app/src/main/res/drawable-xhdpi/ic_notification.png',
        48,
      );
      writePng('android/app/src/main/res/drawable-xhdpi/launch_image.png', 48);

      var notification = scan().forRole(IconRole.androidNotification)!;
      expect(notification.files, hasLength(1));
      expect(notification.files.single.name, 'ic_notification');
    });

    test('lists flavour source sets and scans the one asked for', () {
      writeManifest();
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
      writePng('android/app/src/dev/res/mipmap-hdpi/ic_launcher.png', 144);
      Directory(path('android/app/src/debug')).createSync(recursive: true);

      expect(scan().flavors.map((f) => f.name), ['dev']);
      expect(
        scan(flavor: 'dev').forRole(IconRole.androidLegacy)!.largest!.width,
        144,
      );
    });
  });

  group('android findings', () {
    test('a themed icon with no <monochrome> layer is reported', () {
      writeManifest();
      writeAdaptive();
      writePng(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png',
        162,
      );
      writePng(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher_background.png',
        162,
      );
      writePng(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher_monochrome.png',
        162,
      );

      var findings = scan().findings;
      expect(
        findings.where((f) => f.role == IconRole.androidMonochrome),
        hasLength(1),
      );
      expect(
        findings
            .firstWhere((f) => f.role == IconRole.androidMonochrome)
            .message,
        contains('<monochrome>'),
      );
    });

    test('no finding once the layer is declared', () {
      writeManifest();
      writeAdaptive(monochrome: '@mipmap/ic_launcher_monochrome');
      for (var name in [
        'ic_launcher_foreground',
        'ic_launcher_background',
        'ic_launcher_monochrome',
      ]) {
        writePng('android/app/src/main/res/mipmap-hdpi/$name.png', 162);
      }

      expect(
        scan().findings.where((f) => f.role == IconRole.androidMonochrome),
        isEmpty,
      );
    });

    test('a referenced layer with no file on disk is an error', () {
      writeManifest();
      writeAdaptive();
      writePng(
        'android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png',
        162,
      );

      var errors = scan().findings.where((f) => f.tone == Tone.error);
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('ic_launcher_background'));
    });

    test('a layer answered by a vector drawable is wired, not broken', () {
      // The foreground is a `<vector>`, so no PNG carries that name anywhere.
      // Reporting it missing is wrong twice over: the resource is on disk, and
      // Android draws it perfectly.
      writeManifest();
      writeAdaptive(
        background: '@color/ic_launcher_background',
        foreground: '@drawable/ic_launcher_foreground',
      );
      write('android/app/src/main/res/drawable/ic_launcher_foreground.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
  <path android:fillColor="#FF000000" android:pathData="M0,0h108v108h-108z"/>
</vector>
''');

      var findings = scan().findings;
      expect(findings.where((f) => f.tone == Tone.error), isEmpty);
      expect(
        findings.singleWhere((f) => f.tone == Tone.info).message,
        allOf(
          contains('@drawable/ic_launcher_foreground'),
          contains('drawable/ic_launcher_foreground.xml'),
        ),
      );
    });

    test('a vector under the other resource type is still missing', () {
      // Type-aware to the end: `@mipmap/…` does not reach a `drawable/` vector
      // any more than it reaches a `drawable/` PNG.
      writeManifest();
      writeAdaptive(
        background: '@color/ic_launcher_background',
        foreground: '@mipmap/ic_launcher_foreground',
      );
      write(
        'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
        '<vector/>',
      );

      expect(
        scan().findings.where((f) => f.tone == Tone.error).single.message,
        contains('no such image is on disk'),
      );
    });

    test('stays quiet when the wiring could not be read', () {
      // No manifest and no adaptive XML: everything would look unreferenced,
      // and saying so about every file would be crying wolf.
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

      expect(scan().findings, isEmpty);
      expect(scan().forRole(IconRole.androidLegacy)!.referenced, isNull);
    });
  });

  group('apple', () {
    /// One `Contents.json` image entry, as Xcode writes them.
    String entry(
      String filename, {
      String size = '60x60',
      String scale = '3x',
      String idiom = 'universal',
      String? appearance,
    }) {
      var appearances = appearance == null
          ? ''
          : ',"appearances":[{"appearance":"luminosity","value":"$appearance"}]';
      return '{"filename":"$filename","size":"$size","scale":"$scale",'
          '"idiom":"$idiom"$appearances}';
    }

    void writeCatalog(String platform, {required List<String> entries}) {
      write(
        '$platform/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
        '{"images":[${entries.join(',')}],"info":{"version":1}}',
      );
    }

    test('reads dark and tinted from Contents.json, not from filenames', () {
      writeCatalog(
        'ios',
        entries: [
          entry('a.png'),
          entry('b.png', appearance: 'dark'),
          entry('c.png', appearance: 'tinted'),
        ],
      );
      for (var name in ['a', 'b', 'c']) {
        writePng(
          'ios/Runner/Assets.xcassets/AppIcon.appiconset/$name.png',
          180,
          alpha: false,
        );
      }

      var result = scan();
      expect(result.forRole(IconRole.iosApp)!.files.single.name, 'a');
      expect(result.forRole(IconRole.iosDark)!.files.single.name, 'b');
      expect(result.forRole(IconRole.iosTinted)!.files.single.name, 'c');
      expect(result.ios, IosCatalog.appIconSet);
    });

    test('an alpha channel on an iOS icon is an error', () {
      writeCatalog('ios', entries: [entry('a.png')]);
      writePng(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/a.png',
        180,
        alpha: true,
      );

      var errors = scan().findings.where((f) => f.tone == Tone.error);
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('alpha channel'));
    });

    test('a declared size the file does not match is reported', () {
      writeCatalog(
        'ios',
        entries: [entry('a.png', size: '1024x1024', scale: '1x')],
      );
      writePng(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/a.png',
        512,
        alpha: false,
      );

      expect(
        scan().findings.map((f) => f.message),
        contains(allOf(contains('512×512'), contains('1024'))),
      );
    });

    test('an Icon Composer bundle counts as configured iOS icons', () {
      Directory(path('ios/Runner/AppIcon.icon')).createSync(recursive: true);

      var result = scan();
      expect(result.ios, IosCatalog.iconComposer);
      expect(result.iconBundles, ['ios/Runner/AppIcon.icon']);
      // The point of the three-state enum: no per-size PNGs is correct here,
      // and must not read as "no iOS icons".
      expect(result.forRole(IconRole.iosApp)!.files, isEmpty);
    });

    test('a bundle beside a classic catalog is ambiguous', () {
      Directory(path('ios/Runner/AppIcon.icon')).createSync(recursive: true);
      writeCatalog('ios', entries: [entry('a.png')]);
      writePng(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/a.png',
        180,
        alpha: false,
      );

      var result = scan();
      expect(result.ios, IosCatalog.both);
      expect(
        result.findings.map((f) => f.message),
        contains(contains('Icon Composer')),
      );
    });

    test('one file backing several entries is counted once', () {
      // 20x20@2x and 40x40@1x are the same 40px square, and Xcode lists both.
      // Counting per entry inflates every file count and, worse, makes a
      // finding say "3 icons carry an alpha channel" about one file.
      writeCatalog(
        'ios',
        entries: [
          entry('shared.png', size: '20x20', scale: '2x'),
          entry('shared.png', size: '40x40', scale: '1x'),
          entry('other.png', size: '60x60', scale: '3x'),
        ],
      );
      for (var name in ['shared', 'other']) {
        writePng(
          'ios/Runner/Assets.xcassets/AppIcon.appiconset/$name.png',
          40,
          alpha: false,
        );
      }

      expect(scan().forRole(IconRole.iosApp)!.files, hasLength(2));
    });

    test('macOS reads its own catalog', () {
      writeCatalog(
        'macos',
        entries: [
          entry('app_icon_512.png', size: '256x256', scale: '2x', idiom: 'mac'),
        ],
      );
      writePng(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png',
        512,
      );

      expect(scan().forRole(IconRole.macosApp)!.files, hasLength(1));
    });
  });

  group('web and desktop', () {
    test('separates maskable icons from plain ones', () {
      writePng('web/icons/Icon-192.png', 192);
      writePng('web/icons/Icon-maskable-512.png', 512);
      writePng('web/favicon.png', 48);

      var result = scan();
      expect(result.forRole(IconRole.webIcon)!.files, hasLength(1));
      expect(result.forRole(IconRole.webMaskable)!.files, hasLength(1));
      expect(result.forRole(IconRole.webFavicon)!.files, hasLength(1));
    });

    test('enumerates the frames an .ico packs', () {
      var file = File(path('windows/runner/resources/app_icon.ico'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        img.encodeIco(img.Image(width: 64, height: 64, numChannels: 4)),
      );

      var windows = scan().forRole(IconRole.windowsIco)!;
      expect(windows.files, hasLength(1));
      expect(windows.files.single.icoFrames, isNotEmpty);
    });
  });

  group('file facts', () {
    test('alpha comes from the PNG colour type', () {
      writePng('web/icons/opaque.png', 32, alpha: false);
      writePng('web/icons/transparent.png', 32, alpha: true);

      var files = {
        for (var file in scan().forRole(IconRole.webIcon)!.files)
          file.name: file,
      };
      expect(files['opaque']!.hasAlpha, isFalse);
      expect(files['transparent']!.hasAlpha, isTrue);
      expect(files['opaque']!.width, 32);
    });
  });

  group('the sample project', () {
    /// The sample's root, or null when it is not checked out beside us.
    String? sampleRoot() {
      var example = p.normalize(
        p.join(Directory.current.path, '..', 'fixtures', 'probe_app'),
      );
      return Directory(example).existsSync() ? example : null;
    }

    test('reads its real icon tree', () {
      // Ground truth: a project nobody wrote fixtures for. Loose assertions on
      // purpose — this guards discovery against a real tree, and should not
      // fail when someone regenerates the sample's icons.
      var example = p.normalize(
        p.join(Directory.current.path, '..', 'fixtures', 'probe_app'),
      );
      if (!Directory(example).existsSync()) {
        markTestSkipped('sample project not present');
        return;
      }

      var result = scanIcons(
        packageRoot: example,
        packagePath: 'fixtures/probe_app',
      );

      expect(result.isEmpty, isFalse);
      expect(
        result.platforms,
        containsAll([
          IconPlatform.android,
          IconPlatform.ios,
          IconPlatform.macos,
          IconPlatform.web,
        ]),
      );
      expect(result.forRole(IconRole.androidLegacy)!.files, isNotEmpty);
      expect(result.forRole(IconRole.iosApp)!.files, isNotEmpty);
      expect(result.forRole(IconRole.webMaskable)!.files, isNotEmpty);
    });

    /// Tight, unlike the read above, because these *are* fixtures: the sample
    /// carries one icon set per shape this scan has to get right, and
    /// `fixtures/probe_app/README.md` says which is which. A change here is a
    /// change to the sample, and the two are meant to be edited together.
    group('its icon sets', () {
      IconScan? sample({String? flavor}) {
        var root = sampleRoot();
        if (root == null) return null;
        return scanIcons(
          packageRoot: root,
          packagePath: 'fixtures/probe_app',
          flavor: flavor,
        );
      }

      test('are discovered from all three kinds of evidence', () {
        var scanned = sample();
        if (scanned == null) return markTestSkipped('sample not present');

        expect(
          {for (var set in scanned.flavors) set.name: set.sources},
          {
            'beta': {IconFlavorSource.config},
            'kiosk': {IconFlavorSource.androidSourceSet},
            'partner': {IconFlavorSource.iosCatalog},
            'pro': {
              IconFlavorSource.androidSourceSet,
              IconFlavorSource.iosCatalog,
            },
          },
          reason: 'the product flavors free/proMonthly/proYearly are not sets',
        );
        expect(
          scanned.flavors.singleWhere((f) => f.name == 'beta').isUnbuilt,
          isTrue,
        );
      });

      test('beta has nothing of its own, and shows main’s', () {
        var scanned = sample(flavor: 'beta');
        if (scanned == null) return markTestSkipped('sample not present');

        expect(scanned.forRole(IconRole.androidLegacy)!.allInherited, isTrue);
        expect(scanned.forRole(IconRole.iosApp)!.allInherited, isTrue);
      });

      test('kiosk overrides one density and inherits the rest', () {
        var scanned = sample(flavor: 'kiosk');
        if (scanned == null) return markTestSkipped('sample not present');

        var legacy = scanned.forRole(IconRole.androidLegacy)!;
        expect(legacy.files.where((f) => !f.inherited).map((f) => f.density), [
          'xxxhdpi',
        ]);
        expect(legacy.files.length, greaterThan(1));
        // Both come from main, because kiosk declares neither — the
        // background is the shop's brown, main's `values/colors.xml`.
        expect(scanned.android!.launcher!.path, contains('src/main/'));
        expect(scanned.android!.backgroundColor, '#FF6F4E37');
      });

      test('partner is iOS only, and Android is main’s whole', () {
        var scanned = sample(flavor: 'partner');
        if (scanned == null) return markTestSkipped('sample not present');

        expect(scanned.forRole(IconRole.iosApp)!.allInherited, isFalse);
        expect(
          scanned.forRole(IconRole.iosApp)!.largest!.path,
          contains('AppIcon-partner.appiconset'),
        );
        expect(scanned.forRole(IconRole.androidLegacy)!.allInherited, isTrue);
      });

      test('pro forks both platforms, and drops the themed layer doing it', () {
        var scanned = sample(flavor: 'pro');
        if (scanned == null) return markTestSkipped('sample not present');

        expect(scanned.forRole(IconRole.androidLegacy)!.allInherited, isFalse);
        expect(scanned.forRole(IconRole.iosApp)!.allInherited, isFalse);
        expect(scanned.android!.backgroundColor, '#FF1B5E20');

        // main's monochrome PNGs are still merged in — and pro's own adaptive
        // XML no longer points at them, which is the whole fixture.
        expect(scanned.forRole(IconRole.androidMonochrome)!.allInherited, true);
        expect(scanned.android!.launcher!.hasMonochrome, isFalse);
        expect(
          scanned.findings.map((f) => f.message),
          contains(allOf(contains('<monochrome>'), contains('src/pro/'))),
        );
      });
    });
  });
}
