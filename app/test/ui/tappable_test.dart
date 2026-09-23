import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// What a tap target owes a pointer, and the two ways it stopped paying.
///
/// The cursor group is a regression test with a real report behind it: the
/// comment affordance in a diff showed the text I-beam, because a [Text] under
/// a [SelectionArea] wraps itself in a text-cursor [MouseRegion] that sits
/// *below* the button's own — and the mouse tracker takes the innermost one.
/// Nothing about that is visible from the call site, which is why it is pinned
/// here rather than in the screen that reported it.
void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  /// A mouse parked off-target, ready to be moved onto one.
  Future<TestGesture> mouse(WidgetTester tester) async {
    var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await tester.pump();
    return gesture;
  }

  MouseCursor? cursorNow() =>
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

  /// The colours actually painted over the child, innermost last.
  List<Color?> washes(WidgetTester tester) => [
    for (var box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)))
      (box.decoration as BoxDecoration).color,
  ];

  group('cursor', () {
    testWidgets('is the click cursor over a label', (tester) async {
      await mount(tester, Tappable(onTap: () {}, child: const Text('Delete')));

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Delete')));
      await tester.pump();

      expect(cursorNow(), SystemMouseCursors.click);
    });

    testWidgets('is still the click cursor inside a SelectionArea', (
      tester,
    ) async {
      await mount(
        tester,
        SelectionArea(
          child: Tappable(onTap: () {}, child: const Text('Delete')),
        ),
      );

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Delete')));
      await tester.pump();

      expect(
        cursorNow(),
        SystemMouseCursors.click,
        reason: 'the button lost the cursor to its own selectable label',
      );
    });

    testWidgets('selectableChild hands the label back to the selection', (
      tester,
    ) async {
      await mount(
        tester,
        SelectionArea(
          child: Tappable(
            onTap: () {},
            selectableChild: true,
            child: const Text('Delete'),
          ),
        ),
      );

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Delete')));
      await tester.pump();

      expect(cursorNow(), SystemMouseCursors.text);
    });

    testWidgets('is the basic cursor while disabled', (tester) async {
      await mount(tester, const Tappable(onTap: null, child: Text('Delete')));

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Delete')));
      await tester.pump();

      expect(cursorNow(), SystemMouseCursors.basic);
    });
  });

  group('feedback', () {
    testWidgets('washes on hover and deeper while pressed', (tester) async {
      await mount(tester, Tappable(onTap: () {}, child: const Text('Save')));
      var colors = appTheme.extension<FwTokens>()!.palette;

      expect(washes(tester), isNot(contains(colors.hoverOverlay)));

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Save')));
      await tester.pump();
      expect(washes(tester), contains(colors.hoverOverlay));

      await gesture.down(tester.getCenter(find.text('Save')));
      await tester.pump();
      expect(washes(tester), contains(colors.pressedOverlay));

      await gesture.up();
      await tester.pump();
      expect(washes(tester), contains(colors.hoverOverlay));
    });

    testWidgets('paints nothing while disabled', (tester) async {
      await mount(tester, const Tappable(onTap: null, child: Text('Save')));
      var colors = appTheme.extension<FwTokens>()!.palette;

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Save')));
      await tester.pump();

      expect(washes(tester), isNot(contains(colors.hoverOverlay)));
    });

    // The mode-pill regression: picking a pill disables it, the pointer left
    // while it was deaf, and picking another pill re-enabled it still washed.
    testWidgets('re-enabling after the pointer left does not resurrect hover', (
      tester,
    ) async {
      var enabled = true;
      late StateSetter outer;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            outer = setState;
            return Tappable(
              onTap: enabled ? () {} : null,
              child: const Text('Save'),
            );
          },
        ),
      );
      var colors = appTheme.extension<FwTokens>()!.palette;

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Save')));
      await tester.pump();
      expect(washes(tester), contains(colors.hoverOverlay));

      outer(() => enabled = false);
      await tester.pump();
      await gesture.moveTo(Offset.zero);
      await tester.pump();

      outer(() => enabled = true);
      await tester.pump();
      expect(washes(tester), isNot(contains(colors.hoverOverlay)));
    });

    testWidgets('the builder draws its own, so the primitive does not', (
      tester,
    ) async {
      await mount(
        tester,
        Tappable.builder(
          onTap: () {},
          builder: (context, hovered) => Text(hovered ? 'on' : 'off'),
        ),
      );
      var colors = appTheme.extension<FwTokens>()!.palette;

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('off')));
      await tester.pump();

      expect(find.text('on'), findsOneWidget);
      expect(washes(tester), isNot(contains(colors.hoverOverlay)));
    });

    testWidgets('a builder can hand the wash back and keep the flag', (
      tester,
    ) async {
      await mount(
        tester,
        Tappable.builder(
          onTap: () {},
          feedback: TapFeedback.overlay,
          builder: (context, hovered) => Text(hovered ? 'on' : 'off'),
        ),
      );
      var colors = appTheme.extension<FwTokens>()!.palette;

      var gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('off')));
      await tester.pump();

      expect(find.text('on'), findsOneWidget);
      expect(washes(tester), contains(colors.hoverOverlay));
    });
  });

  group('keyboard', () {
    testWidgets('Enter and Space do what a tap does', (tester) async {
      var taps = 0;
      var node = FocusNode();
      addTearDown(node.dispose);
      await mount(
        tester,
        Tappable(
          onTap: () => taps++,
          focusNode: node,
          child: const Text('Save'),
        ),
      );

      node.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(taps, 2);
    });

    testWidgets('focusable: false keeps it out of the traversal', (
      tester,
    ) async {
      var node = FocusNode();
      addTearDown(node.dispose);
      await mount(
        tester,
        Tappable(
          onTap: () {},
          focusable: false,
          focusNode: node,
          child: const Text('Save'),
        ),
      );

      expect(node.canRequestFocus, isFalse);
      expect(node.skipTraversal, isTrue);
    });

    testWidgets('a tap does not take focus, so the ring stays keyboard-only', (
      tester,
    ) async {
      var node = FocusNode();
      addTearDown(node.dispose);
      await mount(
        tester,
        Tappable(onTap: () {}, focusNode: node, child: const Text('Save')),
      );

      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(node.hasFocus, isFalse);
    });
  });
}
