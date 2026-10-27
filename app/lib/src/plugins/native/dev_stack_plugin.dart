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
/// the exit code, how long the command took — were never drawn at all.
///
/// What replaced it is the anatomy every other working panel here already has:
/// a header band carrying the state and the one control that changes it,
/// sections edge to edge, and a console pinned at the foot.
class _DevStackPanel extends StatelessWidget {
  const _DevStackPanel(this.plugin);

  final DevStackPlugin plugin;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: plugin,
    builder: (context, _) {
      var core = plugin.core;
      if (core.services.isEmpty) return _Unreadable(core);
      // **One service keeps the page it had.** The console taking whatever the
      // sections leave is the whole reason this form exists — a project with a
      // service and two commands gets a console that is most of the screen —
      // and it is only expressible when there is one console. Several services
      // are stacked groups instead, each carrying its own, and the page
      // scrolls.
      if (core.only case var service?) {
        return _ServicePage(plugin, service, fillConsole: true);
      }
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          for (var service in core.services)
            _ServicePage(plugin, service, fillConsole: false),
          for (var service in core.unreadable) _UnreadableRow(service),
          if (core.keepsHistory) _History(core),
        ],
      );
    },
  );
}

/// One service, from its header band down to what it last printed.
class _ServicePage extends StatelessWidget {
  const _ServicePage(this.plugin, this.core, {required this.fillConsole});

  final DevStackPlugin plugin;
  final StackServiceCore core;

  /// Whether the console may take the leftover height. True only for the
  /// single-service page, where there is leftover height to take.
  final bool fillConsole;

