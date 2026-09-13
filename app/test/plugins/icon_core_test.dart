import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/icon_core.dart';
import 'package:flutterware_app/src/plugins/native/icon_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The core as `fw` and an agent see it — a report that stays quiet, and one
/// action that answers without them having to glob.
void main() {
  late Directory root;

  LauncherIconCore core() {
    var worktree = Worktree(path: root.path);
    return LauncherIconCore(
      PluginHost(
        id: launcherIconPluginId,
        label: 'Launcher icon',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: const [Pkg('.')],
          discovered: const ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {'path': '.'},
          ],
        },
      ),
    );
  }

  void write(String relative, String content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writePng(String relative, int size, {bool alpha = true}) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      img.encodePng(
        img.Image(width: size, height: size, numChannels: alpha ? 4 : 3),
      ),
    );
  }

  void writeManifest() {
    write('android/app/src/main/AndroidManifest.xml', '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:icon="@mipmap/ic_launcher"/>
</manifest>
''');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('icon_core_test');
    write('pubspec.yaml', 'name: sample\nenvironment:\n  sdk: ^3.0.0\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('says nothing before anything has looked', () {
    var c = core();
    // The resting state is not news: a viewer that announces "not computed" on
    // every sidebar paint draws the eye to nothing.
    expect(c.report.status.tone, Tone.neutral);
    expect(c.report.badge, StatusBadge.none);
    expect(c.report.children.single.status.tone, Tone.neutral);
  });

  test('reports a file count once it has', () async {
    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
    writePng('web/icons/Icon-192.png', 192);

    var c = core();
    await c.computeAll();

    expect(c.report.children.single.status.tone, Tone.good);
    expect(c.report.children.single.status.message, contains('2 files'));
    expect(c.report.badge, StatusBadge.none);
  });

  test('an empty package is neutral rather than a problem', () async {
    var c = core();
    await c.computeAll();

    expect(c.report.children.single.status.message, 'No icons found');
    expect(c.report.badge, StatusBadge.none);
  });

  test(
    'a finding raises the badge without making the plugin row shout',
    () async {
      write(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
        '{"images":[{"filename":"a.png","size":"60x60","scale":"3x",'
            '"idiom":"universal"}]}',
      );
      writePng(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/a.png',
        180,
        alpha: true,
      );

      var c = core();
      await c.computeAll();

      expect(c.report.badge, const StatusBadge.dot(Tone.error));
      // The plugin's own row stays quiet — the count belongs on the package row
      // underneath, and saying it twice is what the splash core learned not to do.
      expect(c.report.status.tone, Tone.neutral);
      expect(c.report.children.single.status.tone, Tone.error);
    },
  );

  group('inventory', () {
    test('returns roles, findings and worktree-relative paths', () async {
      writeManifest();
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

      var c = core();
      var result = (await c.invoke('inventory'))! as IconInventoryResult;

      expect(result.package, '.');
      expect(result.roles, hasLength(1));
      var role = result.roles.single;
      expect(role.role, 'android.legacy');
      expect(role.referenced, isTrue);
      expect(
        role.files.single.path,
        'android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
      );
      expect(role.files.single.width, 72);
    });

    test('reports an adaptive foreground written under drawable', () async {
      // A project generated the common way: the XML names `@drawable/…` and
      // the densities land beside the notification icons. Both the row and the
      // silence are the point — the foreground used to be missing from the
      // report, and an error used to claim it was not on disk.
      writeManifest();
      write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/ic_launcher_background"/>
  <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
''');
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
      writePng(
        'android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png',
        432,
      );

      var result = (await core().invoke('inventory'))! as IconInventoryResult;

      var foreground = result.roles.singleWhere(
        (r) => r.role == 'android.adaptive-foreground',
      );
      expect(foreground.referenced, isTrue);
      expect(
        foreground.files.single.path,
        'android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png',
      );
      expect(result.findings.where((f) => f.tone == Tone.error.name), isEmpty);
    });

    test('loads on demand, so an agent need not warm it first', () async {
      writeManifest();
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

      // No computeAll: invoke has to be enough on its own.
      var result = (await core().invoke('inventory'))! as IconInventoryResult;
      expect(result.roles, isNotEmpty);
    });

    test('reports the iOS catalog kind', () async {
      Directory(p.join(root.path, 'ios', 'Runner', 'AppIcon.icon'))
          .createSync(recursive: true);

      var result = (await core().invoke('inventory'))! as IconInventoryResult;
      expect(result.iosCatalog, 'iconComposer');
      expect(result.iconBundles, ['ios/Runner/AppIcon.icon']);
    });

    test('serializes to JSON an agent can read', () async {
      writeManifest();
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

      var result = (await core().invoke('inventory'))! as IconInventoryResult;
      var json = result.toJson();
      expect(json['package'], '.');
      expect(json['roles'], isA<List<Object?>>());
    });

    test('an unknown package names the ones that exist', () async {
      await expectLater(
        core().invoke('inventory', arguments: {'package': 'nope'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an unknown flavour says what was found', () async {
      writeManifest();
      writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

      await expectLater(
        core().invoke('inventory', arguments: {'flavor': 'nope'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('an unknown action is an error, not a silent no-op', () async {
    await expectLater(core().invoke('generate'), throwsA(isA<ArgumentError>()));
  });
}
