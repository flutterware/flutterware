import 'dart:io';

import 'package:flutterware_app/src/world/app_guest.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/dart_executable.dart';

/// The guest entry's `_start`, run as the entry runs it, with an outer zone
/// that reports what reaches it as the engine does and carries on.
void main() {
  late Directory dir;
  var said = <String, List<String>>{};

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('guest_start_');
    var script = File(p.join(dir.path, 'start.dart'))
      ..writeAsStringSync('''
import 'dart:async';
import 'dart:io';

${guestStartSource(grace: const Duration(milliseconds: 300))}
$_scenarios''');
    var dart = resolveDartExecutable();
    await Future.wait([
      for (var scenario in _names)
        Process.run(dart, [script.path, scenario]).then((result) {
          said[scenario] = '${result.stdout}${result.stderr}'.trim().split(
            '\n',
          );
        }),
    ]);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  const stoppedOnThrow = '${guestStoppedMarker}Bad state: thrown';
  const stoppedOnFailure = '${guestStoppedMarker}Bad state: failed';

  test('a main that throws stops at once', () {
    expect(said['throws'], [stoppedOnThrow, 'reported: Bad state: thrown']);
  });

  test('a main whose future fails stops at once', () {
    expect(said['returns a failure'], [
      stoppedOnFailure,
      'reported: Bad state: failed',
    ]);
  });

  test('a main that drops a future that fails stops once runApp has not '
      'followed', () {
    // Reported first: the guest waits before it gives up on the app.
    expect(said['drops a failure'], [
      'reported: Bad state: failed',
      stoppedOnFailure,
    ]);
  });

  test('an error nothing catches does not stop an app that goes on to call '
      'runApp', () {
    expect(said['drops a failure, then runs the app'], [
      'reported: Bad state: failed',
    ]);
  });

  test('an error nothing catches does not stop an async main that is still '
      'running', () {
    expect(said['drops a failure while it waits, then runs the app'], [
      'reported: Bad state: failed',
    ]);
  });

  test('an async main that returns without calling runApp stops', () {
    expect(said['drops a failure, then returns'], [
      'reported: Bad state: failed',
      stoppedOnFailure,
    ]);
  });
}

const _names = [
  'throws',
  'returns a failure',
  'drops a failure',
  'drops a failure, then runs the app',
  'drops a failure while it waits, then runs the app',
  'drops a failure, then returns',
];

/// Each of [_names] as an app's `main`, and the `main` that runs one.
const _scenarios = r'''
var ran = false;

Future<void> fail() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
  throw StateError('failed');
}

void runApp() => ran = true;

Object? Function() scenario(String name) => switch (name) {
  'throws' => () => throw StateError('thrown'),
  'returns a failure' => fail,
  'drops a failure' => () {
    fail();
  },
  'drops a failure, then runs the app' => () {
    fail();
    Timer(const Duration(milliseconds: 100), runApp);
  },
  'drops a failure while it waits, then runs the app' => () async {
    unawaited(fail());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    runApp();
  },
  'drops a failure, then returns' => () async {
    unawaited(fail());
    await Future<void>.delayed(const Duration(milliseconds: 50));
  },
  _ => throw ArgumentError(name),
};

Future<void> main(List<String> args) async {
  runZonedGuarded(
    () => _start(() => ran, scenario(args.single)),
    (error, stack) => print('reported: $error'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  exit(0);
}
''';
