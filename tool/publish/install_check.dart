/// Installs flutterware the way a stranger does — from the files `pub publish`
/// would upload, sitting in the pub cache — and runs it.
///
/// ```sh
/// fvm dart tool/publish/install_check.dart          # stage, install, clean up
/// fvm dart tool/publish/install_check.dart --keep   # leave it all for a look
/// ```
///
/// Every other check here starts flutterware from this checkout, and a
/// checkout takes the other branch of the launcher: no copy, no `pub get` of
/// its own, and nothing `.pubignore` leaves out. The hosted branch had no test
/// and broke unseen — the archive carried a workspace list naming packages it
/// did not contain, and every install stopped at its first `pub get`.
///
/// So this asks pub which files it would upload, puts exactly those inside the
/// pub cache — which is what the launcher takes a hosted package to be — points
/// a new project at them, and runs `dart run flutterware --version`: the
/// unpack, the resolve and the CLI build of a first run, without the window.
library;

import 'dart:io';

import 'package:flutterware/src/working_copy.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  var keep = args.contains('--keep');
  var root = _repoRoot();
  var dart = Platform.resolvedExecutable;

  stdout.writeln('Asking pub what it would upload…');
  var dryRun = await Process.run(dart, [
    'pub',
    'publish',
    '--dry-run',
  ], workingDirectory: root);
  var listing = '${dryRun.stdout}';
  var (version, files) = parseArchiveListing(listing);
  stdout.writeln('flutterware $version: ${files.length} files');

  var pubCache =
      Platform.environment['PUB_CACHE'] ??
      p.join(userHomePath(), Platform.isWindows ? 'Pub/Cache' : '.pub-cache');
  var staged = p.join(pubCache, 'install-check', 'flutterware-$version');
  var project = Directory.systemTemp.createTempSync('install_check').path;
  try {
    _stage(root, staged, files);

    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('''
name: install_check
publish_to: none
environment:
  sdk: ^3.0.0
dependencies:
  flutter:
    sdk: flutter
  flutterware:
    path: ${_yamlString(staged)}
''');
    await _run(dart, ['pub', 'get'], project);

    var out = StringBuffer();
    await _run(dart, ['run', 'flutterware', '--version'], project, out: out);
    if (!'$out'.contains(version)) {
      _fail('`fw --version` did not print $version:\n$out');
    }
    stdout.writeln(
      '\nInstalled from the archive and ran: flutterware $version.',
    );
  } finally {
    if (keep) {
      stdout.writeln(
        'Kept:\n  $staged\n  $project\n  ${workingCopyPath(staged)}',
      );
    } else {
      for (var dir in [staged, project, workingCopyPath(staged)]) {
        if (Directory(dir).existsSync()) {
          Directory(dir).deleteSync(recursive: true);
        }
      }
    }
  }
}

/// The version and the files in the tree `pub publish --dry-run` prints.
///
/// pub's own answer rather than a reading of `.pubignore`: the rules of which
/// files ship are pub's, and a second implementation of them is a second
/// place to be wrong. A listing this cannot read fails rather than shrinks —
/// a partial list would install a package pub would never publish.
(String, List<String>) parseArchiveListing(String listing) {
  var lines = listing.split('\n');
  var start = lines.indexWhere((l) => l.startsWith('Publishing '));
  var end = lines.indexWhere((l) => l.startsWith('Total compressed archive'));
  if (start < 0 || end < start) {
    _fail('no file tree in the output of `pub publish --dry-run`:\n$listing');
  }
  var version = RegExp(r'^Publishing \S+ (\S+) to')
      .firstMatch(lines[start])
      ?.group(1);
  if (version == null) _fail('no version in: ${lines[start]}');

  var entry = RegExp(r'^((?:│   |    )*)(?:├── |└── )(.+)$');
  var size = RegExp(r' \((?:<1|\d+) [KMG]?B\)$');
  var dirs = <String>[];
  var files = <String>[];
  for (var line in lines.sublist(start + 1, end)) {
    if (line.trim().isEmpty) continue;
    var match = entry.firstMatch(line);
    if (match == null) _fail('unreadable line in the file tree: $line');
    var depth = match.group(1)!.length ~/ 4;
    var name = match.group(2)!;
    if (depth > dirs.length) _fail('the tree skips a level at: $line');
    dirs.length = depth;
    if (size.hasMatch(name)) {
      files.add(p.joinAll([...dirs, name.replaceFirst(size, '')]));
    } else {
      dirs.add(name);
    }
  }
  for (var required in ['pubspec.yaml', p.join('app', 'pubspec.yaml')]) {
    if (!files.contains(required)) _fail('the archive has no $required');
  }
  return (version, files);
}

void _stage(String root, String staged, List<String> files) {
  if (Directory(staged).existsSync()) {
    Directory(staged).deleteSync(recursive: true);
  }
  for (var file in files) {
    var target = p.join(staged, file);
    Directory(p.dirname(target)).createSync(recursive: true);
    File(p.join(root, file)).copySync(target);
  }
}

String _yamlString(String path) => "'${path.replaceAll("'", "''")}'";

Future<void> _run(
  String exe,
  List<String> args,
  String cwd, {
  StringSink? out,
}) async {
  stdout.writeln('\n\$ ${p.basename(exe)} ${args.join(' ')}');
  var process = await Process.start(exe, args, workingDirectory: cwd);
  var done = [
    process.stdout.transform(systemEncoding.decoder).forEach((chunk) {
      stdout.write(chunk);
      out?.write(chunk);
    }),
    process.stderr.forEach(stderr.add),
  ];
  var code = await process.exitCode;
  await Future.wait(done);
  if (code != 0) _fail('${p.basename(exe)} ${args.join(' ')} exited $code');
}

/// Anchored on this script rather than on cwd, like the other tools here.
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

Never _fail(String message) {
  stderr.writeln('install_check: $message');
  exit(1);
}
