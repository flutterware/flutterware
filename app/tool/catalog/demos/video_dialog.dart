import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/plugins.dart';
import 'package:flutterware_app/src/scenarios/film_encode.dart';
import 'package:flutterware_app/src/scenarios/video_dialog.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'shell.dart';

/// Rendering a scenario as a video — every state the dialog has.
///
/// A dialog is opened by a click, so `fw capture` cannot reach it and a
/// screenshot of the panel would catch the menu item rather than the dialog.
/// These build [ScenarioVideoDialogView] directly with the state already in
/// it, which is the whole reason the view takes values and hands back
/// callbacks: no harness, no scenario, no `ffmpeg`, and a picture of a render
/// in flight without waiting for one.
@Preview(name: 'Video · options', group: 'Scenarios', wrapper: wrapInApp)
Widget videoOptions() => const _Case();

@Preview(name: 'Video · preparing', group: 'Scenarios', wrapper: wrapInApp)
Widget videoPreparing() => const _Case(
  running: true,
  // Nothing has been drawn yet: the harness is compiling, booting the app and
  // painting the first screen, which is the longest part of a cold render and
  // the part with nothing to show.
  progress: ScenarioFilmProgress(frames: 0),
);

@Preview(name: 'Video · counting', group: 'Scenarios', wrapper: wrapInApp)
Widget videoCounting() => const _Case(
  running: true,
  // No total yet — the length of a film is what the scenario does, and the
  // timeline that says how long it is arrives last.
  progress: ScenarioFilmProgress(frames: 87),
);

@Preview(name: 'Video · encoding', group: 'Scenarios', wrapper: wrapInApp)
Widget videoEncoding() => const _Case(
  running: true,
  progress: ScenarioFilmProgress(frames: 296, total: 331),
);

@Preview(name: 'Video · rendered', group: 'Scenarios', wrapper: wrapInApp)
Widget videoRendered() => _Case(
  rendered: Artifact(
    kind: Artifact.mp4,
    address: Address.parse('fw:///worktrees/demo/flutterware.scenarios/shop'),
    path: 'examples/brewline/build/flutterware/video/order-a-cappuccino.mp4',
    meta: const {'frames': 331, 'fps': 30, 'bytes': 767000, 'renderMs': 4239},
  ),
);

@Preview(name: 'Video · refused', group: 'Scenarios', wrapper: wrapInApp)
Widget videoRefused() => const _Case(
  error:
      '`Around the shop` did not finish, so there is no film:\n\n'
      '`Around the shop` splits into `a cappuccino`, `a flat white`, '
      '`a cold brew` and `the empty cart`, and a film is one path. Name it: '
      "--branch='a cappuccino'. Nested splits take one --branch each, "
      'outermost first.',
);

/// The dialog over the ground it opens on, with its options already answered.
class _Case extends StatefulWidget {
  const _Case({this.running = false, this.progress, this.rendered, this.error});

  final bool running;
  final ScenarioFilmProgress? progress;
  final Artifact? rendered;
  final String? error;

  @override
  State<_Case> createState() => _CaseState();
}

class _CaseState extends State<_Case> {
  var _options = const ScenarioVideoOptions();
  // In `initState`, because a controller allocated in `build` resets on every
  // keystroke — and a knob or a hot reload rebuilds this constantly.
  final _branches = TextEditingController();
  final _output = TextEditingController();

  @override
  void dispose() {
    _branches.dispose();
    _output.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: Center(
      child: ScenarioVideoDialogView(
        scenario: 'Order a cappuccino',
        device: 'iphone-13',
        options: _options,
        branches: _branches,
        output: _output,
        onOptions: (options) => setState(() => _options = options),
        command: scenarioVideoCommand(
          pluginId: 'flutterware.scenarios',
          package: 'fixtures/probe_app',
          file: 'test/scenarios/mobile/shop_test.dart',
          scenario: 'Order a cappuccino',
          nameThePackage: true,
          options: _options,
          device: 'iphone-13',
        ),
        running: widget.running,
        progress: widget.progress,
        rendered: widget.rendered,
        error: widget.error,
        onRender: () {},
        onClose: () {},
        onOpen: (_) async {},
      ),
    ),
  );
}
