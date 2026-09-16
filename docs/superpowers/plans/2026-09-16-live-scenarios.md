# Live scenarios — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scenario folder can say `runScenarios(time: ScenarioTime.real)` and its scenarios then run on the real clock with real sockets, headless in `flutter_tester`, one guest per scenario and K at once, captured step by step exactly like a fake-time scenario, with the lane stamped on the report.

**Architecture:** The lane is a process property chosen once when the harness builds its binding: `_HarnessBinding` (FakeAsync) or a new `_LiveHarnessBinding` (a `LiveTestWidgetsFlutterBinding` that leaves HTTP alone, scales animation time around each body, and records platform messages through the same spy messenger). The runner learns the lane from the `ScenariosPackage` declaration, passes it into the generated entrypoint, and for a live package fans scenarios out over a pool of guests spawned from the one kernel. Everything above the binding — verbs, capture, report, flow view — is untouched; the tester skips the one thing that only exists for fake time (`landRealWork`).

**Tech Stack:** Dart 3 / Flutter 3.48.0-0.2.pre (pinned in `.fvmrc`), `flutter_test`'s `LiveTestWidgetsFlutterBinding`, `flutter_tester` spawned by `TesterHost` (`app/lib/src/embedder/tester_host.dart`), the scenario harness (`lib/src/scenarios/harness.dart`), the scenarios plugin (`app/lib/src/scenarios/runner.dart`).

**Spec:** `docs/superpowers/specs/2026-09-16-live-scenarios-findings-and-design.md` — decisions 1–9 are implemented here; decision 10 lists what is deliberately out.

## Global Constraints

- Every Flutter/Dart command goes through fvm: `fvm flutter …` / `fvm dart …`. Never the PATH `dart`/`flutter`. Root-package tests run with `fvm flutter test`, never `dart test`.
- Format only with `fvm dart tool/prepare_submit.dart` — never bare `dart format`.
- Lints: `var` for locals, single quotes, raw strings where they apply, no `final` parameters, `unawaited(...)` for fire-and-forget, no `const` beyond what the surrounding code already uses.
- **Nothing written here may name a client, their repository, their people or their product** — code, comments, tests, fixtures, commit messages, PR text. The consumer in the spec is "a consumer"; its backend is "a real backend".
- `lib/src/scenarios/` is **published** through `lib/flutter_test.dart`: new public names are exactly `ScenarioTime`, `runScenarios(time:)`, `ScenarioTester.setup`. Nothing else leaves `src/`.
- `lib/src/scenarios/time_mode.dart` imports no Flutter: the CLI reads it to validate `--time=` (same rule as `network_mode.dart`; `test/entry_point_purity_test.dart` fails the build otherwise).
- A refusal names what was wrong and what to write instead. Nothing is silently defaulted: an unknown `--time` value refuses; a folder and a package that disagree refuse at probe.
- No source spawns a bare `dart` or `flutter` (`test/ambient_sdk_test.dart`).
- GUI: tokens only (`context.colors`, `context.type`, `FwSpacing`), controls from `app/lib/src/ui/`.
- Commit titles name what changed and where, one plain line, no trailing period. Every commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- One PR at the end, not one per task. Commit only; never push.

## Corrections to the spec

None yet. Task 3 tests the two "measured and not yet explained" items (blank capture after a resize; frame-only settle) and writes what it found back into the spec's *What the substrate answers* section.

## File map

**Create**
- `lib/src/scenarios/time_mode.dart` — `ScenarioTime` (Flutter-free): `fake`, `real(animations:)`, `parseScenarioTime`, `scenarioTimeNames`.
- `lib/src/scenarios/live_binding.dart` — `LiveHarnessBinding`: the live-lane binding.
- `app/lib/src/scenarios/live_pool.dart` — `LiveScenarioPool`: K guests from one kernel, one scenario per request, respawn on failure.
- `test/scenarios/time_mode_test.dart`, `test/scenarios/live_lane/flutter_test_config.dart`, `test/scenarios/live_lane/live_lane_test.dart`, `test/scenarios/live_lane/live_capture_test.dart`, `test/scenarios/live_lane/missing_plugin_test.dart`, `test/scenarios/setup_beat_test.dart`.
- `fixtures/probe_app/test/live/flutter_test_config.dart`, `fixtures/probe_app/test/live/live_probe_test.dart` — three real-time scenarios against an `HttpServer` the scenario starts itself.
- `app/test/scenarios/live_pool_test.dart`, `app/test/scenarios/live_panel_test.dart`.

**Modify**
- `lib/src/scenarios/profile.dart` (`runScenarios`, the ambient/probed slots) — `time:`.
- `lib/src/scenarios/harness.dart` — `runHarness(time:)`, binding choice, `time` on the wire, probe agreement check, `MissingPluginException` refusal.
- `lib/src/scenarios/scenario.dart` — skip `landRealWork` under real time; `setup`.
- `lib/src/scenarios/network.dart` — default `live` under real time.
- `lib/src/scenarios/report.dart` — `time`, `animations` on `ScenarioRunReport`.
- `lib/src/scenarios/drift.dart` — no pixel drift for a live run.
- `lib/flutter_test.dart` — export `ScenarioTime`.
- `lib/src/plugins/first_party.dart` — `ScenariosPackage(time:)`.
- `app/lib/src/scenarios/harness_entrypoint.dart` — pass `time:`.
- `app/lib/src/scenarios/runner.dart` — `time`, `jobs`, pool fan-out.
- `app/lib/src/plugins/native/scenarios_plugin.dart` (the `run` action) — `--time`, `--jobs`.
- `app/lib/src/scenarios/browsing.dart` or the package header widget the panel uses — the `live` badge.
- `docs/superpowers/specs/2026-07-30-scenarios-design.md` — a § *Live lane* pointing at the new spec.
- `docs/capabilities.md` — regenerated.

---

### Task 1: `ScenarioTime` and its altitudes

**Files:**
- Create: `lib/src/scenarios/time_mode.dart`, `test/scenarios/time_mode_test.dart`
- Modify: `lib/src/scenarios/profile.dart:200-262` (`runScenarios` and the `scenarioProbed*` / `scenarioAmbient*` slots at 300-315), `lib/src/plugins/first_party.dart:247` (`ScenariosPackage`), `lib/flutter_test.dart`

