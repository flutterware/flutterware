import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Reaching the part of a line that does not fit.
///
/// Lines never wrap — a row whose height changes as it is built is a
/// virtualised list whose scrollbar jumps under your hand — so anything past
/// the pane's edge was simply cut off, with no scroll, no wrap and no tooltip.
/// These are the claims that replaced that: the body knows there is more, it
/// can be moved, it cannot be moved past the end, and every row moves together.
void main() {
  const worktree = Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  // Wider than any pane a test surface has.
  var longLine = 'final answer = ${'x' * 400};';

  var patch = [
    'diff --git a/lib/a.dart b/lib/a.dart',
    '--- a/lib/a.dart',
    '+++ b/lib/a.dart',
    '@@ -1,3 +1,4 @@',
    ' short',
    '-was here',
    '+$longLine',
    ' tail',
    '',
  ].join('\n');

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            load: (_) async => ChangeSet(
              worktreePath: worktree.path,
              patch: indexPatch(Uint8List.fromList(utf8.encode(patch))),
              base: 'master',
              baseSource: BaseSource.inferred,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('a.dart').first);
    await tester.pumpAndSettle();
  }

  /// The one model every row of the open file shares.
  DiffScrollX modelOf(WidgetTester tester) =>
      tester.widgetList<HunkLineView>(find.byType(HunkLineView)).first.scrollX!;

  testWidgets('a line wider than the pane says so', (tester) async {
    await pump(tester);
    expect(modelOf(tester).canScroll, isTrue);
  });

  testWidgets('a horizontal scroll moves the code', (tester) async {
    await pump(tester);
    var model = modelOf(tester);
    expect(model.x, 0);

    // The real path: a trackpad's horizontal component, read off the same
    // pointer signal the vertical list is reading its own half of.
    var pointer = TestPointer(1, PointerDeviceKind.mouse);
    var where = tester.getCenter(find.byType(HunkLineView).first);
    await tester.sendEventToBinding(pointer.hover(where));
    await tester.sendEventToBinding(pointer.scroll(const Offset(120, 0)));
    await tester.pump();

    expect(model.x, 120);
  });

  testWidgets('it stops at the end of the longest line', (tester) async {
    await pump(tester);
    var model = modelOf(tester);
    model.moveTo(1000000);
    expect(model.x, model.maxX);
    expect(model.maxX, greaterThan(0));

    model.moveTo(-500);
    expect(model.x, 0);
  });

  testWidgets('every row moves by the same amount', (tester) async {
    await pump(tester);
    var model = modelOf(tester);
    // **The point of one shared offset.** A scroll view per row would let a
    // short line clamp at its own width while a long one kept going, and the
    // indentation the monospace exists for would stop lining up.
    for (var row in tester.widgetList<HunkLineView>(
      find.byType(HunkLineView),
    )) {
      expect(identical(row.scrollX, model), isTrue);
    }
  });

  testWidgets('a new file opens at the left edge', (tester) async {
    await pump(tester);
    var model = modelOf(tester);
    model.moveTo(200);
    expect(model.x, 200);

    // Reading one file 200 px in says nothing about where the next one should
    // open — that column is whatever happens to be there.
    model.reset();
    expect(model.x, 0);
  });

  testWidgets('the diff can be selected', (tester) async {
    await pump(tester);
    // Nothing in a diff used to be: the rows are `Text`, and the app had no
    // selection region anywhere, so a line of code could not be copied out.
    expect(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(HunkLineView),
      ),
      findsWidgets,
    );
  });
}
