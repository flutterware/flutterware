import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A child process holding an exclusive lock on [path], for as long as it
/// lives.
///
/// A real process, because an advisory lock is per process: a second take
/// inside this one succeeds and would prove nothing. The studio's suites
/// have the same helper for the same reason.
Future<Process> holdLock(String path) async {
  var script =
      File(
        p.join(
          Directory.systemTemp.createTempSync('fw_lock_holder').path,
          'hold.dart',
        ),
      )..writeAsStringSync('''
import 'dart:io';

void main(List<String> args) {
  var file = File(args.single)..parent.createSync(recursive: true);
  var handle = file.openSync(mode: FileMode.append);
  handle.lockSync();
  stdout.writeln('held');
  // Held until killed.
  stdin.listen((_) {});
}
''');
  var process = await Process.start(_dart, ['run', script.path, path]);
  // Registered before the first await, not after the caller's: a child that
  // holds a lock and reads stdin holds it for ever, so anything between
  // starting it and arranging its death is a window where a failure orphans
  // a process.
  addTearDown(() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  });
  // The lock is not taken until the child says so, and a race here would test
  // the unlocked path while calling itself the locked one.
  var complaint = StringBuffer();
  process.stderr.map(String.fromCharCodes).listen(complaint.write);
  await process.stdout
      .map(String.fromCharCodes)
      .firstWhere(
        (line) => line.contains('held'),
        orElse: () => fail('the lock holder exited: $complaint'),
      )
      .timeout(
        const Duration(seconds: 60),
        onTimeout: () => fail('the lock holder never started: $complaint'),
      );
  return process;
}

/// The real `dart`, which is not always the executable running the test.
///
/// Same walk as `build_lock_test.dart`: under `flutter test`
/// [Platform.resolvedExecutable] is `flutter_tester`, which cannot run a
/// script.
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
