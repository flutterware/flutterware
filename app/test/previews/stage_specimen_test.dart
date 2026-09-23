import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/previews/stage_ground.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The edge around a preview, and the half of it that had no owner.
///
/// The guest's input region requests focus on a pointer-down inside the picture
/// and nothing in the studio ever takes it back — no panel control is focusable
/// — so before [StageSpecimen] owned the release, a ring lit by one click
/// stayed lit until the panel was torn down. Reported from use: *"when the blue
/// border appears it never removes it, only when we leave the previews feature
/// and re-enter."*
void main() {
  late FocusNode focus;

  setUp(() => focus = FocusNode(debugLabel: 'guest'));
  tearDown(() => focus.dispose());

  /// The specimen at a known size with room around it, so "outside" is a place
  /// a pointer can actually be put.
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: Center(
            // What the embedder's input region is, minus the embedder: the
            // node is hosted by a `Focus` — an unattached node cannot take
            // focus at all — and a press inside the picture asks for it.
            child: StageSpecimen(
              focus: focus,
              child: Focus(
                focusNode: focus,
                child: Listener(
                  onPointerDown: (_) => focus.requestFocus(),
                  // Painted, because a `Listener` defers its hit test to its
                  // child and a bare `SizedBox` answers no: the guest's own
                  // picture is a `Texture`, and a transparent stand-in would
                  // test a press that never lands.
                  child: const ColoredBox(
                    color: Color(0xFFFFFFFF),
                    child: SizedBox(width: 200, height: 200),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The colour of the line drawn over the picture's edge.
  Color? edgeColor(WidgetTester tester) {
    var box = tester.widget<Container>(
      find.ancestor(
        of: find.byType(Listener).last,
        matching: find.byType(Container),
      ),
    );
    var decoration = box.foregroundDecoration! as BoxDecoration;
    return decoration.border!.top.color;
  }

  testWidgets('the edge is a hairline until the guest holds the keyboard', (
    tester,
  ) async {
    await mount(tester);
    expect(edgeColor(tester), defaultTokens.palette.line);

    await tester.tap(find.byType(StageSpecimen));
    await tester.pump();

    expect(focus.hasFocus, isTrue);
    expect(edgeColor(tester), defaultTokens.palette.accent);
  });

  testWidgets('a press outside the picture gives the keyboard back', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byType(StageSpecimen));
    await tester.pump();
    expect(focus.hasFocus, isTrue, reason: 'the click on the picture');

    // The pane around the stage — the entry list, the top bar, the inspect
    // dock. None of it is focusable, which is exactly why the ring used to
    // stay lit: there was nothing for the focus to move *to*.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();

    expect(focus.hasFocus, isFalse);
    expect(edgeColor(tester), defaultTokens.palette.line);
  });

  testWidgets('a second press on the picture keeps it', (tester) async {
    await mount(tester);
    await tester.tap(find.byType(StageSpecimen));
    await tester.pump();
    await tester.tap(find.byType(StageSpecimen));
    await tester.pump();

    expect(focus.hasFocus, isTrue);
    expect(edgeColor(tester), defaultTokens.palette.accent);
  });
}
