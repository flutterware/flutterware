import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The view's own claims: that the right pane shows the file you picked and
/// only that one, that the filter narrows the index without touching what you
/// are reading, and that a four-thousand-line file costs a screenful rather
/// than four thousand widgets.
void main() {
  const worktree = Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  PatchIndex index(String patch) =>
      indexPatch(Uint8List.fromList(utf8.encode(patch)));

  Future<void> pumpPatch(WidgetTester tester, PatchIndex patch) async {
    // Wider than the 800 px default: a markdown file's header now carries the
    // Source ⇄ Rendered toggle, which in the all-squares test font overflows
    // a pane the real font has slack in.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree,
            load: (_) async => ChangeSet(
              worktreePath: worktree.path,
              patch: patch,
              base: 'master',
              baseSource: BaseSource.inferred,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  var twoFiles = [
    'diff --git a/lib/alpha.dart b/lib/alpha.dart',
    '--- a/lib/alpha.dart',
    '+++ b/lib/alpha.dart',
    '@@ -1,3 +1,3 @@',
    ' keep',
    '-was here',
    '+is here now',
    ' tail',
    'diff --git a/lib/beta.dart b/lib/beta.dart',
    '--- a/lib/beta.dart',
    '+++ b/lib/beta.dart',
    '@@ -1 +1 @@',
    '-old beta',
    '+new beta',
    '',
  ].join('\n');

  /// Scoped to the left column, because the right pane's header draws the same
  /// filename — which is the point of it.
  Finder inIndex(String text) => find.descendant(
    of: find.byKey(changesListKey),
    matching: find.text(text),
  );

  testWidgets('nothing is read until a file is picked', (tester) async {
    await pumpPatch(tester, index(twoFiles));

    expect(find.byType(DiffLineView), findsNothing);
    expect(find.text('Pick a file'), findsOneWidget);

    await tester.tap(find.text('alpha.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(DiffLineView), findsWidgets);
    expect(find.text('is here now'), findsOneWidget);
    expect(find.text('was here'), findsOneWidget);
    // **One file at a time.** The other one's diff is not below this one, it
    // is not anywhere — which is the whole difference from the list that used
    // to inline every expansion.
    expect(find.text('new beta'), findsNothing);
  });

  testWidgets('picking another replaces it rather than adding to it', (
    tester,
  ) async {
    await pumpPatch(tester, index(twoFiles));
    await tester.tap(find.text('alpha.dart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('beta.dart'));
    await tester.pumpAndSettle();

    expect(find.text('new beta'), findsOneWidget);
    expect(find.text('is here now'), findsNothing);
  });

  testWidgets('the hunk header is drawn from the span, with its context', (
    tester,
  ) async {
    await pumpPatch(
      tester,
      index(
        [
          'diff --git a/lib/a.dart b/lib/a.dart',
          '--- a/lib/a.dart',
          '+++ b/lib/a.dart',
          '@@ -12,2 +12,2 @@ class StreamParser {',
          ' a',
          '-b',
          '+B',
          '',
        ].join('\n'),
      ),
    );

    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();

    expect(find.text('@@ -12,2 +12,2 @@'), findsOneWidget);
    expect(find.text('class StreamParser {'), findsOneWidget);
  });

  testWidgets('picking the same file again keeps it open', (tester) async {
    // **Never a toggle.** Clicking a name means "show me that file", and
    // meaning "hide it" the second time is the opposite of the ask.
    await pumpPatch(tester, index(twoFiles));

    await tester.tap(inIndex('alpha.dart'));
    await tester.pumpAndSettle();
    await tester.tap(inIndex('alpha.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(DiffLineView), findsWidgets);
  });

  testWidgets('the filter narrows the index and leaves the pane alone', (
    tester,
  ) async {
    // The filter is for finding the *next* file. Taking away the one you are
    // reading because it stopped matching would be a search box that closes
    // your document.
    await pumpPatch(tester, index(twoFiles));
    await tester.tap(find.text('alpha.dart'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pumpAndSettle();

    expect(inIndex('alpha.dart'), findsNothing, reason: 'gone from the index');
    expect(
      find.text('is here now'),
      findsOneWidget,
      reason: 'and still open on the right',
    );
  });

  testWidgets('a filter that matches nothing says so', (tester) async {
    await pumpPatch(tester, index(twoFiles));

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('Nothing matches.'), findsOneWidget);
  });

  testWidgets('a four-thousand-line file costs a screenful', (tester) async {
    // The whole reason the rows are flat and the text is decoded per hunk.
    var lines = <String>[
      'diff --git a/lib/huge.dart b/lib/huge.dart',
      '--- a/lib/huge.dart',
      '+++ b/lib/huge.dart',
      '@@ -1,2000 +1,2000 @@',
    ];
    for (var i = 0; i < 2000; i++) {
      lines
        ..add('-line $i was')
        ..add('+line $i is');
    }
    lines.add('');

    await pumpPatch(tester, index(lines.join('\n')));
    await tester.tap(find.text('huge.dart'));
    await tester.pumpAndSettle();

    var built = tester.widgetList<DiffLineView>(find.byType(DiffLineView));
    expect(built, isNotEmpty);
    expect(
      built.length,
      lessThan(200),
      reason: '4,000 lines exist; only what fits on screen was built',
    );
  });
  group('syntax colour', () {
    testWidgets('a Dart line is drawn as spans, not one string', (
      tester,
    ) async {
      await pumpPatch(
        tester,
        index(
          [
            'diff --git a/lib/a.dart b/lib/a.dart',
            '--- a/lib/a.dart',
            '+++ b/lib/a.dart',
            '@@ -1,2 +1,2 @@',
            ' void main() {}',
            "-var a = 'old';",
            "+var a = 'new';",
            '',
          ].join('\n'),
        ),
      );
      await tester.tap(find.text('a.dart'));
      await tester.pumpAndSettle();

      var row = tester
          .widgetList<DiffLineView>(find.byType(DiffLineView))
          .firstWhere((it) => it.line.text == "var a = 'new';");
      expect(row.tokens, isNotNull);
      expect([
        for (var token in row.tokens!) token.className,
      ], contains('keyword'));
      // The text still reads as itself — `find.text` sees through the spans,
      // and so does the semantics tree the drive tools read.
      expect(find.text("var a = 'new';"), findsOneWidget);
    });

    testWidgets('a file with no grammar keeps its plain text', (tester) async {
      await pumpPatch(
        tester,
        index(
          [
            'diff --git a/notes.md b/notes.md',
            '--- a/notes.md',
            '+++ b/notes.md',
            '@@ -1 +1 @@',
            '-was prose',
            '+is prose',
            '',
          ].join('\n'),
        ),
      );
      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();

      var row = tester
          .widgetList<DiffLineView>(find.byType(DiffLineView))
          .firstWhere((it) => it.line.text == 'is prose');
      expect(row.tokens, isNull);
      expect(find.text('is prose'), findsOneWidget);
    });

    testWidgets('a wholly added file is coloured, however long it is', (
      tester,
    ) async {
      // There is no size at which this screen stops colouring, so there is
      // nothing for the header to announce. It briefly had a
      // `not coloured · 600-line hunk` note beside a 500-line cap; the chunked
      // tokeniser removed the cap and the note with it.
      var lines = [
        'diff --git a/lib/huge.dart b/lib/huge.dart',
        '--- a/lib/huge.dart',
        '+++ b/lib/huge.dart',
        '@@ -0,0 +1,600 @@',
      ];
      for (var i = 0; i < 600; i++) {
        lines.add('+var v$i = $i;');
      }
      lines.add('');

      await pumpPatch(tester, index(lines.join('\n')));
      await tester.tap(find.text('huge.dart'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not coloured'), findsNothing);
      var row = tester
          .widgetList<DiffLineView>(find.byType(DiffLineView))
          .firstWhere((it) => it.line.text == 'var v0 = 0;');
      expect([
        for (var token in row.tokens!) token.className,
      ], contains('keyword'));
    });

    testWidgets('only the hunks on screen are tokenised', (tester) async {
      // The same claim `HunkLineCache` makes, and it has to survive the second
      // cache sitting beside it: a 4,000-line file must not be parsed to draw
      // its first screenful.
      var lines = [
        'diff --git a/lib/huge.dart b/lib/huge.dart',
        '--- a/lib/huge.dart',
        '+++ b/lib/huge.dart',
      ];
      for (var hunk = 0; hunk < 40; hunk++) {
        lines.add('@@ -${hunk * 100 + 1},2 +${hunk * 100 + 1},2 @@');
        lines
          ..add('-var was$hunk = 0;')
          ..add('+var is$hunk = 1;');
      }
      lines.add('');

      await pumpPatch(tester, index(lines.join('\n')));
      await tester.tap(find.text('huge.dart'));
      await tester.pumpAndSettle();

      var built = tester
          .widgetList<DiffLineView>(find.byType(DiffLineView))
          .where((it) => it.tokens != null);
      expect(built, isNotEmpty);
      expect(
        built.length,
        lessThan(120),
        reason: '40 hunks exist; only the ones on screen were tokenised',
      );
    });
  });

  testWidgets('a header that overstates its hunk says so instead of crashing', (
    tester,
  ) async {
    // Truncated mid-hunk, or written by something that is not git: the counts
    // promise nine lines and the body has three. Row extents come from the
    // header, so this used to index past the end of the decoded lines and throw
    // while scrolling.
    await pumpPatch(
      tester,
      index(
        [
          'diff --git a/lib/a.dart b/lib/a.dart',
          '--- a/lib/a.dart',
          '+++ b/lib/a.dart',
          '@@ -1,9 +1,9 @@',
          ' a',
          '-b',
          '+B',
          '',
        ].join('\n'),
      ),
    );

    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('ended before its header said'),
      findsOneWidget,
      reason: 'drawn, not silently swallowed',
    );
  });
}
