/// Regenerates the screenshots `README.md` and the guides in `doc/` show.
///
/// ```sh
/// fvm dart tool/screenshots.dart                      # everything
/// fvm dart tool/screenshots.dart --compose hero        # redraw one picture
/// ```
///
/// `--compose` skips the scenarios and the store export and redraws from the
/// shots the last full run left in [rawDirectory] — the loop for working on
/// a composition rather than on what it shows.
///
/// Named through fvm because the pictures are rendered by the `dart` that runs
/// this script: the one on PATH is older than the workspace floor.
///
/// **Every picture of the studio is a named step of one of its own
/// scenarios**, run headless over the recording `app/tool/demo/record.dart`
/// made of the demo app — see [suites]. `Shot('card-run')` in a scenario is
/// `doc/screenshots/card-run.png` here, and nothing else decides what a
/// picture shows. No window is opened, no GUI is built, no clone of the demo
/// is needed, and the same recording gives the same pictures on any machine.
/// A picture that should show something new is a new step in a scenario, or a
/// new recording.
///
/// The pictures that are not the studio come from where they really are: the
/// store images are the demo app's own `fw run store export`, run here first.
///
/// Then [composed] lays the raw shots out at the size a README wants — the
/// hero, the grid's cards, the guides' windows — through preview entries in
/// `app/tool/catalog/readme/hero.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the pictures go, relative to the repo root.
const outputDirectory = 'doc/screenshots';

/// Where the scenarios' named shots are gathered before they are composed:
/// full resolution, one file per shot name. Build output, never committed.
const rawDirectory = 'build/screenshots/raw';

/// A scenario file whose named steps are pictures.
class Suite {
  const Suite(this.package, this.file);

  /// The scenarios package, as `tool/flutterware.dart` declares it.
  final String package;

  /// The file, relative to that package.
  final String file;
}

const suites = [
  // The README's grid: a 4:3 window per card, the rail folded away.
  Suite('app', 'test/scenarios/studio/readme/readme_test.dart'),
  // The previews card, from the one package the previews are compiled into.
  Suite('web_demo', 'test/scenarios/readme/readme_test.dart'),
  // The guides' windows, and the one the hero is drawn around.
  Suite('app', 'test/scenarios/studio/docs/docs_test.dart'),
  Suite('web_demo', 'test/scenarios/docs/docs_test.dart'),
];

/// A picture drawn by a preview entry from the raw shots.
class Composed {
  const Composed(
    this.name,
    this.symbol, {
    required this.width,
    required this.height,
    this.knobs,
  });

  final String name;
  final String symbol;
  final int width;
  final int height;
  final String? knobs;

  String get entry => 'tool/catalog/readme/hero.dart#$symbol';
  String get file => '$outputDirectory/$name.png';
}

/// The README's cards, in the order the grid shows them.
const cards = [
  'card-previews',
  'card-scenarios',
  'card-store',
  'card-translations',
  'card-run',
  'card-comparison',
  'card-changes',
  'card-server',
];

/// The guides' pictures: a window each.
const guides = [
  'previews',
  'previews-tree',
  'scenarios',
  'scenarios-step',
  'store',
  'store-listing',
  'translations',
  'comparison',
  'changes',
  'run',
  'server',
  'dev-stack',
  'dependencies',
  'native-splash',
  'launcher-icon',
];

final composed = [
  // 16:9 at the width of a README column on a 2x screen. The entry lays
  // itself out on a 1600-wide board and scales to this, so the size is free.
  const Composed('hero', 'readmeHero', width: 2000, height: 1125),
  // 4:3, shown at half a column: 1200 is 2x of the widest that ever gets.
  for (var card in cards)
    Composed(card, 'readmeShot', width: 1200, height: 900, knobs: 'file=$card'),
  // 16:10, shown at a column: 1800 is 2x of it, and smaller than the 2880 the
  // window was photographed at.
  for (var guide in guides)
    Composed(
      guide,
      'readmeShot',
      width: 1800,
      height: 1125,
      knobs: 'file=$guide',
    ),
  // Four exported App Store images side by side, for the store guide.
  const Composed('store-strip', 'readmeStoreStrip', width: 1600, height: 858),
];

Future<void> main(List<String> arguments) async {
  var only = arguments.where((a) => !a.startsWith('-')).toSet();
  var root = _repoRoot();
  var failed = <String>[];
  if (!arguments.contains('--compose')) await _capture(root, failed);
  await _compose(root, only, failed);

  if (failed.isNotEmpty) {
    stderr.writeln('\n${failed.length} failed: ${failed.join(', ')}');
    exit(1);
  }
  stdout.writeln('\nDone. Check `git status $outputDirectory`.');
}

