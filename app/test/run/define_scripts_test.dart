import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/run/define_scripts.dart';
import 'package:path/path.dart' as p;

import '../support/dart_executable.dart';

/// A define whose value the project has to work out — the per-worktree port
/// case — against a real `dart` running a real script.
///
/// Spawning is the point: the failure this guards against is a script that
/// cannot answer being mistaken for one that answered nothing in particular,
/// and no fake process can be wrong in the way a real one is.
void main() {
  late Directory worktree;
  late String dart;

  setUpAll(() => dart = resolveDartExecutable());

  setUp(() => worktree = Directory.systemTemp.createTempSync('fw-defines-'));

  tearDown(() {
    if (worktree.existsSync()) worktree.deleteSync(recursive: true);
  });

  Future<ScriptOutcome> run(String source, {List<String> args = const []}) {
    File(p.join(worktree.path, 'tool', 'env.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(source);
    return runDefineScript(
      ScriptSource('tool/env.dart', args: args),
      dartExecutable: dart,
      worktreePath: worktree.path,
    );
  }

  test('one line is the value it computed', () async {
    var outcome = await run('void main() { print(8186); }');

    expect(outcome.value, '8186');
    expect(outcome.options, isEmpty);
    expect(outcome.failed, isFalse);
  });

  test('the arguments are how the script is asked which value', () async {
    var outcome = await run(
      'void main(List<String> a) { print(a.join("-")); }',
      args: ['port', 'server'],
    );

    expect(outcome.value, 'port-server');
  });

  test('a JSON array is a list to choose from, not a value', () async {
    var outcome = await run('void main() { print(\'["a","b"]\'); }');

    expect(outcome.options, ['a', 'b']);
    expect(outcome.value, isNull);
  });

  test('a bracket decides, not what the text parses to', () async {
    // `8186` and `null` are both valid JSON. Deciding by what the output parses
    // to would make a script that prints a port and one that prints a word
    // behave differently for no reason anybody could predict.
    expect((await run('void main() { print("null"); }')).value, 'null');
    expect((await run('void main() { print("12.5"); }')).value, '12.5');
  });

  test('a non-zero exit says so, and says what the script said', () async {
    var outcome = await run('''
import 'dart:io';

void main() {
  stderr.writeln('no .env — run local_env up first');
  exit(3);
}
''');

    expect(outcome.failed, isTrue);
    expect(outcome.problem, contains('exited 3'));
    expect(outcome.problem, contains('run local_env up first'));
  });

  test('more than one line is a failure, not a value with a newline', () async {
    var outcome = await run('''
void main() {
  print('resolving…');
  print(8186);
}
''');

    expect(outcome.failed, isTrue);
    expect(outcome.problem, contains('2 lines'));
  });

  test('printing nothing is a failure, not an empty answer', () async {
    var outcome = await run('void main() {}');

    expect(outcome.failed, isTrue);
    expect(outcome.problem, contains('printed nothing'));
  });

  test('an unfinished JSON array is a failure, not a value', () async {
    var outcome = await run('void main() { print(\'["a",\'); }');

    expect(outcome.failed, isTrue);
    expect(outcome.problem, contains('did not finish'));
  });

  test('a script that is not there says so without running anything', () async {
    var outcome = await runDefineScript(
      const ScriptSource('tool/missing.dart'),
      dartExecutable: dart,
      worktreePath: worktree.path,
    );

    expect(outcome.problem, contains('does not exist'));
  });

  test('a script that never returns is given up on', () async {
    File(p.join(worktree.path, 'tool', 'env.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'dart:async';
void main() { Timer(const Duration(minutes: 5), () {}); }
''');

    var outcome = await runDefineScript(
      const ScriptSource('tool/env.dart'),
      dartExecutable: dart,
      worktreePath: worktree.path,
      timeout: const Duration(seconds: 2),
    );

    expect(outcome.problem, contains('did not answer'));
  });

  test('the failure quotes the script, not the dart CLI', () async {
    File(p.join(worktree.path, 'tool', 'env.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'dart:io';
void main() {
  // The shape `dart run` itself produces: progress on stderr with no newline
  // after it, so the script's own sentence is glued to the end of it.
  stderr.write('Running build hooks...Running build hooks...');
  stderr.writeln('no slot allocated for this worktree');
  exit(1);
}
''');

    var outcome = await runDefineScript(
      const ScriptSource('tool/env.dart'),
      dartExecutable: dart,
      worktreePath: worktree.path,
    );

    // The whole job of this message is to quote the script. Wrapping the one
    // sentence that matters in the tool's own chatter is how a legible
    // refusal becomes an illegible one.
    expect(outcome.problem, contains('no slot allocated for this worktree'));
    expect(outcome.problem, isNot(contains('build hooks')));
  });
}
