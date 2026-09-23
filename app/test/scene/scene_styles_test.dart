// Styles: a text style is a token that bundles the text subset of the
// table, applied whole and overridden per property.
//
// The file's rule is the one the plan decided (§4.3): what the node spells
// beside `style:` is an override, what it leaves out is inherited, and a
// property spelled equal to the style's is inherited — there is no flag.
// So the graders here are the round trip on both sides of that line, the
// constructor resolving the same way a parsed node does, and the editor's
// three doors: apply, override (any edit), reset.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart' hide Token;
import 'package:flutterware_app/src/scene/args_codegen.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/scene_file.dart';
import 'package:flutterware_app/src/scene/tokens_file.dart';
import 'package:flutterware_app/src/scene/ui/inspector.dart';
import 'package:flutterware_app/src/ui/theme.dart';

const _declaration = '''
import 'package:flutterware/scene_authoring.dart';

final sceneTokens = [
  const Token<SceneColor>('ink', SceneColor(0xFF111111)),
  const Token<SceneTextStyle>(
    'title',
    SceneTextStyle(fontSize: 54, weight: SceneFontWeight.w700, textCase: SceneTextCase.upper),
  ),
  const Token<SceneTextStyle>('body', SceneTextStyle(fontSize: 20, lineHeight: 1.4, color: SceneColor(0xFFD8C9BD))),
];
''';

final _tokens = parseTokensFile(_declaration).tokens;

const _scene =
    '''
$sceneFileMarker
import 'package:flutterware/scene_authoring.dart';

import 'scene_args.dart';

class Card({final SceneTokens t = const SceneTokens()}) extends SceneDefinition {
  late final headline = TextNode('Hello', style: t.title, color: t.ink);
  late final sub = TextNode('Sub', style: t.body, fontSize: 24);
  late final plain = TextNode('Plain', fontSize: 12);
  @override
  late final root = FrameNode(width: 200, height: 100, children: [headline, sub, plain]);
}
''';

SceneParse _parse(String source) => parseSceneFile(source, tokens: _tokens);

String _emit(SceneDocument doc) => emitSceneFile(doc, className: 'Card');

