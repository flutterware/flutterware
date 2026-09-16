import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../bytes.dart';
import '../clock.dart';
import '../flutter_gpu_diagnosis.dart';
import '../drive/resolve.dart';
import '../translations/index.dart';
import 'aim.dart';
import 'asset_bundle.dart';
import 'async_watchdog.dart';
import 'film.dart';
import '../app_events/events.dart';
import '../devices.dart';
import 'keyboard.dart';
import 'motion.dart';
import 'network.dart';
import 'notification.dart';
import 'profile.dart';
import 'progress.dart';
import 'real_work.dart';
import 'run_args.dart';
import 'run_listener.dart';
import 'settle.dart';
import 'reel.dart';
import 'stage.dart';
import 'stall.dart';
import 'shots.dart';
import 'staging.dart';
import 'target.dart';
import 'harness.dart' show scenarioFileSafe, scenarioNameMax;

/// A scenario: a widget test with per-step screenshots.
///
/// `scenario` is `testWidgets` plus a [ScenarioTester] — so every scenario is
/// an ordinary widget test, runnable by a bare `flutter test` with no daemon
/// and no GUI. Design: `docs/superpowers/specs/2026-07-30-scenarios-design.md`.
///
/// ```dart
/// scenario('Onboarding', (s) async {
///   await s.pumpWidget(MyApp());
///   await s.tap('NEXT');
///   await s.enterText('Email', 'x@example.com', shot: Shot('Filled form'));
///   await s.screen('Home');
///   expect(find.text('Done'), findsOneWidget);
/// });
/// ```
/// Collects the names `scenario()` declares, while the harness declares one
/// file.
///
/// The harness runs *every* declared test in the group it walks, and a
/// `test/scenarios/` folder may hold ordinary `testWidgets` too — which
/// produce no steps, cannot be opened in the panel, and were being run
/// invisibly. Knowing which tests are scenarios cannot be done by looking at
/// the built group (a test is a test), and reading it off the source would
/// mean the runner and the syntactic scan disagreeing about non-literal
/// names. Recording it as it is declared is the one answer that is true by
/// construction.
///
/// Null outside the harness, where nothing is collecting.
List<String>? scenarioDeclarationSink;

/// The file whose `main()` is declaring right now, or null outside the
/// harness.
///
/// Armed beside [scenarioDeclarationSink] and for the same reason: under the
/// runner one process declares every file, so nothing a scenario knows about
/// itself is unique to it. A description is not — two files may each hold a
/// `scenario('Home')`, and anything this package keys on the description alone
/// silently treats them as one scenario. The standalone lane needs no such
/// thing, because `flutter test` gives each file its own process.
String? scenarioAmbientFile;

/// What a scenario that names no [Timeout] of its own gets.
///
/// Null here, so a bare `flutter test` keeps `flutter_test`'s answer. The
/// harness sets it at startup, because `testWidgets` stamps every test with the
/// binding's ten minutes and a runner that wants its own deadline has no other
/// way to say so — the metadata it reads back cannot tell a default apart from
/// an author who wrote ten minutes on purpose.
Timeout? scenarioDefaultTimeout;

@isTest
void scenario(
  String description,
  Future<void> Function(ScenarioTester s) body, {
  Shots? shots,
  Settle? settle,
  bool? skip,
  Timeout? timeout,
  Object? tags,
  ScenarioNetwork? network,
  ScenarioReelEdit? reel,
}) {
  // Captured as the scenario is *declared*, not read when it runs: a matrix
  // declares this same body once per assignment, and each declaration keeps
  // the one it was made under.
  var assignment = scenarioAmbientAssignment;
  // The folder's policy, where a `runScenarios(shots: ...)` set one — read
  // here for the same reason, and beaten by anything this scenario said for
  // itself. Nobody having spoken is `auto`, which is what it always was.
  var policy = shots ?? scenarioAmbientShots ?? Shots.auto;
  // The folder's settle policy, read here for the reason the shots policy
  // is. Nobody having spoken is the bounded default.
  var settling = settle ?? scenarioAmbientSettle ?? Settle.standard;
  // How this scenario is cut as a reel, captured here for the reason the
  // settle policy is. Null is "nobody wrote one", which a reel render reads
  // as the stock edit — the plain film never reads it at all.
  var edit = reel ?? scenarioAmbientReel;
  // The folder's keyboard policy, captured as this scenario is declared for
  // the reason the shots policy is: a matrix declares one body once per
  // assignment, and each declaration keeps what it was made under. On unless
  // the folder said otherwise — see [scenarioAmbientKeyboard] for what off
  // restores.
  var keyboard = scenarioAmbientKeyboard ?? true;
  // The folder's shadow policy, captured here for the reason the keyboard is.
  // On unless the folder said otherwise — see [runScenarios] for what
  // `flutter_test`'s own default paints instead, and what it buys.
  var shadows = scenarioAmbientShadows ?? true;
  // The folder's network policy, captured here for the reason the two above
  // are — and *only* the folder's. The rest of the ladder is resolved when the
  // body runs, in [_reachOf]: under the runner, `scenarioRunArgs` is armed per
  // scenario inside the walk, long after this function has run for every file,
  // so a `--network=` read here would always be null and the flag would be a
  // silent no-op. Two altitudes, two times, and each read where its answer
  // exists.
  var folderReach = scenarioAmbientNetwork;
  var name =
      scenarioAmbientIsMatrix && assignment != null && !assignment.isEmpty
      ? '$description [${assignment.label}]'
      : description;

  scenarioDeclarationSink?.add(name);

  // Only the standalone lane needs it, and only it pays for it: under the
  // runner the harness knows the file it generated the group from, and a suite
  // that configures no destination captures nothing to file at all.
  var source = ScenarioTester._screenshotsDestination == null
      ? null
      : scenarioDeclaringFile(StackTrace.current);

  // What the once-per-scenario network notices are remembered under. Built
  // here because both halves only exist here: the ambient file is armed around
  // this declaration and cleared before any body runs, and a matrix declares
  // one body once per point — all of them under this one description, which is
  // what makes a matrix say it once rather than once per axis.
  var noticeKey = '${source ?? scenarioAmbientFile ?? ''}\u0000$description';

  testWidgets(
    name,
    skip: skip,
    // Under the harness the declared timeout is a progress deadline the
    // harness keeps itself, and `test_api`'s own timer — which knows nothing
    // about progress — is switched off so it cannot fire first. A bare
    // `flutter test` has no harness, and keeps the timeout as written.
    timeout: scenarioDefaultTimeout == null ? timeout : Timeout.none,
    tags: tags,
    (tester) async {
      if (scenarioDefaultTimeout case var fallback?) {
        scenarioDeclaredTimeout = timeout ?? fallback;
      }
      // Always pinned to something, and to [pinnedClockOrigin] unless somebody
      // said otherwise — a run whose date is "whenever it happened" cannot be
      // compared with the next one, which is what every surface reading these
      // captures is for. `--clock now` and `FW_CLOCK=now` are how a run asks
      // for the wall clock back; both resolve to an instant before they get
      // here, so what ran is always a date somebody could write down.
      //
      // Except on the real clock, where nothing is compared and the backend
      // answers with today's dates: there the wall clock is the clock, and a
      // pin applies only when the run itself asked for one.
      Future<void> scenarioBody() => _runScenario(
        tester,
        description,
        body,
        policy,
        settling,
        assignment,
        source,
        keyboard,
        shadows,
        _reachOf(network, folderReach, description, noticeKey),
        statedNetwork: network != null,
        noticeKey: noticeKey,
        edit: edit,
      );
      var origin = resolvedScenarioClockOrigin;
      if (origin == null) return scenarioBody();
      // Pinned, but still ticking with FakeAsync: the offset from where this
      // scenario's fake clock started is what `s.wait` moves, so a flow that
      // waits a day still reads a day later — from a date that is the same on
      // every run.
      var started = tester.binding.clock.now();
      return withClock(
        Clock(() => origin.add(tester.binding.clock.now().difference(started))),
        scenarioBody,
      );
    },
  );
}

/// The test file a `scenario()` call was made from, `/`-separated and relative
/// to the package when it sits under it, or null when the frame says nothing.
///
/// Read off the declaring stack because nothing else can say it: a bare
/// `flutter test` tells a test nothing about which file it is, and a scenario
/// must not have to repeat its own path to get its screenshots filed under it.
/// The runner's lane never asks — the harness generated the group and knows.
@visibleForTesting
String? scenarioDeclaringFile(StackTrace stack) {
  for (var line in stack.toString().split('\n')) {
    var location = _frameLocation.firstMatch(line)?.group(1);
    if (location == null) continue;
    // This library's own frames sit above the caller — `scenario()` itself,
    // and anything it is reached through — whether the runtime spells them as
    // a package uri or as a path into a checkout.
    if (location.endsWith('flutterware/src/scenarios/scenario.dart') ||
        location.endsWith('flutterware/lib/src/scenarios/scenario.dart')) {
      continue;
    }
    var uri = Uri.tryParse(location);
    if (uri == null || uri.scheme != 'file') return null;
    var path = uri.toFilePath();
    var root = Directory.current.path;
    return p.url.joinAll(
      p.split(p.isWithin(root, path) ? p.relative(path, from: root) : path),
    );
  }
  return null;
}

/// The `(uri:line:column)` a stack frame ends with, in either of the two
/// spellings a Dart trace uses.
final _frameLocation = RegExp(r'\((.+?\.dart):\d+(?::\d+)?\)\s*$');

/// What `clock.now()` reads at the start of every scenario: what the runner
/// asked for, else what the host said, else [pinnedClockOrigin].
///
/// Null only on the real clock with nobody asking — see [pinnedClockOrigin]
/// for why the fake-time default is a date rather than the wall clock, and
/// why a live run has no such default: its backend answers with today, and a
/// pin would put the app on a day the server disagrees with. Read by the
/// harness too, so a run can *report* the clock it ran under: a pinned date
/// is only safe while it is stated, since an app with a trial expiry or a
/// seasonal theme sits in a different state under one and nothing on the
/// screen says why.
DateTime? get resolvedScenarioClockOrigin =>
    scenarioRunArgs?.clockOrigin ??
    _scenarioClockOrigin ??
    (scenarioHarnessTime.isReal ? null : pinnedClockOrigin);

/// What the host said the clock should be, or null when it said nothing —
/// a dart-define first, then the environment, the same pair
/// `screenshots-destination` uses.
///
/// `now` is the wall clock, spelled out loud: it resolves to an instant here,
/// so the run still reports a date somebody could write down and re-run with.
DateTime? get _scenarioClockOrigin {
  const define = String.fromEnvironment('fw.clock');
  var raw = define.isNotEmpty ? define : Platform.environment['FW_CLOCK'];
  if (raw == null || raw.isEmpty) return null;
  return raw == 'now' ? DateTime.now() : DateTime.parse(raw);
}

/// What the run said its http requests reach, or null when it said nothing.
///
/// The runner's request first, then the pair every other "the host tells the
/// test process something" setting reads — a `fw.network` dart-define, then
/// `FW_NETWORK` — which is how the bare `flutter test` lane, that reads no
/// request and no manifest, is told at all.
ScenarioNetwork? get resolvedScenarioNetwork =>
    scenarioRunArgs?.network ?? _scenarioNetworkFromHost;

/// What one scenario's http requests reach, resolved as it runs.
///
/// Nearest wins, and a run sits in the middle of the ladder rather than at the
/// top of it: an explicit `--network=` overrules the folder and the project,
/// and is itself overruled by what a scenario said about itself. [own] is the
/// `scenario(network: ...)` and [folder] the `runScenarios(network: ...)`,
/// both captured at declaration; the middle two are read here because they are
/// not armed until the walk reaches this scenario.
///
/// One losing combination says so out loud — see [recordOverriddenMessage].
ScenarioNetwork _reachOf(
  ScenarioNetwork? own,
  ScenarioNetwork? folder,
  String scenario,
  String noticeKey,
) {
  var run = resolvedScenarioNetwork;
  var reach =
      own ??
      run ??
      folder ??
      scenarioProjectNetwork ??
      // `off` under the fake clock, `live` under the real one: the
      // determinism `off` protects is already spent once the timers are real.
      (scenarioHarnessTime.isReal ? ScenarioNetwork.live : ScenarioNetwork.off);
  if (recordOverriddenMessage(scenario, own, run) case var said?
      when _recordOverridesSaid.add(noticeKey)) {
    stderr.writeln('[flutterware] $said');
  }
  return reach;
}

/// The sentence a scenario whose steps depended on the machine's speed owes
/// its author, or null when none did.
///
/// Said as the scenario ends rather than failed on, and the same under the
/// runner and a plain `flutter test`: a step that is right only because the
/// real loop turned fast enough is a flaky expectation on a slower machine as
/// much as it is a changed picture. It states the hazard and nothing more —
/// what to do about it depends on what the work is.
String? guessedLandingNotice(String scenario, Map<String, int> guessed) {
  if (guessed.isEmpty) return null;
  String step(String label, int turn) =>
      '`${label.isEmpty ? 'the first frame' : 's.$label'}` '
      '(turn $turn of $realWorkTurns)';
  var steps = [
    for (var MapEntry(key: label, value: turn) in guessed.entries)
      step(label, turn),
  ];
  return '"$scenario": ${steps.join(', ')} finished drawing only after '
      'turns of the real event loop, on work nothing announced. On a slower '
      'machine that work can land after the step has moved on.';
}

/// Which scenarios have already had their overruled `record` reported.
///
/// Keyed on the file *and* the description, not the description alone: the
/// harness declares every file in one process, so two files each holding a
/// `scenario('Home')` would otherwise be one entry here and the second would
/// go unreported. Keyed rather than counted so that a matrix — which declares
/// one body once per point, all under one description — says it once rather
/// than once per axis.
final _recordOverridesSaid = <String>{};

/// The sentence a `record` run owes [scenario], or null when nothing is wrong.
///
/// The one losing combination in the ladder worth interrupting for, because it
/// is the only one where nothing on the screen and nothing in the output says
/// what happened: the suite passes, every picture is the one `replay` already
/// had, and the store the run was for stays exactly as it was. Every other
/// pairing shows itself — a scenario keeping `off` against a `live` run draws
/// the blank image and reports the refusal on the step.
///
/// A message rather than a rule. Letting `record` reach past [own] would put a
/// special case inside a precedence ladder, and a ladder with an exception in
/// it is what was misread here to begin with — it would also start recording
/// for a scenario that deliberately said `live`.
@visibleForTesting
String? recordOverriddenMessage(
  String scenario,
  ScenarioNetwork? own,
  ScenarioNetwork? run,
) {
  if (run != ScenarioNetwork.record) return null;
  if (own == null || own == ScenarioNetwork.record) return null;
  return '"$scenario" states `network: ${own.name}`, so this `record` run '
      'left it alone and wrote nothing for it. Nearest wins: a '
      '`scenario(network: ...)` is nearer than a run, and a run only reaches '
      'past a folder and the project. To record it, move the declaration up '
      'to the folder — `runScenarios(network: ...)` in '
      '`flutter_test_config.dart` — which is the altitude a `--network=` can '
      'reach.';
}

/// Which scenarios have already been told their stated mode did nothing.
/// Keyed like [_recordOverridesSaid].
final _inertNetworksSaid = <String>{};

/// Forgets which scenarios have already been warned about their network.
///
/// Said once per scenario, but "once" has to mean once per *run*. The harness
/// keeps a guest warm across many requests, so without this a suite re-run in
/// the same process is silent about a mis-wiring it reported the first time —
/// and the first time is the run nobody was reading. The bare `flutter test`
/// lane never calls it and never needs to: that process runs one suite.
void resetScenarioNetworkNotices() {
  _recordOverridesSaid.clear();
  _inertNetworksSaid.clear();
}

