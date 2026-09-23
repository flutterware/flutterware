// Exports: the app's own values, named for the scenes.
//
// A library token the editor holds and draws; an export it only names —
// `Token<Color>('accent', AppColors.accent)` in the group's declaration —
// and the guest, which compiled the declaration, draws it. What is checked
// here is the whole path of that name: the reader records the type and
// never the value; the generated class converts at the getter so
// `fill: tokens.accent` compiles; the file spells the reference and no
// value; an edit never detaches it; the guest lays the value on the node,
// and an app text style under the text's own.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart' hide Token;
import 'package:flutterware_app/src/scene/args_codegen.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/group_file.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/tokens_file.dart';
import 'package:flutterware_app/src/scene/ui/inspector.dart';
import 'package:flutterware_app/src/scene/ui/swatches.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'scene_args.dart';
import 'scenes.dart' as fixture;

/// The fixture group's vocabulary, read the way the studio reads it: the
/// library's values, then the exports by name and type.
final _tokens = [
  ...parseTokensFile(
    File('test/scene/sample.tokens.dart').readAsStringSync(),
    symbol: 'sampleTokens',
  ).tokens,
  ...parseGroupFile(File('test/scene/scenes.dart').readAsStringSync()).exports,
];

const _scene =
    '''
$sceneFileMarker
import 'package:flutterware/scene_authoring.dart';

import 'scene_args.dart';

class Card({final SceneTokens t = const SceneTokens()}) extends SceneDefinition {
  late final title = TextNode('Hello', style: t.heading, fontSize: 12);
  late final plain = TextNode('Plain');
  @override
  late final root = FrameNode(width: 200, height: 100, fill: t.accent, children: [title, plain]);
}
''';

SceneParse _parse(String source) => parseSceneFile(source, tokens: _tokens);

String _emit(SceneDocument doc) => emitSceneFile(doc, className: 'Card');