  @override
  Widget build(BuildContext context) {
    var services = core.reading.services;
    var body = <Widget>[
      if (services.isNotEmpty) _Services(core),
      if (core.commands.isNotEmpty) _Commands(core),
      // On the one-service page only: with several, the history is the
      // stack's and sits once under all of them.
      if (fillConsole && plugin.core.keepsHistory) _History(plugin.core),
    ];
    if (!fillConsole) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DevStackBlock(plugin, core, form: DevStackForm.band),
          ...body,
          // **Only where something could print.** A service flutterware only
          // watches — a probe, no transitions, no commands — has nothing that
          // can ever write here, so its console is a heading and a sentence
          // explaining an empty box that will stay empty. One of those is
          // tolerable on a page about one service; a column of them is what
          // several services would otherwise be mostly made of.
          if (core.canControl || core.commands.isNotEmpty) _Console(core),
          _Provenance(core),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DevStackBlock(plugin, core, form: DevStackForm.band),
        Expanded(
          child: body.isEmpty
              ? const EmptyState(
                  title: 'Nothing to run here',
                  message:
                      'This project declares a probe, but no services and no '
                      'commands. The state above is all there is to show.',
                )
              : CustomScrollView(
                  slivers: [
                    for (var section in body)
                      SliverToBoxAdapter(child: section),
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
  }
}

/// Every service declared, and none of them readable by this build.
class _Unreadable extends StatelessWidget {
  const _Unreadable(this.core);

  final DevStackCore core;

  @override
  Widget build(BuildContext context) => core.unreadable.isEmpty
      ? const EmptyState(
          title: 'No services declared',
          message:
              'This project uses the dev stack plugin but declares nothing for '
              'it to watch. Add a service to tool/flutterware.dart.',
        )
      : ListView(
          padding: EdgeInsets.zero,
          children: [
            for (var service in core.unreadable) _UnreadableRow(service),
          ],
        );
}

/// A declared service this build cannot read, named with the reason.
///
/// It is on the page rather than dropped because the fix is not guessable from
/// an absence: the row is the only thing that says a service was declared at
/// all.
class _UnreadableRow extends StatelessWidget {
  const _UnreadableRow(this.service);

  final UnreadableStackService service;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    return _Section(
      title: service.name ?? service.id,
      child: DevStackColumn(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.xxxl,
            vertical: FwSpacing.lg,
          ),
          child: Text(
            service.reason,
            style: type.body.copyWith(color: colors.danger),
          ),
        ),
      ),
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

  final StackServiceCore core;

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

/// Who started and stopped what, newest first, across every service.
///
/// Mostly an agent's doing: it starts and stops services from its own
/// process, and this is where the person in the studio sees it happened.
///
/// Three rows until asked for more, because on a one-service page everything
/// above the console comes out of the console's height.
class _History extends StatefulWidget {
  const _History(this.core);

  final DevStackCore core;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  static const _folded = 3;
  static const _unfolded = 10;

  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var all = widget.core.history.take(_unfolded).toList();
    var events = _expanded ? all : all.take(_folded).toList();
    var hidden = all.length - events.length;
    return _Section(
      title: 'History',
      trailing: all.isEmpty ? null : 'latest ${all.length}',
      child: all.isEmpty
          ? Text(
              'Starts and stops show here, with who asked: you in the studio, '
              'fw in a terminal, or an agent.',
              style: type.caption.copyWith(color: colors.mut2),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var (i, event) in events.indexed)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: FwSpacing.md),
                    decoration: i == events.length - 1
                        ? null
                        : BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: colors.line2),
                            ),
                          ),
                    child: _EventRow(event),
                  ),
                if (hidden > 0 || _expanded && all.length > _folded) ...[
                  const Gap(FwSpacing.md),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Tappable(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Container(
                        // The underline every link on this page wears.
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: colors.mut3),
                          ),
                        ),
                        child: Text(
                          _expanded ? 'Show fewer' : 'Show $hidden more',
                          style: type.caption.copyWith(color: colors.mut),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow(this.event);

  final StackEvent event;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var problem = event.outcome.isProblem;
    var detail = eventDetail(event);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _ServiceDot(switch (event.outcome) {
              StackEventOutcome.up ||
              StackEventOutcome.alreadyUp => StackState.up,
              StackEventOutcome.down ||
              StackEventOutcome.alreadyDown => StackState.down,
              _ => StackState.unavailable,
            }),
            const Gap(FwSpacing.lg),
            Expanded(
              child: Text(
                eventHeadline(event),
                style: type.body,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(FwSpacing.lg),
            Text(
              [eventCaller(event), ?stackAge(event.at)].join(' · '),
              style: type.caption.copyWith(color: colors.mut),
            ),
          ],
        ),
        if (detail != null)
          Padding(
            // Under the headline, past the dot and its gap.
            padding: const EdgeInsets.only(left: 6 + FwSpacing.lg, top: 2),
            child: Text(
              detail,
              style: type.caption.copyWith(
                color: problem ? colors.red : colors.mut2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
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

  final StackServiceCore core;

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

  final StackServiceCore core;

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
                      'The output of a command you run above shows here, with '
                      'its exit code.',
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
          // one control on the page you found by hovering.
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
/// first thing they need when the thing being reported on is the broken part.
///
/// The parts come from the service, because the answer differs by kind: a
/// delegated service names its probe, an owned one names what was spawned and
/// how readiness is decided.
///
/// One line rather than two rows: the values are long, but the reason anyone
/// reads them is to run the thing themselves, and copying beats reading an
/// absolute path off a screen.
class _Provenance extends StatelessWidget {
  const _Provenance(this.core);

  final StackServiceCore core;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var parts = core.provenance;
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
                [...parts, 'in ${core.workingDirectory}'].join('   ·   '),
                style: type.caption.copyWith(color: colors.mut2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(FwSpacing.lg),
            _CopyLink(
              [
                // The values without their labels: what this is for is
                // pasting into a terminal, and `probe · ` is not part of the
                // command.
                for (var part in parts) part.split(' · ').last,
                core.workingDirectory,
              ].join('\n'),
            ),
          ],
        ),
      ),
    );
  }
}
