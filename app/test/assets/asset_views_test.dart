import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/assets/detail.dart';
import 'package:flutterware_app/src/assets/list.dart';
import 'package:flutterware_app/src/assets/model/asset_catalog.dart';
import 'package:flutterware_app/src/assets/model/asset_scan.dart';
import 'package:flutterware_app/src/assets/folder.dart';
import 'package:flutterware_app/src/assets/font_face.dart';
import 'package:flutterware_app/src/assets/model/asset_tree.dart';
import 'package:flutterware_app/src/assets/popover.dart';
import 'package:flutterware_app/src/assets/preview.dart';
import 'package:flutterware_app/src/ui/matched_text.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/tree_row.dart';

/// The views, pumped with data that never came off a disk.
///
/// That is the property being asserted as much as any expectation below: an
/// `AssetFile` carries its length and a preview takes bytes, so these widgets
/// can be drawn — here, and in a catalog demo — with no project behind them.
void main() {
  AssetFile file(String key, {double? scale, int length = 400}) =>
      AssetFile(path: '/project/$key', key: key, scale: scale, length: length);

  ResolvedAsset asset(
    String key, {
    String? package,
    String? declaration,
    List<AssetFile>? files,
  }) => ResolvedAsset(
    key: key,
    package: package,
    packageRoot: '/project',
    declaration: declaration ?? key,
    files: files ?? [file(key)],
  );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 900, child: child)),
    ),
  );

  group('the list', () {
    testWidgets('shows assets, sizes and variant counts', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [
            asset(
              'assets/images/logo.png',
              files: [
                file('assets/images/logo.png', length: 663),
                file('assets/images/2.0x/logo.png', scale: 2, length: 1840),
              ],
            ),
          ],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.text('logo.png'), findsOneWidget);
      expect(
        find.text('In this package · assets/images/'),
        findsOneWidget,
        reason:
            'The directory every key shares is said once, in the header, '
            'rather than under each filename.',
      );
      expect(
        find.textContaining('2.4 kB'),
        findsNWidgets(2),
        reason:
            "The row's own size, and the header's total — the same number "
            'while the package has one asset in it.',
      );
      expect(
        find.text('1 variant'),
        findsOneWidget,
        reason: 'One variant beside the main file.',
      );
    });

    testWidgets('reports a tap as a selection', (tester) async {
      String? selected;
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/logo.png')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (key) => selected = key,
        ),
      );

      await tester.tap(find.text('logo.png'));
      expect(selected, 'assets/logo.png');
    });

    testWidgets('keeps a dependency collapsed until asked', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: const [],
          fromPackages: [
            AssetOwner(
              package: 'brand',
              assets: [
                asset('packages/brand/assets/mark.png', package: 'brand'),
              ],
            ),
          ],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.text('package:brand'), findsOneWidget);
      expect(find.text('mark.png'), findsNothing);

      await tester.tap(find.text('package:brand'));
      await tester.pump();

      expect(find.text('mark.png'), findsOneWidget);
    });

    testWidgets('filters by key', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/logo.png'), asset('assets/banner.jpg')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      await tester.enterText(find.byType(TextField), 'banner');
      await tester.pump();

      expect(find.text('banner.jpg'), findsOneWidget);
      expect(find.text('logo.png'), findsNothing);
    });

    testWidgets('lights the characters the filter matched', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/images/logo.png')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      await tester.enterText(find.byType(TextField), 'lg');
      await tester.pump();

      var name = tester.widget<Text>(
        find
            .descendant(
              of: find.byType(MatchedText),
              matching: find.byType(Text),
            )
            .first,
      );
      var spans = (name.textSpan! as TextSpan).children!.cast<TextSpan>();
      var lit = [
        for (var span in spans)
          if (span.style?.backgroundColor != null) span.text,
      ];
      expect(
        lit,
        ['l', 'g'],
        reason:
            'The subsequence that matched, not a substring — `lg` matches '
            '`logo.png` and no substring search would light anything.',
      );
    });

    testWidgets('a typed query flattens the tree back to a ranked list', (
      tester,
    ) async {
      await pump(
        tester,
        AssetListView(
          own: [
            asset('assets/images/logo.png'),
            asset('assets/i18n/en.json'),
            asset('assets/i18n/fr.json'),
          ],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.text('i18n'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'json');
      await tester.pump();

      expect(
        find.text('i18n'),
        findsNothing,
        reason: 'A ranking behind collapsed directories is no ranking.',
      );
      expect(
        find.text('assets/i18n'),
        findsNWidgets(2),
        reason: 'Flattened, each row carries its own directory again.',
      );
    });

    testWidgets('the row picks the folder and the chevron folds it', (
      tester,
    ) async {
      String? picked;
      await pump(
        tester,
        AssetListView(
          own: [
            asset('assets/images/logo.png'),
            asset('assets/images/deep/hero.png'),
            asset('assets/i18n/en.json'),
          ],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (path) => picked = path,
        ),
      );

      Finder chevron(IconData icon) => find.descendant(
        of: find
            .ancestor(of: find.text('deep'), matching: find.byType(FwTreeRow))
            .first,
        matching: find.byIcon(icon),
      );

      expect(find.text('hero.png'), findsNothing);

      await tester.tap(find.text('deep'));
      await tester.pump();
      expect(
        picked,
        'assets/images/deep',
        reason: 'A folder is a place, and the row is how you go there.',
      );
      expect(
        find.text('hero.png'),
        findsNothing,
        reason:
            'One click, one result. The row that used to fold now only picks, '
            'because doing both left no way to ask for either alone.',
      );

      picked = null;
      await tester.tap(chevron(Icons.chevron_right));
      await tester.pump();
      expect(find.text('hero.png'), findsOneWidget);
      expect(
        picked,
        isNull,
        reason: 'The chevron is its own target inside the row it sits in.',
      );

      await tester.tap(chevron(Icons.expand_more));
      await tester.pump();
      expect(find.text('hero.png'), findsNothing);
    });

    testWidgets('arriving at a folder opens it', (tester) async {
      var own = [
        asset('assets/images/logo.png'),
        asset('assets/images/deep/hero.png'),
        asset('assets/i18n/en.json'),
      ];
      Widget list(String? selected) => AssetListView(
        own: own,
        fromPackages: const [],
        problems: const [],
        selected: selected,
        onSelect: (_) {},
      );

      await pump(tester, list(null));
      expect(find.text('hero.png'), findsNothing);

      await pump(tester, list('assets/images/deep'));
      await tester.pump();

      expect(
        find.text('hero.png'),
        findsOneWidget,
        reason:
            'A pane showing a directory beside a tree that has it folded away '
            'is two answers to one question.',
      );
    });

    testWidgets('a directory carries what it holds', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [
            asset('assets/logo.png'),
            asset(
              'assets/deep/one.png',
              files: [file('assets/deep/one.png', length: 2048)],
            ),
            asset(
              'assets/deep/two.png',
              files: [file('assets/deep/two.png', length: 2048)],
            ),
          ],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      var row = find.ancestor(
        of: find.text('deep'),
        matching: find.byType(Row),
      );
      expect(find.descendant(of: row, matching: find.text('2')), findsWidgets);
      expect(
        find.descendant(of: row, matching: find.text('4.0 kB')),
        findsWidgets,
        reason: 'A closed directory still has to say what taking it costs.',
      );
    });

    testWidgets('a selection from outside opens the directories above it', (
      tester,
    ) async {
      var own = [
        asset('assets/images/logo.png'),
        asset('assets/images/deep/hero.png'),
        asset('assets/i18n/en.json'),
      ];
      Widget list(String? selected) => AssetListView(
        own: own,
        fromPackages: const [],
        problems: const [],
        selected: selected,
        onSelect: (_) {},
      );

      await pump(tester, list(null));
      expect(find.text('hero.png'), findsNothing);

      // What the address bar and the command palette do: name an asset the
      // list never asked about.
      await pump(tester, list('assets/images/deep/hero.png'));
      await tester.pump();

      expect(
        find.text('hero.png'),
        findsOneWidget,
        reason: 'A list cannot report a row as selected and then hide it.',
      );
    });

    testWidgets('an asset row answers the pointer, as a directory row does', (
      tester,
    ) async {
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/images/logo.png'), asset('assets/i18n/en.json')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      /// The wash [Tappable] paints over its child, or null when it paints
      /// none. Read rather than eyeballed because the bug it guards was
      /// invisible in a catalog demo: ink under an [InkWell] is only hidden
      /// once something opaque — the panel's own fill — is drawn over it.
      Color? washOver(String label) {
        var scope = find
            .ancestor(of: find.text(label), matching: find.byType(Tappable))
            .first;
        for (var box in tester.widgetList<DecoratedBox>(
          find.descendant(of: scope, matching: find.byType(DecoratedBox)),
        )) {
          var color = (box.decoration as BoxDecoration).color;
          if (color != null) return color;
        }
        return null;
      }

      expect(washOver('logo.png'), isNull);

      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('logo.png')));
      await tester.pump();

      expect(
        washOver('logo.png'),
        isNotNull,
        reason: 'The row under the pointer says so.',
      );
      expect(
        washOver('images'),
        isNull,
        reason: 'And only that row — the directory above it is not hovered.',
      );
    });

    testWidgets('resting on a row shows the asset beside it', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [
            asset('assets/images/logo.png'),
            asset('assets/images/hero.png'),
          ],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      await mouse.moveTo(tester.getCenter(find.text('logo.png')));
      await tester.pump();
      expect(
        find.byType(AssetPopover),
        findsNothing,
        reason: 'A row passed over did not ask a question.',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AssetPopover), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AssetPopover),
          matching: find.text('assets/images/logo.png'),
        ),
        findsOneWidget,
        reason: 'The card says which asset it is showing.',
      );

      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(find.byType(AssetPopover), findsNothing);
    });

    testWidgets('the selected row is not peeked at', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [
            asset('assets/images/logo.png'),
            asset('assets/images/hero.png'),
          ],
          fromPackages: const [],
          problems: const [],
          selected: 'assets/images/logo.png',
          onSelect: (_) {},
        ),
      );

      var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('logo.png')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(AssetPopover),
        findsNothing,
        reason:
            'Its picture is in the pane beside, full size. A second copy of it '
            'under the pointer says nothing and covers something.',
      );
    });

    testWidgets('the header is the way back to all of them', (tester) async {
      String? picked;
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/images/logo.png'), asset('assets/i18n/en.json')],
          fromPackages: const [],
          problems: const [],
          selected: 'assets/images/logo.png',
          onSelect: (path) => picked = path,
        ),
      );

      await tester.tap(find.textContaining('In this package'));
      await tester.pump();

      expect(
        picked,
        '',
        reason:
            'Empty is the package with no key after it — one address for "all "'
            'of them, rather than a second one meaning the same thing.',
      );
    });

    testWidgets('one button folds everything, then unfolds it', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/images/logo.png'), asset('assets/i18n/en.json')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.text('logo.png'), findsOneWidget);
      expect(find.byTooltip('Collapse all'), findsOneWidget);

      await tester.tap(find.byTooltip('Collapse all'));
      await tester.pump();

      expect(find.text('logo.png'), findsNothing);
      expect(find.text('images'), findsOneWidget, reason: 'The folds remain.');
      expect(
        find.byTooltip('Expand all'),
        findsOneWidget,
        reason:
            'With everything folded away the only useful thing the button can '
            'do is the other direction.',
      );

      await tester.tap(find.byTooltip('Expand all'));
      await tester.pump();

      expect(find.text('logo.png'), findsOneWidget);
    });

    testWidgets('a typed query takes the fold button away', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: [asset('assets/images/logo.png'), asset('assets/i18n/en.json')],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      await tester.enterText(find.byType(TextField), 'logo');
      await tester.pump();

      expect(
        find.byTooltip('Collapse all'),
        findsNothing,
        reason: 'A filtered list is flat; there is nothing there to fold.',
      );
    });

    testWidgets('says what an empty package means', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: const [],
          fromPackages: const [],
          problems: const [],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.textContaining('declares no assets'), findsOneWidget);
    });

    testWidgets('shows a problem with what is wrong with it', (tester) async {
      await pump(
        tester,
        AssetListView(
          own: const [],
          fromPackages: const [],
          problems: [
            AssetProblem(
              kind: AssetProblemKind.unreachablePackageFile,
              package: null,
              packageRoot: '/project',
              declaration: 'packages/brand/assets/gone.png',
            ),
          ],
          selected: null,
          onSelect: (_) {},
        ),
      );

      expect(find.text('packages/brand/assets/gone.png'), findsOneWidget);
      expect(
        find.text('Declared through packages/…, and not found.'),
        findsOneWidget,
      );
    });
  });

  group('the detail', () {
    var logo = asset(
      'assets/images/logo.png',
      declaration: 'assets/images/',
      files: [
        file('assets/images/logo.png', length: 663),
        file('assets/images/2.0x/logo.png', scale: 2, length: 1840),
        file('assets/images/3.0x/logo.png', scale: 3, length: 3120),
      ],
    );

    Widget detail({
      AssetFile? shown,
      ValueChanged<AssetFile>? onDensity,
      Object? error,
    }) => AssetDetailView(
      asset: logo,
      file: shown ?? logo.main,
      bytes: error == null ? _png : null,
      error: error,
      dimensions: const Size(48, 48),
      background: PreviewBackground.checker,
      onBackground: (_) {},
      zoom: 1,
      onZoom: (_) {},
      onDensity: onDensity ?? (_) {},
    );

    testWidgets('says where the asset came from', (tester) async {
      await pump(tester, detail());

      // The declaration is the answer to "why is this in my bundle", and for a
      // directory declaration it is not derivable from the path.
      expect(find.text('assets/images/'), findsOneWidget);
      expect(find.text('48 × 48'), findsOneWidget);
      expect(find.text('663 B'), findsOneWidget);
    });

    testWidgets('offers one density per file, and reports the pick', (
      tester,
    ) async {
      AssetFile? picked;
      await pump(tester, detail(onDensity: (file) => picked = file));

      expect(find.text('2×'), findsWidgets);
      await tester.tap(find.text('3×').first);
      expect(picked?.scale, 3);
    });

    testWidgets('offers no zoom for a thing that has no size', (tester) async {
      var specimen = asset('assets/fonts/Roboto.ttf');
      await pump(
        tester,
        AssetDetailView(
          asset: specimen,
          file: specimen.main,
          bytes: _png,
          error: null,
          dimensions: null,
          background: PreviewBackground.checker,
          onBackground: (_) {},
          zoom: 1,
          onZoom: (_) {},
          onDensity: (_) {},
        ),
      );

      expect(find.text('Zoom'), findsNothing);
      expect(find.text('100%'), findsNothing);
    });

    testWidgets('zoom reads as magnification, not as a density', (
      tester,
    ) async {
      await pump(tester, detail());

      // `2×` next to the density switcher's `2×` would be the same thing said
      // twice about two different things.
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Density'), findsOneWidget);
      expect(find.text('Zoom'), findsOneWidget);
    });

    testWidgets('an unreadable file says so instead of drawing', (
      tester,
    ) async {
      await pump(tester, detail(error: 'PathNotFoundException'));

      expect(find.textContaining('Could not read this file'), findsOneWidget);
    });
  });

  group('the preview', () {
    testWidgets('draws a raster', (tester) async {
      await pump(
        tester,
        AssetPreview(bytes: _png, kind: AssetKind.image, name: 'logo.png'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a magnified asset is clipped to its pane', (tester) async {
      await pump(
        tester,
        SizedBox(
          height: 120,
          child: AssetPreview(
            bytes: _png,
            kind: AssetKind.image,
            name: 'logo.png',
            zoom: 8,
          ),
        ),
      );
      await tester.pump();

      // `Transform.scale` does not clip: at 8× a large raster painted straight
      // over the sidebar and the metadata beneath it.
      var viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.clipBehavior, isNot(Clip.none));
      expect(
        viewer.panEnabled,
        isTrue,
        reason: 'Magnifying without panning shows the middle and nothing else.',
      );
    });

    testWidgets('says when a kind has no preview', (tester) async {
      await pump(
        tester,
        AssetPreview(
          bytes: _png,
          kind: AssetKind.media,
          name: 'assets/chime.mp3',
        ),
      );

      expect(find.textContaining('No preview'), findsOneWidget);
    });

    testWidgets('shows the document when JSON is not an animation', (
      tester,
    ) async {
      await pump(
        tester,
        AssetPreview(
          bytes: Uint8List.fromList(utf8.encode('{"not":"lottie"}')),
          kind: AssetKind.data,
          name: 'assets/config.json',
        ),
      );
      await tester.pumpAndSettle();

      // Most `.json` files are not animations, so this is the ordinary path
      // rather than an error — and for a config the document is the thing
      // somebody opened the asset to read.
      expect(find.textContaining('"not"'), findsOneWidget);
      expect(find.textContaining('No preview'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a minified JSON is indented to be readable', (tester) async {
      await pump(
        tester,
        AssetPreview(
          bytes: Uint8List.fromList(utf8.encode('{"a":1,"b":{"c":2}}')),
          kind: AssetKind.data,
          name: 'assets/config.json',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('\n  "a": 1'),
        findsOneWidget,
        reason: 'A bundled config is usually one long line.',
      );
    });

    testWidgets('malformed JSON is shown as it is on disk', (tester) async {
      await pump(
        tester,
        AssetPreview(
          bytes: Uint8List.fromList(utf8.encode('{"unclosed": ')),
          kind: AssetKind.data,
          name: 'assets/config.json',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('"unclosed"'),
        findsOneWidget,
        reason:
            'The file that will not parse is exactly the one somebody came to '
            'look at; a parse error would take away the only view of it.',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an image that will not decode leaves the cache empty', (
      tester,
    ) async {
      PaintingBinding.instance.imageCache.clear();
      await pump(
        tester,
        AssetPreview(
          bytes: Uint8List.fromList(utf8.encode('{"not":"a png"}')),
          kind: AssetKind.image,
          name: 'assets/images/truncated.png',
        ),
      );
      // The decode fails on the *real* event loop, which fake time never runs.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump();
      }

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      // `MemoryImage` does not evict a failed decode, so without the preview
      // doing it the key sits in `_pendingImages` for the life of the process
      // — and everything that reads `pendingImageCount` to mean "work is in
      // flight" then waits out its budget on an image that will never land.
      expect(
        PaintingBinding.instance.imageCache.pendingImageCount,
        0,
        reason: 'a decode that failed is not work still in flight',
      );
    });

    testWidgets('reports a font it cannot load', (tester) async {
      await pump(
        tester,
        AssetPreview(
          bytes: _png,
          kind: AssetKind.font,
          name: 'assets/fonts/Broken.ttf',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Not a usable font file'), findsOneWidget);
    });
  });

  group('a font, and a document', () {
    testWidgets('a font is drawn in its own face, not as a glyph', (
      tester,
    ) async {
      await pump(
        tester,
        AssetPopover(
          asset: asset('assets/fonts/Roboto-Regular.ttf'),
          anchor: const Rect.fromLTWH(0, 0, 100, 20),
          // A real TrueType signature over bytes that are not a font: enough
          // to get past the gate, not enough to register. What is asserted is
          // the wiring — that a font reaches the loader at all — since the app
          // bundles no font bytes for a test to draw with.
          bytes: Uint8List.fromList([0, 1, 0, 0, ...List.filled(64, 0)]),
        ),
      );

      expect(
        find.byType(AssetFontFace),
        findsOneWidget,
        reason:
            'A card that answers "this is a font" has told you what the '
            'extension already did.',
      );
    });

    testWidgets('bytes that are not a font fall back rather than draw blank', (
      tester,
    ) async {
      await pump(
        tester,
        AssetPopover(
          asset: asset('assets/fonts/Broken.ttf'),
          anchor: const Rect.fromLTWH(0, 0, 100, 20),
          bytes: Uint8List.fromList(utf8.encode('this is not a font')),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byIcon(Icons.text_fields),
        findsOneWidget,
        reason:
            'FontLoader does not reliably refuse — it can register a family '
            'with no glyphs, which draws as a blank panel that looks like a '
            'working preview.',
      );
    });

    testWidgets('a data asset shows its first lines', (tester) async {
      await pump(
        tester,
        AssetPopover(
          asset: asset('assets/i18n/en.json'),
          anchor: const Rect.fromLTWH(0, 0, 100, 20),
          bytes: Uint8List.fromList(
            utf8.encode('{"greeting": "hello", "farewell": "bye"}'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('"greeting"'), findsOneWidget);
    });

    testWidgets('a folder sheet draws its fonts in their faces', (
      tester,
    ) async {
      var own = [
        asset('assets/fonts/Roboto-Regular.ttf'),
        asset('assets/fonts/Roboto-Bold.ttf'),
      ];
      await pump(
        tester,
        AssetFolderView(
          node: AssetTree.of(own).root,
          path: 'assets/fonts',
          onSelect: (_) {},
          bytesFor: (_) =>
              Uint8List.fromList([0, 1, 0, 0, ...List.filled(64, 0)]),
        ),
      );

      expect(
        find.byType(AssetFontFace),
        findsNWidgets(2),
        reason:
            'A sheet of fonts that all draw the same glyph cannot be used for '
            'the one thing a sheet of fonts is for.',
      );
    });
  });
}

/// The 48×48 fixture from `fixtures/probe_app`.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAARklEQVR42u3YMQ0AIAwAwepgI/hE'
  'Ro1ioB5YoMklL+Dmj7H2VwVQa9DM8yQgICAgICAgICAgICAgICAgICAgICAgJx/osgK8LWl1SxSv'
  '2QAAAABJRU5ErkJggg==',
);
