import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/worktrees/explorer_row.dart';
import 'package:flutterware_app/src/worktrees/explorer_screen.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';

/// The explorer, driven without a mouse.
///
/// The rule these pin down: **the keyboard does what the pointer does, by the
/// same split.** Clicking a row expands it and only the Open button opens it,
/// because opening costs a config subprocess and a tab — so Enter expands and
/// ⌘↵ opens.
void main() {
  var now = DateTime(2026, 8, 10, 14, 30);

  /// The three worktrees, in the order the list will show them.
  var entries = [
    _entry('alpha', now, seconds: 5),
    _entry('beta', now, seconds: 60),
    _entry('gamma', now, seconds: 7200),
  ];

  late List<String> opened;
  late List<String> changes;
  late String query;

  Future<void> pump(WidgetTester tester, {List<ExplorerEntry>? rows}) async {
    opened = [];
    changes = [];
    query = '';
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) => WorktreeExplorerView(
              entries: rows ?? entries,
              now: now,
              query: query,
              onQueryChanged: (value) => setState(() => query = value),
              onOpen: (entry) => opened.add(entry.worktree.branch!),
              onOpenChanges: (entry) => changes.add(entry.worktree.branch!),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Which row the keyboard is on, read off the rendered rows rather than off
  /// the state — this is what someone looking at the screen can see.
  String? cursor(WidgetTester tester) {
    for (var row in tester.widgetList<WorktreeRow>(find.byType(WorktreeRow))) {
      if (row.cursor) return row.branch;
    }
    return null;
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool meta = false,
  }) async {
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(key);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();
  }

  testWidgets('the filter has the keyboard on arrival', (tester) async {
    await pump(tester);

    // Typing filters without reaching for anything first.
    await tester.enterText(find.byType(TextField), 'gam');
    await tester.pumpAndSettle();
    expect(find.byType(WorktreeRow), findsOneWidget);
  });

  testWidgets('down and up walk the list, and stop at the ends', (
    tester,
  ) async {
    await pump(tester);
    expect(cursor(tester), isNull, reason: 'nothing is selected to begin with');

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'alpha');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'beta');

    // Clamped, not wrapped: a cursor that reappears at the other end of a list
    // is a cursor you have to go looking for.
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'gamma');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(cursor(tester), 'beta');
  });

  testWidgets('up from nothing starts at the bottom', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(cursor(tester), 'gamma');
  });

  testWidgets('enter expands, and expands only', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);

    expect(find.text('PATH'), findsOneWidget, reason: 'the detail opened');
    expect(opened, isEmpty, reason: 'and no worktree was opened');

    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('PATH'), findsNothing, reason: 'and it closes again');
  });

  testWidgets('meta-enter opens, and does not expand', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter, meta: true);

    expect(opened, ['beta']);
    expect(find.text('PATH'), findsNothing);
  });

  testWidgets('enter with no cursor does nothing at all', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.enter);
    expect(opened, isEmpty);
    expect(find.text('PATH'), findsNothing);
  });

  testWidgets('c opens what the cursor row changed', (tester) async {
    // It used to open a hover card over the list, which held its own
    // `ChangesController` and ran the full probe. The card is gone; `c` goes
    // where the card's own footer link went.
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.keyC);

    expect(changes, ['alpha']);
    expect(opened, isEmpty, reason: 'c is not open');
  });

  testWidgets('c with no cursor types instead, because the filter wants it', (
    tester,
  ) async {
    // A bare letter can only be a binding in the state where the keyboard is
    // driving the list rather than the field.
    await pump(tester);
    await press(tester, LogicalKeyboardKey.keyC);
    expect(changes, isEmpty);
  });

  testWidgets('escape clears the filter', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'gam');
    await tester.pumpAndSettle();
    expect(find.byType(WorktreeRow), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(WorktreeRow), findsNWidgets(3));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
      reason: 'the field shows the cleared query too',
    );
  });

  testWidgets('the cursor follows the worktree, not the row number', (
    tester,
  ) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'beta');

    // A watcher fires and `gamma` becomes the freshest, so every row moves.
    await pump(
      tester,
      rows: [
        _entry('alpha', now, seconds: 300),
        _entry('beta', now, seconds: 360),
        _entry('gamma', now, seconds: 5),
      ],
    );
    // Deliberately not re-selecting: the cursor is a path, so it is still on
    // the worktree you put it on, wherever that row went. An index would have
    // left it pointing at whatever slid into second place.
    expect(cursor(tester), 'beta');
  });

  testWidgets('a filter that excludes the cursor does not strand enter', (
    tester,
  ) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'alpha');

    await tester.enterText(find.byType(TextField), 'gam');
    await tester.pumpAndSettle();
    expect(cursor(tester), isNull, reason: 'the cursor row is filtered out');

    // Enter must not fire on a row nobody can see.
    await press(tester, LogicalKeyboardKey.enter);
    expect(opened, isEmpty);
    expect(find.text('PATH'), findsNothing);

    // And Down starts again inside what is left.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(cursor(tester), 'gamma');
  });

  testWidgets('the keys are written down where you can see them', (
    tester,
  ) async {
    // Reset inside the body: the framework asserts on leftover foundation
    // overrides before `addTearDown` gets a turn.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await pump(tester);
    var found = find.textContaining('⌘↵ open').evaluate().length;
    debugDefaultTargetPlatformOverride = null;
    expect(found, 1);
  });

  testWidgets('and they name the modifier this keyboard has', (tester) async {
    // The handler takes either modifier everywhere; the hint must not promise a
    // key that is not on the machine.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pump(tester);
    var found = find.textContaining('ctrl+↵ open').evaluate().length;
    debugDefaultTargetPlatformOverride = null;
    expect(found, 1);
  });

  testWidgets('and control opens on any platform', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(opened, ['alpha']);
  });
}

ExplorerEntry _entry(String branch, DateTime now, {required int seconds}) =>
    ExplorerEntry(
      worktree: Worktree(
        path: '/repo/$branch',
        gitName: branch,
        branch: branch,
      ),
      facts: WorktreeFacts(
        activity: Fact.fresh(
          ActivityFacts(
            at: now.subtract(Duration(seconds: seconds)),
            source: ActivitySource.commit,
          ),
        ),
      ),
    );
