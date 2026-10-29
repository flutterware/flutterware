import 'dart:async';

import 'package:flutterware/devices.dart';
import 'package:material_ui/material_ui.dart';

import '../session/job.dart' show ActionRefusal;
import '../ui/action_button.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'open_world.dart';
import 'platform/studio_platform.dart';
import 'world_messages.dart';
import 'world_trace.dart';

/// [child], a person's screen, with what reaches them on top: each message
/// a server sends them and each notification their app posts, as a banner
/// for a few seconds, the way a phone shows one. A phone's come down from
/// the top; a desktop's sit in the corner.
///
/// Clicking one does what tapping it would: a notification opens in the
/// app, and an email opens in the person's panel through [onRead].
class MessageBanners extends StatefulWidget {
  const MessageBanners({
    super.key,
    required this.world,
    required this.person,
    required this.device,
    required this.child,
    this.onRead,
  });

  final OpenWorld world;
  final WorldPerson person;
  final Device device;
  final Widget child;

  /// Opens an email to read, by its message id.
  final ValueChanged<String>? onRead;

  @override
  State<MessageBanners> createState() => _MessageBannersState();
}

class _MessageBannersState extends State<MessageBanners> {
  /// How long a banner stays.
  static const _shownFor = Duration(seconds: 8);

  /// How long it stays once the pointer leaves it.
  static const _afterHover = Duration(seconds: 2);

  /// How many banners can wait under the one on top, showing as a stack.
  static const _behind = 2;

  WorldTrace? _trace;
  GuestNotifications? _notifications;
  final _heard = <StreamSubscription<Object?>>[];
  Timer? _redraw;
  Timer? _expire;

  final _dismissed = <String>{};
  final _keptUntil = <String, DateTime>{};
  String? _hovered;

  /// What a click on a banner was refused with, by its id.
  final _refused = <String, String>{};

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(MessageBanners old) {
    super.didUpdateWidget(old);
    _follow();
  }

  /// Listens to the world's trace and the app's notifications — both new
  /// after a restart.
  void _follow() {
    var trace = widget.world.tracer?.trace;
    var notifications = widget.person.platform?.notifications;
    if (identical(trace, _trace) && identical(notifications, _notifications)) {
      return;
    }
    _trace = trace;
    _notifications = notifications;
    for (var subscription in _heard) {
      unawaited(subscription.cancel());
    }
    _heard
      ..clear()
      ..addAll([
        ?trace?.changed.listen(_soon),
        ?notifications?.shows.listen(_soon),
      ]);
  }

