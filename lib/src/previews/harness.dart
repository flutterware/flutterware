import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// The declarer, so one generated file can serve both lanes — see
// [runPreviewHarness] for how its presence is the thing that tells them apart.
// ignore: implementation_imports
import 'package:test_api/src/backend/declarer.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/runtime.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/suite.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/suite_platform.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/test.dart' as backend;

import '../canvases.dart';
import '../clock.dart';
import '../flutter_gpu_diagnosis.dart';
import '../devices.dart';
import '../ui_catalog/fake_keyboard.dart';
import '../drive/drive.dart';
import '../drive/guest_drive.dart' show runWireVerb;
import '../drive/lane.dart';
import '../drive/resolve.dart' show TargetError;
import '../inspect/error.dart';
import '../inspect/guest_errors.dart';
import '../inspect/guest_inspect.dart';
import '../inspect/reveal.dart';
import '../scenarios/asset_bundle.dart';
import '../scenarios/fonts.dart';
import '../scenarios/real_work.dart';
import '../scenarios/run_args.dart';
import '../scenarios/settle.dart';
import '../scene/core/stops.dart';
import 'grow.dart';
import 'playhead.dart';
import '../scenarios/staging.dart';
import '../ui_catalog/axes.dart';
import '../ui_catalog/guest.dart';

/// How much fake clock an entry is given before it is judged.
const auditBudget = Duration(seconds: 5);

/// [Settle.elapse] rather than [Settle.standard], because the audit is the one
/// caller with nothing to photograph.
///
/// A frame-driven settle returns at the first frame the entry does not ask for,
/// and an entry waiting on a timer asks for none while it waits — an image
/// provider that sleeps before it decodes, a demo holding its placeholder long
/// enough to be seen. The tree is then disposed with that timer still on the
/// clock, and `flutter_test` reports that as the entry leaking a timer, which
/// reads as the entry's bug and is the harness's. Spending the clock instead
/// costs close to nothing here — a pump with nothing due builds no frame — and
/// widens what the error buffer sees, since every frame in between is still
/// built and still reported.
///
/// What this policy gives up is the screen *as it settled*: what a capture
/// photographs is the screen at `budget`. The comparison rides that on
/// purpose — under a fake clock the screen at `budget` is the same picture
/// every run, animations and all, and a diff wants reproducible pixels more
/// than it wants the prettiest frame.
const auditSettle = Settle.elapse(auditBudget);

/// How much fake clock a step may take to go quiet — [Settle.standard]'s, the
/// budget a scenario step has. Frames stop it early, so it costs a spinner
/// fifty pumps and a quiet screen one.
const stepSettle = Duration(seconds: 5);

/// How tall `--full` may grow a screen, in screens of the one it started as.
/// A list with no end stops here and says so.
const fullScreens = 10;

/// The longest side of a picture this lane draws, in pixels: the
/// rasteriser's largest texture.
///
/// **Past it the picture is scaled down in silence.** Measured on a 3× phone
/// grown to 7349pt for `--full`: asked for 1179×22047, the frame came back
/// 876×16384, and every crop and page cut computed at 3× landed on the wrong
/// rows. So [_capture] lowers the ratio itself and says which it used.
const maxPictureSide = 16384;

/// How long, in real time, an entry's settle waits for work the app handed to
/// `RealWork.track` before the entry is photographed anyway.
///
/// The fake clock makes every other input to the picture reproducible, and a
/// ceiling on real time is the one thing it cannot cover. At the default
/// [realWorkWait] of one second the picture depended on the machine: measured
/// on a 1.7 MB glTF import that took ~860ms on an idle machine, the entry drew
/// the model when the machine was idle and its spinner every time the CPU was
/// saturated, and the comparison reported the difference as a change.
///
/// So this is a deadline rather than a budget: the scenario deadline's thirty
/// seconds, `package:test`'s own default. Work that finishes is waited for
/// exactly as long as it takes. Work that does not is named on the capture as
/// `pending`, so a picture taken with it outstanding is never mistaken for the
/// entry.
const auditTrackedWait = Duration(seconds: 30);

/// One preview, as the generated harness hands it over.
///
/// [build] is a thunk rather than a widget because a preview is built *inside*
/// the test body: the annotation's `wrapper` runs there, under the canvas the
/// entry is judged on, and a widget built at table-construction time would have
/// been built under whatever the previous entry left behind.
class PreviewEntry {
  const PreviewEntry({
    required this.id,
    required this.path,
    required this.name,
    required this.build,
  });

  /// What the tool calls this entry — `demo/tile.dart#tileEmpty`.
  final String id;

  /// Package-relative and `/`-separated, which is the coordinate space
  /// [canvasFor] matches against.
  final String path;

  final String name;

  /// The entry with its `wrapper` already applied — the generator owns that,
  /// because only the generated file can name the annotation.
  final Widget Function() build;
}

/// Runs every preview in a package as a widget test, and answers what each one
/// reported.
///
/// The same widgets, the same errors, a different engine. Each entry is
/// mounted under [CatalogGuest] and its annotation's `wrapper`, exactly as the
/// embedder guest's entrypoint mounts it, and errors are collected into
/// [GuestErrors] — the same buffer, the same dedup key, the same counts. What
/// changes is only that the frame is drawn by a test binding under FakeAsync
/// rather than by a real engine in real time, which is what takes a
/// catalog-wide render from minutes to seconds: a demo that animates for ever
/// costs a few microseconds of fake clock instead of a three-second wait.
///
/// Two lanes off one generated file, told apart by whether a test runner is
/// already declaring:
///
/// - `Declarer.current == null` — nobody is. This was launched as a bare
///   program in a `flutter_tester` the tool spawned, so it declares into its
///   own [Declarer], registers `ext.flutterware.previews.audit` and waits to be
///   asked. **This is the lane whose fonts are real**: the tool omits
///   `--use-test-fonts` and `--disable-asset-fonts`, which `flutter test`
///   passes unconditionally.
/// - `Declarer.current != null` — `flutter test` is running this file as an
///   ordinary test. Each entry is declared as an ordinary `testWidgets` that
///   fails when the entry reports anything. Convenient, shardable, and
///   measuring unstyled text in *approximate* Roboto — real bytes under the
///   platform-default family names, which is near enough for an overflow
///   verdict to mean something and not near enough for a pixel-exact one.
///
/// [setup] is the package's declared `previewSetup` — see
/// `PreviewsPackage.setup` — run once in either lane, after the binding exists
/// and before any entry builds.
void runPreviewHarness(
  List<PreviewEntry> entries, {
  List<PreviewCanvas> canvases = const [],
  FutureOr<void> Function()? setup,
}) {
  if (Declarer.current != null) {
    // The driven lane loads fonts before it declares anything; this one has
    // nowhere earlier to do it. A scenario folder has a
    // `flutter_test_config.dart` to hang that on and a generated preview
    // harness has no folder of its own, so the declaration carries it — and
    // the project's own setup, for the same reason.
    //
    // Without this the catalog is measured in the fallback font, which is wrong
    // in the one way nothing catches: it still renders, and reports the
    // difference as `RenderFlex overflowed by 3.5 pixels`.
    //
    // The defaults too, and only in this branch: `--use-test-fonts` boxes the
    // families nobody loads bytes for, and the families most of a catalog
    // names none of are exactly those. `runScenarios` does the same two lines
    // for the scenario half of this lane; see [loadDefaultScenarioFonts] for
    // why the driven lane below must not.
    setUpAll(() async {
      await loadScenarioFonts();
      await loadDefaultScenarioFonts();
      await setup?.call();
    });
    _declare(entries, canvases, collect: null);
    return;
  }
  // Guarded for the reason the scenario harness is: a failing entry can leak an
  // async error after its test completes, and unguarded that reaches
  // `tester_main.cc`'s unhandled handler, which kills the process. A shared
  // harness dying because one preview failed is the one outcome this may never
  // have.
  unawaited(
    runZonedGuarded(() => _serve(entries, canvases, setup), (error, stack) {
      stderr.writeln('[previews] uncaught: $error\n$stack');
    }),
  );
}

