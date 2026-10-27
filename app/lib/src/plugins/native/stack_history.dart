import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../../run/run_files.dart';
import 'dev_stack_results.dart';

final _logger = Logger('dev_stack');

/// Where a dev stack's starts and stops are written down and read back.
///
/// The point is the person in the studio seeing what an agent did: an agent
/// starts and stops services from its own process, through the MCP server or
/// `fw`, and the only thing the studio shares with that process is the run
/// directory. So the history is a file there, and the studio follows it.
abstract class StackHistoryStore {
  void record(StackEvent event);

  /// The latest [limit] events, newest first.
  List<StackEvent> read({int limit = 50});

  /// Changes whenever the history may have, so a reader can skip a re-read
  /// when it has not.
  Object? get stamp;

  /// Fires when the history may have changed, from this process or another.
  Stream<void> changes();
}

/// The history as one JSON line per event, in the run directory.
///
/// Appended, one write per line, so two processes recording at once each land
/// whole. Trimmed to the last [keep] lines once it passes [trimAt] bytes, which
/// a dev loop reaches in months rather than days.
class FileStackHistory implements StackHistoryStore {
  FileStackHistory(this._path, {this.keep = 500, this.trimAt = 512 * 1024});

  /// A function, because the container's run-dir seam is one and a test may
  /// point it somewhere else after this was built.
  final String Function() _path;

  /// How many lines a trim leaves.
  final int keep;

  /// How large the file grows before a trim, in bytes.
  final int trimAt;

  @override
  void record(StackEvent event) {
    var file = File(_path());
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${jsonEncode(event.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (file.lengthSync() > trimAt) _trim(file);
    } on Object catch (e) {
      // A history that cannot be written must not fail the start it is
      // describing.
      _logger.warning(
        'Could not write the dev stack history to ${file.path}: $e',
      );
    }
  }

  /// Keeps the last [keep] lines, through a temp file and a rename so a reader
  /// never sees half a file. A line another process appends during the rename
  /// can be lost; that is the price of not locking a file nobody reads twice a
  /// second.
  void _trim(File file) {
    var lines = file.readAsLinesSync();
    var kept = lines.skip(max(0, lines.length - keep));
    File('${file.path}.$pid.tmp')
      ..writeAsStringSync('${kept.join('\n')}\n')
      ..renameSync(file.path);
  }

  @override
  List<StackEvent> read({int limit = 50}) {
    List<String> lines;
    try {
      lines = File(_path()).readAsLinesSync();
    } on Object {
      // Missing, unreadable, or no file system at all.
      return const [];
    }
    var events = <StackEvent>[];
    for (var line in lines.reversed) {
      if (events.length >= limit) break;
      if (line.trim().isEmpty) continue;
      try {
        if (jsonDecode(line) case Map json) {
          events.add(StackEvent.fromJson(json.cast<String, Object?>()));
        }
      } on FormatException {
        // A line cut short by a crash mid-write. The rest still reads.
      }
    }
    return events;
  }

  @override
  Object? get stamp {
    try {
      var stat = File(_path()).statSync();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return (stat.modified, stat.size);
    } on Object {
      return null;
    }
  }

  @override
  Stream<void> changes() => const DiskRunFiles().changes(_path());
}

/// A history that lives in memory: the catalog's, where a preview must neither
/// read nor write the developer's run directory.
class MemoryStackHistory implements StackHistoryStore {
  MemoryStackHistory([Iterable<StackEvent> events = const []])
    : _events = [...events];

  /// Oldest first, as the file is.
  final List<StackEvent> _events;

  final _changes = StreamController<void>.broadcast();

  @override
  void record(StackEvent event) {
    _events.add(event);
    _changes.add(null);
  }

  @override
  List<StackEvent> read({int limit = 50}) =>
      _events.reversed.take(limit).toList();

  @override
  Object? get stamp => _events.length;

  @override
  Stream<void> changes() => _changes.stream;
}

/// What happened, as one line: `API server started`, `API server did not
/// start`. Shared by the panel and the projection, so `fw status` and the
/// studio say it the same way.
String eventHeadline(StackEvent event) {
  var what = switch ((event.verb, event.outcome)) {
    (_, StackEventOutcome.up) => 'started',
    (_, StackEventOutcome.down) => 'stopped',
    (_, StackEventOutcome.alreadyUp) => 'was already running',
    (_, StackEventOutcome.alreadyDown) => 'was not running',
    ('stop', StackEventOutcome.failed) => 'did not stop',
    (_, StackEventOutcome.failed) => 'did not start',
    ('stop', StackEventOutcome.refused) => 'was not stopped',
    (_, StackEventOutcome.refused) => 'was not started',
    (_, StackEventOutcome.exited) => 'exited',
  };
  return '${event.name} $what';
}

/// Who asked, in words.
String eventCaller(StackEvent event) => switch (event.by) {
  'studio' => 'You, in the studio',
  'terminal' => 'fw, in a terminal',
  'agent' => 'An agent',
  null => 'On its own',
  var other => other,
};

/// Why it failed, or how long it took and what it left: `took 3.2s ·
/// localhost:8080 · pid 4120`.
String? eventDetail(StackEvent event) {
  if (event.failure case var failure?) return failure;
  var parts = [
    if (event.took case var took? when !event.outcome.isProblem)
      'took ${_took(took)}',
    ?event.detail,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _took(Duration took) {
  if (took.inMilliseconds < 1000) return '${took.inMilliseconds}ms';
  if (took.inSeconds < 90) {
    return '${(took.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  return '${took.inMinutes}m ${took.inSeconds % 60}s';
}
