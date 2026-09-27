// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:material_ui/material_ui.dart';

import '../ui/filter_bar.dart' show FwPill;
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'world_canvas.dart';
import 'world_trace.dart';

/// The world's timeline, the column the world is read in: every step taken
/// on the phones or by the world's own actions, and every message the
/// servers sent, newest first, in the colour of the person they belong to.
///
/// A step opens where it is, on what it caused; a message carries its
/// delivery — *Type it*, *Open*, *Read it* — on its own row. The world's log
/// folds into the foot, where it is there when wanted and not in the way.
class WorldTimeline extends StatefulWidget {
  const WorldTimeline({
    super.key,
    required this.steps,
    required this.messages,
    required this.people,
    required this.colorOf,
    required this.chosen,
    required this.following,
    required this.onChoose,
    required this.onOpenMessage,
    required this.deliverTo,
    required this.log,
  });

  /// Newest first.
  final List<TracedStep> steps;

  /// Newest first.
  final List<OutboxMessage> messages;

  /// The world's people, in the order they were declared.
  final List<String> people;
  final Color Function(String? person) colorOf;

  /// The step held open, or null.
  final String? chosen;

  /// The step the stage shows while none is chosen.
  final String? following;

  /// Holds [step] open, or lets go of it with null.
  final void Function(String? step) onChoose;

  /// Opens [message] in the sheet: a mail to read, an SMS or a push whole.
  final void Function(OutboxMessage message) onOpenMessage;

  /// How [message] is handed to its recipient's app; null while their app
  /// is not running.
  final Future<void> Function(String how)? Function(OutboxMessage message)
  deliverTo;

  /// The world's log, oldest first.
  final List<String> log;

  @override
  State<WorldTimeline> createState() => _WorldTimelineState();
}

/// What the timeline shows: everything, one person's, the world's own
/// actions, or the messages alone.
const _all = 'All';
const _messages = 'Messages';

class _WorldTimelineState extends State<WorldTimeline> {
  var _filter = _all;
  var _logOpen = false;

  @override
  Widget build(BuildContext context) {
    var filters = [
      _all,
      ...widget.people,
      if (widget.steps.any((traced) => traced.step.verb == 'action'))
        worldActionsOwner,
      _messages,
    ];
    if (!filters.contains(_filter)) _filter = _all;
    bool keepsStep(TracedStep traced) => switch (_filter) {
      _all => true,
      _messages => false,
      var who => traced.step.person == who,
    };
    bool keepsMessage(OutboxMessage message) => switch (_filter) {
      _all || _messages => true,
      var who => message.person == who,
    };
    // Steps and messages on one line of time, newest first.
    var rows = <(DateTime, Widget)>[
      for (var traced in widget.steps)
        if (keepsStep(traced))
          (
            traced.step.at!,
            _StepRow(
              traced: traced,
              open: traced.step.id == widget.chosen,
              followed:
                  widget.chosen == null && traced.step.id == widget.following,
              colorOf: widget.colorOf,
              onTap: () => widget.onChoose(
                traced.step.id == widget.chosen ? null : traced.step.id,
              ),
            ),
          ),
      for (var message in widget.messages)
        if (keepsMessage(message))
          (
            message.at,
            _MessageLine(
              message: message,
              color: widget.colorOf(message.person),
              deliver: widget.deliverTo(message),
              onOpen: () => widget.onOpenMessage(message),
            ),
          ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.lg,
            FwSpacing.md,
            FwSpacing.lg,
            FwSpacing.sm,
          ),
          child: Wrap(
            spacing: FwSpacing.xs,
            runSpacing: FwSpacing.xs,
            children: [
              for (var filter in filters)
                FwPill(
                  label: filter == worldActionsOwner ? 'The world' : filter,
                  selected: filter == _filter,
                  onTap: () => setState(() => _filter = filter),
                ),
            ],
          ),
        ),
        Container(height: 1, color: context.colors.line2),
        Expanded(
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  child: Text(
                    widget.steps.isEmpty && widget.messages.isEmpty
                        ? 'Nothing yet. Tap something on a phone, run an '
                              'action, or drive an app with `flutterware_act`.'
                        : 'Nothing here for $_filter yet.',
                    style: context.type.bodyMuted,
                  ),
                )
              : ListView(children: [for (var (_, row) in rows) row]),
        ),
        _LogFoot(
          lines: widget.log,
          open: _logOpen,
          onToggle: () => setState(() => _logOpen = !_logOpen),
        ),
      ],
    );
  }
}

