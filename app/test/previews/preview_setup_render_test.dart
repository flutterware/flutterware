@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/catalog_render.dart';
import 'package:flutterware_app/src/previews/preview_setup.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';
import 'package:flutterware_app/src/previews/tester_renderer.dart';
import 'package:path/path.dart' as p;

/// End-to-end: a package's declared setup, on a real `flutter_tester`.
///
/// The entry reads back a global only the setup writes, so what it draws says
/// whether the setup had run — and finished — before it was built. Declared
/// here rather than in the fixture's config, which would put the setup under
/// every other test that renders the fixture.
void main() {
  var packageRoot = p.join(
    Directory.current.parent.path,
    'fixtures',
    'probe_app',
  );

  /// A runner in a directory of its own, disposed and released after the test.
  PreviewTestRunner runnerFor(
    List<CatalogEntry> entries, {
    required PreviewSetup setup,
  }) {
    var flutterRoot = Platform.environment['FLUTTER_ROOT'];
    expect(
      flutterRoot,
      isNotNull,
      reason: 'flutter test always sets FLUTTER_ROOT',
    );
    var buildDirectory = claimBuildDirectory(
      packageRoot,
      root: comparisonBuildRoot,
    );
    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterRoot!,
      read: () => (entries: entries, canvases: const []),
      buildDirectory: buildDirectory,
      setup: setup,
    );
    addTearDown(() async {
      await runner.dispose();
      releaseBuildDirectory(
        packageRoot,
        buildDirectory,
        root: comparisonBuildRoot,
      );
    });
    return runner;
  }

  test('the setup has run before the first entry builds', () async {
    const probe = CatalogEntry(
      path: 'demo/src/setup_probe.dart',
      symbol: 'setupProbe',
      annotation: "Preview(name: 'Setup probe')",
      name: 'Setup probe',
    );
    var runner = runnerFor([
      probe,
    ], setup: const PreviewSetup('demo/src/setup_probe.dart'));

    var rendered = await TesterRenderer(runner: runner)
        .render(CatalogRender(entryId: probe.id, wantTree: true));
    var said = [for (var node in rendered.tree!.nodes) ?node.description]
        .join(' ');
    expect(said, contains('configured by previewSetup'));
    expect(rendered.errors.errors, isEmpty);
  });

  test('a setup that throws refuses every render, with its reason', () async {
    // Never skipped: every entry would render without what the setup
    // installs, and plausibly.
    const probe = CatalogEntry(
      path: 'demo/src/setup_probe.dart',
      symbol: 'setupProbe',
      annotation: "Preview(name: 'Setup probe')",
      name: 'Setup probe',
    );
    var runner = runnerFor([
      probe,
    ], setup: const PreviewSetup('demo/src/failing_setup.dart'));

    await expectLater(
      TesterRenderer(runner: runner).render(CatalogRender(entryId: probe.id)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('previewSetup() threw'),
            contains('no font is bundled'),
          ),
        ),
      ),
    );
    await expectLater(
      runner.audit(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('previewSetup() threw'),
        ),
      ),
    );
  });

  test(
    'a setup that is not there is refused before anything compiles',
    () async {
      var runner = runnerFor(
        const [],
        setup: const PreviewSetup('lib/preview_setup.dart'),
      );
      await expectLater(
        runner.render(entryId: 'demo/any.dart#any', request: const {}),
        throwsA(
          isA<PreviewSetupProblem>().having(
            (e) => e.message,
            'message',
            contains('does not exist'),
          ),
        ),
      );
    },
  );
}
