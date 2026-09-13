import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/changes/diff_view.dart';
import 'package:flutterware_app/src/demo/recorded_project.dart';
import 'package:flutterware_app/src/demo/recording.dart';
import 'package:flutterware_app/src/launcher_icon/ui/plate.dart';
import 'package:flutterware_app/src/scenarios/framed_shot.dart';
import 'package:flutterware_app/src/plugins/scan_cache.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:path/path.dart' as p;

/// The whole studio over the recording `tool/demo/record.dart` wrote, with no
/// git, no manifest subprocess and no scan of the disk — which is the shape
/// the studio's own scenarios and the web demo open it in.
void main() {
  final recording = FileScenarioArtifacts(
    p.join(Directory.current.path, 'demo', 'fixture'),
  );

  testWidgets('opens on the recorded project and draws its launcher icons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = recordedShell(recording: recording);
    addTearDown(shell.dispose);
    await shell.start(recordedProjectRoot);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    // The rail is the recorded project's declared plugins.
    expect(find.text('Launcher icon'), findsOneWidget);
    expect(find.text('Dependencies'), findsOneWidget);

    await tester.tap(find.text('Launcher icon'));
    await tester.pumpAndSettle();

    // The demo app's icons, read from the recording rather than the disk: a
    // plate per role that has files, under the platform that ships it.
    expect(find.byType(IconPlate), findsWidgets);
    expect(find.text('Android'), findsWidgets);
    expect(find.text('Reading the icons…'), findsNothing);
    expect(find.textContaining('Could not read'), findsNothing);
  });

  testWidgets('previews with no entries compiled in say so', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = recordedShell(recording: recording);
    addTearDown(shell.dispose);
    await shell.start(recordedProjectRoot);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Previews'));
    await tester.pumpAndSettle();

    expect(find.text('Not in this recording'), findsOneWidget);
  });

  testWidgets('draws the recorded delta and its bodies', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = recordedShell(recording: recording);
    addTearDown(shell.dispose);
    await shell.start(recordedProjectRoot);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    // The tab is the recorded branch, not `main`: the tape answers the
    // worktree list too.
    expect(find.text('loyalty-stamps'), findsWidgets);

    await tester.tap(find.text('Changes'));
    await tester.pumpAndSettle();

    // Opens on what the project's rules pinned, ranked by the recorded
    // config: the words, in both languages, and the app's shell.
    expect(find.text('en.json'), findsOneWidget);
    expect(find.text('fr.json'), findsOneWidget);
    expect(find.text('shop_app.dart'), findsOneWidget);
    expect(find.text('loyalty.dart'), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    // The delta, indexed from the recorded patch: the new file, the rename,
    // the deletion, and the two entries git has not been told about.
    expect(find.text('loyalty.dart'), findsOneWidget);
    expect(find.text('markdown_text.dart'), findsOneWidget);
    expect(find.text('store_panorama.dart'), findsOneWidget);
    expect(find.textContaining('docs/'), findsWidgets);
    // The untracked test sits in a folder two deep, which starts folded.
    await tester.tap(find.text('shop'));
    await tester.pumpAndSettle();
    expect(find.text('loyalty_test.dart'), findsOneWidget);
    expect(find.textContaining('Reading'), findsNothing);
    expect(find.textContaining('not in the recording'), findsNothing);

    // A diff opens from the patch bytes: hunks, drawn.
    await tester.tap(find.text('shop_app.dart'));
    await tester.pumpAndSettle();
    expect(find.byType(HunkLineView), findsWidgets);

    // The image's two sides: the base from the tape's blob, now from the
    // copied file. Its folder is two deep and starts folded.
    await tester.tap(find.text('splash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('branding.png'));
    await tester.pumpAndSettle();
    expect(find.text('base'), findsOneWidget);
    expect(find.text('now'), findsOneWidget);
    expect(find.textContaining('Not readable'), findsNothing);
    expect(find.textContaining('No longer on disk'), findsNothing);
  });

  testWidgets('opens a recorded scenario and draws its run', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = recordedShell(recording: recording);
    addTearDown(shell.dispose);
    await shell.start(recordedProjectRoot);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    // The list is the recorded scan, narrowed by the recorder to the files
    // it ran: nothing on it that a click could not open.
    await tester.tap(find.text('Scenarios'));
    await tester.pumpAndSettle();
    // Small enough to arrive open: both files, every scenario.
    expect(find.text('Order a cappuccino'), findsOneWidget);
    expect(find.text('Around the shop'), findsOneWidget);
    expect(find.text('Order a cold brew on a laptop'), findsOneWidget);

    // Opening one "runs" it, which over a recording is a read: the flow
    // fills in with the recorded steps and their frames.
    await tester.tap(find.text('Order a cappuccino'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Welcome'), findsWidgets);
    expect(find.textContaining('Order placed'), findsWidgets);
    expect(find.text('iPhone 16 (default)'), findsOneWidget);
    expect(find.byType(FramedShot), findsWidgets);
    expect(find.textContaining('This recording has no'), findsNothing);
  });

  test('a scan missing from the recording is a failure, not a crash', () async {
    var scan = recordedIconScanner(recording);
    Object? failure;
    try {
      await scan(packageRoot: () => '/none', packagePath: 'nope');
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<ScanFailure>());
    expect('$failure', startsWith('This recording has no launcher icon scan'));
  });
}