/// The store export, then every suite's named shots into [rawDirectory].
Future<void> _capture(String root, List<String> failed) async {
  stdout.writeln('The demo app’s store export');
  if (!await _fw(p.join(root, 'examples', 'brewline'), ['store', 'export'])) {
    failed.add('store export');
  }

  stdout.writeln('The scenarios behind every picture');
  var raw = Directory(p.join(root, rawDirectory));
  if (raw.existsSync()) raw.deleteSync(recursive: true);
  raw.createSync(recursive: true);
  for (var suite in suites) {
    stdout.write('  ${suite.package}/${suite.file}  ');
    var shots = await _shots(root, suite);
    if (shots == null) {
      stdout.writeln('FAILED');
      failed.add(suite.file);
      continue;
    }
    for (var shot in shots) {
      // `NN-name.png`: the number is the step's order in the run, which is
      // the one thing about a shot a picture's file name must not depend on.
      var name = p.basename(shot).replaceFirst(RegExp(r'^\d+-'), '');
      File(shot).copySync(p.join(raw.path, name));
    }
    stdout.writeln('${shots.length} shots');
  }
}

Future<void> _compose(
  String root,
  Set<String> only,
  List<String> failed,
) async {
  stdout.writeln('The pictures');
  for (var picture in composed) {
    if (only.isNotEmpty && !only.contains(picture.name)) continue;
    stdout.write('  ${picture.name.padRight(24)}');
    var ok = await _render(root, picture);
    stdout.writeln(ok ? picture.file : 'FAILED');
    if (!ok) failed.add(picture.name);
  }
}

/// Runs [suite] through `scenarios shots` and returns the named shots it
/// wrote, or null when the run failed.
///
/// A failed scenario fails the lot rather than leaving its pictures stale:
/// the pictures are only true of the recording if every walk to them still
/// works.
Future<List<String>?> _shots(String root, Suite suite) async {
  var output = p.join(
    root,
    'build',
    'screenshots',
    'shots',
    suite.package,
    p.basenameWithoutExtension(p.dirname(suite.file)),
  );
  var directory = Directory(output);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  var result = await _fwJson(root, [
    'scenarios',
    'shots',
    '--package=${suite.package}',
    '--file=${suite.file}',
    '--output=$output',
  ]);
  if (result == null) return null;
  var shots = <String>[];
  for (var package in result['packages'] as List? ?? const []) {
    for (var entry in (package as Map)['sets'] as List? ?? const []) {
      var set = entry as Map;
      if ((set['failed'] as num? ?? 0) > 0) return null;
      for (var image in set['images'] as List) {
        shots.add(p.join(output, '${set['directory']}', '$image'));
      }
    }
  }
  return shots;
}

Future<bool> _render(String root, Composed picture) async {
  var result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'flutterware',
    'run',
    'previews',
    'screenshot',
    '--entry=${picture.entry}',
    '--width=${picture.width}',
    '--height=${picture.height}',
    if (picture.knobs case var knobs?) '--knobs=$knobs',
    '--output=${p.join(root, picture.file)}',
  ], workingDirectory: root);
  return result.exitCode == 0;
}

/// `dart run flutterware run <arguments>` in [cwd], with the `dart` running
/// this script — the SDK is whichever one the invocation named.
Future<bool> _fw(String cwd, List<String> arguments) async {
  var result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'flutterware',
    'run',
    ...arguments,
  ], workingDirectory: cwd);
  if (result.exitCode != 0) {
    stderr
      ..writeln(result.stdout)
      ..writeln(result.stderr);
  }
  return result.exitCode == 0;
}

/// [_fw], and the action's result: the last JSON object it printed.
Future<Map<String, Object?>?> _fwJson(
  String cwd,
  List<String> arguments,
) async {
  var result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'flutterware',
    'run',
    ...arguments,
  ], workingDirectory: cwd);
  var out = result.stdout as String;
  // Whatever the launcher and the harness narrate comes first; the result is
  // the object that starts on a line of its own.
  var start = out.startsWith('{') ? 0 : out.indexOf('\n{') + 1;
  if (result.exitCode != 0 || start <= 0 && !out.startsWith('{')) {
    stderr
      ..writeln(out)
      ..writeln(result.stderr);
    return null;
  }
  try {
    var json = jsonDecode(out.substring(start)) as Map<String, Object?>;
    return (json['result'] as Map<String, Object?>?) ?? json;
  } on FormatException {
    stderr.writeln(out);
    return null;
  }
}

/// The repo root, anchored on this script rather than on cwd.
String _repoRoot() {
  var dir = File.fromUri(Platform.script).parent;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'app')).existsSync()) {
      return dir.path;
    }
    var parent = dir.parent;
    if (parent.path == dir.path) throw StateError('no repository above');
    dir = parent;
  }
}
