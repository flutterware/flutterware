/// What the scenario replay page, the index a `flutter test` run writes and
/// `fw` say to one another.
///
/// Plain Dart, so the command line that merges the index reads the same
/// types the page does.
library;

/// The file beside the page that says what to load before each scenario.
const replayManifestFile = 'replay.json';

/// The file beside the page that says which steps show each key.
const replayIndexFile = 'replay_index.json';

/// The `type` of each message the page sends or answers.
abstract final class ReplayMessages {
  /// Sent by the page once it can take requests, with what it can replay.
  static const ready = 'flutterware.replay.ready';

  /// Sent to the page to ask for a step.
  static const run = 'flutterware.replay.run';

  /// The page's answer to [run], carrying the request's `id`.
  static const result = 'flutterware.replay.result';
}

/// Which step to show, how, and with which drafts.
class ReplayRequest {
  const ReplayRequest({
    required this.file,
    required this.scenario,
    required this.position,
    this.language,
    this.device,
    this.drafts = const {},
    this.locate = const [],
  });

  /// The test file, relative to the package: `test/scenarios/home_test.dart`.
  final String file;

  /// The scenario's description, as `scenario()` was given it.
  final String scenario;

  /// The step, as the index names it: `#3`, `1.0#2`.
  final String position;

  /// The language to run in, when the scenarios are declared in several.
  final String? language;

  /// The device to run on, by id (`iphone-16`), when there are several.
  final String? device;

  /// Words to show in place of the catalogs', by `catalog/key`.
  final Map<String, String> drafts;

  /// Keys (`catalog/key`) whose places on screen the result should give, as
  /// [ReplayResult.boxes], so the embedding page can draw over them.
  final List<String> locate;

  factory ReplayRequest.fromJson(Map<String, Object?> json) => ReplayRequest(
    file: json['file'] as String? ?? '',
    scenario: json['scenario'] as String? ?? '',
    position: json['position'] as String? ?? '',
    language: json['language'] as String?,
    device: json['device'] as String?,
    drafts: {
      for (var MapEntry(:key, :value)
          in (json['drafts'] as Map? ?? const {}).entries)
        '$key': '$value',
    },
    locate: [for (var key in json['locate'] as List? ?? const []) '$key'],
  );

  /// A request from the page's address, or null when it names none:
  /// `?file=…&scenario=…&position=%233&language=fr&draft=shop/title=Bonjour`.
  static ReplayRequest? fromQuery(Map<String, List<String>> query) {
    String? one(String name) => query[name]?.firstOrNull;
    var file = one('file');
    var scenario = one('scenario');
    var position = one('position');
    if (file == null || scenario == null || position == null) return null;
    return ReplayRequest(
      file: file,
      scenario: scenario,
      position: position,
      language: one('language'),
      device: one('device'),
      drafts: {
        for (var draft in query['draft'] ?? const <String>[])
          if (draft.indexOf('=') case var at when at > 0)
            draft.substring(0, at): draft.substring(at + 1),
      },
      locate: query['locate'] ?? const [],
    );
  }

  Map<String, Object?> toJson() => {
    'file': file,
    'scenario': scenario,
    'position': position,
    'language': ?language,
    'device': ?device,
    if (drafts.isNotEmpty) 'drafts': drafts,
    if (locate.isNotEmpty) 'locate': locate,
  };
}

/// A scenario the page can run, and the points of the matrix it was declared
/// for.
class ReplayScenario {
  const ReplayScenario({
    required this.file,
    required this.scenario,
    required this.points,
  });

  final String file;
  final String scenario;
  final List<ReplayPoint> points;

  /// The point that best matches: the language and the device asked for,
  /// else the language, else the device, else the first one declared.
  ReplayPoint pointFor({String? language, String? device}) {
    bool speaks(ReplayPoint p) => language == null || p.language == language;
    bool runsOn(ReplayPoint p) => device == null || p.device == device;
    return points.where((p) => speaks(p) && runsOn(p)).firstOrNull ??
        points.where(speaks).firstOrNull ??
        points.where(runsOn).firstOrNull ??
        points.first;
  }

  Map<String, Object?> toJson() => {
    'file': file,
    'scenario': scenario,
    'points': [for (var point in points) point.toJson()],
  };
}

