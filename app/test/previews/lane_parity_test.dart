@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/previews/catalog_render.dart';
import 'package:flutterware_app/src/previews/devices.dart';
import 'package:flutterware_app/src/previews/discovery.dart';
import 'package:flutterware_app/src/previews/headless_catalog.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/previews/test_runner.dart';
import 'package:flutterware_app/src/previews/tester_renderer.dart';
import 'package:path/path.dart' as p;

// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';

/// **The two backends, asked the same question.**
///
/// The reason is a bug the last such check found:
/// the guest *audit* framed entries on `flutter_test`'s 800×600 where the
/// single-entry path gave 900×700, so one demo was reported overflowing by 576
/// pixels where it really overflowed by 476. Nothing else caught it, because
/// an audit row said which device an entry was framed as and never how wide it
/// actually came out. The check that would have caught it was deleted with
/// `captureAll`; this is its replacement.
///
/// **What is compared is the layout, not the pixels.** Two rasterizers on two
/// clocks will not agree byte for byte and are not supposed to: the guest
/// photographs whatever real instant its socket round-trip lands on. What must
/// agree is everything a caller *reasons* with — the surface the entry was
/// judged on, the boxes it laid out, and what it complained about — because
/// those are what make one lane's answer usable in place of the other's.
void main() {
  test('the guest and the harness lay the same entry out the same', () async {
    var flutterRoot = Platform.environment['FLUTTER_ROOT'];
    expect(flutterRoot, isNotNull, reason: 'flutter test always sets it');
    var repoRoot = Directory.current.parent.path;
    var packageRoot = p.join(repoRoot, 'fixtures', 'probe_app');

    var scan = CatalogScanner(projectRoot: packageRoot).scan();
    // Buttons: laid out rather than painted, which is what a layout comparison
    // can speak about — and **nothing in it focuses a field**, which is not a
    // detail. `demo/input.dart#textFields` was the first fixture and failed
    // here by 336 logical points, because it autofocuses and the guest honours
    // `KeyboardMode.auto` by raising a keyboard the way a phone does. This
    // lane cannot: it stages a keyboard before the pump, so there is nothing
    // focused yet to read a variant off, and its own comment has always said
    // so. That divergence is real and is recorded in the design; it is not
    // what this check is about, and a fixture carrying it would report it
    // every run in place of the drift the check exists to catch.
    var entry = scan.entries.singleWhere(
      (entry) => entry.id == 'demo/buttons.dart#buttons',
    );

    var buildDirectory = claimBuildDirectory(
      packageRoot,
      root: comparisonBuildRoot,
    );
    var runner = PreviewTestRunner(
      packageRoot: packageRoot,
      flutterSdkRoot: flutterRoot!,
      read: () => (entries: [entry], canvases: const []),
      buildDirectory: buildDirectory,
    );
    // **Both surfaces, because they fail differently.** A phone has a ratio,
    // safe areas and a platform, and each is a way for the framing to go
    // wrong — that is where the inset bug lived. The panel's plain rectangle
    // has none of those and looked like the easy case, which is why it was
    // left out at first and why the platform divergence got past: with no
    // device named, the harness answered `android` where the guest answers
    // the machine it runs on, and a `FilledButton` was 48 points tall instead
    // of 40.
    var surfaces = {
      'iPhone 16': CaptureViewport.of(deviceById('iphone-16')!),
      'the panel rectangle': CaptureViewport.panel,
    };

    try {
      for (var MapEntry(key: what, value: viewport) in surfaces.entries) {
        var request = CatalogRender(
          entryId: entry.id,
          viewport: viewport,
          wantTree: true,
        );
        var harness = await TesterRenderer(runner: runner).render(request);
        var guest = await HeadlessCatalog(
          dartExecutable: p.join(flutterRoot, 'bin', 'dart'),
          config: DaemonConfig.forPackage(
            appToolDirectory: p.join(repoRoot, 'app'),
            packageRoot: packageRoot,
            flutterSdkRoot: flutterRoot,
            roots: const ['demo'],
          ),
        ).render(request);

        // The surface first: everything below is only meaningful if both lanes
        // judged the entry on the same screen.
        expect(harness.stagedOn!.width, request.viewport.width);
        expect(harness.stagedOn!.height, request.viewport.height);
        expect(harness.stagedOn!.pixelRatio, request.viewport.pixelRatio);

        var byId = {for (var node in guest.tree!.nodes) node.id: node};
        expect(byId, isNotEmpty, reason: 'the guest rendered something');

        var compared = 0;
        for (var node in harness.tree!.nodes) {
          if (byId[node.id] case var twin?) {
            expect(
              node.type,
              twin.type,
              reason: 'on $what the lanes disagree about what ${node.id} is',
            );
            if ((node.layout, twin.layout) case (var mine?, var theirs?)) {
              compared++;
              expect(
                [mine.x, mine.y, mine.width, mine.height],
                [theirs.x, theirs.y, theirs.width, theirs.height],
                reason:
                    'on $what, ${node.type} (${node.id}) is laid out '
                    'differently: the harness says ${_box(mine)} and the guest '
                    '${_box(theirs)}',
              );
            }
          }
        }
        // Not an assertion about *how many* — a tree is filtered differently
        // nowhere, but a run that compared three boxes and passed would be
        // reporting on nothing.
        expect(
          compared,
          greaterThan(10),
          reason: 'a parity check that compares nothing passes trivially',
        );

        // And what each complained about. `flutter_test` answers every HTTP
        // request with 400, so a network failure is the lane talking about
        // itself rather than about the entry — the audit sets those aside for
        // the same reason.
        String indicting(CatalogObservation observed) => [
          for (var error in observed.errors.errors)
            if (!error.network) error.exception,
        ].join('\n');
        expect(indicting(harness), indicting(guest), reason: 'on $what');
      }
    } finally {
      await runner.dispose();
      releaseBuildDirectory(
        packageRoot,
        buildDirectory,
        root: comparisonBuildRoot,
      );
    }
  });
}

String _box(InspectLayout rect) =>
    '${rect.x},${rect.y} ${rect.width}×${rect.height}';
