/// The scenarios plugin over a recording: the live core and the live panel,
/// handed a scan and a runner that answer from what `tool/demo/record.dart`
/// kept rather than from a parse of the disk and a `flutter_tester`.
///
/// What a recording holds per package is exactly what the core asks its two
/// doors for — the syntactic scan, the harness's listing, and the harness's
/// own report of each recorded file's run with every artifact copied in
/// beside it. The report is kept verbatim but for its artifact paths, which
/// the tool spells relative to the recording; [RecordedScenarioRunner] puts
/// them under [recordedProjectRoot] on the way out, so the core's own
/// relativising hands the panel a recording-relative path, and the panel's
/// artifact source — the recording itself — reads it. No path here ever
/// names a real directory.
///
/// Opening a scenario runs it, in the panel's model; over a recording that
/// "run" is a read, so the flow page fills in at once and every button on it
/// that would spawn something is honest about the one thing it cannot do.
library;

import 'dart:convert';

// ignore: implementation_imports
import 'package:flutterware/src/scenarios/network_mode.dart';

import '../plugins/native/scenarios_core.dart';
import '../plugins/native/scenarios_plugin.dart';
import '../scenarios/axes.dart';
import '../scenarios/discovery.dart';
import '../scenarios/runner.dart';
import 'recording.dart';

/// A scan that answers from the recording — `ScenariosCore(scan: …)`.
ScenarioScan recordedScenarioScan(Recording recording) =>
    ({required packageRoot, required directory}) async {
      var package = _packagePathOf(packageRoot);
      var path = recordedScenarioScanPath(package);
      // Through `Future.value`, for the reason `recordedIconScanner` gives: a
      // synchronous end must still resume this function on a microtask.
      var text = await Future.value(recording.readString(path));
      if (text == null) {
        throw StateError(
          'This recording has no scenario scan for "$package" '
          '(looked for $path).',
        );
      }
      return ScenarioScanResult.fromJson(
        jsonDecode(text) as Map<String, Object?>,
      );
    };

/// A runner factory that answers from the recording —
/// `ScenariosCore(runner: …)`.
ScenarioRunSourceFactory recordedScenarioRunner(Recording recording) =>
    (path, {required onLog}) =>
        RecordedScenarioRunner(recording, packagePath: path);

/// The flow page's banner icon, from the recording —
/// `ScenariosPlugin(appIcon: …)`.
ScenarioAppIcon recordedScenarioAppIcon(Recording recording) =>
    (packageRoot) => recording.encodedImage(
      recordedScenarioAppIconPath(_packagePathOf(packageRoot)),
    );

/// The recorded project has one package at `.`, which the core addresses by
/// its absolute root.
String _packagePathOf(String packageRoot) {
  if (packageRoot == recordedProjectRoot) return '.';
  var prefix = '$recordedProjectRoot/';
  return packageRoot.startsWith(prefix)
      ? packageRoot.substring(prefix.length)
      : packageRoot;
}

/// The five members of [ScenarioRunSource], read from a recording.
class RecordedScenarioRunner implements ScenarioRunSource {
  RecordedScenarioRunner(this.recording, {required this.packagePath});

  final Recording recording;
  final String packagePath;

  @override
  void Function(Map<String, Object?> event)? onStep;

  /// A file nothing ever wrote. The core only opens it when a caller asks
  /// for the harness console, and answers "none" when it is not there.
  @override
  String get logPath => '$recordedProjectRoot/scenarios/harness.log';

  @override
  Future<List<ScenarioListing>> list() async {
    var json = await _read(recordedScenarioListingsPath(packagePath));
    return [
      for (var entry in (json['scenarios'] as List? ?? const []))
        ScenarioListing.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<Map<String, Object?>> run({
    required String outDir,
    String? file,
    String? scenario,
    String? tag,
    ScenarioAxes axes = const ScenarioAxes(),
    String? unspecifiedDevice,
    int? jobs,
    double? captureScale,
    bool captureRaw = false,
    bool captureNative = false,
    Duration? recordInterval,
    double? recordScale,
    int recordMaxFrames = 90,
    DateTime? clock,
    ScenarioNetwork? network,
    String? networkStore,
    ScenarioPixels pixels = ScenarioPixels.all,
    int? expandTranslations,
    bool narrowestDevice = false,
    FilmSettings? film,
    bool filmReel = false,
  }) async {
    var files = file != null ? [file] : await _recordedFiles();
    var scenarios = <Map<String, Object?>>[];
    var ms = 0;
    String? clockRead;
    var networks = <Object?>{};
    for (var recorded in files) {
      var report = await _read(recordedScenarioRunPath(packagePath, recorded));
      ms += report['ms'] as int? ?? 0;
      clockRead ??= report['clock'] as String?;
      networks.addAll(report['network'] as List? ?? const []);
      for (var entry in (report['scenarios'] as List? ?? const [])) {
        var outcome = (entry as Map).cast<String, Object?>();
        if (scenario != null && outcome['name'] != scenario) continue;
        if (tag != null &&
            !((outcome['tags'] as List?)?.contains(tag) ?? false)) {
          continue;
        }
        scenarios.add(_located(outcome));
      }
    }
    return {
      'scenarios': scenarios,
      'ms': ms,
      'clock': ?clockRead,
      'network': networks.toList(),
    };
  }

  /// The recorded files, as the tool wrote them down.
  Future<List<String>> _recordedFiles() async {
    var json = await _read(recordedScenarioRunsIndexPath(packagePath));
    return (json['files'] as List?)?.cast<String>() ?? const [];
  }

  /// The outcome with every artifact path put under [recordedProjectRoot] —
  /// see the library comment for why.
  Map<String, Object?> _located(Map<String, Object?> outcome) => {
    ...outcome,
    'steps': [
      for (var step in (outcome['steps'] as List? ?? const []))
        {
          for (var MapEntry(:key, :value)
              in (step as Map).cast<String, Object?>().entries)
            key: _pathFields.contains(key) && value is String
                ? '$recordedProjectRoot/$value'
                : value,
        },
    ],
  };

  /// The step fields that name a file — the ones `ScenarioRunStep.locate`
  /// rewrites.
  static const _pathFields = {
    'image',
    'tree',
    'file',
    'keys',
    'semantics',
    'events',
    'frames',
  };

  Future<Map<String, Object?>> _read(String path) async {
    var text = await Future.value(recording.readString(path));
    if (text == null) {
      throw StateError(
        'This recording has no scenario run for "$packagePath" '
        '(looked for $path).',
      );
    }
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  @override
  Future<void> dispose() async {}
}