/// The sentence a scenario owes when it stated a mode and then asked for
/// nothing, or null.
///
/// A mode is a claim about what this scenario's requests reach, and zero
/// requests contradicts it. The usual cause is not the mode but the app: a
/// layer that answers before anything opens an `HttpClient` is a layer the
/// funnel cannot see, and the failure is silent in both directions — the
/// screen shows a broken-image placeholder and the suite goes green.
///
/// Only a `scenario(network: ...)` is held to this. A folder's
/// `runScenarios(network: ...)` and the project's `fw.network(...)` are
/// defaults over a whole suite, where most scenarios legitimately touch
/// nothing, and warning per scenario there would be dozens of lines saying
/// that a login flow did not fetch anything. Stating a mode on **one**
/// scenario is a sentence about that scenario, and this is what it means for
/// it to have turned out false.
@visibleForTesting
String? inertNetworkMessage(
  String scenario,
  ScenarioNetwork reach, {
  required bool stated,
  required int requests,
}) {
  if (!stated || requests > 0 || reach == ScenarioNetwork.off) return null;
  return '"$scenario" states `network: ${reach.name}` and then made no http '
      'request at all, so the mode did nothing. A request reaches the funnel '
      'only if something actually opens an `HttpClient`: `HttpOverrides` '
      "catches the app's own client and everything built on it — "
      '`package:http`, `dio` — and `NetworkImage` is caught alongside it. '
      'What is not caught is a layer that answers before opening one. A '
      '`CachedNetworkImage` is the common case: its bytes come from a '
      '`BaseCacheManager`, and the no-op manager a project writes because the '
      'real one cannot run on a test binding fails every url without opening '
      'anything. A manager whose `getFileStream` is a plain `HttpClient` '
      'passthrough is caught like everything else.';
}

ScenarioNetwork? get _scenarioNetworkFromHost {
  const define = String.fromEnvironment('fw.network');
  var raw = define.isNotEmpty ? define : Platform.environment['FW_NETWORK'];
  if (raw == null || raw.isEmpty) return null;
  return parseScenarioNetwork(raw);
}

Future<void> _runScenario(
  WidgetTester tester,
  String description,
  Future<void> Function(ScenarioTester s) body,
  Shots shots,
  Settle settle,
  ScenarioAssignment? assignment,
  String? source,
  bool wantsKeyboard,
  bool wantsShadows,
  ScenarioNetwork reach, {
  required bool statedNetwork,
  required String noticeKey,
  ScenarioReelEdit? edit,
}) async {
  // The runner's assignment wins, like its args do below: the declaration
  // captured the ambient one, which under the runner is null — and a body
  // reading `s.assignment?.language` has to see the language the request
  // named, the same as it would under `flutter test` with `FW_LANGUAGES`.
  assignment = scenarioRunArgs?.assignment ?? assignment;
  var restore = _applyRunArgs(tester, assignment);
  var restoreErrors = _installExpansionOverflowFilter();
  // **The measurement, read off the device the run is staged as.** Zero when
  // the folder turned the keyboard off, when the run is staged on nothing, and
  // on every desktop size — and zero is the whole of "off": no insets, no
  // slab, and no refusal for a target under a band that is not there.
  //
  // One driver for the scenario, not one per replay: a split's branches share
  // a tester and a view, so a keyboard raised on the first path has to be put
  // back before the second one starts.
  var keyboard = ScenarioKeyboard(
    tester,
    device: assignment?.orientedDevice,
    enabled: wantsKeyboard,
  );
  // Whatever the scenario before this one left memoized on `rootBundle`
  // belongs to *its* FakeAsync zone. A read still in flight when that scenario
  // ended can never complete again — nothing will ever flush that zone — and
  // this scenario awaiting it waits forever. Cleared at the top rather than at
  // the bottom, so a run also survives whatever ran before the first scenario:
  // the harness loads the app's fonts through `rootBundle` at startup.
  rootBundle.clear();
  // The same shape one counter further out: the image cache is process-wide
  // and `testWidgets` never empties it, so a scenario that ended with a decode
  // still in flight would have this one waiting out its whole allowance on
  // work that is not its own.
  resetAnnouncedWork();
  // And what a deadline would quote: the previous scenario's unanswered
  // sends and last verb are its own.
  resetStallFacts();
  // The iOS caret blinks through an `AnimationController`, not a timer, so on
  // an iOS-staged device every screen with a focused field is asking for a
  // frame forever, and no settle policy can tell that from a spinner.
  // [Settle.upTo] gets away with it — the controller runs a one-second
  // simulation and restarts on a `Timer.zero`, so the loop finds its quiet
  // frame at the blink boundary. The two policies that do not stop there do
  // not: [Settle.elapse], which is what a boot-time pump spends, and
  // [Settle.none] land wherever the blink happens to be, and the step reports
  // `settled: false` on the phase of an animation nobody is waiting for. The
  // pixels move with it too — enough for a `screen` to refuse to adopt its
  // verb's frame and emit a second step instead. Determinism here is this
  // harness's, the same as the fonts and the clock.
  var priorCursor = EditableText.debugDeterministicCursor;
  EditableText.debugDeterministicCursor = true;
  // `flutter_test` hard-codes this true and asserts at the end of the body
  // that nobody left it moved, so a folder that wants real shadows can only
  // have them for the length of a scenario — which is the length that paints.
  var priorShadows = debugDisableShadows;
  debugDisableShadows = !wantsShadows;
  var assets = ScenarioAssetBundle();
  // One policy for the scenario, shared by every replay of its splits the way
  // the bundle and the keyboard are — a real connection pool that a branch
  // rebuilt would leak, and one thing for the `finally` below to close.
  var network = ScenarioNetworkPolicy(reach);
  scenarioNetworkModesRun.add(reach);
  var restoreNetwork = installScenarioNetwork(network);
  // A film renders one scenario: a second one's frames would land in the same
  // directory and encode as one clip. Which scenario is the host's to select,
  // and this only refuses to guess.
  var film = switch (scenarioRunArgs?.film) {
    null => null,
    var settings => startFilm(
      settings,
      scenario: description,
      // The film pumps frames of its own between the verbs, and the software
      // keyboard moves on this hook — the same one every settle policy gives
      // it. Without it the slab stands still through a whole beat and arrives
      // after the typing it belongs to.
      beforePump: keyboard.step,
      reel: scenarioRunArgs?.reel,
      stage: scenarioRunArgs?.stage ?? const BareStage(),
      edit: edit,
      // What the cursor will be drawn as. A phone is touched and a window is
      // pointed at, and the stage already knows which this is.
      touch: switch (assignment?.orientedDevice?.platform) {
        DevicePlatform.macos ||
        DevicePlatform.windows ||
        DevicePlatform.linux => false,
        _ => true,
      },
    ),
  };
  _countFrames(tester);
  var state = _ReplayState(
    branches: film?.settings.branches,
    scenario: description,
  );
  // Under the runner only: every exception the binding sees goes into the
  // harness's buffer *before* the binding aggregates. Two exceptions in one
  // test otherwise reach the report as the sentence "Multiple exceptions (2)
  // were detected…" with no stack — the real ones exist only as console
  // dumps. Chained, not replaced: the binding's handler is what fails the
  // test, and it asserts at the end that it got its handler back.
  var caught = scenarioCaughtErrors;
  var priorOnError = FlutterError.onError;
  // Chained in **both** lanes, unlike the buffer it carries: `tester.runAsync`
  // reports its callback's failure here and returns null rather than
  // rethrowing it, so under `flutter test` this is the only place such a
  // failure passes through at all — and `flutter test` is the lane the
  // Flutter GPU diagnosis exists for.
  FlutterError.onError = (details) {
    // A refusal is already *on* the step, as a network event carrying the
    // whole message — so it is reported, and reporting it twice would be the
    // second report failing the scenario.
    //
    // Which it would: an `Image.network` with no `errorBuilder` has no error
    // listener of its own, so `MultiFrameImageStreamCompleter` hands the throw
    // to `FlutterError.reportError`, and in a test binding that is what turns a
    // test red. Left alone, `off` would fail every scenario with an
    // unguarded network image on screen — including the https ones that
    // silently drew a blank frame and passed before any of this existed, which
    // is precisely the upgrade nobody asked for.
    //
    // Only a refusal, and never a stub's own `throws:`: an author who wrote
    // `throws: SocketException(...)` is injecting an error on purpose and
    // wants it to behave like one.
    //
    // Outermost of the three handlers chained here, so it also keeps the
    // refusal out of the runner's caught-errors buffer — a scenario that did
    // not fail must not be reported with an error against it.
    if (details.exception is ScenarioNetworkRefusal) return;
    announceFlutterGpuDiagnosis(
      details.exceptionAsString(),
      executableArguments: Platform.executableArguments,
      macOS: Platform.isMacOS,
    );
    caught?.add(
      ScenarioCaughtError(
        details.exception,
        details.exceptionAsString(),
        details.stack,
      ),
    );
    priorOnError?.call(details);
  };
  try {
    // The split-replay loop: the body runs once per path through its
    // `split`s, depth-first — a body with none runs once. Every replay
    // starts from the top, so its `pumpWidget` rebuilds the app from
    // scratch; steps already captured on a shared prefix are recognised by
    // position and not captured again.
    var first = true;
    do {
      state.plan.beginRun();
      if (!first) {
        // Tear the tree down first: re-pumping the same app widget over
        // its previous self keeps every State alive — the navigator stack
        // included — and a replay must start from nothing.
        await tester.pumpWidget(const SizedBox.shrink());
        // With the tree goes the keyboard: the next branch starts from a fresh
        // app, and one left up would be over a form nobody has touched yet.
        keyboard.reset();
        // And with it the stated answers: each path through the splits states
        // its own from the top, so a branch must not inherit what the branch
        // before it said — nor read its requests back.
        network.resetForReplay();
      }
      first = false;
      var s = ScenarioTester._(
        tester,
        description,
        shots,
        settle,
        state,
        assignment,
        source,
        assets,
        keyboard,
        network,
        film,
      );
      // Reachable from outside the body while the body runs, for the one
      // reader that needs it there: the harness's deadline.
      scenarioFlushHeld = s._flushPending;
      scenarioBreakPlacement = s._breakPlacement;
      try {
        await body(s);
        s._flushPending();
        // The closing hold, once the body is through: a film that cut on the
        // frame its last verb happened to land on would end mid-gesture.
        await film?.close(tester);
      } catch (error, stack) {
        var inContext = s._inContext(error);
        // The binding reports this rethrow only after the body — after the
        // `finally` below has unchained the handler — so it has to be
        // buffered here, with the stack it actually broke on. Skipped when
        // the chain already saw this same object reported mid-body.
        if (caught != null &&
            !caught.any((c) => identical(c.exception, error))) {
          caught.add(ScenarioCaughtError(inContext, '$inContext', stack));
        }
        // One catch for the whole body, so every failure has a picture of
        // the frame it broke on — whatever raised it: a verb, a bare
        // `expect`, the app's own build. A capture that fails in turn is
        // swallowed: it may never mask what it was called about.
        try {
          await s._captureFailure(error);
        } catch (_) {}
        // A thrown failure never reaches `reportTestException`, so the
        // structured report's diagnosis does not reach a console. Said here
        // instead, once, the way the `runAsync` watchdog says its own.
        announceFlutterGpuDiagnosis(
          '$error',
          executableArguments: Platform.executableArguments,
          macOS: Platform.isMacOS,
        );
        // Rethrown with the original stack, so the report still points at
        // the user's line; only the message gains its split branch.
        Error.throwWithStackTrace(inContext, stack);
      }
    } while (state.plan.advance());

    if (guessedLandingNotice(description, state.guessed) case var said?) {
      stderr.writeln('[flutterware] $said');
    }

    if (inertNetworkMessage(
          description,
          reach,
          stated: statedNetwork,
          requests: network.requestsEver,
        )
        case var said?
        // Never on top of the override message. That is the more specific
        // reading of the same silence — the mode did nothing *because* a
        // record run could not reach it — and it already names the fix.
        when !_recordOverridesSaid.contains(noticeKey) &&
            _inertNetworksSaid.add(noticeKey)) {
      stderr.writeln('[flutterware] $said');
    }
  } finally {
    // Whatever happened — a film cut short by a failure is still a film, and
    // its timeline is what says how many frames there are and where they
    // stop. Never allowed to throw over the failure that got us here.
    if (film != null) {
      try {
        await film.finish(tester);
      } catch (error) {
        stderr.writeln('[flutterware] the film could not be written: $error');
      }
    }
    // Unconditional, because the chain above is: the binding asserts at the
    // end that it got its own handler back.
    FlutterError.onError = priorOnError;
    // Both before the body ends, not in a tearDown: the binding checks its
    // debug variables — and complains about a live semantics handle — at
    // the end of the body, before tearDowns run.
    state.disposeSemantics();
    EditableText.debugDeterministicCursor = priorCursor;
    debugDisableShadows = priorShadows;
    // Before the tearDowns for the reason the semantics handle is: the binding
    // asserts no timer is pending at the end of the body, and a live keepalive
    // connection holds one.
    restoreNetwork();
    restore?.call();
    restoreErrors?.call();
  }
}

/// Layout overflow errors swallowed since the last capture, drained per step
/// into [ScenarioStepCapture.overflowErrors]. Only ever counts under the
/// expansion filter below, so it stays zero on every ordinary run.
int _overflowsSinceLastCapture = 0;

/// The deepest turn of the real loop on which work nothing announced landed
/// since the last capture — see `landRealWork`'s `guessed` — drained per step
/// into [ScenarioStepCapture.guessed] the way the overflows are.
int? _guessedSinceLastCapture;

/// Under a budget probe, an overflow is the *measurement*, not a failure.
///
/// Every value on screen was just deliberately expanded, so a `RenderFlex`
/// running out of room is data the pass exists to collect — and left to the
/// binding it fails the scenario, which would make every fragile screen
/// unmeasurable past its first break. Installed inside the test body, over the
/// binding's own handler, and restored before the body ends; anything that is
/// not an overflow report still goes where it always went.
///
/// Design: `2026-08-19-translation-max-lengths-design.md`.
VoidCallback? _installExpansionOverflowFilter() {
  if (TranslationIndex.expandPercent == null) return null;
  var prior = FlutterError.onError;
  FlutterError.onError = (details) {
    // The one stable word in every "RenderFlex overflowed by … pixels"
    // report, and in its cousins (constrained boxes overflow the same way).
    if (details.exception.toString().contains('overflowed')) {
      _overflowsSinceLastCapture++;
      return;
    }
    prior?.call(details);
  };
  return () => FlutterError.onError = prior;
}

/// A failure raised inside a `split` branch, wrapping the real error with the
/// path that reached it — `'a cappuccino › large cup'`. Without it a failing
/// branch reports only the scenario's name, and which of the paths broke is
/// nowhere in the output.
class ScenarioFailure implements Exception {
  ScenarioFailure(this.branch, this.error);

  /// The split choices taken to reach the failure, outermost first.
  final List<String> branch;

  final Object error;

  String get path => branch.join(' › ');

  @override
  String toString() => 'in split branch "$path": $error';
}

/// A verb's target that names no widget, or several — raised before the
/// action rather than after, so the message can say what to do about it.
class ScenarioTargetError implements Exception {
  ScenarioTargetError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Frames drawn under the test binding since the process started.
///
/// Counted by a persistent frame callback registered **once per binding** —
/// they cannot be unregistered, and the harness runs thousands of scenarios
/// through one binding, so one is all there may ever be. It lets a step tell
/// how many frames happened outside the scenario's verbs, which is how a flow
/// reports a gap in itself.
///
/// It counts frames that were actually *drawn*: the test binding's `pump`
/// skips the frame entirely when nothing is scheduled, so an idle pump is not
/// a gap and does not read as one. Only the raw tester making the app do
/// something the flow then misses does.
int _frames = 0;
var _countingFrames = false;

void _countFrames(WidgetTester tester) {
  if (_countingFrames) return;
  _countingFrames = true;
  tester.binding.addPersistentFrameCallback((_) => _frames++);
}

/// What survives across a scenario's replays: which paths ran, which step
/// positions were already captured, and the global step numbering.
class _ReplayState {
  _ReplayState({List<String>? branches, String scenario = ''})
    : plan = _SplitPlan(stated: branches, scenario: scenario);

  final _SplitPlan plan;

  SemanticsHandle? _semantics;