class ReplayPoint {
  const ReplayPoint({
    required this.testName,
    required this.label,
    this.device,
    this.language,
  });

  /// The test's full name, matrix label included.
  final String testName;

  /// `iPhone 16 · fr`, or empty when the scenario runs one way.
  final String label;
  final String? device;
  final String? language;

  Map<String, Object?> toJson() => {
    'testName': testName,
    'label': label,
    'device': ?device,
    'language': ?language,
  };
}

/// What a request came to.
class ReplayResult {
  const ReplayResult({
    required this.request,
    required this.reached,
    required this.ok,
    this.point,
    this.steps = 0,
    this.ms = 0,
    this.assetsMs = 0,
    this.failures = const [],
    this.missedAssets = const [],
    this.width,
    this.height,
    this.boxes = const [],
  });

  /// The request names nothing the page can run.
  factory ReplayResult.refused(ReplayRequest request, String why) =>
      ReplayResult(
        request: request,
        reached: false,
        ok: false,
        failures: [why],
      );

  factory ReplayResult.failed(
    ReplayRequest request,
    ReplayPoint point,
    String why,
  ) => ReplayResult(
    request: request,
    point: point,
    reached: false,
    ok: false,
    failures: [why],
  );

  final ReplayRequest request;

  /// The point of the matrix that ran.
  final ReplayPoint? point;

  /// Whether the step is on screen.
  final bool reached;

  /// Whether it got there with nothing failing on the way. A step can be
  /// reached and not ok: the picture is then of an app that had already
  /// failed.
  final bool ok;

  /// Steps of the scenario run, the one shown included.
  final int steps;

  /// From the request to the picture.
  final int ms;

  /// Of [ms], the part spent loading the scenario's assets.
  final int assetsMs;

  final List<String> failures;

  /// Assets the app read that the page had not loaded: the index did not
  /// record them, and the step may be missing what they draw.
  final List<String> missedAssets;

  /// The device's logical size, so an embedding page can give the frame its
  /// shape.
  final double? width;
  final double? height;

  /// Where the keys the request asked to [ReplayRequest.locate] are drawn.
  final List<ReplayBox> boxes;

  Map<String, Object?> toJson() => {
    'request': request.toJson(),
    if (point case var point?) 'point': point.toJson(),
    'reached': reached,
    'ok': ok,
    'steps': steps,
    'ms': ms,
    'assetsMs': assetsMs,
    if (failures.isNotEmpty) 'failures': failures,
    if (missedAssets.isNotEmpty) 'missedAssets': missedAssets,
    'width': ?width,
    'height': ?height,
    if (boxes.isNotEmpty) 'boxes': [for (var box in boxes) box.toJson()],
  };
}

/// One place a key is drawn, in the device's logical pixels from its top
/// left: the same space as [ReplayResult.width] and [ReplayResult.height].
///
/// The page shows the device scaled to fit, centered. In a frame of `w` by
/// `h` CSS pixels the scale is `min(w / width, h / height)`, and the device
/// starts `(w - width * scale) / 2` from the left and `(h - height * scale)
/// / 2` from the top.
class ReplayBox {
  const ReplayBox({
    required this.key,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String key;
  final double left;
  final double top;
  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'key': key,
    'left': _round(left),
    'top': _round(top),
    'width': _round(width),
    'height': _round(height),
  };

  static double _round(double value) => (value * 10).roundToDouble() / 10;
}

/// What a failure says in a replay result.
///
/// A test file that reads the disk compiles for the web and throws there,
/// with a message about the runtime rather than about the file. This says
/// which it is.
String describeReplayFailure(Object error) {
  var said = '$error';
  if (error is UnsupportedError) {
    return 'This scenario uses dart:io (the disk, a process or the '
        'environment), which a web page does not have. Give it what it '
        'reads another way: an asset, or data written in the test. The '
        'error: $said';
  }
  return said;
}

/// What the page loads before a scenario runs.
///
/// Written by `fw` from the index. The page reads it once, when it opens.
class ReplayManifest {
  const ReplayManifest({
    required this.commonAssets,
    required this.scenarios,
    this.defaultFonts = const [],
  });

  static const empty = ReplayManifest(commonAssets: [], scenarios: {});

  /// Font files beside the page, relative to it, that stand in for the
  /// families Flutter's themes name when a style names none: the faces a
  /// `flutter test` run draws that text in.
  final List<String> defaultFonts;

