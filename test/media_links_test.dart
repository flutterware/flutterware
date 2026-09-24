import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/media.dart'
    show documents, mediaBase, mediaLink, mediaUrl, pubspecVersion;
import '../tool/screenshots.dart' show pictureNames;

/// The README and the guides link their pictures to the `media` branch, by
/// version — see `tool/media.dart` for why. Three ways that goes wrong
/// quietly, each of which shows on pub.dev as a broken image on a page that
/// can no longer be changed.
void main() {
  var root = Directory.current.path;
  var version = pubspecVersion(root);
  var files = documents(root);

  final image = RegExp(r'!\[[^\]]*\]\(([^)\s]+)');

  test('every picture is an absolute https URL', () {
    var relative = [
      for (var file in files)
        for (var m in image.allMatches(file.readAsStringSync()))
          if (!m.group(1)!.startsWith('https://'))
            '${p.relative(file.path, from: root)}: ${m.group(1)}',
    ];
    expect(
      relative,
      isEmpty,
      reason:
          'pub.dev resolves a relative image against master, never the tag, '
          'and drops it on versions it no longer analyses. Publish the picture '
          'with tool/screenshots.dart and link it as $mediaBase/v<version>/…',
    );
  });

  test('every picture names the version being published', () {
    var stale = [
      for (var file in files)
        for (var m in mediaLink.allMatches(file.readAsStringSync()))
          if (m.group(1) != version)
            '${p.relative(file.path, from: root)}: ${m.group(0)}',
    ];
    expect(
      stale,
      isEmpty,
      reason:
          'pubspec.yaml says $version. Run `fvm dart tool/media.dart links` '
          'to point every picture at ${mediaUrl(version, '<name>')}.',
    );
  });

  test(
    'every picture linked is one the script makes, and every one is used',
    () {
      var linked = {
        for (var file in files)
          for (var m in mediaLink.allMatches(file.readAsStringSync()))
            m.group(2)!,
      };
      expect(
        linked.difference(pictureNames.toSet()),
        isEmpty,
        reason:
            'linked, but tool/screenshots.dart makes no picture by that name',
      );
      expect(
        pictureNames.toSet().difference(linked),
        isEmpty,
        reason:
            'made by tool/screenshots.dart and linked from nowhere: drop it '
            'from the script, or show it',
      );
    },
  );
}
