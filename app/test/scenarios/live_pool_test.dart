@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/flutter_test.dart' show ScenarioTime;
import 'package:flutterware_app/src/scenarios/runner.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a live package runs one guest per scenario and survives a red one',
    () async {
      var flutterRoot = Platform.environment['FLUTTER_ROOT'];
      expect(
        flutterRoot,
        isNotNull,
        reason: 'flutter test always sets FLUTTER_ROOT',
      );
      // app/ → the repo root, the workspace this test runs in.
      var repoRoot = Directory.current.parent.path;
      var packageRoot = p.join(repoRoot, 'fixtures', 'probe_app');
      var out = Directory.systemTemp.createTempSync('live_pool');
      addTearDown(() => out.deleteSync(recursive: true));

      var runner = ScenarioRunner(
        packageRoot: packageRoot,
        directory: 'test/live',
        flutterSdkRoot: flutterRoot!,
        time: ScenarioTime.real(),
        jobs: 3,
      );
      addTearDown(runner.dispose);

      // The build is paid once, outside the stopwatch: the parallelism claim is
      // about the scenarios, and a cold compile is tens of seconds of noise.
      await runner.list();
      var sw = Stopwatch()..start();
      var result = await runner.run(outDir: out.path);
      var wall = sw.elapsed;

      var scenarios = (result['scenarios']! as List)
          .cast<Map<String, Object?>>();
      expect(scenarios, hasLength(4));
      expect(scenarios.where((s) => s['ok'] == true), hasLength(3));
      expect(
        scenarios.singleWhere((s) => s['ok'] == false)['name'],
        'a failing scenario does not poison its neighbours',
      );
      expect(result['time'], 'real');
      expect(result['jobs'], 3);
      // Three 400ms fetches in parallel plus boots: well under the sequential
      // cost, and far under a poisoned-guest cascade that would time out.
      expect(wall, lessThan(const Duration(seconds: 20)), reason: 'took $wall');
      var written = out
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .length;
      expect(
        written,
        greaterThanOrEqualTo(3),
        reason: 'one picture per green flow',
      );
    },
  );
}