  /// Read before any scenario: what the app reads at start, and what was
  /// read while no scenario was running.
  final List<String> commonAssets;

  /// By `file`, then by scenario.
  final Map<String, Map<String, List<String>>> scenarios;

  List<String> assetsOf(String file, String scenario) =>
      scenarios[file]?[scenario] ?? const [];

  /// What every scenario of [file] reads.
  ///
  /// The page loads the whole file's, not one scenario's: an app that keeps
  /// what it read in a static reads it once per process, so only the first
  /// scenario of a file records it, and the page may run any of them first.
  Set<String> assetsOfFile(String file) => {
    for (var assets in scenarios[file]?.values ?? const <List<String>>[])
      ...assets,
  };

  factory ReplayManifest.fromJson(Map<String, Object?> json) => ReplayManifest(
    commonAssets: _strings(json['commonAssets']),
    defaultFonts: _strings(json['defaultFonts']),
    scenarios: {
      for (var MapEntry(:key, :value)
          in (json['scenarios'] as Map? ?? const {}).entries)
        '$key': {
          for (var MapEntry(key: scenario, value: assets)
              in (value as Map).entries)
            '$scenario': _strings(assets),
        },
    },
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'commonAssets': commonAssets,
    if (defaultFonts.isNotEmpty) 'defaultFonts': defaultFonts,
    'scenarios': scenarios,
  };
}

/// Which steps show each translation key, and what each scenario reads.
///
/// Written by `fw` from what one `flutter test` run recorded, one file per
/// test process.
class ReplayIndex {
  const ReplayIndex({
    required this.scenarios,
    required this.commonAssets,
    required this.fonts,
    this.faces = const [],
  });

  final List<ReplayIndexScenario> scenarios;

  final List<String> commonAssets;

  /// Every font family a step drew text in. The page keeps these and drops
  /// the rest of the app's fonts, which it would otherwise download on
  /// opening.
  final List<String> fonts;

  /// Every face a step drew text in, as `family:weight`, `i` for italic:
  /// `Roboto:500`, `CupertinoSystemText:400i`.
  final List<String> faces;

  /// Folds the files a run wrote into one index. A scenario recorded twice,
  /// in two processes, keeps the union of both.
  factory ReplayIndex.merge(Iterable<Map<String, Object?>> parts) {
    var scenarios = <(String, String), _MergedScenario>{};
    var common = <String>{};
    var fonts = <String>{};
    var faces = <String>{};
    for (var part in parts) {
      common.addAll(_strings(part['commonAssets']));
      fonts.addAll(_strings(part['fonts']));
      faces.addAll(_strings(part['faces']));
      for (var raw in part['scenarios'] as List? ?? const []) {
        var json = raw as Map;
        var file = json['file'] as String?;
        // Declared outside a file of the package: nothing to replay.
        if (file == null) continue;
        var scenario = json['scenario'] as String? ?? '';
        var merged = scenarios[(file, scenario)] ??= _MergedScenario();
        merged.assets.addAll(_strings(json['assets']));
        for (var step in json['steps'] as List? ?? const []) {
          var s = step as Map;
          var position = s['position'] as String? ?? '';
          (merged.steps[position] ??= {}).addAll(_strings(s['keys']));
          merged.verbs[position] ??= s['verb'] as String?;
        }
      }
    }
    var entries = scenarios.entries.toList()
      ..sort((a, b) {
        var byFile = a.key.$1.compareTo(b.key.$1);
        return byFile != 0 ? byFile : a.key.$2.compareTo(b.key.$2);
      });
    return ReplayIndex(
      scenarios: [
        for (var MapEntry(key: (file, scenario), value: merged) in entries)
          ReplayIndexScenario(
            file: file,
            scenario: scenario,
            assets: merged.assets.toList()..sort(),
            steps: [
              for (var position
                  in merged.steps.keys.toList()..sort(comparePositions))
                ReplayIndexStep(
                  position: position,
                  verb: merged.verbs[position],
                  keys: merged.steps[position]!.toList()..sort(),
                ),
            ],
          ),
      ],
      commonAssets: common.toList()..sort(),
      fonts: fonts.toList()..sort(),
      faces: faces.toList()..sort(),
    );
  }

