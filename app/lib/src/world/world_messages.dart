// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:material_ui/material_ui.dart';

import '../session/job.dart' show ActionRefusal;
import '../ui/action_button.dart';
import '../ui/chip.dart';
import '../ui/theme.dart';
import 'open_world.dart';
import 'platform/studio_platform.dart';
import 'world_trace.dart';

/// `SMS`, `Push`, `Mail`.
String messageKind(String kind) => switch (kind) {
  'sms' => 'SMS',
  'push' => 'Push',
  'mail' => 'Mail',
  var other => other,
};

IconData messageIcon(String kind) => switch (kind) {
  'push' => Icons.notifications_none,
  'mail' => Icons.mail_outline,
  _ => Icons.sms_outlined,
};

/// The kinds a person's tag counts, in the order it counts them.
const messageKinds = ['mail', 'push', 'sms'];

/// `22:46:13`, local.
String clockOf(DateTime at) {
  var local = at.toLocal();
  return [
    local.hour,
    local.minute,
    local.second,
  ].map((part) => '$part'.padLeft(2, '0')).join(':');
}

/// Who sent [message]: the service it says it came from, else the server
/// that reported it — `lab/42` is lab's.
String senderOf(OutboxMessage message) =>
    message.sender ?? message.id.split('/').first;

/// What caused [message], in the words the trace has for its step:
/// `action "Rush hour"` for one of the world's own actions, `Leo: tap
/// "Order"` for a gesture on someone's app. The step's id when the trace
/// knows no words for it — it no longer holds it, or heard of it only from
/// a server; null for a message sent under no step.
String? causeOf(OutboxMessage message, WorldTrace? trace) {
  var id = message.step;
  if (id == null) return null;
  var step = trace?.step(id);
  if (step == null || step.verb == null) return id;
  return step.person == worldActionsOwner
      ? step.did
      : '${step.person}: ${step.did}';
}

/// Whether the app showed [push] itself: a notification it posted with the
/// push's title, around when the push was sent.
bool wasShown(OutboxMessage push, List<GuestNotification> posted) =>
    push.kind == 'push' &&
    posted.any(
      (n) =>
          n.title == push.text &&
          n.at.difference(push.at).abs() < const Duration(seconds: 10),
    );

/// One message a person was sent: what it says, who sent it and what
/// caused it, and how to hand it to their app.
class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.cause,
    required this.shown,
    required this.onDeliver,
    required this.onRead,
  });

  final OutboxMessage message;

  /// See [causeOf].
  final String? cause;

  /// Whether the app showed it — a push it posted a notification for.
  final bool shown;

  /// With `type` or `open`; null while the recipient's app is not running.
  final Future<void> Function(String how)? onDeliver;
  final VoidCallback onRead;

  /// What a row says under its title: a push's body, a mail's first line.
  String? get _body => switch (message.kind) {
    'push' => message.subtitle,
    'mail' =>
      message.body
          ?.split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => ''),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var body = _body;
    var marks = [
      if (shown) _Mark(Icons.check, 'shown', color: colors.grn),
      if (message.byTime)
        _Mark(
          Icons.schedule,
          'matched by time',
          color: colors.mut,
          tooltip:
              'Sent by a service that carries no step: joined to the step '
              'that ran just before it',
        ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KindIcon(message.kind),
          const SizedBox(width: FwSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        message.text,
                        style: context.type.bodyStrong,
                      ),
                    ),
                    const SizedBox(width: FwSpacing.md),
                    Text(
                      clockOf(message.at),
                      style: context.type.caption.copyWith(color: colors.mut2),
                    ),
                  ],
                ),
                if (body != null && body.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: FwSpacing.xxs),
                    child: SelectableText(
                      body,
                      style: context.type.body.copyWith(color: colors.ink2),
                    ),
                  ),
                const SizedBox(height: FwSpacing.md),
                LayoutBuilder(
                  builder: (context, constraints) {
                    var from =
                        '${messageKind(message.kind)} from ${senderOf(message)}';
                    var footer = Wrap(
                      spacing: FwSpacing.md,
                      runSpacing: FwSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(from, style: context.type.caption),
                        if (cause case var cause?)
                          FwChip(
                            cause,
                            icon: Icons.subdirectory_arrow_right,
                            mono: true,
                            tooltip: 'What caused it: ${message.step}',
                          ),
                        ...marks,
                      ],
                    );
                    var buttons = DeliveryButtons(
                      message: message,
                      deliver: onDeliver,
                      onRead: message.kind == 'mail' ? onRead : null,
                    );
                    // Beside the footer while both fit; under it, at the
                    // right, once they would squeeze the cause.
                    if (_footerWidth(context, from) +
                            _buttonsWidth(context) +
                            FwSpacing.lg <=
                        constraints.maxWidth) {
                      return Row(
                        children: [
                          Expanded(child: footer),
                          buttons,
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        footer,
                        const SizedBox(height: FwSpacing.sm),
                        Align(alignment: Alignment.centerRight, child: buttons),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

double _textWidth(String words, TextStyle style) {
  var painter = TextPainter(
    text: TextSpan(text: words, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  var width = painter.width;
  painter.dispose();
  return width;
}

extension on MessageRow {
  /// How wide the footer is drawn on one line: where it came from, the
  /// cause's chip and the marks.
  double _footerWidth(BuildContext context, String from) {
    var type = context.type;
    var caption = type.caption;
    var chip = switch (cause) {
      var cause? =>
        _textWidth(cause, type.mono.copyWith(fontSize: caption.fontSize)) +
            FwIconSize.xs +
            FwSpacing.xs +
            2 * FwSpacing.sm +
            2,
      null => 0.0,
    };
    var marks = [
      if (shown) 'shown',
      if (message.byTime) 'matched by time',
    ].map((mark) => _textWidth(mark, caption) + FwIconSize.xs + FwSpacing.xxs);
    var parts = [_textWidth(from, caption), chip, ...marks];
    return parts.fold(0.0, (a, b) => a + b) + parts.length * FwSpacing.md;
  }

  /// How wide its buttons are drawn: what [DeliveryButtons] will show.
  double _buttonsWidth(BuildContext context) {
    var running = onDeliver != null;
    var labels = [
      if (message.kind == 'mail') 'Read it',
      if (message.code != null && running) 'Type it',
      if (message.link != null && running)
        message.kind == 'push' ? 'Tap it' : 'Open',
    ];
    return labels
            .map(
              (label) =>
                  _textWidth(label, context.type.caption) +
                  2 * FwSpacing.lg +
                  2,
            )
            .fold(0.0, (a, b) => a + b) +
        (labels.length - 1).clamp(0, 9) * FwSpacing.sm;
  }
}

/// A message's kind, as a round icon at the head of its row.
class _KindIcon extends StatelessWidget {
  const _KindIcon(this.kind);

  final String kind;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: messageKind(kind),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: colors.panel,
          shape: BoxShape.circle,
          border: Border.all(color: colors.line),
        ),
        child: Icon(messageIcon(kind), size: FwIconSize.md, color: colors.ink2),
      ),
    );
  }
}

/// What became of a message, beside where it came from: `✓ shown`.
class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.label, {required this.color, this.tooltip});

  final IconData icon;
  final String label;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget mark = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: FwIconSize.xs, color: color),
        const SizedBox(width: FwSpacing.xxs),
        Text(label, style: context.type.caption.copyWith(color: color)),
      ],
    );
    return switch (tooltip) {
      var tooltip? => Tooltip(message: tooltip, child: mark),
      null => mark,
    };
  }
}

