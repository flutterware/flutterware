/// A command plugin: everything about push notifications that a developer —
/// or an agent — needs to reach from outside the app.
///
/// This is the sample that argues for the whole bridge. A push is the
/// canonical thing you cannot test: it needs a backend, a device token, and
/// somebody willing to send you one at the moment you are looking at the
/// screen. Everything below reaches that code path directly, in about a
/// hundred lines of declaration, and the same declaration is what the cockpit
/// draws, what `fw` turns into flags, and what an agent reads as a schema.
///
/// It is deliberately *not* a notification implementation. `PushService` is
/// the app's own product code; this plugin holds no state and makes no
/// decisions. A plugin that reimplements the feature it is meant to drive can
/// pass every test while the app stays broken.
///
/// Step 7 of `docs/superpowers/specs/2026-08-11-devbar-run-bridge-design.md`.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/channels.dart';
import 'package:flutterware/channels_ui.dart';
import 'package:flutterware/devbar.dart';

import '../notifications/push_service.dart';

class NotificationsPlugin implements DevbarPlugin, DevbarPanelSource {
  NotificationsPlugin._(this.devbar, this.service) {
    // Widget mode *and* descriptor mode, from one declaration: the overlay tab
    // below renders [PanelView] over this plugin's own descriptor, which is
    // the same widget the cockpit draws. Nothing here describes the panel
    // twice — see [_OverlayTab].
    devbar.ui.addTab(Tab(text: panelLabel), _OverlayTab(this));
    service.addListener(_onServiceChanged);
  }

  static NotificationsPlugin Function(DevbarState) init({
    required PushService service,
  }) =>
      (devbar) => NotificationsPlugin._(devbar, service);

  final DevbarState devbar;
  final PushService service;

  @override
  String get panelId => 'push';

  @override
  String get panelLabel => 'Push';

  /// The panel being served, once the bridge has mounted it. Null in an app
  /// that has no devbar at all — the overlay tab says so rather than drawing
  /// half a screen.
  Panel? get panel => _panel;
  Panel? _panel;

  /// Ring event id → the message it reported. An item action is invoked with
  /// nothing but that id, so this is what lets `open` know which notification
  /// the row belonged to.
  final _messageByEvent = <int, String>{};

  /// Which messages have reached the feed, by id.
  ///
  /// A set rather than a count, because **the inbox can shrink**: `clear`
  /// empties it, and a high-water mark then sits above the length forever, so
  /// nothing is ever emitted again. The feed went quiet for the rest of the
  /// run and said nothing about it — found by driving it, 2026-08-11.
  final _emitted = <String>{};

  @override
  void describePanel(Panel panel) {
    _panel = panel;

    panel.knob(
      KnobDescriptor(
        name: 'permission',
        kind: KnobKind.picker,
        value: service.permission.label,
        defaultValue: PushPermission.notDetermined.label,
        options: [for (var value in PushPermission.values) value.label],
        description:
            'What the OS has told the app. Delivery is refused unless this '
            'is granted — the same refusal a real device gives you.',
      ),
      read: () => service.permission.label,
      write: (value) {
        var permission = PushPermission.byLabel(value);
        // Left alone rather than cleared: a stale picker must not be able to
        // put the app into a state nobody named.
        if (permission != null) service.permission = permission;
      },
    );

    panel.state(
      'registration',
      'Registration',
      description: 'What the app would tell a push backend about itself.',
      fields: [
        FieldDescriptor('token', 'Device token', primary: true),
        FieldDescriptor('permission', 'Permission'),
        FieldDescriptor('delivered', 'Delivered', kind: FieldKind.number),
        FieldDescriptor('links', 'Deep links'),
      ],
      read: () => {
        'token': PushService.token,
        'permission': service.permission.label,
        'delivered': service.inbox.length,
        'links': [for (var link in service.links) link.path].join(' '),
      },
    );

    panel.feed(
      'inbox',
      'Inbox',
      description: 'Every notification this run delivered, tapped or not.',
      fields: [
        FieldDescriptor('title', 'Title', primary: true),
        FieldDescriptor('body', 'Body'),
        FieldDescriptor('link', 'Link'),
        FieldDescriptor('receivedAt', 'Received', kind: FieldKind.timestamp),
      ],
    );

    panel.action(
      PluginAction(
        'send',
        'Send a notification',
        description:
            'Delivers a push to the running app, exactly as the platform '
            'would. Refused when permission is not granted, or when the link '
            'points at a screen this app does not have.',
        parameters: [
          ActionParameter(
            'title',
            'Title',
            description: 'The bold line — "Your order is ready".',
          ),
          ActionParameter(
            'body',
            'Body',
            required: false,
            description: 'The second line, if the notification has one.',
          ),
          ActionParameter(
            'link',
            'Deep link',
            kind: ActionParameterKind.choice,
            required: false,
            description: 'Where tapping it goes. Omit for an announcement.',
            options: [
              for (var link in service.links)
                ActionOption(link.path, label: link.label),
            ],
          ),
        ],
      ),
      _send,
    );

    panel.itemAction(
      'inbox',
      PluginAction(
        'open',
        'Open',
        description:
            'Follows this notification, the way tapping it on a lock screen '
            'would — the app navigates.',
      ),
      _open,
    );

    panel.action(
      PluginAction(
        'clear',
        'Clear the inbox',
        danger: true,
        description: 'Forgets every notification delivered this run.',
      ),
      (_) {
        service.clear();
        return {'cleared': true};
      },
    );

    // Anything delivered before the bridge mounted — an app that pushes on
    // startup is the ordinary case, not a corner.
    _flush();
  }