  factory ReplayIndex.fromJson(Map<String, Object?> json) => ReplayIndex(
    scenarios: [
      for (var raw in json['scenarios'] as List? ?? const [])
        ReplayIndexScenario.fromJson((raw as Map).cast()),
    ],
    commonAssets: _strings(json['commonAssets']),
    fonts: _strings(json['fonts']),
    faces: _strings(json['faces']),
  );

  /// Every key shown, with where: the steps a translator can be shown it on.
  Map<String, List<ReplayStepRef>> get keys {
    var keys = <String, List<ReplayStepRef>>{};
    for (var scenario in scenarios) {
      for (var step in scenario.steps) {
        for (var key in step.keys) {
          (keys[key] ??= []).add(
            ReplayStepRef(
              file: scenario.file,
              scenario: scenario.scenario,
              position: step.position,
            ),
          );
        }
      }
    }
    return Map.fromEntries(
      keys.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  ReplayManifest get manifest {
    var byFile = <String, Map<String, List<String>>>{};
    for (var scenario in scenarios) {
      (byFile[scenario.file] ??= {})[scenario.scenario] = scenario.assets;
    }
    return ReplayManifest(commonAssets: commonAssets, scenarios: byFile);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'keys': {
      for (var MapEntry(:key, :value) in keys.entries)
        key: [for (var ref in value) ref.toJson()],
    },
    'scenarios': [for (var scenario in scenarios) scenario.toJson()],
    'commonAssets': commonAssets,
    'fonts': fonts,
    'faces': faces,
  };
}

class _MergedScenario {
  final steps = <String, Set<String>>{};
  final verbs = <String, String?>{};
  final assets = <String>{};
}

class ReplayIndexScenario {
  const ReplayIndexScenario({
    required this.file,
    required this.scenario,
    required this.steps,
    required this.assets,
  });

  final String file;
  final String scenario;
  final List<ReplayIndexStep> steps;
  final List<String> assets;

  factory ReplayIndexScenario.fromJson(Map<String, Object?> json) =>
      ReplayIndexScenario(
        file: json['file'] as String? ?? '',
        scenario: json['scenario'] as String? ?? '',
        steps: [
          for (var raw in json['steps'] as List? ?? const [])
            ReplayIndexStep.fromJson((raw as Map).cast()),
        ],
        assets: _strings(json['assets']),
      );

  Map<String, Object?> toJson() => {
    'file': file,
    'scenario': scenario,
    'steps': [for (var step in steps) step.toJson()],
    'assets': assets,
  };
}

class ReplayIndexStep {
  const ReplayIndexStep({
    required this.position,
    required this.keys,
    this.verb,
  });

  final String position;
  final String? verb;

  /// `catalog/key` of every key on screen at this step.
  final List<String> keys;

  factory ReplayIndexStep.fromJson(Map<String, Object?> json) =>
      ReplayIndexStep(
        position: json['position'] as String? ?? '',
        verb: json['verb'] as String?,
        keys: _strings(json['keys']),
      );

  Map<String, Object?> toJson() => {
    'position': position,
    'verb': ?verb,
    'keys': keys,
  };
}

/// One step, as a request names it.
class ReplayStepRef {
  const ReplayStepRef({
    required this.file,
    required this.scenario,
    required this.position,
  });

  final String file;
  final String scenario;
  final String position;

  Map<String, Object?> toJson() => {
    'file': file,
    'scenario': scenario,
    'position': position,
  };
}

/// Orders positions the way a scenario reaches them: by branch path, then by
/// step, numerically.
int comparePositions(String a, String b) {
  List<int> parts(String position) => [
    for (var part in position.replaceFirst('#', '.#').split('.'))
      if (part.isNotEmpty) int.tryParse(part.replaceFirst('#', '')) ?? 0,
  ];
  var (x, y) = (parts(a), parts(b));
  // The step number is last; compare branch paths first.
  var (px, py) = (x.sublist(0, x.length - 1), y.sublist(0, y.length - 1));
  for (var i = 0; i < px.length && i < py.length; i++) {
    if (px[i] != py[i]) return px[i].compareTo(py[i]);
  }
  if (px.length != py.length) return px.length.compareTo(py.length);
  return x.last.compareTo(y.last);
}

List<String> _strings(Object? value) => [
  for (var item in value as List? ?? const []) '$item',
];