void main() {
  group('the declaration', () {
    test('reads a style token, each field a literal of its kind', () {
      var parsed = parseTokensFile(_declaration);
      expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
      var title = parsed.tokens[1];
      expect(title.isStyle, isTrue);
      expect(title.isOpaque, isFalse);
      expect(title.typeName, 'SceneTextStyle');
      expect(title.style!.fontSize, 54);
      expect(title.style!.weight, SceneFontWeight.w700);
      expect(title.style!.textCase, SceneTextCase.upper);
      expect(title.style!.color, isNull);
      expect(parsed.tokens[2].style!.lineHeight, 1.4);
      expect(parsed.tokens[2].style!.values.keys, [
        'fontSize',
        'lineHeight',
        'color',
      ]);
    });

    test('refuses a field that is not one, and a mode', () {
      var parsed = parseTokensFile('''
final sceneTokens = [
  Token<SceneTextStyle>('a', SceneTextStyle(kerning: 2)),
  Token<SceneTextStyle>('b', SceneTextStyle(fontSize: 10), modes: {'dark': SceneTextStyle(fontSize: 12)}),
  Token<SceneTextStyle>('c', SceneTextStyle(fontSize: 10)),
];
''');
      expect(parsed.refusals.map((r) => r.construct), ['style', 'modes']);
      expect(parsed.tokens.single.name, 'c');
    });

    test('spells a paint stack the app can compile', () {
      // The generated class used to spell a style field by falling through
      // to `'$value'` — a toString(). Enums survived by luck; a paint stack
      // came out as `StrokeLayer(21.9, SolidPaint(Color(0xFF…)))`, which is
      // positional where the constructors are named and names a type the
      // file cannot see. A library with any paint pass generated a
      // scene_args.dart that did not compile.
      var tokens = parseTokensFile('''
final sceneTokens = [
  const Token<SceneTextStyle>('poster', SceneTextStyle(fontSize: 54, layers: [
    StrokeLayer(width: 6, paint: SolidPaint(SceneColor(0xFF000000)), dy: 2),
    FillLayer(opacity: 0.8),
  ], textCase: SceneTextCase.upper)),
];
''').tokens;
      var source = emitSceneArgs(externals: [], scenes: [], tokens: tokens);
      var flat = source.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        flat,
        contains(
          'layers: [ StrokeLayer(width: 6, paint: '
          'SolidPaint(SceneColor(0xFF000000)), dy: 2), '
          'FillLayer(opacity: 0.8), ]',
        ),
      );
      expect(flat, contains('textCase: SceneTextCase.upper'));
      expect(source, isNot(contains('SolidPaint(Color(')));
    });

    test('is a const field on the generated class', () {
      var source = emitSceneArgs(externals: [], scenes: [], tokens: _tokens);
      expect(source, contains('final SceneTextStyle title;'));
      var flat = source.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        flat,
        contains(
          'this.title = const SceneTextStyle( fontSize: 54, '
          'weight: SceneFontWeight.w700, textCase: SceneTextCase.upper, )',
        ),
        reason: 'the same spelling the scene file uses, through one table',
      );
      expect(flat, contains('lineHeight: 1.4, color: SceneColor(0xFFD8C9BD)'));
    });
  });

  group('a text taking a style', () {
    test('inherits what it does not spell, overrides what it does', () {
      var parsed = _parse(_scene);
      expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
      var doc = parsed.doc!;
      var headline = doc.nodeNamed('headline')! as TextNode;
      expect(headline.bindings[styleBindingKey], const StyleRef('title'));
      expect(headline.fontSize, 54);
      expect(headline.weight, SceneFontWeight.w700);
      expect(headline.textCase, SceneTextCase.upper);
      expect(headline.color, const SceneColor(0xFF111111), reason: 'override');
      expect(headline.bindings['color'], const TokenRef('ink'));
      var sub = doc.nodeNamed('sub')! as TextNode;
      expect(sub.fontSize, 24, reason: "its own, over the style's 20");
      expect(sub.color, const SceneColor(0xFFD8C9BD));
      expect(sub.lineHeight, 1.4);
      expect(inheritsFromStyle(doc, sub, 'fontSize'), isFalse);
      expect(inheritsFromStyle(doc, sub, 'color'), isTrue);
      expect(inheritsFromStyle(doc, headline, 'color'), isFalse);
    });

    test(
      'round-trips: inherited absent, overrides spelled, equal is inherited',
      () {
        var parsed = _parse(_scene);
        var out = _emit(parsed.doc!);
        expect(out, contains('style: t.title.copyWith(color: t.ink)'));
        expect(
          out,
          contains("TextNode('Sub', style: t.body.copyWith(fontSize: 24))"),
        );
        expect(out, isNot(contains('weight: SceneFontWeight.w700')));
        expect(_emit(_parse(out).doc!), out);
        // Overridden back to the style's own value: the override disappears.
        var sub = parsed.doc!.nodeNamed('sub')! as TextNode;
        sub.fontSize = 20;
        expect(_emit(parsed.doc!), contains("TextNode('Sub', style: t.body)"));
        // A value equal to the TABLE default but not the style's is spelled:
        // the style is the baseline, not the default.
        var headline = parsed.doc!.nodeNamed('headline')! as TextNode;
        headline.weight = SceneFontWeight.w400;
        expect(_emit(parsed.doc!), contains('weight: SceneFontWeight.w400'));
      },
    );

    test('takes its own style, and refuses what is not one', () {
      // A literal is a node's OWN type, and legal: it is the only way to
      // spell a treatment nothing else shares (master plan §4.5).
      var parsed = _parse(
        _scene.replaceAll(
          'style: t.title',
          'style: SceneTextStyle(fontSize: 10)',
        ),
      );
      expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
      expect((parsed.doc!.nodeNamed('headline')! as TextNode).fontSize, 10);
      parsed = _parse(_scene.replaceAll('style: t.title', 'style: 12'));
      expect(parsed.refusals.single.construct, 'style');
      parsed = _parse(_scene.replaceAll('style: t.title', 'style: t.ink'));
      expect(parsed.refusals.single.construct, 'token type');
      parsed = _parse(_scene.replaceAll('style: t.title', 'style: t.nope'));
      expect(parsed.refusals.single.construct, 'unknown token');
    });
  });

  group('in the editor', () {
    SceneEditor open() => SceneEditor(_parse(_scene).doc!);

    test('apply writes the style; any edit overrides; reset comes back', () {
      var e = open();
      var plain = e.doc.nodeNamed('plain')! as TextNode;
      e.applyStyle(plain, 'title');
      expect(plain.fontSize, 54);
      expect(plain.weight, SceneFontWeight.w700);
      expect(plain.bindings[styleBindingKey], const StyleRef('title'));
      e.perform('Size', () => plain.fontSize = 60);
      expect(
        plain.bindings[styleBindingKey],
        const StyleRef('title'),
        reason: 'never detached',
      );
      expect(inheritsFromStyle(e.doc, plain, 'fontSize'), isFalse);
      expect(
        _emit(e.doc),
        contains("TextNode('Plain', style: t.title.copyWith(fontSize: 60))"),
      );
      e.resetToStyle(plain, 'fontSize');
      expect(plain.fontSize, 54);
      expect(_emit(e.doc), contains("TextNode('Plain', style: t.title)"));
      e.detachStyle(plain);
      expect(plain.bindings[styleBindingKey], isNull);
      expect(plain.fontSize, 54, reason: 'the values stay');
      var out = _emit(e.doc).replaceAll(RegExp(r'\s+'), ' ');
      expect(
        out,
        contains(
          "TextNode( 'Plain', style: SceneTextStyle( fontSize: 54, "
          'weight: SceneFontWeight.w700, textCase: SceneTextCase.upper, ), )',
        ),
      );
    });

    test('a style is refused on a frame, and as a property binding', () {
      var e = open();
      expect(() => e.applyStyle(e.doc.root, 'title'), throwsArgumentError);
      expect(
        () => e.bindToken(e.doc.nodeNamed('plain')!, 'color', 'title'),
        throwsArgumentError,
      );
      expect(
        () => e.applyStyle(e.doc.nodeNamed('plain')!, 'ink'),
        throwsArgumentError,
      );
    });

    test('readers, and a style gone from the declaration', () {
      var e = open();
      expect(e.readersOfToken('title').map((r) => '${r.$1.name}.${r.$2}'), [
        'headline.style',
      ]);
      e.doc.tokens.removeWhere((t) => t.name == 'title');
      e.perform('Touch', () {});
      expect(e.doc.nodeNamed('headline')!.bindings[styleBindingKey], isNull);
      expect(
        (e.doc.nodeNamed('headline')! as TextNode).fontSize,
        54,
        reason: 'kept',
      );
    });
  });

  test('a compiled text resolves a delta, then the style, then default', () {
    const style = SceneTextStyle(fontSize: 20, weight: SceneFontWeight.w600);
    var t = TextNode('x', style: style.copyWith(fontSize: 30));
    expect(t.fontSize, 30);
    expect(t.weight, SceneFontWeight.w600);
    expect(t.color, const SceneColor(0xFF1A1A1A));
    expect(TextNode('y').fontSize, 16);
  });

  test('a style carries the paint stack, inherited and overridden', () {
    // The stack is a style property like every other, and the one the panel
    // could not say that about: it draws its own list with its own header,
    // so it does not fit in a property row and had no marker at all.
    const stack = [
      StrokeLayer(width: 8, paint: SolidPaint(SceneColor(0xFF120720))),
      FillLayer(),
    ];
    var t = TextNode('Hi', name: 'headline');
    var doc = SceneDocument(FrameNode(name: 'root')..children.add(t))
      ..tokens.add(
        const SceneTokenDecl.style('display', SceneTextStyle(layers: stack)),
      );
    var editor = SceneEditor(doc);
    editor.applyStyle(t, 'display');
    expect(t.layers, hasLength(2), reason: 'the style wrote its stack');
    expect(inheritsFromStyle(doc, t, 'layers'), isTrue);
    t.layers = [...t.layers, const FillLayer(dx: 2)];
    expect(
      inheritsFromStyle(doc, t, 'layers'),
      isFalse,
      reason: 'a list is compared by contents, not by identity',
    );
    editor.resetToStyle(t, 'layers');
    expect(inheritsFromStyle(doc, t, 'layers'), isTrue);
  });

  testWidgets('the panel separates all three states a property can be in', (
    tester,
  ) async {
    // Under a style a property is in one of three states, and the panel has
    // to tell them apart: the style decides it, the node has typed over it,
    // or the style says nothing about it and the value is the node's own.
    // Marking only the override made the first and the last identical, which
    // is the same as never saying which properties the style is made of.
    var t = TextNode('Hi', name: 'headline');
    var doc = SceneDocument(FrameNode(name: 'root')..children.add(t))
      ..tokens.add(
        const SceneTokenDecl.style(
          'display',
          SceneTextStyle(fontSize: 54, weight: SceneFontWeight.w700),
        ),
      );
    var editor = SceneEditor(doc)..applyStyle(t, 'display');
    editor.select(t);
    // The panel is a lazy list: a viewport taller than the test surface
    // builds only what fits on it, and the type section is below the fold.
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
                height: 1600,
                child: SceneInspector(editor),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byIcon(Icons.link_off),
      findsNothing,
      reason: 'nothing is typed over yet',
    );
    // The tooltip is what separates the style's mark from the plug every
    // free property carries — both are a link icon, and only one of them
    // says whose value this is.
    expect(
      find.byTooltip('display decides this'),
      findsNWidgets(2),
      reason: 'fontSize and weight, and nothing else the style leaves alone',
    );

    // The editor coalesces its notification onto a post-frame callback, so
    // a single pump paints the frame that schedules it and not the one that
    // shows it.
    editor.perform('Size', () => t.fontSize = 66);
    await tester.pump();
    await tester.pump();
    // ignore: avoid_print
    expect(
      find.byTooltip('Typed over display — click to take its value back'),
      findsOneWidget,
    );
    expect(
      find.byTooltip('display decides this'),
      findsOneWidget,
      reason: 'the overridden row swapped its mark, weight kept its own',
    );

    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pump();
    await tester.pump();
    expect(t.fontSize, 54, reason: "the style's value came back");
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.byTooltip('display decides this'), findsNWidgets(2));
  });

  test('a file spelling align inside the style opens, and converges', () {
    // align and maxLines left the style on 2026-09-08. A scene file is real
    // Dart, so one that spells them inside its style stops compiling — but
    // the parser reads them rather than refusing, puts them on the node, and
    // the next save writes them where they belong. The same courtesy the 0.8
    // files get for their text properties.
    var parsed = parseSceneFile('''
$sceneFileMarker
import 'package:flutterware/scene_authoring.dart';

class Poster() extends SceneDefinition {
  late final title = TextNode('ARCADE', style: SceneTextStyle(fontSize: 54, align: SceneTextAlign.center, maxLines: 2));
  @override
  late final root = FrameNode(children: [title]);
}
''');
    expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
    var t = parsed.doc!.nodeNamed('title')! as TextNode;
    expect(t.align, SceneTextAlign.center);
    expect(t.maxLines, 2);
    var out = emitSceneFile(parsed.doc!, className: 'Poster');
    expect(out, contains('style: SceneTextStyle(fontSize: 54)'));
    expect(out, contains('align: SceneTextAlign.center'));
    expect(out, contains('maxLines: 2'));
  });

  test('a face is set by its axes, and one axis is a key of its own', () {
    var parsed = parseSceneFile('''
$sceneFileMarker
import 'package:flutterware/scene_authoring.dart';

class Poster() extends SceneDefinition {
  late final title = TextNode('ARCADE', style: SceneTextStyle(axes: {'wght': 780, 'wdth': 62.5}));
  @override
  late final root = FrameNode(children: [title]);
}
''');
    expect(parsed.refusals, isEmpty, reason: parsed.refusals.join('\n'));
    var t = parsed.doc!.nodeNamed('title')! as TextNode;
    expect(t.axes, {'wght': 780.0, 'wdth': 62.5});
    expect(
      emitSceneFile(parsed.doc!, className: 'Poster'),
      contains("axes: {'wght': 780, 'wdth': 62.5}"),
    );

    // The map is one property; each tag is a part of it. That is what makes
    // a continuously morphing headline possible at all — the map as a whole
    // is neither a number a parameter can fill nor one a track can lerp.
    expect(bindableKind(t, 'axes'), isNull);
    expect(bindableKind(t, 'axes.wght'), SceneParamKind.number);
    expect(getSceneProperty(t, 'axes.wght'), 780.0);
    setSceneProperty(t, 'axes.wght', 320.0);
    expect(t.axes, {'wght': 320.0, 'wdth': 62.5}, reason: 'one axis moved');
    setSceneProperty(t, 'axes.wght', null);
    expect(t.axes, {'wdth': 62.5}, reason: "null is the face's own default");
  });

  test('an axis a motion moves is drawn even where the node set none', () {
    var t = TextNode('x', name: 't');
    expect(sceneFontVariations(t), isNull, reason: 'nothing to say');
    t.writeFx(Object(), 'axes.wght', 612.0);
    expect(
      sceneFontVariations(t)!.single,
      const FontVariation('wght', 612),
      reason: 'the track is the whole of what it says',
    );
  });

  test('the wire spells a style apart from a token', () {
    expect(const StyleRef('title').toWire(), 'style:title');
    expect(SceneBinding.fromWire('style:title'), const StyleRef('title'));
    expect('${const StyleRef('title')}', 'tokens.title');
  });
}