/// A step: who did what, when, and how much it caused — opened, what it
/// caused beneath, as `worlds trace` says it.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.traced,
    required this.open,
    required this.followed,
    required this.colorOf,
    required this.onTap,
  });

  final TracedStep traced;
  final bool open;

  /// Shown on the stage because it is the newest, not because it was chosen.
  final bool followed;
  final Color Function(String? person) colorOf;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var (:step, :beats) = traced;
    var count = everyBeat(beats).length;
    var numbers = open ? numberNodes(traced) : const <String, int>{};
    return Container(
      decoration: BoxDecoration(
        color: open
            ? context.colors.accentSoft2
            : followed
            ? context.colors.panel2
            : null,
        border: Border(bottom: BorderSide(color: context.colors.line2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tappable(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 68,
                    child: Text(
                      clockOf(step.at!),
                      style: context.type.mono.copyWith(
                        color: context.colors.mut,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: PersonDot(colorOf(step.person)),
                  ),
                  const SizedBox(width: FwSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stepTitle(step),
                          style: open
                              ? context.type.bodyStrong
                              : context.type.body,
                        ),
                        Text(
                          [
                            step.id,
                            count == 0
                                ? step.verb == 'action'
                                      ? 'nothing heard yet'
                                      : 'nothing left the phone'
                                : count == 1
                                ? '1 thing'
                                : '$count things',
                          ].join(' · '),
                          style: context.type.caption,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: FwIconSize.sm,
                    color: context.colors.mut2,
                  ),
                ],
              ),
            ),
          ),
          if (open && beats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: FwSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A number names a part; what a request did at its own part
                  // is beneath it already, and does not repeat it.
                  for (var head in beats) ...[
                    BeatRow(
                      beat: head,
                      since: step.at!,
                      number: numbers[head.node],
                      color: colorOf(step.person),
                      dot: colorOf(head.person),
                    ),
                    for (var (beat, depth) in beatsByDepth(head.children, 1))
                      BeatRow(
                        beat: beat,
                        depth: depth,
                        since: step.at!,
                        number: beat.node == head.node
                            ? null
                            : numbers[beat.node],
                        color: colorOf(step.person),
                        dot: colorOf(beat.person ?? step.person),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A message on the timeline, with its delivery on its own row: the place
/// a code is typed from.
class _MessageLine extends StatelessWidget {
  const _MessageLine({
    required this.message,
    required this.color,
    required this.deliver,
    required this.onOpen,
  });

  final OutboxMessage message;
  final Color color;
  final Future<void> Function(String how)? deliver;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.colors.line2)),
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.lg,
      vertical: FwSpacing.sm,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 68,
          child: Text(
            clockOf(message.at),
            style: context.type.mono.copyWith(color: context.colors.mut),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            messageIcon(message.kind),
            size: FwIconSize.sm,
            color: color,
          ),
        ),
        const SizedBox(width: FwSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tappable(
                onTap: onOpen,
                feedback: TapFeedback.link,
                child: Text(
                  '${messageKind(message.kind)} to '
                  '${message.person ?? message.to} · ${message.text}',
                  style: context.type.body,
                ),
              ),
              if (message.subtitle case var subtitle?)
                Text(subtitle, style: context.type.bodyMuted),
              Text(
                [
                  if (message.sender case var sender?) 'from $sender',
                  if (message.step case var step?)
                    message.byTime ? '$step, by time' : step,
                ].join(' · '),
                style: context.type.caption,
              ),
              DeliveryButtons(
                message: message,
                deliver: deliver,
                onRead: message.kind == 'mail' ? onOpen : null,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The world's log, folded to its last line until opened.
class _LogFoot extends StatelessWidget {
  const _LogFoot({
    required this.lines,
    required this.open,
    required this.onToggle,
  });

  final List<String> lines;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    var shown = open
        ? lines.sublist(lines.length > 14 ? lines.length - 14 : 0)
        : const <String>[];
    return Container(
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border(top: BorderSide(color: context.colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tappable(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.expand_more : Icons.expand_less,
                    size: FwIconSize.sm,
                    color: context.colors.mut,
                  ),
                  const SizedBox(width: FwSpacing.xs),
                  Text('Log', style: context.type.caption),
                  const SizedBox(width: FwSpacing.sm),
                  if (!open && lines.isNotEmpty)
                    Expanded(
                      child: Text(
                        lines.last,
                        style: context.type.mono.copyWith(
                          color: context.colors.mut,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (open)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(
                  FwSpacing.lg,
                  0,
                  FwSpacing.lg,
                  FwSpacing.sm,
                ),
                child: SelectableText(
                  shown.join('\n'),
                  style: context.type.mono.copyWith(color: context.colors.ink2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