/// The driven lane: declare once, then run on request.
Future<void> _serve(
  List<PreviewEntry> entries,
  List<PreviewCanvas> canvases,
  FutureOr<void> Function()? setup,
) async {
  // The binding first, because everything below reaches for it — loading a font
  // needs the messenger `rootBundle` goes through, and that is the binding's.
  TestWidgetsFlutterBinding.ensureInitialized();
  var fonts = await loadScenarioFonts();
  // A setup that threw is not skipped: every entry would render without what
  // it installs, and plausibly — a fallback font, a network call answered
  // with 400. So the harness still comes up, and refuses every request with
  // the reason instead.
  String? setupFailed;
  try {
    await setup?.call();
  } catch (error, stack) {
    setupFailed =
        "the package's previewSetup() threw, so nothing is rendered "
        'without it:\n$error\n$stack';
  }

  developer.registerExtension('ext.flutterware.previews.audit', (
    _,
    args,
  ) async {
    try {
      if (setupFailed != null) {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': setupFailed}),
        );
      }
      var only = args['entries']
          ?.split(',')
          .where((id) => id.isNotEmpty)
          .toSet();
      var report = await _audit(
        entries,
        canvases,
        only: only,
        // One device for the whole catalog, which is how you ask whether all
        // of it survives a small phone. Absent — the right answer for CI —
        // leaves each entry framed as its own subtree declared.
        device: switch (args['device']) {
          null => null,
          var id => deviceById(id),
        },
        orientation: switch (args['orientation']) {
          null => null,
          var name => orientationById(name),
        },
        // A directory to photograph into. Pixels stay out of the response —
        // a frame is megabytes and the service protocol is JSON — so what
        // travels back is the paths, the way a scenario run reports its
        // captures.
        output: args['output'],
        pixelRatio: double.tryParse(args['pixelRatio'] ?? '') ?? 1,
        tree: args['tree'] != 'false',
        // Off unless asked for. What it writes is a measurement, and a
        // measurement nobody asked for is noise in somebody's console.
        timings: args['timings'] == 'true',
        format: args['format'] ?? 'raw',
        // Absent is the pin, not the wall clock — the host only says this when
        // the project set `fw.clock(...)`, and a lane that fell back to `now`
        // on silence is the drift this parameter exists to end.
        clock: switch (args['clock']) {
          null => null,
          var iso => DateTime.parse(iso),
        },
      );
      return developer.ServiceExtensionResponse.result(jsonEncode(report));
    } catch (error, stack) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    }
  });

  // **Its own extension, not a wider `audit`.** This file is published, so an
  // extension is a wire contract with whatever `package:flutterware` the
  // consumer's checkout resolves — and a checkout that predates a *argument*
  // renders the entry and ignores it in silence, which is a trap the
  // comparison already paid for once. A checkout that predates an *extension*
  // refuses at the call, and the host can say which version is missing.
  developer.registerExtension('ext.flutterware.previews.render', (
    _,
    args,
  ) async {
    try {
      if (setupFailed != null) {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': setupFailed}),
        );
      }
      var request = jsonDecode(args['request'] ?? '{}') as Map<String, Object?>;
      // What is left unanswerable is refused by name rather than dropped. A
      // demo's `print` is the one: a test-zone print rides `live.onMessage`
      // into the runner rather than through the zone `GuestLogs.install`
      // wraps, so there is nothing here to collect — and a caller told "no
      // logs" when it means "not on this engine" would go looking in the demo.
      for (var unsupported in const ['logs']) {
        if (request[unsupported] != null) {
          return developer.ServiceExtensionResponse.result(
            jsonEncode({
              'error':
                  'the previews harness cannot answer `$unsupported` yet; '
                  'ask the embedder guest for it.',
            }),
          );
        }
      }
      var report = await _render(
        entries,
        canvases,
        entryId: request['entry']! as String,
        device: switch (request['device']) {
          String id => deviceById(id),
          _ => null,
        },
        orientation: switch (request['orientation']) {
          String name => orientationById(name),
          _ => null,
        },
        knobValues: (request['knobs'] as Map?)?.cast<String, Object?>(),
        axisValues: switch (request['axes']) {
          Map byShell => {
            for (var shell in byShell.entries)
              '${shell.key}': (shell.value as Map).cast<String, Object?>(),
          },
          _ => null,
        },
        wantKnobs: request['wantKnobs'] == true,
        wantAxes: request['wantAxes'] == true,
        wantTree: request['tree'] == true,
        at: switch (request['at']) {
          String point when point.contains(',') => (
            double.parse(point.split(',').first),
            double.parse(point.split(',').last),
          ),
          _ => null,
        },
        output: request['output'] as String?,
        format: request['format'] as String? ?? 'raw',
        walk: _Walk.fromJson(request['walk']),
        motionT: switch (request['motionT']) {
          num t => t.toDouble(),
          _ => null,
        },
        clock: switch (request['clock']) {
          String iso => DateTime.parse(iso),
          _ => null,
        },
        viewport: switch (request['viewport']) {
          Map json => StagedViewport.fromJson(json.cast<String, Object?>()),
          _ => null,
        },
        reveal: switch (request['reveal']) {
          String selector when selector.isNotEmpty => selector,
          _ => null,
        },
        full: request['full'] == true,
        // `act`'s own parameters, every value a string, exactly as the live
        // extension receives them.
        steps: switch (request['steps']) {
          List steps => [
            for (var step in steps)
              if (step is Map)
                {
                  for (var MapEntry(:key, :value) in step.entries)
                    if (value != null)
                      '$key': value is String ? value : jsonEncode(value),
                },
          ],
          _ => null,
        },
        // Carried now though nothing here takes a picture yet, so that when
        // one does it is asked for in physical pixels rather than acquiring a
        // silent 1× default on the way — which is the whole of §4.2.
        pixelRatio: switch (request['pixelRatio']) {
          num ratio => ratio.toDouble(),
          _ => 1,
        },
      );
      return developer.ServiceExtensionResponse.result(jsonEncode(report));
    } catch (error, stack) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    }
  });

  // The line the host waits for. Fonts named because a catalog rendered in the
  // fallback font is wrong in the one way nothing catches, and "which fonts"
  // is the first question when an overflow row looks implausible.
  print(
    'flutterware previews harness ready — '
    '${entries.length} entries, fonts: ${fonts.join(', ')}',
  );
}

