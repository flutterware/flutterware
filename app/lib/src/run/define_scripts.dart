import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../utils/terminal_environment.dart';

/// What a [ScriptSource] said when it was asked, or why it could not be.
///
/// The two good answers are different in kind, and that difference is the
/// feature. A script that prints **one thing** has *computed the
/// value* — the port this worktree was allocated — and that value is used. One
/// that prints a **JSON array** has *listed the possibilities*, and those are
/// offered to choose from. A config asking for a per-worktree port wants the
/// first; a config asking "which of our backends" wants the second.
class ScriptOutcome {
  const ScriptOutcome.value(String this.value)
    : options = const [],
      problem = null;

  const ScriptOutcome.options(this.options) : value = null, problem = null;

  const ScriptOutcome.failed(String this.problem)
    : value = null,
      options = const [];

  /// The single value the script computed, used as the define's default.
  final String? value;

  /// The values the script offered, when it offered a list.
  final List<String> options;

  /// Why there is no answer. Never null when there is no answer, because a
  /// script source that quietly resolves to nothing is the exact failure this
  /// feature exists to prevent: a define that falls back compiles, runs, and
  /// talks to the wrong thing.
  final String? problem;

  bool get failed => problem != null;
}

/// Runs [source] and reads what it printed.
///
/// [dartExecutable], never a name to look up. The config names a script,
/// not a command, so there is nothing here to resolve against `PATH` — and that
/// is deliberate: a `dart` on `PATH` is routinely older than the SDK a project
/// pins, and a config file cannot know which one its reader has. This is the
/// same `dart` that compiled and ran the config file itself.
///
/// Run from [worktreePath], so a relative path in the script means what it
/// means everywhere else in the project.
///
/// The default [timeout] matches the one the config file itself gets, and for
/// the same reason: a first `dart run` compiles, and a limit tuned to the warm
/// case would report a slow machine as a broken script.
Future<ScriptOutcome> runDefineScript(
  ScriptSource source, {
  required String dartExecutable,
  required String worktreePath,
  Duration timeout = const Duration(seconds: 30),
}) async {
  var file = File(p.join(worktreePath, source.path));
  if (!file.existsSync()) {
    return ScriptOutcome.failed('${source.path} does not exist');
  }

  ProcessResult result;
  try {
    // In a new terminal's environment, because `dart run` runs the package's
    // build hooks, and they rerun from scratch whenever the PATH differs from
    // the last run's. See [terminalEnvironment].
    var environment = await terminalEnvironment();
    result = await Process.run(
      dartExecutable,
      ['run', source.path, ...source.args],
      workingDirectory: worktreePath,
      environment: environment,
      includeParentEnvironment: false,
    ).timeout(timeout);
  } on TimeoutException {
    return ScriptOutcome.failed(
      '${source.path} did not answer within ${timeout.inSeconds}s',
    );
  } on ProcessException catch (e) {
    return ScriptOutcome.failed(
      '${source.path} could not be run: ${e.message}',
    );
  }

  if (result.exitCode != 0) {
    var said = _firstLine(result.stderr);
    return ScriptOutcome.failed(
      '${source.path} exited ${result.exitCode}${said == null ? '' : ': $said'}',
    );
  }

  var out = (result.stdout as String? ?? '').trim();
  if (out.isEmpty) {
    return ScriptOutcome.failed('${source.path} printed nothing');
  }

  // A leading bracket is the whole rule, and it is a rule rather than "try JSON
  // and see" because most of the values worth computing are *also* valid JSON:
  // `8186` parses as a number and `null` as null. Deciding by what the text
  // parses to would make a script that prints a port and one that prints a word
  // behave differently for no reason a user could predict.
  if (!out.startsWith('[')) {
    // A value is one line. Taking the last of several would quietly bake a
    // debug `print` into the build, and taking all of them would bake in a
    // newline — both produce an app that is wrong in a way nothing on screen
    // shows, which is the failure this whole source exists to avoid.
    if (out.contains('\n')) {
      return ScriptOutcome.failed(
        '${source.path} printed ${out.split('\n').length} lines; a computed '
        'value is one line, or a JSON array to choose from',
      );
    }
    return ScriptOutcome.value(out);
  }

  Object? decoded;
  try {
    decoded = jsonDecode(out);
  } on FormatException catch (e) {
    return ScriptOutcome.failed(
      '${source.path} started printing a JSON array and did not finish one: '
      '${e.message}',
    );
  }
  if (decoded is! List) {
    return ScriptOutcome.failed(
      '${source.path} printed JSON that is not an array',
    );
  }
  return ScriptOutcome.options([for (var value in decoded) '$value']);
}

/// The `dart` CLI's own progress chatter, which arrives on stderr in front of
/// whatever the script had to say.
///
/// It is not newline-terminated, so a naive first-line read returns
/// `Running build hooks...Running build hooks...no slot allocated for this
/// worktree` — the tool's noise wrapped around the one sentence that
/// mattered, in a message whose whole job is to quote the script.
final _dartChatter = RegExp(
  r'(Running build hooks\.{0,3}|Building package executable\.{0,3}|'
  r'Built [^\s]+ [^\s]+\.)',
);

/// [output] without what `dart run` says about its own progress.
String withoutDartChatter(String output) => output.replaceAll(_dartChatter, '');

/// The first thing the script itself said on stderr, or null.
String? _firstLine(Object? stderr) {
  var text = withoutDartChatter(stderr as String? ?? '');
  for (var line in text.split(RegExp(r'[\r\n]'))) {
    var trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
