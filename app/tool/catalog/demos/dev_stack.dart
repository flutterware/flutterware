import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/dev_stack/stack_block.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_core.dart';
import 'package:flutterware_app/src/plugins/native/dev_stack_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';

import 'shell.dart';

/// The dev stack, in the states it has to survive.
///
/// A stack needs a stack, which is why these exist: the plugin's whole
/// subject is a docker project this repo does not have, so without a stand-in
/// the panel can only be looked at inside a project that declares one. Each
/// preview below wires a real [DevStackCore] to a scripted `runProcess`, so the
/// panel is the shipping one and only the subprocess is fake.
///
/// `up` and `down` are live in every preview: pressing them runs the script,
/// which takes a beat and then reports the other state. That is the transition
/// the design exists for and the one a screenshot cannot show.
@Preview(name: 'Dev stack · up', group: 'Dev stack', wrapper: wrapInApp)
Widget devStackUp() => _Panel(_plugin(state: _Scripted.up));

@Preview(name: 'Dev stack · down', group: 'Dev stack', wrapper: wrapInApp)
Widget devStackDown() => _Panel(_plugin(state: _Scripted.down));

/// The state a first draft leaves out. The probe itself failed, which is not
/// the same fact as "down" — so the control still offers to try, and says why
/// it might not work.
///
/// The reason takes the address's slot, which is the reason that slot exists:
/// every state fills it, so the eye lands in the same place whether the news is
/// good or bad.
@Preview(
  name: 'Dev stack · unreachable',
  group: 'Dev stack',
  wrapper: wrapInApp,
)
Widget devStackUnreachable() => _Panel(_plugin(state: _Scripted.unreachable));

/// Up, and not all of it. The headline is **derived from the services** rather
/// than written beside them, which is the only arrangement where a green
/// summary cannot end up sitting above an amber row.
@Preview(name: 'Dev stack · partly up', group: 'Dev stack', wrapper: wrapInApp)
Widget devStackPartial() => _Panel(_plugin(state: _Scripted.partial));

/// What a project that only *watches* a stack gets: a status, and no controls.
/// A complete declaration, not a degraded one.
@Preview(
  name: 'Dev stack · observe only',
  group: 'Dev stack',
  wrapper: wrapInApp,
)
Widget devStackObserveOnly() =>
    _Panel(_plugin(state: _Scripted.up, controls: false));

/// The strip the worktree home draws — one line, tinted, and the line is the
/// way into the panel.
@Preview(
  name: 'Dev stack · on the home screen',
  group: 'Dev stack',
  wrapper: wrapInApp,
)
Widget devStackCompact() => Builder(
  builder: (context) => ColoredBox(
    color: context.colors.bg,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('explorer brainstorm', style: context.type.pageTitle),
          const Gap(FwSpacing.sm),
          Text(
            '/Users/dev/worktrees/example/explorer-brainstorm-e5efdc',
            style: context.type.caption,
          ),
          const Gap(FwSpacing.xxxl),
          DevStackBlock(
            _plugin(state: _Scripted.up),
            form: DevStackForm.strip,
            onOpenPanel: () {},
          ),
        ],
      ),
    ),
  ),
);

class _Panel extends StatelessWidget {
  const _Panel(this.plugin);

  final DevStackPlugin plugin;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.bg,
    body: plugin.buildPanel(context),
  );
}

/// Which script the fake stack runs.
enum _Scripted { up, down, unreachable, partial }

/// A core over a scripted subprocess, holding real state: `up` writes it, `down`
/// clears it, and the probe reports what it finds. Nothing here touches docker,
/// and nothing outlives the preview.
DevStackPlugin _plugin({required _Scripted state, bool controls = true}) {
  var up = state == _Scripted.up || state == _Scripted.partial;
  var core = DevStackCore(
    PluginHost(
      id: devStackPluginId,
      label: 'Dev stack',
      worktree: Worktree(path: '/Users/dev/worktrees/example'),
      workspace: Workspace(
        root: '/Users/dev/worktrees/example',
        declared: [],
        discovered: [],
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/tmp/flutter'),
      ),
      config: DevStack.background(
        workingDirectory: 'packages/server',
        probe: Probe.json(StackRun.command(['stack', 'doctor', '--json'])),
        start: controls ? StackRun.command(['stack', 'up']) : null,
        stop: controls ? StackRun.command(['stack', 'down']) : null,
        stopIsDestructive: true,
        poll: const Duration(seconds: 5),
        commands: [
          const StackCommand(
            'logs',
            'Logs',
            StackRun.command(['stack', 'logs']),
          ),
          const StackCommand(
            'restart',
            'Restart',
            StackRun.command(['stack', 'restart']),
            argument: 'service',
          ),
        ],
      ).config,
    ),
  );

  core.runProcess = (command, {workingDirectory}) async {
    var verb = command.elementAtOrNull(1);
    // A beat for the things a person watches happen, and **none for the
    // probe**. A headless preview screenshot settles on frames rather than on
    // `SettleSource` — that is the window capture's mechanism, and a preview
    // has no plugin host to register one — so a probe that took even a moment
    // photographed the panel before its first reading and captured "not
    // checked yet" as if it were the state.
    if (verb != 'doctor') {
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    switch (verb) {
      case 'up':
        up = true;
        return ProcessResult(0, 0, 'Stack up on 8200-8208.', '');
      case 'down':
        up = false;
        return ProcessResult(0, 0, 'Stack down, volumes removed.', '');
      case 'logs':
        return ProcessResult(
          0,
          0,
          [
            'postgres  | database system is ready to accept connections',
            'identity  | listening on :8201',
            'sync      | replication slot active',
          ].join('\n'),
          '',
        );
      case 'doctor':
        if (state == _Scripted.unreachable) {
          return ProcessResult(
            0,
            1,
            '',
            'Cannot connect to the Docker daemon.',
          );
        }
        return ProcessResult(
          0,
          0,
          up
              ? '{"state":"up","detail":"slot 8200-8208 · 4 containers",'
                    '"services":[{"name":"postgres","port":8200,"state":"up"},'
                    '{"name":"identity","port":8201,"state":"up"},'
                    '{"name":"sync","port":8202,"state":'
                    '"${state == _Scripted.partial ? 'starting' : 'up'}"},'
                    '{"name":"mail","port":8203,"state":"up"}]}'
              : '{"state":"down","detail":"slot 8200-8208 reserved"}',
          '',
        );
      default:
        return ProcessResult(0, 0, '', '');
    }
  };
  return DevStackPlugin(core);
}