  /// Holds the semantics tree open for the rest of the scenario, and pumps
  /// once so the frame the finder reads actually has one.
  ///
  /// `testWidgets` passes `semanticsEnabled: true` by default, so this is a
  /// guarantee rather than a fix: `find.bySemanticsLabel` throws outright
  /// where semantics are off, and a scenario asking for a label should not
  /// rest on someone else's default. Lazy because semantics are not free and their
  /// presence changes what some widgets build — a scenario that never asks
  /// for a label captures exactly what it captured before.
  Future<void> ensureSemantics(WidgetTester tester) async {
    if (_semantics != null) return;
    _semantics = tester.ensureSemantics();
    await tester.pump();
  }

  void disposeSemantics() {
    _semantics?.dispose();
    _semantics = null;
  }

  /// Position key → the emitted step's index. A position seen again on a
  /// later replay's shared prefix is skipped without rendering anything.
  final emitted = <String, int>{};

  var stepCount = 0;

  /// Every verb whose landing found work by guessing, with the deepest turn
  /// it took — see `landRealWork`'s `guessed`. Said once when the scenario
  /// ends, by [guessedLandingNotice].
  final guessed = <String, int>{};
}

/// Depth-first enumeration of a scenario's `split` choices.
///
/// One entry per split encountered along the current path, in order: replay
/// the recorded prefix, then explore `0` at every split found beyond it.
/// [advance] bumps the deepest split that still has an unvisited branch and
/// drops everything after it.
class _SplitPlan {
  _SplitPlan({this.stated, this.scenario = ''});

  /// The branches a **film** was told to take, outermost first — null for
  /// every ordinary run, which walks all of them.
  ///
  /// A film is one path through the scenario and which path it is is the
  /// author's call: a suite wants every branch and a video wants the one
  /// worth watching, so the enumeration below is replaced by a walk of what
  /// was named rather than defaulted to the first of each.
  final List<String>? stated;

  /// Whose splits these are, for the refusal.
  final String scenario;

  final _stack = <({int choice, List<String> names})>[];
  var _cursor = 0;

  void beginRun() => _cursor = 0;

  /// The branch to take at the next split of the current run.
  int choose(List<String> names) {
    if (_cursor < _stack.length) return _stack[_cursor++].choice;
    var choice = stated == null ? 0 : _stated(names);
    // Pushed in both modes, because the choice path is half of every capture's
    // position: a stated walk that recorded nothing here would give the first
    // step after a split the same key as the first step before it, and the
    // second of them would be recognised as already captured and skipped.
    _stack.add((choice: choice, names: names));
    _cursor++;
    return choice;
  }

  /// The stated branch for the split now being entered, or the refusal that
  /// says what could have been named.
  int _stated(List<String> names) {
    var stated = this.stated!;
    var quoted = [for (var name in names) '`$name`'];
    // `a`, `b` and `c` — a list of four joined by three "and"s reads as one
    // long name.
    var listed = quoted.length < 2
        ? quoted.join()
        : '${quoted.take(quoted.length - 1).join(', ')} and ${quoted.last}';
    if (_cursor >= stated.length) {
      throw ScenarioFilmRefusal(
        '`$scenario` splits into $listed, and a film is one path. Name it: '
        "--branch='${names.first}'. Nested splits take one --branch each, "
        'outermost first.',
      );
    }
    var wanted = stated[_cursor];
    var index = names.indexOf(wanted);
    if (index < 0) {
      throw ScenarioFilmRefusal(
        '`$scenario` has no branch called `$wanted` here — it splits into '
        '$listed.',
      );
    }
    return index;
  }

  /// The choices consumed so far this run — the position key's path half.
  String get path =>
      [for (var entry in _stack.take(_cursor)) entry.choice].join('.');

  /// The branch this run is replaying its way towards and has not reached
  /// yet — the first planned choice not consumed, by name, with the path its
  /// first step sits under — or null once every planned split has been
  /// entered.
  ///
  /// Non-null only on a later replay's shared prefix, which is exactly where
  /// a failure has no branch of its own to wear: the steps around it were all
  /// captured by an earlier replay, and the choice that makes this replay
  /// different has not been taken yet.
  ({String label, String path})? get upcoming {
    if (_cursor >= _stack.length) return null;
    var next = _stack[_cursor];
    return (
      label: next.names[next.choice],
      path: [for (var entry in _stack.take(_cursor + 1)) entry.choice]
          .join('.'),
    );
  }

  /// Moves to the next unvisited path; false when every path has run — and
  /// false at once for a film, which walks the one path it was given.
  bool advance() {
    if (stated != null) return false;
    while (_stack.isNotEmpty &&
        _stack.last.choice + 1 >= _stack.last.names.length) {
      _stack.removeLast();
    }
    if (_stack.isEmpty) return false;
    _stack.last = (choice: _stack.last.choice + 1, names: _stack.last.names);
    return true;
  }
}

/// Applies the harness's axis assignment, when there is one to apply.
///
/// The application itself is [applyScenarioRunArgs], which is also what
/// `tester.applyDevice` calls — one implementation, so a scenario on an axis
/// and a plain widget test staged by hand cannot end up on subtly different
/// surfaces. Only the *resolution* is here, because only a scenario has two
/// places an assignment can come from.
///
/// Null args are a bare `flutter test` with no profile, which pays nothing.
VoidCallback? _applyRunArgs(WidgetTester tester, ScenarioAssignment? ambient) {
  // The runner's assignment wins where there is one: it is answering a request
  // that named its axes. The ambient one is the other lane — a bare
  // `flutter test`, where the folder's profile is the only thing that spoke.
  var args =
      scenarioRunArgs ??
      (ambient == null || ambient.isEmpty
          ? null
          : ScenarioRunArgs.forAssignment(ambient));
  if (args == null) return null;
  return applyScenarioRunArgs(tester, args);
}

/// Drives one scenario. Wraps the real [WidgetTester] — every method here
/// settles and then captures per the scenario's [Shots] policy; anything done
/// through [tester] directly is plain `flutter_test` and captures nothing.
///
/// Waiting is the same [Settle] policy for every verb, bounded by default, so
/// a screen that animates forever is captured rather than thrown on.
class ScenarioTester {
  ScenarioTester._(
    this.tester,
    this._description,
    this.shots,
    this._settle,
    this._state,
    this.assignment,
    this._source,
    this.assets,
    this._keyboard,
    this.network,
    this._film,
  );

  /// The real tester — the escape hatch to the full `flutter_test` surface.
  final WidgetTester tester;

  /// The bundle this scenario reads assets through, installed over whatever
  /// [pumpWidget] pumps — so `DefaultAssetBundle.of(context)`, and everything
  /// built on it, is already this one.
  ///
  /// It caches values where `rootBundle` caches futures, which is what makes an
  /// asset the app has already read safe to read again from inside
  /// [runAsync]. Pass it wherever a widget takes a bundle explicitly:
  ///
  /// ```dart
  /// SvgPicture.asset('assets/logo.svg', bundle: s.assets);
  /// ```
  ///
  /// One per scenario, shared by every replay of its splits.
  final ScenarioAssetBundle assets;

  /// What raises and lowers the software keyboard — shared across replays for
  /// the same reason [assets] is.
  final ScenarioKeyboard _keyboard;

  /// What this scenario's http requests reach, and where it states the answers
  /// it wants.
  ///
  /// ```dart
  /// s.network.get('/api/messages', json: []);
  /// s.network.image('/avatars/1.png', scenarioPlaceholderPng(width: 64));
  /// s.network.any(throws: const SocketException('Network is unreachable'));
  /// ```
  ///
  /// A stub always beats the mode, so a scenario under
  /// [ScenarioNetwork.live] can still pin the one response it is about and let
  /// the rest go out. `s.network.requests` is what was actually asked for, and
  /// every one of them is on the step's Events pane besides.
  ///
  /// One per scenario, shared by every replay of its splits — and reset at the
  /// top of each replay, so a branch states its own answers.
  final ScenarioNetworkPolicy network;

  /// The software keyboard, for a scenario that wants to say it explicitly.
  ///
  /// Nothing here is needed to get one. A scenario that taps a text field
  /// already renders with a keyboard over the bottom of the screen, because
  /// that is what a phone does and the framework says when. This is for the
  /// other cases: a layout you want to see under one with nothing focused, a
  /// user who swipes it away, a screen you want photographed without it.
  ///
  /// Every one of them is a **no-op on a stage with no keyboard** — a run on
  /// a desktop size or on nothing, and a folder that turned the feature off.
  /// Raising one there would mean inventing a height, which is the one thing
  /// the measured table exists not to do, and a matrix crossing a phone with a
  /// window must not fail on the window.
  late final keyboard = ScenarioKeyboardVerbs._(this);

  final Shots shots;

  /// How every verb waits before it captures — overridable per call.
  final Settle _settle;

  final String _description;

  /// The test file this scenario was declared in, when the standalone lane
  /// looked it up — the directory above [_description] in a destination, so
  /// that two files naming the same screen do not write into each other.
  final String? _source;

  /// The axes this scenario is running under, when anything assigned any —
  /// what keeps a matrix's captures out of each other's directories, and what
  /// a body reads to adapt an expectation to the screen it is on.
  ///
  /// Both lanes answer here: a folder profile or a CI list (`FW_LANGUAGES`)
  /// under `flutter test`, and the request's own axes (`--language`,
  /// `--device`) under the flutterware runner. That agreement is the point —
  /// a base class keying its locale off `assignment.language` was silently
  /// running every `scenarios run --language=nl` in English, because the
  /// runner used to leave this null.
  final ScenarioAssignment? assignment;

  /// Shared across replays; everything below is this replay's alone.
  final _ReplayState _state;

  /// Captures since the last split (or the start) — the position key's
  /// ordinal half. Two replays walking the same choice prefix count the same
  /// way, which is what makes a position mean "the same step as last time".
  var _ordinal = 0;

  /// Which stretch of the scenario this replay is in: 0 until the first
  /// `split`, one more at every branch entered. Stamped on each capture, so
  /// adoption can tell a step this branch emitted from the shared step
  /// before the fork — see [_adoptablePending].
  var _segment = 0;

  /// The position of the last capture this replay saw — emitted or
  /// recognised — whose step is the next capture's parent.
  String? _lastPosition;

  /// The branch label owed to the next capture, set on entering a split
  /// branch.
  String? _pendingBranch;

  /// The split choices taken to reach here, by name — the failure message's
  /// context, and never popped, for the same reason the plan's choice path is
  /// not: it describes *this replay*.
  final _branchTrail = <String>[];

  /// The error already given a failed step, so the verb that raised it and
  /// the scenario-level backstop do not both capture one.
  Object? _capturedFailure;

  /// The frame count when the last verb finished — the baseline stray frames
  /// are measured from. Set at construction, which is after the replay's
  /// teardown pump, so tearing the tree down never counts as a stray frame.
  var _framesAtLastStep = _frames;

  /// The frame count when this replay last passed a capture point — emitted,
  /// adopted, or recognised from an earlier replay's shared prefix. While
  /// [_frames] still equals it, the screen is byte for byte the picture the
  /// flow already holds, which is what lets a no-op verb skip its automatic
  /// shot (see [_afterStep], and the skip branch of [_capture]).
  ///
  /// Deliberately not read off [_pending]'s own frame count, which is absent
  /// while a replay walks a shared prefix. A skipped shot consumes its
  /// position, so a decision that flipped between passes could not
  /// desynchronise the walk — but it would decide a step's existence twice,
  /// and this counter, moving at the same points on every pass, keeps the
  /// answer the same wherever rendering is deterministic.
  var _framesAtLastCapture = _frames;

  /// Collects the frames of the transition being walked, when the run asked
  /// for motion and there is a listener to hand them to.
  ///
  /// Not created for a standalone `flutter test` writing PNGs to a
  /// destination: a folder of screenshots has nowhere to put a movie, and
  /// nobody asked that lane to slow down.
  late final ScenarioMotionRecorder? _recorder =
      scenarioRunListener != null && scenarioRunArgs?.record != null
      ? ScenarioMotionRecorder(scenarioRunArgs!.record!)
      : null;

  /// The film being rendered, when this run is rendering one — created once
  /// per scenario, above the replay loop, because a film spans the whole of
  /// one path and not one branch of it.
  final ScenarioFilm? _film;

  /// What this run is telling whatever is filming it.
  ///
  /// Silent when nothing is: every call is a no-op without a film, so a
  /// scenario carrying cues costs an evidence run nothing and asserts nothing.
  late final ScenarioFilmVoice film = ScenarioFilmVoice._(this);

  /// A caption for the stretch that follows — sugar over [film].
  ///
  /// ```dart
  /// s.title('Order a coffee');
  /// await s.tap('Cappuccino');
  /// ```
  void title(String text) => film.emit(ScenarioTitle(text));

  /// What the settle loops hand their frames to.
  ///
  /// One or the other, never both: an evidence run banks a transition for the
  /// panel and a film run keeps everything and spills it to disk, and the
  /// harness refuses a request that asks for the two at once.
  late final ScenarioFrameSink? _sink = _recorder ?? _film;

  Future<void> pumpWidget(Widget widget, {Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    () async {
      // Wrapped in the scenario's own bundle, so every `Image.asset`,
      // `AssetImage` and `SvgPicture.asset` under the app reads through
      // something that caches values rather than futures — see [assets]. An
      // app that installs a `DefaultAssetBundle` of its own still wins, since
      // its is the nearer ancestor.
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: assets,
          // The slab, above the app and inside the pumped tree, so every
          // capture that exists already contains it — step shots, motion
          // frames, the web export — with no compositing step anywhere. The
          // *insets* are on the view rather than here; see [ScenarioKeyboard].
          child: _keyboard.deviceHeight > 0
              ? ScenarioKeyboardSlab(driver: _keyboard, child: widget)
              : widget,
        ),
      );
      await _realAsyncTurn();
      await tester.pump();
    },
    verb: 'pumpWidget',
    target: '${widget.runtimeType}',
  );

  /// `tester.runAsync` with a watchdog on it: real async work, and a sentence
  /// rather than a hang when it turns out not to be work at all.
  ///
  /// Everything a scenario waits on for real — a database, a socket, an http
  /// call, an asset the app has not read yet — needs a turn of the real event
  /// loop, and this is the turn. The catch is that no pump can run while it is
  /// open, so awaiting a future that was made *outside* it, and that only a
  /// pump could complete, deadlocks the whole run silently. The watchdog
  /// reports that within seconds, and names the cache usually behind it.
  ///
  /// ```dart
  /// var bytes = await s.runAsync(() => report.generatePdf());
  /// ```
  ///
  /// A verb like the rest of them: it settles afterwards and captures what
  /// landed. Real work arriving is exactly the moment the tree has something
  /// new to paint — a query returns and the list fills in — and before this
  /// it was the one method on this surface that sat among `tap` and `drag`
  /// and quietly did neither, so every site that needed the repaint settled
  /// by hand.
  ///
  /// Work that lands nothing on screen still takes no step: the automatic
  /// shot is skipped where the settle drew no frame, so the `generatePdf`
  /// above is followed by its [document] and by nothing else.
  Future<T?> runAsync<T>(
    Future<T> Function() callback, {
    Shot? shot,
    Settle? settle,
  }) => _step(
    shot,
    settle,
    () => watchRunAsync(() => tester.runAsync(callback)),
    verb: 'runAsync',
    autoShotNeedsFrames: true,
  );

