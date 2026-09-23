// The editor foundation under test: selection as a set of names, every
// mutation a command door, the undo stack a journal — plus the focus
// discipline in widgets (a Backspace in an inspector field must never
// delete a node).
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';
import 'package:flutterware_app/src/scene/fixtures.dart';
import 'package:flutterware_app/src/scene/measure.dart';
import 'package:flutterware_app/src/scene/ui/canvas.dart';
import 'package:flutterware_app/src/scene/ui/tree_panel.dart';
import 'package:flutterware_app/src/scene/ui/shortcuts.dart';
import 'package:flutterware_app/src/scene/editor.dart';
import 'package:flutterware_app/src/scene/ui/inspector.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The inspector is a list and the content field sits below the geometry;
/// the outermost Scrollable in it is the list (a text field has one too).
Future<void> scrollInspectorTo(WidgetTester tester, Finder target) =>
    tester.scrollUntilVisible(
      target,
      120,
      scrollable: find
          .descendant(
            of: find.byType(SceneInspector),
            matching: find.byType(Scrollable),
          )
          .first,
    );

void main() {
  bindingDoorTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selection is a set of names', () {
    test('select replaces, toggle flips, the root never selects', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var doc = editor.doc;
      editor.select(doc.nodeNamed('headline'));
      editor.select(doc.nodeNamed('glow'));
      expect(editor.selectionNames, ['glow']);
      editor.select(doc.nodeNamed('headline'), toggle: true);
      expect(editor.selectionNames, ['glow', 'headline']);
      editor.select(doc.nodeNamed('glow'), toggle: true);
      expect(editor.selectionNames, ['headline']);
      editor.select(doc.root);
      expect(editor.selectionNames, isEmpty);
    });

    test('dead names prune silently and primary is the last live one', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var doc = editor.doc;
      editor.setSelection(['glow', 'headline']);
      expect(editor.primary!.name, 'headline');
      expect(editor.single, isNull);
      doc.delete(doc.nodeNamed('headline')!);
      expect(editor.selectionNames, ['glow']);
      expect(editor.single!.name, 'glow');
    });

    test('selectWithin takes top-level nodes overlapping the rect', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var doc = editor.doc;
      doc.nodeNamed('glow')!.measured = const SceneRect(600, 0, 480, 370);
      doc.nodeNamed('copy')!.measured = const SceneRect(64, 120, 500, 250);
      doc.nodeNamed('headline')!.measured = const SceneRect(64, 120, 490, 60);
      editor.selectWithin(const SceneRect(0, 0, 400, 400));
      // headline overlaps too, but it is not top-level — the marquee
      // selects siblings of the artboard, not their insides.
      expect(editor.selectionNames, ['copy']);
      editor.selectWithin(const SceneRect(0, 0, 1024, 500));
      expect(editor.selectionNames, ['glow', 'copy']);
    });

    test('addressable exposes the chains of every selected node', () {
      var editor = SceneEditor(coffeeBannerDraft());
      Iterable<String> names(Iterable<SceneNode> nodes) =>
          nodes.map((n) => n.name);
      expect(names(editor.addressable()), isNot(contains('headline')));
      editor.setSelection(['copy', 'cta']);
      expect(
        names(editor.addressable()),
        containsAll(['headline', 'subtitle', 'ctaLabel']),
      );
    });
  });

  group('the command door and its journal', () {
    test('perform + undo + redo round-trip values and structure', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var doc = editor.doc;
      var headline = doc.nodeNamed('headline')! as TextNode;
      editor.perform('Edit fontSize', () => headline.fontSize = 99);
      editor.perform('Delete glow', () {
        doc.root.children.remove(doc.nodeNamed('glow'));
      });
      expect(doc.nodeNamed('glow'), isNull);
      editor.undo();
      expect(doc.nodeNamed('glow'), isNotNull);
      expect((doc.nodeNamed('headline')! as TextNode).fontSize, 99);
      editor.undo();
      expect((doc.nodeNamed('headline')! as TextNode).fontSize, 54);
      editor.redo();
      expect((doc.nodeNamed('headline')! as TextNode).fontSize, 99);
      expect(doc.nodeNamed('glow'), isNotNull);
      editor.redo();
      expect(doc.nodeNamed('glow'), isNull);
    });

    test('a new door clears redo', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var node = editor.doc.nodeNamed('glow')!;
      editor.perform('a', () => node.x = 1);
      editor.undo();
      expect(editor.canRedo, true);
      editor.perform('b', () => editor.doc.nodeNamed('glow')!.y = 2);
      expect(editor.canRedo, false);
    });

    test('selection survives undo by name', () {
      var editor = SceneEditor(coffeeBannerDraft());
      editor.setSelection(['headline']);
      editor.perform('Edit x', () => editor.doc.nodeNamed('headline')!.x = 40);
      editor.undo();
      expect(editor.primary!.name, 'headline');
    });

    test('a mergeKey burst is one undo entry', () {
      var editor = SceneEditor(coffeeBannerDraft());
      editor.setSelection(['glow']);
      var before = editor.doc.nodeNamed('glow')!.x;
      for (var i = 0; i < 5; i++) {
        editor.nudgeSelection(1, 0, mergeKey: 'drag1');
      }
      editor.nudgeSelection(0, 1, mergeKey: 'drag2');
      expect(editor.doc.nodeNamed('glow')!.x, before + 5);
      editor.undo(); // drops the whole second gesture
      editor.undo(); // drops the whole first gesture
      expect(editor.doc.nodeNamed('glow')!.x, before);
      expect(editor.canUndo, false);
    });

    test('two gestures on one property are two entries', () {
      // The merge key alone cannot tell one drag from the next — both carry
      // 'x'. endMerge is what closes a run, and a field calls it on release.
      var editor = SceneEditor(coffeeBannerDraft());
      var glow = editor.doc.nodeNamed('glow')!;
      for (var v in [601.0, 602.0, 603.0]) {
        editor.perform('Edit x', mergeKey: 'x', () => glow.x = v);
      }
      editor.endMerge();
      for (var v in [610.0, 620.0]) {
        editor.perform('Edit x', mergeKey: 'x', () => glow.x = v);
      }
      expect(editor.doc.nodeNamed('glow')!.x, 620);
      editor.undo();
      expect(editor.doc.nodeNamed('glow')!.x, 603, reason: 'second gesture');
      editor.undo();
      expect(editor.doc.nodeNamed('glow')!.x, 600, reason: 'first gesture');
      expect(editor.canUndo, false);
    });

    test('undo restores the authored plane and leaves fx alone', () {
      var editor = SceneEditor(coffeeBannerDraft());
      var headline = editor.doc.nodeNamed('headline')!;
      var effect = headline.effect()..opacity = 0.5;
      editor.perform(
        'Edit opacity',
        () => editor.doc.nodeNamed('headline')!.opacity = 0.8,
      );
      editor.undo();
      var restored = editor.doc.nodeNamed('headline')!;
      // Restore REVIVES the same object — the writer's handle, the fx
      // entry and anything else holding the node keep working.
      expect(identical(restored, headline), true);
      expect(restored.opacity, 1.0);
      expect(effect.opacity, 0.5);
      expect(headline.fxRendered('opacity'), 0.5);
    });
  });

  group('editing verbs', () {
    test('deleteSelection removes all selected, one undo brings all back', () {
      var editor = SceneEditor(coffeeBannerDraft());
      editor.setSelection(['glow', 'badge']);
      editor.deleteSelection();
      expect(editor.doc.nodeNamed('glow'), isNull);
      expect(editor.doc.nodeNamed('badge'), isNull);
      expect(editor.selectionNames, isEmpty);
      editor.undo();
      expect(editor.doc.nodeNamed('glow'), isNotNull);
      expect(editor.doc.nodeNamed('badge'), isNotNull);
    });

    test('nudgeSelection moves absolute children only', () {
      var editor = SceneEditor(coffeeBannerDraft());
      // headline sits in the flex `copy` column; glow is absolute.
      editor.setSelection(['glow', 'headline']);
      var headlineX = editor.doc.nodeNamed('headline')!.x;
      editor.nudgeSelection(5, 0);
      expect(editor.doc.nodeNamed('glow')!.x, 605);
      expect(editor.doc.nodeNamed('headline')!.x, headlineX);
    });

    test('duplicateSelection renames the whole subtree and selects it', () {
      var editor = SceneEditor(coffeeBannerDraft());
      editor.setSelection(['cta']);
      editor.duplicateSelection();
      var copy = editor.doc.nodeNamed('cta1');
      expect(copy, isNotNull);
      expect(copy!.children.single.name, 'ctaLabel1');
      expect((copy.children.single as TextNode).text, 'Get the app');
      expect(editor.selectionNames, ['cta1']);
      editor.undo();
      expect(editor.doc.nodeNamed('cta1'), isNull);
    });
  });

  group('focus discipline in widgets', () {
    Widget harness(SceneEditor editor, {Widget Function()? beside}) =>
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            // The panels rebuild on editor changes, the way the shells do —
            // the inspector shows whatever is selected now.
            body: AnimatedBuilder(
              animation: editor.listenable,
              builder: (context, _) => Row(
                children: [
                  Expanded(
                    child: EditorShortcuts(
                      editor,
                      child: SceneTreePanel(editor),
                    ),
                  ),
                  if (beside != null) SizedBox(width: 320, child: beside()),
                ],
              ),
            ),
          ),
        );

    // The renderer beside the editor is SceneView, measuring onto the nodes
    // the way the guest does over the wire.
    Widget canvasHarness(SceneEditor editor, {Widget Function()? beside}) =>
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: AnimatedBuilder(
              animation: editor.listenable,
              builder: (context, _) => Row(
                children: [
                  Expanded(
                    child: EditorShortcuts(
                      editor,
                      child: SceneCanvas(
                        editor,
                        content: SceneView.document(
                          editor.doc,
                          onMeasured: (rects) =>
                              applyMeasuredRects(editor.doc, rects),
                        ),
                      ),
                    ),
                  ),
                  if (beside != null) SizedBox(width: 320, child: beside()),
                ],
              ),
            ),
          ),
        );

    testWidgets('modifier-click in the tree toggles a multi-selection', (
      tester,
    ) async {
      var editor = SceneEditor(coffeeBannerDraft());
      await tester.pumpWidget(harness(editor));
      await tester.tap(find.text('glow'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(find.text('badge'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(editor.selectionNames, ['glow', 'badge']);
    });

    testWidgets('delete, arrows and undo bind in the editing scope', (
      tester,
    ) async {
      var editor = SceneEditor(coffeeBannerDraft());
      await tester.pumpWidget(harness(editor));
      await tester.tap(find.text('glow'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(editor.doc.nodeNamed('glow')!.x, 601);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(editor.doc.nodeNamed('glow'), isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(editor.doc.nodeNamed('glow'), isNotNull);
    });

    testWidgets('the canvas takes the keyboard back after a field edit', (
      tester,
    ) async {
      // The reported bug, exactly: type in an inspector field, click the
      // CANVAS (which holds no focusable widget of its own, unlike a tree
      // row's InkWell), then press cmd+Z — the keys were still going to
      // the field's own undo, which beeps on macOS once it is empty.
      var editor = SceneEditor(coffeeBannerDraft());
      await tester.pumpWidget(
        canvasHarness(editor, beside: () => SceneInspector(editor)),
      );
      await tester.pump();
      editor.select(editor.doc.nodeNamed('headline'));
      await tester.pump();
      // The content field sits below the geometry; the inspector scrolls.
      // First of the two: the typeface field is the other one.
      await scrollInspectorTo(tester, find.text('Content'));
      await tester.enterText(
        find.byType(TextFormField).first,
        'Fresh coffee, sooner',
      );
      await tester.pump();
      expect(
        (editor.doc.nodeNamed('headline')! as TextNode).text,
        'Fresh coffee, sooner',
      );
      await tester.tapAt(const Offset(300, 500));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        (editor.doc.nodeNamed('headline')! as TextNode).text,
        'Fresh coffee, faster',
      );
    });

    testWidgets('the scope takes the keyboard back after a field edit', (
      tester,
    ) async {
      // The reported bug: type in an inspector field, click a node, press
      // cmd+Z — the keys were still going to the field's own undo (which
      // beeps on macOS once its history is empty) instead of the editor's.
      var editor = SceneEditor(coffeeBannerDraft());
      await tester.pumpWidget(
        harness(editor, beside: () => SceneInspector(editor)),
      );
      await tester.tap(find.text('headline'));
      await tester.pump();
      // First of the two: the typeface field is the other one.
      await scrollInspectorTo(tester, find.text('Content'));
      await tester.enterText(
        find.byType(TextFormField).first,
        'Fresh coffee, sooner',
      );
      await tester.pump();
      expect(
        (editor.doc.nodeNamed('headline')! as TextNode).text,
        'Fresh coffee, sooner',
      );
      await tester.tap(find.text('glow'));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(
        (editor.doc.nodeNamed('headline')! as TextNode).text,
        'Fresh coffee, faster',
      );
    });

    testWidgets('a text field outside the scope keeps its keys', (
      tester,
    ) async {
      var editor = SceneEditor(coffeeBannerDraft());
      var nodes = editor.doc.walk().length;
      await tester.pumpWidget(
        harness(editor, beside: () => const TextField(autofocus: false)),
      );
      await tester.tap(find.text('glow'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      // Backspace edits the text; the selected node stays.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(editor.doc.nodeNamed('glow'), isNotNull);
      expect(editor.doc.walk().length, nodes);
    });
  });
}

/// A binding is the stronger of the two: an edit through a door reaches the
/// parameter's default, every other reader follows, and undo brings the
/// default back with the node.
void bindingDoorTests() {
  group('bound properties', () {
    SceneEditor twins() {
      var a = FrameNode(name: 'a')
        ..width = 10
        ..height = 10
        ..fill = const SceneColor(0xFF112233)
        ..bindings['fill'] = const ParamRef('accent');
      var b = FrameNode(name: 'b')
        ..x = 20
        ..width = 10
        ..height = 10
        ..fill = const SceneColor(0xFF112233)
        ..bindings['fill'] = const ParamRef('accent');
      var root = FrameNode(name: 'root')
        ..width = 100
        ..height = 100
        ..children.addAll([a, b]);
      var doc = SceneDocument(root)
        ..params.add(
          SceneParamDecl(
            'accent',
            SceneParamKind.color,
            const SceneColor(0xFF112233),
          ),
        );
      return SceneEditor(doc);
    }

    test('a door on one reader moves the default and the other reader', () {
      var editor = twins();
      var a = editor.doc.nodeNamed('a')!;
      var b = editor.doc.nodeNamed('b')!;
      editor.perform('Edit fill', () => a.fill = const SceneColor(0xFFABCDEF));
      expect(b.fill, const SceneColor(0xFFABCDEF));
      expect(
        editor.doc.paramNamed('accent')!.defaultValue,
        const SceneColor(0xFFABCDEF),
      );
      expect(a.bindings['fill'], const ParamRef('accent'));
    });

    test('undo restores the default with the node, in one entry', () {
      var editor = twins();
      var a = editor.doc.nodeNamed('a')!;
      var b = editor.doc.nodeNamed('b')!;
      editor.perform('Edit fill', () => a.fill = const SceneColor(0xFFABCDEF));
      editor.undo();
      expect(a.fill, const SceneColor(0xFF112233));
      expect(b.fill, const SceneColor(0xFF112233));
      expect(
        editor.doc.paramNamed('accent')!.defaultValue,
        const SceneColor(0xFF112233),
      );
      expect(editor.canUndo, isFalse);
    });

    test('unbind keeps the value and frees the node from the parameter', () {
      var editor = twins();
      var a = editor.doc.nodeNamed('a')!;
      var b = editor.doc.nodeNamed('b')!;
      editor.perform('Unbind fill', () => a.bindings.remove('fill'));
      editor.perform('Edit fill', () => a.fill = const SceneColor(0xFFABCDEF));
      expect(a.bindings, isEmpty);
      expect(b.fill, const SceneColor(0xFF112233));
      expect(
        editor.doc.paramNamed('accent')!.defaultValue,
        const SceneColor(0xFF112233),
      );
    });
  });
}
