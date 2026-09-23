import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/semantics.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/inspect/node_highlight.dart';
import 'package:flutterware_app/src/plugins/native/run_address.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/run/device_strip.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/inspect.dart';
import 'package:flutterware_app/src/run/inventory.dart';
import 'package:flutterware_app/src/run/launch.dart';
import 'package:flutterware_app/src/run/logs_tab.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/picker.dart';
import 'package:flutterware_app/src/ui/split_button.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/daemon/device.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// The Screen tab, mounted for real against a fake reading.
///
/// This exists because a `capture` did not catch the bug it guards. The
/// pane reads on mount and tells the page above it so the strip can show a
/// spinner — a `setState` on an *ancestor*, from inside `initState`. Debug
/// throws there and the read never started; release compiles the assertion out
/// and it worked. `capture` builds the GUI in release, so the screenshot that
/// reviewed the change showed a tree that a real debug session never drew.
void main() {
  late Directory runDir;
  late Directory worktree;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-run-panel-');
    worktree = Directory.systemTemp.createTempSync('fw-run-panel-wt-');
    RunCore.runDirProvider = () => runDir.path;
    RunCore.debugLive = false;
  });

  tearDown(() {
    RunCore.runDirProvider = flutterwareRunDir;
    RunCore.debugLive = true;
    for (var dir in [runDir, worktree]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// Mounts the panel on the Screen tab against one fake reading.
  ///
  /// Answers with the core and the handle, so a test can go on doing things
  /// to the run the pane is watching.
  Future<(RunCore, RunHandle)> pumpScreenTab(
    WidgetTester tester,
    Uint8List? image, {
    InspectTree? tree,
    Map<String, Object?>? semantics,
    bool guest = false,
  }) async {
    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {},
      ),
    );
    addTearDown(core.dispose);

    var handle = RunHandle(
      worktree: worktree.path,
      // The host's own name, or the run reads as another checkout's and the
      // header says `held by …` instead of offering reload.
      worktreeName: Worktree(path: worktree.path).name,
      device: 'macos',
      deviceName: 'macOS',
      entrypoint: 'lib/main.dart',
      entrypointName: 'App',
      launcherPid: pid,
      vmService: 'ws://127.0.0.1:1/x=/ws',
      startedAt: DateTime.now(),
    ).publish(runDir.path);

    // Real file and socket work, so it cannot run inside `testWidgets`' fake
    // async zone — the future would simply never complete.
    await tester.runAsync(core.computeAll);
    core.debugSetProbe(handle, const RunProbe(app: true, launcher: true));
    core.debugRead = (_) async => InspectRead(
      tree:
          tree ??
          InspectTree(
            entryId: null,
            root: const InspectNode(
              id: '',
              type: 'MyApp',
              createdByLocalProject: true,
            ),
          ),
      fromGuest: tree != null || guest,
      image: image,
      semantics: semantics == null
          ? null
          : InspectSemantics(entryId: null, root: semantics),
    );

    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: [handle.key, 'screen'],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        // As the shell mounts it: `shell_view.dart` puts the panel inside a
        // Scaffold, and the log tab's search box is a TextField, which asserts
        // without a Material over it.
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (a) => address.value = a,
            child: Builder(builder: RunPlugin(core).buildPanel),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The decode is real engine work and the pumps above run in fake async, so
    // it needs a real moment to land. The pane holds the reading open until it
    // does — which is the point: the picture and the caption describing it
    // arrive in one build, never the caption first.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    return (core, handle);
  }

  group('the Semantics tab', () {
    /// One button with nothing to say, which is a finding — so the badge, the
    /// script and the audit are all exercised by the smallest tree there is.
    ///
    /// In the guest's own wire shape rather than as a `SemanticsSnapshotNode`,
    /// because that is what the reading carries: the decode into typed nodes
    /// is the pane's job and belongs under test with it.
    Map<String, Object?> aButton() => {
      'rect': {'x': 0, 'y': 0, 'width': 100, 'height': 40},
      'flags': ['isButton'],
      'actions': ['tap'],
      'children': <Object?>[],
    };

    testWidgets('reads with the picture, and is one tab away', (tester) async {
      await pumpScreenTab(
        tester,
        Uint8List.fromList(_onePixelPng),
        guest: true,
        semantics: aButton(),
      );

      // The tab is there before it is opened, and its badge is the audit's
      // count — which is what says the tab is worth opening at all.
      expect(find.text('Semantics'), findsOneWidget);
      expect(find.text('1'), findsWidgets);

      await tester.tap(find.text('Semantics'));
      await tester.pumpAndSettle();

      // The screen reader's script, from the reading the picture came from.
      expect(find.textContaining('nothing to read'), findsWidgets);
    });

    testWidgets('a run with no guest is told from an app with no tree', (
      tester,
    ) async {
      // No guest at all: the service extension has no semantics to give, so
      // this is news about the *run*, not about the app's accessibility.
      await pumpScreenTab(tester, Uint8List.fromList(_onePixelPng));

      await tester.tap(find.text('Semantics'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no flutterware guest'),
        findsOneWidget,
        reason: 'the pane says which absence this is',
      );
    });
  });

  group('freshness', () {
    testWidgets('the reading says how old it is', (tester) async {
      await pumpScreenTab(tester, Uint8List.fromList(_onePixelPng));

      // A photograph of a live app looks exactly like a mirror of one, and
      // only the caption separates them.
      expect(find.text('read just now'), findsOneWidget);
    });

    testWidgets('what the cockpit did to the app, the pane re-reads', (
      tester,
    ) async {
      var (core, handle) = await pumpScreenTab(
        tester,
        Uint8List.fromList(_onePixelPng),
      );

      var reads = 0;
      var first = core.debugRead!;
      core.debugRead = (h) {
        reads++;
        return first(h);
      };

      // Stands in for the VM service round trip. A reload that returned is a
      // reload that happened.
      core.debugControl = (_, _) async {};
      await core.control('reload', handle);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(reads, 1, reason: 'the reload re-read the app');
      expect(find.text('read just now'), findsOneWidget);
      // Nothing to warn about: the picture is of the app as it now is.
      expect(find.textContaining('has moved since'), findsNothing);
    });

    testWidgets("the human's own taps are reported, not chased", (
      tester,
    ) async {
      var (core, handle) = await pumpScreenTab(
        tester,
        Uint8List.fromList(_onePixelPng),
      );

      var reads = 0;
      var first = core.debugRead!;
      core.debugRead = (h) {
        reads++;
        return first(h);
      };

      // What the beat poller collects, up to once a second. Re-reading on
      // each would be a render and a full tree walk per tap.
      core.debugCollectBeats(handle, [
        {
          'verb': 'tap',
          'target': '"Pay"',
          'at': DateTime.now().toIso8601String(),
        },
      ]);
      await tester.pump();

      expect(reads, 0, reason: 'a human tap does not spend a reading');
      expect(find.textContaining('the app has moved since'), findsOneWidget);
    });
  });

  testWidgets('the device strip is over the picture, and only there', (
    tester,
  ) async {
    // Above the picture rather than on a tab of its own: a tab strip is
    // exclusive, so a *Device* tab would be a control writing to a page you
    // are not on. And only on Screen, because that page is where the result of
    // pressing one is visible.
    await pumpScreenTab(tester, Uint8List.fromList(_onePixelPng));
    expect(find.byType(DeviceStrip), findsOneWidget);

    var strip = tester.getRect(find.byType(DeviceStrip));
    var picture = tester.getRect(find.byType(RawImage));
    expect(strip.bottom, lessThanOrEqualTo(picture.top));

    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceStrip), findsNothing);
  });

  testWidgets('the screen pane finishes its read and draws both halves', (
    tester,
  ) async {
    await pumpScreenTab(tester, Uint8List.fromList(_onePixelPng));

    // The read completed. Before the fix this threw inside `initState`, the
    // read never ran, and the pane said `Reading the app…` for ever.
    expect(tester.takeException(), isNull);
    expect(find.text('Reading the app…'), findsNothing);

    // Both halves of the Screen tab, from the one reading.
    expect(find.text('MyApp'), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);

    // **The caption is only ever drawn over a picture that is there.** It used
    // to be drawn on `image != null`, which is true a decode before there is
    // anything to see: `Image.memory` resolves asynchronously and a
    // `RenderImage` with nothing yet takes zero height, so the caption slid up
    // and described a blank pane. Measured at 103ms against a painting app and
    // unbounded against one that is not — an occluded window schedules no
    // frame for the decode to arrive on.
    var picture = tester.widget<RawImage>(find.byType(RawImage));
    expect(picture.image, isNotNull);
    expect(
      find.text('rendered by the app — platform views will not appear'),
      findsOneWidget,
    );

    // **The detail pane must not read this reader's blindness as the widget's
    // shape.** A VM-service tree carries no layout for any node, and the pane
    // used to answer that with "lays nothing out of its own — a provider or a
    // builder" on every one of them, `Scaffold` included. It says who is not
    // looking instead.
    await tester.tap(find.text('MyApp'));
    await tester.pump();
    expect(find.textContaining('Lays nothing out'), findsNothing);
    expect(find.textContaining('Structure and source only'), findsOneWidget);

    // The design's tabs, and the header above them — the run named as one
    // phrase and the controls spelled out. No capability pill here: this run
    // is reloadable, which is the normal state; the pill only appears when
    // something is missing.
    expect(find.text('Screen'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    expect(find.text('App \u2192 macOS'), findsOneWidget);
    expect(find.text('reloadable'), findsNothing);
    expect(find.text('Hot reload'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    // Hot restart is the split button's alternative, built only while the
    // menu is open.
    expect(find.text('Hot restart'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Hot reload'),
          matching: find.byType(FwSplitButton),
        ),
        matching: find.byIcon(Icons.expand_more),
      ),
    );
    await tester.pump();
    expect(find.text('Hot restart'), findsOneWidget);
  });

  /// The box over the picture, which only a guest tree can draw.
  ///
  /// Three things have to line up for it and only the first is arithmetic:
  /// the rects are in the app's own logical pixels, the picture is those
  /// pixels shrunk into a third of a pane, and what says how much they were
  /// shrunk by is the topmost rect in the tree — the same box the screenshot
  /// RPC was framed on.
  group('the highlight', () {
    /// `MyApp` is the canvas at 400×200; the `Text` sits in it; the `Ghost` is
    /// wearing the rect it had when it was last on a screen.
    InspectTree treeWithBoxes() => const InspectTree(
      entryId: null,
      root: InspectNode(
        id: '',
        type: 'MyApp',
        createdByLocalProject: true,
        layout: InspectLayout(x: 0, y: 0, width: 400, height: 200),
        children: [
          InspectNode(
            id: '0',
            type: 'Text',
            createdByLocalProject: true,
            layout: InspectLayout(x: 40, y: 20, width: 120, height: 30),
          ),
          InspectNode(
            id: '1',
            type: 'Ghost',
            createdByLocalProject: true,
            offstage: true,
            layout: InspectLayout(x: 0, y: 0, width: 10, height: 10),
          ),
        ],
      ),
    );

    TestGesture? mouse;

    /// Points at [row] the way a mouse does.
    Future<void> hover(WidgetTester tester, String row) async {
      if (mouse == null) {
        mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(() => mouse!.removePointer());
        await mouse!.addPointer(location: Offset.zero);
      }
      await mouse!.moveTo(tester.getCenter(find.text(row)));
      await tester.pump();
    }

    /// Whatever box is drawn over the picture — none being a real answer, and
    /// the one two of these tests are about.
    List<NodeHighlightPainter> painted(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<NodeHighlightPainter>()
        .toList();

    testWidgets('lands where the node is, scaled into the picture', (
      tester,
    ) async {
      await pumpScreenTab(
        tester,
        await _png(tester, 400, 200),
        tree: treeWithBoxes(),
      );

      await hover(tester, 'Text');
      var painter = painted(tester).single;
      // Whatever width the pane happened to give the picture — the point is
      // that the box is the same *fraction* of it that the node is of the app.
      var picture = tester.getSize(find.byType(RawImage));
      // **What makes the fraction the whole of the mapping.** `RenderImage`
      // sizes itself preserving the image's aspect, so `BoxFit.contain` fills
      // that box exactly and there is no letterbox inside it to account for.
      // Asserted rather than assumed: a change of `fit` here would move every
      // box and break nothing else.
      expect(picture.width / picture.height, closeTo(400 / 200, 0.001));
      expect(painter.label, 'Text');
      expect(painter.rect!.left, closeTo(picture.width * 40 / 400, 0.01));
      expect(painter.rect!.top, closeTo(picture.height * 20 / 200, 0.01));
      expect(painter.rect!.width, closeTo(picture.width * 120 / 400, 0.01));
      expect(painter.rect!.height, closeTo(picture.height * 30 / 200, 0.01));
    });

    testWidgets('leaves the picture alone for a node that is not on it', (
      tester,
    ) async {
      await pumpScreenTab(
        tester,
        await _png(tester, 400, 200),
        tree: treeWithBoxes(),
      );

      // Proves the pointer is doing something, so that the nothing below is
      // an answer about the node rather than about the hover.
      await hover(tester, 'Text');
      expect(painted(tester), hasLength(1));

      // An offstage node's rect is where it *was*. Drawing it would put a box
      // on a screen the widget is not on.
      await hover(tester, 'Ghost');
      expect(painted(tester), isEmpty);
    });

    testWidgets('is not drawn at all over a tree that carries no box', (
      tester,
    ) async {
      // The service-extension reading — every node without a layout. Nothing
      // tests for the reader; a node with no rect simply paints nothing.
      await pumpScreenTab(tester, await _png(tester, 400, 200));

      await hover(tester, 'MyApp');
      expect(painted(tester), isEmpty);
    });
  });

  testWidgets('a picture that will not decode is said, not captioned', (
    tester,
  ) async {
    // Bytes the app called a screenshot and no decoder will take. The read
    // succeeded, so this is not the failure banner's case — the pane has an
    // answer, and the answer is that there is no picture in it.
    await pumpScreenTab(tester, Uint8List.fromList([1, 2, 3, 4]));

    expect(tester.takeException(), isNull);
    expect(
      find.text('The app answered with a picture that decodes to nothing.'),
      findsOneWidget,
    );

    // Neither of the two things it is not: a caption over an empty box, nor
    // the "no picture yet" that means the reading has not happened.
    expect(
      find.text('rendered by the app — platform views will not appear'),
      findsNothing,
    );
    expect(find.text('No picture yet'), findsNothing);

    // The other half of the reading still arrived.
    expect(find.text('MyApp'), findsOneWidget);
  });

  testWidgets('the New run page offers only the devices the entry point '
      'declares, and reads its flavor rather than asking for it', (
    tester,
  ) async {
    File(p.join(worktree.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: app\nflutter:\n  default-flavor: dev\n');
    File(p.join(worktree.path, 'lib', 'main_kiosk.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    DeviceCache.write(runDir.path, const [
      DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
      DaemonDevice(
        id: 'macos',
        name: 'macOS',
        platformType: 'macos',
        ephemeral: false,
      ),
    ]);

    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {
              'path': '.',
              'entrypoints': [
                {
                  'path': 'lib/main_kiosk.dart',
                  'name': 'Kiosk',
                  'platforms': ['mobile'],
                },
              ],
            },
          ],
        },
      ),
    );
    addTearDown(core.dispose);

    // One run in the ledger. It used to be here to make the desk disappear, so
    // that `macOS` being nowhere would prove the picker had filtered it; the
    // desk is drawn whether or not anything is running now, so the claim is
    // made by scoping instead — this Mac is on the desk and nowhere else.
    RunHandle(
      worktree: worktree.path,
      worktreeName: Worktree(path: worktree.path).name,
      device: 'phone',
      entrypoint: 'lib/main_kiosk.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
    await tester.runAsync(core.computeAll);

    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: const [newRunSegment],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (a) => address.value = a,
            child: Builder(builder: RunPlugin(core).buildPanel),
          ),
        ),
      ),
    );
    await tester.pump();

    // The entry point is the first decision, and the device list below it is
    // the mobile half of a desk that also holds this Mac.
    expect(find.text('Kiosk'), findsWidgets);
    expect(find.text('Pixel'), findsWidgets);
    // The one that matters. This Mac is in the cache and on the desk, and the
    // only reason it is nowhere *else* on this page is that `Kiosk` said
    // `mobile`. Scoped rather than absolute: the desk lists the whole machine
    // by design, so its row is not the picker failing to filter.
    expect(find.text('macOS'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(deskKey), matching: find.text('macOS')),
      findsOneWidget,
    );
    expect(find.text('Kiosk runs on mobile'), findsOneWidget);

    // The flavor is read, not asked for: `default-flavor: dev` in the pubspec
    // is the project having already answered.
    expect(find.text('dev'), findsOneWidget);
    expect(find.text('from the pubspec’s default-flavor'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // And it is one click away when this run really does need another.
    await tester.tap(find.text('Override'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Use dev'), findsOneWidget);
  });

  testWidgets('the flavor pre-fills for the selected device, and overriding '
      'against a declared vocabulary is a pick, not a box', (tester) async {
    File(p.join(worktree.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: app\n');
    File(p.join(worktree.path, 'lib', 'main_kiosk.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    DeviceCache.write(runDir.path, const [
      DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
    ]);

    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {
              'path': '.',
              'flavors': {
                'mobile': ['local', 'kioskLocal'],
              },
              'entrypoints': [
                {
                  'path': 'lib/main_kiosk.dart',
                  'name': 'Kiosk',
                  'flavor': 'local',
                  'flavorByPlatform': {'mobile': 'kioskLocal'},
                },
              ],
            },
          ],
        },
      ),
    );
    addTearDown(core.dispose);

    RunHandle(
      worktree: worktree.path,
      worktreeName: Worktree(path: worktree.path).name,
      device: 'phone',
      entrypoint: 'lib/main_kiosk.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
    await tester.runAsync(core.computeAll);

    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: const [newRunSegment],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (a) => address.value = a,
            child: Builder(builder: RunPlugin(core).buildPanel),
          ),
        ),
      ),
    );
    await tester.pump();

    // The pairing resolved for the phone — not the plain declaration.
    expect(find.text('kioskLocal'), findsOneWidget);
    expect(find.text('from the entry point'), findsOneWidget);

    // Overriding offers the declared vocabulary instead of an empty box —
    // the launch would refuse an unlisted word, and a picker says so first.
    // The device and entry point are pickers too, so the flavor's is the one
    // whose trigger wears the resolved flavor.
    await tester.tap(find.text('Override'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    var flavorPicker = find.ancestor(
      of: find.text('kioskLocal'),
      matching: find.byType(FwPicker<String>),
    );
    expect(flavorPicker, findsOneWidget);
    await tester.tap(flavorPicker);
    await tester.pumpAndSettle();
    expect(find.text('local'), findsWidgets);
  });

  testWidgets('a platform declared flavorless collapses the field to that '
      'fact', (tester) async {
    File(p.join(worktree.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: app\n');
    File(p.join(worktree.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    DeviceCache.write(runDir.path, const [
      DaemonDevice(
        id: 'macos',
        name: 'macOS',
        platformType: 'macos',
        ephemeral: false,
      ),
    ]);

    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {
              'path': '.',
              'flavors': {
                'mobile': ['local', 'kioskLocal'],
                'macos': <String>[],
              },
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App', 'flavor': 'local'},
              ],
            },
          ],
        },
      ),
    );
    addTearDown(core.dispose);

    RunHandle(
      worktree: worktree.path,
      worktreeName: Worktree(path: worktree.path).name,
      device: 'macos',
      entrypoint: 'lib/main.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
    await tester.runAsync(core.computeAll);

    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: const [newRunSegment],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (a) => address.value = a,
            child: Builder(builder: RunPlugin(core).buildPanel),
          ),
        ),
      ),
    );
    await tester.pump();

    // The declaration answers the whole question: nothing to read beyond the
    // fact, and nothing to override — the launch drops the flag as on web.
    expect(
      find.text('none — the platform declares no flavors'),
      findsOneWidget,
    );
    expect(find.text('Override'), findsNothing);
  });

  testWidgets("the New run page comes back holding last time's knobs", (
    tester,
  ) async {
    // Running the same thing again should be opening this page and pressing
    // Start. `lastLaunch` carried a `defines` map the form stopped filling in
    // when defines were deleted, so it came back empty every time — the values
    // somebody had actually chosen were the ones being dropped.
    File(p.join(worktree.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: app\n');
    File(p.join(worktree.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("void main({String apiHost = 'localhost'}) {}");
    DeviceCache.write(runDir.path, const [
      DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
    ]);

    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {
          'packages': [
            {
              'path': '.',
              'entrypoints': [
                {'path': 'lib/main.dart', 'name': 'App'},
              ],
            },
          ],
        },
      ),
    );
    addTearDown(core.dispose);
    // One run in the ledger, so the desk is not drawn under the form — it
    // starts the device daemon, and a real process is not this test's subject.
    RunHandle(
      worktree: worktree.path,
      worktreeName: Worktree(path: worktree.path).name,
      device: 'phone',
      entrypoint: 'lib/main.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
    await tester.runAsync(core.computeAll);
    core.lastLaunch = (
      device: 'phone',
      package: '.',
      entrypoint: 'lib/main.dart',
      flavor: null,
      knobs: {'apiHost': 'staging.example.com'},
    );

    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: const [newRunSegment],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AddressRoot(
            address: address,
            onChanged: (a) => address.value = a,
            child: Builder(builder: RunPlugin(core).buildPanel),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('staging.example.com'), findsOneWidget);
  });

  testWidgets('Run lands on the page that starts one, not on whichever run '
      'sorts first', (tester) async {
    // The bug this is about. With an app running, the rail's `Run` row opened
    // that app's cockpit — so the only page carrying a device list, an
    // emulator to boot and a launch form was unreachable for as long as
    // anything was up, and the only way back to it was a `+` that appeared
    // while the mouse was over the row.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    _publishRun(runDir, worktree, device: 'phone');
    await tester.runAsync(core.computeAll);

    await _mountRun(tester, core, const []);

    expect(find.text('New run'), findsOneWidget);
    // Not the cockpit, which is what an address naming no run used to reach.
    expect(find.text('Hot reload'), findsNothing);
  });

  testWidgets('the desk is drawn while a run is going, with what it can boot', (
    tester,
  ) async {
    // The report, in one test. `boot` lived only on a page that was hidden as
    // soon as this worktree had a run, and an unbooted emulator is not a
    // device — so one running app made every other machine unreachable.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    core.debugEmulators = const [
      DaemonEmulator(id: 'Pixel_8', name: 'Pixel 8', platformType: 'android'),
      DaemonEmulator(id: 'apple_ios_simulator', platformType: 'ios'),
    ];
    _publishRun(runDir, worktree, device: 'phone');
    await tester.runAsync(core.computeAll);

    await _mountRun(tester, core, const []);

    expect(find.byKey(deskKey), findsOneWidget);
    // An AVD is booted and the Simulator is opened — different verbs because
    // they are different acts.
    expect(find.text('boot'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    // And the reading can be taken again, which the GUI could never ask for.
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('Run here answers the Device field rather than navigating', (
    tester,
  ) async {
    // A desk row is a fact with one offer on the end of it, and the offer is
    // for the form above: the entry point, the flavor and the knobs have
    // already been chosen up there, so a jump would ask for them again.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    await tester.runAsync(core.computeAll);

    await _mountRun(tester, core, const []);

    // The form opened on one machine; the desk offers the other, and only the
    // other — a row offering the device already chosen is offering nothing.
    var offered = find.descendant(
      of: find.byKey(deskKey),
      matching: find.text('Run here'),
    );
    expect(offered, findsOneWidget);

    // A name is on screen once while only the desk carries it and twice once
    // the picker holds it too, so the count says which machine is chosen
    // without the test having to know which one the form opened on.
    int macs() => find.text('macOS').evaluate().length;
    var before = macs();
    await tester.tap(offered);
    await tester.pump();

    expect({before, macs()}, {1, 2}, reason: 'the field took what was offered');
  });

  testWidgets('a live run outranks a failure wearing its key', (tester) async {
    // A run's key is its entry point, device and flavor, so relaunching what
    // just failed produces a handle and a failure record with the *same* key.
    // Reading the failure first made both rail rows open the obituary while
    // the app they were about was up and driveable, with no way to reach it
    // but Dismiss.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    var handle = _publishRun(runDir, worktree, device: 'phone');
    var logPath = p.join(runDir.path, 'app-failed.log');
    File(
      logPath,
    ).writeAsStringSync('Error: Build process failed\nApp failed to start\n');
    core.recordFailure(handle, LaunchLog.read(logPath));
    await tester.runAsync(core.computeAll);

    expect(core.failureFor(handle.key), isNotNull, reason: 'both exist');

    await _mountRun(tester, core, [handle.key]);

    expect(find.text('Error: Build process failed'), findsNothing);
    expect(find.text('Hot reload'), findsOneWidget);
  });

  testWidgets('a launch that never came up hands over its whole log', (
    tester,
  ) async {
    // The last page still printing a *path* instead of the thing it names. A
    // build failure is the one moment somebody wants to scroll the whole log,
    // and it was the one page that would not let them — the reason block is
    // capped at forty lines by design, and the cause of an Xcode signing
    // failure is twenty lines above the summary.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    var logPath = p.join(runDir.path, 'app-failed.log');
    File(logPath).writeAsStringSync(
      [
        'Launching lib/main.dart on Pixel in debug mode...',
        'Note: some input files use unchecked or unsafe operations.',
        // A structured event closes the plain block before it, so the reason
        // this page extracts is only what follows — and the two lines above
        // exist nowhere but the log.
        jsonEncode([
          {
            'event': 'app.progress',
            'params': {
              'appId': 'a1',
              'id': '0',
              'progressId': null,
              'message': 'Running Gradle task...',
              'finished': false,
            },
          },
        ]),
        'Error: Build process failed',
        'App failed to start',
        '',
      ].join('\n'),
    );
    // Recorded but never published: a launch that failed has its handle
    // deleted, which is exactly why this page could not reuse the run's log
    // pane and printed a path instead.
    var handle = _unpublishedRun(worktree, logPath);
    core.recordFailure(handle, LaunchLog.read(logPath));
    await tester.runAsync(core.computeAll);

    await _mountRun(tester, core, [handle.key]);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.byType(LogsTab), findsOneWidget);
    // Three places, which is the page's anatomy: the headline picked out of
    // the block, the block itself, and the line in the log it came from.
    expect(find.textContaining('Build process failed'), findsNWidgets(3));
    // And the lines the extract cannot reach are here too, which is the point.
    expect(find.textContaining('unchecked or unsafe'), findsOneWidget);
    // And the path is not printed as text any more — the log pane's own menu
    // carries it, beside the lines it names.
    expect(find.text(logPath), findsNothing);
  });

  testWidgets('and offers no platform log, having no session to ask about', (
    tester,
  ) async {
    // The device log is read by asking a session about a window of time. A
    // launch that never came up has none, so the pill is dropped rather than
    // offered and refused.
    var core = _homeCore(worktree);
    addTearDown(core.dispose);
    var logPath = p.join(runDir.path, 'app-failed.log');
    File(logPath).writeAsStringSync('Error: Build process failed\n');
    var handle = _unpublishedRun(worktree, logPath);
    core.recordFailure(handle, LaunchLog.read(logPath));
    await tester.runAsync(core.computeAll);

    await _mountRun(tester, core, [handle.key]);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    expect(find.text('Build'), findsOneWidget, reason: 'the other pills stay');
    expect(find.text('Platform'), findsNothing);
  });

  group('a run that has not come up yet', () {
    /// A published run whose app does not answer, with a launcher log already
    /// carrying [lines] — the state a cold build spends minutes in.
    Future<(RunCore, RunHandle)> building(
      WidgetTester tester,
      List<String> lines, {
      Duration age = Duration.zero,
      String? package,
      String device = 'phone',
      bool probed = true,
    }) async {
      var core = _homeCore(worktree);
      addTearDown(core.dispose);
      var logPath = p.join(runDir.path, 'building.log');
      File(logPath).writeAsStringSync([...lines, ''].join('\n'));
      var key = _publishRun(
        runDir,
        worktree,
        device: device,
        logPath: logPath,
        package: package,
        startedAt: DateTime.now().subtract(age),
      ).key;
      await tester.runAsync(core.computeAll);
      // The *scanned* handle, not the one that was published: a probe is keyed
      // by the handle file's path, and the object `_publishRun` answers with
      // has not got one.
      var handle = core.handles.firstWhere((each) => each.key == key);
      // The launcher is alive and the app is not: `canInspect` is false, which
      // is the flag every pane on this page used to hang off.
      if (probed) {
        core.debugSetProbe(handle, const RunProbe(app: false, launcher: true));
      }
      return (core, handle);
    }

    testWidgets('the log is live before the app is', (tester) async {
      // The complaint this is about: a consumer watched a cold build say one
      // word for ninety seconds while the launcher wrote a page of narration
      // into a file the panel would not open. The file has been there since
      // before the process had a pid — `launchApp` redirects the launcher's
      // whole stdio into it — and the Logs tab was gated on the app answering.
      var (core, handle) = await building(tester, [
        'Resolving dependencies...',
        'Running Gradle task assembleDebug...',
      ]);

      await _mountRun(tester, core, [handle.key, 'logs']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      expect(find.textContaining('Running Gradle task'), findsOneWidget);
    });

    testWidgets('the pane that cannot answer is the log', (tester) async {
      // It used to be a spinner, one word, and the log's *path* printed as
      // selectable text under a doc comment claiming the logs were being
      // offered. A path is a string to carry to a terminal.
      var (core, handle) = await building(tester, [
        'Launching lib/main.dart on Pixel in debug mode...',
        'Running Gradle task assembleDebug...',
      ]);

      await _mountRun(tester, core, [handle.key, 'screen']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      // The stage, then the log itself — the same pane it gets once it is up,
      // so `app.started` changes which tabs are open and nothing else.
      expect(find.text('building'), findsOneWidget);
      expect(find.byType(LogsTab), findsOneWidget);
      expect(find.textContaining('Running Gradle task'), findsOneWidget);
    });

    testWidgets('a build that is late says so, and a young one does not', (
      tester,
    ) async {
      // A cold build is allowed to be slow. What nobody can tell from a
      // spinner is whether *this* one has stopped being slow and started being
      // stuck — which is the state the consumer was in when they reported all
      // of this.
      var lines = ['Launching lib/main.dart on Pixel in debug mode...'];

      var (young, itsHandle) = await building(tester, lines);
      await _mountRun(tester, young, [itsHandle.key, 'screen']);
      expect(find.textContaining('usually finishes within'), findsOneWidget);
      expect(find.textContaining('longer than'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      var (old, itsKey) = await building(
        tester,
        lines,
        age: const Duration(minutes: 9),
      );
      await _mountRun(tester, old, [itsKey.key, 'screen']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      expect(find.textContaining('longer than a cold'), findsOneWidget);
      expect(find.textContaining('in the log below'), findsOneWidget);
    });

    testWidgets('an unprobed run is not accused of running late', (
      tester,
    ) async {
      // Before anything has asked the run, a handle that has not answered is
      // as likely to be an app that has been up for hours as a build in
      // flight — the panel renders every announced run in that state for as
      // long as the first probe takes. Measuring from `startedAt` there turns
      // an unknown into `3h 12m in, longer than a cold build usually takes`,
      // in amber, about a perfectly healthy app.
      var (core, handle) = await building(
        tester,
        ['Launching lib/main.dart on Pixel in debug mode...'],
        age: const Duration(hours: 3),
        probed: false,
      );

      await _mountRun(tester, core, [handle.key, 'screen']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      expect(find.textContaining('longer than'), findsNothing);
      expect(find.textContaining('usually finishes within'), findsNothing);
      // The stage still shows: that much is read off the log, not guessed.
      expect(find.textContaining('in — '), findsNothing);
      expect(find.byType(LogsTab), findsOneWidget);
    });

    testWidgets('a device this build cannot place is left unnamed', (
      tester,
    ) async {
      // `platformLabelFor` falls back to the device *id* so a sentence always
      // has a noun, which is right for prose and wrong here: an id is not a
      // platform, and a simulator that has since been shut down is no longer
      // in the device list. The pane read `a cold
      // 575104B7-6AB9-42BA-82B6-351FC0DA2921 build usually finishes within`.
      var (core, handle) = await building(tester, [
        'Launching lib/main.dart in debug mode...',
      ], device: '575104B7-6AB9-42BA-82B6-351FC0DA2921');

      await _mountRun(tester, core, [handle.key, 'screen']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      expect(find.textContaining('a cold build usually finishes'), findsOne);
      // Scoped to the sentence: the *header* names the device, and naming the
      // thing you launched on is exactly what it is for. What must not happen
      // is an id standing where a platform goes.
      expect(find.textContaining('cold 575104B7'), findsNothing);
    });

    testWidgets('Stop and edit stops it and opens the form holding its '
        'settings', (tester) async {
      // What somebody does when the log has just told them the flavor was
      // wrong. Without it: stop, find the form — itself impossible until the
      // rail landed on it again — and re-answer five fields from memory.
      var (core, handle) = await building(tester, [
        'Launching lib/main.dart on Pixel in debug mode...',
      ], package: '.');
      var stopped = <String>[];
      core.debugControl = (action, _) async => stopped.add(action);

      await _mountRun(tester, core, [handle.key, 'screen']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      await tester.tap(find.text('Stop and edit'));
      await tester.pumpAndSettle();

      expect(stopped, ['stop']);
      expect(find.text('New run'), findsOneWidget);
      // Primed through the same door the form already reads on open.
      expect(core.lastLaunch?.device, 'phone');
      expect(core.lastLaunch?.entrypoint, 'lib/main.dart');
    });

    testWidgets('a tab that cannot be opened is drawn as one', (tester) async {
      // The second complaint. Every tab drew in the normal colour and five of
      // the six swallowed the tap, so the page read as a broken window rather
      // than as a wait: you clicked Steps because it was the one that
      // responded, and then could not get back.
      var (core, handle) = await building(tester, ['Building the app…']);

      await _mountRun(tester, core, [handle.key, 'logs']);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      await tester.tap(find.text('Screen'));
      await tester.pumpAndSettle();

      // Still on the log, and the refusal is said rather than swallowed: the
      // four panes that need an app carry the reason, the two file-backed ones
      // carry nothing because they work.
      expect(find.textContaining('Building the app…'), findsOneWidget);
      expect(
        find.byTooltip('waiting for the app — the log is live'),
        findsNWidgets(4),
      );
    });
  });
}

/// A core over two machines and one entry point that runs on either — enough
/// for the form to open filled in and the desk to have something to offer.
RunCore _homeCore(Directory worktree) {
  File(p.join(worktree.path, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('name: app\n');
  File(p.join(worktree.path, 'lib', 'main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void main() {}');
  DeviceCache.write(RunCore.runDirProvider(), const [
    DaemonDevice(id: 'phone', name: 'Pixel', platformType: 'android'),
    DaemonDevice(
      id: 'macos',
      name: 'macOS',
      platformType: 'macos',
      ephemeral: false,
    ),
  ]);
  return RunCore(
    PluginHost(
      id: runPluginId,
      label: 'Run',
      worktree: Worktree(path: worktree.path),
      workspace: Workspace(
        root: worktree.path,
        declared: [Pkg('.')],
        discovered: ['.'],
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/tmp/flutter'),
      ),
      config: const {
        'packages': [
          {
            'path': '.',
            'entrypoints': [
              {'path': 'lib/main.dart', 'name': 'App'},
            ],
          },
        ],
      },
    ),
  );
}

/// A run that was never announced — what a launch that failed leaves behind,
/// since [RunCore] deletes the handle and keeps only the reason.
RunHandle _unpublishedRun(Directory worktree, String logPath) => RunHandle(
  worktree: worktree.path,
  worktreeName: Worktree(path: worktree.path).name,
  device: 'phone',
  entrypoint: 'lib/main.dart',
  launcherPid: pid,
  logPath: logPath,
  startedAt: DateTime.now(),
);

RunHandle _publishRun(
  Directory runDir,
  Directory worktree, {
  required String device,
  String? logPath,
  String? package,
  DateTime? startedAt,
}) {
  var handle = RunHandle(
    worktree: worktree.path,
    worktreeName: Worktree(path: worktree.path).name,
    device: device,
    entrypoint: 'lib/main.dart',
    package: package,
    // This process, so a probe reads it as alive.
    launcherPid: pid,
    logPath: logPath,
    startedAt: startedAt ?? DateTime.now(),
  );
  handle.publish(runDir.path);
  return handle;
}

Future<void> _mountRun(
  WidgetTester tester,
  RunCore core,
  List<String> segments,
) async {
  var address = ValueNotifier(
    Address(worktree: 'wt', plugin: runPluginId, segments: segments),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: Scaffold(
        body: AddressRoot(
          address: address,
          onChanged: (a) => address.value = a,
          child: Builder(builder: RunPlugin(core).buildPanel),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// One opaque white pixel: signature, IHDR, IDAT, IEND.
///
/// It has to decode, not merely look like a PNG. An undecodable blob does not
/// fail the test that mounts it — nothing awaits the codec — it fails whichever
/// test runs next, as an image-resource exception with no visible cause.
const _onePixelPng = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, //
  73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
  8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0,
  13, 73, 68, 65, 84, 120, 218, 99, 96, 96, 96, 248,
  15, 0, 1, 4, 1, 0, 128, 187, 209, 91, 0, 0,
  0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

/// A blank PNG [width]×[height], so the pane has a picture with a real shape
/// to fit — a one-pixel image would make every fraction of it the same
/// fraction.
Future<Uint8List> _png(WidgetTester tester, int width, int height) async {
  var bytes = await tester.runAsync(() async {
    var recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF202020),
    );
    var image = await recorder.endRecording().toImage(width, height);
    try {
      return await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
  });
  return bytes!.buffer.asUint8List();
}
