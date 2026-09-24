import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/publish/check_release.dart' show changelogProblem;
import '../tool/release.dart';

/// The two tools a release goes through, run against the files they edit.
///
/// Both run once per release, which is exactly how a tool rots: the pubspec
/// grows a comment, the constant moves, and the first to notice is the person
/// releasing. Reading the real files here makes that a red build instead.
void main() {
  String read(String path) =>
      File(p.joinAll([Directory.current.path, ...path.split('/')]))
          .readAsStringSync();

  group('tool/release.dart finds every version it moves', () {
    test('the package', () {
      var bumped = withPackageVersion(read('pubspec.yaml'), '9.8.7');
      expect(bumped, contains('\nversion: 9.8.7 '));
    });

    test('the app, with the next build number', () {
      var app = read('app/pubspec.yaml');
      var build = int.parse(
        RegExp(
          r'^version: \S+\+(\d+)',
          multiLine: true,
        ).firstMatch(app)!.group(1)!,
      );
      expect(
        withAppVersion(app, '9.8.7'),
        contains('\nversion: 9.8.7+${build + 1}'),
      );
    });

    test('the constant', () {
      expect(
        withVersionConstant(read('lib/src/constants.dart'), '9.8.7'),
        contains("const flutterwareVersion = '9.8.7';"),
      );
    });

    test("the demo's constraint", () {
      expect(
        withDemoConstraint(read('examples/brewline/pubspec.yaml'), '9.8.7'),
        contains('\n  flutterware: ^9.8.7\n'),
      );
    });

    test('the changelog gets one empty entry, once', () {
      var once = withChangelogEntry('## 0.6.0\n\n- A.\n', '0.6.1');
      expect(once, '## 0.6.1\n\n## 0.6.0\n\n- A.\n');
      expect(withChangelogEntry(once, '0.6.1'), once);
    });
  });

  group('the release refuses a changelog that', () {
    test('does not start with the version', () {
      expect(
        changelogProblem('## 0.6.0\n\n- A.\n', '0.6.1'),
        contains('does not start with "## 0.6.1"'),
      );
    });

    test('has an empty entry for it', () {
      expect(
        changelogProblem('## 0.6.1\n\n## 0.6.0\n\n- A.\n', '0.6.1'),
        contains('is empty'),
      );
    });

    test('and takes one that says something', () {
      expect(changelogProblem('## 0.6.1\n\n- B.\n\n## 0.6.0\n', '0.6.1'), null);
    });

    test('including the one in this repository', () {
      var version = RegExp(
        r'^version: (\S+)',
        multiLine: true,
      ).firstMatch(read('pubspec.yaml'))!.group(1)!;
      expect(changelogProblem(read('CHANGELOG.md'), version), null);
    });
  });
}
