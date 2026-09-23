import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/plugins.dart';

import '../../dev_stack/stack_block.dart';
import '../../ui/action_button.dart';
import '../../ui/empty_state.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../native_plugin.dart';
import 'dev_stack_core.dart';
import 'dev_stack_results.dart';

/// The dev stack's panel: the state as a header band, then what is under the
/// stack, then what it can be told to do, then what the last thing printed.
class DevStackPlugin extends NativePlugin<DevStackCore> {
  DevStackPlugin(super.core);

  @override
  String? get busyWith => core.busyWith;

  @override
  Widget buildPanel(BuildContext context) => _DevStackPanel(this);
}

/// Answer, then evidence, then controls, then output — the Run cockpit's shape.
///
/// The page used to open with a copy of the thing that links to it. The
/// worktree overview's card was mounted verbatim at the top, 720px wide inside a
/// panel twice that, above two mismatched command controls and three hundred
/// pixels of empty state, while facts the core already held — per-service state,
/// the exit code, how long the command took — were never drawn at all. See
/// `docs/superpowers/specs/2026-08-12-dev-stack-ui-study-2.md`.
///
/// What replaced it is the anatomy every other working panel here already has:
/// a header band carrying the state and the one control that changes it,
/// sections edge to edge, and a console pinned at the foot.
class _DevStackPanel extends StatelessWidget {
  const _DevStackPanel(this.plugin);

  final DevStackPlugin plugin;

  @override
  Widget build(BuildContext context) {
    var core = plugin.core;
    return AnimatedBuilder(
      animation: plugin,
      builder: (context, _) {
        var services = core.reading.services;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DevStackBlock(plugin, form: DevStackForm.band),
            Expanded(
              child: services.isEmpty && core.commands.isEmpty
                  ? const EmptyState(
                      title: 'Nothing to run here',
                      message:
                          'This project declares a probe and nothing else — no '
                          'services to break down, and no commands to run from '
                          'here. The state above is all there is to show.',
                    )
                  // The console takes whatever the sections leave rather than
                  // being pinned under a gap they were too short to fill: a
                  // project with six services and four commands pushes it down
                  // and the page scrolls, and this one has a service and two
                  // commands and the console is most of the screen. Both are
                  // the right answer, and neither is a void in the middle.
                  : CustomScrollView(
                      slivers: [
                        if (services.isNotEmpty)
                          SliverToBoxAdapter(child: _Services(core)),
                        if (core.commands.isNotEmpty)
                          SliverToBoxAdapter(child: _Commands(core)),
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _Console(core),
                        ),
                      ],
                    ),
            ),
            _Provenance(core),
          ],
        );
      },
    );
  }
}

/// A titled band of the page, edge to edge.
class _Section extends StatelessWidget {
  const _Section({required this.title, this.trailing, required this.child});

  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xxxl,
        FwSpacing.xl,
        FwSpacing.xxxl,
        FwSpacing.xxl,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: DevStackColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  title.toUpperCase(),
                  style: type.fieldLabel.copyWith(color: colors.mut),
                ),
                if (trailing != null) ...[
                  const Gap(FwSpacing.lg),
                  Text(trailing!, style: type.caption),
                ],
              ],
            ),
            const Gap(FwSpacing.lg),
            child,
          ],
        ),
      ),
    );
  }
}

/// What is under the stack, one row each.
///
/// The probe has always reported a name, a port and a state per service, and
/// the only place any of it was drawn was a wrap of 6px dots under a hairline.
/// Rows, because "which one is not up" is the question a partial stack raises
/// and a chip cloud cannot answer.
class _Services extends StatelessWidget {
  const _Services(this.core);

