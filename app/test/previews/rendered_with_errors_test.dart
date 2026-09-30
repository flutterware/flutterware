@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_render.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/previews/error_location.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';
import 'package:flutterware_app/src/previews/tester_renderer.dart';
import 'package:path/path.dart' as p;

/// End-to-end: an entry that renders and *then* fails, and one that fails
/// before anything renders, on a real `flutter_tester`.
///
/// The first is the shape of a font package that starts a download from a
/// text style getter and rethrows when `flutter_test` answers it with 400.
/// Its screenshot used to come back as `did not render` with no picture, while
/// `inspect` of the same entry could call it clean — two wrong answers about
/// one frame. The second is what `did not render` is still for.
///
/// The entries are declared here rather than annotated in the fixture: the CI
/// audit of `fixtures/probe_app` fails on anything wrong, and these are wrong
/// on purpose.
void main() {
  test('a frame comes back with its errors; only no frame refuses', () async {
    var flutterRoot = Platform.environment['FLUTTER_ROOT'];
    expect(
      flutterRoot,
      isNotNull,
      reason: 'flutter test always sets FLUTTER_ROOT',
    );
    var repoRoot = Directory.current.parent.path;
    var packageRoot = p.join(repoRoot, 'fixtures', 'probe_app');
    const file = 'demo/src/error_probes.dart';
    const lateError = CatalogEntry(
      path: file,
      symbol: 'lateError',
      annotation: "Preview(name: 'Late error')",
      name: 'Late error',
    );
    const themed = CatalogEntry(
      path: file,
      symbol: 'themed',
      annotation: "Preview(name: 'Themed', wrapper: brokenTheme)",
      name: 'Themed',
    );
    var probes = File(p.join(packageRoot, file)).readAsLinesSync();
    int lineOf(String text) => probes.indexWhere((l) => l.contains(text)) + 1;
    // The project's own file, worktree-relative, on the line that threw —
    // not the harness that ran it, and not the wrapper flutterware generated.
    var thrownLate = 'fixtures/probe_app/$file:${lineOf('throw Exception(')}:';
    var thrownByTheme =
        'fixtures/probe_app/$file:${lineOf('throw StateError')}';
    var locator = ErrorLocator.forPackage(packageRoot, worktree: repoRoot);

    var buildDirectory = claimBuildDirectory(
      packageRoot,
      root: comparisonBuildRoot,
    );
    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterRoot!,
      read: () => (entries: [lateError, themed], canvases: const []),
      buildDirectory: buildDirectory,
    );
    var renderer = TesterRenderer(runner: runner);
    var shots = Directory.systemTemp.createTempSync('fw_rendered_with_errors');
    try {
      // `screenshot`: the picture, and the complaint beside it.
      var captured = await renderer.capture(
        CatalogRender(
          entryId: lateError.id,
          screenshot: p.join(shots.path, 'late.png'),
        ),
      );
      var picture = img.decodePng(captured.file.readAsBytesSync())!;
      expect(picture.width, CaptureViewport.panel.width);
      expect(
        captured.errors.single.exception,
        contains('Failed to load font with url'),
      );
      expect(
        locator.locate(captured.errors.single.frames),
        startsWith(thrownLate),
      );

      // `inspect`, which asks for no picture: the settled screen is the
      // evidence it rendered, and the failure is counted, so it is not `ok`.
      var inspected = await renderer.render(
        CatalogRender(entryId: lateError.id),
      );
      expect(inspected.stagedOn, isNotNull);
      expect(inspected.errors.errors, isNotEmpty);
      expect(
        inspected.errors.errors.first.exception,
        contains('Failed to load font with url'),
      );

      // Nothing drawn is still a refusal, in the words it always had.
      await expectLater(
        renderer.render(
          CatalogRender(
            entryId: themed.id,
            screenshot: p.join(shots.path, 'themed.png'),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('did not render'), contains('theme was asked')),
          ),
        ),
      );

      // The audit reports both, each with where it was thrown. The theme's
      // is carried on the failure itself, because nothing reached the error
      // buffer to carry it.
      var rows = {for (var row in await runner.audit()) row.id: row};
      var late = rows[lateError.id]!;
      expect(late.ok, isFalse);
      expect(
        locator.locate(late.findings.single.frames),
        startsWith(thrownLate),
      );
      var broken = rows[themed.id]!;
      expect(broken.ok, isFalse);
      expect(broken.findings.single.exception, contains('theme was asked'));
      expect(
        locator.locate(broken.findings.single.frames),
        startsWith(thrownByTheme),
      );
    } finally {
      shots.deleteSync(recursive: true);
      await runner.dispose();
      releaseBuildDirectory(
        packageRoot,
        buildDirectory,
        root: comparisonBuildRoot,
      );
    }
  });
}