/// How a message is handed to its recipient's app — the three deliveries a
/// person makes of one: a code *typed*, a push *tapped*, a link *opened* —
/// and, for a mail, *Read it*. A refusal is said beneath, in the world's own
/// words: it says what to do.
class DeliveryButtons extends StatefulWidget {
  const DeliveryButtons({
    super.key,
    required this.message,
    this.deliver,
    this.onRead,
  });

  final OutboxMessage message;

  /// With `type` or `open`; throws the world's refusal. Null while the
  /// recipient's app is not running.
  final Future<void> Function(String how)? deliver;

  /// Opens a mail to read, as its recipient would see it.
  final VoidCallback? onRead;

  @override
  State<DeliveryButtons> createState() => _DeliveryButtonsState();
}

class _DeliveryButtonsState extends State<DeliveryButtons> {
  String? _refused;

  Future<void> _deliver(String how) async {
    setState(() => _refused = null);
    try {
      await widget.deliver!(how);
    } on ActionRefusal catch (refusal) {
      if (mounted) setState(() => _refused = refusal.message);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    var message = widget.message;
    var whose = message.person == null ? 'their' : "${message.person}'s";
    var deliver = widget.deliver;
    var buttons = [
      if (widget.onRead case var read?)
        FwActionButton(
          label: 'Read it',
          acknowledges: false,
          onPressed: () async => read(),
        ),
      if (message.code case var code? when deliver != null)
        FwActionButton(
          label: 'Type it',
          tooltip: 'Types $code into the focused field in $whose app',
          onPressed: () => _deliver('type'),
        ),
      if (message.link case var link? when deliver != null)
        FwActionButton(
          label: message.kind == 'push' ? 'Tap it' : 'Open',
          tooltip: 'Opens $link in $whose app',
          onPressed: () => _deliver('open'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var (i, button) in buttons.indexed) ...[
              if (i > 0) const SizedBox(width: FwSpacing.sm),
              button,
            ],
          ],
        ),
        if (_refused case var refused?)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.only(top: FwSpacing.xs),
              child: Text(
                refused,
                style: context.type.bodyMuted,
                textAlign: TextAlign.end,
              ),
            ),
          ),
      ],
    );
  }
}

/// The deliveries of [message] that opened a link, as the lines under a
/// mail being read: `✓ Opened in Ana's app worldlab://orders/o3 · 23:41:30`.
class DeliveredLines extends StatelessWidget {
  const DeliveredLines({super.key, required this.deliveries});

  final List<WorldDelivery> deliveries;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var delivery in deliveries)
          Padding(
            padding: const EdgeInsets.only(top: FwSpacing.xs),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: FwIconSize.sm,
                  color: colors.grn,
                ),
                const SizedBox(width: FwSpacing.sm),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: delivery.how == 'type'
                              ? "Typed into ${delivery.person}'s app "
                              : "Opened in ${delivery.person}'s app ",
                        ),
                        TextSpan(
                          text: delivery.what,
                          style: context.type.mono.copyWith(
                            fontSize: context.type.caption.fontSize,
                            color: colors.ink2,
                          ),
                        ),
                        if (delivery.at case var at?)
                          TextSpan(text: '  ·  ${clockOf(at)}'),
                      ],
                    ),
                    style: context.type.body.copyWith(color: colors.grn),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