/// Runs [entries] and reports what each one said.
Future<Map<String, Object?>> _audit(
  List<PreviewEntry> entries,
  List<PreviewCanvas> canvases, {
  Set<String>? only,
  Device? device,
  ScreenOrientation? orientation,
  String? output,
  double pixelRatio = 1,
  bool tree = true,
  bool timings = false,
  String format = 'raw',
  Map<String, Object?>? knobValues,
  Map<String, Map<String, Object?>>? axisValues,
  bool wantKnobs = false,
  bool wantAxes = false,
  bool wantTree = false,
  (double, double)? at,
  StagedViewport? viewport,
  _Walk? walk,
  double? motionT,

  /// What `clock.now()` reads while an entry builds, or null for
  /// [pinnedClockOrigin].
  DateTime? clock,
  String? reveal,
  List<Map<String, String>>? steps,
  bool full = false,
}) async {
  var wanted = [
    for (var entry in entries)
      if (only == null || only.contains(entry.id)) entry,
  ];
  var collected = <String, InspectErrors>{};
  var captured = <String, Map<String, Object?>>{};
  // Always collected: the surface rides every render, and the knobs and axes
  // only when they were asked for.
  var declared = <String, Map<String, Object?>>{};
  var declarer = Declarer();
  declarer.declare(
    () => _declare(
      wanted,
      canvases,
      collect: collected,
      device: device,
      orientation: orientation,
      output: output,
      captured: captured,
      pixelRatio: pixelRatio,
      tree: tree,
      timings: timings,
      format: format,
      knobValues: knobValues,
      axisValues: axisValues,
      declared: declared,
      wantKnobs: wantKnobs,
      wantAxes: wantAxes,
      wantTree: wantTree,
      at: at,
      viewport: viewport,
      walk: walk,
      motionT: motionT,
      clock: clock,
      reveal: reveal,
      steps: steps,
      full: full,
    ),
  );
  // Flat by construction — one `testWidgets` per entry, no groups — so the
  // group walk the scenario harness needs has nothing to walk here.
  var suite = Suite(declarer.build(), SuitePlatform(Runtime.vm));

  var failures = <String, String>{};
  // Where each failure was thrown, as an error's `frames` say it. The failure
  // is often the only record there is — a wrapper that throws before anything
  // is pumped reports nothing to the error buffer — and a message with no
  // place in it sends the reader to the entry when the fault is in its theme.
  var failedAt = <String, List<String>>{};
  void fail(PreviewEntry entry, String message, StackTrace? stack) {
    if (failures.containsKey(entry.id)) return;
    failures[entry.id] = auditFailureMessage(message);
    failedAt[entry.id] = InspectError.framesOf(stack);
  }

  var watch = Stopwatch()..start();
  for (var (index, test) in suite.group.entries.cast<backend.Test>().indexed) {
    var entry = wanted[index];
    var live = test.load(suite);
    // The binding's failure path bypasses the LiveTest: it dumps to console and
    // throws from the binding's own zone, so the failure would surface as an
    // uncaught zone error rather than an outcome. The same hook `flutter test`'s
    // own bootstrap uses.
    var priorReporter = reportTestException;
    reportTestException = (details, _) =>
        fail(entry, details.exceptionAsString(), details.stack);
    var each = Stopwatch()..start();
    try {
      await live.run();
    } finally {
      reportTestException = priorReporter;
    }
    // **The number that decides how a catalog-wide render is scheduled.**
    // Measured on this repo's own 151 previews: a median entry is 40ms, the
    // ninetieth is 94ms and the slowest three are over a second each — ten
    // entries carry 42% of the total. A mean says none of that.
    if (timings) {
      stderr.writeln('[entry] ${each.elapsedMicroseconds} ${entry.id}');
    }
    for (var error in live.errors) {
      fail(entry, '${error.error}', error.stackTrace);
    }
  }

  return {
    'ms': watch.elapsedMilliseconds,
    'entries': {
      for (var entry in wanted)
        entry.id: {
          ...?collected[entry.id]?.toJson(),
          ...?captured[entry.id],
          ...?declared[entry.id],
          // The entry's test failed — the builder threw outright, a timer
          // outlived the clock, an error landed after the frame. Beside a
          // frame it is one more complaint about a picture; with none it says
          // the entry did not render at all, and the host tells the two apart.
          'failure': ?failures[entry.id],
          if (failedAt[entry.id] case var frames? when frames.isNotEmpty)
            'failureFrames': frames,
        },
    },
  };
}

/// Stages [viewport] on [tester] and answers the callback that puts it back.
///
/// **A viewport, not a device**, and that is the whole of what this lane was
/// missing. `applyDevice` needs a `Device`, and half the screens a preview is
/// asked for are not one: the panel's own rectangle is no device, and
/// `--width`/`--height` override a real one into a size no phone has. The
/// numbers are what both backends are staged from — the guest over its resize
/// message, this over `ScenarioRunArgs` — so a picture from either is of the
/// same screen.
///
/// A null platform is left null rather than defaulted, which is the difference
/// between *a rectangle* and *a Mac*: an override reassembles the application
/// and would make a `ThemeData` built at the top of a demo describe a machine
/// nobody asked about.
VoidCallback _stageViewport(WidgetTester tester, StagedViewport viewport) {
  var reset = applyScenarioRunArgs(
    tester,
    ScenarioRunArgs(
      size: Size(viewport.logicalWidth, viewport.logicalHeight),
      pixelRatio: viewport.pixelRatio,
      padding: EdgeInsets.fromLTRB(
        viewport.insetLeft,
        viewport.insetTop,
        viewport.insetRight,
        viewport.insetBottom,
      ),
      // **Null is left null, and that is not obviously right.** A viewport
      // with no platform is the panel's own rectangle, and the two lanes then
      // each answer with a default of their own: this binding's, and — since
      // `stageGuestPlatform(null)` resets the override — the machine the guest
      // runs on. Where a theme computes `materialTapTargetSize` from
      // `defaultTargetPlatform` that is a real difference: measured on this
      // repo's own catalog, a `FilledButton` is 48 logical points tall here
      // and 40 in the guest.
      //
      // Staging the host platform here was tried and made it worse, not
      // better: it agreed with the guest on one catalog and disagreed on
      // another, which means the rectangle's platform is not simply "the
      // machine" and the question is what a *rectangle* should be. Left as it
      // was until that is answered, because a change that trades one
      // disagreement for another is not a fix — see §5.3 of
      // `2026-08-27-previews-render-lane-design.md`.
      platform: switch (viewport.platform) {
        DevicePlatform.ios => TargetPlatform.iOS,
        DevicePlatform.android => TargetPlatform.android,
        DevicePlatform.macos => TargetPlatform.macOS,
        DevicePlatform.windows => TargetPlatform.windows,
        DevicePlatform.linux => TargetPlatform.linux,
        null => null,
      },
    ),
  );
  // After the metrics, because it reads the padding it is about to eat into.
  if (viewport.keyboardUp) stageKeyboard(tester, viewport.keyboard);
  return reset;
}