  final DevStackCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var services = core.reading.services;
    var count = core.reading.serviceCount;
    return _Section(
      title: 'Services',
      trailing: count == null
          ? '${services.length} named'
          : '${count.$1} of ${count.$2} up',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var (i, service) in services.indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: FwSpacing.md),
              decoration: i == services.length - 1
                  ? null
                  : BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.line2)),
                    ),
              child: Row(
                children: [
                  _ServiceDot(service.state),
                  const Gap(FwSpacing.lg),
                  // Bounded rather than [Flexible]: a flexible child beside a
                  // [Spacer] is handed half the row and leaves the slack at the
                  // far end, which put the state column in the middle of the
                  // page instead of against its edge.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      service.name,
                      style: type.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (service.port case var port?) ...[
                    const Gap(FwSpacing.md),
                    Text(
                      ':$port',
                      style: type.bodyMuted.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const Spacer(),
                  // The probe's own word, or nothing. A service whose state the
                  // project did not report must not be rendered as one it did —
                  // the same rule `serviceCount` follows when it refuses to
                  // count a partial declaration.
                  Text(
                    service.state?.name ?? 'not reported',
                    style: type.caption.copyWith(
                      color: service.state == StackState.up
                          ? colors.grn
                          : colors.mut,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ServiceDot extends StatelessWidget {
  const _ServiceDot(this.state);

  final StackState? state;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: switch (state) {
          StackState.up => colors.grn,
          StackState.starting || StackState.stopping => colors.amber,
          StackState.unavailable => colors.red,
          _ => colors.mut3,
        },
      ),
    );
  }
}

/// Everything the stack's CLI can be asked to do, in one group and one shape.
///
/// A command looks like a command whether or not it needs a value. The
/// argument-less ones used to be a `Wrap` of bare buttons whose labels were the
/// only thing said about them — the project's `description` reached the tooltip
/// and nowhere else, which is how `Logs` became a button nobody could identify
/// without hovering it. The description is the row's subtitle now.
class _Commands extends StatefulWidget {
  const _Commands(this.core);

  final DevStackCore core;

  @override
  State<_Commands> createState() => _CommandsState();
}

class _CommandsState extends State<_Commands> {
  final _controllers = <String, TextEditingController>{};

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String id) =>
      _controllers.putIfAbsent(id, TextEditingController.new);

  /// Runs it, and swallows nothing: the future goes back to [FwActionButton],
  /// which is what turns a failure into a message rather than a green tick.
  Future<void> _run(StackCommand command) => widget.core.runCommand(
    command.id,
    argument: command.argument == null
        ? null
        : _controllerFor(command.id).text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var commands = widget.core.commands;
    var busy = widget.core.busy != null;
    return _Section(
      title: 'Commands',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var (i, command) in commands.indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: FwSpacing.lg),
              decoration: i == commands.length - 1
                  ? null
                  : BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.line2)),
                    ),
              child: Row(
                // The field and the button are different heights, and the text
                // beside them is one line or two depending on what the project
                // wrote. Centred, every row's controls sit on the same line as
                // each other and in the middle of what they act on; aligned to
                // the top they stepped down the page with the descriptions.
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(command.label, style: type.bodyStrong),
                        const Gap(FwSpacing.xxs),
                        // The project's sentence, or failing that the
                        // invocation. A label alone is what made `Logs` a
                        // button nobody could identify, and `description` is
                        // optional — so the row falls back to the one thing
                        // that is always known, the same way the action list
                        // does for `fw` and for an agent.
                        Text(
                          command.description ??
                              _Console.shorten(describeRun(command.run)),
                          style: command.description == null
                              ? type.caption.copyWith(
                                  fontFamily: 'monospace',
                                  color: colors.mut2,
                                )
                              : type.caption,
                        ),
                        if (command.danger) ...[
                          const Gap(FwSpacing.xxs),
                          Text(
                            'this project marks it as destructive',
                            style: type.caption.copyWith(
                              color: colors.warningText,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Gap(FwSpacing.xl),
                  if (command.argument case var argument?) ...[
                    // Bounded rather than [Expanded]: a box for a service name
                    // or a path is a short answer, and one stretched across a
                    // wide window puts its Run button a screen away from the
                    // thing it runs.
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _controllerFor(command.id),
                        style: type.bodySmall,
                        decoration: InputDecoration(
                          isDense: true,
                          // The argument's declared name, which is the only
                          // word anyone has for what goes in the blank.
                          hintText: argument,
                        ),
                        onSubmitted: busy
                            ? null
                            : (_) => unawaited(_run(command)),
                      ),
                    ),
                    const Gap(FwSpacing.lg),
                  ],
                  FwActionButton(
                    label: 'Run',
                    onPressed: busy ? null : () => _run(command),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What the last command printed, and how it ended.
///
/// Not a log viewer, and deliberately not one: the stack's own `logs` command is
/// declared right beside this and streams the real thing in a terminal that can
/// scroll, search and stay open. This is the tail of the command *this panel*
/// just ran, which is output no other surface has — echoed under its own
/// invocation, the way a terminal would, so there is never a question of which
/// command the text belongs to.
///
/// Empty, it is one line rather than a page: the panel's empty state used to be
/// three hundred pixels of centred prose about a probe, on a screen whose whole
/// top half was already the probe's answer.
class _Console extends StatelessWidget {
  const _Console(this.core);

  final DevStackCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var command = core.lastCommand;
    return Container(
      decoration: BoxDecoration(
        color: colors.panel2,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xxxl,
              vertical: FwSpacing.lg,
            ),
            child: DevStackColumn(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'CONSOLE',
                    style: type.fieldLabel.copyWith(color: colors.mut),
                  ),
                  const Gap(FwSpacing.lg),
                  Expanded(
                    child: Text(
                      command == null ? '' : shorten(command),
                      style: type.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (core.busy != null)
                    Text('running…', style: type.caption)
                  else if (core.lastExitCode case var code?) ...[
                    _Pill(
                      'exit $code',
                      tone: code == 0 ? colors.grn : colors.red,
                    ),
                    if (core.lastRunFor case var elapsed?) ...[
                      const Gap(FwSpacing.md),
                      _Pill(_duration(elapsed)),
                    ],
                  ],
                  if (command != null) ...[
                    const Gap(FwSpacing.lg),
                    _CopyLink('\$ $command\n${core.lastOutput}'),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xxxl,
              0,
              FwSpacing.xxxl,
              FwSpacing.xl,
            ),
            child: DevStackColumn(
              child: command == null
                  ? Text(
                      'Anything you run above prints here — the tail of it, with '
                      'the exit code.',
                      style: type.caption.copyWith(color: colors.mut2),
                    )
                  : ConstrainedBox(
                      // A tail, not a transcript: past this the console would
                      // push the commands that produce it off the screen.
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '\$ ${shorten(command)}\n',
                                style: type.caption.copyWith(
                                  fontFamily: 'monospace',
                                  color: colors.mut2,
                                ),
                              ),
                              TextSpan(
                                text: core.lastOutput.isEmpty
                                    ? '(no output)'
                                    : core.lastOutput,
                                style: type.caption.copyWith(
                                  fontFamily: 'monospace',
                                  color: colors.ink2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// The invocation as a person would type it.
  ///
  /// A config runs its scripts under the SDK the project is pinned to, so the
  /// first token is an absolute path ending in `bin/dart` — 70 characters of
  /// provenance in front of the two words that say what ran. The footer below
  /// still carries all of it.
  static String shorten(String command) {
    var space = command.indexOf(' ');
    if (space <= 0) return command;
    var executable = command.substring(0, space);
    var slash = executable.lastIndexOf('/');
    if (slash < 0) return command;
    return '${executable.substring(slash + 1)}${command.substring(space)}';
  }

  static String _duration(Duration elapsed) => elapsed.inSeconds < 1
      ? '${elapsed.inMilliseconds}ms'
      : '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.tone});

  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: tone == null ? colors.bg : colors.statusFill(tone!),
        border: Border.all(
          color: tone == null ? colors.line : colors.statusBorder(tone!),
        ),
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        label,
        style: context.type.micro.copyWith(color: tone ?? colors.mut),
      ),
    );
  }
}

/// Copy, and say it copied — the same acknowledgement rule [FwActionButton]
/// follows, because a clipboard write is the definition of work with no visible
/// result.
class _CopyLink extends StatefulWidget {
  const _CopyLink(this.text);

  final String text;

  @override
  State<_CopyLink> createState() => _CopyLinkState();
}

class _CopyLinkState extends State<_CopyLink> {
  Timer? _revert;
  var _copied = false;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
    _revert?.cancel();
    setState(() => _copied = true);
    _revert = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: _copy,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
        child: Container(
          // The same underline the block's links wear. Without it this was the
          // one control on the page you found by hovering, which is the finding
          // the first study closed everywhere else.
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.mut3)),
          ),
          child: Text(
            _copied ? 'Copied' : 'Copy',
            style: context.type.caption.copyWith(
              color: _copied ? colors.accent : colors.mut,
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the state on screen came from — the last thing anyone reads, and the
/// first thing they need when the project's own CLI is the broken part.
///
/// One line rather than two rows: the values are long, but the reason anyone
/// reads them is to run the thing themselves, and copying beats reading an
/// absolute path off a screen.
class _Provenance extends StatelessWidget {
  const _Provenance(this.core);

  final DevStackCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var probe = core.declaredProbeCommand;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xxxl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: DevStackColumn(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                [
                  if (probe != null) 'probe · $probe',
                  'in ${core.workingDirectory}',
                ].join('   ·   '),
                style: type.caption.copyWith(color: colors.mut2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(FwSpacing.lg),
            _CopyLink([?probe, core.workingDirectory].join('\n')),
          ],
        ),
      ),
    );
  }
}