**Interfaces:**
- Produces: `sealed class ScenarioTime { const fake; const real({double animations = 0.1}); bool get isReal; double get animations; String get name; }`, `ScenarioTime parseScenarioTime(String raw)` (refuses), `const scenarioTimeNames = ['fake', 'real']`, `runScenarios(time: ScenarioTime?)`, `ScenarioTime? scenarioProbedTime`, `ScenarioTime? scenarioAmbientTime`, `ScenariosPackage(time: ScenarioTime?)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/scenarios/time_mode_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/time_mode.dart';

void main() {
  test('parses the two names and refuses anything else', () {
    expect(parseScenarioTime('fake'), ScenarioTime.fake);
    expect(parseScenarioTime('real'), isA<ScenarioTimeReal>());
    expect(
      () => parseScenarioTime('wall'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('One of: fake, real'),
        ),
      ),
    );
  });

  test('real scales animations to a tenth unless told otherwise', () {
    expect(ScenarioTime.real().animations, 0.1);
    expect(ScenarioTime.real(animations: 1).animations, 1);
    expect(ScenarioTime.fake.animations, 1);
    expect(ScenarioTime.real().isReal, isTrue);
    expect(ScenarioTime.fake.isReal, isFalse);
  });

  test('the name is what the wire and the report say', () {
    expect(ScenarioTime.fake.name, 'fake');
    expect(ScenarioTime.real().name, 'real');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/scenarios/time_mode_test.dart`
Expected: FAIL — `time_mode.dart` does not exist.

- [ ] **Step 3: Write the mode file**

```dart
// lib/src/scenarios/time_mode.dart
/// What clock a scenario folder runs on.
///
/// A lane is a **process**: the harness picks its binding once, before any
/// scenario is declared, so this is said per folder — `runScenarios(time: …)`
/// in its `flutter_test_config.dart` — and mirrored on the `ScenariosPackage`
/// so the runner knows which harness to spawn. There is deliberately no
/// `scenario(time: …)`: a body written for fake time pays `Settle.elapse(5s)`
/// in five real seconds under the other clock.
///
/// Flutter-free on purpose, like `network_mode.dart`: the CLI validates
/// `--time=` with it and must not reach Flutter to do so.
library;

sealed class ScenarioTime {
  const ScenarioTime._();

  /// FakeAsync under `AutomatedTestWidgetsFlutterBinding`. The default, and
  /// what every scenario before 2026-09 ran on.
  static const ScenarioTime fake = ScenarioTimeFake._();

  /// The wall clock under `LiveTestWidgetsFlutterBinding`: real timers, real
  /// sockets, real work landing on its own. [animations] scales every
  /// ticker — 0.1 runs a 300ms page transition in 30ms, and a step's picture
  /// is taken after settle so the default loses nothing. A folder that films
  /// a transition says `animations: 1`.
  const factory ScenarioTime.real({double animations}) = ScenarioTimeReal._;

  bool get isReal;

  /// The ticker scale; 1 under [fake].
  double get animations;

  /// `fake` or `real` — the wire, the flag and the report all say this.
  String get name => isReal ? 'real' : 'fake';
}

final class ScenarioTimeFake extends ScenarioTime {
  const ScenarioTimeFake._() : super._();
  @override
  bool get isReal => false;
  @override
  double get animations => 1;
}

final class ScenarioTimeReal extends ScenarioTime {
  const ScenarioTimeReal._({this.animations = 0.1}) : super._();
  @override
  bool get isReal => true;
  @override
  final double animations;
}

/// [raw] as a mode, or a refusal listing the ones there are. `real` comes
/// with the default animation scale; the scale itself is not a flag.
ScenarioTime parseScenarioTime(String raw) => switch (raw) {
  'fake' => ScenarioTime.fake,
  'real' => ScenarioTime.real(),
  _ => throw ArgumentError.value(
    raw,
    'time',
    'Not a time mode. One of: ${scenarioTimeNames.join(', ')}',
  ),
};

const scenarioTimeNames = ['fake', 'real'];
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/scenarios/time_mode_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Thread `time:` through `runScenarios` and the declaration**

In `lib/src/scenarios/profile.dart`, next to `ScenarioNetwork? network,` in the `runScenarios` signature add `ScenarioTime? time,`; next to `scenarioProbedNetwork = network;` add `scenarioProbedTime = time;`; next to `scenarioAmbientNetwork = network;` add `scenarioAmbientTime = time;`; beside the two `ScenarioNetwork?` top-level slots (`scenarioAmbientNetwork`, `scenarioProbedNetwork`) add:

```dart
/// The folder's clock, as `runScenarios(time: …)` said it.
ScenarioTime? scenarioAmbientTime;

/// What the probe read from the folder's config, for the harness to check
/// against the package's declaration before it runs anything.
ScenarioTime? scenarioProbedTime;
```

Import `time_mode.dart` in `profile.dart`. In `lib/flutter_test.dart` add `export 'src/scenarios/time_mode.dart' show ScenarioTime;`.

In `lib/src/plugins/first_party.dart` at `class ScenariosPackage extends PluginPackage` add a field and constructor parameter beside `captureScale`:

```dart
  /// The folder's clock. `ScenarioTime.real` runs it on the wall clock with
  /// real sockets, one guest per scenario. Must agree with the folder's own
  /// `runScenarios(time: …)`; the harness refuses at probe when they differ.
  final ScenarioTime? time;
```

with `this.time,` in the constructor and `'time': time?.name` wherever the package serialises its fields (follow how `captureScale` reaches the runner — grep `captureScale` in `first_party.dart` and in `app/lib/src/plugins/native/scenarios_plugin.dart`, and carry `time` the same way).

- [ ] **Step 6: Analyze and run the profile tests**

Run: `fvm flutter analyze && fvm flutter test test/scenarios/profile_test.dart test/scenarios/time_mode_test.dart`
Expected: no analyzer issues, PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/src/scenarios/time_mode.dart lib/src/scenarios/profile.dart lib/src/plugins/first_party.dart lib/flutter_test.dart test/scenarios/time_mode_test.dart
git commit -m "Scenarios: declare a folder's clock with ScenarioTime, fake or real" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: The live harness binding

**Files:**
- Create: `lib/src/scenarios/live_binding.dart`, `test/scenarios/live_lane/flutter_test_config.dart`, `test/scenarios/live_lane/live_lane_test.dart`
- Modify: `lib/src/scenarios/harness.dart:137-160` (`runHarness` / `_runHarness` signatures, the `_HarnessBinding()` construction at ~163) and `:256-300` (`_HarnessBinding`, `_SpyMessenger`), `lib/src/scenarios/profile.dart` (`runScenarios`, bare lane), `app/lib/src/scenarios/harness_entrypoint.dart:20-47`

**Interfaces:**
- Consumes: `ScenarioTime` (Task 1).
- Produces: `class LiveHarnessBinding extends LiveTestWidgetsFlutterBinding` with `LiveHarnessBinding({required double animations, required TestDefaultBinaryMessenger Function(TestDefaultBinaryMessenger) wrapMessenger})`, `runHarness(scenarioMains, {configs, ScenarioTime time = ScenarioTime.fake})`, and the generated entrypoint's `time: ScenarioTime.real()` line.

- [ ] **Step 1: Write the failing lane test**

The lane lives in its own folder so its `flutter_test_config.dart` can say the clock, exactly as `test/scenarios/network_lane/` says its network.

```dart
// test/scenarios/live_lane/flutter_test_config.dart
import 'dart:async';