  /// A burst of events is one redraw, and none of them lands mid-build.
  void _soon(Object? _) {
    _redraw ??= Timer(Duration.zero, () {
      _redraw = null;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (var subscription in _heard) {
      unawaited(subscription.cancel());
    }
    _redraw?.cancel();
    _expire?.cancel();
    super.dispose();
  }

  /// What is on the screen now, newest first, and when the next one goes.
  (List<Received>, DateTime?) _showing() {
    var now = DateTime.now();
    var received = receivedBy(
      _trace?.outbox(person: widget.person.name, limit: 10) ??
          const <OutboxMessage>[],
      _notifications?.shown ?? const <GuestNotification>[],
    );
    DateTime? next;
    var showing = <Received>[];
    for (var each in received) {
      var id = each.id;
      // Opened is the world's, and outlives this screen: a banner clicked on
      // the stage stays gone on the person in focus.
      if (_dismissed.contains(id) || widget.world.opened.contains(id)) {
        continue;
      }
      var until = each.at.add(_shownFor);
      if (_keptUntil[id] case var kept? when kept.isAfter(until)) {
        until = kept;
      }
      if (_hovered != id && !until.isAfter(now)) continue;
      showing.add(each);
      if (_hovered != id && (next == null || until.isBefore(next))) {
        next = until;
      }
      if (showing.length == 1 + _behind) break;
    }
    return (showing, next);
  }

  void _dismiss(String id) => setState(() {
    _dismissed.add(id);
    _refused.remove(id);
    if (_hovered == id) _hovered = null;
  });

  /// Does what tapping [received] would.
  Future<void> _tap(Received received) async {
    var id = received.id;
    var world = widget.world;
    var person = widget.person;
    if (received.notification case var notification?) {
      if (person.running) person.platform?.notifications.tap(notification);
      world.markOpened(id);
      _dismiss(id);
      return;
    }
    var message = received.message!;
    switch (message.kind) {
      case 'mail':
        world.markOpened(id);
        widget.onRead?.call(id);
        _dismiss(id);
      case 'push' when message.link != null && person.running:
        await _deliver(received, 'open');
      default:
        _dismiss(id);
    }
  }

  Future<void> _deliver(Received received, String how) async {
    var id = received.id;
    setState(() => _refused.remove(id));
    try {
      await widget.world.deliver(id, how: how, actor: 'human');
      if (mounted) _dismiss(id);
    } on ActionRefusal catch (refusal) {
      if (mounted) {
        setState(() {
          _refused[id] = refusal.message;
          _keptUntil[id] = DateTime.now().add(_shownFor);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var (showing, next) = _showing();
    _expire?.cancel();
    if (next != null) {
      _expire = Timer(next.difference(DateTime.now()), () {
        if (mounted) setState(() {});
      });
    }
    var device = widget.device;
    var desktop = device.kind == DeviceKind.desktop;
    var app = widget.person.spec.app?.entrypoint ?? widget.person.name;
    var running = widget.person.running;
    Widget banner(Received received) {
      var id = received.id;
      return KeyedSubtree(
        key: ValueKey(id),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = id),
          onExit: (_) => setState(() {
            if (_hovered == id) _hovered = null;
            _keptUntil[id] = DateTime.now().add(_afterHover);
          }),
          child: _Arriving(
            child: MessageBanner(
              received: received,
              app: app,
              refused: _refused[id],
              onTap: () => unawaited(_tap(received)),
              onEnterCode: received.code != null && running
                  ? () => _deliver(received, 'type')
                  : null,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (showing.isNotEmpty)
          Positioned(
            top: desktop ? FwSpacing.lg : device.insetTop,
            right: FwSpacing.md,
            left: desktop ? null : FwSpacing.md,
            width: desktop ? 340 : null,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                // The newest on top, the rest as the edges of a stack
                // under it, the way a phone groups what arrives at once.
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var depth = showing.length - 1; depth > 0; depth--)
                      Positioned(
                        left: FwSpacing.md * depth,
                        right: FwSpacing.md * depth,
                        top: FwSpacing.sm * depth,
                        bottom: -FwSpacing.sm * depth,
                        child: const _Edge(),
                      ),
                    banner(showing.first),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One banner: where it comes from, who sent it, what it says — and, for a
/// message with a code, the button that types it.
class MessageBanner extends StatelessWidget {
  const MessageBanner({
    super.key,
    required this.received,
    required this.app,
    this.refused,
    this.onTap,
    this.onEnterCode,
  });

  final Received received;

  /// The recipient's app: who a push or a notification is from.
  final String app;

  /// Why a click did nothing, in place of what it says.
  final String? refused;

  final VoidCallback? onTap;

  /// Types its code into the app; null when it has none, or the app is not
  /// running.
  final Future<void> Function()? onEnterCode;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var lines = linesOf(received, app: app);
    var (source, title, text, more) = switch (received.kind) {
      'sms' => ('Messages', lines.from, lines.text, null),
      'mail' => ('Mail', lines.from, lines.text, lines.more),
      _ => (app, lines.text, lines.more, null),
    };
    var radius = BorderRadius.circular(context.radii.radiusLarge);
    return Container(
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: radius,
        border: Border.all(color: colors.line),
        boxShadow: context.elevation.md,
      ),
      child: Tappable(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: colors.panel,
                  borderRadius: BorderRadius.circular(
                    context.radii.radiusSmall,
                  ),
                  border: Border.all(color: colors.line2),
                ),
                child: Icon(
                  messageIcon(received.kind),
                  size: FwIconSize.sm,
                  color: colors.ink2,
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
                            source,
                            style: context.type.caption.copyWith(
                              color: colors.mut,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          'now',
                          style: context.type.caption.copyWith(
                            color: colors.mut2,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      title,
                      style: context.type.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (refused case var refused?)
                      Text(refused, style: context.type.bodyMuted)
                    else ...[
                      if (text != null && text.isNotEmpty)
                        Text(
                          text,
                          style: context.type.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (more != null && more.isNotEmpty)
                        Text(
                          more,
                          style: context.type.bodyMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ],
                ),
              ),
              if (onEnterCode case var enter?) ...[
                const SizedBox(width: FwSpacing.md),
                Padding(
                  padding: const EdgeInsets.only(top: FwSpacing.md),
                  child: FwActionButton(
                    label: 'Enter code',
                    acknowledges: false,
                    onPressed: enter,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A banner waiting under the one on top, of which only the edge shows.
class _Edge extends StatelessWidget {
  const _Edge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.colors.bg,
      borderRadius: BorderRadius.circular(context.radii.radiusLarge),
      border: Border.all(color: context.colors.line),
      boxShadow: context.elevation.sm,
    ),
  );
}

/// A banner coming down into place as it arrives.
class _Arriving extends StatelessWidget {
  const _Arriving({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (t - 1) * 16), child: child),
    ),
    child: child,
  );
}
