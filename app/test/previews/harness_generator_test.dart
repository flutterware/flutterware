import 'dart:io';

import 'package:flutterware/devices.dart';
import 'package:flutterware_app/src/previews/catalog_entry.dart';
import 'package:flutterware_app/src/previews/harness_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/generated_source.dart';

void main() {
  late Directory root;

  const members = CatalogEntry(
    path: 'demo/team/avatar_tile.dart',
    symbol: 'avatarTileMembers',
    name: 'Members',
    annotation: "Preview(name: 'Members')",
  );
  const wide = CatalogEntry(
    path: 'demo/desktop/table.dart',
    symbol: 'tableWide',
    name: 'Wide',
    annotation: "Preview(name: 'Wide')",
  );
  // Everything a display name is allowed to carry and a raw string cannot: the
  // delimiter itself, the other delimiter, and a `$` that an escaped literal
  // would otherwise read as interpolation.
  const awkward = CatalogEntry(
    path: 'demo/shop/whats_new.dart',
    symbol: 'whatsNewSheet',
    name: 'What\'s "new" — \$5',
    annotation: 'Preview(name: \'What\\\'s "new" — \\\$5\')',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_preview_harness_test');
    for (var entry in [members, wide, awkward]) {
      var file = File(p.join(root.path, entry.path))
        ..parent.createSync(recursive: true);
      file.writeAsStringSync('''
import 'package:material_ui/material_ui.dart';

Widget ${entry.symbol}() => const Placeholder();
''');
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  String harness() =>
      File(p.join(root.path, previewHarnessPath)).readAsStringSync();
  File wrapper(int index) =>
      File(p.join(root.path, previewWrapperDir, 'entry_$index.dart'));

  test('declares every entry, with the path a canvas is matched on', () {
    writePreviewHarness(root.path, [members, wide], canvases: const []);

    expect(
      generatedArguments(harness(), 'id'),
      containsAll([
        'demo/desktop/table.dart#tableWide',
        'demo/team/avatar_tile.dart#avatarTileMembers',
      ]),
    );
    expect(
      generatedArguments(harness(), 'path'),
      contains('demo/desktop/table.dart'),
    );
    // The wrapper is applied inside the thunk, so it runs in the test body
    // under the entry's own canvas rather than at table construction.
    expect(harness(), contains('build: () => _build(fw0.fwPreview'));
  });

  test('emits canvases by device id, never as literal geometry', () {
    // The harness compiles against the *project's* flutterware, whose device
    // table may not be this build's. An id resolves there; a width resolved
    // here would be this build's opinion baked into their program.
    writePreviewHarness(
      root.path,
      [members],
      canvases: [
        const PreviewCanvas('demo', devices: [Devices.iphoneSe]),
        const PreviewCanvas(
          'demo/desktop',
          devices: [Devices.wideWindow],
          orientations: [ScreenOrientation.landscape],
        ),
      ],
    );

    expect(harness(), contains("PreviewCanvas('demo', devices: ["));
    expect(harness(), contains("?deviceById('iphone-se')"));
    expect(harness(), contains("?orientationById('landscape')"));
    expect(
      harness(),
      isNot(contains('${Devices.iphoneSe.width}')),
      reason: 'geometry belongs to the table the harness resolves against',
    );
  });

  test('indices follow sorted ids, so an unchanged catalog is unchanged', () {
    writePreviewHarness(root.path, [members, wide], canvases: const []);
    var first = harness();
    var wrapperSource = wrapper(0).readAsStringSync();

    // Declared the other way round: the order a caller happens to hold them in
    // must not renumber wrappers, or every entry recompiles for nothing.
    writePreviewHarness(root.path, [wide, members], canvases: const []);

    expect(harness(), first);
    expect(wrapper(0).readAsStringSync(), wrapperSource);
  });

  test('leaves files alone when their content is already right', () {
    // A rewritten file is a moved mtime, and a moved mtime is what
    // `SourceInvalidator` reads as an edit — so this is what keeps a warm sync
    // from recompiling the whole catalog every time it looks.
    writePreviewHarness(root.path, [members, wide], canvases: const []);
    var harnessFile = File(p.join(root.path, previewHarnessPath));
    var before = (
      harnessFile.lastModifiedSync(),
      wrapper(0).lastModifiedSync(),
    );

    writePreviewHarness(root.path, [members, wide], canvases: const []);

    expect((
      harnessFile.lastModifiedSync(),
      wrapper(0).lastModifiedSync(),
    ), before);
  });

  test('an entry that went away takes its wrapper with it', () {
    writePreviewHarness(root.path, [members, wide], canvases: const []);
    expect(wrapper(1).existsSync(), isTrue);

    writePreviewHarness(root.path, [members], canvases: const []);

    expect(wrapper(0).existsSync(), isTrue);
    expect(
      wrapper(1).existsSync(),
      isFalse,
      reason: 'an unimported wrapper is still a file the invalidator watches',
    );
  });

  test('one apostrophe in one name does not take the catalog down', () {
    // The harness is one file for the whole package, so a name that closes its
    // own literal is not one broken entry — it is a catalog that does not
    // compile, reported as nine errors in a file under `build/` naming an
    // undefined `s`. `previews audit` is the surface that claims to have
    // checked everything, so it is the worst one to lose to punctuation.
    writePreviewHarness(root.path, [
      members,
      wide,
      awkward,
    ], canvases: const []);

    expect(() => parseGenerated(harness()), returnsNormally);
    expect(
      generatedArguments(harness(), 'name'),
      containsAll(['Members', 'Wide', awkward.name]),
      reason: 'the name reaches the program as the human wrote it',
    );
  });

  test('a canvas root a human typed is escaped too', () {
    // A canvas is rooted at a directory, and a directory is named by whoever
    // made it. Same literal, same one-character failure.
    writePreviewHarness(
      root.path,
      [members],
      canvases: [const PreviewCanvas("demo/xavier's")],
    );

    expect(() => parseGenerated(harness()), returnsNormally);
    expect(generatedStrings(harness()), contains("demo/xavier's"));
  });

  test('says how to run it without flutterware, and what that costs', () {
    writePreviewHarness(root.path, [members], canvases: const []);
    expect(harness(), contains('flutter test $previewHarnessPath'));
    expect(harness(), contains('--use-test-fonts'));
  });

  test('two directories are two harnesses that never touch each other', () {
    // The comparison generates a *subset* harness on the same package the
    // panel's warm runner holds the full catalog on. Indices are assigned
    // within each list, so in one shared directory the subset would renumber
    // — and prune — the full harness's wrappers under the warm compiler.
    writePreviewHarness(root.path, [members, wide], canvases: const []);
    var full = harness();
    var fullWrapper = wrapper(0).readAsStringSync();

    const claimed = 'build/flutterware/comparison/123-0';
    var path = writePreviewHarness(
      root.path,
      [wide],
      canvases: const [],
      directory: claimed,
    );

    expect(p.isWithin(p.join(root.path, claimed), path), isTrue);
    expect(File(path).existsSync(), isTrue);
    expect(
      File(path).readAsStringSync(),
      contains('flutter test $claimed/previews_harness.dart'),
    );
    expect(harness(), full);
    expect(wrapper(0).readAsStringSync(), fullWrapper);
    expect(
      wrapper(1).existsSync(),
      isTrue,
      reason: "the subset's prune only reaches its own wrapper directory",
    );
  });
}