void main() {
  group('the declaration', () {
    test('records a type and a kind, never the value', () {
      var parsed = parseGroupFile('''
import 'package:material_ui/material_ui.dart';
final scenes = SceneGroup(exports: [
  Token<Color>('accent', AppColors.accent),
  Token<TextStyle>('heading', Theme.of(context).textTheme.titleLarge!),
  Token<double>('gutter', AppSpacing.md),
  Token<ButtonStyle>('cta', FilledButton.styleFrom()),
]);
''');
      expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
      var [accent, heading, gutter, cta] = parsed.exports;
      expect(accent.isExport, isTrue);
      expect(accent.kind, SceneParamKind.color);
      expect(accent.type, 'Color');
      expect(accent.value, isNull);
      expect(accent.hasValue, isFalse);
      expect(heading.isStyle, isTrue);
      expect(heading.style, isNull, reason: 'fields only the app knows');
      expect(gutter.kind, SceneParamKind.number);
      expect(cta.isOpaque, isTrue);
      expect(cta.kind, isNull);
    });

    test('refuses modes: the app picks where it builds', () {
      var parsed = parseGroupFile('''
final scenes = SceneGroup(exports: [
  Token<Color>('accent', a, modes: {'dark': b}),
]);
''');
      expect(parsed.refusals.single.construct, 'modes');
    });
  });

  group('the generated class', () {
    var source = emitSceneArgs(
      externals: [],
      scenes: [],
      tokens: _tokens,
      entries: false,
    );

    test("converts at the getter, so a scene reads the editor's type", () {
      expect(
        source,
        contains(
          "SceneColor get accent => sceneColorOf(_token('accent')! as Color);",
        ),
      );
      expect(source, contains('SceneTextStyle get heading =>'));
      expect(
        source,
        contains("sceneTextStyleOf(_token('heading')! as TextStyle)"),
      );
      expect(source, contains("import 'package:flutterware/scene.dart';"));
      // A library value is still a const field with its literal.
      expect(source, contains('this.surface = const SceneColor(0xFF2B1B12)'));
    });

    test("is what the fixture compiles: the app's value, converted", () {
      const tokens = SceneTokens();
      expect(tokens.accent, const SceneColor(0xFF0000FF));
      expect(tokens.heading.fontSize, 40);
      expect(tokens.heading.weight, SceneFontWeight.w800);
      expect(tokens.heading.color, isNull);
      expect(fixture.scenes.exports.length, 2);
    });
  });

  group('the file', () {
    test('spells the reference and no value, on a property and a style', () {
      var parsed = _parse(_scene);
      expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
      var doc = parsed.doc!;
      expect(doc.root.bindings['fill'], const TokenRef('accent'));
      var title = doc.nodeNamed('title')! as TextNode;
      expect(title.bindings[styleBindingKey], const StyleRef('heading'));
      expect(title.fontSize, 12, reason: "spelled, so the text's own");
      expect(title.weight, SceneFontWeight.w400, reason: 'nothing laid here');
      var out = _emit(doc);
      expect(out, contains('fill: t.accent'));
      expect(
        out,
        contains("TextNode('Hello', style: t.heading.copyWith(fontSize: 12))"),
      );
      expect(_emit(_parse(out).doc!), out);
    });

    test('refuses an export of the wrong kind, and names it', () {
      var parsed = _parse(
        _scene.replaceAll('fill: t.accent', 'corner: t.accent'),
      );
      expect(parsed.refusals.single.construct, 'token type');
      expect(parsed.refusals.single.message, contains('Color'));
    });
  });

  group('the editor', () {
    SceneEditor open() => SceneEditor(_parse(_scene).doc!);

    test('never detaches an export on an edit; only a lost token ends it', () {
      var e = open();
      e.perform(
        'Recolour',
        () => e.doc.root.fill = const SceneColor(0xFF123456),
      );
      expect(e.doc.root.bindings['fill'], const TokenRef('accent'));
      e.perform('Clear', () => e.doc.root.fill = null);
      expect(e.doc.root.bindings['fill'], const TokenRef('accent'));
      var title = e.doc.nodeNamed('title')! as TextNode;
      e.perform('Resize', () => title.fontSize = 30);
      expect(title.bindings[styleBindingKey], const StyleRef('heading'));
      e.doc.tokens.removeWhere((t) => t.isExport);
      e.perform('Touch', () {});
      expect(e.doc.root.bindings['fill'], isNull);
      expect(title.bindings[styleBindingKey], isNull);
    });

    test('binds a property to an export without touching its value', () {
      var e = open();
      var plain = e.doc.nodeNamed('plain')! as TextNode;
      e.bindToken(plain, 'color', 'accent');
      expect(plain.bindings['color'], const TokenRef('accent'));
      expect(plain.color, const SceneColor(0xFF1A1A1A), reason: 'kept');
      expect(_emit(e.doc), contains('color: t.accent'));
      expect(
        () => e.bindToken(plain, 'fontSize', 'accent'),
        throwsArgumentError,
      );
      e.applyStyle(plain, 'heading');
      expect(plain.bindings[styleBindingKey], const StyleRef('heading'));
      expect(plain.fontSize, 16, reason: 'the app lays its style under');
    });
  });

  group('the guest', () {
    test('is told which property reads which export, on the wire', () {
      var doc = _parse(_scene).doc!;
      var wire = doc.toWire();
      var root = wire['root'] as Map<String, Object?>;
      expect(root['exports'], {'fill': 'accent'});
      var title = (root['children']! as List).first! as Map<String, Object?>;
      expect(title['exports'], {'style': 'heading'});
      // A library binding is the editor's business: the value travels.
      expect(title.containsKey('bindings'), isFalse);
      var arrived = sceneFromWire(root);
      expect(arrived.root.bindings['fill'], const TokenRef('accent'));
      bindExternals(arrived, const [], tokens: fixture.scenes.tokens);
      expect(arrived.root.fill, const SceneColor(0xFF0000FF));
      expect(
        (arrived.nodeNamed('title')! as TextNode).weight,
        SceneFontWeight.w800,
      );
    });

    test("puts the app's value on the property, and its style under", () {
      var doc = _parse(_scene).doc!;
      bindExternals(doc, const [], tokens: fixture.scenes.tokens);
      expect(doc.root.fill, const SceneColor(0xFF0000FF));
      var title = doc.nodeNamed('title')! as TextNode;
      expect(title.fontSize, 12, reason: "the text's own wins");
      expect(title.weight, SceneFontWeight.w800, reason: "unset: the app's");
      var plain = doc.nodeNamed('plain')! as TextNode;
      expect(plain.weight, SceneFontWeight.w400, reason: 'no style, no change');
    });

    test(
      "converts the table's properties of a TextStyle and drops the rest",
      () {
        var style = sceneTextStyleOf(
          const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: Color(0xFF112233),
            letterSpacing: 2,
            fontFamily: 'Serif',
          ),
        );
        expect(style.fontSize, 22);
        expect(style.weight, SceneFontWeight.w600);
        expect(style.color, const SceneColor(0xFF112233));
        expect(style.fontFamily, 'Serif');
        expect(style.letterSpacing, 2);
        expect(style.values.keys, [
          'fontFamily',
          'fontSize',
          'weight',
          'letterSpacing',
          'color',
        ]);
        expect(
          sceneColorOf(const Color(0xFF0000FF)),
          const SceneColor(0xFF0000FF),
        );
      },
    );
  });

  testWidgets('the inspector offers an export by name, and shows it bound', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var editor = SceneEditor(_parse(_scene).doc!);
    editor.select(editor.doc.nodeNamed('plain')!);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: AnimatedBuilder(
            animation: editor.listenable,
            builder: (context, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: 900,
                child: SceneInspector(editor),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The text's colour swatches: the last swatch row on the panel — and
    // the panel is a lazy list, so it has to be scrolled to before it is
    // built at all.
    await tester.scrollUntilVisible(
      find.text('Color'),
      120,
      scrollable: find
          .descendant(
            of: find.byType(SceneInspector),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await tester.tapAt(
      tester.getCenter(find.byType(SceneColorField).last),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('FROM THE APP'), findsOneWidget);
    expect(find.text('tokens.accent'), findsOneWidget);
    expect(
      find.text('Color'),
      findsAtLeastNWidgets(1),
      reason: 'the type rides along, not a value',
    );
    await tester.tap(find.text('tokens.accent'));
    await tester.pump();
    await tester.pump();
    var plain = editor.doc.nodeNamed('plain')!;
    expect(plain.bindings['color'], const TokenRef('accent'));
    expect(find.text('tokens.accent'), findsOneWidget);
    expect(
      find.text("the app's"),
      findsOneWidget,
      reason: 'the editor holds no value for an export',
    );
    await tester.pump(kDoubleTapTimeout);
  });
}
