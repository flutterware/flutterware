import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/launcher_icon/screen.dart';
import 'package:flutterware_app/src/launcher_icon/model/role.dart';
import 'package:flutterware_app/src/launcher_icon/ui/detail.dart';
import 'package:flutterware_app/src/launcher_icon/ui/plate.dart';
import 'package:flutterware_app/src/plugins/native/icon_core.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The panel, mounted for real.
///
/// The render tests cover the geometry in isolation; this covers the thing the
/// user actually looks at — every role side by side, each captioned with what
/// the OS does to it. The captions are the half that makes the pictures
/// actionable, so they are asserted rather than assumed.
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

  Future<LauncherIconCore> mount(WidgetTester tester) async {
    var c = core();
    await c.computeAll();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: LauncherIconScreen(c, package: '.')),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('launcher_icon_screen_test');
    write('pubspec.yaml', 'name: sample\nenvironment:\n  sdk: ^3.0.0\n');
  });

  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('says so plainly when there is nothing to show', (tester) async {
    await mount(tester);
    expect(find.textContaining('No launcher icons found'), findsOneWidget);
  });

  testWidgets('draws a tile per role, grouped by platform', (tester) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
    writePng('web/icons/Icon-192.png', 192);
    writePng('web/icons/Icon-maskable-192.png', 192);

    await mount(tester);

    expect(find.byType(IconPlate), findsNWidgets(3));
    expect(find.text('Android'), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('Maskable icon'), findsOneWidget);
  });

  testWidgets('captions a notification icon with what Android does to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/drawable-xhdpi/ic_notification.png', 48);

    await mount(tester);

    // The picture alone says "white blob"; this is the line that says why.
    expect(
      find.text('The status bar keeps the alpha channel and nothing else.'),
      findsOneWidget,
    );
    expect(find.text('Android 5 (API 21)'), findsOneWidget);
  });

  testWidgets('the launcher picker is offered only where a launcher picks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Web only: nothing here is masked by a launcher, so there is no choice to
    // offer and the stage must not pretend there is.
    writePng('web/icons/Icon-192.png', 192);
    await mount(tester);
    await tester.tap(find.text('Web icon').first);
    await tester.pumpAndSettle();
    expect(find.text('Squircle'), findsNothing);

    write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@mipmap/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
    writeManifest();
    for (var name in ['ic_launcher_foreground', 'ic_launcher_background']) {
      writePng('android/app/src/main/res/mipmap-hdpi/$name.png', 162);
    }

    await mount(tester);
    await tester.tap(find.text('Adaptive foreground').first);
    await tester.pumpAndSettle();
    for (var label in ['Squircle', 'Circle', 'Teardrop']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a finding sits on the plate it is about', (tester) async {
    tester.view.physicalSize = const Size(2600, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

    await mount(tester);

    // On the card, not in a list at the bottom and not behind a dot that has
    // to be clicked — the whole complaint about the first cut.
    expect(find.textContaining('alpha channel'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(IconPlate),
        matching: find.textContaining('alpha channel'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a plate compares the source against every launcher shape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@mipmap/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
    writeManifest();
    for (var name in ['ic_launcher_foreground', 'ic_launcher_background']) {
      writePng('android/app/src/main/res/mipmap-hdpi/$name.png', 162);
    }

    await mount(tester);

    // Every shape at once, on the card, without selecting anything: seeing what
    // a mask removes is the content, not a detail behind a click.
    expect(find.text('as authored'), findsWidgets);
    for (var mask in AdaptiveMask.values) {
      expect(
        find.text(mask.label.toLowerCase()),
        findsWidgets,
        reason: mask.label,
      );
    }
  });

  testWidgets('opening a role shows it where it is seen', (tester) async {
    tester.view.physicalSize = const Size(2600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

    await mount(tester);
    expect(find.byType(IconDetail), findsNothing);
    expect(find.text('Pick an icon'), findsOneWidget);

    await tester.tap(find.text('Launcher icon').first);
    await tester.pumpAndSettle();

    expect(find.byType(IconDetail), findsOneWidget);
    expect(find.text('On the launcher'), findsOneWidget);
  });

  testWidgets('a role opens straight from the address', (tester) async {
    tester.view.physicalSize = const Size(2400, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

    var c = core();
    await c.computeAll();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: LauncherIconScreen(
            c,
            package: '.',
            role: IconRole.androidLegacy,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A finding that names a role has to open on that role, or its address is
    // decoration.
    expect(find.byType(IconDetail), findsOneWidget);
  });

  testWidgets('reload picks up a file written after the scan', (tester) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);

    var c = await mount(tester);
    expect(find.text('1 file'), findsOneWidget);

    // What running a generator in another terminal looks like from in here.
    writePng('web/icons/Icon-192.png', 192);
    await tester.pumpAndSettle();
    expect(find.text('1 file'), findsOneWidget, reason: 'still cached');

    await tester.tap(find.byTooltip('Read the icons again'));
    // Bounded pumps rather than pumpAndSettle: the reload spinner is an
    // indeterminate animation, so there is never a frame with nothing
    // scheduled and settling would wait forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(c.scanFor('.')!.fileCount, 2);
    expect(find.text('2 files'), findsOneWidget);
  });

  testWidgets("an icon-set chip goes to that set's files", (tester) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
    writePng('android/app/src/kiosk/res/mipmap-hdpi/ic_launcher.png', 72);

    var address = ValueNotifier(
      Address(
        worktree: 'test',
        plugin: launcherIconPluginId,
        segments: const ['.'],
        axes: const {'role': 'android-legacy'},
      ),
    );
    addTearDown(address.dispose);
    var written = <Address>[];

    var c = core();
    await c.computeAll();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (next) {
              written.add(next);
              address.value = next;
            },
            child: AddressScope(child: LauncherIconScreen(c, package: '.')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('kiosk'));
    await tester.pumpAndSettle();

    // The flavor is a segment: it names a different set of files, and the role
    // it was opened on belongs to the set it came from.
    expect(written.single.segments, ['.', 'kiosk']);
    expect(written.single.axes.containsKey('role'), isFalse);
  });

  testWidgets('a flavor says which of its icons it does not override', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
    writePng('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', 192);
    writePng('android/app/src/dev/res/mipmap-xxxhdpi/ic_launcher.png', 192);

    var c = core();
    await c.reload('.', flavor: 'dev');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: LauncherIconScreen(c, package: '.', flavor: 'dev'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The count is the merge Gradle would do; the qualifier is the half that
    // keeps it from reading as art this flavor owns.
    expect(find.textContaining('2 densities · 1 not overridden'), findsOne);

    await tester.tap(find.text('Launcher icon').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Not overridden by dev'), findsNothing);
  });

  testWidgets('a flavor that overrides nothing says so on the role', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    writeManifest();
    writePng('android/app/src/main/res/mipmap-hdpi/ic_launcher.png', 72);
    write('flutter_launcher_icons-dev.yaml', 'flutter_launcher_icons:\n');

    var c = core();
    await c.reload('.', flavor: 'dev');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: LauncherIconScreen(c, package: '.', flavor: 'dev'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('not overridden'), findsOne);

    await tester.tap(find.text('Launcher icon').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Not overridden by dev'), findsOne);
  });

  testWidgets('an Icon Composer project is explained, not reported empty', (
    tester,
  ) async {
    Directory(p.join(root.path, 'ios', 'Runner', 'AppIcon.icon'))
        .createSync(recursive: true);
    writePng('web/icons/Icon-192.png', 192);

    await mount(tester);

    expect(find.textContaining('Icon Composer'), findsOneWidget);
    expect(find.textContaining('No launcher icons found'), findsNothing);
  });
}
