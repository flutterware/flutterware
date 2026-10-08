import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../utils/list_files.dart';
import 'harness_entrypoint.dart';

/// Where discovery looks when the config does not say otherwise: all of
/// `test/`. A scenario is an ordinary widget test, and `flutter test` does not
/// care which folder a test sits in — so neither does the scan. The substring
/// prefilter is what keeps the wider walk cheap.
const defaultScenariosScanRoot = 'test';

/// Where `new` writes when the config does not say otherwise — the convention,
/// not a fence. Discovery looks at all of [defaultScenariosScanRoot]; this is
/// only the answer to "where should the next file go".
const defaultScenariosDirectory = 'test/scenarios';

/// One `scenario('name', …)` call, located.
class ScenarioRef {
  ScenarioRef({
    required this.name,
    required this.file,
    required this.line,
    int? endLine,
  }) : endLine = endLine ?? line;

  final String name;

  /// Package-relative, `/`-separated — the same on every machine.
  final String file;

  final int line;

  /// Where the call ends — its closing parenthesis — 1-based and inclusive
  /// like [line]. What tells a branch's diff which scenario in a file it
  /// touched; see `entry_change.dart`.
  final int endLine;

  factory ScenarioRef.fromJson(Map<String, Object?> json) => ScenarioRef(
    name: json['name']! as String,
    file: json['file']! as String,
    line: json['line']! as int,
    endLine: json['endLine'] as int?,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'file': file,
    'line': line,
    'endLine': endLine,
  };

  @override
  String toString() => '$file:$line $name';
}

class ScenarioScanResult {
  ScenarioScanResult({
    required this.scenarios,
    required this.diagnostics,
    this.unnamed = 0,
    this.configFolders = const [],
  });

  final List<ScenarioRef> scenarios;

  /// Every folder whose `flutter_test_config.dart` governs one of
  /// [scenarios] — package-relative, `''` for the package root, listed once.
  ///
  /// Here so that *which pool a scenario belongs to* is a question the scan
  /// answers rather than the disk: the panel used to stat the folders on
  /// every scenario it opened, which is a read a recording cannot answer
  /// and a browser cannot make.
  final List<String> configFolders;

  /// The folder whose `flutter_test_config.dart` governs [file] — the nearest
  /// of [configFolders] at or above it — or null where nothing does. The same
  /// answer `testConfigFolderFor` reads off the disk.
  String? testConfigFolderOf(String file) {
    var directory = p.url.dirname(file);
    if (directory == '.') directory = '';
    while (true) {
      if (configFolders.contains(directory)) return directory;
      if (directory.isEmpty) return null;
      directory = p.url.dirname(directory);
      if (directory == '.') directory = '';
    }
  }

  /// What the scan noticed but did not act on — a non-literal name it cannot
  /// list, a duplicate. Never guessed at, always reported.
  final List<String> diagnostics;

  /// How many `scenario(…)` calls the scan found and could not name.
  ///
  /// Each is a line in [diagnostics] as well, and this is the same fact for a
  /// reader who has to *act* on it rather than print it: zero means this
  /// listing is the whole set, and anything else means it is a subset of what
  /// the harness would report. A duplicate is not one of these — it is
  /// ambiguous, not missing, and the listing still holds it.
  final int unnamed;

  /// The scan as a recording keeps it — every field, so a reader of the
  /// recording sees exactly what the scan of the disk saw.
  factory ScenarioScanResult.fromJson(Map<String, Object?> json) =>
      ScenarioScanResult(
        scenarios: [
          for (var entry in (json['scenarios'] as List? ?? const []))
            ScenarioRef.fromJson((entry as Map).cast<String, Object?>()),
        ],
        diagnostics: (json['diagnostics'] as List?)?.cast<String>() ?? const [],
        unnamed: json['unnamed'] as int? ?? 0,
        configFolders:
            (json['configFolders'] as List?)?.cast<String>() ?? const [],
      );

  Map<String, Object?> toJson() => {
    'scenarios': [for (var ref in scenarios) ref.toJson()],
    'diagnostics': diagnostics,
    'unnamed': unnamed,
    'configFolders': configFolders,
  };
}

/// Finds scenarios by **parsing** the scenario directory, never by resolving
/// or compiling it — the catalog's discovery posture, applied to the third
/// source.
///
/// A `scenario('literal', …)` call is as syntactically discoverable as a
/// `@Preview` annotation: the call's name and its first argument are all the
/// report and the badges need. The runtime listing stays ground truth; a
/// disagreement is a diagnostic, not a failure.
class ScenarioScanner {
  ScenarioScanner({
    required this.packageRoot,
    this.directory = defaultScenariosScanRoot,
  });

  final String packageRoot;

  /// The directory the scan walks, relative to [packageRoot].
  final String directory;

