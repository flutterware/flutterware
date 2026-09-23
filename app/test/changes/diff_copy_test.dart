import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';

/// Taking code out of a diff.
///
/// The body has been selectable for a while and the selection was unusable:
/// four rows came back as one run-together string with the line numbers welded
/// into it, because sibling `Text`s have nothing between them and the gutter is
/// a `Text` like any other. What a selected diff is for is pasting the code
/// somewhere else, so these are the claims that replaced it — lines stay lines,
/// and the furniture stays behind.
void main() {
  const worktree = Worktree(
    path: '/wt/feature',
    gitName: 'feature',
    branch: 'claude/feature',
  );

  var patch = [
    'diff --git a/lib/a.dart b/lib/a.dart',
    '--- a/lib/a.dart',
    '+++ b/lib/a.dart',
    '@@ -1,3 +1,4 @@',
    ' void main() {',
    '-  print("old");',
    '+  print("new");',
    ' }',
    '',
  ].join('\n');

  testWidgets('a selection down the diff copies the code, and only it', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

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
    // The body is behind the file, as the screen has it.
    await tester.tap(find.text('a.dart').first);
    await tester.pumpAndSettle();

    var first = find.text('void main() {');
    var last = find.text('}');
    var gesture = await tester.startGesture(
      tester.getTopLeft(first) + const Offset(1, 6),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(tester.getTopRight(last) - const Offset(1, -6));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    var region = tester.state(find.byType(SelectableRegion));
    (region as dynamic).copySelection(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    // Lines, not one run-together string.
    expect(copied, contains('\n'));
    // And no blank line in front of them. A drag that begins on the top edge
    // of a line rests its start on the end of the line above, which used to
    // hand back nothing plus a terminator.
    expect(copied, isNot(startsWith('\n')));
    // The code, whole.
    for (var line in [
      'void main() {',
      '  print("old");',
      '  print("new");',
      '}',
    ]) {
      expect(
        copied!.split('\n'),
        contains(line),
        reason: 'the code of every selected row is there, on a line of its own',
      );
    }
    // And nothing that is furniture: no line numbers, no +/- markers.
    for (var line in copied!.split('\n')) {
      expect(
        line,
        isNot(matches(RegExp(r'^\s*\d'))),
        reason: 'a line number would make this paste as nothing at all',
      );
      expect(line, isNot(startsWith('+')));
      expect(line, isNot(startsWith('-')));
    }
  });
}
