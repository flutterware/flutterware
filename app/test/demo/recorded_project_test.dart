import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('a plugin with nothing recorded says so', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = recordedShell(recording: recording);
    addTearDown(shell.dispose);
    await shell.start(recordedProjectRoot);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Splash screen'));
    await tester.pumpAndSettle();

    expect(find.text('Not in this recording'), findsOneWidget);
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
