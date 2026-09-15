@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/scenarios/authoring.dart';
import 'package:flutterware_app/src/scenarios/axes.dart';
import 'package:flutterware_app/src/scenarios/harness_entrypoint.dart';
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:path/path.dart' as p;

/// End-to-end: the real `fixtures/probe_app` package, a real `flutter_tester`,
/// a real run. Slow (a cold harness compile), so everything is exercised in
/// one warm sequence rather than one test per assertion.
void main() {
  test('lists, runs, and writes the step triple', () async {
    var flutterRoot = Platform.environment['FLUTTER_ROOT'];
    expect(
      flutterRoot,
      isNotNull,
      reason: 'flutter test always sets FLUTTER_ROOT',
    );
    // app/ → the repo root, the workspace this test runs in.
    var repoRoot = Directory.current.parent.path;
    var packageRoot = p.join(repoRoot, 'fixtures', 'probe_app');
    var outDir = Directory.systemTemp.createTempSync('scenario_run').path;

    // A project clock, so the run below proves `fw.clock(...)` reaches the
    // guest rather than only compiling. Deliberately not the default pin.
    var projectClock = DateTime(2031, 3, 4, 5, 6, 7);
    var runner = ScenarioRunner(
      packageRoot: packageRoot,
      directory: 'test/scenarios',
      flutterSdkRoot: flutterRoot!,
      projectClock: projectClock,
    );
    try {
      var listed = await runner.list();
      expect([
        for (var s in listed) '${s.file} ${s.name}',
      ], contains('test/scenarios/counter_test.dart Counter'));

      // Each step is also announced mid-run over the VM service — the
      // streaming half; the blocking response stays the complete report.
      var streamed = <Map<String, Object?>>[];
      runner.onStep = streamed.add;

      var report = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/counter_test.dart',
        scenario: 'Counter',
      );
      // What the run says it ran at — stated because a pinned date is only
      // safe while it is said out loud, and here it is the project's, which
      // nobody passed to this call.
      expect(report['clock'], projectClock.toIso8601String());
      var scenarios = (report['scenarios']! as List)
          .cast<Map<String, dynamic>>();
      expect(scenarios, hasLength(1));
      var counter = scenarios.single;
      expect(counter['ok'], isTrue, reason: '${counter['errors']}');

      var steps = (counter['steps']! as List).cast<Map<String, dynamic>>();
      // `pumpWidget`, two taps — the second carrying a named shot — and an
      // `enterText`. The `screen('Labelled')` that follows it is *not* a fifth:
      // nothing was drawn between the two, so it names the enterText's picture
      // rather than taking the same one again.
      expect(steps, hasLength(4));
      expect([
        for (var s in steps) s['name'],
      ], containsAll(['Counted to two', 'Labelled']));
      for (var step in steps) {
        var png = File(step['image']! as String);
        expect(png.existsSync(), isTrue);
        expect(png.lengthSync(), greaterThan(1000));
        expect(step['format'], 'png');
        var tree = jsonDecode(
          File(step['tree']! as String).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(tree['root'], isNotNull);
        // The fourth leg: what a screen reader gets, beside the widget tree.
        var semantics = jsonDecode(
          File(step['semantics']! as String).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(semantics['rect'], isNotNull);
        expect(semantics['children'], isNotEmpty);
      }
      // Nothing here stalled: the count moved on every tap and the last step
      // typed into a field. Both used to be flagged, the tree being blind to
      // typed text and — until the read moved to the shutter — a step behind
      // the picture besides.
      expect(steps.every((s) => s['unchanged'] == null), isTrue);
      // The tree beside the picture is the picture's own: `pumpWidget`
      // photographed `Count: 0`, whatever the two taps after it did.
      expect(
        File(steps.first['tree']! as String).readAsStringSync(),
        contains(r'Count: 0'),
      );
      expect(
        (steps.first['texts']! as List).cast<String>(),
        contains('Count: 0'),
      );

      var last = steps.last;
      expect((last['texts']! as List).cast<String>(), contains('a label'));
      // The adopted name, on the step whose verb produced the frame.
      expect(last['name'], 'Labelled');
      expect(last['verb'], 'enterText');

      expect(streamed, hasLength(4));
      expect(streamed.first['scenario'], 'Counter');
      expect((streamed.first['step']! as Map)['index'], 1);
      runner.onStep = null;

      // A run that names its own clock beats the project's, and the report
      // follows. After `onStep` is dropped: these steps are not the four the
      // streaming half is counted on.
      var overridden = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/counter_test.dart',
        scenario: 'Counter',
        clock: DateTime.utc(2029, 12, 25, 8),
      );
      expect(
        overridden['clock'],
        DateTime.utc(2029, 12, 25, 8).toIso8601String(),
      );

      // A run that did not ask records nothing — the CLI lane, and what keeps
      // it costing what it always cost.
      expect(steps.every((s) => s['frames'] == null), isTrue);
      // Every step of this one is a screen, so none carries a payload.
      expect(steps.every((s) => s['kind'] == null), isTrue);
      expect(steps.every((s) => s['file'] == null), isTrue);

      // A flow whose beats are not all screens: what it produced is a step of
      // the run, in the place it happened, with its own index and its own
      // stem on disk.
      var produced = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/attachment_test.dart',
      );
      var producedSteps =
          ((produced['scenarios']! as List).single
                  as Map<String, dynamic>)['steps']!
              as List;
      var beats = producedSteps.cast<Map<String, dynamic>>();
      expect(
        [for (var step in beats) '${step['kind'] ?? 'screen'} ${step['name']}'],
        [
          'screen null',
          'document request',
          'screen Exported',
          'document receipt',
          'notification null',
          'document summary',
        ],
      );

      // A document: bytes with a name and a type, and no frame at all —
      // there was no screen showing it, which is why it is not one.
      var receipt = beats[3];
      expect(receipt['mimeType'], 'application/json');
      expect(receipt['image'], isNull);
      expect(receipt['tree'], isNull);
      var file = File(receipt['file']! as String);
      expect(file.existsSync(), isTrue);
      // Its own stem, because it is its own step: the declared file name after
      // the index and label, so a directory reads as the flow did.
      expect(p.basename(file.path), '4-receipt.receipt.json');
      expect(receipt['bytes'], file.lengthSync());
      expect(
        jsonDecode(file.readAsStringSync()),
        containsPair('currency', 'EUR'),
      );

      // A notification is typed and inline: three short strings, on both ends
      // of the wire, so there is no file to fetch and nothing to decode before
      // a viewer can draw the banner.
      var notification = beats[4]['notification']! as Map<String, dynamic>;
      expect(notification['title'], 'Receipts');
      expect(notification['body'], startsWith('Receipt #1042'));
      expect(beats[4]['file'], isNull);

      // The screen between them is still the tap's own picture wearing the
      // name the `screen` after it gave up taking a second one for — a beat
      // draws nothing, so it does not get in the way of that.
      expect(beats[2]['verb'], 'tap');
      // And the chain is linear across every beat: one child each, so a walk
      // over the flow reaches all of them.
      expect([for (var step in beats) step['parent']], [null, 1, 2, 3, 4, 5]);

      // Recording on: the sixth leg, a directory of numbered frames beside
      // the pixels. The panel's settings, so this is the real cost too.
      var recorded = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/counter_test.dart',
        scenario: 'Counter',
        recordInterval: const Duration(milliseconds: 33),
        recordScale: 0.5,
      );
      var recordedSteps =
          ((recorded['scenarios']! as List).single
                  as Map<String, dynamic>)['steps']!
              as List;
      var withMotion = [
        for (var step in recordedSteps.cast<Map<String, dynamic>>())
          if (step['frames'] != null) step,
      ];
      expect(withMotion, isNotEmpty);
      for (var step in withMotion) {
        expect(step['frameIntervalMs'], 33);
        var count = step['frameCount']! as int;
        expect(count, greaterThan(1));
        // Half of the run's own capture scale, and every frame on disk.
        expect(step['frameWidth'], lessThan(step['width']! as int));
        var directory = Directory(step['frames']! as String);
        expect(
          directory.listSync().whereType<File>(),
          hasLength(count),
          reason: 'every frame written',
        );
      }

      // Warm re-run: the compiled harness and the live tester are reused, so
      // this is the instantaneous FakeAsync loop, not a second cold start.
      var watch = Stopwatch()..start();
      var rerun = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/counter_test.dart',
        scenario: 'Counter',
      );
      expect(((rerun['scenarios']! as List).single as Map)['ok'], isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));

      // A new scenario file. No hot reload re-runs the generated entrypoint's
      // `main`, so this must take the restart lane — and prove the freshly
      // imported file arrives.
      var scratch = File(
        p.join(packageRoot, 'test', 'scenarios', 'scratch_test.dart'),
      );
      scratch.writeAsStringSync(_scratchSource('v1'));
      try {
        await runner.refresh();
        var refreshed = await runner.list();
        expect([
          for (var s in refreshed) '${s.file} ${s.name}',
        ], contains('test/scenarios/scratch_test.dart Scratch'));
        expect(
          _scratchTexts(
            await runner.run(
              outDir: outDir,
              file: 'test/scenarios/scratch_test.dart',
              scenario: 'Scratch',
            ),
          ),
          contains('v1'),
        );

        // A body edit. `run` on a warm runner refreshes by itself — the Run
        // button never replays stale code — and the same file set means this
        // takes the reload lane, not a restart.
        await Future<void>.delayed(const Duration(seconds: 1));
        scratch.writeAsStringSync(_scratchSource('v2'));
        expect(
          _scratchTexts(
            await runner.run(
              outDir: outDir,
              file: 'test/scenarios/scratch_test.dart',
              scenario: 'Scratch',
            ),
          ),
          contains('v2'),
        );
      } finally {
        scratch.deleteSync();
      }

      // The transition events, end to end through a real tester: the three
      // automatic lanes and the reported one, on the step each belongs to.
      var signIn = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/events_test.dart',
        scenario: 'Signing in',
      );
      var signInOutcome = (signIn['scenarios']! as List).single as Map;
      expect(signInOutcome['ok'], isTrue, reason: '${signInOutcome['errors']}');
      var signInSteps = (signInOutcome['steps']! as List).cast<Map>();
      // Every step names the transition into it, which is what the flow's
      // arrows and the Events tab's header both read. Three steps, not four:
      // `screen('Signed in')` names the tap's picture rather than taking the
      // same one again, so the strongest label and the transition that earned
      // it sit on one step.
      expect(
        [for (var step in signInSteps) '${step['verb']} ${step['target']}'],
        ['pumpWidget _SignInApp', 'enterText TextField', 'tap "Sign in"'],
      );
      expect(signInSteps.last['name'], 'Signed in');
      // The tap is the interesting transition: the app logged, the fake
      // reported a request, a query and an analytics event, and the framework
      // talked to `flutter/textinput` on the way.
      var tapped = signInSteps[2];
      expect(tapped['eventChannels'], containsPair('log', 1));
      expect(tapped['eventChannels'], containsPair('network', 1));
      expect(tapped['eventChannels'], containsPair('db', 1));
      expect(tapped['eventChannels'], containsPair('analytics', 1));
      // Captured, and left out of the inline digest, which is the whole
      // policy: the volume is real and the reader filters it away.
      expect(tapped['eventChannels'], contains('system'));
      expect(
        (tapped['eventTitles']! as List).cast<String>(),
        containsAll(<String>['POST /sessions → 200', 'sign_in']),
      );
      var events = jsonDecode(
        File(tapped['events']! as String).readAsStringSync(),
      ) as List;
      expect(
        [
          for (var event in events.cast<Map>())
            if (event['channel'] == 'db') event['body'],
        ],
        ['INSERT INTO sessions (email) VALUES (?)'],
      );

      // The `new` action's scaffold, run as written. It is the only
      // documentation of the scenario API that executes, so it is checked
      // where a real tester already is: change `tap` or `Shot` and this is
      // what says the template now teaches something that does not exist.
      var scaffold = File(
        p.join(packageRoot, 'test', 'scenarios', 'scaffold_check_test.dart'),
      );
      scaffold.writeAsStringSync(scenarioScaffold('Scaffold check'));
      try {
        await runner.refresh();
        var scaffolded = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/scaffold_check_test.dart',
          scenario: 'Scaffold check',
        );
        var outcome = (scaffolded['scenarios']! as List).single as Map;
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
        expect(
          [
            for (var step in (outcome['steps']! as List).cast<Map>())
              step['name'],
          ],
          [null, 'Tapped continue'],
        );
      } finally {
        scaffold.deleteSync();
      }

      // Axes: the same warm harness, run as an iPhone in French, dark and
      // scaled — then bare again, proving the reset is per-run, not
      // per-process. The probe scenario prints what `MediaQuery` actually
      // sees, so these assertions are the app's view, not the harness's.
      var probe = File(
        p.join(packageRoot, 'test', 'scenarios', 'axes_probe_test.dart'),
      );
      probe.writeAsStringSync(_probeSource);
      try {
        var framed = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
          axes: const ScenarioAxes(
            device: 'iphone-se',
            language: 'fr-CA',
            textScale: 1.3,
            brightness: 'dark',
            boldText: true,
          ),
        );
        expect(
          _scratchTexts(framed),
          contains(
            '375x667 2.0 20.0 fr-CA Brightness.dark 13.0 true '
            'iphone-se-fr-CA',
          ),
        );
        // Logical pixels by default — the measured cost of physical capture
        // (10× the time and bytes) is not a good default; `captureScale`
        // buys it back explicitly.
        expect(_pngSize(_lastPng(framed)), (375, 667));

        var bare = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
        );
        var text = _scratchTexts(bare).single;
        expect(text, startsWith('800x600 3.0 0.0'));
        expect(text, contains('Brightness.light'));
        expect(text, endsWith('10.0 false unassigned'));
        expect(_pngSize(_lastPng(bare)), (800, 600));

        // The knob back up: the device's own ratio is a true screenshot.
        var sharp = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
          axes: const ScenarioAxes(device: 'iphone-se'),
          captureScale: 2,
        );
        expect(_pngSize(_lastPng(sharp)), (750, 1334));

        // Native resolution is resolved **in the guest**, at capture time —
        // the device may have come from a folder profile the host never saw,
        // so a ratio computed here would be a guess.
        var native = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
          axes: const ScenarioAxes(device: 'iphone-16'),
          captureNative: true,
        );
        expect(_pngSize(_lastPng(native)), (393 * 3, 852 * 3));

        // Raw skips PNG encoding — ~7.5ms a picture — and writes bare
        // rgba8888, width×height×4, exactly as the step reports.
        var raw = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
          axes: const ScenarioAxes(device: 'iphone-se'),
          captureRaw: true,
        );
        var rawStep =
            (((raw['scenarios']! as List).single as Map)['steps']! as List).last
                as Map;
        expect(rawStep['format'], 'raw');
        expect(rawStep['image'] as String, endsWith('.raw'));
        expect((rawStep['width'], rawStep['height']), (375, 667));
        expect(File(rawStep['image']! as String).lengthSync(), 375 * 667 * 4);

        // A step with no picture reports no digest. It has to: every one of
        // them would digest the same empty bytes, and `compareScenarioRuns`
        // counts a step it can read a digest off as compared — so drift would
        // vouch for screens nobody photographed. The tree still rides along,
        // which is the whole point of a pixel-less pass.
        var blind = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/axes_probe_test.dart',
          scenario: 'Probe',
          axes: const ScenarioAxes(device: 'iphone-se'),
          pixels: ScenarioPixels.none,
        );
        var blindStep =
            (((blind['scenarios']! as List).single as Map)['steps']! as List)
                    .last
                as Map;
        expect(blindStep['format'], 'none');
        expect(blindStep['image'], isNull);
        expect(blindStep['digest'], isNull);
        expect(blindStep['tree'], isNotNull);
        expect((blindStep['width'], blindStep['height']), (375, 667));
      } finally {
        probe.deleteSync();
      }

      // A nested split: the body replays once per path, shared-prefix steps
      // are captured exactly once, and every step carries the parent link
      // (and the branch label on a branch's first step) the flow graph draws
      // its edges from.
      var forked = File(
        p.join(packageRoot, 'test', 'scenarios', 'split_test.dart'),
      );
      forked.writeAsStringSync(_splitSource);
      try {
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/split_test.dart',
          scenario: 'Split',
        );
        var outcome = (report['scenarios']! as List).single as Map;
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
        var steps = (outcome['steps']! as List).cast<Map<String, dynamic>>();
        // 3 paths → root and L once each, tail three times: 8, not 10.
        expect(steps, hasLength(8));
        Map<String, dynamic> named(String name) =>
            steps.singleWhere((s) => s['name'] == name);
        (int?, String?) shape(String name) =>
            (named(name)['parent'] as int?, named(name)['branch'] as String?);

        expect(shape('root'), (null, null));
        expect(shape('L'), (named('root')['index'], 'left'));
        expect(shape('LX'), (named('L')['index'], 'x'));
        expect(shape('LY'), (named('L')['index'], 'y'));
        expect(shape('R'), (named('root')['index'], 'right'));
        // One tail per leaf, each chained to its own path's last step.
        var leaves = {
          for (var name in ['LX', 'LY', 'R']) named(name)['index'],
        };
        var tails = steps.where((s) => s['name'] == 'tail').toList();
        expect(tails, hasLength(3));
        expect({for (var t in tails) t['parent']}, leaves);
      } finally {
        forked.deleteSync();
      }

      // A stalled walk: verbs that act and change nothing carry
      // `unchanged: true`, so seven identical captures cannot pass as seven
      // pages — the consumer failure this flag exists for. Identical is the
      // *picture* being identical: the tree used to stand in for it and said
      // so on a quarter of a real suite's steps, four fifths of them wrongly.
      //
      // `screen` used to be excluded, on the grounds that it was a deliberate
      // second picture. It is not one any more: the first here names the
      // second tap's own picture, so what the flag lands on is a *named*
      // stalled step — which is the case it was previously blind to. The
      // forced one is a genuine second picture of that same frame, and says
      // so.
      var stalled = File(
        p.join(packageRoot, 'test', 'scenarios', 'stalled_test.dart'),
      );
      stalled.writeAsStringSync(_stalledSource);
      try {
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/stalled_test.dart',
          scenario: 'Stalled',
        );
        var outcome = (report['scenarios']! as List).single as Map;
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
        var steps = (outcome['steps']! as List).cast<Map<String, dynamic>>();
        expect(
          [for (var step in steps) step['name']],
          [null, null, 'end', 'end again'],
        );
        expect(
          [for (var step in steps) step['unchanged']],
          [null, true, true, true],
        );
      } finally {
        stalled.deleteSync();
      }

      // A scenario the author wrapped in a `group()` — listed by its own
      // name, and runnable by it. `test_api` composes the full name out of
      // the enclosing groups, so filtering by that name is the harness's job
      // rather than the declarer's.
      var grouped = File(
        p.join(packageRoot, 'test', 'scenarios', 'grouped_test.dart'),
      );
      grouped.writeAsStringSync(_groupedSource);
      try {
        await runner.refresh();
        expect([
          for (var s in await runner.list()) s.name,
        ], containsAll(['inside a group', 'outside any group']));
        expect(
          _scratchTexts(
            await runner.run(
              outDir: outDir,
              file: 'test/scenarios/grouped_test.dart',
              scenario: 'inside a group',
            ),
          ),
          contains('grouped'),
        );
      } finally {
        grouped.deleteSync();
      }

      // `setUpAll` and `tearDownAll`: stored on the group rather than among
      // its entries, so a walk over entries alone never ran them — the one
      // way a file could pass under `flutter test` and capture the wrong
      // screens here. The fixture writes what its hooks did into the app, so
      // the assertion is what the scenario actually saw.
      var hooks = File(
        p.join(packageRoot, 'test', 'scenarios', 'hooks_test.dart'),
      );
      hooks.writeAsStringSync(_hooksSource.replaceAll('OUT_DIR', outDir));
      try {
        await runner.refresh();
        var whole = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/hooks_test.dart',
        );
        var ran = (whole['scenarios']! as List).cast<Map<String, dynamic>>();
        expect(ran.map((s) => s['name']), ['Seeded', 'Also seeded']);
        expect(ran.every((s) => s['ok'] == true), isTrue, reason: '$ran');
        // Once for the group, not once per scenario, and the tear-down ran
        // after the last one.
        expect(
          [
            for (var s in ran)
              ((s['steps']! as List).last as Map)['texts']! as List,
          ],
          [
            ['setUpAll:1'],
            ['setUpAll:1'],
          ],
        );
        expect(
          File(p.join(outDir, 'teardown.txt')).readAsStringSync(),
          'torn down',
        );

        // One scenario asked for by name still gets the group's fixtures.
        // `setUpAll:2`, not `1`: the fixture is built once per *run request*,
        // and the counter lives in a guest that outlives the request — which
        // is the scope this harness owes a user who edits a fixture and hits
        // Run again.
        File(p.join(outDir, 'teardown.txt')).deleteSync();
        var one = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/hooks_test.dart',
          scenario: 'Also seeded',
        );
        expect(_scratchTexts(one), ['setUpAll:2']);
        expect(File(p.join(outDir, 'teardown.txt')).existsSync(), isTrue);
      } finally {
        hooks.deleteSync();
      }

      // A `setUpAll` that throws: the scenarios under it do not run against
      // half-built state, and each one that would have run says why.
      var brokenHook = File(
        p.join(packageRoot, 'test', 'scenarios', 'broken_hook_test.dart'),
      );
      brokenHook.writeAsStringSync(_brokenHookSource);
      try {
        await runner.refresh();
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/broken_hook_test.dart',
        );
        var outcome =
            ((report['scenarios']! as List).single) as Map<String, dynamic>;
        expect(outcome['name'], 'never runs');
        expect(outcome['ok'], isFalse);
        expect(outcome['steps'], isEmpty);
        expect('${outcome['errors']}', contains('the fixture is broken'));
      } finally {
        brokenHook.deleteSync();
      }

      // Two exceptions in one scenario: the binding aggregates them into
      // "Multiple exceptions (2) were detected…" with no stack — a count of
      // what it declined to show, and all a consumer's red suite had to go
      // on. The report now carries each real exception with its own message
      // and its own stack.
      var doubly = File(
        p.join(packageRoot, 'test', 'scenarios', 'doubly_broken_test.dart'),
      )..writeAsStringSync(_doublyBrokenSource);
      try {
        await runner.refresh();
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/doubly_broken_test.dart',
        );
        var outcome =
            (report['scenarios']! as List).single as Map<String, dynamic>;
        expect(outcome['ok'], isFalse);
        var errors = (outcome['errors']! as List).cast<Map<String, dynamic>>();
        expect('$errors', isNot(contains('Multiple exceptions')));
        expect(errors, hasLength(2));
        expect('${errors[0]['error']}', contains('the first exception'));
        expect('${errors[1]['error']}', contains('the second exception'));
        for (var error in errors) {
          expect('${error['stack']}', contains('doubly_broken_test.dart'));
        }
        // And the process's own console — engine noise, anything printed
        // outside a test zone — is on disk beside it, named by the report.
        var log = File(runner.logPath);
        expect(log.existsSync(), isTrue);
        expect(log.readAsStringSync(), contains('scenarios harness ready'));
      } finally {
        doubly.deleteSync();
      }

      // `scenario(skip: true)` reaches `testWidgets`, so `flutter test`
      // reports it skipped — and the harness used to run the body anyway,
      // the two lanes answering differently about the same file. A consumer
      // suite was green on CI and red on the runner with nothing connecting
      // the two.
      var skipped = File(
        p.join(packageRoot, 'test', 'scenarios', 'partly_skipped_test.dart'),
      )..writeAsStringSync(_partlySkippedSource);
      try {
        await runner.refresh();
        var listed = await runner.list();
        expect(
          listed.singleWhere((entry) => entry.name == 'Declared broken').skip,
          isTrue,
        );
        expect(
          listed.singleWhere((entry) => entry.name == 'Still runs').skip,
          isFalse,
        );
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/partly_skipped_test.dart',
        );
        var outcomes = (report['scenarios']! as List)
            .cast<Map<String, dynamic>>();
        var skippedOutcome = outcomes.singleWhere(
          (outcome) => outcome['name'] == 'Declared broken',
        );
        // Green the way `flutter test` is green on it — but saying why.
        expect(skippedOutcome['ok'], isTrue);
        expect(skippedOutcome['skipped'], isTrue);
        expect(skippedOutcome['steps'], isEmpty);
        var ran = outcomes.singleWhere(
          (outcome) => outcome['name'] == 'Still runs',
        );
        expect(ran['ok'], isTrue);
        expect(ran['skipped'], isNull);
        expect(ran['steps'], isNotEmpty);
        // Naming the skipped scenario alone still answers — skipped, not
        // "selector matched nothing".
        var alone = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/partly_skipped_test.dart',
          scenario: 'Declared broken',
        );
        var only = (alone['scenarios']! as List).single as Map<String, dynamic>;
        expect(only['skipped'], isTrue);
      } finally {
        skipped.deleteSync();
      }

      // A folder with its own `flutter_test_config.dart`: the harness runs it
      // — the same file `flutter test` would run — and reports what it says
      // the folder is for. Executed, never parsed, so a profile imported from
      // somewhere else reads exactly as well as one written in place.
      var folder = Directory(
        p.join(packageRoot, 'test', 'scenarios', 'profiled'),
      )..createSync(recursive: true);
      File(p.join(folder.path, 'flutter_test_config.dart'))
          .writeAsStringSync(_folderConfigSource);
      File(p.join(folder.path, 'profiled_test.dart'))
          .writeAsStringSync(_profiledSource);
      // The same scenario outside the folder, to prove the framing is worked
      // out per file rather than per request.
      var unprofiled = File(
        p.join(packageRoot, 'test', 'scenarios', 'unprofiled_test.dart'),
      )..writeAsStringSync(_profiledSource);
      try {
        await runner.refresh();
        var listed = await runner.list();
        var profiled = listed.firstWhere((s) => s.name == 'Profiled');
        expect(profiled.profile, 'phones');
        expect(profiled.devices, ['iphone-se', 'android-tall']);
        expect(profiled.languages, ['fr', 'en']);
        // What `matrix=declared` fans out from: the declaration, whole, on
        // the listing — orientations included, the axis the listing used to
        // drop.
        expect(profiled.orientations, ['portrait', 'landscape']);
        // A scenario outside that folder is not governed by it.
        expect(listed.firstWhere((s) => s.name == 'Counter').profile, isNull);

        // The run itself is the runner's, not the config's: one pass, at the
        // axes the request named rather than the profile's head.
        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/profiled/profiled_test.dart',
          scenario: 'Profiled',
          axes: const ScenarioAxes(device: 'iphone-se'),
        );
        var outcome = (report['scenarios']! as List).single as Map;
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
        expect(outcome['steps']! as List, hasLength(1));
        expect(_scratchTexts(report), ['375.0x667.0']);
        expect(outcome['device'], 'iphone-se');

        // And a request that names *no* device leaves the folder to answer:
        // the profile's head, not the fallback the host would otherwise
        // apply. The two are different sizes, which is the whole assertion.
        var byFolder = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/profiled/profiled_test.dart',
          scenario: 'Profiled',
          unspecifiedDevice: 'iphone-13',
        );
        expect(_scratchTexts(byFolder), ['375.0x667.0']);
        expect(
          ((byFolder['scenarios']! as List).single as Map)['device'],
          'iphone-se',
        );

        // A scenario the folder does not govern takes the fallback instead —
        // one run, two framings, worked out per file.
        var elsewhere = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/unprofiled_test.dart',
          scenario: 'Profiled',
          unspecifiedDevice: 'iphone-13',
        );
        expect(_scratchTexts(elsewhere), ['390.0x844.0']);
        expect(
          ((elsewhere['scenarios']! as List).single as Map)['device'],
          'iphone-13',
        );
      } finally {
        folder.deleteSync(recursive: true);
        unprofiled.deleteSync();
      }

      // An ordinary `testWidgets` living in the scenario folder: it produces
      // no steps and cannot be opened in the panel, so `list` never showed it
      // — and `run` used to execute it anyway. Both now agree it is not a
      // scenario.
      var strayTest = File(
        p.join(packageRoot, 'test', 'scenarios', 'stray_test.dart'),
      )..writeAsStringSync(_straySource);
      try {
        await runner.refresh();
        var listed = await runner.list();
        expect([for (var s in listed) s.name], contains('A real scenario'));
        expect([for (var s in listed) s.name], isNot(contains('Plain widget')));

        var report = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/stray_test.dart',
        );
        expect(
          [
            for (var s
                in (report['scenarios']! as List).cast<Map<String, dynamic>>())
              s['name'],
          ],
          ['A real scenario'],
        );
      } finally {
        strayTest.deleteSync();
      }

      // Tags: declared on the scenario, reported by the listing, and the one
      // thing `run --tag` filters on. The syntactic scan cannot see them —
      // it never evaluates an argument — so the live listing is the only
      // place they exist.
      var tagged = File(
        p.join(packageRoot, 'test', 'scenarios', 'tagged_test.dart'),
      )..writeAsStringSync(_taggedSource);
      try {
        await runner.refresh();
        var listed = await runner.list();
        expect(listed.firstWhere((s) => s.name == 'Smoke tagged').tags, [
          'smoke',
        ]);
        expect(listed.firstWhere((s) => s.name == 'Untagged').tags, isEmpty);

        var filtered = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/tagged_test.dart',
          tag: 'smoke',
        );
        expect(
          [
            for (var s
                in (filtered['scenarios']! as List)
                    .cast<Map<String, dynamic>>())
              s['name'],
          ],
          ['Smoke tagged'],
        );
      } finally {
        tagged.deleteSync();
      }

      // The verbs past tap and enterText, through the real substrate: a list
      // walked until an off-screen row is on screen, a scoped icon tapped
      // inside that row, and a clock moved past a timer no settle would wait
      // for.
      var verbs = File(
        p.join(packageRoot, 'test', 'scenarios', 'verbs_test.dart'),
      );
      verbs.writeAsStringSync(_verbsSource);
      try {
        await runner.refresh();
        var outcome =
            (await runner.run(
                  outDir: outDir,
                  file: 'test/scenarios/verbs_test.dart',
                  scenario: 'Verbs',
                ))['scenarios']!
                as List;
        var run = outcome.single as Map;
        expect(run['ok'], isTrue, reason: '${run['errors']}');
        var last = (run['steps']! as List).last as Map;
        expect((last['texts']! as List).cast<String>(), contains('starred 30'));
      } finally {
        verbs.deleteSync();
      }

      // A screen that never stops animating, and a scenario that breaks in a
      // split branch — the two things a run says about itself when it is not
      // simply fine. Both travel as step fields, so the panel and an agent
      // read them the same way.
      var unhappy = File(
        p.join(packageRoot, 'test', 'scenarios', 'unhappy_test.dart'),
      );
      unhappy.writeAsStringSync(_unhappySource);
      try {
        await runner.refresh();
        var spinning =
            (await runner.run(
                  outDir: outDir,
                  file: 'test/scenarios/unhappy_test.dart',
                  scenario: 'Spinning',
                ))['scenarios']!
                as List;
        var outcome = spinning.single as Map;
        // Never settling is not a failure: the run passes, and the steps say
        // the app was still animating.
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
        var steps = (outcome['steps']! as List).cast<Map<String, dynamic>>();
        expect(steps.map((s) => s['settled']), everyElement(isFalse));

        var broken =
            (await runner.run(
                  outDir: outDir,
                  file: 'test/scenarios/unhappy_test.dart',
                  scenario: 'Broken',
                ))['scenarios']!
                as List;
        var failed = broken.single as Map;
        expect(failed['ok'], isFalse);
        expect('${failed['errors']}', contains('in split branch "by card"'));
        var last = (failed['steps']! as List).last as Map;
        expect(last['failure'], contains('in split branch "by card"'));
        expect(last['failure'], contains('nothing matches "Pay now"'));
        // The failure has a picture, and it is of the screen it broke on.
        expect(File(last['image']! as String).existsSync(), isTrue);
        expect((last['texts']! as List).cast<String>(), contains('Checkout'));
      } finally {
        unhappy.deleteSync();
      }

      // A guest that dies mid-session is noticed: the next run respawns one
      // instead of talking to a service that is gone. (Killing it from here
      // is the same thing the OS does when a scenario blows the isolate up.)
      await runner.debugKillGuest();
      var revived = await runner.run(
        outDir: outDir,
        file: 'test/scenarios/counter_test.dart',
        scenario: 'Counter',
      );
      expect(((revived['scenarios']! as List).single as Map)['ok'], isTrue);

      // A reel: the same scenario twice in one request — dry for the take,
      // then filmed under the stock edit's cut of it. The take lands beside
      // the frames, never among them.
      var reelDir = Directory.systemTemp.createTempSync('scenario_reel');
      try {
        var frames = p.join(reelDir.path, 'frames');
        var reel = await runner.run(
          outDir: outDir,
          file: 'test/scenarios/counter_test.dart',
          scenario: 'Counter',
          pixels: ScenarioPixels.none,
          film: FilmSettings(directory: frames, scale: 1),
          filmReel: true,
        );
        var cut = (reel['scenarios']! as List).single as Map;
        expect(cut['ok'], isTrue, reason: '${cut['errors']}');
        Map<String, dynamic> timeline(String directory) =>
            jsonDecode(File(p.join(directory, 'film.json')).readAsStringSync())
                as Map<String, dynamic>;
        var take = timeline('$frames.take');
        expect(take['dry'], isTrue);
        expect(
          File(p.join('$frames.take', 'film.head.json')).existsSync(),
          isFalse,
        );
        var film = timeline(frames);
        expect(film['dry'], isNull);
        // The stock edit holds the first tap for 800ms — the app really runs
        // through it, so the pumped count grows by 24 at 30fps — and freezes
        // the last frame for 1200ms, 36 output frames the app never ran.
        expect(film['pumped'], (take['frames'] as int) + 24);
        expect(film['frames'], (take['frames'] as int) + 60);
        // Every one of them is on disk: nothing drained this render.
        expect(
          Directory(frames)
              .listSync()
              .where((f) => f.path.endsWith('.raw'))
              .length,
          film['frames'],
        );
      } finally {
        reelDir.deleteSync(recursive: true);
      }
    } finally {
      await runner.dispose();
      Directory(outDir).deleteSync(recursive: true);
    }
  });

  test('a failed cold start is forgotten, not memoized', () async {
    var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
    var repoRoot = Directory.current.parent.path;
    var packageRoot = p.join(repoRoot, 'fixtures', 'probe_app');
    var outDir = Directory.systemTemp.createTempSync('scenario_cold').path;

    // An empty directory is the cheapest cold-start failure there is — no
    // compile, same lane.
    var empty = Directory(p.join(packageRoot, 'test', 'scenarios_cold'))
      ..createSync(recursive: true);
    var runner = ScenarioRunner(
      packageRoot: packageRoot,
      directory: 'test/scenarios_cold',
      flutterSdkRoot: flutterRoot,
    );
    try {
      await expectLater(runner.list(), throwsA(isA<ActionRefusal>()));

      // The fix: writing the scenario the runner complained about and asking
      // again starts it, rather than replaying the old complaint forever.
      File(p.join(empty.path, 'cold_test.dart'))
          .writeAsStringSync(_scratchSource('cold'));
      var listed = await runner.list();
      expect([for (var s in listed) s.name], contains('Scratch'));
    } finally {
      await runner.dispose();
      empty.deleteSync(recursive: true);
      Directory(outDir).deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
    'a package with no lib/main.dart runs, and taps a Material button',
    () async {
      var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
      // The workspace root — the `flutterware` package itself, which has no
      // `lib/main.dart`, like any library or any app whose entry lives
      // elsewhere. Shelling out to `flutter build bundle` used to stop such a
      // package with `Target file "lib/main.dart" not found` before a single
      // scenario ran.
      var repoRoot = Directory.current.parent.path;
      var outDir = Directory.systemTemp.createTempSync('scenario_no_main').path;
      var dir = Directory(p.join(repoRoot, 'test', 'scenarios_no_main'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'ripple_test.dart'))
          .writeAsStringSync(_rippleSource);

      var runner = ScenarioRunner(
        packageRoot: repoRoot,
        directory: 'test/scenarios_no_main',
        flutterSdkRoot: flutterRoot,
      );
      try {
        var report = await runner.run(outDir: outDir);
        var outcome = (report['scenarios']! as List).single as Map;
        expect(outcome['ok'], isTrue, reason: '${outcome['errors']}');
      } finally {
        await runner.dispose();
        dir.deleteSync(recursive: true);
        Directory(outDir).deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a scenario that never returns is reported, and does not take the run',
    () async {
      var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
      // Written into the workspace root and deleted after, like the
      // no-main test below: a scenario that never returns must not be left
      // lying inside a package whose `test/` a real run scans.
      var repoRoot = Directory.current.parent.path;
      var outDir = Directory.systemTemp.createTempSync('scenario_hang').path;
      var dir = Directory(p.join(repoRoot, 'test', 'scenarios_hang'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'hanging_test.dart'))
          .writeAsStringSync(_hangingSource);

      var runner = ScenarioRunner(
        packageRoot: repoRoot,
        directory: 'test/scenarios_hang',
        flutterSdkRoot: flutterRoot,
      );
      try {
        var report = await runner.run(outDir: outDir);
        var scenarios = (report['scenarios']! as List)
            .cast<Map<String, dynamic>>();

        // The whole point: an answer came back at all.
        expect(report['abandoned'], isTrue);
        expect(scenarios, hasLength(1));
        var hung = scenarios.single;
        expect(hung['name'], 'Never returns');
        expect(hung['ok'], isFalse);
        var error = '${((hung['errors']! as List).first as Map)['error']}';
        expect(error, contains('made no progress for 2s'));
        // The diagnosis: where the body was, and which mechanism. This body
        // went past its last verb into a bare `tester.runAsync`, so it is
        // placed after that verb; and nothing is queued in the fake zone,
        // because the future it awaits was never going to complete anything.
        expect(error, contains('between verbs: `s.pumpWidget SizedBox`'));
        expect(error, contains('hanging_test.dart:'));
        expect(error, contains('Nothing is queued in the fake zone'));
        // The step it never took, taken for it: failed, no picture, and the
        // print on the way there as its event — the evidence a stuck step
        // used to lose.
        var steps = (hung['steps']! as List).cast<Map<String, dynamic>>();
        expect(steps, hasLength(2));
        var last = steps.last;
        expect(last['failure'], error);
        expect(last['image'], isNull);
        expect(last['eventTitles'], contains('about to hang'));
        // Declared after it, and deliberately never reached.
        expect(
          scenarios.map((s) => s['name']),
          isNot(contains('After the hang')),
        );
      } finally {
        await runner.dispose();
        dir.deleteSync(recursive: true);
        Directory(outDir).deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // A scenario's timeout is how long it may go without progress. As a
  // wall-clock budget it failed a split that passes in five seconds on a
  // quiet machine once three comparison jobs shared the host.
  test(
    'a scenario slower than its timeout passes while it gets somewhere',
    () async {
      var flutterRoot = Platform.environment['FLUTTER_ROOT']!;
      var repoRoot = Directory.current.parent.path;
      var outDir = Directory.systemTemp.createTempSync('scenario_slow').path;
      var dir = Directory(p.join(repoRoot, 'test', 'scenarios_slow'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'slow_test.dart')).writeAsStringSync(_slowSource);

      var runner = ScenarioRunner(
        packageRoot: repoRoot,
        directory: 'test/scenarios_slow',
        flutterSdkRoot: flutterRoot,
      );
      try {
        var report = await runner.run(outDir: outDir);
        var scenarios = (report['scenarios']! as List)
            .cast<Map<String, dynamic>>();

        expect(report['abandoned'], isNot(isTrue));
        for (var scenario in scenarios) {
          expect(
            scenario['ok'],
            isTrue,
            reason: '${scenario['name']}: ${scenario['errors']}',
          );
          expect(
            scenario['ms'] as int,
            greaterThan(1500),
            reason: 'it has to have outlived its one-second timeout',
          );
        }
        expect(scenarios, hasLength(2));
      } finally {
        await runner.dispose();
        dir.deleteSync(recursive: true);
        Directory(outDir).deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test('the entrypoint file is left alone when its content is right', () {
    var root = Directory.systemTemp.createTempSync('scenario_entrypoint');
    try {
      var path = writeHarnessEntrypoint(root.path, ['test/scenarios/a.dart']);
      var written = File(path).statSync().modified;
      writeHarnessEntrypoint(root.path, ['test/scenarios/a.dart']);
      expect(File(path).statSync().modified, written);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('the generated entrypoint is stable and relative', () {
    var source = generateHarnessEntrypoint([
      'test/scenarios/b_test.dart',
      'test/scenarios/a_test.dart',
    ]);
    expect(
      source,
      '// GENERATED — flutterware scenarios harness. Do not edit.\n'
      "import 'package:flutterware/src/scenarios/harness.dart'\n"
      '    as harness;\n'
      "import '../../test/scenarios/a_test.dart' as s0;\n"
      "import '../../test/scenarios/b_test.dart' as s1;\n"
      '\n'
      'void main() => harness.runHarness(\n'
      '  {\n'
      "    'test/scenarios/a_test.dart': s0.main,\n"
      "    'test/scenarios/b_test.dart': s1.main,\n"
      '  },\n'
      ');\n',
    );
  });

  test('a folder config is imported and keyed by the folder it governs', () {
    var source = generateHarnessEntrypoint(
      ['test/scenarios/mobile/a_test.dart'],
      configs: ['test/scenarios/mobile/flutter_test_config.dart'],
    );

    expect(
      source,
      contains(
        "import '../../test/scenarios/mobile/flutter_test_config.dart' as c0;",
      ),
    );
    expect(source, contains("    'test/scenarios/mobile': c0.testExecutable,"));
  });

  test('imports climb out of whatever directory the entrypoint sits in', () {
    // A comparison's entrypoint sits two levels deeper than the default —
    // a hardcoded `../../` there would import files that do not exist.
    var source = generateHarnessEntrypoint(
      ['test/scenarios/a_test.dart'],
      configs: ['test/scenarios/flutter_test_config.dart'],
      directory: 'build/flutterware/comparison/123-0',
    );
    expect(
      source,
      contains("import '../../../../test/scenarios/a_test.dart' as s0;"),
    );
    expect(
      source,
      contains(
        "import '../../../../test/scenarios/flutter_test_config.dart' as c0;",
      ),
    );
    // The declared map keys stay package-relative: they are the harness's
    // identity for a file, not a path anyone resolves.
    expect(source, contains("    'test/scenarios/a_test.dart': s0.main,"));
  });

  test('the entrypoint lands in the directory it was asked into', () {
    var root = Directory.systemTemp.createTempSync('scenario_entrypoint');
    try {
      var path = writeHarnessEntrypoint(root.path, [
        'test/scenarios/a.dart',
      ], directory: 'build/flutterware/comparison/123-0');
      expect(
        p.equals(
          path,
          p.join(
            root.path,
            'build/flutterware/comparison/123-0/scenarios_harness.dart',
          ),
        ),
        isTrue,
      );
      expect(File(path).existsSync(), isTrue);
      // The default lane's copy is untouched — isolation is the point.
      expect(
        File(p.join(root.path, harnessEntrypointPath)).existsSync(),
        isFalse,
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}

/// The last (only) step's texts of a single-scenario run report.
List<String> _scratchTexts(Map<String, Object?> report) {
  var scenarios = (report['scenarios']! as List).cast<Map<String, dynamic>>();
  var scratch = scenarios.single;
  expect(scratch['ok'], isTrue, reason: '${scratch['errors']}');
  var steps = (scratch['steps']! as List).cast<Map<String, dynamic>>();
  return (steps.last['texts']! as List).cast<String>();
}

/// A scenario that needs the bundle to be right in the one way a hand-written
/// one is most likely to get wrong: `FragmentProgram.fromAsset` throws unless
/// `shaders/ink_sparkle.frag` is the *compiled* form, and it is what an M3
/// button's first tap loads.
const _rippleSource = r'''
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Ripple', (s) async {
    await FragmentProgram.fromAsset('shaders/ink_sparkle.frag');
    await s.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('Tap')),
          ),
        ),
      ),
    );
    await s.tap('Tap');
  });
}
''';

String _scratchSource(String label) =>
    '''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Scratch', (s) async {
    await s.tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('$label'))),
    );
    await s.screen('shot');
  });
}
''';

/// The last step's image path of a single-scenario run report.
String _lastPng(Map<String, Object?> report) {
  var steps = ((report['scenarios']! as List).single as Map)['steps']! as List;
  return (steps.last as Map)['image']! as String;
}

/// Width and height from the PNG's IHDR chunk — no decoder needed.
(int, int) _pngSize(String path) {
  var bytes = File(path).readAsBytesSync();
  int word(int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
  return (word(16), word(20));
}

/// A scenario nested in a user `group()`, beside one that is not.
const _groupedSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  group('checkout', () {
    scenario('inside a group', (s) async {
      await s.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('grouped'))),
        shot: Shot('shot'),
      );
    });
  });

  scenario('outside any group', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('plain'))),
      shot: Shot('shot'),
    );
  });
}
''';

/// A nested split: three paths (left→x, left→y, right), a shared prefix
/// (`root`), and a step after the split (`tail`) that runs once per path.
const _splitSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Split', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('root'))),
      shot: Shot.skip,
    );
    await s.screen('root');
    await s.split({
      'left': () async {
        await s.screen('L');
        await s.split({
          'x': () async {
            await s.screen('LX');
          },
          'y': () async {
            await s.screen('LY');
          },
        });
      },
      'right': () async {
        await s.screen('R');
      },
    });
    await s.screen('tail');
  });
}
''';

/// A group with both `all` hooks, counting its own runs so the scenarios can
/// report whether the fixture was built once or once each.
const _hooksSource = r'''
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

var setUps = 0;

void main() {
  setUpAll(() => setUps++);
  tearDownAll(() {
    // Written where the test can find it: the harness outlives the run, so a
    // tear-down that never ran would otherwise leave no trace either way.
    File('OUT_DIR/teardown.txt').writeAsStringSync('torn down');
  });

  scenario('Seeded', (s) async {
    await s.pumpWidget(
      MaterialApp(home: Scaffold(body: Text('setUpAll:$setUps'))),
    );
  });

  scenario('Also seeded', (s) async {
    await s.pumpWidget(
      MaterialApp(home: Scaffold(body: Text('setUpAll:$setUps'))),
    );
  });
}
''';

/// A `setUpAll` that throws — the fixture every scenario under it needed.
const _brokenHookSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  setUpAll(() => throw StateError('the fixture is broken'));

  scenario('never runs', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('unreachable'))),
    );
  });
}
''';

/// A skipped scenario whose body would fail, beside one that runs — skipped
/// the way an author skips: because the body is known broken.
const _partlySkippedSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Declared broken', (s) async {
    fail('the body of a skipped scenario ran');
  }, skip: true);

  scenario('Still runs', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('alive'))),
    );
  });
}
''';

/// One scenario, two exceptions: one reported to the framework mid-body, one
/// thrown — the smallest recipe for the binding's "Multiple exceptions"
/// aggregate.
const _doublyBrokenSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Doubly broken', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('about to break'))),
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('the first exception'),
        stack: StackTrace.current,
      ),
    );
    throw StateError('the second exception');
  });
}
''';

/// A folder that declares what it is for. The profile is imported rather than
/// written inline, which is the case a syntactic scan could not have read.
const _folderConfigSource = '''
import 'dart:async';

