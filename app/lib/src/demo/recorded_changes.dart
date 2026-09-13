/// The changes screen over a recording: a git tape, and the files it read.
///
/// The screen's probe is a dozen git calls and two reads off the working
/// tree, and the recorder ran the real one over a real checkout through a
/// runner that kept every call's answer. Here the same probe runs over those
/// answers: the patch is indexed, the files are ranked, the untracked entries
/// are stamped by the same code, over what git said once. The two reads —
/// the stat that stamps an untracked file, the bytes behind an image or a
/// rendered markdown file — come from the copies the recorder took.
///
/// The tape is one map, keyed by the argument list. That is also what the
/// explorer's facts and the worktree list are answered from: the recorder
/// asked git the same questions, in the same words, so the tab says the
/// recorded branch and the overview says how far ahead it is.
library;

import 'dart:convert';
import 'dart:io' show ProcessResult;
import 'dart:typed_data';

import '../changes/changes_config_cache.dart';
import '../changes/changes_files.dart';
import '../changes/changes_probe.dart';
import '../changes/changes_sources.dart';
import '../changes/file_contents.dart';
import '../changes/review_store.dart';
import 'recorded_config.dart';
import 'recording.dart';

/// Every git answer the recording has, addressed by the arguments asked with.
class RecordedGit {
  RecordedGit(this.recording);

  final Recording recording;

  Map<String, _Call>? _calls;

  Future<Map<String, _Call>> _tape() async {
    if (_calls case var loaded?) return loaded;
    // Through `Future.value`, so a synchronous end still resumes this
    // function on a microtask — see `recordedIconScanner`.
    var text = await Future.value(recording.readString(recordedGitTapePath));
    if (text == null) return _calls = const {};
    var json = jsonDecode(text) as Map<String, Object?>;
    return _calls = {
      for (var call in (json['calls']! as List).cast<Map<String, Object?>>())
        gitTapeKey((call['args']! as List).cast<String>()): _Call(
          exitCode: call['exit']! as int,
          out: call['out'] as String?,
        ),
    };
  }

  /// The probe's runner. The directory is not part of the key: a recording
  /// has one checkout, and every call was made in it.
  Future<GitOutput> run(String directory, List<String> arguments) async {
    var call = (await _tape())[gitTapeKey(arguments)];
    if (call == null) {
      return GitOutput(
        exitCode: 1,
        stdout: Uint8List(0),
        stderr: 'not in the recording: git ${arguments.join(' ')}',
      );
    }
    var bytes = call.out == null
        ? null
        : await Future.value(recording.readBytes(call.out!));
    return GitOutput(exitCode: call.exitCode, stdout: bytes ?? Uint8List(0));
  }

  /// The explorer's runner — the facts probe's and the worktree list's —
  /// which wants text.
  Future<ProcessResult> runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    var out = await run(workingDirectory ?? recordedProjectRoot, arguments);
    return ProcessResult(
      0,
      out.exitCode,
      const Utf8Decoder(allowMalformed: true).convert(out.stdout),
      out.stderr,
    );
  }
}

class _Call {
  const _Call({required this.exitCode, required this.out});

  final int exitCode;

  /// Where the answer's bytes are, or null for an answer with none.
  final String? out;
}

/// The working-tree reads, from the copies the recorder took.
class RecordedChangesFiles extends ChangesFiles {
  RecordedChangesFiles(this.recording);

  final Recording recording;

  Map<String, FileFacts>? _index;

  Future<Map<String, FileFacts>> _facts() async {
    if (_index case var loaded?) return loaded;
    var text = await Future.value(
      recording.readString(recordedChangesFilesIndexPath),
    );
    if (text == null) return _index = const {};
    var json = jsonDecode(text) as Map<String, Object?>;
    return _index = {
      for (var MapEntry(:key, :value) in json.entries)
        if (value case Map<String, Object?> facts)
          key: (
            size: facts['size']! as int,
            modified: DateTime.parse(facts['modified']! as String),
          ),
    };
  }

  /// `/recording/lib/a.dart` → `lib/a.dart`; a path outside the checkout is
  /// nothing the recording has.
  static String? _relative(String path) {
    const prefix = '$recordedProjectRoot/';
    var spelled = path.replaceAll(r'\', '/');
    return spelled.startsWith(prefix) ? spelled.substring(prefix.length) : null;
  }

  @override
  Future<FileFacts?> stat(String path) async {
    var relative = _relative(path);
    return relative == null ? null : (await _facts())[relative];
  }

  @override
  Future<Uint8List?> readBytes(String path) async {
    var relative = _relative(path);
    if (relative == null) return null;
    return Future.value(recording.readBytes(recordedChangesFilePath(relative)));
  }
}

/// The changes screen's three sources, over [recording].
///
/// [git] is shared with the explorer when the caller has one, so the tape is
/// read once. The notes taken on the screen live in memory for the session.
ChangesSources recordedChangesSources(Recording recording, {RecordedGit? git}) {
  var tape = git ?? RecordedGit(recording);
  var files = RecordedChangesFiles(recording);
  var probe = ChangesProbe(runGit: tape.run, files: files);
  var notes = MemoryReviewStore();
  return ChangesSources(
    load: (path) => probe.probe(
      path,
      config: recordedChangesConfig,
      configState: ChangesConfigState.fresh,
    ),
    contents: (path) => FileContentStore(path, probe: probe, files: files),
    reviewStore: (_) => notes,
    comparisonUnavailable:
        'This is a recording: there is no checkout to build a base of, so '
        'nothing to compare against. The files are here.',
  );
}
