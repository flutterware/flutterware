// The library on its own page: the palette and the type ramp as pictures,
// a table of contents down the rail, and a token's fields opening under
// its own picture rather than in a column away from it.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene_authoring.dart' hide Token;
import 'package:flutterware_app/src/scene/import/variables.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/tokens_library.dart';
import 'package:flutterware_app/src/scene/ui/library_view.dart';
import 'package:flutterware_app/src/scene/workspace.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _library = '''
//@flutterware:tokens=1
import 'package:flutterware/scene_authoring.dart';

final brandTokens = [
  const Token<SceneColor>('brand', SceneColor(0xFFE8632B)),
  const Token<double>('radius', 28),
  const Token<SceneTextStyle>('title', SceneTextStyle(fontSize: 54)),
];
''';

const _scene =
    '''
$sceneFileMarker
import 'package:flutterware/scene_authoring.dart';

import 'scene_args.dart';

class Card({final SceneTokens t = const SceneTokens()}) extends SceneDefinition {
  late final headline = TextNode('Hello', style: t.title);
  @override
  late final root = FrameNode(width: 200, height: 100, fill: t.brand, children: [headline]);
}
''';

void main() {
  late TokensLibrary library;
  late SceneFile file;
  late SceneWorkspace workspace;

  setUp(() {
    library = TokensLibrary.open(
      '/pkg/lib/brand.tokens.dart',
      _library,
    ).library!;
    file = SceneFile.open(
      '/pkg/lib/card.scene.dart',
      _scene,
      tokens: library.tokens,
    ).file!;
    workspace = SceneWorkspace(
      file,
      libraries: [library],
      tokensFor: (libs) => [for (var l in libs) ...l.tokens],
    );
  });

  tearDown(() => workspace.dispose());

  /// The page is a rail and a sheet.
  Widget host(Widget child) {
    return MaterialApp(
      theme: appTheme,
      home: Material(child: SizedBox(height: 600, child: child)),
    );
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> open(
    WidgetTester tester, {
    List<SceneTokenDecl> exports = const [],
    List<String> Function(String)? readersOf,
    void Function(String, String)? onRename,
    void Function(String)? onDelete,
    VoidCallback? onImport,
  }) async {
    wide(tester);
    await tester.pumpWidget(
      host(
        SceneLibraryView(
          library,
          exports: exports,
          readersOf: readersOf,
          onRename: onRename ?? (name, wanted) => library.rename(name, wanted),
          onDelete: onDelete ?? library.delete,
          onImport: onImport,
        ),
      ),
    );
  }

  testWidgets('the sheet is the three a design system holds', (tester) async {
    await open(tester, exports: [SceneTokenDecl.export('cta', 'ButtonStyle')]);
    expect(find.text('COLOURS'), findsOneWidget);
    expect(find.text('NUMBERS'), findsOneWidget);
    expect(find.text('TYPE STYLES'), findsOneWidget);
    expect(find.text('FROM THE APP'), findsOneWidget);
    // Not a bag of values: no section for copy or for flags.
    expect(find.text('TEXT'), findsNothing);
    expect(find.text('SWITCHES'), findsNothing);
    expect(find.byKey(const ValueKey('library:rail:Colours')), findsOneWidget);
    expect(find.byKey(const ValueKey('library:token:brand')), findsOneWidget);
    expect(find.byKey(const ValueKey('library:token:radius')), findsOneWidget);
    expect(find.byKey(const ValueKey('library:token:cta')), findsOneWidget);
    // A style is set in itself, which is the whole reason for the page.
    expect(find.text('The quick brown fox'), findsOneWidget);
  });

  testWidgets('a colour opens under the palette, and closes again', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const ValueKey('library:editor:brand')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library:token:brand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library:editor:brand')), findsOneWidget);
    library.setValue('brand', const SceneColor(0xFF00FF00));
    await tester.pumpAndSettle();
    expect(
      find.text('#00FF00'),
      findsNWidgets(2),
      reason: 'the tile above and the field below both follow',
    );
    expect(file.scene.root.fill, const SceneColor(0xFF00FF00));
    // Clicking the open one closes it: the palette comes back whole.
    await tester.tap(find.byKey(const ValueKey('library:token:brand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library:editor:brand')), findsNothing);
  });

  testWidgets("a style's fields open under its own specimen", (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('library:token:title')));
    await tester.pumpAndSettle();
    // The picture is still on screen, above the fields that change it.
    expect(find.text('The quick brown fox'), findsOneWidget);
    expect(find.byKey(const ValueKey('library:editor:title')), findsOneWidget);
    // Size is set on this one; the rest are not, and say so.
    for (var label in ['Typeface · unset', 'Size', 'Tracking · unset']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a library refuses copy and flags', (tester) async {
    expect(
      () => library.add('label', SceneParamKind.string),
      throwsArgumentError,
    );
    expect(
      () => library.add('dense', SceneParamKind.bool),
      throwsArgumentError,
    );
    var refused = TokensLibrary.open('/pkg/lib/brand.tokens.dart', '''