  /// Lets whatever the app started on its first frame actually happen.
  ///
  /// A scenario runs under fake time, where a real asset read — the shape
  /// every app that loads translations or a font manifest at boot has —
  /// completes on an event loop no pump reaches. So the tree builds with
  /// nothing in it and every screen after this captures blank.
  ///
  /// The alternative was answering `flutter/assets` from Dart, which is what
  /// `flutter test` does with `UNIT_TEST_ASSETS`. Measured against a real
  /// suite, that deadlocks a `tester.runAsync` that loads an asset itself —
  /// `flutter test` hangs where this does not. A turn of the real event loop
  /// costs a few milliseconds once per pumped app and has no such edge.
  ///
  /// Deliberately not on every verb: this is about *boot*, and a scenario
  /// that needs real async mid-flow says so with its own [runAsync].
  Future<void> _realAsyncTurn() => tester.runAsync(() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });

  /// Taps [target] — a `Finder`, a `String` (visible text), a `Key`, an
  /// `IconData`, a `Type`, or a [Target] for the rest (a semantics label, a
  /// tooltip, a scope, an index).
  ///
  /// `dynamic` is a deliberate exception to the house no-dynamic preference:
  /// `tap('NEXT')` / `tap(Icons.add)` / `tap(Keys.next)` read too well to give
  /// up, and the auto-write generator emits exactly the string form.
  Future<void> tap(dynamic target, {Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    // The `At` forms of the SDK's verbs, never the finder forms: `_resolve`
    // has already decided reachability — and loudly, where the SDK's
    // `warnIfMissed` is a console line the flow sails past — and where the
    // finger lands is [_aimFor]'s answer rather than a centre the SDK would
    // take for itself.
    () async {
      var finder = await _resolve(target, 'tap');
      var at = _aimFor(target, finder);
      await _approach('tap');
      await tester.tapAt(at);
    },
    verb: 'tap',
    target: describeTarget(target),
  );

  /// Taps a point rather than a widget — the same press as [tap], aimed where
  /// no finder can reach.
  ///
  /// The zones of an SVG, a chart or a map are painted rather than built, so
  /// they share one widget and one box, and [tap] on that box presses its
  /// centre. Only a coordinate says which zone was meant, and before this the
  /// nearest way to say one was `dragFrom(at, Offset.zero)` — the right
  /// gesture arrived at sideways, and a step that reads `dragFrom` in the
  /// report for what the author meant as a tap.
  ///
  /// `tap(Target.at(x, y))` is the same press by another name — see
  /// [_aimFor], which is the one rule both go through. What this spelling has
  /// is that it needs no widget to resolve, and that the step it writes says
  /// what the author meant.
  ///
  /// The coordinates are the ones every box in a report is in: the view's
  /// logical pixels, top-left origin — what a step's aim rectangle reads back
  /// in, so a point can be lifted straight off one.
  ///
  /// It makes the same trade [dragFrom] makes: there is no target to prove
  /// reachable, so it goes where it is told, and a point over nothing taps
  /// nothing silently where every finder verb would have refused.
  Future<void> tapAt(Offset at, {Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    () async {
      _aimAtPoint(at);
      await _approach('tapAt');
      await tester.tapAt(at);
    },
    verb: 'tapAt',
    target: '${at.dx.round()},${at.dy.round()}',
  );

  Future<void> longPress(dynamic target, {Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    () async {
      var finder = await _resolve(target, 'longPress');
      var at = _aimFor(target, finder);
      await _approach('longPress');
      await tester.longPressAt(at);
    },
    verb: 'longPress',
    target: describeTarget(target),
  );

  Future<void> enterText(
    dynamic target,
    String text, {
    Shot? shot,
    Settle? settle,
  }) => _step(
    shot,
    settle,
    // `editableWithin` rather than the finder itself: `tester.enterText`
    // searches down for the editable, and a point target — `Target.at`, and
    // the `item:` an agent spells it with — resolves to a render object below
    // it, where down finds nothing.
    () async {
      var editable = editableWithin(await _resolve(target, 'enterText'));
      // **The editable's box, not the finder's** — the one place this differs
      // from `tap`. The verb acts on the editable whatever the target named,
      // and the box is read for the text that is about to land in it, so the
      // region the text lands in is the honest one. A point target would
      // otherwise box the render object under the finger.
      _aimAt(editable);
      await _approach('enterText');
      // A film types; a run sets the value. The verb hands the setter over
      // rather than the film reaching for the editable, so what lands in the
      // field is the same call either way — see [ScenarioFilm.type].
      if (_film case var film?) {
        await film.type(
          tester,
          text,
          (value) => tester.enterText(editable, value),
          // Measured rather than remembered, and deliberately not through
          // [_aimAt]: the mark on the step is where the verb *aimed*, which is
          // the frame it acted on, and the cursor following the field up is a
          // different question asked ten frames later.
          follow: () =>
              _boundsOf(editable.evaluate().firstOrNull?.renderObject)?.center,
        );
      } else {
        await tester.enterText(editable, text);
      }
    },
    verb: 'enterText',
    target: describeTarget(target),
  );

  /// Drags [target] by [by] — a swipe, a dismiss, a slider, a sheet pulled
  /// down. Negative `dy` moves the finger up the screen, the touch convention
  /// `flutter_test` itself uses.
  ///
  /// [duration] spreads the same travel over that much of the clock, which is
  /// how a drag says anything at all about *velocity*.
  ///
  /// Without it the finger moves in one jump, so the velocity tracker sees the
  /// whole distance in no time and reports **none**: the list stops dead where
  /// the finger stopped, and no offset will make it overscroll. Right for a
  /// dismiss or a slider, and the reason a fling was not previously
  /// expressible. Measured on a 200-row list: `Offset(0, -300)` bare lands at
  /// exactly 300, over a second it carries to ~324, and over 300ms — the same
  /// distance at three times the speed — it flies past 450.
  Future<void> drag(
    dynamic target,
    Offset by, {
    Duration? duration,
    Shot? shot,
    Settle? settle,
  }) => _step(
    shot,
    settle,
    () async {
      var finder = await _resolve(target, 'drag');
      var at = _aimFor(target, finder, by: by);
      await _approach('drag');
      if (_film case var film?) {
        await film.dragBy(tester, by, over: duration);
      } else if (duration == null) {
        await tester.dragFrom(at, by);
      } else {
        await tester.timedDragFrom(at, by, duration);
      }
    },
    verb: 'drag',
    target: describeTarget(target),
  );

  /// Drags from a point rather than from a widget — the same gesture as
  /// [drag], aimed where no finder can reach.
  ///
  /// A canvas, a chart, a map, a signature pad: the thing to grab is a
  /// painted region inside one widget, so naming the widget grabs its centre
  /// and naming nothing was the only other option. [Target.at] does not
  /// close this — it resolves the widget *under* the point and the drag still
  /// starts from that widget's centre, which on a full-bleed canvas is
  /// somewhere else entirely.
  ///
  /// The coordinates are the ones every box in a report is in: the view's
  /// logical pixels, top-left origin — what a step's aim rectangle reads back
  /// in, so a point can be lifted straight off one.
  ///
  /// [duration] means what it means on [drag].
  Future<void> dragFrom(
    Offset from,
    Offset by, {
    Duration? duration,
    Shot? shot,
    Settle? settle,
  }) => _step(
    shot,
    settle,
    () async {
      // No ladder to climb: there is no target to prove reachable, only a
      // point the author named. That is the trade this verb makes — it goes
      // where it is told, and a point over nothing drags nothing silently,
      // where every finder verb would have refused.
      _aimAtPoint(from, by: by);
      await _approach('dragFrom');
      if (_film case var film?) {
        await film.dragBy(tester, by, over: duration);
      } else if (duration == null) {
        await tester.dragFrom(from, by);
      } else {
        await tester.timedDragFrom(from, by, duration);
      }
    },
    verb: 'dragFrom',
    target: '${from.dx.round()},${from.dy.round()}',
  );

  /// Scrolls until [target] is on screen, then captures it there.
  ///
  /// The scrollable is the first one on screen unless [within] names one — a
  /// widget that *is* a `Scrollable` or contains one. A target that is built
  /// but behind the viewport is jumped to directly, whichever direction and
  /// axis that is. [step] is how far each drag travels toward the end of the
  /// list when the target is not built yet; make it negative to walk back
  /// toward the start.
  ///
  /// A target already on screen is the step's point achieved — so the verb
  /// is safe inside a loop over pages of varying length, where which pages
  /// scroll depends on the device. On a page that cannot scroll that is a
  /// true no-op; on one that can, the trailing alignment may still bring the
  /// target to the viewport's edge, and the scrolled screen is captured as
  /// ever. A call that drew nothing skips its automatic capture: the step
  /// would repeat the previous picture byte for byte, and the defensive
  /// calls such a loop makes were measured on a consumer suite as half its
  /// duplicate warnings. The skipped shot still consumes its position — see
  /// [_capture] — and an explicit [shot] still captures: the author asked
  /// for a picture. Unlike the other verbs this one may start with a target
  /// that matches nothing — being off screen is the reason to call it — so
  /// it reports the miss itself when the scrolling never finds it, and when
  /// nothing scrolls and the target is absent or off screen.
  Future<void> scrollTo(
    dynamic target, {
    dynamic within,
    double step = 200,
    int maxScrolls = 50,
    Shot? shot,
    Settle? settle,
  }) => _step(
    shot,
    settle,
    () async {
      var finder = finderForTarget(target);
      var scrollable = within == null
          ? find.byType(Scrollable)
          : find.descendant(
              of: finderForTarget(within),
              matching: find.byType(Scrollable),
              matchRoot: true,
            );
      // Held, not re-evaluated: a `Finder` caches nothing between calls, so
      // every `evaluate()` walks the element tree from the root. This verb
      // needs the same two answers three times over, and a walking scenario
      // pays for them per step.
      var scrollables = scrollable.evaluate();
      if (scrollables.isEmpty) {
        var refusal = refusalWhenNothingScrolls(
          finder,
          describeTarget(target),
          within,
          _messages,
        );
        // A target already on screen is the step's whole point achieved:
        // capture it there, scroll nothing. Which pages scroll varies with
        // the device, so a walking scenario cannot know statically. It is
        // still marked, because "already here" is what the verb did.
        if (refusal == null) {
          _aimAt(finder);
          return;
        }
        throw ScenarioTargetError(refusal.message);
      }
      var onstage = finder.evaluate();
      // Built but behind the viewport: the walk only drags one way, so a
      // target the list has already scrolled past is unreachable however
      // long it walks. `Scrollable.ensureVisible` reads the target's own
      // position and jumps — both directions, both axes. The walk stays for
      // what it was built for: a lazy list whose target is not built yet.
      //
      // Looked up here rather than after the mark, because the mark wants the
      // same element and this is the expensive lookup of the two: it ignores
      // `skipOffstage`, so it visits the whole tree rather than the onstage
      // part of it.
      var behind = onstage.isEmpty
          ? scrolledPastTarget(finder, scrollable)
          : null;
      _aimAtScroll(
        scrollables.first,
        step,
        at: behind ?? (onstage.length == 1 ? onstage.single : null),
      );
      if (behind != null) {
        await Scrollable.ensureVisible(behind);
        await tester.pump();
        // Not revealed means it was never in this viewport's reach — an
        // `Offstage` under the list, say. The walk's own exhaustion
        // message below is the one that says what to try.
        if (finder.evaluate().isNotEmpty) return;
      }
      try {
        // A film walks it with a thumb. Same walk, same step, same stopping
        // condition — and the same tail, so the alignment it ends on and the
        // refusal it throws are the SDK's rather than a second version of
        // them. See [ScenarioFilm.scroll].
        if ((_film, _boundsOf(scrollables.first.renderObject)) case (
          var film?,
          var pane?,
        )) {
          await film.scroll(
            tester,
            pane: pane,
            by: switch ((scrollables.first.widget as Scrollable)
                .axisDirection) {
              AxisDirection.up => Offset(0, step),
              AxisDirection.down => Offset(0, -step),
              AxisDirection.left => Offset(step, 0),
              AxisDirection.right => Offset(-step, 0),
            },
            until: () => finder.evaluate().isNotEmpty,
            maxScrolls: maxScrolls,
          );
          // `dragUntilVisible`'s own last line, and its own way of failing: an
          // empty `single` is the `StateError` the catch below turns into the
          // exhaustion message.
          await Scrollable.ensureVisible(finder.evaluate().single);
          await tester.pump();
          return;
        }
        await tester.scrollUntilVisible(
          finder,
          step,
          // The first, as `flutter_test` itself defaults to: nested scrollables
          // are ordinary, and `within` is how a scenario says which one.
          scrollable: scrollable.first,
          maxScrolls: maxScrolls,
        );
      } on StateError {
        throw ScenarioTargetError(
          _messages.scrollExhausted(maxScrolls, step, describeTarget(target)),
        );
      }
    },
    verb: 'scrollTo',
    target: describeTarget(target),
    autoShotNeedsFrames: true,
  );

  /// The platform's back gesture — Android's button, iOS's edge swipe, the
  /// thing that pops a route without a widget to tap.
  ///
  /// Sent as the engine sends it, down `flutter/navigation`, rather than
  /// through the binding's own handler: the message is the public, sanctioned
  /// route, and it exercises the app's `PopScope`s on the way in.
  Future<void> back({Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    () => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      null,
    ),
    verb: 'back',
  );

  /// Advances the clock by [duration].
  ///
  /// The verbs settle, which waits out *animations*; a pending timer schedules
  /// no frames, so a splash screen that navigates after three seconds needs
  /// the clock moved rather than settled. Instant either way — the clock is
  /// fake.
  Future<void> wait(Duration duration, {Shot? shot, Settle? settle}) => _step(
    shot,
    settle,
    () => tester.pump(duration),
    verb: 'wait',
    target: '$duration',
  );

  /// Waits per the scenario's [Settle] policy — or [policy] — and captures
  /// nothing.
  ///
  /// The wait without the step: what a bridge maps a legacy `pumpAndSettle()`
  /// onto, and what a scenario wants after work it pumped itself through
  /// [tester]. Same budget, same "give up quietly on a screen that never
  /// stops animating" as every verb — where a raw `tester.pumpAndSettle`
  /// throws on the first spinner and leaves the budget to be re-derived by
  /// hand.
  Future<void> settle([Settle? policy]) =>
      _step(Shot.skip, policy, () async {}, verb: 'settle');

  /// A step whose cause is not a finger: [description] says what happened,
  /// [body] makes it happen, and the screen it produces is captured under
  /// that name.
  ///
  /// The verbs above all reach into the widget tree, and a great deal of what
  /// moves a real app does not. A push arrives, a deep link lands, a socket
  /// pushes a row, a completer the scenario is holding resolves, a fake
  /// backend is seeded mid-flow:
  ///
  /// ```dart
  /// await s.act('A photo-ready push arrives', () {
  ///   app.notifications.onOpen(data);
  /// });
  /// ```
  ///
  /// The waiting was never the gap — [settle] does that, and did before this
  /// existed. The report was: the screen changed and nothing in the run said
  /// why, so a reader had to infer the cause from the two pictures either
  /// side of it. [document] and [notification] are beats that are not
  /// screens; this is the same idea one step earlier, the beat that *causes*
  /// one.
  ///
  /// [body] may be synchronous or return a future, and whatever it returns
  /// comes back — a handle the rest of the scenario needs is not worth a
  /// variable declared a line above. It runs under fake time like everything
  /// else, and it is not the place for work that needs the *real* event loop:
  /// [runAsync] is its own step, so putting one inside this one captures
  /// twice, once for what landed and once for the name.
  Future<T> act<T>(
    String description,
    FutureOr<T> Function() body, {
    List<String> tags = const [],
    Settle? settle,
  }) => _step(
    Shot(description, tags: tags),
    settle,
    () async => await body(),
    verb: 'act',
  );

  /// Names the screen as it stands, without performing an action.
  ///
  /// Where nothing has moved since the last verb captured — the ordinary
  /// `tap` then `screen` pair — this **names that capture** rather than
  /// photographing the same frame a second time:
  ///
  /// ```dart
  /// await s.tap(Keys.search);
  /// await s.screen('Cases');   // one step, named 'Cases', verb `tap`
  /// ```
  ///
  /// So a name costs nothing, and an author never has to weigh writing one
  /// against the picture it would duplicate. "Nothing has moved" is answered
  /// twice: the frame count answers first and free — nothing drawn is the
  /// same picture — and where frames *were* drawn (extra settling between
  /// the verb and its name, a periodic timer repainting an identical screen)
  /// the render this call was about to pay anyway is compared against the
  /// held one — words, bytes and all — and a proven-identical screen adopts
  /// just the same. Only where the screen actually differs — a `pump`, a
  /// completer, a rebuild from outside the tree — is there something new to
  /// photograph, and this captures it, which is the whole reason the verb
  /// exists:
  ///
  /// ```dart
  /// await s.tap(Keys.takePicture);
  /// await s.screen('Capturing');        // names the tap's frame
  /// await s.wait(const Duration(seconds: 5));
  /// await s.screen('Captured');         // a new frame: its own step
  /// ```
  ///
  /// It settles first, like every other verb — a capture wants a screen that
  /// has finished moving, and which verb waits and which does not is exactly
  /// the knowledge [Settle] exists to remove. **To photograph a screen
  /// mid-flight, say so here**, on the name rather than only on the verb
  /// before it:
  ///
  /// ```dart
  /// await s.tap(Keys.takePicture, settle: Settle.none);
  /// await s.screen('Capturing', settle: Settle.none);
  /// ```
  ///
  /// Both halves, because the wait is per step and the second one would
  /// otherwise undo the first. On a screen holding an indefinite animation
  /// that is not pedantry: a bounded policy never sees a quiet frame there,
  /// so it spends its whole budget, and a spent budget under fake time is a
  /// clock that **moved** — every timer due inside the window fires, and the
  /// thing the scenario meant to photograph may have finished. True of any
  /// verb that follows, not only of this one.
  ///
  /// A name never overwrites a name: two `screen` calls on one frame stay two
  /// steps. [force] declines the adoption outright, for a deliberate second
  /// picture of a frame that already has a name on it.
  Future<void> screen(
    String name, {
    List<String> tags = const [],
    Settle? settle,
    bool force = false,
  }) => _step(
    Shot(name, tags: tags),
    settle,
    () async {},
    verb: 'screen',
    adopt: !force,
  );

  /// A beat of the flow that is not a screen: the PDF it just generated, the
  /// email body it queued, the payload it posted.
  ///
  /// A step like any other — named, positioned, carrying the events that led
  /// to it — whose picture is the document rather than the app:
  ///
  /// ```dart
  /// await s.tap('Export');
  /// var bytes = await s.runAsync(() => report.generatePdf());
  /// await s.document('receipt', bytes!, fileName: 'receipt.pdf',
  ///     mimeType: 'application/pdf');
  /// ```
  ///
  /// A flow that exists to produce a document was otherwise a scenario that
  /// stopped one step short: you could screenshot the button and
  /// prove nothing about what it made. Deliberately one verb rather than one
  /// per format — the format is [mimeType]'s job, and a viewer shows what it
  /// can and offers the rest as a download.
  ///
  /// It renders nothing, so it costs no capture: there is no screen here to
  /// photograph, which is why it is its own kind of step rather than a file
  /// attached to another one.
  Future<void> document(
    String name,
    List<int> bytes, {
    String? fileName,
    String? mimeType,
    List<String> tags = const [],
  }) => _beat(
    kind: ScenarioCaptureKind.document,
    verb: 'document',
    name: name,
    tags: tags,
    payload: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    fileName: fileName,
    mimeType: mimeType,
  );

  /// A push the flow's backend would have sent — a beat the recipient sees,
  /// drawn the way their phone would draw it.
  ///
  /// ```dart
  /// await s.tap('Pay');
  /// await s.notification("Your cappuccino is ready — counter 3",
  ///     title: "Barista's");
  /// ```
  ///
  /// Like [document] it has no frame of its own. A viewer draws it over the
  /// nearest screen before it — which is what a real banner does — and
  /// supplies everything the payload leaves out: the project's own launcher
  /// icon, the banner's "now", the brightness the scenario ran under.
  ///
  /// Deliberately unnamed as a step. A notification's words are the app's
  /// user-facing text, so they are translated and reworded; keying a
  /// comparison on them would read one flow under two languages as two
  /// different flows. The same reasoning the aligner already applies to a
  /// verb's visible-text target.
  Future<void> notification(
    String body, {
    String? title,
    String? appName,
    List<String> tags = const [],
  }) => _beat(
    kind: ScenarioCaptureKind.notification,
    verb: 'notification',
    tags: tags,
    notification: ScenarioNotification(
      title: title,
      body: body,
      appName: appName,
    ),
  );

  /// Emits a step that has no frame — see [document] and [notification].
  ///
  /// Everything a captured step does about position, parent, branch and
  /// replay, and none of what it does about pixels. It deliberately does
  /// **not** hand over the capture being held: nothing was drawn here, so a
  /// `screen` after this beat may still name the frame before it, and the
  /// chain stays linear because the position map records the chain's head
  /// rather than the step a name landed on.
  /// Runs [body] as a step with a duration and no picture.
  ///
  /// The body runs in-process, so the network funnel already records its
  /// exchanges on this step. A consumer's "create an account through the API,
  /// read the confirmation mail, confirm it" becomes visible on the flow
  /// without changing. Under the fake clock the body gets a real-async turn,
  /// the way [runAsync] does, because what a setup awaits is real.
  ///
  /// ```dart
  /// var token = await s.setup('fresh account', () => api.register(...));
  /// await s.pumpWidget(app(initialToken: token));
  /// ```
  Future<T> setup<T>(String name, Future<T> Function() body) async {
    var watch = Stopwatch()..start();
    var result = scenarioHarnessTime.isReal
        ? await body()
        : (await watchRunAsync(() => tester.runAsync(body))) as T;
    await _beat(
      kind: ScenarioCaptureKind.setup,
      verb: 'setup',
      name: name,
      ms: watch.elapsedMilliseconds,
    );
    return result;
  }

  Future<void> _beat({
    required ScenarioCaptureKind kind,
    required String verb,
    String? name,
    List<String> tags = const [],
    Uint8List? payload,
    String? fileName,
    String? mimeType,
    ScenarioNotification? notification,
    int? ms,
  }) async {
    var position = '${_state.plan.path}#${++_ordinal}';
    if (!_capturing) return;
    var parent = _lastPosition == null ? null : _state.emitted[_lastPosition!];
    if (_state.emitted.containsKey(position)) {
      // Recognised from an earlier replay of a shared prefix, exactly as a
      // captured step is: the beat was emitted on the first pass with that
      // pass's events, and appending these would multiply the prefix.
      appEventBuffer?.discard();
      _lastCaptureFresh = false;
      _lastPosition = position;
      _pendingBranch = null;
      return;
    }
    var index = ++_state.stepCount;
    _state.emitted[position] = index;
    _lastPosition = position;
    var branch = _pendingBranch;
    _pendingBranch = null;
    var (events, dropped) = appEventBuffer?.drain() ?? (const <AppEvent>[], 0);
    _pendingBeats.add(
      _PendingEmit(
        index: index,
        parent: parent,
        branch: branch,
        kind: kind,
        name: name,
        tags: tags,
        payload: payload,
        fileName: fileName,
        mimeType: mimeType,
        notification: notification,
        ms: ms,
        verb: verb,
        target: null,
        position: position,
        events: List.of(events),
        eventsDropped: dropped,
        settled: true,
        waited: true,
        landed: true,
        strayFrames: 0,
        failure: null,
        segment: _segment,
        frames: _frames,
      ),
    );
    _lastCaptureFresh = true;
  }

  /// Whether the last capture this replay saw was emitted by this replay —
  /// false when it was recognised from an earlier pass over a shared `split`
  /// prefix, which leaves something older held.
  var _lastCaptureFresh = false;

  /// What the verb now running aimed at, measured by [_aimAt] the moment
  /// after its target resolved and before it acted. Cleared per step, so a
  /// verb that aims at nothing never inherits the last one's box.
  ScenarioAim? _aim;

  /// Marks what the verb is about to touch, and hands back **where** it will
  /// touch it.
  ///
  /// One rule for both spellings of a point. `Target.at` names a coordinate,
  /// and a coordinate is where the finger goes down — not the centre of
  /// whatever widget the hit test found under it, which on the surfaces this
  /// form exists for (an SVG map, a chart, a signature pad, anything whose
  /// regions are painted rather than laid out) is the middle of the canvas
  /// and a different region every time. So `tap(Target.at(x, y))` and
  /// [tapAt] are the same press, and `drag(Target.at(…), by)` and [dragFrom]
  /// the same drag; the pair with the coordinate in the verb is the one that
  /// says so in the report.
  ///
  /// The mark follows the contact, which is why this returns the point rather
  /// than leaving the caller to ask twice. A point target marks itself the
  /// way [tapAt] does — the point, and a box of no size — because the box it
  /// resolved would be the whole canvas, and a ring drawn at that box's
  /// centre would be a picture of a press that did not happen.
  ///
  /// Everything else is unchanged: a target that says *what* has only one
  /// place it can mean, and that is the middle of what it found.
  Offset _aimFor(dynamic target, Finder finder, {Offset? by}) {
    if (pointOf(target) case var point?) {
      _aimAtPoint(point, by: by);
      return point;
    }
    _aimAt(finder, by: by);
    return tester.getCenter(finder);
  }

  /// Records the box [finder] resolved to, in the same space every other rect
  /// in a report is in.
  ///
  /// Measured before the verb acts, because after it the widget may be gone —
  /// and read off the render object the actionability ladder just proved is
  /// there, so it costs a transform and no searching.
  ///
  /// Never throws. A picture of where the finger went is a nicety; a scenario
  /// that failed because it could not measure the thing it just tapped would
  /// be a bad trade.
  void _aimAt(Finder finder, {Offset? by, String? toward}) {
    var render = finder.evaluate().firstOrNull?.renderObject;
    if (render is! RenderBox || !render.hasSize || !render.attached) return;
    // The whole rect through the transform, for the reason `_layoutOf` gives
    // at length: an origin from `localToGlobal` beside a raw `render.size` are
    // in different spaces the moment any ancestor scales, and a box drawn from
    // the two of them disagrees with the picture it is drawn on.
    var bounds = MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
    _aim = ScenarioAim(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
      dx: by?.dx,
      dy: by?.dy,
      toward: toward,
    );
  }

  /// Flies the film's cursor to what the verb just measured, and presses.
  ///
  /// Nothing at all on an ordinary run — there is no cursor, and the verb goes
  /// straight from resolving its target to touching it. On a film run this is
  /// the only moment both halves are true: the box has been measured, and the
  /// app has not been touched yet.
  ///
  /// Called by the verbs with a finger and by no others. `scrollTo` and the
  /// keyboard verbs act on a *region* — which pane, which way — and a mark
  /// promising a contact point they never make would be the picture lying
  /// about the gesture.
  Future<void> _approach(String verb) async {
    if ((_film, _aim) case (var film?, var aim?)) {
      await film.approach(tester, aim, verb: verb);
    }
  }

  /// The mark for a verb aimed at a point — [tapAt] and [dragFrom], and any
  /// verb whose target named one; see [_aimFor].
  ///
  /// A box of no size, which is the honest shape of what the author said: a
  /// point verb names a coordinate and not a widget, and inventing a box
  /// around it would draw a ring over whatever happens to be under the finger
  /// as though the verb had resolved it. Viewers already mark the point as
  /// well as the box, and [ScenarioAim.point] derives it from the rect, so an
  /// empty rect at the point reads back as exactly that point.
  void _aimAtPoint(Offset at, {Offset? by}) {
    _aim = ScenarioAim(
      x: at.dx,
      y: at.dy,
      width: 0,
      height: 0,
      dx: by?.dx,
      dy: by?.dy,
    );
  }

  /// The mark for a `scrollTo`: **the target where it stands** when it is
  /// already wholly inside the viewport, and otherwise **the viewport and the
  /// way to it**.
  ///
  /// Those are the two sentences the verb can make true, and which one it is
  /// is decided by geometry rather than by whether the finder matches — a
  /// target can be built, onstage and a thousand pixels above the pane, and
  /// `dragUntilVisible` ends with an `ensureVisible` that will go and get it.
  ///
  /// The target's own box is deliberately not the mark in the travelling
  /// case, and that is the thing this verb could most easily lie about: on
  /// the frame the mark is drawn on it is off the screen, or not built at
  /// all, so a ring would point at empty space.
  ///
  /// [pane] is the scrollable the walk will use and [at] the one element the
  /// target resolved to — counting one the viewport has scrolled past, and
  /// null when nothing has built it or several things match. Both are handed
  /// in because both cost a walk of the whole element tree, and the caller
  /// needed them anyway.
  void _aimAtScroll(Element pane, double step, {Element? at}) {
    var view = _boundsOf(pane.renderObject);
    if (view == null) return;
    var box = _boundsOf(at?.renderObject);
    if (box != null && _within(view, box)) {
      _aim = ScenarioAim(
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height,
      );
      return;
    }
    _aim = ScenarioAim(
      x: view.left,
      y: view.top,
      width: view.width,
      height: view.height,
      toward: _towardOfBox(box, view) ?? _towardOfWalk(pane.widget, step),
    );
  }

  /// Whether [box] sits wholly inside [view], its edges included.
  ///
  /// Not `Rect.contains`, which is half-open on the right and the bottom.
  /// A list row is exactly as wide as the pane holding it, so its bottom-right
  /// corner lands on the excluded edge and every full-width row would read as
  /// being somewhere else on the screen — the mark would promise a scroll for
  /// a row already under the reader's eyes.
  bool _within(Rect view, Rect box) =>
      box.left >= view.left &&
      box.top >= view.top &&
      box.right <= view.right &&
      box.bottom <= view.bottom;

  /// Which way [box] lies from [view] — the direction for a target the run
  /// can actually see the position of, which beats the walk's own because the
  /// jump goes where the element is rather than where the walk was pointed.
  String? _towardOfBox(Rect? box, Rect view) {
    if (box == null) return null;
    var away = box.center - view.center;
    if (away == Offset.zero) return null;
    if (away.dy.abs() >= away.dx.abs()) return away.dy < 0 ? 'up' : 'down';
    return away.dx < 0 ? 'left' : 'right';
  }

  /// Which way the walk will travel: the scrollable's own axis direction,
  /// flipped when [step] is negative.
  ///
  /// `scrollUntilVisible` turns a positive delta into a finger moving
  /// *against* the axis, which reveals what lies further along it — so a
  /// positive step means the target is that way, which is the sentence a mark
  /// on the frame before is making. The fallback for a target nothing has
  /// built yet, where there is no box to read a direction off.
  String? _towardOfWalk(Widget pane, double step) {
    if (pane is! Scrollable) return null;
    var direction = pane.axisDirection;
    return (step >= 0 ? direction : flipAxisDirection(direction)).name;
  }

  /// A render object's box in the space every rect in a report is in, or null
  /// when it has none to give.
  Rect? _boundsOf(RenderObject? render) {
    if (render is! RenderBox || !render.hasSize || !render.attached) {
      return null;
    }
    return MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
  }

  /// The band the keyboard is about to take or give back, for a verb that
  /// moves it.
  ///
  /// [want] is the fraction the mode being set asks for, read *before* it is
  /// applied — the slab writes the view as it lands, so anything measured
  /// after the jump describes the screen the mark is not drawn on.
  ///
  /// Nothing at all on a stage with no keyboard, and nothing when the band is
  /// already where the verb wants it: a mark promising a movement that does
  /// not happen is worse than no mark.
  void _aimAtKeyboard(double want) {
    var rising = want > 0;
    if (_keyboard.deviceHeight <= 0 || rising == _keyboard.up) return;
    // The band arriving is the one the *field* asked for — a number pad is
    // not as tall as the letters, and `deviceHeight` above is only the
    // question of whether this stage has a keyboard at all. The band leaving
    // is measured rather than asked for: it is already on the screen.
    var height = rising ? _keyboard.targetHeight : _keyboard.height;
    var size = tester.binding.renderViews.firstOrNull?.size;
    if (height <= 0 || size == null) return;
    _aim = ScenarioAim(
      x: 0,
      y: size.height - height,
      width: size.width,
      height: height,
      toward: rising ? 'up' : 'down',
    );
  }

  /// One verb: act, wait per the policy, capture. The settle result rides the
  /// step, so a screen that never stopped animating is reported instead of
  /// throwing.
  Future<T> _step<T>(
    Shot? shot,
    Settle? settle,
    Future<T> Function() action, {
    String? verb,
    String? target,
    bool adopt = false,
    bool autoShotNeedsFrames = false,
  }) async {
    // Frames since the previous verb finished: nothing this scenario's verbs
    // drew, so they came from `s.tester` — and whatever they showed is not in
    // the flow. Read before the action, reported on the step it precedes.
    var stray = _frames - _framesAtLastStep;
    _aim = null;
    var policy = settle ?? _settle;
    bool settled;
    bool landed;
    T result;
    // Which verb the body is inside, and from which line of the scenario —
    // the one thing a deadline can still say once the body is suspended on
    // a future nothing will complete. Cleared as the verb returns, and kept
    // as the last one, so a body that then awaits something of its own is
    // placed "after `s.tap`" rather than nowhere.
    var inFlight = verb == null
        ? null
        : ScenarioVerbInFlight(verb, target, StackTrace.current);
    scenarioVerbInFlight = inFlight;
    try {
      // The frame the transition starts from, banked before the verb acts —
      // otherwise a movie of a tap opens on the frame after the tap and the
      // "before" is nowhere in it.
      _recorder?.capture(tester);
      // The film's frames are continuous, so there is nothing to bank here —
      // what it wants is the *name* of the stretch about to be filmed. A verb
      // with a finger re-marks this from inside [_approach], with the travel
      // and the press between the two marks.
      _film?.act(verb: verb, target: target, aim: _aim);
      result = await action();
      _film?.release();
      // One purse for the whole step: the policy's frames draw whatever has
      // announced itself as they go — otherwise fake time runs the transition
      // out in a few real milliseconds and every frame of the movie behind the
      // step is a hole — and the landing below spends what is left.
      // No ceiling on tracked work here: the scenario's deadline holds one
      // per tracked future, and its message names what was still pending.
      var budget = RealWorkBudget(trackedWait: null);
      settled = await policy.apply(
        tester,
        record: _sink,
        // The keyboard rides the same between-frames hook the real work does,
        // and for a related reason: it has to move *between* the policy's
        // frames or the slide is not in them. Writing the view schedules a
        // forced frame, so a bounded policy keeps pumping until it lands
        // rather than stopping halfway down.
        land: () async {
          _keyboard.step();
          await budget.land(tester, assets);
        },
      );
      // Frames are all a policy follows; work on the real event loop
      // schedules none while it is in flight. See [landRealWork].
      var landing = await landRealWork(
        tester,
        policy,
        settled: settled,
        budget: budget,
        assets: assets,
        record: _sink,
        beforePump: _keyboard.step,
      );
      (settled, landed) = (landing.settled, landing.landed);
      if (landing.guessed case var turn?) {
        _guessedSinceLastCapture = _deeper(_guessedSinceLastCapture, turn);
        var label = [?verb, ?target].join(' ');
        _state.guessed[label] = _deeper(_state.guessed[label], turn)!;
      }
      // After the landing and not before it: a strict policy is red about
      // a screen that *stays* animating, and a decode still on its way is
      // not that. The throw takes the ordinary failure path below, so the
      // failed step carries the frame that was still moving.
      if (policy.failsWhenUnsettled && !settled) {
        throw stillAnimating(policy, verb: verb, target: target);
      }
    } catch (error) {
      // The verb that broke captures its own frame; `scenario`'s catch is the
      // backstop for everything else. Both go through the same once-per-error
      // guard, so an error travelling up the stack yields one failed step.
      await _captureFailure(error, verb: verb, target: target);
      rethrow;
    } finally {
      if (inFlight != null) scenarioLastVerb = inFlight;
      scenarioVerbInFlight = null;
      markScenarioProgress();
    }
    _framesAtLastStep = _frames;
    await _afterStep(
      shot,
      settled: settled,
      waited: policy.waits,
      landed: landed,
      stray: stray,
      verb: verb,
      target: target,
      aim: _aim,
      adopt: adopt,
      autoShotNeedsFrames: autoShotNeedsFrames,
    );
    // After the capture rather than before it, so the film changes neither
    // what the step's picture is of nor whether a verb that drew nothing is
    // allowed to skip its shot.
    await _film?.dwell(tester);
    return result;
  }

  /// Forks the scenario: every branch runs, each in its own replay of the
  /// whole body — so each branch starts from the exact state this line was
  /// reached with, and the flow graph fans out here.
  ///
  /// ```dart
  /// await s.split({
  ///   'pay by card': () async {
  ///     await s.tap('Pay');
  ///     await s.screen('Receipt');
  ///   },
  ///   'payment fails': () async {
  ///     await s.tap('Pay');
  ///     await s.screen('Error dialog');
  ///   },
  /// });
  /// ```
  ///
  /// Steps before the split are captured once and shared; anything after the
  /// call runs per branch, since by then the paths have genuinely diverged.
  /// Splits nest. Under bare `flutter test` the replays run too, so CI
  /// asserts every path.
  ///
  /// What a replay does and does not reset. The widget tree is torn down
  /// and rebuilt from nothing, so each path starts from a fresh app. Anything
  /// *outside* the tree is not: a seeded repository, a registered singleton, a
  /// mock's recorded calls carry from one path into the next.
  ///
  /// The body is what re-runs, so the body is where per-path setup belongs:
  ///
  /// ```dart
  /// scenario('Around the shop', (s) async {
  ///   repo.seed();                          // every path gets a fresh one
  ///   await s.pumpWidget(const ShopApp());
  ///   await s.split({ ... });
  /// });
  /// ```
  ///
  /// A `setUp` will *not* do it. `setUp` runs once per test and a scenario is
  /// one test however many paths it has — which is `package:test`'s own rule,
  /// kept rather than bent: a `setUp` that fired three times for one test
  /// would be a surprise nothing in the file could explain, and its
  /// `tearDown` could not follow it (those run when the test ends).
  Future<void> split(Map<String, Future<void> Function()> branches) async {
    if (branches.isEmpty) return;
    var names = branches.keys.toList();
    var name = names[_state.plan.choose(names)];
    // A new segment: positions restart under the extended choice path, and
    // the branch's first capture wears the label.
    _ordinal = 0;
    _segment++;
    _pendingBranch = name;
    _branchTrail.add(name);
    try {
      await branches[name]!();
    } catch (error, stack) {
      // Annotated where the branch is, so a failure says which path reached
      // it. The original stack rides along, so the report still points at the
      // user's line; nested splits annotate innermost-first and the outer
      // ones leave the message alone.
      Error.throwWithStackTrace(_inContext(error), stack);
    }
  }

  Future<void> _afterStep(
    Shot? shot, {
    required bool settled,
    required bool waited,
    required bool landed,
    required int stray,
    String? verb,
    String? target,
    ScenarioAim? aim,
    bool adopt = false,
    bool autoShotNeedsFrames = false,
  }) async {
    // Nothing captures, so nothing drains: what the app did during this verb
    // belongs to whichever step captures next, which is the transition a
    // reader of that step will be looking at.
    if (identical(shot, Shot.skip)) return;
    if (shot == null && shots == Shots.manual) return;
    await _capture(
      shot,
      settled: settled,
      waited: waited,
      landed: landed,
      stray: stray,
      verb: verb,
      target: target,
      aim: aim,
      adopt: adopt,
      // A verb that declared its no-op a success, and drew nothing since the
      // last capture: the automatic shot would repeat that capture byte for
      // byte, so no step is taken — though the position is, see [_capture].
      // An explicit shot still captures: the author asked for a picture.
      noopSkip:
          shot == null &&
          autoShotNeedsFrames &&
          _frames == _framesAtLastCapture,
    );
  }

  /// [error] with the split branch that reached it, when there was one.
  Object _inContext(Object error) =>
      _branchTrail.isEmpty || error is ScenarioFailure
      ? error
      : ScenarioFailure(List.of(_branchTrail), error);

  /// The scenario flavor of the shared refusal wording: verbs read as `s.tap`,
  /// and `s.tester` is offered as the covered escape hatch.
  static const _messages = TargetMessages(
    prefix: 's.',
    coveredEscapeHatch:
        ' Use `s.tester` if you meant to hit whatever is on top.',
    blankScreenHint:
        'Nothing has rendered — there is no text on screen at all, so this '
        'is not something `s.scrollTo` can reach. A scenario runs under fake '
        'time: anything the app waits on for real — a database, a socket, an '
        'http call — never completes between pumps. Give it a turn with '
        '`await s.runAsync(() async { … })`.',
  );

  /// The actionability ladder every pointer verb climbs — shared with the
  /// live drive engine (`lib/src/drive/resolve.dart`), which runs the same
  /// checks with the same wording against a running app.
  late final TargetResolver _targetResolver = TargetResolver(
    tester,
    messages: _messages,
    pump: () => tester.pump(),
    ensureSemantics: () => _state.ensureSemantics(tester),
    describeScreen: _describeVisibleTexts,
    namedCovering: _keyboardOver,
  );

  /// The refusal for a target under the keyboard, or null when the keyboard is
  /// not what is over it.
  ///
  /// The refusal is deliberate. Without it the tap lands on the slab,
  /// which absorbs it, and the flow sails on: the verb reported success, the
  /// button was never pressed, and the failure surfaces three steps later as a
  /// screen that did not change. The generic covered sentence would be true —
  /// something absorbs the pointer — and would send the reader looking for an
  /// overlay that is not in their code.
  ///
  /// It does not offer `scrollTo`, and that was measured rather than
  /// assumed. `Scrollable.ensureVisible` stops the moment the target is
  /// inside the *viewport*, and in the app this refusal actually fires on —
  /// one that does not resize — the viewport runs under the keyboard. So the
  /// scroll succeeds, the target is still covered, and the very next verb is
  /// refused again. That is faithful: a row parked at the bottom of a list
  /// under a real keyboard is not reachable on a real phone either. The way
  /// past is to dismiss the keyboard.
  String? _keyboardOver(Offset center, String verb, String described) {
    if (!_keyboard.up || center.dy < _keyboardTop) return null;
    return '$described is behind the software keyboard, which covers the '
        'bottom ${_keyboard.height.round()} points of the screen, so '
        '`s.$verb` at its centre lands on the keyboard instead. If the app is '
        'meant to reach this while the keyboard is up, that is a layout '
        'problem: a `Scaffold` that resizes moves it out of the way. To carry '
        'the flow on: `await s.keyboard.dismiss()`.';
  }

  /// Where the keyboard's top edge is, in the logical pixels every box in a
  /// scenario is measured in.
  double get _keyboardTop {
    var view = tester.binding.renderViews.firstOrNull;
    var height = view?.size.height ?? 0;
    return height - _keyboard.height;
  }

  /// Resolves a verb's target and checks it names exactly one widget the
  /// pointer can actually reach.
  ///
  /// The same checks the underlying `tap` fails on anyway — made legible, and
  /// made *before* the action, so the message can say what to do rather than
  /// dump the matching render objects.
  Future<Finder> _resolve(dynamic target, String verb) async {
    try {
      return await _targetResolver.resolve(target, verb);
    } on TargetError catch (error) {
      throw ScenarioTargetError(error.message);
    }
  }

  String _describeVisibleTexts() {
    var texts = visibleTexts().where((t) => t.isNotEmpty).toList();
    if (texts.isEmpty) return 'none on screen';
    var shown = texts.take(20).map((t) => '"$t"').join(', ');
    return texts.length > 20 ? '$shown, …' : shown;
  }

  /// Resolves a verb's polymorphic target to a [Finder].
  @visibleForTesting
  Finder finderFor(dynamic target) => finderForTarget(target);

  /// The capture that has been rendered but not yet handed over.
  ///
  /// Held for exactly one step, because a [screen] that follows without
  /// moving the screen adopts its name — and adoption has to land before
  /// anything is written, every artifact's file name being built from the
  /// step's label. Handing over one step late is what allows it, and that is
  /// the only cost: a host drawing the flow live sees each step as the next
  /// one is taken, and the last is flushed when the body ends.
  _PendingEmit? _pending;

  /// Frameless beats — [document]s and [notification]s — emitted since
  /// [_pending] was rendered, still waiting behind it.
  ///
  /// They cannot go out first: their indices are higher than the held frame's,
  /// and a host drawing the flow live reads the order it is given. And they
  /// must not force the frame out, because nothing they do draws — so a
  /// `screen` after them still names the frame before them.
  final _pendingBeats = <_PendingEmit>[];

  /// Whether the capture being taken is the frame [_pending] already took.
  ///
  /// The frame counter carries it, and exactly rather than approximately: the
  /// binding draws no frame at all for a pump with nothing scheduled, so an
  /// untouched settled screen does not move it. Counted from the
  /// pending *capture* rather than from the last step, because the two are not
  /// the same line — a `Shot.skip` verb between them draws its frames like any
  /// other, and they are frames this screen would otherwise adopt away.
  ///
  /// Read here rather than at the top of the verb, so it spans the verb's own
  /// settle too: a `screen` acts on nothing, but its settle still lands work
  /// the verb before it left in flight, and an image arriving there is a
  /// different picture.
  ///
  /// The rest is bookkeeping that keeps a real second picture, or an unrelated
  /// step, from being swallowed by a name.
  ///
  /// This is the half that costs no render: frames and settledness are a
  /// *prediction* that the pixels did not move. Where the prediction says
  /// they may have, [_emit] gets a second chance on the rendered evidence —
  /// see its doc — so a "no" here is never the last word on an identical
  /// picture.
  bool _canAdopt({required bool settled}) {
    var pending = _adoptablePending();
    return pending != null &&
        // Nothing has been drawn since that capture, so the frame still
        // stands as it photographed it.
        _frames == pending.frames &&
        // Neither that capture nor this one is parked mid-flight: a settle
        // that gave up leaves an animation running, and *that* is one pump
        // away from different pixels.
        pending.settled &&
        settled;
  }

  /// The capture a name may still land on, or null — the render-free core
  /// both adoption paths share, so a refusal added here binds both.
  /// [_canAdopt] layers the frame-count prediction on it; [_emit]'s
  /// byte-proven path layers the rendered evidence instead.
  _PendingEmit? _adoptablePending() {
    var pending = _pending;
    if (pending == null) return null;
    // A name never overwrites a name.
    if (pending.name != null) return null;
    // And a name never lands on a capture with no picture in it.
    //
    // [ScenarioPixels.named] is the only mode this can happen in, and it is
    // structural rather than incidental: every other mode decides from the
    // *screen*, and adoption only happens where the screen has not moved, so
    // the held capture and the shot about to adopt it would decide alike. This
    // one decides from the *step* — and the capture a name may land on is
    // unnamed by the rule above, which is exactly the capture this mode
    // skipped. Without the refusal a store run's every shot adopts an empty
    // frame and the export writes nothing.
    if (pending.format == 'none' &&
        (scenarioRunArgs?.pixels ?? ScenarioPixels.all) ==
            ScenarioPixels.named) {
      return null;
    }
    // A failure's own picture is nobody's to rename. (A failure is flushed
    // the moment it is captured, so today this states the rule more than it
    // guards a reachable branch.)
    if (pending.failure != null) return null;
    // The pending capture is this replay's immediately preceding step —
    // false where that step was recognised from an earlier pass over a
    // shared `split` prefix, which leaves something older pending.
    if (!_lastCaptureFresh) return null;
    // And it was captured in this branch segment. A step from before the
    // fork is on every path, and a branch-local name has no business on it.
    // The capture's own segment rather than `_pendingBranch`, which a
    // branch-opening beat consumes while the pre-fork capture is still the
    // one pending — the label moving on does not move the step.
    if (pending.segment != _segment) return null;
    return pending;
  }

  /// Puts [shot]'s name on the capture waiting to be handed over, with
  /// everything the flow produced on the way to it.
  ///
  /// [drained] is the event buffer's contents, drained by the caller — the
  /// frame-exact path drains at the door, and the byte-proven path in [_emit]
  /// drained before it rendered, for the reason written there.
  ///
  /// The step now stands for the whole stretch up to the name, so the
  /// stretch's facts merge onto it rather than vanishing with the second
  /// picture: a settle that gave up on either side leaves the step saying
  /// so, stray frames stay counted, and overflows raised on the way are
  /// filed here rather than on whatever captures next.
  void _adoptOntoPending(
    Shot shot,
    (List<AppEvent>, int) drained, {
    required bool settled,
    required bool waited,
    required bool landed,
    int stray = 0,
    ScenarioMotionFrames? motion,
  }) {
    var pending = _pending!;
    pending.name = shot.name;
    pending.tags = shot.tags;
    // `waited` is only ever read beside a false `settled`, and there it has to
    // name the half that *produced* the false: two halves that each did what
    // they were told do not add up to a settle that gave up. So the merge is
    // over the pair rather than over either flag — one half that waited and
    // did not get it makes the stretch one that gave up, and a stretch with
    // none of those is parked however many policies waited inside it.
    var gaveUp = (!pending.settled && pending.waited) || (!settled && waited);
    pending.settled = pending.settled && settled;
    pending.waited = pending.settled || gaveUp;
    pending.landed = pending.landed && landed;
    pending.strayFrames += stray;
    pending.overflowErrors += _overflowsSinceLastCapture;
    _overflowsSinceLastCapture = 0;
    pending.guessed = _deeper(pending.guessed, _guessedSinceLastCapture);
    _guessedSinceLastCapture = null;
    // The events belong to the step wearing the name rather than to whichever
    // step captures next: they happened on the way to *this* frame, and this
    // frame is the pending capture. Rolling them forward — what a
    // non-capturing verb does with them — would file the request the flow
    // made here under a screen two taps later.
    var (events, dropped) = drained;
    // One step keeps one step's worth. The buffer caps each drain, and this
    // step is now the far side of two of them — so the overflow is counted
    // here the way the buffer counts its own, rather than quietly making one
    // step's `events.json` twice the size every other step's may be.
    var room = (maxAppEventsPerStep - pending.events.length).clamp(
      0,
      maxAppEventsPerStep,
    );
    if (events.length > room) {
      dropped += events.length - room;
      events = events.take(room).toList();
    }
    pending.events.addAll(events);
    pending.eventsDropped += dropped;
    if (motion == null) {
      // The frame-exact path: nothing was drawn, so every recorded frame is
      // a still of the picture the step already shows.
      _recorder?.discard();
      return;
    }
    // The byte-proven path drained the recording, because here frames *were*
    // drawn and the interval may have shown something — a snackbar in and
    // out on provably identical end pixels. Only the frames that moved are
    // kept, judged against the frame the step's own recording ended on (the
    // same recorder, so the same scale and format): the banked stills of a
    // quiet interval are that frame byte for byte, and a movie padded with
    // them reads as a transition that never happened.
    var before = pending.motion;
    var still = before.bytes.lastOrNull;
    var moving = [
      for (var frame in motion.bytes)
        if (still == null || !sameBytes(frame, still)) frame,
    ];
    if (moving.isEmpty && motion.dropped == 0) return;
    pending.motion = ScenarioMotionFrames(
      bytes: [...before.bytes, ...moving],
      width: before.bytes.isEmpty ? motion.width : before.width,
      height: before.bytes.isEmpty ? motion.height : before.height,
      dropped: before.dropped + motion.dropped,
    );
  }

  /// Hands the held capture over, to the listener or to disk.
  ///
  /// Nothing can adopt it afterwards: the name it has here is the name its
  /// files are called after.
  void _flushPending() {
    var frame = _pending;
    _pending = null;
    var beats = List.of(_pendingBeats);
    _pendingBeats.clear();
    for (var pending in [?frame, ...beats]) {
      _hand(pending);
    }
  }

  /// One held step, out.
  void _hand(_PendingEmit pending) {
    if (scenarioRunListener case var listener?) {
      listener(pending.toCapture());
      return;
    }
    var destination = _screenshotsDestination;
    if (destination == null) return;
    var label = pending.failure != null
        ? 'failed'
        : pending.name ?? pending.verb ?? 'step ${pending.index}';
    // The axis above the scenario: a matrix writes every combination under
    // one destination, and without it the last language to run would be the
    // only one on disk. The file above the scenario for the same reason, and
    // spelled the way the harness spells it (`<file>/<name>`): a name is
    // unique per file, not per suite, so two files naming the same screen
    // were overwriting each other step for step.
    var slug = assignment?.slug ?? '';
    var directory = Directory(
      '$destination/'
      '${slug.isEmpty ? '' : '${scenarioFileSafe(slug)}/'}'
      '${_source == null ? '' : '${scenarioFileSafe(_source)}/'}'
      '${scenarioFileSafe(_description)}',
    )..createSync(recursive: true);
    var prefix = '${pending.index}-';
    var base =
        '${directory.path}/$prefix'
        '${scenarioFileSafe(label, max: scenarioNameMax - prefix.length - '.png'.length)}';
    // What the step is a picture of, written as itself. This lane writes only
    // what a person would look at — no trees, no events — so a beat that is
    // not a screen writes its own content and nothing else.
    switch (pending.kind) {
      case ScenarioCaptureKind.screen:
        File('$base.png').writeAsBytesSync(pending.bytes!);
      case ScenarioCaptureKind.document:
        var name = (pending.fileName ?? pending.name ?? 'document').replaceAll(
          RegExp(r'[^A-Za-z0-9._-]+'),
          '_',
        );
        File('$base.$name').writeAsBytesSync(pending.payload!);
      case ScenarioCaptureKind.notification:
        // Three strings and no picture. Written anyway rather than skipped: a
        // destination directory that silently omits a beat reads as a flow
        // that never had one.
        File('$base.notification.json')
            .writeAsBytesSync(pending.notification!.encode());
      case ScenarioCaptureKind.setup:
        // Nothing to look at; written anyway, for the reason above.
        File('$base.setup.json').writeAsStringSync('{"ms": ${pending.ms}}');
    }
  }

  /// Captures one step.
  ///
  /// Under the flutterware runner the harness listens and receives the bytes.
  /// Standalone (bare `flutter test`), a screenshot is written only when a
  /// destination is configured — via
  /// `--dart-define=screenshots-destination=…` or the
  /// `SCREENSHOTS_DESTINATION` environment variable — and skipped otherwise,
  /// so plain CI runs pay nothing for it.
  Future<void> _capture(
    Shot? shot, {
    bool settled = true,
    bool waited = true,
    bool landed = true,
    int stray = 0,
    String? verb,
    String? target,
    ScenarioAim? aim,
    bool adopt = false,
    bool noopSkip = false,
  }) async {
    // Where this capture sits in the scenario's shape: the split choices
    // taken so far plus the count since the last one. Replays of a shared
    // prefix land on the same position — captured once, recognised after.
    var position = '${_state.plan.path}#${++_ordinal}';
    if (!_capturing) return;
    var parent = _lastPosition == null ? null : _state.emitted[_lastPosition!];
    if (_state.emitted.containsKey(position)) {
      // Already captured on an earlier replay — skip the rendering entirely,
      // but keep our place so the next new step's parent is right. The events
      // this replay collected on the way go with it: the step they belong to
      // was emitted on the first pass, with the events of *that* pass, and
      // appending these would multiply a shared prefix once per branch.
      appEventBuffer?.discard();
      _recorder?.discard();
      // What landed on the way to a step an earlier replay captured belongs
      // to that step. Left to ride, it was credited to the next step this
      // replay emits — a branch's first step, which guessed at nothing.
      _guessedSinceLastCapture = null;
      _lastCaptureFresh = false;
      _lastPosition = position;
      _pendingBranch = null;
      // The first pass took a capture at this very point, so the no-op skip
      // (see [_framesAtLastCapture]) keeps deciding the same way here as it
      // did there.
      _framesAtLastCapture = _frames;
      return;
    }
    if (noopSkip) {
      // The verb drew nothing since the last capture, so its automatic shot
      // would repeat that capture byte for byte. No step is taken — but the
      // position is consumed and mapped to the chain's head, exactly as an
      // adoption consumes its own. A decision that flips (a page that
      // scrolls only when its text is longer, a frame that lands only on
      // one pass) then costs one step's presence, never the alignment of
      // everything after it: drift comparisons and split replays keep
      // walking matching positions either way.
      //
      // The recorder's banked frames are discarded rather than left to
      // ride: zero frames drawn since the last capture means every one of
      // them is a byte-identical still of the picture already in the flow,
      // and left alone they pad the next step's movie and eat its frame
      // budget. The events keep riding, as a skipped shot's always have.
      _recorder?.discard();
      _guessedSinceLastCapture = null;
      _state.emitted[position] = _state.stepCount;
      _lastPosition = position;
      return;
    }
    // Nothing has moved since the last capture, so this is that capture with
    // a name on it. Adopting rather than rendering is the point: the second
    // picture is never taken, and the name lands on the step that already
    // carries the verb which produced the frame.
    //
    // Keyed like an emitted step so a later replay recognises the position
    // and skips it. The value is the *chain head* — what the step after this
    // one should call its parent — which is what every entry in this map has
    // always meant. Usually that is the step the name landed on; where a
    // frameless beat has been emitted since, it is the beat, and recording
    // the adopted step instead would fork the chain in two and leave the
    // aligner walking only one of them.
    if (adopt && shot != null && _canAdopt(settled: settled)) {
      _adoptOntoPending(
        shot,
        appEventBuffer?.drain() ?? (const <AppEvent>[], 0),
        settled: settled,
        waited: waited,
        landed: landed,
        stray: stray,
      );
    } else {
      // The frame count said no. Where the only doubt left is what the
      // render will show — the pending step still adoptable at its core —
      // the render below gets a second chance on the evidence.
      var adoptByPixels = adopt && shot != null && _adoptablePending() != null;
      var branch = _pendingBranch;
      _pendingBranch = null;
      if (!await _emit(
        parent: parent,
        branch: branch,
        shot: shot,
        settled: settled,
        waited: waited,
        landed: landed,
        stray: stray,
        verb: verb,
        target: target,
        aim: aim,
        position: position,
        adoptByPixels: adoptByPixels,
      )) {
        // The render threw and the binding swallowed it (reported, run
        // continues): the index [_emit] burned keeps this position from
        // aliasing a live step, and the baseline stays put — no picture was
        // taken, so nothing may later behave as though one was.
        _state.emitted[position] = _state.stepCount;
        _lastPosition = position;
        _lastCaptureFresh = false;
        return;
      }
    }
    // One tail for both: after an emit `stepCount` is the fresh step's
    // index; after an adoption it is the chain's head.
    _state.emitted[position] = _state.stepCount;
    _lastPosition = position;
    _lastCaptureFresh = true;
    _framesAtLastCapture = _frames;
  }

  /// Where a step the scenario breaks on belongs: its parent, its branch and
  /// its position.
  ///
  /// Usually where the flow is — the last step seen, and the branch label
  /// still owed if the branch has captured nothing yet. On a later replay's
  /// shared prefix that answer is wrong: every step around the break was
  /// captured by an earlier replay, so the last one seen is a trunk step that
  /// already has a branch hanging off it, and a second, unlabelled child there
  /// is one the aligner cannot walk past — everything below it went missing
  /// from a comparison, and a timeout there read as a step of the *previous*
  /// branch. So the break is placed where this replay was heading: the first
  /// step of the branch it had not reached, under the step the split forks
  /// from.
  ({int? parent, String? branch, String position}) _breakPlacement() {
    var parent = _lastPosition == null ? null : _state.emitted[_lastPosition!];
    if (_state.plan.upcoming case var upcoming?) {
      var trunk = _state.plan.path;
      var fork = parent;
      var deepest = -1;
      for (var MapEntry(key: position, value: index)
          in _state.emitted.entries) {
        var hash = position.lastIndexOf('#');
        if (hash < 0 || position.substring(0, hash) != trunk) continue;
        var ordinal = int.tryParse(position.substring(hash + 1)) ?? -1;
        if (ordinal > deepest) (deepest, fork) = (ordinal, index);
      }
      return (
        parent: fork,
        branch: upcoming.label,
        position: '${upcoming.path}#1',
      );
    }
    return (
      parent: parent,
      branch: _pendingBranch,
      position: '${_state.plan.path}#${_ordinal + 1}',
    );
  }

  /// The frame the scenario broke on.
  ///
  /// Captured whatever the shot policy says, since a failure is the step most
  /// worth having a picture of, and deliberately given no position key: it
  /// belongs to this replay's dead end, never to a shared prefix a later
  /// replay would recognise.
  Future<void> _captureFailure(
    Object error, {
    String? verb,
    String? target,
  }) async {
    // Compared unwrapped: `split` re-throws the same failure wearing its
    // branch, and that is one failure, not two.
    var root = error is ScenarioFailure ? error.error : error;
    if (!_capturing || identical(_capturedFailure, root)) return;
    _capturedFailure = root;
    var placed = _breakPlacement();
    await _emit(
      parent: placed.parent,
      branch: placed.branch,
      shot: null,
      settled: true,
      // The position this step *would* have had. A failure is never captured
      // twice, so nothing is keyed on it — but a comparison aligning two runs
      // needs somewhere to put it, and "the place the flow stopped" is the
      // only honest answer. See [_breakPlacement] for where that is.
      position: placed.position,
      // The verb that broke, on the step that records the break — a failed
      // step used to be the one step in a flow that could not say what it was
      // trying to do.
      verb: verb,
      target: target,
      aim: _aim,
      failure: '${_inContext(error)}',
    );
    // Handed over at once rather than held: a failure's picture is nobody's
    // to rename, and this replay is over — nothing is coming that could.
    _flushPending();
  }

  bool get _capturing =>
      scenarioRunListener != null || _screenshotsDestination != null;

  /// Whether this step's frame is worth rasterizing — see [ScenarioPixels].
  ///
  /// A failure always is, whatever the mode: a red step's picture is the first
  /// thing anybody opens, and a pass that photographed every screen except the
  /// one that broke would be the wrong economy by a wide margin.
  bool _wantsPixels(
    ScenarioScreenRead? screen, {
    Shot? shot,
    String? failure,
  }) => switch (scenarioRunArgs?.pixels ?? ScenarioPixels.all) {
    ScenarioPixels.all => true,
    ScenarioPixels.none => false,
    ScenarioPixels.named => failure != null || shot?.name != null,
    ScenarioPixels.keyed =>
      failure != null || (screen?.tree.translationKeys().isNotEmpty ?? false),
  };

  /// Renders the frame and holds it as the next [_pending] — or, when
  /// [adoptByPixels] is set and the render matches the held capture, puts
  /// [shot]'s name on that capture instead and discards the fresh picture.
  ///
  /// The comparison is adoption's second chance. [_canAdopt]'s frame count
  /// is a *prediction* that the screen did not move, and where it says it
  /// may have — extra settling between a verb and its name, a periodic
  /// timer repainting an identical screen — the render this step was about
  /// to pay anyway settles the question on evidence: the dimensions, the
  /// overlay style, the visible words, the shutter's tree read, and the
  /// bytes. Each is there because the ones before it cannot vouch for it —
  /// raw bytes carry no dimensions, a box-glyph test font rasters two
  /// different strings identically, and a semantics-only change never
  /// touches a pixel. Proven equal, the name lands on the pending step and
  /// nothing new is written; the settled flags stay out of the gate (they
  /// were only ever a prediction about this same evidence) and merge onto
  /// the adopted step instead. Never on a pixel-less probe pass: every
  /// probe capture holds the same empty bytes, which prove nothing.
  ///
  /// Answers false when the render threw and the binding swallowed it
  /// (reported, run continues): the held capture is still handed over, and
  /// an index is burned so the caller's position map cannot alias a live
  /// step.
  Future<bool> _emit({
    required int? parent,
    required String? branch,
    required Shot? shot,
    required bool settled,
    bool waited = true,
    bool landed = true,
    int stray = 0,
    String? verb,
    String? target,
    ScenarioAim? aim,
    required String position,
    String? failure,
    bool adoptByPixels = false,
  }) async {
    var listener = scenarioRunListener;
    // Drained here rather than inside `runAsync`: the capture itself sends
    // platform messages (and the spy records them), and those belong to the
    // *next* transition, not to the one being closed.
    var (events, dropped) = appEventBuffer?.drain() ?? (const <AppEvent>[], 0);
    var adopted = false;
    ScenarioMotionFrames? adoptedMotion;
    _PendingEmit? fresh;
    await tester.runAsync(() async {
      var view = tester.binding.renderViews.single;
      var layer = view.debugLayer! as OffsetLayer;
      // The root layer's coordinates are **physical** pixels — the
      // device-pixel-ratio transform sits inside it — so the capture rect
      // must be the physical frame or a 3× device saves its top-left ninth.
      //
      // The default *output* is logical (1×), measured, not guessed: on a
      // 50-screen scenario, physical 3× costs 22.4s and 56MB where 1× costs
      // 2.4s and 7MB — capture is the whole cost of a FakeAsync run, and 1×
      // is what keeps it feeling instantaneous. `captureScale` (up to the
      // device ratio for a true screenshot) is the host's knob when
      // fidelity is worth the wait.
      var dpr = view.flutterView.devicePixelRatio;
      var scale = scenarioCaptureScale(scenarioRunArgs, dpr);
      // Raw when the host asked for it — see `ScenarioRunArgs.captureRaw` for
      // what that trade actually is, which is not what it says on the tin.
      // Standalone runs always get PNG, which everything can open.
      var raw = listener != null && (scenarioRunArgs?.captureRaw ?? false);
      // Read before the picture rather than after it, and once, for the
      // adoption gate and the step alike: this capture waits a step before it
      // is handed over, and by then the app has moved on. Nothing pumps
      // between here and the rasterization below, so the read and the picture
      // are still the same frame — and [ScenarioPixels.keyed] needs the read
      // to decide whether there is a picture worth taking at all.
      // Visible-for-testing is exactly what the style read is: scenario code
      // only ever runs under the test binding.
      var texts = visibleTexts();
      var screen = scenarioScreenReader?.call();
      // ignore: invalid_use_of_visible_for_testing_member
      var style = SystemChrome.latestStyle;
      Uint8List bytes;
      String format;
      int width;
      int height;
      if (listener != null &&
          !_wantsPixels(screen, shot: shot, failure: failure)) {
        // Skipping the rasterization and the encode is what makes a probe
        // pass cheaper than the capture pass it rides beside. The dimensions
        // are still reported, because the survey computes screen share from
        // them.
        bytes = Uint8List(0);
        format = 'none';
        width = (view.size.width * scale).round();
        height = (view.size.height * scale).round();
      } else {
        var image = await layer.toImage(
          Offset.zero & (view.size * dpr),
          pixelRatio: scale / dpr,
        );
        var data = (await image.toByteData(
          format: raw ? ui.ImageByteFormat.rawRgba : ui.ImageByteFormat.png,
        ))!;
        (width, height) = (image.width, image.height);
        image.dispose();
        bytes = data.buffer.asUint8List();
        format = raw ? 'raw' : 'png';
      }
      // The held capture and this render are the same screen — dimensions,
      // overlay style, words, tree read, and bytes — so the name belongs on
      // the held one, and the fresh picture is discarded unwritten: cheaper,
      // not dearer, than the duplicate step it used to become. Cheap checks
      // first, and none redundant with the bytes: raw bytes carry no
      // dimensions, a test binding with no real font rasters two different
      // strings of one length as identical filled boxes, and a change the
      // shutter read sees — a semantics label, a flag — may touch no pixel.
      var pending = adoptByPixels ? _adoptablePending() : null;
      if (pending != null &&
          format != 'none' &&
          pending.width == width &&
          pending.height == height &&
          pending.bytes!.length == bytes.length &&
          pending.statusBrightness == style?.statusBarIconBrightness?.name &&
          pending.navBrightness ==
              style?.systemNavigationBarIconBrightness?.name &&
          listEquals(pending.texts, texts) &&
          _sameScreenRead(pending.screen, screen) &&
          sameBytes(pending.bytes!, bytes)) {
        // Frames were drawn on the way here, so the recording may hold a
        // real transition even though it ended on the same picture — drained
        // now, in the same `runAsync` for the reason on the drain below, and
        // sifted in [_adoptOntoPending].
        adoptedMotion =
            await _recorder?.drain(raw: raw) ?? ScenarioMotionFrames.empty;
        adopted = true;
        return;
      }
      // Drained in the same `runAsync` as the shot: this is where the
      // rasterization `toImageSync` deferred is finally paid, and paying it
      // once for the whole transition is the difference between a recording
      // that costs 10ms and one that costs 250.
      var motion =
          await _recorder?.drain(raw: raw) ?? ScenarioMotionFrames.empty;
      // Held rather than handed over, so a `screen` that names this same
      // frame can put its name here instead of taking a second picture. See
      // [_pending] — this is the one step of latency that buys it.
      fresh = _PendingEmit(
        index: ++_state.stepCount,
        parent: parent,
        branch: branch,
        name: shot?.name,
        tags: shot?.tags ?? const [],
        bytes: bytes,
        format: format,
        width: width,
        height: height,
        texts: texts,
        screen: screen,
        statusBrightness: style?.statusBarIconBrightness?.name,
        navBrightness: style?.systemNavigationBarIconBrightness?.name,
        verb: verb,
        target: target,
        aim: aim,
        position: position,
        events: List.of(events),
        eventsDropped: dropped,
        motion: motion,
        motionInterval: _recorder?.interval,
        settled: settled,
        waited: waited,
        landed: landed,
        strayFrames: stray,
        failure: failure,
        segment: _segment,
        overflowErrors: _overflowsSinceLastCapture,
        guessed: _guessedSinceLastCapture,
        frames: _frames,
        // What the screen lost to a keyboard when this was photographed. Read
        // here with the texts and the overlay style, for the reason written on
        // both: the hand-over is a step late and by then the app has moved on.
        keyboard: _keyboard.up ? _keyboard.height : null,
      );
      // Consumed only by a step that emits: an adoption above leaves the
      // count riding to the next capture, exactly as the frame-exact path
      // does.
      _overflowsSinceLastCapture = 0;
      _guessedSinceLastCapture = null;
    });
    if (adopted) {
      _adoptOntoPending(
        shot!,
        (events, dropped),
        settled: settled,
        waited: waited,
        landed: landed,
        stray: stray,
        motion: adoptedMotion,
      );
      return true;
    }
    if (fresh == null) {
      // The render closure threw; the binding reported the error and
      // completed with null. Burn an index so the position this capture
      // consumed can never alias a live step, and hand the held capture
      // over exactly as the old pre-render flush did.
      ++_state.stepCount;
      _flushPending();
      return false;
    }
    // Whatever was being held goes now: this capture took a frame of its
    // own, so it is not the name of the held one and nothing else can be
    // either.
    _flushPending();
    _pending = fresh;
    return true;
  }

  /// Whether two shutter reads describe the same screen — compared on the
  /// serialized form a step hands over anyway. Null on the lanes with no
  /// reader installed, where null == null is the honest answer.
  static bool _sameScreenRead(ScenarioScreenRead? a, ScenarioScreenRead? b) {
    if (a == null || b == null) return a == b;
    return jsonEncode(a.tree.toJson()) == jsonEncode(b.tree.toJson()) &&
        jsonEncode(a.semantics) == jsonEncode(b.semantics);
  }

  /// The visible text, in tree order — the projection an agent reads next to
  /// the screenshot. `EditableText` too, or what the user just typed into a
  /// `TextField` would be pixels only.
  List<String> visibleTexts() => visibleTextsOf(tester);

  /// Stands in for the define and the environment variable below, which are
  /// the two things a test process cannot change about itself: one is fixed at
  /// compile time and the other is read-only. Without it the standalone lane —
  /// what a bare `flutter test` writes, and the only lane a consumer's CI uses
  /// without the GUI — can be exercised nowhere but a subprocess.
  @visibleForTesting
  static String? screenshotsDestinationOverride;

  static String? get _screenshotsDestination {
    if (screenshotsDestinationOverride case var override?) return override;
    const define = String.fromEnvironment('screenshots-destination');
    if (define.isNotEmpty) return define;
    var env = Platform.environment['SCREENSHOTS_DESTINATION'];
    if (env != null && env.isNotEmpty) return env;
    return null;
  }
}

/// A capture that has been rendered but not yet handed over — see
/// [ScenarioTester._pending].
///
/// Mutable in exactly the places a following `screen` may still change: the
/// name, the tags, and what the flow produced on the way here — which an
/// adoption extends with the stretch's facts (settledness, strays, overflows,
/// the moving frames of its recording). The picture itself has been taken and
/// does not move.
class _PendingEmit {
  _PendingEmit({
    required this.index,
    required this.parent,
    required this.branch,
    required this.name,
    required this.tags,
    required this.verb,
    required this.target,
    required this.position,
    required this.events,
    required this.eventsDropped,
    required this.settled,
    required this.waited,
    required this.landed,
    required this.strayFrames,
    required this.failure,
    required this.frames,
    this.segment = 0,
    this.overflowErrors = 0,
    this.guessed,
    this.keyboard,
    this.aim,
    this.kind = ScenarioCaptureKind.screen,
    this.bytes,
    this.format,
    this.width,
    this.height,
    this.texts = const [],
    this.screen,
    this.statusBrightness,
    this.navBrightness,
    this.payload,
    this.fileName,
    this.mimeType,
    this.notification,
    this.ms,
    this.motion = ScenarioMotionFrames.empty,
    this.motionInterval,
  });

  final int index;
  final int? parent;
  final String? branch;

  /// The frame count when this picture was taken — the baseline a following
  /// `screen` proves nothing has been drawn since. Not the count at the end of
  /// the last *step*: a step whose shot was skipped captures nothing and still
  /// draws.
  final int frames;

  /// Null while the frame is anonymous — which is what makes it adoptable.
  /// A name arriving here from a later `screen` is indistinguishable
  /// afterwards from one the shot carried, and that is the point.
  String? name;
  List<String> tags;

  final ScenarioCaptureKind kind;
  final Uint8List? bytes;
  final String? format;
  final int? width;
  final int? height;
  final List<String> texts;

  /// The tree and the semantics behind [bytes], read at the shutter — see
  /// [ScenarioScreenRead] for why they cannot wait for the hand-over below.
  final ScenarioScreenRead? screen;
  final Uint8List? payload;
  final String? fileName;
  final String? mimeType;
  final ScenarioNotification? notification;
  final int? ms;
  final String? statusBrightness;
  final String? navBrightness;
  final String? verb;
  final String? target;

  /// Where the verb's finger went — see [ScenarioAim].
  final ScenarioAim? aim;

  final String position;
  final List<AppEvent> events;
  int eventsDropped;
  ScenarioMotionFrames motion;
  final Duration? motionInterval;
  bool settled;
  bool waited;
  bool landed;
  int strayFrames;
  final String? failure;

  /// The branch segment this step was captured in — see
  /// [ScenarioTester._segment].
  final int segment;

  /// See [ScenarioStepCapture.overflowErrors] — carried on the edge into this
  /// step, like [events].
  int overflowErrors;

  /// See [ScenarioStepCapture.guessed] — the deepest over the stretch an
  /// adoption extends this step with.
  int? guessed;

  /// How tall the software keyboard was when this frame was taken, in logical
  /// pixels — null when it was down, which is nearly every step.
  final double? keyboard;

  ScenarioStepCapture toCapture() => ScenarioStepCapture(
    index: index,
    parent: parent,
    branch: branch,
    name: name,
    tags: tags,
    kind: kind,
    bytes: bytes,
    format: format,
    width: width,
    height: height,
    texts: texts,
    screen: screen,
    payload: payload,
    fileName: fileName,
    mimeType: mimeType,
    notification: notification,
    ms: ms,
    statusBrightness: statusBrightness,
    navBrightness: navBrightness,
    verb: verb,
    target: target,
    aim: aim,
    position: position,
    events: events,
    eventsDropped: eventsDropped,
    motion: motion,
    motionInterval: motionInterval,
    settled: settled,
    waited: waited,
    landed: landed,
    strayFrames: strayFrames,
    failure: failure,
    overflowErrors: overflowErrors,
    guessed: guessed,
    keyboard: keyboard,
  );
}

int? _deeper(int? a, int? b) => a == null
    ? b
    : b == null
    ? a
    : a > b
    ? a
    : b;

/// What a scenario says to whatever is filming it — `s.film`.
///
/// A cue is an ordinary object the author already has, handed over here and
/// read back by an edit with a pattern:
///
/// ```dart
/// s.film.emit(Basket(count: 3));      // in the scenario
/// case Said(cue: Basket(:var count))  // in the edit
/// ```
///
/// There is no registry, no map and no cast — the class is the identity, and
/// because an edit runs in this same process the object arrives as itself.
/// Nothing is filming most of the time, and then every call here does nothing.
class ScenarioFilmVoice {
  ScenarioFilmVoice._(this._s);

  final ScenarioTester _s;

  /// Says [cue] at this point of the film.
  ///
  /// Instantaneous and free: it spends no fake time, draws no frame and takes
  /// no picture. What it marks is a *moment*, and what a stage does with the
  /// moment is the stage's business.
  void emit(Object cue) => _s._film?.say(cue);

  /// Whether anything is listening — false in an ordinary run.
  ///
  /// Rarely needed, because emitting into silence is already free. It is here
  /// for the cue whose *value* is expensive to compute.
  bool get isFilming => _s._film != null;
}

/// The software keyboard's own verbs — `s.keyboard`.
///
/// A scenario needs none of them for the ordinary case: tapping a field raises
/// a keyboard already. These are for the cases a flow cannot express on its
/// own — hold one up over a layout with nothing focused, swipe one away the way
/// a user does, or take one picture without it.
///
/// Each is a step like any other verb, so the flow shows the screen moving
/// rather than a screen that changed between two shots for no visible reason.
class ScenarioKeyboardVerbs {
  ScenarioKeyboardVerbs._(this._s);

  final ScenarioTester _s;

  /// Whether one is on screen.
  bool get isUp => _s._keyboard.up;

  /// Which keyboard is on screen — what the focused field asked for, and
  /// letters where nothing did.
  ///
  /// A `phone` or `number` field gets [KeyboardVariant.keypad], which on an
  /// iPhone is a measurably shorter keyboard as well as a different picture.
  KeyboardVariant get variant => _s._keyboard.variant;

  /// Whether the **app** has asked for one — a field has focus, and the
  /// framework told the platform so.
  ///
  /// Separate from [isUp] because the two genuinely differ, and reporting only
  /// one is how a control ends up lying: [hide] leaves this true with nothing
  /// on screen, and [show] leaves it false with a keyboard over a third of it.
  bool get isRequested => _s._keyboard.requested;

  /// How much of the screen it is taking, in logical pixels — 0 when down.
  double get height => _s._keyboard.height;

  /// Whether this stage has a keyboard at all: false on a desktop size, on a
  /// run staged as nothing, and in a folder that turned the feature off.
  /// Every verb below is a no-op when it is false.
  bool get isAvailable => _s._keyboard.deviceHeight > 0;

  /// Holds it up, focus or no focus — *what does this layout do with a third
  /// of the screen gone*, asked without hunting for a field to tap.
  ///
  /// Sticky: the app asking for the keyboard to go away no longer takes it
  /// away. [auto] hands it back, and so does [dismiss].
  Future<void> show({Shot? shot, Settle? settle}) =>
      _set(KeyboardMode.up, 'show', shot, settle);

  /// Holds it down, whatever the app asks for — one picture of the whole
  /// screen in the middle of a flow that is typing into it.
  Future<void> hide({Shot? shot, Settle? settle}) =>
      _set(KeyboardMode.down, 'hide', shot, settle);

  /// Back to following the app, which is where every scenario starts.
  Future<void> auto({Shot? shot, Settle? settle}) =>
      _set(KeyboardMode.auto, 'auto', shot, settle);

  /// The platform closing it without the app being touched — a swipe down on
  /// Android, the dismiss key on an iPad.
  ///
  /// Not the same as [hide], and the difference is the whole reason both
  /// exist: this makes the app *let go*. The focused field is unfocused, so
  /// anything the app does on losing focus — validating, committing a draft,
  /// collapsing a suggestion list — actually happens. [hide] leaves the field
  /// focused and takes the picture away.
  Future<void> dismiss({Shot? shot, Settle? settle}) => _s._step(
    shot,
    settle,
    () async {
      _s._aimAtKeyboard(0);
      _s._keyboard.dismiss();
    },
    verb: 'keyboard',
    target: 'dismiss',
  );

  Future<void> _set(
    KeyboardMode mode,
    String said,
    Shot? shot,
    Settle? settle,
  ) => _s._step(
    shot,
    settle,
    () async {
      _s._aimAtKeyboard(_s._keyboard.wantedFor(mode));
      _s._keyboard.jumpTo(mode);
    },
    verb: 'keyboard',
    target: said,
  );
}
