import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/loading_state.dart';
import 'package:flutterware_app/src/ui/startup_progress.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';

/// What the page says while a run is in flight, which is two surfaces and a
/// rule for choosing between them.
///
/// **The half that used to go unsaid is the second one.** The page narrated its
/// wait only while the canvas was empty and stopped the moment the first step
/// landed — so a long scenario filled in step by step with nothing on screen
/// saying more was coming, and the only difference between a run still going
/// and one that had finished was whether anything new ever appeared.
///
/// Both surfaces now read one [StartupProgress], the same model the previews
/// landing reads, for the same wait: a scenario and a catalog page both come up
/// through one `TesterHost`.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_scenarios_progress_test');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<_Gated> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var core = ScenariosCore(
      PluginHost(
        id: scenariosPluginId,
        label: 'Scenarios',
        worktree: Worktree(path: root.path),
        workspace: Workspace(
          root: root.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {
          'packages': [
            {'path': '.'},
          ],
        },
      ),
    );
    var runner = _Gated();
    core.debugInstallRunner('.', runner);
    var plugin = ScenariosPlugin(core);
    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: scenariosPluginId,
        segments: ['.', 'test', 'scenarios', 'a_test.dart', 'A'],
      ),
    );
    addTearDown(address.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: AddressRoot(
          address: address,
          onChanged: (a) => address.value = a,
          child: Builder(builder: plugin.buildPanel),
        ),
      ),
    );
    await tester.pump();
    return runner;
  }

  // The panel is master/detail and the *list* is still scanning this temp
  // directory, so it has a loader of its own. Every finder here is scoped to
  // the surface under test rather than to a type that appears twice.
  Finder centred() => find.descendant(
    of: find.byType(LoadingState),
    matching: find.text('Running the scenario'),
  );
  Finder banded() => find.descendant(
    of: find.byType(StartupStrip),
    matching: find.text('Running the scenario'),
  );

  testWidgets('nothing at all inside the floor', (tester) async {
    var runner = await open(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      centred(),
      findsNothing,
      reason:
          'a warm run lands in a few hundred milliseconds, and a spinner '
          'that appears and leaves inside one is a flash rather than news',
    );
    expect(find.byType(StartupStrip), findsNothing);
    runner.finish();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('past the floor, the centred state — and only it', (
    tester,
  ) async {
    var runner = await open(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(centred(), findsOneWidget);
    expect(find.text('0s'), findsOneWidget);
    // **Not both.** With an empty canvas there is nothing for a band to sit
    // above, and mounting one put the same sentence on screen twice — once as
    // a band and once under a spinner four hundred pixels below it.
    expect(find.byType(StartupStrip), findsNothing);
    // And the seconds climb, which is the whole of what separates slow from
    // hung.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('3s'), findsOneWidget);
    runner.finish();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('once the flow starts, the strip takes over', (tester) async {
    var runner = await open(tester);
    await tester.pump(const Duration(milliseconds: 400));
    runner.emitStep(0, 'shot');
    await tester.pump();
    await tester.pump();

    expect(centred(), findsNothing, reason: 'the flow is the surface now');
    expect(banded(), findsOneWidget);
    // A run has no denominator — nothing knows how many steps are coming — so
    // the bar is indeterminate and there is no count beside it.
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: find.byType(StartupStrip),
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      isNull,
    );

    runner.finish();
    // Pumped rather than settled: the scenario list beside this pane is still
    // scanning, and its spinner never settles.
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(
      find.byType(StartupStrip),
      findsOneWidget,
      reason: 'still mounted — the flow it sits above is still there',
    );
    expect(
      banded(),
      findsNothing,
      reason: 'and it says nothing, because the run is over',
    );
  });
}

/// A runner that streams one step and then waits to be told the run is over.
///
/// The mid-flight state is the one under test, and a fake that returned its
/// outcome in a microtask never has one.
class _Gated extends ScenarioRunner {
  _Gated()
    : super(packageRoot: '/none', directory: 'none', flutterSdkRoot: '/none');

  @override
  String get logPath => '/none/scenarios.log';

  final _gate = Completer<void>();
  String? _outDir;
  final _steps = <Map<String, Object?>>[];

  void finish() {
    if (!_gate.isCompleted) _gate.complete();
  }

  void emitStep(int index, String name) {
    var png = '$_outDir/$index-$name.png';
    File(png)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(_transparentPng);
    var step = <String, Object?>{
      'index': index,
      if (index > 0) 'parent': index - 1,
      'name': name,
      'auto': false,
      'image': png,
      'format': 'png',
      'width': 1,
      'height': 1,
      'texts': <String>[],
    };
    _steps.add(step);
    onStep?.call({
      'file': 'test/scenarios/a_test.dart',
      'scenario': 'A',
      'device': 'iphone-se',
      'step': step,
    });
  }

  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,
    int? jobs,
    double? captureScale,
    bool captureRaw = false,
    ScenarioPixels pixels = ScenarioPixels.all,
    int? expandTranslations,
    bool narrowestDevice = false,
    bool captureNative = false,
    FilmSettings? film,
    bool filmReel = false,
    Duration? recordInterval,
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,
    ScenarioNetwork? network,
    ScenarioNetwork? projectNetwork,
    String? networkStore,
  }) async {
    _outDir = outDir;
    Directory(outDir).createSync(recursive: true);
    await _gate.future;
    return {
      'ms': 5,
      'scenarios': [
        {
          'file': file,
          'name': scenario,
          'device': 'iphone-se',
          'ok': true,
          'ms': 3,
          'steps': _steps,
        },
      ],
    };
  }

  @override
  Future<List<ScenarioListing>> list() async => const [];

  @override
  Future<void> dispose() async {}
}

const _transparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