import 'package:flutterware/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, time: ScenarioTime.real());
```

```dart
// test/scenarios/live_lane/live_lane_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('the binding is live and http is real', (s) async {
    expect(
      WidgetsBinding.instance,
      isA<LiveTestWidgetsFlutterBinding>(),
      reason: 'a real-time folder runs under the live binding',
    );
    // A server the scenario owns: real sockets, no network weather.
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = 200
        ..write('hello')
        ..close();
    });
    addTearDown(() => server.close(force: true));

    var client = HttpClient();
    var response = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    ).then((r) => r.close());
    expect(response.statusCode, 200, reason: 'no 400 mock under real time');
    client.close();
  });

  scenario('a real timer fires on the wall clock', (s) async {
    var sw = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(45));
  });

  scenario('animations are scaled for the body only', (s) async {
    expect(timeDilation, 0.1);
    await s.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text('scaled')),
        ),
      ),
    );
    expect(timeDilation, 0.1);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/scenarios/live_lane`
Expected: FAIL — `runScenarios` has no `time:` effect yet; the first scenario fails on the binding type.

- [ ] **Step 3: Write the binding**

```dart
// lib/src/scenarios/live_binding.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';

/// The real-time lane's binding: `LiveTestWidgetsFlutterBinding` with three
/// things changed, each measured to be necessary on a consumer's suite.
///
/// - HTTP is left alone. The base class installs `flutter_test`'s 400 mock
///   whatever the binding, and only the integration_test binding flips it.
/// - Animation time is scaled **around the body**: the base class asserts
///   `timeDilation == 1.0` the moment the body returns, before any
///   `addTearDown` runs, so a test that sets it fails at its own end.
/// - Platform messages go through the harness's spy messenger, so a channel
///   call lands on the step like it does under fake time.
class LiveHarnessBinding extends LiveTestWidgetsFlutterBinding {
  LiveHarnessBinding({required this.animations, required this.wrapMessenger});

  /// The ticker scale while a body runs.
  final double animations;

  /// The harness's spy around the binding's own messenger.
  final TestDefaultBinaryMessenger Function(TestDefaultBinaryMessenger)
  wrapMessenger;

  @override
  bool get overrideHttpClient => false;

  @override
  TestDefaultBinaryMessenger createBinaryMessenger() =>
      wrapMessenger(super.createBinaryMessenger());

  // A hot reload schedules a warm-up frame; outside a test that frame
  // asserts. The same guard the fake-time binding carries.
  @override
  void scheduleWarmUpFrame() {
    if (inTest) super.scheduleWarmUpFrame();
  }

  @override
  Future<void> runTest(
    Future<void> Function() testBody,
    VoidCallback invariantTester, {
    String description = '',
  }) => super.runTest(
    () async {
      timeDilation = animations;
      try {
        await testBody();
      } finally {
        timeDilation = 1.0;
      }
    },
    invariantTester,
    description: description,
  );
}
```

- [ ] **Step 4: Let the harness choose it**

In `lib/src/scenarios/harness.dart`:

- `runHarness` and `_runHarness` gain `ScenarioTime time = ScenarioTime.fake` (named, after `configs`); `runHarness` forwards it.
- Where `_runHarness` does `var binding = _HarnessBinding();`, write:

```dart
  var binding = time.isReal
      ? LiveHarnessBinding(
          animations: time.animations,
          wrapMessenger: _SpyMessenger.new,
        )
      : _HarnessBinding();
```

  `_SpyMessenger` already takes the inner messenger as its one positional argument, so `_SpyMessenger.new` is the wrapper. If `binding` is typed `_HarnessBinding` further down (the `runAsync` watchdog override lives there), lift what both need onto a small interface or check the two call sites use only `TestWidgetsFlutterBinding` members; the `watchRunAsync` override is carried by `LiveHarnessBinding` too — add the same `runAsync` override there, importing `async_watchdog.dart`.
- Record `time` beside the other harness-wide state (the same place `scenarioProjectNetwork` is set from `args['networkDefault']` at ~204) as `scenarioHarnessTime = time;` — a new top-level `ScenarioTime scenarioHarnessTime = ScenarioTime.fake;` in `profile.dart`, read by Task 3 and Task 4.
- **Probe agreement.** Where the harness reads `scenarioProbedNetwork` after probing a folder's config, add:

```dart
      if (scenarioProbedTime case var folderTime?
          when folderTime.isReal != time.isReal) {
        throw StateError(
          'The folder says `runScenarios(time: ${folderTime.name})` and the '
          'package says `ScenariosPackage(time: ${time.name})`. A lane is a '
          'process, so both must agree — change one of them.',
        );
      }