import 'package:flutterware/flutter_test.dart';

const phones = ScenarioProfile(
  'phones',
  devices: [Devices.iphoneSe, Devices.androidTall],
  languages: ['fr', 'en'],
  orientations: [ScreenOrientation.portrait, ScreenOrientation.landscape],
);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: phones);
''';

const _profiledSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Profiled', (s) async {
    await s.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            var size = MediaQuery.sizeOf(context);
            return Scaffold(body: Text('${size.width}x${size.height}'));
          },
        ),
      ),
    );
  });
}
''';

/// A scenario and a plain `testWidgets` in the same file — what `list` and
/// `run` used to disagree about.
const _straySource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('A real scenario', (s) async {
    await s.pumpWidget(const MaterialApp(home: Scaffold(body: Text('real'))));
  });

  testWidgets('Plain widget', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('plain'))),
    );
    expect(find.text('plain'), findsOneWidget);
  });
}
''';

/// Two scenarios, one tagged — the fixture for `--tag` and for what a
/// listing reports about it.
const _taggedSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Smoke tagged', tags: ['smoke'], (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('tagged'))),
    );
  });

  scenario('Untagged', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('untagged'))),
    );
  });
}
''';

/// The verbs past tap and enterText: a list scrolled to an off-screen row, a
/// target scoped to that row, and a timer waited out.
const _verbsSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Verbs', (s) async {
    await s.pumpWidget(const _App(), shot: Shot.skip);
    await s.scrollTo('Item 30');
    await s.tap(const Target.within(ValueKey('row-30'), Icons.star));
    await s.wait(const Duration(seconds: 2));
    await s.screen('done');
  });
}

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var note = 'none';

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      // The note above the list, not in it: the last step's texts are what
      // the assertion reads, and a widget scrolled off the bottom is not
      // among them.
      body: Column(
        children: [
          Text(note),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(
                    key: ValueKey('row-$i'),
                    height: 80,
                    child: Row(
                      children: [
                        Text('Item $i'),
                        IconButton(
                          icon: const Icon(Icons.star),
                          onPressed: () => setState(() => note = 'starred $i'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
''';

/// The two unhappy shapes: a screen holding a spinner, where the settle
const _unhappySource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Spinning', (s) async {
    await s.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [Text('Loading'), CircularProgressIndicator()]),
      ),
    ));
    await s.screen('still going');
  });

  scenario('Broken', (s) async {
    await s.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Checkout'))),
    );
    await s.split({
      'by card': () async {
        await s.tap('Pay now');
      },
    });
  });
}
''';

/// A scenario that never returns, and one declared after it that must not run.
const _hangingSource = r'''
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario(
    'Never returns',
    // Two seconds rather than the 30-second default: the test asserts that
    // the deadline fires, not how patient it is.
    timeout: const Timeout(Duration(seconds: 2)),
    (s) async {
      await s.pumpWidget(const SizedBox.shrink());
      print('about to hang');
      // Real async that no pump — and no clock — will ever complete.
      await s.tester.runAsync(() => Completer<void>().future);
    },
  );

  scenario('After the hang', (s) async {
    await s.pumpWidget(const SizedBox.shrink());
  });
}
''';

const _slowSource = r'''
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/real_work.dart';

void main() {
  scenario(
    'Steps that take longer than the timeout together',
    timeout: const Timeout(Duration(seconds: 1)),
    (s) async {
      for (var i = 0; i < 5; i++) {
        await s.tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)),
        );
        await s.pumpWidget(
          Text('$i', textDirection: TextDirection.ltr),
        );
      }
    },
  );

  scenario(
    'Tracked work that takes longer than the timeout',
    timeout: const Timeout(Duration(seconds: 1)),
    (s) async {
      await s.pumpWidget(const _Loads());
    },
  );
}

class _Loads extends StatefulWidget {
  const _Loads();

  @override
  State<_Loads> createState() => _LoadsState();
}

class _LoadsState extends State<_Loads> {
  var _done = false;

  @override
  void initState() {
    super.initState();
    RealWork.run(
      () => Future<void>.delayed(const Duration(seconds: 2)),
      label: 'slow import',
    ).then((_) {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      Text(_done ? 'loaded' : 'loading', textDirection: TextDirection.ltr);
}
''';

/// Prints the app's own view of the axes: logical size, pixel ratio, the top
/// safe area, the platform locale, brightness, and 10 through the text
/// scaler.
/// A page whose `Continue` ignores every tap — the shape of a flow that
/// stalls without an exception or a failed matcher.
const _stalledSource = r'''
import 'package:flutter/widgets.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Stalled', (s) async {
    await s.pumpWidget(const _DeadEnd());
    await s.tap('Continue');
    await s.tap('Continue');
    await s.screen('end');
    await s.screen('end again', force: true);
  });
}

class _DeadEnd extends StatelessWidget {
  const _DeadEnd();

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: GestureDetector(onTap: () {}, child: const Text('Continue')),
    ),
  );
}
''';

const _probeSource = r'''
import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Probe', (s) async {
    await s.tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              var media = MediaQuery.of(context);
              var locale = View.of(context).platformDispatcher.locale;
              return Text(
                '${media.size.width.round()}x${media.size.height.round()} '
                '${media.devicePixelRatio} '
                '${media.padding.top} '
                '${locale.toLanguageTag()} '
                '${media.platformBrightness} '
                '${media.textScaler.scale(10)} '
                '${media.boldText} '
                // The axes as the *body* reads them — the consumer seam: a
                // base class keys its locale off `s.assignment?.language`.
                '${s.assignment?.slug ?? 'unassigned'}',
              );
            },
          ),
        ),
      ),
    );
    await s.screen('probe');
  });
}
''';