  Map<String, Object?> _send(Map<String, Object?> args) {
    var title = args['title'];
    if (title is! String || title.trim().isEmpty) {
      throw ArgumentError('send needs a `title`');
    }
    var link = args['link'] as String?;
    var body = args['body'] as String?;
    // `deliver` throws [PushRefused] with a sentence saying why; that becomes
    // the error frame, so a refusal reads the same in the cockpit, in `fw` and
    // to an agent.
    var message = service.deliver(
      title: title,
      body: body == null || body.isEmpty ? null : body,
      link: link == null || link.isEmpty ? null : link,
    );
    return {'id': message.id, 'link': message.link, 'delivered': true};
  }

  Map<String, Object?> _open(Map<String, Object?> args) {
    var event = args['event'];
    var id = event is int ? _messageByEvent[event] : null;
    if (id == null) {
      throw ArgumentError(
        'open is an item action — it needs the `event` id of the row it was '
        'pressed on',
      );
    }
    var message = service.open(id);
    return {'id': message.id, 'opened': message.link ?? '(no link)'};
  }

  void _onServiceChanged() {
    _flush();
    // Values moved without the shape moving: permission flipped in-app, or a
    // notification was tapped. Coalesced by the transport's nudge.
    _panel?.announce();
  }

  /// Mirrors the inbox onto the feed, once per message.
  ///
  /// Driven by the service rather than by [_send], deliberately: a
  /// notification the *app* delivers to itself has to appear too, and a feed
  /// that only echoed the command would be a log of this plugin rather than of
  /// the feature.
  void _flush() {
    var panel = _panel;
    if (panel == null) return;
    for (var message in service.inbox) {
      if (!_emitted.add(message.id)) continue;
      var id = panel.emit('inbox', {
        'title': message.title,
        'body': message.body,
        'link': message.link,
        'receivedAt': message.receivedAt.millisecondsSinceEpoch,
      }, rid: message.id);
      _messageByEvent[id] = message.id;
    }
  }

  @override
  void dispose() {
    service.removeListener(_onServiceChanged);
  }
}

/// The overlay's tab — [PanelView] over this plugin's own descriptor.
///
/// One declaration, two hosts. Nothing here knows what the panel contains;
/// it renders whatever `describePanel` registered, and hands every interaction
/// straight to the code the wire handlers call. So an app running on a phone
/// with no flutterware attached gets the identical screen the cockpit shows,
/// and the two cannot drift because there is only one of them.
class _OverlayTab extends StatefulWidget {
  const _OverlayTab(this.plugin);

  final NotificationsPlugin plugin;

  @override
  State<_OverlayTab> createState() => _OverlayTabState();
}

class _OverlayTabState extends State<_OverlayTab> {
  final _states = <String, Map<String, Object?>>{};
  final _results = <String, String>{};

  NotificationsPlugin get _plugin => widget.plugin;

  @override
  void initState() {
    super.initState();
    _plugin.service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _plugin.service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Every interaction goes back through the [Panel] — the same handler the
  /// wire reaches, never a copy of it.
  Future<void> _guard(String id, Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e) {
      if (mounted) setState(() => _results[id] = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    var panel = _plugin.panel;
    if (panel == null) {
      return const Center(
        child: Text('The push panel is not mounted in this app.'),
      );
    }
    return PanelView(
      descriptor: panel.descriptor,
      states: _states,
      results: _results,
      onKnob: (name, value) =>
          unawaited(_guard(name, () async => panel.writeKnob(name, value))),
      onAction: (id, args) => unawaited(
        _guard(id, () async {
          var result = await panel.run(id, args);
          if (mounted) setState(() => _results[id] = '$result');
        }),
      ),
      onItemAction: (id, event) => unawaited(
        _guard(id, () async {
          var result = await panel.run(id, {'event': event});
          if (mounted) setState(() => _results[id] = '$result');
        }),
      ),
      onReadState: (id) => unawaited(
        _guard(id, () async {
          var snapshot = await panel.readState(id);
          if (mounted) setState(() => _states[id] = snapshot);
        }),
      ),
    );
  }
}
