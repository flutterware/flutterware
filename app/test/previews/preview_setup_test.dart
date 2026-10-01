import 'dart:io';

import 'package:flutterware_app/src/previews/preview_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A declared setup is checked before any program imports it, and refused in
/// words: left to the compiler, a missing file or function fails inside
/// generated code and blames no entry.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fw_preview_setup'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String relative, String content) =>
      File(p.join(root.path, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);

  String? problem(String path) => PreviewSetup(path).problemIn(root.path);

  test('a file that declares it is fine, async or not', () {
    write('lib/preview_setup.dart', 'Future<void> previewSetup() async {}');
    write('lib/sync_setup.dart', 'void previewSetup() {}');
    write('lib/optional.dart', 'void previewSetup([int tries = 1]) {}');

    expect(problem('lib/preview_setup.dart'), isNull);
    expect(problem('lib/sync_setup.dart'), isNull);
    expect(problem('lib/optional.dart'), isNull);
  });

  test('a file that is not there is named, with what to write', () {
    expect(
      problem('lib/preview_setup.dart'),
      allOf(contains('lib/preview_setup.dart'), contains('does not exist')),
    );
    expect(
      () => PreviewSetup('lib/preview_setup.dart').check(root.path),
      throwsA(
        isA<PreviewSetupProblem>().having(
          (e) => '$e',
          'printed',
          startsWith('The preview setup `lib/preview_setup.dart`'),
        ),
      ),
    );
  });

  test('a file without the function says which function', () {
    write('lib/preview_setup.dart', 'Future<void> setUpPreviews() async {}');
    expect(
      problem('lib/preview_setup.dart'),
      allOf(contains('declares no top-level'), contains('previewSetup()')),
    );
  });

  test('one that cannot be called with nothing is refused', () {
    write('lib/needs.dart', 'void previewSetup(String flavor) {}');
    write('lib/getter.dart', 'int get previewSetup => 1;');

    expect(problem('lib/needs.dart'), contains('no arguments'));
    expect(problem('lib/getter.dart'), contains('no arguments'));
  });

  test('a path outside the package is refused, not followed', () {
    expect(problem('../elsewhere.dart'), contains('not inside the package'));
    expect(problem('/abs/setup.dart'), contains('not inside the package'));
  });
}