```

In `app/lib/src/scenarios/harness_entrypoint.dart`, `generateHarnessEntrypoint` (the function whose buffer writes `harness.runHarness(`) gains `ScenarioTime time = ScenarioTime.fake`, and after the `configs: {…},` block writes:

```dart
  if (time.isReal) {
    buffer.writeln('  time: harness.ScenarioTime.real(animations: ${time.animations}),');
  }
```

(`harness.dart` must export or re-export `ScenarioTime` under its prefix: add `export 'time_mode.dart' show ScenarioTime;` to `harness.dart`.) The runner passes the package's `time` here in Task 5; until then the default keeps every existing package on the fake binding.

- **Bare lane.** In `runScenarios` (`profile.dart`), before `await loadScenarioFonts();` resolve the clock the way `network.dart` resolves `FW_NETWORK` — the argument, else the environment, else fake:

```dart
  var resolvedTime = time ??
      switch (Platform.environment['FW_TIME']) {
        null || '' => null,
        var raw => parseScenarioTime(raw),
      };
```

  (`profile.dart` is Flutter-side, so `dart:io` is fine there; `time_mode.dart` stays free of it.) Use `resolvedTime` for everything below, including `scenarioAmbientTime`. Then add:

```dart
  if (resolvedTime?.isReal ?? false) {
    var existing = TestWidgetsFlutterBinding.instance;
    if (existing is! LiveTestWidgetsFlutterBinding) {
      throw StateError(
        'runScenarios(time: real) needs the live binding, but '
        '${existing.runtimeType} is already initialized. In this folder\'s '
        'flutter_test_config.dart call `ensureLiveScenarioBinding()` instead '
        'of `TestWidgetsFlutterBinding.ensureInitialized()`, or call nothing '
        '— runScenarios initializes the right one.',
      );
    }
  }
```

  and above `runScenarios` add the door it names, in `profile.dart`:

```dart
/// The live binding, created once, for a folder that runs on the real clock
/// under bare `flutter test`. `runScenarios(time: real)` calls it; a config
/// that initializes a binding itself must call this rather than
/// `TestWidgetsFlutterBinding.ensureInitialized()`.
LiveTestWidgetsFlutterBinding ensureLiveScenarioBinding({
  double animations = 0.1,
}) {
  if (TestWidgetsFlutterBinding.instance case LiveTestWidgetsFlutterBinding b) {
    return b;
  }
  return LiveHarnessBinding(
    animations: animations,
    wrapMessenger: (inner) => inner,
  );
}
```

  `TestWidgetsFlutterBinding.instance` throws when nothing is initialized: wrap the read in the same `_instance == null` check `ensureInitialized` uses — read it as `BindingBase.checkInstance`-safe code: `WidgetsBinding.instance` is only readable after init, so use `TestWidgetsFlutterBinding.ensureInitialized()`'s sibling pattern: try `TestWidgetsFlutterBinding.instance` inside a `try { } on FlutterError { }` and create when it throws. Then in `runScenarios`, when `resolvedTime?.isReal ?? false`, call `ensureLiveScenarioBinding(animations: resolvedTime!.animations)` first and keep the refusal above for the mismatched case. Export `ensureLiveScenarioBinding` from `lib/flutter_test.dart` — it is a public name; add it to the Global Constraints list of published names in this plan when done (`ScenarioTime`, `runScenarios(time:)`, `ScenarioTester.setup`, `ensureLiveScenarioBinding`).

- [ ] **Step 5: Run the lane test to verify it passes**

Run: `fvm flutter test test/scenarios/live_lane`
Expected: PASS (3 scenarios). If the third fails with `timeDilation` read as 1.0 inside the body, the bare lane's `runScenarios` path is not going through `LiveHarnessBinding.runTest` — check that `scenario()` declares through `testWidgets`, which calls `binding.runTest`.

- [ ] **Step 6: Run the fake lanes to prove nothing moved**

Run: `fvm flutter test test/scenarios && fvm flutter analyze`
Expected: PASS, no analyzer issues. `test/scenarios/network_lane` in particular still runs under the fake binding.

- [ ] **Step 7: Commit**

```bash
git add lib/src/scenarios/live_binding.dart lib/src/scenarios/harness.dart lib/src/scenarios/profile.dart lib/flutter_test.dart app/lib/src/scenarios/harness_entrypoint.dart test/scenarios/live_lane
git commit -m "Scenarios: run a real-time folder under a live binding with real sockets" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: A step under real time — landing, settle, capture

**Files:**
- Create: `test/scenarios/live_lane/live_capture_test.dart`
- Modify: `lib/src/scenarios/scenario.dart:2090-2160` (`_step`, the `landRealWork` call at ~2143), `lib/src/scenarios/settle.dart` (doc only), `docs/superpowers/specs/2026-09-16-live-scenarios-findings-and-design.md` (write back what the capture test found)

**Interfaces:**
- Consumes: `scenarioHarnessTime` (Task 2).
- Produces: nothing new; `_step` behaves under both clocks.

- [ ] **Step 1: Write the failing tests**

```dart
// test/scenarios/live_lane/live_capture_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart';

/// A 1×1 red PNG, the smallest image `Image.network` decodes.
final _redPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  scenario('a network image lands inside the step that mounts it', (s) async {
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(_redPng)
        ..close();
    });
    addTearDown(() => server.close(force: true));

    await s.pumpWidget(
      MaterialApp(
        home: Image.network('http://127.0.0.1:${server.port}/red.png'),
      ),
    );
    var image = s.tester.widget<Image>(find.byType(Image));
    var stream = image.image.resolve(ImageConfiguration.empty);
    var loaded = false;
    stream.addListener(ImageStreamListener((_, _) => loaded = true));
    await s.settle();
    expect(loaded, isTrue, reason: 'the step waited for the real decode');
  });

  scenario('a capture at a phone size is not blank', (s) async {
    await s.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ColoredBox(color: Colors.red)),
      ),
    );
    var step = await s.screen('red');
    var png = File(step.image!).readAsBytesSync();
    // Decode through the same door the report reader uses and count colours.
    var decoded = await decodeImageFromList(png);
    var bytes = await decoded.toByteData();
    var colours = <int>{};
    for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
      colours.add(bytes.getUint32(i));
    }
    expect(
      colours.length,
      greaterThan(1),
      reason: 'a red scaffold under an app bar is at least two colours; one '
          'colour means the layer raster came back blank',
    );
  });
}
```

Give this folder a device in its config so the second scenario runs at a phone size: in `test/scenarios/live_lane/flutter_test_config.dart` pass `profile: ScenarioProfile('live', devices: [Devices.iphone13Mini])` beside `time:` (see `test/scenarios/profile_lane/flutter_test_config.dart` for the exact `ScenarioProfile` spelling in this tree). If `s.screen` returns no step object with an `image` path in the bare lane, read the newest PNG under the folder's output directory instead — `report_io.dart` names it.

- [ ] **Step 2: Run them to verify they fail**

Run: `fvm flutter test test/scenarios/live_lane/live_capture_test.dart`
Expected: the first scenario fails or hangs at `landRealWork` (a `runAsync` turn under a live binding is a real pass but `RealWorkBudget` polls the fake-time counters); the second is the measured-blank question and may pass or fail — record which.

- [ ] **Step 3: Skip the fake-time landing under real time**

In `_step` (`scenario.dart` ~2143) wrap the landing:

```dart
      // Real work is invisible only from inside a fake zone. On the wall
      // clock the decode, the socket and the frame it schedules are all on
      // the one loop the settle already follows.
      var landing = scenarioHarnessTime.isReal
          ? (settled: settled, landed: true, guessed: null)
          : await landRealWork(tester, policy, budget: budget, /* keep the existing arguments */);
```

(Keep whatever arguments the existing call passes; only the branch is new.) Import `profile.dart`'s `scenarioHarnessTime`.

If the capture scenario failed blank in Step 2: in `_emit` (~2885), before `layer.toImage`, under real time force a frame and wait for it —

```dart
      if (scenarioHarnessTime.isReal) {
        tester.binding.scheduleForcedFrame();
        await tester.binding.endOfFrame;
      }
```

— and re-run. If it still fails, the raster is being read from a layer the resize detached: read the view through `tester.binding.renderViews.single.debugLayer` **after** `await tester.pump()` rather than the cached `view`. Record the fix in the spec.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm flutter test test/scenarios/live_lane`
Expected: PASS (5 scenarios across the two files).

- [ ] **Step 5: Write the findings back**

In the spec's *What the substrate answers* section replace the paragraph beginning "Two things measured and not yet explained" with what Step 2 and Step 3 found — one sentence per item, with the fix if there was one. In `settle.dart`'s class comment for `Settle` add one paragraph:

```dart
/// Under `ScenarioTime.real` every duration here is a **real** one:
/// `tester.pump(interval)` on the live binding waits the interval on the wall
/// clock and then a real frame, so `upTo(5s)` reads "until quiet, at most
/// five real seconds" and `elapse(2s)` costs two real seconds. Nothing in the
/// policies changes; only what a second is.
```

- [ ] **Step 6: Commit**

```bash
git add lib/src/scenarios/scenario.dart lib/src/scenarios/settle.dart test/scenarios/live_lane/live_capture_test.dart docs/superpowers/specs/2026-09-16-live-scenarios-findings-and-design.md
git commit -m "Scenarios: land and capture a step on the wall clock without the fake-time landing" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Network defaults to live, the report says the clock, drift ignores live pixels

**Files:**
- Modify: `lib/src/scenarios/network.dart` (the resolver around `scenarioRunArgs?.network ?? _scenarioNetworkFromHost` at ~268-280), `lib/src/scenarios/report.dart` (`ScenarioRunReport` fields and JSON), `lib/src/scenarios/drift.dart`, `lib/src/scenarios/harness.dart` (write `time`/`animations` into the report it returns)
- Test: `test/scenarios/network_test.dart` (add a case), `test/scenarios/report_test.dart` (add a case), `test/scenarios/drift_test.dart` (add a case)

**Interfaces:**
- Consumes: `scenarioHarnessTime`.
- Produces: `ScenarioRunReport.time` (`String`, `'fake'`/`'real'`), `ScenarioRunReport.animations` (`double?`, only when real), `run.json` keys `time` and `animations`, `ScenarioDrift` skipping pixels when `time == 'real'`.

- [ ] **Step 1: Write the failing tests**

In `test/scenarios/network_test.dart` add:

```dart
  test('under real time an unstated network is live', () {
    scenarioHarnessTime = ScenarioTime.real();
    addTearDown(() => scenarioHarnessTime = ScenarioTime.fake);
    expect(resolveScenarioNetwork(stated: null, folder: null, project: null),
        ScenarioNetwork.live);
    expect(resolveScenarioNetwork(stated: null, folder: ScenarioNetwork.replay,
        project: null), ScenarioNetwork.replay);
  });
```

(`resolveScenarioNetwork` is the name to give the existing ladder if it is inline today — extract it as a top-level function with those three named parameters, returning the resolved mode; the existing tests in `network_test.dart` show the ladder's current shape.)

In `test/scenarios/report_test.dart` add:

```dart
  test('a live run says so, with its animation scale', () {
    var report = ScenarioRunReport.fromJson({
      ...minimalRunJson(),
      'time': 'real',
      'animations': 0.1,
    });
    expect(report.time, 'real');
    expect(report.animations, 0.1);
    expect(report.toJson()['time'], 'real');
    expect(ScenarioRunReport.fromJson(minimalRunJson()).time, 'fake');
  });
```

(`minimalRunJson()` is whatever helper the file already uses to build a valid `run.json` map; if none exists, write one that fills every required field with the smallest valid value, next to the test.)

In `test/scenarios/drift_test.dart` add:

```dart
  test('two live runs never drift by pixels', () {
    var before = runWithOnePngStep(color: 0xFFFF0000, time: 'real');
    var after = runWithOnePngStep(color: 0xFF00FF00, time: 'real');
    var drift = ScenarioDrift.between(before, after);
    expect(drift.pixelsChanged, isEmpty);
    expect(drift.note, contains('real clock'));
  });
```

(Use the file's existing fixture builder for a run with one PNG step; give it a `time:` parameter that writes the key into `run.json`. `pixelsChanged` and `note` are the names to use if the drift model has no such fields yet — add them; `note` is the one sentence the panel shows.)

- [ ] **Step 2: Run them to verify they fail**

Run: `fvm flutter test test/scenarios/network_test.dart test/scenarios/report_test.dart test/scenarios/drift_test.dart`
Expected: FAIL on the three new cases.

- [ ] **Step 3: Implement**

`network.dart`: at the bottom of the ladder, where nothing stated a mode, return `scenarioHarnessTime.isReal ? ScenarioNetwork.live : ScenarioNetwork.off`. Update the doc comment above it: "`off` under the fake clock, `live` under the real one — determinism is already spent once the timers are real."

`report.dart`: add `final String time;` and `final double? animations;` to `ScenarioRunReport`, defaulting `time` to `'fake'` when the key is absent so every report on disk still reads; write both in `toJson` (omit `animations` when null).

`harness.dart`: where the run report map is assembled for the `scenarios.run` reply (and the file it writes), add `'time': scenarioHarnessTime.name` and, when real, `'animations': scenarioHarnessTime.animations`.

`drift.dart`: when either report's `time == 'real'`, skip the pixel comparison, leave the status/settle/shape comparisons, and set `note = 'Pictures are not compared: this run was on the real clock against live data.'`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm flutter test test/scenarios/network_test.dart test/scenarios/report_test.dart test/scenarios/drift_test.dart test/scenarios/live_lane`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/scenarios/network.dart lib/src/scenarios/report.dart lib/src/scenarios/drift.dart lib/src/scenarios/harness.dart test/scenarios/network_test.dart test/scenarios/report_test.dart test/scenarios/drift_test.dart
git commit -m "Scenarios: a real-time run defaults its network to live, says its clock in the report, and is never pixel-compared" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The live pool — one kernel, K guests, one scenario each

**Files:**
- Create: `app/lib/src/scenarios/live_pool.dart`, `app/test/scenarios/live_pool_test.dart`, `fixtures/probe_app/test/live/flutter_test_config.dart`, `fixtures/probe_app/test/live/live_probe_test.dart`
- Modify: `app/lib/src/embedder/tester_host.dart:342` (`_spawnGuest` → a public `spawnGuest(dill)` returning a `TesterGuest` handle), `app/lib/src/scenarios/runner.dart:247-300` (constructor: `time`, `jobs`), `:373-470` (`run`: fan out when real), `app/lib/src/scenarios/harness_entrypoint.dart` (pass `time`), `app/lib/src/plugins/native/scenarios_plugin.dart` (`--time`, `--jobs` on `run`; carry the package's `time`), `fixtures/probe_app/tool/flutterware.dart` (declare the live folder)

**Interfaces:**
- Consumes: `ScenarioTime`, `runHarness(time:)`, the harness's `ext.flutterware.scenarios.run` taking `file` + `scenario`.
- Produces: `class TesterGuest { GuestVmService get vm; Future<void> kill(); }`, `TesterHost.spawnGuest(String dill) → Future<TesterGuest>`, `class LiveScenarioPool { LiveScenarioPool({required TesterHost host, required int jobs}); Future<List<Map<String, Object?>>> run(List<({String file, String scenario})> selection, Map<String, String> Function(({String file, String scenario})) argsFor); }`, `ScenarioRunner(time: ScenarioTime?, jobs: int?)`, `run(... , jobs: int?)`.

- [ ] **Step 1: Write the probe fixture**

```dart
// fixtures/probe_app/test/live/flutter_test_config.dart
import 'dart:async';

import 'package:flutterware/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, time: ScenarioTime.real());
```

```dart
// fixtures/probe_app/test/live/live_probe_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart';

/// Three scenarios, each owning a server, each slow enough that running
/// them one after another is measurably slower than three at once.
Future<HttpServer> _serve(String body) async {
  var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    request.response
      ..write(body)
      ..close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

Future<String> _fetch(HttpServer server) async {
  var client = HttpClient();
  var response = await client
      .getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))
      .then((r) => r.close());
  var body = await response.transform(const SystemEncoding().decoder).join();
  client.close();
  return body;
}

void main() {
  for (var word in ['one', 'two', 'three']) {
    scenario('fetches $word', (s) async {
      var server = await _serve(word);
      await s.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FutureBuilder<String>(
              future: _fetch(server),
              builder: (_, snap) => Text(snap.data ?? 'loading'),
            ),
          ),
        ),
      );
      await s.screen(word);
      expect(find.text(word), findsOneWidget);
    });
  }

  scenario('a failing scenario does not poison its neighbours', (s) async {
    await s.pumpWidget(MaterialApp(home: Text('about to fail')));
    throw StateError('deliberate');
  });
}
```

In `fixtures/probe_app/tool/flutterware.dart` add a second `ScenariosPackage` entry for the same package with `directory: 'test/live', time: ScenarioTime.real()` beside the existing one (the plugin's `packages:` is a list; two entries for one package with different directories is the shape this needs — if the plugin keys packages by path only, key them by `(path, directory)` in `app/lib/src/plugins/native/scenarios_plugin.dart` and in the panel's package list).

- [ ] **Step 2: Write the failing pool test**

```dart
// app/test/scenarios/live_pool_test.dart
@Tags(['gpu'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart' show ScenarioTime;
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart'; // whatever helper names the probe app root and the SDK; see sibling tests

void main() {
  test('a live package runs one guest per scenario and survives a red one',
      () async {
    var out = Directory.systemTemp.createTempSync('live_pool');
    addTearDown(() => out.deleteSync(recursive: true));
    var runner = ScenarioRunner(
      packageRoot: probeAppRoot,
      directory: 'test/live',
      flutterSdkRoot: flutterSdkRoot,
      time: ScenarioTime.real(),
      jobs: 3,
    );
    addTearDown(runner.dispose);

    var sw = Stopwatch()..start();
    var result = await runner.run(outDir: out.path);
    var wall = sw.elapsed;

    var scenarios = (result['scenarios'] as List).cast<Map<String, Object?>>();
    expect(scenarios, hasLength(4));
    expect(scenarios.where((s) => s['ok'] == true), hasLength(3));
    expect(
      scenarios.singleWhere((s) => s['ok'] == false)['name'],
      'a failing scenario does not poison its neighbours',
    );
    expect(result['time'], 'real');
    expect(result['jobs'], 3);
    // Three 400ms fetches plus three boots: well under the ~2s sequential cost.
    expect(wall, lessThan(const Duration(seconds: 6)));
    expect(
      File(p.join(out.path, 'run.json')).existsSync(),
      isTrue,
      reason: 'one merged report for the whole package',
    );
  });
}
```

Use the same fixture helpers and tags the neighbouring runner tests in `app/test/scenarios/` use for the probe app root and SDK root; the `gpu` tag follows `cd app && fvm dart test integration_test --exclude-tags gpu` in CLAUDE.md — check which directory the existing runner tests live in (`app/test/scenarios/` or `app/integration_test/`) and put this one beside them.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd app && fvm flutter test test/scenarios/live_pool_test.dart` (or the `dart test` form if the file lands under `integration_test/`)
Expected: FAIL — `ScenarioRunner` has no `time`/`jobs`.

- [ ] **Step 4: Expose guest spawning on the host**

In `tester_host.dart`, extract the body of `_spawnGuest(String dill)` into a public `Future<TesterGuest> spawnGuest(String dill)` that starts the process, waits for `program.readyLine`, connects a `GuestVmService`, and returns:

```dart
/// One running `flutter_tester` from a kernel this host compiled. The host's
/// own guest is one of these; a live pool holds several.
class TesterGuest {
  TesterGuest({required this.process, required this.vm});
  final Process process;
  final GuestVmService vm;

  Future<void> kill() async {
    process.kill();
    await process.exitCode;
  }
}
```

`_spawnGuest` becomes `_guest = await spawnGuest(dill); _vm = _guest.vm;`. Add `String get dillPath` returning the output dill `ensureGuest` built, so the pool spawns from the same kernel.

- [ ] **Step 5: Write the pool**

```dart
// app/lib/src/scenarios/live_pool.dart
import 'dart:async';
import 'dart:collection';

import '../embedder/tester_host.dart';

/// K guests from one kernel, one scenario per request.
///
/// Under a live binding one failure poisons the process — the binding's
/// `!inTest` assertion then fails every later test — so a guest that
/// answered a red scenario is killed and a fresh one takes its slot. A boot
/// is ~135ms; a poisoned guest is every remaining scenario red.
class LiveScenarioPool {
  LiveScenarioPool({required this.host, required this.jobs});

  final TesterHost host;
  final int jobs;

  Future<List<Map<String, Object?>>> run(
    List<({String file, String scenario})> selection,
    Map<String, String> Function(({String file, String scenario})) argsFor,
  ) async {
    var queue = Queue.of(selection);
    var results = <Map<String, Object?>>[];
    var dill = host.dillPath;

    Future<void> worker() async {
      var guest = await host.spawnGuest(dill);
      try {
        while (queue.isNotEmpty) {
          var next = queue.removeFirst();
          var reply = await guest.vm.requireExtension(
            'ext.flutterware.scenarios.run',
            argsFor(next),
          );
          results.add(reply);
          var outcomes = (reply['scenarios'] as List?) ?? const [];
          var red = outcomes.any((o) => (o as Map)['ok'] != true);
          if (red) {
            await guest.kill();
            guest = await host.spawnGuest(dill);
          }
        }
      } finally {
        await guest.kill();
      }
    }

    var workers = List.generate(
      jobs.clamp(1, selection.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    return results;
  }
}
```

(`requireExtension`'s exact signature is on `GuestVmService` — `app/lib/src/embedder/`; match it.)

- [ ] **Step 6: Fan out in the runner**

`ScenarioRunner` gains `ScenarioTime? time` and `int? jobs` (constructor, stored). `_ScenarioProgram` passes `time` to `generateHarnessEntrypoint`. In `run(...)`:

- when `time?.isReal != true`: unchanged.
- when real: after `await _host.ensureGuest()` (which compiles the kernel and starts the host's own guest — keep it, it also validates the build), call `ext.flutterware.scenarios.list` on it to get `[{file, name}]`, apply the request's `file`/`scenario`/`tag` filters to that list, then

```dart
      var pool = LiveScenarioPool(host: _host, jobs: jobs ?? _defaultJobs(selection.length));
      var replies = await pool.run(selection, (s) => {
        ...baseArgs,          // the same map the single-guest path sends: out, device, language, clock, network…
        'file': s.file,
        'scenario': s.scenario,
        'out': p.join(outDir, _slug(s.file, s.scenario)),
      });
```

  and merge: one `run.json` at `outDir` whose `scenarios` is the concatenation of every reply's, `ms` the wall time, `passed`/`failed` counted, `time: 'real'`, `animations`, `jobs`. Step image paths inside each reply are already worktree-relative (see `ScenarioRunStep.image`'s doc in `docs/capabilities.md`), so concatenation does not break them. Write it with the same `ScenarioRunReport` writer the single path uses. `_defaultJobs(n) => n.clamp(1, max(1, Platform.numberOfProcessors ~/ 2))`.

`scenarios_plugin.dart`'s `run` action gains `--time=` (validated with `parseScenarioTime`, overriding the package's declaration, stamped) and `--jobs=<int>`; `list`/`read` need nothing.

- [ ] **Step 7: Run the pool test and the fake-lane runner tests**

Run: `cd app && fvm flutter test test/scenarios/live_pool_test.dart && fvm flutter test test/scenarios/`
Expected: PASS. The wall-time assertion is the parallelism proof; if it fails on a loaded machine raise the bound to 10s and note the measured value in the commit body, never remove it.

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/scenarios/live_pool.dart app/lib/src/embedder/tester_host.dart app/lib/src/scenarios/runner.dart app/lib/src/scenarios/harness_entrypoint.dart app/lib/src/plugins/native/scenarios_plugin.dart app/test/scenarios/live_pool_test.dart fixtures/probe_app/test/live fixtures/probe_app/tool/flutterware.dart
git commit -m "Scenarios runner: fan a real-time package out over a pool of guests from one kernel" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: A plugin with no host is a named refusal

**Files:**
- Create: `test/scenarios/live_lane/missing_plugin_test.dart`
- Modify: `lib/src/scenarios/harness.dart` (the `_runScenario` error chain where `ScenarioNetworkRefusal` is already filtered)

**Interfaces:**
- Produces: `class ScenarioPluginRefusal implements Exception { final String channel; final String method; String toString(); }`.

- [ ] **Step 1: Write the failing test**

```dart
// test/scenarios/live_lane/missing_plugin_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('a channel nobody answers fails with the two fixes', (s) async {
    const channel = MethodChannel('probe/nobody');
    Object? error;
    try {
      await channel.invokeMethod<void>('ping');
    } catch (e) {
      error = e;
    }
    // The refusal is what the harness turns the exception into when it
    // reaches the scenario's failure; here we check the rewrite directly.
    var refusal = describePluginFailure(error!);
    expect(refusal, contains('probe/nobody'));
    expect(refusal, contains('ping'));
    expect(refusal, contains('has no host on flutter_tester'));
    expect(refusal, contains('setMockMethodCallHandler'));
    expect(refusal, contains('inject'));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/scenarios/live_lane/missing_plugin_test.dart`
Expected: FAIL — `describePluginFailure` is not defined.

- [ ] **Step 3: Implement the rewrite**

In `harness.dart` (exported through `lib/flutter_test.dart` as `describePluginFailure`):

```dart
/// A `MissingPluginException` as a sentence a scenario author can act on.
///
/// The exception names the channel and the method; what it does not say is
/// that this is expected on `flutter_tester` — there is no plugin registrant
/// — and that the fix is one of two lines the fake-time lane already uses.
/// Anything that is not that exception comes back as its own `toString`.
String describePluginFailure(Object error) {
  if (error is! MissingPluginException) return error.toString();
  var text = error.message ?? '';
  var method = RegExp(r'method (\S+) on channel').firstMatch(text)?.group(1);
  var channel = RegExp(r'on channel (\S+)').firstMatch(text)?.group(1);
  return 'Channel ${channel ?? '?'} (method ${method ?? '?'}) has no host on '
      'flutter_tester: a plugin\'s platform half never runs here. Either '
      'inject the value the app reads from it, or answer the channel in the '
      'folder\'s config: '
      'TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger'
      '.setMockMethodCallHandler(const MethodChannel(\'${channel ?? ''}\'), '
      '(_) async => …).';
}
```

In `_runScenario`'s error chain, where a failure's message is composed for the report, pass the caught error through `describePluginFailure` so the report's `error` field carries the sentence (the original stack stays beside it).

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/scenarios/live_lane/missing_plugin_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/scenarios/harness.dart lib/flutter_test.dart test/scenarios/live_lane/missing_plugin_test.dart
git commit -m "Scenarios: name the channel and the fix when a plugin has no host on flutter_tester" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `s.setup` — a beat with a duration and no picture

**Files:**
- Create: `test/scenarios/setup_beat_test.dart`
- Modify: `lib/src/scenarios/scenario.dart` (`ScenarioTester`, beside `document()` / `notification()` — see `test/scenarios/beats_test.dart` for how those steps are asserted), `lib/src/scenarios/report.dart` (`ScenarioStepKind.setup`)

**Interfaces:**
- Produces: `Future<T> ScenarioTester.setup<T>(String name, Future<T> Function() body)`, `ScenarioStepKind.setup`, a step with `kind: 'setup'`, `name`, `ms`, no `image`, and the events (network exchanges included) that happened during the body.

- [ ] **Step 1: Write the failing test**

```dart
// test/scenarios/setup_beat_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart';

import 'raster_fixture.dart'; // the folder's helper for reading a run's steps back; see beats_test.dart

void main() {
  scenario('setup is a step of its own', (s) async {
    var token = await s.setup('fresh account', () async {
      await Future<void>.delayed(Duration.zero);
      return 'token-1';
    });
    expect(token, 'token-1');
    await s.pumpWidget(MaterialApp(home: Text(token)));
    await s.screen('home');
  });

  test('the report lists the setup beat before the first picture', () async {
    var steps = await stepsOfLastRun('setup is a step of its own');
    expect(steps.first.kind, 'setup');
    expect(steps.first.name, 'fresh account');
    expect(steps.first.image, isNull);
    expect(steps.first.ms, isNonNegative);
    expect(steps[1].name, 'home');
  });
}
```

(`stepsOfLastRun` is whatever `beats_test.dart` uses to read the current run's steps; reuse it by name. If it is private there, move it into `raster_fixture.dart` or a sibling helper and use it from both.)

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/scenarios/setup_beat_test.dart`
Expected: FAIL — `setup` is not defined on `ScenarioTester`.

- [ ] **Step 3: Implement**

Add `setup` to `ScenarioStepKind` in `report.dart` (with the one-line doc: "Work done before the flow — an account created through the API, a database seeded — captured for its duration and its exchanges, never its pixels."). In `ScenarioTester`, beside `document`:

```dart
  /// Runs [body] as a step with a duration and no picture.
  ///
  /// The body runs in-process, so the network funnel already records its
  /// exchanges on this step. A consumer's "create an account through the
  /// API, read the confirmation mail, confirm it" becomes visible on the
  /// flow without changing.
  Future<T> setup<T>(String name, Future<T> Function() body) async {
    late T result;
    await _beat(
      kind: ScenarioStepKind.setup,
      name: name,
      verb: 'setup',
      body: () async {
        result = await body();
      },
    );
    return result;
  }
```

where `_beat` is the private routine `document()` and `notification()` already share to record a non-picture step with its `ms` and events (name it `_beat` if it is inline in those two today, and have them call it). Under fake time, `body` runs inside `tester.runAsync` so a real await completes; under real time it runs directly.

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/scenarios/setup_beat_test.dart test/scenarios/beats_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/scenarios/scenario.dart lib/src/scenarios/report.dart test/scenarios/setup_beat_test.dart
git commit -m "Scenarios: s.setup records preparatory work as a beat with its duration and exchanges" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: The studio says which clock, and the docs say the lane exists

**Files:**
- Create: `app/test/scenarios/live_panel_test.dart`
- Modify: the scenarios panel's package header (find it by grepping `directory` in `app/lib/src/scenarios/browsing.dart` and the panel widget `app/test/scenarios/panel_test.dart` builds), `docs/superpowers/specs/2026-07-30-scenarios-design.md`, `docs/capabilities.md` (generated)

- [ ] **Step 1: Write the failing panel test**

```dart
// app/test/scenarios/live_panel_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'panel_test.dart' show pumpScenariosPanel; // the sibling's builder; export it if private

void main() {
  testWidgets('a real-time package carries a live badge', (tester) async {
    await pumpScenariosPanel(tester, packages: [
      fakePackage(directory: 'test/scenarios', time: 'fake'),
      fakePackage(directory: 'test/live', time: 'real'),
    ]);
    expect(find.text('live'), findsOneWidget);
  });
}
```

(`fakePackage` is the fixture `panel_test.dart` uses for a listed package; give it a `time` parameter that lands where the package header reads it.)

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && fvm flutter test test/scenarios/live_panel_test.dart`
Expected: FAIL — no `live` text.

- [ ] **Step 3: Draw the badge, regenerate, document**

In the package header, beside the directory name, when the package's `time` is `'real'` add a small label built from tokens (`context.type.caption`, `context.colors.accent` background at low opacity, `FwSpacing.xs` padding, `context.radii.small`) with the text `live` and a tooltip "Runs on the real clock with real sockets; pictures are not compared between runs." Look at how the panel draws its existing count chips and copy that anatomy rather than inventing one.

Regenerate the capabilities doc: `cd app && fvm dart run tool/generate_capabilities.dart` (the header of `docs/capabilities.md` names this file). Check the diff shows `--time` and `--jobs` on `scenarios run` and `time`/`animations`/`jobs` on `ScenarioRunResult`.

In `docs/superpowers/specs/2026-07-30-scenarios-design.md` add a short section after *The API — three layers*:

```markdown
## The live lane (2026-09-16)

A folder may run on the real clock: `runScenarios(time: ScenarioTime.real())`
in its `flutter_test_config.dart`, mirrored on its `ScenariosPackage`. Same
`scenario()`, same verbs, same report; the harness picks a
`LiveTestWidgetsFlutterBinding` instead of FakeAsync, sockets are real,
animations run at a tenth, the network defaults to `live`, and the runner
spawns one guest per scenario from the one kernel. Findings, numbers and
decisions: `2026-09-16-live-scenarios-findings-and-design.md`.
```

- [ ] **Step 4: Run the tests, the analyzer, the formatter**

Run: `cd app && fvm flutter test test/scenarios/ && cd .. && fvm flutter analyze && fvm dart tool/prepare_submit.dart && git status --short`
Expected: PASS, no issues, and the formatter changes nothing beyond what it just formatted (stage those).

- [ ] **Step 5: Commit**

```bash
git add -A app/lib/src/scenarios app/test/scenarios/live_panel_test.dart docs/capabilities.md docs/superpowers/specs/2026-07-30-scenarios-design.md
git commit -m "Scenarios panel: badge a real-time package, and document the live lane" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The whole thing, end to end, through the studio

**Files:**
- No new source. `fixtures/probe_app/test/live/` (Task 5), the MCP tools.

- [ ] **Step 1: Run the live probe through the plugin the way an agent would**

With the flutterware MCP connected (CLAUDE.md § Driving the running GUI), from a session on this checkout:

`flutterware_invoke scenarios/run {package: fixtures/probe_app, file: test/live/live_probe_test.dart}`

Expected: the reply has `time: real`, `jobs: 3`, `passed: 3`, `failed: 1`, and the red scenario's `error` is the deliberate `StateError`, not a binding assertion. Then `flutterware_invoke scenarios/read {}` with no arguments reads the red step.

- [ ] **Step 2: Run it under bare `flutter test`**

Run: `cd fixtures/probe_app && fvm flutter test test/live`
Expected: 3 pass, 1 fails with the deliberate error, and — because bare `flutter test` runs the file in one process — the three that follow the red one are still green, which proves `scenario()`'s own cleanup under the live binding (if they are not, the binding needs `postTest` to clear `_pendingFrame` state: override `postTest` in `LiveHarnessBinding` to swallow the `!inTest` case after a failed body and re-check).

- [ ] **Step 3: Run the full root and app suites**

Run: `fvm flutter test && cd app && fvm flutter test && fvm dart test integration_test --exclude-tags gpu`
Expected: PASS everywhere.

- [ ] **Step 4: Final format and a single PR**

Run: `fvm dart tool/prepare_submit.dart`, commit any formatting as `Format` if it produced a diff. Open **one** PR titled `Scenarios: a real-time lane with real sockets, one guest per scenario` whose body links the spec, lists the eight commits, and quotes the measured table from the spec. Do not push until the owner says so.

---

## Self-review

**Spec coverage.** Decision 1 (folder is the lane, mirrored on the package, refused when they disagree) — Tasks 1, 2. Decision 2 (altitudes: package, folder, run, env) — Task 1 declares, Task 2 reads the folder and `FW_TIME`, Task 5 adds `--time`. Decision 3 (animations at 0.1 by default, on the report) — Tasks 2, 4. Decision 4 (network defaults to live) — Task 4. Decision 5 (pool) — Task 5. Decision 6 (settle meaning, `landRealWork` skipped) — Task 3. Decision 7 (plugin refusal) — Task 6. Decision 8 (`s.setup`) — Task 7. Decision 9 (no pixel drift) — Task 4. Decision 10 (out of scope) — nothing here touches the dev stack, a fresh-user command, a device lane or `waitFor`.

**Placeholders.** None of "TBD"/"TODO"/"handle edge cases". Two steps tell the implementer to match an existing signature by name (`requireExtension`, `stepsOfLastRun`, `pumpScenariosPanel`) because those names exist in the tree today; each says where to look.

**Type consistency.** `ScenarioTime.real()` is a factory with `animations` defaulting to 0.1 (Task 1) and is called that way in Tasks 2, 5. `scenarioHarnessTime` is declared in Task 2 (`profile.dart`) and read in Tasks 3, 4. `TesterGuest`/`spawnGuest`/`dillPath` are declared in Task 5 Step 4 and used in Step 5. `describePluginFailure` is declared and exported in Task 6. `ScenarioStepKind.setup` is declared in Task 7 before use.
