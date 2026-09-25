/// Where the README's and the guides' pictures live, and the three things done
/// to them.
///
/// ```sh
/// fvm dart tool/media.dart links              # point every picture at this version
/// fvm dart tool/media.dart publish [--dry-run] [--force]
/// fvm dart tool/media.dart check              # every picture link answers
/// ```
///
/// **The pictures are not on master.** They are on the orphan `media` branch,
/// one folder per release — `media/v0.6.0/hero.webp` — and `README.md` and
/// `doc/*.md` link to them by absolute URL, [mediaBase] and the pubspec's
/// version. Three facts about pub.dev decide that, all read from its source:
///
/// * A *relative* image is resolved against the repository's default branch,
///   never the tag, so a published version's page shows whatever master holds
///   today — and once pub.dev stops analysing an old version, which it does
///   for all but the latest few, its relative images render as their alt text.
///   An absolute URL is served as written, on every version, for ever.
/// * `doc/` ships in the archive, and pub.dev never shows a file from it. The
///   pictures were most of the archive's weight for nothing.
/// * A branch holding only pictures leaves master's history free of binaries
///   that are replaced whenever a panel moves.
///
/// A version's folder is **frozen once pub.dev has that version**: `publish`
/// refuses to touch it, so the page of a release keeps the pictures it shipped
/// with. Until then every push to master may refresh it, which is what keeps
/// the README on GitHub showing the current studio between releases.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'screenshots.dart' show mediaDirectory, pictureNames;

/// The branch the pictures are pushed to.
const mediaBranch = 'media';

/// Every picture URL starts with this, then `v<version>/<name>.webp`.
const mediaBase =
    'https://raw.githubusercontent.com/flutterware/flutterware/$mediaBranch';

/// The URL of picture [name] for [version].
String mediaUrl(String version, String name) =>
    '$mediaBase/v$version/$name.webp';

/// A link to a picture on the media branch, whatever version it names.
final mediaLink = RegExp(
  RegExp.escape(mediaBase) + r'/v([^/\s)]+)/([A-Za-z0-9_-]+)\.webp',
);

Future<void> main(List<String> arguments) async {
  var root = _repoRoot();
  var version = pubspecVersion(root);
  switch (arguments.firstOrNull) {
    case 'links':
      relinkPictures(root, version);
    case 'publish':
      await _publish(
        root,
        version,
        dryRun: arguments.contains('--dry-run'),
        force: arguments.contains('--force'),
      );
    case 'check':
      await _check(root, version);
    default:
      stderr.writeln(
        'usage: media.dart links | publish [--dry-run] [--force] '
        '| check',
      );
      exit(64);
  }
}

/// The markdown files whose pictures are on the media branch.
List<File> documents(String root) => [
  File(p.join(root, 'README.md')),
  ...Directory(p.join(root, 'doc'))
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path)),
];

String pubspecVersion(String root) {
  var match = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(File(p.join(root, 'pubspec.yaml')).readAsStringSync());
  if (match == null) throw StateError('no version: in pubspec.yaml');
  return match.group(1)!;
}

/// Rewrites every picture link to name [version]: the step after a version
/// bump, which `test/media_links_test.dart` asks for.
void relinkPictures(String root, String version) {
  for (var file in documents(root)) {
    var before = file.readAsStringSync();
    var after = before.replaceAllMapped(
      mediaLink,
      (m) => mediaUrl(version, m.group(2)!),
    );
    if (after != before) {
      file.writeAsStringSync(after);
      stdout.writeln('  ${p.relative(file.path, from: root)}');
    }
  }
}

