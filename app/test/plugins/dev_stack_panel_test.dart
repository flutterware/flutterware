import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_core.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';

/// The one part of the panel that is not the shared block: the row that runs a
/// command taking an argument.
///
/// Written because the panel had no such row. `DevStackBlock` deliberately
/// leaves an argument-taking command out of its links — a link is one click and
/// there is nothing to click *with* — and the panel it deferred to did not ask
/// for the value either, so a declared command was reachable from `fw` and from
/// an agent and from nowhere in the GUI. The gap was found by declaring one in
/// the example project, which is exactly what a worked example is for.
void main() {
  late Directory runDir;
  late Directory project;
  late List<List<String>> ran;

  DevStackCore coreWith(Map<String, Object?> config) =>
      DevStackCore(
          PluginHost(
            id: devStackPluginId,
            label: 'Dev stack',
            worktree: Worktree(path: project.path),
            workspace: Workspace(
              root: project.path,
              declared: [],
              discovered: [],
              appContext: AppContext(logger: LogClient.print()),
              flutterSdk: FlutterSdkPath('/tmp/flutter'),
            ),
            config: config,
          ),
        )
        ..runProcess = (command, {workingDirectory}) async {
          ran.add(command);
          return ProcessResult(0, 0, '{"state":"up"}', '');
        };

  Map<String, Object?> configWith(List<StackCommand> commands) =>
      DevStack.background(
        probe: Probe.json(StackRun.command(['stack', 'doctor'])),
        start: StackRun.command(['stack', 'up']),
        stop: StackRun.command(['stack', 'down']),
        commands: commands,
      ).config;

  Future<void> pump(WidgetTester tester, DevStackCore core) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: Builder(builder: DevStackPlugin(core).buildPanel)),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-stack-panel-run-');
    project = Directory.systemTemp.createTempSync('fw-stack-panel-');
    ran = [];
    DevStackCore.runDirProvider = () => runDir.path;
  });

  tearDown(() {
    DevStackCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, project]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  testWidgets('a command with an argument gets a field and runs with it', (
    tester,
  ) async {
    var core = coreWith(
      configWith([
        const StackCommand(
          'hit',
          'Send a request',
          StackRun.command(['stack', 'hit']),
          argument: 'path',
        ),
      ]),
    );
    await pump(tester, core);

    // The argument's declared name is the hint, because it is the only word
    // anybody has for what goes in the blank.
    expect(find.text('Send a request'), findsOneWidget);
    expect(find.text('path'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/users');
    await tester.tap(find.text('Run'));
    // `FwActionButton` holds its running state for a floor and its tick for a
    // while after — plain timers, which schedule no frames, so `pumpAndSettle`
    // returns with both still pending. Time has to be advanced explicitly.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(ran.last, ['stack', 'hit', '/users']);
    core.dispose();
  });

  testWidgets('a command that takes nothing gets no field', (tester) async {
    // Those are links in the block above, and a row with an empty box beside
    // them would be a control that does nothing.
    var core = coreWith(
      configWith([
        const StackCommand('logs', 'Logs', StackRun.command(['stack', 'logs'])),
      ]),
    );
    await pump(tester, core);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Logs'), findsOneWidget);
    core.dispose();
  });

  testWidgets('a stack with no commands shows no row at all', (tester) async {
    var core = coreWith(configWith(const []));
    await pump(tester, core);
    expect(find.byType(TextField), findsNothing);
    core.dispose();
  });
}