/// One entry, staged, with [knobValues] and [axisValues] turned, and whatever
/// it declares afterwards.
///
/// **Values are applied in the body, never over the VM service.** The guest's
/// `setKnobs` and `setAxes` extensions await `endOfFrame` before they answer,
/// and under FakeAsync with nobody pumping that never completes: an external
/// call would wait out its own timeout and then report success against a build
/// that never happened. In here there is a tester, so a value is applied and
/// pumped in one breath.
///
/// **Already resolved when they arrive.** Which kind a knob is and which label
/// an axis option answers to are facts about the build that declared them, and
/// the host reads those in a first call and resolves against them — so the
/// refusals for a name nobody declared are worded once, on the host, for both
/// backends.
Future<Map<String, Object?>> _render(
  List<PreviewEntry> entries,
  List<PreviewCanvas> canvases, {
  required String entryId,
  Device? device,
  ScreenOrientation? orientation,
  Map<String, Object?>? knobValues,
  Map<String, Map<String, Object?>>? axisValues,
  bool wantKnobs = false,
  bool wantAxes = false,
  bool wantTree = false,
  (double, double)? at,
  double pixelRatio = 1,
  StagedViewport? viewport,
  String? output,
  String format = 'raw',

  /// A walk of the playhead to photograph, instead of one picture of the
  /// settled screen. See [_Walk].
  _Walk? walk,

  /// Where to park the playhead for the one picture. Ignored when [walk] says
  /// to take many.
  double? motionT,

  /// What `clock.now()` reads while the entry builds, or null for
  /// [pinnedClockOrigin].
  DateTime? clock,

  /// A `--node` selector to bring on screen before anything is read or
  /// photographed. See [revealNode].
  String? reveal,

  /// Drive verbs to run before anything is read or photographed, in `act`'s
  /// wire spelling. See [runWireVerb].
  List<Map<String, String>>? steps,

  /// Grow the screen to what its lists hold before anything is read or
  /// photographed. See [growToContent].
  bool full = false,
}) async {
  var entry = entries.where((entry) => entry.id == entryId).toList();
  if (entry.isEmpty) {
    return {
      'error':
          'no entry called $entryId. This harness holds '
          '${entries.length} of them.',
    };
  }
  return _audit(
    entry,
    canvases,
    device: device,
    orientation: orientation,
    knobValues: knobValues,
    axisValues: axisValues,
    wantKnobs: wantKnobs,
    wantAxes: wantAxes,
    wantTree: wantTree,
    at: at,
    pixelRatio: pixelRatio,
    viewport: viewport,
    output: output,
    format: format,
    walk: walk,
    motionT: motionT,
    clock: clock,
    reveal: reveal,
    steps: steps,
    full: full,
    // The `tree.json` beside the frame is the catalog-wide lane's; here the
    // tree travels inline and writing a second copy would be 9ms for nothing.
    tree: false,
  );
}

/// A row says what happened, not what `flutter_test` calls it.
///
/// The pending-timer assertion is the one failure whose wording sends the
/// reader to the wrong place. `flutter_test` says a timer is still pending
/// *after the widget tree was disposed* and quotes a line of `binding.dart` to
/// say it, which reads as the entry leaking a timer — but the disposal is
/// [auditSettle] reaching the end of [auditBudget], and how long the audit
/// waits is the fact that makes the row actionable. It separates a demo that
/// sleeps longer than the audit does from one whose timer never stops; the
/// framework's spelling separates neither.
String auditFailureMessage(String failure) {
  // Before the timer rewrite, because a Flutter GPU failure is never a timer
  // and the check is a substring test either way.
  if (isFlutterGpuFailure(failure)) {
    return withFlutterGpuDiagnosis(
      failure,
      executableArguments: Platform.executableArguments,
      macOS: Platform.isMacOS,
    );
  }
  if (!failure.contains('A Timer is still pending')) return failure;
  return 'A Timer this entry started had not fired after ${auditBudget.inSeconds}s '
      'of the audit clock, so the harness disposed the tree with it '
      'outstanding. Either the entry waits longer than the audit does, or its '
      'timer never stops.';
}

