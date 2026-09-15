@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/previews_side.dart';
import 'package:flutterware_app/src/previews/authoring.dart';

/// A side that compiled and rendered, and whose picture could not be filed,
/// did not fail to compile. Reported as one, a CI runner with a full disk read
/// "the base checkout does not compile" and sent its reader to the base
/// branch's code.
///
/// End-to-end over `fixtures/probe_app`, because the wrapping happens around
/// the real capture loop: a cold harness compile, one entry.
void main() {
  test('a frame the caller cannot file reaches it as itself', () async {
    // app/ → the repo root, which holds the fixture as a package.
    var checkout = Directory.current.parent.path;
    var side = PreviewsSide(
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      packagePath: 'fixtures/probe_app',
      root: defaultCatalogRoot,
      previewAnnotations: defaultPreviewAnnotations,
      canvases: const [],
    );
    var full = const FileSystemException(
      'writeFrom failed',
      'shots/09/4a/094a.part',
      OSError('No space left on device', 28),
    );

    await expectLater(
      side.render(
        checkout: checkout,
        entryIds: const ['demo/buttons.dart#buttons'],
        onFrame: (frame) async => throw full,
      ),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.osError?.errorCode,
          'errno',
          28,
        ),
      ),
    );
  });
}
