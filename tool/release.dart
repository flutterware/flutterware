/// Prepares a release: moves the version everywhere it is written and opens
/// its changelog entry.
///
/// ```sh
/// fvm dart tool/release.dart 0.6.1
/// ```
///
/// Merge that as an ordinary PR, with the changelog entry written. Publishing
/// is then one action — a GitHub release tagged `v0.6.1` — and
/// `.github/workflows/publish-on-pub.yaml` does the rest.
///
/// What moves, and why each has to:
///
/// * `pubspec.yaml` — what pub publishes;
/// * `app/pubspec.yaml` — the same release, with the next build number;
/// * `flutterwareVersion` in `lib/src/constants.dart` — what `fw --version`
///   prints, compiled in;
/// * the picture links in `README.md` and `doc/` — `media/v<version>/`, the
///   folder the release renders;
/// * the demo's `flutterware:` constraint — `^<version>`, so a clone resolves
///   the release its code was written against;
/// * `render/pubspec.yaml` — flutterware_render, published from the same tag,
///   and its `flutterware:` constraint, which allows only this release.
///
/// `CHANGELOG.md` gets an empty `## <version>`. The release refuses an empty
/// entry, so it is written in the PR rather than remembered afterwards.
/// `render/CHANGELOG.md` gets an entry that points at it.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'media.dart' show pubspecVersion, relinkPictures;

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: fvm dart tool/release.dart <version>');
    exit(64);
  }
  var root = p.dirname(p.dirname(Platform.script.toFilePath()));
  var current = Version.parse(pubspecVersion(root));
  Version next;
  try {
    next = Version.parse(args.single);
  } on FormatException {
    stderr.writeln('release: "${args.single}" is not a version');
    exit(64);
  }
  if (next <= current) {
    stderr.writeln('release: $next is not after the current $current');
    exit(64);
  }
  var version = '$next';

  void edit(String path, String Function(String) change) {
    var file = File(p.join(root, path));
    file.writeAsStringSync(change(file.readAsStringSync()));
    stdout.writeln('  $path');
  }

  edit('pubspec.yaml', (s) => withPackageVersion(s, version));
  edit(p.join('app', 'pubspec.yaml'), (s) => withAppVersion(s, version));
  edit(
    p.join('lib', 'src', 'constants.dart'),
    (s) => withVersionConstant(s, version),
  );
  edit(
    p.join('examples', 'brewline', 'pubspec.yaml'),
    (s) => withDemoConstraint(s, version),
  );
  edit(
    p.join('render', 'pubspec.yaml'),
    (s) => withRenderConstraint(withPackageVersion(s, version), version),
  );
  edit('CHANGELOG.md', (s) => withChangelogEntry(s, version));
  edit(
    p.join('render', 'CHANGELOG.md'),
    (s) => withRenderChangelogEntry(s, version),
  );
  relinkPictures(root, version);

  stdout.writeln('''

$current → $version. Next:
  1. Write the entry under "## $version" in CHANGELOG.md.
  2. fvm flutter pub get, then open the PR.
  3. Once it is merged, create a GitHub release tagged v$version.''');
}

String withPackageVersion(String pubspec, String version) =>
    _replaceOnce(pubspec, RegExp(r'^version: [^\s#]+', multiLine: true), (_) {
      return 'version: $version';
    });

/// `flutterware_app` is an application, so its version carries a build
/// number; each release takes the next one.
String withAppVersion(String pubspec, String version) => _replaceOnce(
  pubspec,
  RegExp(r'^version: [^\s+#]+\+(\d+)', multiLine: true),
  (m) => 'version: $version+${int.parse(m.group(1)!) + 1}',
);

String withVersionConstant(String constants, String version) => _replaceOnce(
  constants,
  RegExp(r"^const flutterwareVersion = '[^']*';", multiLine: true),
  (_) => "const flutterwareVersion = '$version';",
);

String withDemoConstraint(String pubspec, String version) => _replaceOnce(
  pubspec,
  RegExp(r'^  flutterware: \^[^\s#]+', multiLine: true),
  (_) => '  flutterware: ^$version',
);

/// One release of flutterware, written as a range: pub's validator warns about
/// an exact version, and a warning fails the release's dry run.
String withRenderConstraint(String pubspec, String version) => _replaceOnce(
  pubspec,
  RegExp(r"^  flutterware: '[^'\n]*'", multiLine: true),
  (_) => "  flutterware: '>=$version <${Version.parse(version).nextPatch}'",
);

String withChangelogEntry(String changelog, String version) {
  if (changelog.startsWith('## $version\n')) return changelog;
  return '## $version\n\n$changelog';
}

/// flutterware_render ships with flutterware and has no changes of its own to
/// list, so its entry is written for it.
String withRenderChangelogEntry(String changelog, String version) {
  if (changelog.startsWith('## $version\n')) return changelog;
  return '## $version\n\n'
      'Released with flutterware $version. What changed is in its '
      '[changelog](https://pub.dev/packages/flutterware/changelog).\n\n'
      '$changelog';
}

String _replaceOnce(
  String text,
  RegExp pattern,
  String Function(Match) replace,
) {
  var matches = pattern.allMatches(text).toList();
  if (matches.length != 1) {
    throw StateError(
      'expected one match of ${pattern.pattern}, found ${matches.length}',
    );
  }
  return text.replaceRange(
    matches.single.start,
    matches.single.end,
    replace(matches.single),
  );
}
