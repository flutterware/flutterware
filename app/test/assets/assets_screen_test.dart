import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/assets/list.dart';
import 'package:flutterware_app/src/assets/screen.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/assets_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// The half the catalog demos cannot reach.
///
/// The views are pure and demoable; this is the wiring under them — the address
/// in, the file off disk, and the address back out. What it pins is the rule
/// that everything naming something goes through the address: selecting an
/// asset must *navigate*, not set a field, or the same selection would be
/// unreachable from a link, a search hit and eventually an artifact.
void main() {
  late Directory root;
  late ValueNotifier<Address> address;
  late List<Address> written;

  AssetsCore core() {
    var worktree = Worktree(path: root.path);
    return AssetsCore(
      PluginHost(
        id: assetsPluginId,
        label: 'Assets',
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

  void write(String relative, List<int> content) {
    var file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(content);
  }

  /// Lets the real world happen, then draws what came back.
  ///
  /// Two things here run outside the test's fake clock and cannot be pumped
  /// into existence: the scan (`Isolate.run`) and the screen's own
  /// `File.readAsBytes`. Inside `testWidgets` both futures simply never
  /// complete, so the widget sits on its spinner forever — and
  /// `pumpAndSettle` would then wait out its ten-minute timeout on an
  /// animation that is working exactly as designed. `runAsync` is the door out
  /// of the fake zone.
  /// Three rounds, because the work arrives in stages: the read lands, the
  /// frame it produces starts the *next* async step — a Lottie parse, a font
  /// load — and only the frame after that shows what it decided.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// [finder], but only where it is inside the list rather than in the pane
  /// beside it.
  Finder inList(Finder finder) =>
      find.descendant(of: find.byType(AssetListView), matching: finder);

  Future<void> pump(WidgetTester tester, AssetsCore plugin) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (next) {
              written.add(next);
              address.value = next;
            },
            child: AddressScope(child: AssetsScreen(plugin, package: '.')),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// Mounts the real panel rather than the bare screen, because reload is a
  /// round trip: the tap invalidates the core, and only the panel's own
  /// subscription rebuilds the screen when the new scan lands.
  Future<void> pumpPanel(WidgetTester tester, AssetsCore subject) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (next) {
              written.add(next);
              address.value = next;
            },
            child: AddressScope(
              child: Builder(builder: AssetsPlugin(subject).buildPanel),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_assets_screen_test');
    written = [];
    address = ValueNotifier(
      Address(worktree: 'test', plugin: assetsPluginId, segments: const ['.']),
    );

    write(
      '.dart_tool/package_config.json',
      '{"configVersion":2,"packages":[]}'.codeUnits,
    );
    write(
      'pubspec.yaml',
      '''
name: app
flutter:
  assets:
    - assets/logo.png
    - assets/notes.txt
'''
          .codeUnits,
    );
    write('assets/logo.png', _png);
    write('assets/notes.txt', 'hello'.codeUnits);
  });

  tearDown(() {
    address.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets('selecting an asset navigates rather than setting a field', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    await pump(tester, plugin);

    // Scoped to the list: with nothing selected the pane beside it is the
    // whole bundle's contact sheet, so the name is legitimately on screen
    // twice and only one of them is the row.
    await tester.tap(inList(find.text('logo.png')));
    await settle(tester);

    expect(
      '${written.single}',
      'fw:///worktrees/test/flutterware.assets/./assets/logo.png',
    );
    // And the pane followed the address rather than a local selection. More
    // than once: the detail names the key as its title and again as the file
    // it resolved to.
    expect(find.text('assets/logo.png'), findsWidgets);
  });

  testWidgets('an address opens straight onto its asset', (tester) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    address.value = Address(
      worktree: 'test',
      plugin: assetsPluginId,
      segments: const ['.', 'assets', 'notes.txt'],
    );

    await pump(tester, plugin);

    expect(find.text('assets/notes.txt'), findsWidgets);
    // That the pane opened on the addressed asset, not what it drew inside it:
    // the read starts in `didChangeDependencies`, which runs in the fake zone,
    // and a `File.readAsBytes` begun there never completes however much real
    // time `runAsync` grants afterwards. What the preview makes of the bytes is
    // asserted in `asset_views_test.dart`, where the bytes are handed over
    // directly.
    expect(find.text('Where it comes from'), findsOneWidget);
  });

  testWidgets('with nothing selected the panel opens on the whole bundle', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);

    // The address the rail leaves you on: the package, and no key.
    await pump(tester, plugin);

    expect(
      find.textContaining('assets ·'),
      findsOneWidget,
      reason:
          'A contact sheet of what is there beats a pane telling you to go '
          'and pick something.',
    );
  });

  testWidgets('an address that names a directory opens the folder', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    address.value = Address(
      worktree: 'test',
      plugin: assetsPluginId,
      segments: const ['.', 'assets'],
    );

    await pump(tester, plugin);

    // The same grammar as an asset, one segment shorter — which is why the
    // address needed nothing added to carry a folder.
    expect(
      find.text('assets'),
      findsWidgets,
      reason: 'The folder is the heading of the pane, not an empty state.',
    );
    expect(
      find.textContaining('assets ·'),
      findsOneWidget,
      reason: 'What is in it, counted and weighed.',
    );
  });

  testWidgets('a folder tile navigates, like every other selection', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    address.value = Address(
      worktree: 'test',
      plugin: assetsPluginId,
      segments: const ['.', 'assets'],
    );

    await pump(tester, plugin);
    await tester.tap(find.text('notes.txt').last);
    await tester.pump();

    expect(
      written.last.segments,
      ['.', 'assets', 'notes.txt'],
      reason:
          'A tile is a selection, so it writes an address like the list does '
          'rather than setting a field only this pane can see.',
    );
  });

  testWidgets('the backdrop is in the address, so a preview is citable', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    address.value = Address(
      worktree: 'test',
      plugin: assetsPluginId,
      segments: const ['.', 'assets', 'logo.png'],
    );
    await pump(tester, plugin);

    await tester.tap(find.text('Dark'));
    await settle(tester);

    expect(
      '${written.last}',
      'fw:///worktrees/test/flutterware.assets/./assets/logo.png?bg=dark',
    );
  });

  testWidgets('a file that vanished under us is reported, not blank', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    File(p.join(root.path, 'assets', 'logo.png')).deleteSync();

    address.value = Address(
      worktree: 'test',
      plugin: assetsPluginId,
      segments: const ['.', 'assets', 'logo.png'],
    );
    await pump(tester, plugin);

    expect(find.textContaining('Could not read this file'), findsOneWidget);
  });

  testWidgets('the refresh button picks up an asset added after the scan', (
    tester,
  ) async {
    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    await pumpPanel(tester, plugin);
    expect(inList(find.text('logo.png')), findsOneWidget);

    // A designer drops a file in and declares it — outside this process, so
    // nothing tells the panel.
    write('assets/banner.png', _png);
    write(
      'pubspec.yaml',
      '''
name: app
flutter:
  assets:
    - assets/logo.png
    - assets/notes.txt
    - assets/banner.png
'''
          .codeUnits,
    );
    await tester.pump();
    expect(find.text('banner.png'), findsNothing);

    await tester.tap(find.byTooltip('Read the assets again'));
    await settle(tester);
    expect(find.text('banner.png'), findsOneWidget);
  });

  testWidgets('a scan failure offers a retry, and the retry recovers', (
    tester,
  ) async {
    // The classic first-run failure: no resolution yet.
    File(p.join(root.path, '.dart_tool', 'package_config.json')).deleteSync();

    var plugin = core();
    await tester.runAsync(plugin.computeAll);
    await pumpPanel(tester, plugin);
    expect(find.text('Could not read the assets'), findsOneWidget);
    expect(find.textContaining('flutter pub get'), findsOneWidget);

    // The user runs pub get, as the message told them to.
    write(
      '.dart_tool/package_config.json',
      '{"configVersion":2,"packages":[]}'.codeUnits,
    );
    await tester.tap(find.text('Try again'));
    await settle(tester);

    expect(find.text('Could not read the assets'), findsNothing);
    expect(inList(find.text('logo.png')), findsOneWidget);
  });
}

/// A 1×1 PNG — the screen only needs bytes that decode.
const _png = [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];