/// Puts what `tool/screenshots.dart` wrote into `media/v<version>/`, and
/// pushes it.
///
/// The folder is replaced rather than added to, so a picture nothing makes
/// any more is gone from the next version rather than served for ever. A run
/// that changes no byte makes no commit.
Future<void> _publish(
  String root,
  String version, {
  required bool dryRun,
  required bool force,
}) async {
  if (!force && await _published(version)) {
    stdout.writeln(
      'v$version is on pub.dev, so its pictures are frozen. Bump the version '
      'to publish new ones.',
    );
    return;
  }
  var source = Directory(p.join(root, mediaDirectory));
  var pictures = [
    for (var name in pictureNames) File(p.join(source.path, '$name.webp')),
  ];
  var missing = [
    for (var picture in pictures)
      if (!picture.existsSync()) p.basename(picture.path),
  ];
  if (missing.isNotEmpty) {
    stderr.writeln(
      'Missing from $mediaDirectory: ${missing.join(', ')}.\n'
      'Run `fvm dart tool/screenshots.dart` first.',
    );
    exit(1);
  }

  var tree = p.join(root, 'build', 'media_branch');
  await _git(root, ['worktree', 'remove', '--force', tree], check: false);
  if (Directory(tree).existsSync()) Directory(tree).deleteSync(recursive: true);
  var fetched = await _git(root, [
    'fetch',
    'origin',
    '$mediaBranch:refs/remotes/origin/$mediaBranch',
  ], check: false);
  if (fetched) {
    await _git(root, [
      'worktree',
      'add',
      '--detach',
      tree,
      'origin/$mediaBranch',
    ]);
  } else {
    // The first publish: a branch with no history of master's in it.
    stdout.writeln('No $mediaBranch branch on origin yet: starting one.');
    await _git(root, ['worktree', 'add', '--orphan', '-b', mediaBranch, tree]);
  }
  try {
    var folder = Directory(p.join(tree, 'v$version'));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    folder.createSync(recursive: true);
    for (var picture in pictures) {
      picture.copySync(p.join(folder.path, p.basename(picture.path)));
    }
    File(p.join(tree, 'README.md')).writeAsStringSync(_branchReadme);

    await _git(tree, ['add', '-A']);
    var staged = await Process.run('git', [
      'diff',
      '--cached',
      '--quiet',
    ], workingDirectory: tree);
    if (staged.exitCode == 0) {
      stdout.writeln('media/v$version is already these pictures.');
      return;
    }
    var head = await _output(root, ['rev-parse', '--short', 'HEAD']);
    await _git(tree, [
      'commit',
      '-q',
      '-m',
      'Pictures for v$version, from $head',
    ]);
    if (dryRun) {
      stdout.writeln(
        'Committed media/v$version in $tree; not pushed (--dry-run).',
      );
      return;
    }
    await _git(tree, ['push', 'origin', 'HEAD:refs/heads/$mediaBranch']);
    stdout.writeln('Pushed media/v$version (${pictures.length} pictures).');
  } finally {
    if (!dryRun) {
      await _git(root, ['worktree', 'remove', '--force', tree], check: false);
    }
  }
}

const _branchReadme = '''# Pictures

The screenshots `README.md` and `doc/` link to, one folder per version. Made by
`tool/screenshots.dart` and pushed by `tool/media.dart` from CI; a version's
folder stops changing once that version is on pub.dev. Nothing here is edited
by hand.
''';

/// Whether pub.dev has [version] of the package.
Future<bool> _published(String version) async {
  var client = HttpClient();
  try {
    var request = await client.getUrl(
      Uri.parse('https://pub.dev/api/packages/flutterware/versions/$version'),
    );
    var response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200;
  } finally {
    client.close();
  }
}

/// Asks for every picture the documents link to, and fails on any that is
/// not there — the last thing before `pub publish`, whose page would otherwise
/// ship with a broken image nobody can change.
///
/// Retried, because a file pushed a minute ago may not have reached every
/// edge of the CDN yet.
Future<void> _check(String root, String version) async {
  var urls = <String>{
    for (var file in documents(root))
      for (var m in mediaLink.allMatches(file.readAsStringSync())) m.group(0)!,
  };
  var client = HttpClient();
  var broken = <String>[];
  try {
    for (var url in urls) {
      var ok = false;
      for (var attempt = 0; attempt < 6 && !ok; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        var request = await client.headUrl(Uri.parse(url));
        var response = await request.close();
        await response.drain<void>();
        ok =
            response.statusCode == 200 &&
            (response.headers.contentType?.mimeType == 'image/webp');
      }
      stdout.writeln('  ${ok ? 'ok  ' : 'FAIL'}  $url');
      if (!ok) broken.add(url);
    }
  } finally {
    client.close();
  }
  if (broken.isNotEmpty) {
    stderr.writeln(
      '${broken.length} of ${urls.length} pictures do not answer.',
    );
    exit(1);
  }
  stdout.writeln('All ${urls.length} pictures answer for v$version.');
}

Future<bool> _git(
  String cwd,
  List<String> arguments, {
  bool check = true,
}) async {
  var result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0 && check) {
    stderr
      ..writeln('git ${arguments.join(' ')} failed in $cwd:')
      ..writeln(result.stderr);
    exit(1);
  }
  return result.exitCode == 0;
}

Future<String> _output(String cwd, List<String> arguments) async {
  var result = await Process.run('git', arguments, workingDirectory: cwd);
  return '${result.stdout}'.trim();
}

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
