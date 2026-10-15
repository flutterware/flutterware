import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'report.dart';

/// The transition's events, read from the file the harness wrote beside the
/// pixels — empty when there were none, and empty rather than throwing when
/// the file cannot be read: a missing artifact must not take a failure report
/// down with it.
///
/// The path resolves against [root] when given, and the step's own
/// [ScenarioRunStep.root] otherwise — which is empty on a step read back out
/// of a report, leaving the path relative to the working directory.
List<Map<String, Object?>> readStepEvents(
  ScenarioRunStep step, {
  String? root,
}) {
  var path = step.events;
  if (path == null) return const [];
  var file = File(p.join(root ?? step.root, path));
  if (!file.existsSync()) return const [];
  try {
    return [
      for (var event in jsonDecode(file.readAsStringSync()) as List)
        (event as Map).cast<String, Object?>(),
    ];
  } catch (_) {
    return const [];
  }
}
