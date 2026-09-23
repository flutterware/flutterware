import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/journal.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;

/// The Steps tab: the run's journal as a reviewable strip. Reachable while
/// the app is still building — the journal is a file — and showing the
/// newest step's face by default.
void main() {
  late Directory runDir;
  late Directory worktree;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-run-steps-');
    worktree = Directory.systemTemp.createTempSync('fw-run-steps-wt-');
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

  testWidgets('the strip lists the journal and opens the newest step, '
      'without waiting for the app', (tester) async {
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

    var handle = RunHandle(
      worktree: worktree.path,
      worktreeName: Worktree(path: worktree.path).name,
      device: 'macos',
      deviceName: 'macOS',
      entrypoint: 'lib/main.dart',
      entrypointName: 'App',
      launcherPid: pid,
      // No VM service: the app is "still building". The journal answers
      // anyway.
      startedAt: DateTime.now(),
    ).publish(runDir.path);

    var textsPath = p.join(runDir.path, 'texts.json');
    File(textsPath).writeAsStringSync(jsonEncode(['Count: 3', 'Increment']));
    appendJournal(
      handle,
      JournalEntry(
        at: '2026-08-11T10:00:00Z',
        verb: 'tap',
        actor: 'agent',
        target: '"Increment"',
        attempts: 1,
        settled: true,
        settleMs: 320,
        logLines: 1,
      ),
    );
    appendJournal(
      handle,
      JournalEntry(at: '2026-08-11T10:00:02Z', verb: 'reload', elapsedMs: 90),
    );
    appendJournal(
      handle,
      JournalEntry(
        at: '2026-08-11T10:00:05Z',
        verb: 'tap',
        actor: 'agent',
        target: '"Nope"',
        error: 'nothing matches "Nope", which `tap` needs.',
        failure: 'notFound',
        texts: textsPath,
      ),
    );

    await tester.runAsync(core.computeAll);
    var address = ValueNotifier(
      Address(
        worktree: 'wt',
        plugin: runPluginId,
        segments: [handle.key, 'steps'],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: AddressRoot(
          address: address,
          onChanged: (a) => address.value = a,
          child: Builder(builder: RunPlugin(core).buildPanel),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // All three steps in the strip, verb sentences shared with the errors.
    expect(find.text('1 · tap "Increment"'), findsOneWidget);
    expect(find.text('2 · reload'), findsOneWidget);
    expect(find.text('3 · tap "Nope"'), findsOneWidget);

    // The newest step is open by default: the refusal, and — no picture —
    // its text projection.
    expect(
      find.text('nothing matches "Nope", which `tap` needs.'),
      findsOneWidget,
    );
    expect(find.text('Count: 3'), findsOneWidget);

    // Selecting an older step swaps the detail.
    await tester.tap(find.text('1 · tap "Increment"'));
    await tester.pump();
    expect(find.text('by agent · settled in 320ms · 1 log line'), findsOne);
    expect(find.text('This step kept no picture.'), findsOneWidget);

    // Unmount before the poll timer is judged pending.
    await tester.pumpWidget(const SizedBox());
  });
}