//@flutterware:tokens=1
import 'package:flutterware/scene_authoring.dart';

final brandTokens = [
  const Token<String>('copy', 'Order now'),
];
''');
    expect(refused.library, isNull);
    expect(refused.refusals.single.message, contains('a library holds a '));
    expect(refused.refusals.single.message, contains('scene'));
  });

  testWidgets('editing one field of a style keeps the other fourteen', (
    tester,
  ) async {
    // The pane used to rebuild the style from a hand-written constructor
    // call naming five fields, so setting the weight deleted the tracking,
    // the typeface and the paint stack — from the model and, on the next
    // autosave, from the file.
    library.setStyle(
      'title',
      const SceneTextStyle(
        fontFamily: 'Bungee',
        fontSize: 54,
        weight: SceneFontWeight.w700,
        letterSpacing: 8,
        textCase: SceneTextCase.upper,
        wordSpacing: 3,
        layers: [
          StrokeLayer(width: 6, paint: SolidPaint(SceneColor(0xFF000000))),
          FillLayer(),
        ],
      ),
    );
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('library:token:title')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bold').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Black').last);
    await tester.pumpAndSettle();
    var style = library.named('title')!.style!;
    expect(style.weight, SceneFontWeight.w900);
    expect(style.fontSize, 54);
    expect(style.fontFamily, 'Bungee');
    expect(style.letterSpacing, 8);
    expect(style.textCase, SceneTextCase.upper);
    expect(style.wordSpacing, 3);
    expect(style.layers, hasLength(2));
  });

  testWidgets('adds a token of the section it was pressed under', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('library:add:Colours')));
    await tester.pumpAndSettle();
    expect(library.tokens.map((t) => t.name), contains('color'));
    // Added and named at once: the field is open on the new token.
    await tester.enterText(find.byType(EditableText), 'accent');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(library.named('accent')!.kind, SceneParamKind.color);
    expect(find.byKey(const ValueKey('library:editor:accent')), findsOneWidget);
  });

  testWidgets('the editor names who reads it', (tester) async {
    await open(tester, readersOf: (name) => ['Card · root.fill']);
    await tester.tap(find.byKey(const ValueKey('library:token:brand')));
    await tester.pumpAndSettle();
    expect(find.text('READ BY 1 PROPERTY'), findsOneWidget);
    expect(find.text('Card · root.fill'), findsOneWidget);
  });

  testWidgets('shows the last import, and the door to the next', (
    tester,
  ) async {
    var imported = 0;
    await open(tester, onImport: () => imported++);
    expect(find.textContaining('Nothing imported yet'), findsOneWidget);
    library.merge(
      importVariables(
        File('test/scene/fixtures/variables.json').readAsStringSync(),
      ),
      from: 'variables.json',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library:import-note')), findsOneWidget);
    expect(find.textContaining('not imported'), findsOneWidget);
    expect(find.textContaining('Kept: brand, radius, title'), findsOneWidget);
    await tester.tap(find.text('import again…'));
    await tester.pumpAndSettle();
    expect(imported, 1);
  });
}
