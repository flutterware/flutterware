/// The dev stack plugin over a recording: the stack's own script, answered
/// from a file rather than spawned. See `tool/demo/record.dart --only=stack`.
///
/// The core already takes its process runner as a value — the catalog
/// scripts five stacks on one screen that way — so the recording is one
/// more runner: it looks at which verb the declared command carries and
/// hands back what the script printed for it. `up` and `down` move a state
/// the probe then reports, so the panel's controls do what they say.
library;

import 'dart:convert';
import 'dart:io';

// ignore: implementation_imports
import 'package:flutterware/src/clock.dart';

import '../plugins/native/dev_stack_results.dart';
import '../worktrees/providers/stack.dart';
import 'recording.dart';

class RecordedStack {
  RecordedStack(this.recording, {this.packagePath = '.'});

  final Recording recording;
  final String packagePath;

  Map<String, Object?>? _file;
  String? _state;

  Future<Map<String, Object?>?> _load() async {
    if (_file case var file?) return file;
    var text = await Future.value(
      recording.readString(recordedStackPath(packagePath)),
    );
    if (text == null) return null;
    var file = jsonDecode(text) as Map<String, Object?>;
    _state ??= file['state'] as String? ?? 'up';
    return _file = file;
  }

  /// What the script printed for [verb], in the current state when the
  /// answer depends on it. Null when the recording has nothing for it.
  Future<({int exitCode, String stdout, String stderr})?> answer(
    String verb,
  ) async {
    var file = await _load();
    if (file == null) return null;
    var answers = file['answers'];
    if (answers is! Map) return null;
    var raw = answers['$verb@$_state'] ?? answers[verb];
    if (raw is! Map) return null;
    if (verb == 'up' || verb == 'down') _state = verb;
    return (
      exitCode: raw['exitCode'] as int? ?? 0,
      stdout: raw['stdout'] as String? ?? '',
      stderr: raw['stderr'] as String? ?? '',
    );
  }

  /// The core's process runner, answering from the recording. The verb is
  /// the first argument after the script the declaration names, or the last
  /// argument when there is no script.
  Future<ProcessResult> run(
    List<String> command, {
    String? workingDirectory,
  }) async {
    var script = command.indexWhere((arg) => arg.endsWith('stack.dart'));
    var verb = script >= 0 && script + 1 < command.length
        ? command[script + 1]
        : command.last;
    var answer = await this.answer(verb);
    if (answer == null) {
      return ProcessResult(
        0,
        64,
        '',
        'The recording has no answer for `$verb`.',
      );
    }
    return ProcessResult(0, answer.exitCode, answer.stdout, answer.stderr);
  }
}

/// The worktree explorer's column, from the same recording: what the probe
/// says right now, at the pinned instant everything recorded renders at.
class RecordedStacks implements StackProbe {
  RecordedStacks(this.stack);

  final RecordedStack stack;

  @override
  Future<StackReading?> probe(String worktreePath) async {
    var answer = await stack.answer('status');
    if (answer == null) return null;
    var read = StackReading.fromJson(
      (jsonDecode(answer.stdout) as Map).cast<String, Object?>(),
    );
    return StackReading(
      state: read.state,
      at: pinnedClockOrigin,
      detail: read.detail,
      services: read.services,
    );
  }
}