  ScenarioScanResult scan() {
    var scenarios = <ScenarioRef>[];
    var diagnostics = <String>[];
    var unnamed = 0;
    var configFolders = <String>{};

    var root = p.join(packageRoot, directory);
    var rootUrl = p.url.joinAll(p.split(directory));
    if (Directory(root).existsSync()) {
      // Listed the way git lists — see `list_files.dart`. A recursive
      // `listSync` follows symlinks by default, which is how a scan of a
      // modest directory ends up reading whatever a link inside it points at.
      var files = [
        for (var file in listFilesInDirectory(root))
          if (file.path.endsWith('.dart')) file,
      ]..sort((a, b) => a.path.compareTo(b.path));
      for (var file in files) {
        if (p.basename(file.path) == testConfigFileName) {
          var folder = p.url.dirname(
            p.url.joinAll(p.split(p.relative(file.path, from: packageRoot))),
          );
          configFolders.add(folder == '.' ? '' : folder);
          continue;
        }
        var source = file.readAsStringSync();
        // A substring prefilter before parsing, as the catalog scanner does.
        if (!source.contains('scenario(')) continue;
        unnamed += _scanFile(file, source, scenarios, diagnostics);
      }
      // A config above the scan root governs everything in it that has no
      // nearer one — the same rule the harness applies, so the two agree.
      if (testConfigFolderFor(packageRoot, p.url.join(rootUrl, '_'))
          case var above?) {
        configFolders.add(above);
      }
    }

    _reportDuplicates(scenarios, diagnostics);
    return ScenarioScanResult(
      scenarios: scenarios,
      diagnostics: diagnostics,
      unnamed: unnamed,
      configFolders: configFolders.toList()..sort(),
    );
  }

  /// Adds one file's scenarios to [scenarios] and returns how many calls in it
  /// could not be named — see [ScenarioScanResult.unnamed].
  int _scanFile(
    File file,
    String source,
    List<ScenarioRef> scenarios,
    List<String> diagnostics,
  ) {
    var parsed = parseString(content: source, throwIfDiagnostics: false);
    var path = p.split(p.relative(file.path, from: packageRoot)).join('/');

    var visitor = _ScenarioCallVisitor();
    parsed.unit.accept(visitor);
    var unnamed = 0;
    for (var call in visitor.calls) {
      var line = parsed.lineInfo.getLocation(call.offset).lineNumber;
      var endLine = parsed.lineInfo.getLocation(call.end).lineNumber;
      var name = call.name;
      if (name == null) {
        diagnostics.add(
          '$path:$line: scenario name is not a string literal, so it cannot '
          'be listed without running the file',
        );
        unnamed++;
        continue;
      }
      scenarios.add(
        ScenarioRef(name: name, file: path, line: line, endLine: endLine),
      );
    }
    return unnamed;
  }

  /// Two scenarios with one name are both real, and the name is only
  /// ambiguous **within a file**.
  ///
  /// A name repeated across files costs nothing: the file is part of a
  /// scenario's address (`<package>/<file…>/<scenario>`), `run --scenario=`
  /// refuses without one, and the harness writes its artifacts under
  /// `<file>/<name>`. All three tell two `Overview`s in two files apart on
  /// their own, so warning about them enforced a rule nothing in the tool
  /// actually held — a suite that names the same screen once per feature file
  /// got a warning it could do nothing about.
  ///
  /// Repeated *in one file* is the case where those three have nothing left to
  /// choose by. Reported rather than rejected: the run honours a name matching
  /// twice by running both, which is the right reading of a request that names
  /// only what the panel displays.
  void _reportDuplicates(
    List<ScenarioRef> scenarios,
    List<String> diagnostics,
  ) {
    var byName = <(String, String), List<ScenarioRef>>{};
    for (var ref in scenarios) {
      byName.putIfAbsent((ref.file, ref.name), () => []).add(ref);
    }
    for (var MapEntry(key: (file, name), value: refs) in byName.entries) {
      if (refs.length < 2) continue;
      diagnostics.add(
        '$file: scenario "$name" is declared ${refs.length} times '
        '(lines ${refs.map((r) => r.line).join(', ')}). Running or opening '
        'one of them runs or opens them all.',
      );
    }
  }
}

/// The deepest directory every file in [files] sits under, `/`-separated like
/// the paths themselves, or `''` when they share none (or there are none).
///
/// What the list pane drops from its labels: a prefix every row shares says
/// nothing. Computed from the files found rather than read off the
/// configuration, so a suite kept conventionally under `test/scenarios/`
/// displays exactly as it did when that was the fence, and one spread across
/// `test/` shows the part that differs.
String commonScenarioDirectory(Iterable<String> files) {
  List<String>? common;
  for (var file in files) {
    var directory = p.url.dirname(file);
    var segments = directory == '.' ? <String>[] : p.url.split(directory);
    if (common == null) {
      common = segments;
      continue;
    }
    var length = 0;
    while (length < common.length &&
        length < segments.length &&
        common[length] == segments[length]) {
      length++;
    }
    common = common.sublist(0, length);
  }
  return common == null || common.isEmpty ? '' : p.url.joinAll(common);
}

class _ScenarioCall {
  _ScenarioCall({required this.name, required this.offset, required this.end});

  final String? name;
  final int offset;
  final int end;
}

class _ScenarioCallVisitor extends RecursiveAstVisitor<void> {
  final calls = <_ScenarioCall>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && node.methodName.name == 'scenario') {
      var first = node.argumentList.arguments.firstOrNull;
      calls.add(
        _ScenarioCall(
          name: first is StringLiteral ? first.stringValue : null,
          offset: node.offset,
          end: node.end,
        ),
      );
    }
    super.visitMethodInvocation(node);
  }
}