/// Declares one `testWidgets` per entry into whichever declarer is current.
///
/// [collect] is where each entry's report lands in the driven lane. Null in the
/// `flutter test` lane, where nobody is going to read it and the test's own
/// pass or fail is the whole answer.
///
/// [output] asks for pictures: each entry's settled screen and its tree are
/// written under it and their paths land in [captured]. Only the driven lane
/// passes it — the comparison is the caller — so an ordinary audit pays
/// nothing for the capability.
void _declare(
  List<PreviewEntry> entries,
  List<PreviewCanvas> canvases, {
  required Map<String, InspectErrors>? collect,
  Device? device,
  ScreenOrientation? orientation,
  String? output,
  Map<String, Map<String, Object?>>? captured,
  double pixelRatio = 1,
  bool tree = true,
  bool timings = false,
  String format = 'raw',
  Map<String, Object?>? knobValues,
  Map<String, Map<String, Object?>>? axisValues,
  Map<String, Map<String, Object?>>? declared,
  bool wantKnobs = false,
  bool wantAxes = false,
  bool wantTree = false,
  (double, double)? at,
  StagedViewport? viewport,
  _Walk? walk,
  double? motionT,

  /// What `clock.now()` reads while the entry builds, or null for
  /// [pinnedClockOrigin] — the project's own `fw.clock(...)`.
  DateTime? clock,
  String? reveal,
  List<Map<String, String>>? steps,
  bool full = false,
}) {
  for (var (index, entry) in entries.indexed) {
    testWidgets(entry.id, (tester) async {
      // **Pinned here, in the body, rather than around the harness.** A
      // preview exists to be looked at more than once — beside yesterday's
      // screenshot, on the other side of a branch — and an entry that renders
      // the wall clock differs at every reading for a reason that has nothing
      // to do with the code. This is the lane the audit and the comparison
      // read, so it is the one that had to stop drifting.
      //
      // Fixed rather than ticking from the origin, which is what the scenario
      // lane mounts: the embedder guest and the web build both pin
      // `Clock.fixed`, and three preview lanes disagreeing about whether time
      // passes is three different pictures of one entry.
      return withClock(Clock.fixed(clock ?? pinnedClockOrigin), () async {
        // Not `install()`: the binding owns `FlutterError.onError` for the length
        // of a test, and that ownership is what makes a reported error fail it.
        // Chaining collects everything — including the first, which the binding
        // stashes rather than reports — and hands it on unchanged.
        var previous = FlutterError.onError;
        FlutterError.onError = (details) {
          GuestErrors.instance.report(details);
          previous?.call(details);
        };
        // `CatalogGuest` resets on a *change* of entry, so re-running the same one
        // would otherwise still be holding the last run's errors.
        GuestErrors.instance.clear();
        // The other buffer nothing empties between bodies, and the expensive
        // one: an entry left holding a pending decode makes every entry after
        // it wait out the whole real-work allowance on it.
        resetAnnouncedWork();
        // A device named for the whole run wins over every canvas; absent, each
        // entry is framed as its own subtree declared. `canvasFor` rather than a
        // prefix match written out again here, because a rule applied twice is a
        // rule that eventually differs.
        var canvas = canvasFor(canvases, entry.path);
        var reset = switch ((device, canvas?.defaultDevice)) {
          // A viewport named for *this* render wins over everything: it is
          // already the answer the host worked out — the entry's declared
          // canvas, a device the call named, a `--width` override on top — and
          // re-deriving any of that here would be a second opinion about one
          // screen.
          _ when viewport != null => _stageViewport(tester, viewport),
          (var named?, _) => tester.applyDevice(
            named,
            orientation: orientation,
            // The device is the run's; the keyboard is still the entry's own
            // canvas talking, because *which entries are worth seeing with a
            // keyboard over them* is a fact about the entries and not about
            // which phone somebody asked for.
            keyboard: canvas?.defaultKeyboard,
          ),
          (_, _?) => tester.applyCanvas(canvas),
          // Neither: the plain rectangle, staged rather than left alone. The
          // default test surface is 800×600 and the guest's is 900×700, and an
          // entry judged on the narrower one overflows where the guest says it
          // does not.
          _ => applyScenarioRunArgs(
            tester,
            ScenarioRunArgs(
              size: Size(
                previewPanelWidth.toDouble(),
                previewPanelHeight.toDouble(),
              ),
              pixelRatio: 1,
            ),
          ),
        };
        // Held rather than built inline: `landRealWork` reads its in-flight count
        // to know an asset the entry asked for is genuinely still on the way.
        var assets = ScenarioAssetBundle();
        // Real shadows, for the reason the clock above is pinned: this is the
        // lane the audit and the comparison read, and `flutter_test` paints a
        // `BoxShadow` with its blur dropped and a Material `elevation:` as a
        // stroked outline. A preview and a scenario of one widget have to be
        // pictures of the same widget — see `runScenarios`, which says what
        // the default costs. Put back in the `finally`, never a tearDown, for
        // the reason `reset()` is.
        var priorShadows = debugDisableShadows;
        debugDisableShadows = false;
        // Outside the `try`, so the `finally` can take its mouse away.
        Drive? driven;
        try {
          // The harness read the app's fonts through `rootBundle` at startup, and
          // that cached a future belonging to a zone this test is not in.
          rootBundle.clear();
          await tester.pumpWidget(
            // Caches values where `rootBundle` caches futures, which is what makes
            // an asset the app has already read safe to read again from inside
            // `runAsync`. An app installing its own still wins — it is nearer.
            DefaultAssetBundle(
              bundle: assets,
              // The same two wrappers the embedder guest's entrypoint mounts, in
              // the same order, so what differs between the backends is the
              // engine and not the tree. `CatalogGuest` is what makes knobs
              // answer and what resets the axes, errors and logs per entry.
              // And the keyboard, if the canvas staged one — as tall as the
              // view says, so the picture and the layout are the same number.
              //
              // **Always the letters one, and that is a limit of this lane.**
              // The canvas stages its keyboard *before* the pump, so there is
              // nothing focused yet to read a variant off; an entry that
              // autofocuses a `phone` field is drawn here with the keyboard the
              // canvas asked for rather than the one the field did. Following
              // it would need a driver sampling between frames, which is the
              // scenario lane's `ScenarioKeyboard` — and this lane renders one
              // cold frame.
              child: ViewKeyboardSlab(
                child: CatalogGuest(
                  entryId: entry.id,
                  // **The same three widgets the guest entrypoint mounts, in the
                  // same order**, and this one is easy to think unnecessary: the
                  // guest keys per entry so that *switching* remounts rather
                  // than reusing the last demo's State, and a body here renders
                  // one entry and throws the tree away.
                  //
                  // It is not about remounting. A node id is a *position in the
                  // summary tree*, so a widget the two lanes do not both mount
                  // shifts every id below it by one — `--node=0/1/2` would name
                  // different widgets depending on which engine answered, and an
                  // annotated screenshot's labels would not match a tree read
                  // from the other lane. Found by `lane_parity_test.dart` on its
                  // first run, which is what it is for.
                  child: KeyedSubtree(
                    key: ValueKey<String>(entry.id),
                    child: entry.build(),
                  ),
                ),
              ),
            ),
          );
          // A turn of the *real* event loop, which is what lets an asset read
          // complete — the boot turn that replaces `UNIT_TEST_ASSETS`, whose
          // handler deadlocks any `runAsync` that reads an asset itself.
          await tester.runAsync(() async {
            for (var i = 0; i < 5; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          });
          // The boot turn above lands what the *first* frame asked for, and
          // nothing after that: a demo that holds a placeholder for half a second
          // starts its load inside the settle, on fake time the real loop never
          // sees, and is judged with the load still in flight. Measured on
          // `demo/vector_smoke.dart` — the entry pointing at an asset that does
          // not exist was reported clean, because the read that would have thrown
          // never completed. So the settle lands announced work as it goes, out
          // of the same purse as the landing after it.
          //
          // Only the last settle's answer is kept, because the picture is of the
          // screen that settle left.
          var pending = const <String, Object?>{};
          Future<bool> settleBy(Settle policy) async {
            var budget = RealWorkBudget(trackedWait: auditTrackedWait);
            // Only tracked work between the policy's frames. What else is
            // announced may be waiting for the clock those frames move — an
            // image provider that sleeps before it decodes — and is landed
            // below, once the clock has been spent.
            var settled = await policy.apply(
              tester,
              land: () => budget.land(tester, assets, untracked: false),
            );
            var result = await landRealWork(
              tester,
              policy,
              settled: settled,
              budget: budget,
              assets: assets,
            );
            pending = result.landed ? const {} : pendingRealWork(assets);
            return result.settled;
          }

          Future<void> settle() => settleBy(auditSettle);

          await settle();

          // Axes before knobs, exactly as the guest applies them: an axis
          // rebuilds the *shell*, which changes what the demo is handed, so a
          // knob turned first would be read back against the wrong build.
          //
          // And both after the first settle rather than before the pump: a knob
          // does not exist until the demo has asked for it, and an axis until
          // the shell has declared it. There is nothing to apply to a tree that
          // has not built.
          if (axisValues != null && CatalogAxes.instance.apply(axisValues)) {
            await settle();
          }
          if (knobValues != null &&
              CatalogKnobs.instance.applyAll(knobValues)) {
            await settle();
          }
          // The drive verbs, on this test's clock: after the values, because a
          // step acts on the entry as it was configured, and before the
          // reveal, because a `--node` crops what the steps left.
          //
          // **Settled by frames, not by the audit's clock.** The audit spends
          // five seconds on every settle so an entry waiting on a timer is
          // judged after it fires; after a step that would dismiss the very
          // thing the step opened — a `SnackBar` is gone at four.
          var stepped = <Map<String, Object?>>[];
          Map<String, Object?>? stepRefused;
          if (steps != null && steps.isNotEmpty) {
            driven = Drive.on(
              TesterLane(
                tester,
                settle: (budget) => settleBy(Settle.upTo(budget)),
              ),
            )..settleBudget = stepSettle;
            for (var (index, step) in steps.indexed) {
              try {
                stepped.add((await runWireVerb(driven, step)).toJson());
              } on TargetError catch (error) {
                stepRefused = {
                  'index': index,
                  'error': error.message,
                  'failure': error.failure.name,
                };
                break;
              } on ArgumentError catch (error) {
                stepRefused = {'index': index, 'error': '${error.message}'};
                break;
              } on FormatException catch (error) {
                stepRefused = {'index': index, 'error': error.message};
                break;
              }
            }
          }
          // After the steps, which may have opened what is to be seen whole,
          // and before the reveal, which then has nothing left to scroll.
          // Settled the way a step is, by frames: the rows that came on
          // screen are drawn with what they asked for, and whatever a step
          // opened is still open.
          Grown? grown;
          if (full) {
            var view = tester.view;
            var ratio = view.devicePixelRatio;
            var height = view.physicalSize.height / ratio;
            grown = await growToContent(
              () => CatalogGuest.demoRoot,
              height: height,
              resize: (height) async {
                view.physicalSize = Size(
                  view.physicalSize.width,
                  (height * ratio).roundToDouble(),
                );
                await tester.pump();
              },
              settle: () => settleBy(Settle.upTo(stepSettle)),
              maxHeight: height * fullScreens,
            );
          }
          // After the values, which can change what is on the list, and before
          // the tree and the picture, so both are of the screen with the node
          // on it — the host crops to the id this reports, not to the one it
          // asked with.
          Reveal? revealed;
          if (reveal != null) {
            revealed = await revealNode(
              GuestInspector(
                rootOf: () => CatalogGuest.demoRoot,
                entryIdOf: () => entry.id,
              ),
              reveal,
              pump: () => tester.pump(),
              settle: settle,
            );
          }
          if (declared != null) {
            var view = tester.view;
            declared[entry.id] = {
              // **What it actually rendered on**, read off the binding rather
              // than echoed back from the request. A staging that silently did
              // not land is the one failure a caller cannot otherwise see: every
              // other answer — the knobs, the errors, even a picture — looks
              // exactly the same on the wrong surface as on the right one.
              'viewport': {
                'width': view.physicalSize.width,
                'height': view.physicalSize.height,
                'pixelRatio': view.devicePixelRatio,
              },
              // What the *settled* build declares, which is not what it started
              // with: turning one knob can reveal or retire another, and only
              // the set that survived is worth reporting.
              if (wantKnobs) 'knobs': CatalogKnobs.instance.describe().toJson(),
              if (wantAxes) 'axes': CatalogAxes.instance.describe().toJson(),
              // Answered whenever it was asked, moved or not, so a reply
              // without it is a harness that predates the argument rather
              // than a node that was already on screen.
              'reveal': ?revealed?.toJson(),
              // The same rule: answered whenever asked, grown or not.
              'grown': ?grown?.toJson(),
              if (stepped.isNotEmpty) 'steps': stepped,
              'stepRefused': ?stepRefused,
            };
            // **Inline, and the same walk the guest answers with.** A tree is
            // tens of kilobytes for one entry and the guest's own
            // `ext.flutterware.tree` hands one back over the service too, so
            // this is the established size rather than a new one. The
            // catalog-wide lane still writes to disk beside the frame, because
            // there it is a tree per entry.
            if (wantTree || at != null) {
              var read = GuestInspector(
                rootOf: () => CatalogGuest.demoRoot,
                entryIdOf: () => entry.id,
              );
              if (wantTree) declared[entry.id]!['tree'] = read.read().toJson();
              // Against the tree above, by construction: a hit resolved against
              // a second read would be ids from one build reported beside boxes
              // from another.
              if (at case (var x, var y)?) {
                declared[entry.id]!['hits'] = read.hitTest(x, y);
              }
            }
          }

          // After the settle, so the picture is of the same screen the errors
          // are about. An entry whose build threw is photographed anyway — the
          // ErrorWidget is what is there — and the host decides whether that
          // picture is worth comparing.
          // Parks the playhead before the one picture is taken. A screenshot
          // asked for at `t` and rendered at zero is wrong in the one way
          // nothing catches, which is what this lane did until now.
          if (walk == null && motionT != null) {
            var scope = _defaultScope();
            await _seek(tester, _playheadDuration(scope) * motionT, scope);
          }
          if (output != null && walk != null) {
            captured?[entry.id] = {
              ...await _walk(
                tester,
                entry,
                walk,
                output,
                assets: assets,
                pixelRatio: pixelRatio,
                timings: timings,
                format: format,
              ),
            };
          } else if (output != null) {
            captured?[entry.id] = {
              ...await _capture(
                tester,
                entry,
                output,
                index,
                pixelRatio: pixelRatio,
                tree: tree,
                timings: timings,
                format: format,
              ),
              // The walk above says this per frame. A still has one frame, and
              // until this it said nothing: a capture that gave up on a load
              // looked exactly like one that finished.
              if (pending.isNotEmpty) 'pending': pending,
            };
          } else if (pending.isNotEmpty) {
            // No picture was asked for — an audit — and the same wait gave up
            // all the same. Without this the audit passed an entry the
            // comparison refuses to compare.
            captured?[entry.id] = {'pending': pending};
          }
        } finally {
          // A mouse a step parked is the binding's, not the tree's, and this
          // process renders the next entry on the same binding: left there, it
          // would hover whatever that entry draws under the same point.
          if (driven?.hovering != null) {
            await driven!.unhover(hold: Duration.zero, settle: Duration.zero);
          }
          driven?.dispose();
          FlutterError.onError = previous;
          debugDisableShadows = priorShadows;
          // Inside the body, never a tearDown: the binding verifies its debug
          // variables at the end of the body, and a reset filed as a tearDown
          // fails the test it was meant to clean up after.
          reset();
          collect?[entry.id] = GuestErrors.instance.describe();
        }
        // Nothing is taken from the binding on purpose. An entry that reported
        // anything leaves it pending, and a pending exception is what fails this
        // test — which is the whole answer in the `flutter test` lane, and one
        // more way of saying it in the driven one.
      });
    });
  }
}

/// A walk of one entry's playhead, as the request spells it.
///
/// A section of its own rather than extra keys on a capture, because a walk is
/// a different question: a capture asks what the settled screen looks like, and
/// this asks what the screen looks like at each of a list of moments.
class _Walk {
  const _Walk({this.stops, this.scope, this.timed = false, this.fps = 30});

  /// Playhead positions, 0..1, **in the order given**, or null for the whole
  /// motion at [fps] — which only the mounted motion can work out. See [_walk].
  final List<double>? stops;

  /// Which mounted scope to drive; the only one when null.
  final String? scope;

  /// Whether a stop also advances the clock by one frame. See [_walk].
  final bool timed;

  final int fps;

  static _Walk? fromJson(Object? json) {
    if (json is! Map) return null;
    var raw = '${json['stops'] ?? ''}';
    var stops = [
      for (var part in raw.split(','))
        if (part.trim().isNotEmpty) double.parse(part.trim()),
    ];
    return _Walk(
      stops: stops.isEmpty ? null : stops,
      scope: json['scope'] as String?,
      timed: json['mode'] == 'time',
      fps: switch (json['fps']) {
        int value when value > 0 => value,
        _ => 30,
      },
    );
  }

  /// What one stop is worth on the clock.
  Duration get frame => Duration(microseconds: 1000000 ~/ fps);
}

/// The playhead to drive when the caller named none — the first mounted one,
/// so a screen that mounts two still renders rather than refusing.
String? _defaultScope() => PlayheadRegistry.instance.defaultId;

/// Park the mounted playhead and let the frame it asks for happen.
///
/// The one thing the harness needs from whatever is animating, and the whole
/// of what it knows about it: the scene runtime and any other implementer of
/// [Playhead] are equally drivable here.
Future<void> _seek(
  WidgetTester tester,
  Duration position,
  String? scope,
) async {
  var playhead = PlayheadRegistry.instance.resolve(scope);
  if (playhead == null) {
    var mounted = PlayheadRegistry.instance.ids.toList();
    throw StateError(
      scope == null
          ? 'nothing on this screen has a playhead to walk — mount a scene, '
                'or register one'
          : 'no playhead "$scope" on this screen. Mounted: '
                '${mounted.isEmpty ? 'none' : mounted.join(', ')}',
    );
  }
  playhead.seek(position);
  await tester.pump();
}

Duration _playheadDuration(String? scope) =>
    PlayheadRegistry.instance.resolve(scope)?.duration ?? Duration.zero;

/// How many zero-duration frames a stop is given to *apply* its playhead.
///
/// Structural work only — no time passes in any of them — so this bounds a
/// chain of post-frame callbacks rather than a transition. Two is enough for
/// the `jumpTo` shape that motivated it; the rest is room.
const _applyPlayheadFrames = 6;

/// Photographs the playhead at each of [walk]'s stops, in order.
///
/// **This is the whole reason export lives on this lane.** There is no wire
/// and no second thread: the playhead is parked and pumped, and
/// `toImage` rasterises the layer tree *that pump produced*. A frame cannot be
/// of a moment other than the one just built. The embedder cannot say that —
/// it advances the playhead on the UI thread and writes whatever its
/// rasteriser presents, and measured over six trials the same walk came out
/// differently in four of them.
///
/// Two clocks, because two kinds of screen ask for different things:
///
///   * **playhead** — set `t`, draw. No time passes, so the picture is
///     `evaluate(t)` and nothing else. Right for a scene, and the order of the
///     stops cannot matter, which is what makes a walk verifiable by taking it
///     backwards.
///   * **timed** — set `t`, then let exactly one frame of [_Walk.fps] elapse.
///     A `Ticker`, an implicit animation or a scroll simulation then advances
///     by exactly that much rather than by however long the machine took. This
///     is what a fake clock buys and a real-time renderer cannot: the
///     alternatives forbid such screens instead of rendering them.
///
/// Real work is a separate axis from the fake clock and is waited for in both
/// modes — an image or a fetch genuinely in flight blocks the shutter rather
/// than being photographed half-arrived.
Future<Map<String, Object?>> _walk(
  WidgetTester tester,
  PreviewEntry entry,
  _Walk walk,
  String output, {
  required ScenarioAssetBundle assets,
  double pixelRatio = 1,
  bool timings = false,
  String format = 'raw',
}) async {
  // The first mounted scope when none was named, which is what the guest's
  // seek does — a demo that mounts two would otherwise start refusing every
  // clip it used to render. Which one was driven is reported, so a caller can
  // see there were others rather than discover it in the picture.
  var mounted = PlayheadRegistry.instance.ids.toList();
  var scope = walk.scope ?? _defaultScope();
  var durationMs = _playheadDuration(scope).inMilliseconds;
  // The whole motion when the caller did not say: it could not have, because
  // the duration is the running motion's and nobody outside it knows.
  var stops = walk.stops ?? videoStops(durationMs: durationMs, fps: walk.fps);
  var frames = <Map<String, Object?>>[];
  for (var (index, t) in stops.indexed) {
    await _seek(
      tester,
      Duration(microseconds: (durationMs * 1000 * t).round()),
      scope,
    );
    // **Let the screen finish applying the playhead, without letting time
    // pass.** A screen that reads `t` during build and then moves something
    // else from a post-frame callback — a flow driven by `PageView.jumpTo` is
    // the everyday one — shows the *previous* position on the frame that moved
    // the playhead. On a real clock that is unfixable without guessing how
    // many frames to allow, which is what `framesPerStop` was.
    //
    // Here it costs nothing to be exact. A zero-duration pump runs layout,
    // post-frame callbacks and a rebuild, and advances **no** animation at
    // all, because a `Ticker` moves on elapsed time and none elapses. So this
    // drains structural work and cannot overshoot into a transition. It stops
    // the moment a ticker is what is asking for frames, since that will not
    // converge and is the other mode's business.
    var guard = 0;
    while (tester.binding.hasScheduledFrame &&
        SchedulerBinding.instance.transientCallbackCount == 0 &&
        guard++ < _applyPlayheadFrames) {
      await tester.pump(Duration.zero);
    }
    if (walk.timed) await tester.pump(walk.frame);
    // The shutter waits for work that is genuinely on its way, which is this
    // lane's answer to photographing a loading state. Announced work only —
    // never a settle to quiet, which in `timed` would run an animation to its
    // end inside a frame that is supposed to be a thirtieth of a second.
    //
    // A purse per stop, like a scenario's per step: a frame that waited out a
    // slow decode must not leave the next one with less allowance than it
    // needs for its own.
    var budget = RealWorkBudget();
    var landed = await budget.land(tester, assets);
    // An image that arrived during the wait has not been painted yet.
    if (tester.binding.hasScheduledFrame) await tester.pump(Duration.zero);
    frames.add({
      ...await _capture(
        tester,
        entry,
        output,
        index,
        pixelRatio: pixelRatio,
        tree: false,
        timings: timings,
        format: format,
      ),
      // Carried rather than inferred from position downstream: pairing a frame
      // with a stop by position is the assumption that made the other lane
      // wrong.
      't': t,
      // Reported rather than thrown: one stop that timed out on a decode is a
      // fact about that frame, and the caller can decide whether a clip with
      // it in is worth having.
      if (!landed) 'pending': true,
    });
  }
  return {
    'walk': frames,
    'durationMs': durationMs,
    'scope': ?scope,
    if (mounted.length > 1) 'scopes': mounted,
  };
}

/// Photographs the settled screen into [output] and reads the tree it drew,
/// answering with the paths and the picture's dimensions.
///
/// **[pixelRatio] is physical pixels per logical pixel, not a fraction of the
/// screen** — the same word `FrameCapture` uses on the guest side, so the two
/// backends are asked for a resolution in one vocabulary. The default of `1`
/// therefore renders a 3× phone at its *logical* 440×956, which is right for a
/// comparison diffing pixels and for a thumbnail nobody reads text in, and
/// wrong for a picture somebody is going to judge a 16pt glyph in: that one
/// passes the staged device's own ratio and gets 1320×2868. The rect is
/// physical and the output logical-times-this, which is also the scenario
/// rule: the root layer's coordinates have the device-pixel-ratio transform
/// inside them, so a 3× canvas captured at face value saves its top-left
/// ninth.
Future<Map<String, Object?>> _capture(
  WidgetTester tester,
  PreviewEntry entry,
  String output,
  int index, {
  double pixelRatio = 1,
  bool tree = true,
  bool timings = false,
  String format = 'raw',
}) async {
  var png = format == 'png';
  var directory = Directory(output)..createSync(recursive: true);
  var imagePath = p.join(directory.path, '$index.${png ? 'png' : 'raw'}');
  var treePath = p.join(directory.path, '$index.tree.json');
  var width = 0;
  var height = 0;
  var drawnAt = pixelRatio;
  var bytes = 0;
  var toImageUs = 0;
  var bytesUs = 0;
  var writeUs = 0;
  var treeUs = 0;
  // A real-async turn, like the scenario capture: `toImage` completes on the
  // real event loop, which fake time never runs.
  await tester.runAsync(() async {
    var watch = Stopwatch()..start();
    var view = tester.binding.renderViews.single;
    var layer = view.debugLayer! as OffsetLayer;
    var dpr = view.flutterView.devicePixelRatio;
    // Lowered where it is said rather than past the texture where it is
    // not — see [maxPictureSide]. Only a `--full` screen is ever this tall.
    // A pixel short, so the rounding up of the size cannot cross it.
    drawnAt = math.min(
      pixelRatio,
      (maxPictureSide - 1) / math.max(view.size.width, view.size.height),
    );
    var image = await layer.toImage(
      Offset.zero & (view.size * dpr),
      pixelRatio: drawnAt / dpr,
    );
    toImageUs = watch.elapsedMicroseconds;
    watch.reset();
    var data = (await image.toByteData(
      format: png ? ui.ImageByteFormat.png : ui.ImageByteFormat.rawRgba,
    ))!;
    bytesUs = watch.elapsedMicroseconds;
    watch.reset();
    width = image.width;
    height = image.height;
    image.dispose();
    File(imagePath).writeAsBytesSync(data.buffer.asUint8List());
    writeUs = watch.elapsedMicroseconds;
    bytes = data.lengthInBytes;
  });
  // The same walk every other surface answers with, so the comparison's tree
  // diff reads the identical shape a live guest or a scenario step reports.
  if (tree) {
    var watch = Stopwatch()..start();
    var read = GuestInspector(
      rootOf: () => CatalogGuest.demoRoot,
      entryIdOf: () => entry.id,
    ).read();
    File(treePath).writeAsStringSync(jsonEncode(read.toJson()));
    treeUs = watch.elapsedMicroseconds;
  }
  // **What each stage costs, measured on this repo's 154 previews.** Against a
  // median entry that takes 43ms to *render*, the picture is close to free and
  // the two things beside it are not:
  //
  //     tree.json                 9.07ms   — nine times the picture
  //     png encode, 1x           12.46ms      36kb
  //     png encode, 700px         7.77ms      27kb
  //     png encode, quarter       1.07ms       4kb
  //     raw, any ratio            0.11ms     152kb at quarter, 2444kb at 1x
  //
  // Which is the whole argument for both options. [tree] is 9ms nobody looking
  // at a picture wants. [format] trades about 8ms of encode for **38× less
  // disk** — a whole catalog is 4MB as PNG against 368MB as raw — so a store
  // that keeps thumbnails keeps them as PNG, and a comparison, which diffs
  // pixels and would decode straight back out, keeps raw. [pixelRatio] barely
  // moves the clock either way; it moves the bytes — as the square of itself,
  // which is why a 3× device is 9× the frame.
  if (timings) {
    stderr.writeln(
      '[capture] toImage=$toImageUs bytes=$bytesUs write=$writeUs '
      'tree=$treeUs kb=${bytes ~/ 1024}',
    );
  }
  return {
    'image': imagePath,
    'format': png ? 'png' : 'raw',
    'width': width,
    'height': height,
    // Said only when it is not what was asked for, which is only when the
    // picture would not fit a texture.
    if (drawnAt != pixelRatio) 'pixelRatio': drawnAt,
    if (tree) 'tree': treePath,
  };
}
