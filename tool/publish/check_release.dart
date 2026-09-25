/// What the release workflow checks before anything leaves: the tag names the
/// version master is at, and the changelog says what that version is.
///
/// ```sh
/// fvm dart tool/publish/check_release.dart v0.6.1
/// ```
///
/// Both are cheap, and both catch a mistake nobody can fix afterwards: a
/// published version is permanent, and so is the changelog pub.dev shows for
/// it.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

void main(List<String> args) {
  var tag = args.isEmpty ? '' : args.first.split('/').last;
  var tagVersion = tag.startsWith('v') ? tag.substring(1) : tag;
  var pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  var version = pubspec['version'] as String;

  var mismatch =
      'pubspec.yaml says $version and the tag says "$tag". Create the '
      'release as v$version, or bump master first with '
      '`fvm dart tool/release.dart <version>`.';
  var problems = [
    if (tagVersion != version) mismatch,
    ?changelogProblem(File('CHANGELOG.md').readAsStringSync(), version),
  ];
  for (var problem in problems) {
    stderr.writeln('::error::$problem');
  }
  if (problems.isNotEmpty) exit(1);
  stdout.writeln('Releasing $version.');
}

/// Why [changelog] cannot ship [version], or null when it can: its first
/// entry has to be that version's, and say something.
String? changelogProblem(String changelog, String version) {
  var headings = RegExp(r'^## (.*)$', multiLine: true).allMatches(changelog);
  var first = headings.firstOrNull;
  if (first == null || first.group(1)!.trim() != version) {
    return 'CHANGELOG.md does not start with "## $version".';
  }
  var end = headings.elementAtOrNull(1)?.start ?? changelog.length;
  if (changelog.substring(first.end, end).trim().isEmpty) {
    return 'The "## $version" entry in CHANGELOG.md is empty.';
  }
  return null;
}
