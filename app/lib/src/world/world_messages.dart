import 'package:material_ui/material_ui.dart';

import '../session/job.dart' show ActionRefusal;
import '../ui/action_button.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'open_world.dart';
import 'platform/studio_platform.dart';
import 'world_trace.dart';

/// `SMS`, `Push`, `Email`.
String messageKind(String kind) => switch (kind) {
  'sms' => 'SMS',
  'push' => 'Push',
  'mail' => 'Email',
  'notification' => 'Notification',
  var other => other,
};

IconData messageIcon(String kind) => switch (kind) {
  'push' || 'notification' => Icons.notifications_none,
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

/// `22:46`, local: the time a phone puts on a message.
String timeOf(DateTime at) {
  var local = at.toLocal();
  return [
    local.hour,
    local.minute,
  ].map((part) => '$part'.padLeft(2, '0')).join(':');
}

/// Who sent [message]: the service it says it came from, else the server
/// that reported it — `lab/42` is lab's.
String senderOf(OutboxMessage message) =>
    message.sender ?? message.id.split('/').first;

/// Whether the app showed [push] itself: a notification it posted with the
/// push's title, around when the push was sent.
bool wasShown(OutboxMessage push, List<GuestNotification> posted) =>
    push.kind == 'push' &&
    posted.any(
      (n) =>
          n.title == push.text &&
          n.at.difference(push.at).abs() < const Duration(seconds: 10),
    );

/// Something that reached a person: a message a server sent them, or a
/// notification their app posted.
class Received {
  const Received.message(OutboxMessage this.message) : notification = null;

  const Received.notification(GuestNotification this.notification)
    : message = null;

  final OutboxMessage? message;
  final GuestNotification? notification;

  /// The message's id; a notification's, made unique by when it was posted,
  /// since an app reuses its ids.
  String get id => switch ((message, notification)) {
    (var message?, _) => message.id,
    (_, var n?) => 'notification/${n.id}/${n.at.microsecondsSinceEpoch}',
    _ => '',
  };

  DateTime get at => message?.at ?? notification!.at;

  /// `sms`, `push`, `mail` or `notification`.
  String get kind => message?.kind ?? 'notification';

  /// The one-time code in it.
  String? get code => message?.code;
}

/// What a person received, newest first: [messages] servers sent them and
/// the notifications their app [posted]. A push the app showed a
/// notification for is listed once, as the notification.
List<Received> receivedBy(
  Iterable<OutboxMessage> messages,
  List<GuestNotification> posted,
) => [
  for (var message in messages)
    if (!wasShown(message, posted)) Received.message(message),
  for (var notification in posted) Received.notification(notification),
]..sort((a, b) => b.at.compareTo(a.at));

/// What a phone shows of [received]: who it is from, what it says and a
/// line more. A push and a notification come from [app], the recipient's
/// app.
({String from, String text, String? more}) linesOf(
  Received received, {
  required String app,
}) {
  if (received.notification case var n?) {
    return (from: app, text: n.title ?? '', more: n.body);
  }
  var message = received.message!;
  return switch (message.kind) {
    'push' => (from: app, text: message.text, more: message.subtitle),
    'mail' => (
      from: senderOf(message),
      text: message.text,
      more: message.body
          ?.split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => ''),
    ),
    _ => (from: senderOf(message), text: message.text, more: null),
  };
}

/// One row of a person's messages, as their phone would list it: who it is
/// from, what it says and when. An email opens to be read; a code or a
/// notification has a button that hands it to their app.
class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.received,
    required this.app,
    required this.unread,
    this.onDeliver,
    this.onOpenNotification,
    this.onRead,
  });

  final Received received;

  /// The recipient's app: who a push or a notification is from.
  final String app;

  /// Not yet opened or handed to the app.
  final bool unread;

  /// With `type` or `open`; null while the recipient's app is not running.
  final Future<void> Function(String how)? onDeliver;

  /// Taps the notification the app posted; null while the app is not
  /// running.
  final VoidCallback? onOpenNotification;

  /// Opens an email to read.
  final VoidCallback? onRead;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var lines = linesOf(received, app: app);
    var mail = received.kind == 'mail';
    Widget words(String text, TextStyle style, {int? maxLines}) => mail
        ? Text(
            text,
            style: style,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
          )
        : SelectableText(text, style: style);
    var more = lines.more;
    var row = Container(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.lg,
        FwSpacing.xl,
        FwSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: FwSpacing.lg,
            height: FwIconSize.md,
            child: unread
                ? Center(
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: FwSpacing.xs),
          Tooltip(
            message: messageKind(received.kind),
            child: Icon(
              messageIcon(received.kind),
              size: FwIconSize.md,
              color: colors.mut,
            ),
          ),
          const SizedBox(width: FwSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        lines.from,
                        style: context.type.bodyStrong,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: FwSpacing.md),
                    Text(
                      timeOf(received.at),
                      style: context.type.caption.copyWith(color: colors.mut2),
                    ),
                  ],
                ),
                words(lines.text, context.type.body),
                if (more != null && more.isNotEmpty)
                  words(
                    more,
                    context.type.bodyMuted,
                    maxLines: mail ? 1 : null,
                  ),
              ],
            ),
          ),
          const SizedBox(width: FwSpacing.md),
          DeliveryButtons(
            received: received,
            deliver: onDeliver,
            openNotification: onOpenNotification,
          ),
          if (mail)
            Padding(
              padding: const EdgeInsets.only(left: FwSpacing.sm, top: 2),
              child: Icon(
                Icons.chevron_right,
                size: FwIconSize.md,
                color: colors.mut2,
              ),
            ),
        ],
      ),
    );
    return mail ? Tappable(onTap: onRead, child: row) : row;
  }
}

/// How a message is handed to its recipient's app: a code typed, the way
/// autofill offers one, or a notification opened, as tapping it would. A
/// refusal is said beneath, in the world's own words: it says what to do.
class DeliveryButtons extends StatefulWidget {
  const DeliveryButtons({
    super.key,
    required this.received,
    this.deliver,
    this.openNotification,
  });

  final Received received;

  /// With `type` or `open`; throws the world's refusal. Null while the
  /// recipient's app is not running.
  final Future<void> Function(String how)? deliver;

  /// Taps the notification the app posted; null while the app is not
  /// running.
  final VoidCallback? openNotification;

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
    var received = widget.received;
    var message = received.message;
    var person = message?.person;
    var whose = person == null ? 'their' : "$person's";
    var deliver = widget.deliver;
    var buttons = [
      if (received.code case var code? when deliver != null)
        FwActionButton(
          label: 'Enter code',
          tooltip: 'Types $code into the selected field in $whose app',
          onPressed: () => _deliver('type'),
        ),
      if (message != null &&
          message.kind == 'push' &&
          message.link != null &&
          deliver != null)
        FwActionButton(
          label: 'Open',
          tooltip: 'Opens it in $whose app, as tapping it would',
          onPressed: () => _deliver('open'),
        ),
      if (widget.openNotification case var open?)
        FwActionButton(
          label: 'Open',
          acknowledges: false,
          tooltip: 'Opens it in the app, as tapping it would',
          onPressed: () async => open(),
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
            constraints: const BoxConstraints(maxWidth: 240),
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
