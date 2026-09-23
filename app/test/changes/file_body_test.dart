import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/changes/review_comment.dart';
import 'package:flutterware_app/src/changes/review_store.dart';
import 'package:flutterware_app/src/changes/review_view.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// The bodies a diff cannot draw, against a **real directory**: these tests
/// exist because the pane used to show an untracked file nothing at all, and
/// a placeholder saying "every line is new" is not a line of the file.
///
/// The later ones exist for the next thing that was missing: an untracked file
/// was drawn in one grey, with nothing to click in its margin, so whether an
/// agent had got as far as `git add` decided what you could do with the file
/// on your screen.
void main() {
  late Directory temp;
  late ReviewStore store;

  // Sync IO throughout the setup: a widget test's body runs under FakeAsync,
  // where a real async file operation never completes and the test hangs in
  // `setUp` before its first line.
  setUp(() {
    temp = Directory.systemTemp.createTempSync('file_body_test');
    // Never the developer's real `~/.flutterware`.
    store = ReviewStore(File('${temp.path}/review.jsonl'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Worktree worktree() =>
      Worktree(path: temp.path, gitName: 'feature', branch: 'claude/feature');

  FileChange file(String path, {required ChangeStatus status}) => FileChange(
    path: path,
    status: status,
    added: 1,
    removed: 0,
    hunks: [
      HunkSpan(
        oldStart: 1,
        oldCount: 0,
        newStart: 1,
        newCount: 1,
        added: 1,
        removed: 0,
        byteStart: 0,
        byteEnd: 0,
      ),
    ],
    byteStart: 0,
    byteEnd: 0,
  );

  ChangeSet setOf({
    List<FileChange> files = const [],
    List<UntrackedEntry> untracked = const [],
  }) => ChangeSet(
    worktreePath: temp.path,
    patch: PatchIndex.empty,
    base: 'master',
    baseSource: BaseSource.inferred,
    files: files,
    untracked: untracked,
  );

  /// What the screen's next read will find. Held rather than passed straight
  /// in, so a test can move the checkout under a mounted screen and press
  /// refresh — which is the only way to make it read again.
  late ChangeSet current;

  Future<void> refresh(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Read this checkout again'));
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester,
    ChangeSet set, {
    required String open,
  }) async {
    current = set;
    // A realistic pane, not the 800 px default: the test font draws every
    // glyph as a full square, so the header's toggle and button measure far
    // wider here than they ever do in the app — see the header overflow that
    // only Ahem could produce.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: ChangesScreen(
            worktree: worktree(),
            live: false,
            initialPath: open,
            reviewStore: store,
            load: (_) async => current,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every colour one drawn line is painted in.
  ///
  /// A line nothing coloured is one span; a coloured one is several, and that
  /// is the only difference between the two bodies worth asserting — which
  /// *keyword* green it is belongs to the palette, not to this screen.
  Set<Color?> inkOf(WidgetTester tester, String text) {
    for (var rich in tester.widgetList<RichText>(find.byType(RichText))) {
      if (rich.text.toPlainText() != text) continue;
      var ink = <Color?>{};
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) ink.add(span.style?.color);
        return true;
      });
      return ink;
    }
    return const {};
  }

  /// Opens the composer on the [n]th line drawn in the body, 0-based.
  Future<void> plus(WidgetTester tester, int n) async {
    await tester.tap(
      find
          .byTooltip('Comment on this line — shift-click to extend a span')
          .at(n),
    );
    await tester.pumpAndSettle();
  }

  /// Lets the real file reads behind the body complete, then draws them.
  ///
  /// Plain `pumpAndSettle` cannot: the test body runs under FakeAsync, where
  /// real IO futures never fire. And one `runAsync` is not enough either —
  /// a future created in the fake zone resumes only on a pump, so a chain of
  /// awaits (stat, then read, then the builder's own `then`) advances one
  /// link per window. Alternate until the chain is longer than any body has.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('an untracked markdown file opens rendered', (tester) async {
    File('${temp.path}/notes.md')
        .writeAsStringSync('# A heading\n\nA paragraph of prose.\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('notes.md')]),
      open: 'notes.md',
    );
    await settleIo(tester);

    // Rendered: the heading's text without its `#`.
    expect(find.textContaining('A heading', findRichText: true), findsOne);
    expect(
      find.textContaining('# A heading', findRichText: true),
      findsNothing,
    );
    // And the toggle offers the other face.
    expect(find.text('Source'), findsOne);
    expect(find.text('Rendered'), findsOne);
  });

  testWidgets('the toggle flips a markdown body to its lines', (tester) async {
    File('${temp.path}/notes.md').writeAsStringSync('# A heading\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('notes.md')]),
      open: 'notes.md',
    );
    await settleIo(tester);

    await tester.tap(find.text('Source'));
    await settleIo(tester);

    // The source face is the file's own line, marker and all.
    expect(find.text('# A heading'), findsOne);
  });

  testWidgets('an untracked text file shows its numbered lines', (
    tester,
  ) async {
    File('${temp.path}/scratch.txt').writeAsStringSync('first\nsecond\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('scratch.txt')]),
      open: 'scratch.txt',
    );
    await settleIo(tester);

    expect(find.text('first'), findsOne);
    expect(find.text('second'), findsOne);
    expect(find.text('2'), findsOne);
    // No toggle: a plain text file has one face.
    expect(find.text('Source'), findsNothing);
  });

  testWidgets('an untracked source file is coloured, the same as a diff of '
      'one would be', (tester) async {
    File('${temp.path}/migration.dart')
        .writeAsStringSync("var greeting = 'hello';\n");
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('migration.dart')]),
      open: 'migration.dart',
    );
    await settleIo(tester);

    expect(
      inkOf(tester, "var greeting = 'hello';"),
      hasLength(greaterThan(1)),
      reason: 'the keyword and the string are not the same ink',
    );
  });

  testWidgets('a file in no language we read stays one plain grey', (
    tester,
  ) async {
    // Not an error and not a guess: a highlighter that has an opinion about
    // every file is a highlighter that is wrong about some of them.
    File('${temp.path}/scratch.txt').writeAsStringSync('var greeting = 1;\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('scratch.txt')]),
      open: 'scratch.txt',
    );
    await settleIo(tester);

    expect(inkOf(tester, 'var greeting = 1;'), hasLength(1));
  });

  testWidgets('a line of an untracked file takes a note, drawn under it', (
    tester,
  ) async {
    File('${temp.path}/scratch.txt').writeAsStringSync('one\ntwo\nthree\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('scratch.txt')]),
      open: 'scratch.txt',
    );
    await settleIo(tester);

    await plus(tester, 1);
    await tester.enterText(
      find.byKey(reviewComposerKey),
      'This is the wrong default.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add comment'));
    await settleIo(tester);

    var comment = store.read().unresolved.single;
    expect(comment.anchor.label, 'scratch.txt:2');
    expect(comment.quote, [
      'two',
    ], reason: 'read from the file on disk — no patch has these lines');

    // And drawn where it is about, not at the top with the file-wide notes:
    // below line 2's margin and above line 3's.
    var margins = find.byTooltip(
      'Comment on this line — shift-click to extend a span',
    );
    var thread = tester.getTopLeft(find.byType(ReviewThread)).dy;
    expect(tester.getTopLeft(margins.at(1)).dy, lessThan(thread));
    expect(tester.getTopLeft(margins.at(2)).dy, greaterThan(thread));
  });

  testWidgets('a note on an untracked file is stamped, and says when the '
      'file moves under it', (tester) async {
    File('${temp.path}/scratch.txt').writeAsStringSync('one\ntwo\nthree\n');
    var before = const UntrackedEntry('scratch.txt', stamp: 'disk:14:1000');
    await pump(tester, setOf(untracked: [before]), open: 'scratch.txt');
    await settleIo(tester);

    await plus(tester, 1);
    await tester.enterText(find.byKey(reviewComposerKey), 'a note');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add comment'));
    await settleIo(tester);

    // Stamped with what the probe knew, which for a file with no slice of the
    // patch is what a stat said.
    expect(store.read().unresolved.single.fileDigest, 'disk:14:1000');
    expect(
      find.textContaining('This file changed after you commented'),
      findsNothing,
      reason: 'nothing has moved yet',
    );

    // The agent rewrites it under the open screen. A new stamp is a moved
    // answer, and saying so is the whole point of taking one.
    current = setOf(
      untracked: const [UntrackedEntry('scratch.txt', stamp: 'disk:31:2000')],
    );
    await refresh(tester);
    await settleIo(tester);

    expect(
      find.textContaining('This file changed after you commented'),
      findsOneWidget,
    );
  });

  testWidgets('staging that file is not the file changing', (tester) async {
    // The false alarm the tag exists to stop: `git add` moves a path from the
    // untracked list into the patch, so its fingerprint stops being a stat's
    // stamp and becomes a sha1. Comparing the two would badge every note on a
    // new file the moment the agent staged it — which is the most ordinary
    // thing an agent does next.
    File('${temp.path}/scratch.txt').writeAsStringSync('one\ntwo\nthree\n');
    store.append([
      CommentAdded(
        ReviewComment(
          id: 'staged',
          anchor: const LineAnchor(
            path: 'scratch.txt',
            from: 1,
            to: 1,
            side: ReviewSide.after,
          ),
          body: 'written while it was untracked',
          createdAt: DateTime.utc(2026, 9, 1),
          quote: const ['one'],
          fileDigest: 'disk:14:1000',
        ),
      ),
    ]);

    await pump(
      tester,
      setOf(files: [file('scratch.txt', status: ChangeStatus.added)]),
      open: 'scratch.txt',
    );
    await settleIo(tester);

    expect(find.byType(ReviewThread), findsOneWidget);
    expect(
      find.textContaining('This file changed after you commented'),
      findsNothing,
    );
  });

  testWidgets('shift-click covers a block of an untracked file', (
    tester,
  ) async {
    File('${temp.path}/scratch.txt').writeAsStringSync('one\ntwo\nthree\n');
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('scratch.txt')]),
      open: 'scratch.txt',
    );
    await settleIo(tester);

    await plus(tester, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await plus(tester, 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    await tester.enterText(find.byKey(reviewComposerKey), 'all of this');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add comment'));
    await settleIo(tester);

    var comment = store.read().unresolved.single;
    expect(comment.anchor.label, 'scratch.txt:1–3');
    expect(comment.quote, ['one', 'two', 'three']);
  });

  testWidgets('an untracked binary file is refused in words', (tester) async {
    File('${temp.path}/blob.bin').writeAsBytesSync([104, 105, 0, 33]);
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('blob.bin')]),
      open: 'blob.bin',
    );
    await settleIo(tester);

    expect(find.textContaining('Binary file'), findsOne);
  });

  testWidgets('an untracked image gets the viewer, not a notice', (
    tester,
  ) async {
    File('${temp.path}/pixel.png').writeAsBytesSync(base64Decode(_pixelPng));
    await pump(
      tester,
      setOf(untracked: const [UntrackedEntry('pixel.png')]),
      open: 'pixel.png',
    );
    await settleIo(tester);

    expect(find.byType(Image), findsOne);
    expect(find.textContaining('B'), findsWidgets); // the byte-size caption
  });

  testWidgets('a tracked, added markdown file opens rendered', (tester) async {
    File('${temp.path}/README.md').writeAsStringSync('# Fresh\n');
    await pump(
      tester,
      setOf(files: [file('README.md', status: ChangeStatus.added)]),
      open: 'README.md',
    );
    await settleIo(tester);

    expect(find.textContaining('Fresh', findRichText: true), findsWidgets);
    expect(find.textContaining('@@'), findsNothing);
  });

  testWidgets('a modified markdown file opens on its diff, toggle in reach', (
    tester,
  ) async {
    File('${temp.path}/README.md').writeAsStringSync('# Fresh\n');
    await pump(
      tester,
      setOf(files: [file('README.md', status: ChangeStatus.modified)]),
      open: 'README.md',
    );
    await settleIo(tester);

    // The diff is the default — the change is what review is about.
    expect(find.textContaining('@@'), findsOne);

    await tester.tap(find.text('Rendered'));
    await settleIo(tester);
    expect(find.textContaining('Fresh', findRichText: true), findsWidgets);
    expect(find.textContaining('@@'), findsNothing);
  });

  testWidgets('a tracked image replaces the binary notice with the viewer', (
    tester,
  ) async {
    File('${temp.path}/pixel.png').writeAsBytesSync(base64Decode(_pixelPng));
    var image = FileChange(
      path: 'pixel.png',
      status: ChangeStatus.added,
      added: 0,
      removed: 0,
      isBinary: true,
      hunks: const [],
      byteStart: 0,
      byteEnd: 0,
    );
    await pump(tester, setOf(files: [image]), open: 'pixel.png');
    await settleIo(tester);

    expect(find.byType(Image), findsOne);
    expect(find.textContaining('no lines to show'), findsNothing);
  });
}

/// A 1×1 transparent PNG — 68 bytes, the smallest honest image.
const _pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==';
