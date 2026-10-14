import 'report.dart';

/// On the web there is no filesystem to read a step's events file from — the
/// exported page fetches artifacts over HTTP itself, and the one caller of
/// this seam (a failing run's inlined artifacts) never runs there.
List<Map<String, Object?>> readStepEvents(
  ScenarioRunStep step, {
  String? root,
}) => const [];
