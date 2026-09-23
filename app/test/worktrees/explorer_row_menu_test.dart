import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

/// The row's hover-only controls, and the one that has to outlive the hover.
///
/// Written after "Remove worktree… disappears before I can click it". The
/// controls are hover-only by design — a button beside every row is a wall
/// rather than a list — but a menu opens into an *overlay*, and moving the
/// pointer from the trigger to the item leaves the row. Hover ends, the trigger
/// unmounts, and the menu goes with it, so the item can be seen and never
/// reached.
///
/// That is not a hover bug, it is a lifetime bug: anything that opens something
/// else has to stay mounted for as long as the thing it opened.
void main() {
  var now = DateTime(2026, 8, 11, 9, 0);

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onRemove,
    bool isMain = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: SizedBox(
            width: 1200,
            child: WorktreeRow(
              label: 'A worktree',
              branch: 'claude/thing',
              path: '/repo/thing',
              isMain: isMain,
              facts: const WorktreeFacts(),
              now: now,
              onRemove: onRemove,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Moves a synthetic pointer onto the row, which is what makes the hover-only
  /// controls appear.
  Future<TestGesture> hoverRow(WidgetTester tester) async {
    var gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(WorktreeRow)));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('the menu trigger is hidden until the row is hovered', (
    tester,
  ) async {
    await pump(tester, onRemove: () {});
    expect(find.byIcon(Icons.more_horiz), findsNothing);

    await hoverRow(tester);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
  });

  testWidgets('the menu survives the pointer leaving the row', (tester) async {
    var removed = 0;
    await pump(tester, onRemove: () => removed++);
    var gesture = await hoverRow(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree…'), findsOneWidget);

    // The item is in an overlay above the row, so reaching for it takes the
    // pointer off the row. The menu has to still be there when it arrives.
    await gesture.moveTo(const Offset(1199, 1));
    await tester.pumpAndSettle();
    expect(
      find.text('Remove worktree…'),
      findsOneWidget,
      reason: 'the menu closed as soon as the row lost hover',
    );

    await tester.tap(find.text('Remove worktree…'));
    await tester.pumpAndSettle();
    expect(removed, 1);
  });

  testWidgets('the trigger does not move when the hover ends', (tester) async {
    // The jump that made it unclickable even once it stayed mounted: the
    // hover-only `Open` button vacated its space, shifting the trigger right —
    // out from under the cursor that was on its way to it.
    await pump(tester, onRemove: () {});
    var gesture = await hoverRow(tester);
    var hovered = tester.getCenter(find.byIcon(Icons.more_horiz));

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(1199, 1));
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.byIcon(Icons.more_horiz)),
      hovered,
      reason: 'the trigger moved when the row lost hover',
    );
  });

  testWidgets('opening the menu does not expand the row', (tester) async {
    // The whole row is a tap target for expand/collapse, so the trigger has to
    // win its own taps.
    var expanded = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: SizedBox(
            width: 1200,
            child: WorktreeRow(
              label: 'A worktree',
              path: '/repo/thing',
              facts: const WorktreeFacts(),
              now: now,
              onRemove: () {},
              onToggleExpand: () => expanded++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await hoverRow(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Remove worktree…'), findsOneWidget);
    expect(expanded, 0);
  });

  testWidgets('a row with no remove callback offers no menu', (tester) async {
    // The primary checkout cannot be removed, so it carries no affordance
    // rather than a disabled one.
    await pump(tester, isMain: true);
    await hoverRow(tester);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  /// The column budget, guarded.
  ///
  /// The actions column had to grow to fit a menu trigger, and it comes out of
  /// the one flexible column — so there is an upper bound as well as a lower
  /// one, and neither is visible from reading the widths. Both were found by
  /// measuring; this keeps them found, because a row that clips is a control
  /// the user reaches for and misses.
  ///
  /// One row per pump, which is how the list renders it. Stacking several in a
  /// `Column` overflows for a reason of its own and would guard the wrong
  /// thing.
  // **A widget test's surface is 800×600 unless told otherwise**, so every
  // width here sets the view as well as the box — without that, four "widths"
  // are four runs at 800 and the narrow case is the only one ever measured.
  for (var width in [640.0, 800.0, 1000.0, 1400.0]) {
    for (var (name, isMain, isCurrent) in const [
      // The rows carrying a trailing marker beside the name. `current` is the
      // one that used to clip: it is a fixed 75px that cannot ellipsise, so it
      // overflowed whenever the columns had squeezed the name cell below it.
      ('main', true, false),
      ('current', false, true),
      ('plain', false, false),
    ]) {
      testWidgets('the $name row fits at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            home: Material(
              child: SizedBox(
                width: width,
                child: WorktreeRow(
                  label: 'A worktree with a reasonably long name',
                  branch: 'claude/some-longish-branch-name-a1b2c3',
                  path: '/repo/thing',
                  isMain: isMain,
                  isCurrent: isCurrent,
                  facts: const WorktreeFacts(),
                  now: now,
                  onRemove: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  /// Columns actually leave, rather than the row hoping they fit.
  ///
  /// Asserted on behaviour and not on a screenshot: a picture proves one width
  /// on one build, and the rule this guards is arithmetic over seven columns.
  testWidgets('the widest column goes first when the row is short', (
    tester,
  ) async {
    Future<void> pumpAt(double width) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Material(
            child: WorktreeRow(
              label: 'A worktree',
              branch: 'claude/thing',
              path: '/repo/thing',
              isCurrent: true,
              facts: WorktreeFacts(
                git: Fact.fresh(const GitFacts(ahead: 1, dirty: 2)),
              ),
              now: now,
              onRemove: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // Roomy: the fingerprint is there.
    await pumpAt(1400);
    expect(find.byKey(changesCellKey), findsOneWidget);

    // Squeezed: `changes` is the widest and the least load-bearing — the
    // screen exists to say which checkout needs you, and that is the agent and
    // the PR.
    await pumpAt(700);
    expect(find.byKey(changesCellKey), findsNothing);
  });
}
