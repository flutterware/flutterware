import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/run_core.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/logs_tab.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory runDir;
  late Directory worktree;
  late File log;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-logs-tab-');
    worktree = Directory.systemTemp.createTempSync('fw-logs-tab-wt-');
    log = File(p.join(runDir.path, 'run.log'))..writeAsStringSync('');
    RunCore.runDirProvider = () => runDir.path;
    RunCore.debugLive = false;
  });

  tearDown(() {
    RunCore.runDirProvider = flutterwareRunDir;
    RunCore.debugLive = true;
    for (var dir in [runDir, worktree]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// A run of this worktree writing to [logPath].
  ///
  /// Named as `launch.dart` names them: the key is a hash of the worktree, the
  /// device and the entry point, so two launches of the same thing share it and
  /// differ only in the file they write.
  RunHandle handleFor(String logPath) => RunHandle(
    worktree: worktree.path,
    worktreeName: Worktree(path: worktree.path).name,
    device: 'macos',
    deviceName: 'macOS',
    entrypoint: 'lib/main.dart',
    entrypointName: 'App',
    launcherPid: pid,
    logPath: logPath,
    startedAt: DateTime.now(),
  );

  /// The tab, mounted against a log file this test writes.
  Future<void> pumpTab(
    WidgetTester tester, {
    double height = 600,
    String? logPath,
  }) async {
    var core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: Worktree(path: worktree.path),
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: ['.'],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: const {},
      ),
    );
    addTearDown(core.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 800,
              height: height,
              child: LogsTab(
                core: core,
                handle: handleFor(logPath ?? log.path),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The tab's own timers die with it, and the test framework will not let
    // one outlive the test.
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  testWidgets('Errors narrows the source rather than replacing it', (
    tester,
  ) async {
    log.writeAsStringSync(
      [
        'Building the app…',
        '[ERROR:flutter/x.cc(1)] the build broke',
        'flutter: the app said something',
        'flutter: [ERROR:flutter/y.cc(2)] the app threw',
        '',
      ].join('\n'),
    );
    await pumpTab(tester);

    expect(find.text('4 lines'), findsOneWidget);

    // Errors alone: both of them, whoever said it.
    await tester.tap(find.text('Errors'));
    await tester.pump();
    expect(find.text('2 of 4'), findsOneWidget);

    // Errors *and* a source: the point of two axes. The build's error, not the
    // app's — which is the question a launch that failed actually asks.
    await tester.tap(find.text('Build'));
    await tester.pump();
    expect(find.textContaining('the build broke'), findsOneWidget);
    expect(find.textContaining('the app threw'), findsNothing);
  });

  testWidgets('a build failure has errors to find', (tester) async {
    // Measured on a real broken build: `Errors` matched **0 of 44** on a log
    // whose whole point was the fault it could not find. The launcher's own
    // structured error is `Error: Build process failed`, which is true of
    // every build failure and names none; the line that says which one is the
    // front end's `path:line:col: Error:`, and nothing was looking for it.
    log.writeAsStringSync(
      [
        'Launching lib/main.dart on macOS in debug mode...',
        'Removing CocoaPods integration will improve build time.',
        "lib/main.dart:119:21: Error: Method not found: 'notAThing'.",
        'final int _broken = notAThing();',
        '** BUILD FAILED **',
        '',
      ].join('\n'),
    );
    await pumpTab(tester);

    await tester.tap(find.text('Errors'));
    await tester.pump();

    // The diagnostic and the verdict; not the advice about CocoaPods, and not
    // the source line under the caret.
    expect(find.text('2 of 5'), findsOneWidget);
    expect(find.textContaining('Method not found'), findsOneWidget);
    expect(find.textContaining('BUILD FAILED'), findsOneWidget);
    expect(find.textContaining('CocoaPods'), findsNothing);
  });

  testWidgets('and still refuses to read a fault out of prose', (tester) async {
    // The rule this sits inside: a line containing the word "error" is very
    // often a line about not having one. Only fixed shapes from known emitters
    // count.
    log.writeAsStringSync(
      [
        'flutter: Recovered from the error, carrying on',
        'No errors found in 42 files.',
        '',
      ].join('\n'),
    );
    await pumpTab(tester);

    await tester.tap(find.text('Errors'));
    await tester.pump();

    expect(find.text('0 of 2'), findsOneWidget);
  });

  testWidgets('the search box narrows and says by how much', (tester) async {
    log.writeAsStringSync(
      [
        'flutter: alpha',
        'flutter: bravo',
        'flutter: alpha again',
        '',
      ].join('\n'),
    );
    await pumpTab(tester);

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.textContaining('bravo'), findsNothing);
  });

  testWidgets('it follows the end of the log, and says so by not offering to', (
    tester,
  ) async {
    log.writeAsStringSync(
      [for (var i = 0; i < 200; i++) 'flutter: line $i', ''].join('\n'),
    );
    await pumpTab(tester, height: 200);
    await tester.pump();

    // Riding the end: the newest line is on screen and there is nothing to
    // jump back to.
    expect(find.textContaining('line 199'), findsOneWidget);
    expect(find.text('Jump to latest'), findsNothing);

    // Reading history: the offer appears, and the view stays where it was put.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('Jump to latest'), findsOneWidget);
    expect(find.textContaining('line 199'), findsNothing);

    await tester.tap(find.text('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.textContaining('line 199'), findsOneWidget);
    expect(find.text('Jump to latest'), findsNothing);
  });

  testWidgets('a reader scrolled away is not dragged to the newest line', (
    tester,
  ) async {
    log.writeAsStringSync(
      [for (var i = 0; i < 200; i++) 'flutter: line $i', ''].join('\n'),
    );
    await pumpTab(tester, height: 200);

    // A few rows back from the end, which is where a reader who scrolled up a
    // little is — the case the reversed list handled worst.
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    var before = tester.getTopLeft(find.textContaining('line 190')).dy;

    // The run logs on. This is what the reversed list used to get wrong: the
    // line being read moved by a row for every line that arrived.
    log.writeAsStringSync(
      [for (var i = 0; i < 203; i++) 'flutter: line $i', ''].join('\n'),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.textContaining('line 190'), findsOneWidget);
    expect(tester.getTopLeft(find.textContaining('line 190')).dy, before);
  });

  testWidgets('a scrollback with a front that fell off says so', (
    tester,
  ) async {
    // Past what the tail holds, at the real bound rather than a knob opened
    // for the test — the number the tab actually ships with is the one worth
    // knowing works.
    log.writeAsStringSync(
      [for (var i = 0; i < 10050; i++) 'flutter: line $i', ''].join('\n'),
    );
    await pumpTab(tester, height: 400);

    expect(find.text('10000 lines'), findsOneWidget);

    // The notice is at the top of the scrollback, where the missing lines
    // would have been — so it takes scrolling all the way back to meet it.
    // Straight to the top: 10,000 rows is further than one drag carries.
    tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('50 earlier lines are no longer held here'),
      findsOneWidget,
    );
    expect(find.textContaining(log.path), findsOneWidget);
  });

  testWidgets('a relaunch is followed to the file it writes', (tester) async {
    // A run keeps its key across a stop and a start — that is what lets an
    // address still name it — but every launch writes a new log file. Watching
    // the key alone left the tab tailing the dead run's file.
    var second = File(p.join(runDir.path, 'second.log'))
      ..writeAsStringSync('flutter: from the second run\n');
    log.writeAsStringSync('flutter: from the first run\n');

    await pumpTab(tester);
    expect(find.textContaining('from the first run'), findsOneWidget);
    expect(
      handleFor(log.path).key,
      handleFor(second.path).key,
      reason: 'the premise: a relaunch does not change the key',
    );

    await pumpTab(tester, logPath: second.path);
    await tester.pumpAndSettle();
    expect(find.textContaining('from the second run'), findsOneWidget);
    expect(find.textContaining('from the first run'), findsNothing);
  });
}
