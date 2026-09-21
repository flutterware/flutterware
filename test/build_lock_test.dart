import 'dart:io';

import 'package:flutterware/src/build_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real `dart`, which is not always the executable running the test.
///
/// Same reason and same walk as `build_output_test.dart`: under `flutter test`
/// [Platform.resolvedExecutable] is `flutter_tester`, which cannot run a script.
final _dart = () {
  var name = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    var candidate = File(p.join(directory.path, 'dart-sdk', 'bin', name));
    if (candidate.existsSync()) return candidate.path;
    var parent = directory.parent;
    if (parent.path == directory.path) return Platform.resolvedExecutable;
    directory = parent;
  }
}();

final _child = p.join(
  Directory.current.path,
  'test',
  'fixtures',
  'build_lock_child.dart',
);

/// What the lock is for: two processes, one build tree, and never both inside.
///
/// The bug it exists to prevent is not a slow build but a broken artifact —
/// two `dart build cli` runs into one output directory produce a binary that
/// `install_name_tool` has already rewritten, or one whose snapshot was
/// appended to a file being replaced. Neither shows up on a machine that only
/// ever runs one cold build at a time, so the coverage has to be a real second
/// process.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('build_lock'));
  tearDown(() => temp.deleteSync(recursive: true));

  String path(String name) => p.join(temp.path, name);

  test('a second process waits rather than joining in', () async {
    var lock = path('tree.lock');
    var transcript = path('transcript');
    var runs = await Future.wait([
      Process.run(_dart, [_child, lock, transcript, 'a']),
      // After the first is inside — its window is 500ms, so this lands well
      // within it.
      Future<void>.delayed(const Duration(milliseconds: 150))
          .then((_) => Process.run(_dart, [_child, lock, transcript, 'b'])),
    ]);

    for (var run in runs) {
      expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    }

    var lines = File(transcript).readAsLinesSync();
    expect(lines, hasLength(4));
    // The whole assertion: whoever went first came out before the other went
    // in. Which of them won is a race and is not the claim.
    expect(lines[1], '${lines[0].split(' ').first} out');
    expect(lines[3], '${lines[2].split(' ').first} out');
    expect(lines[0].split(' ').first, isNot(lines[2].split(' ').first));

    // And the loser said so, exactly once, rather than waiting in silence.
    var waited = runs.where((r) => '${r.stdout}'.contains('waited'));
    expect(waited, hasLength(1));
  });

  test('an uncontended lock says nothing and runs the body', () async {
    var waits = 0;
    var ran = false;
    await withBuildLock(path('tree.lock'), () async {
      ran = true;
    }, onWait: () => waits++);

    expect(ran, isTrue);
    expect(waits, 0);
  });

  test('the lock file is created, directories and all', () async {
    var lock = path(p.join('locks', 'deep', 'tree.lock'));
    await withBuildLock(lock, () async {});
    expect(File(lock).existsSync(), isTrue);
  });

  test('a failing build is reported, not swallowed by the lock', () async {
    // Deliberately not a claim about the handle being closed: the POSIX lock is
    // per *process*, so a second acquire from this one would pass whether or
    // not the first was released, and a test written that way would assert
    // nothing. What is asserted is the part a caller can observe.
    await expectLater(
      withBuildLock(path('tree.lock'), () async => throw StateError('boom')),
      throwsStateError,
    );
  });
}
