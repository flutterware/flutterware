import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../inspect/inspect_dock.dart' show InspectDockTab, InspectTabStrip;
import '../plugins/native/run_core.dart' show RunCore;
import '../run/flag_memory.dart';
import '../run/logs_tab.dart';
import '../run/network_tab.dart';
import '../run/panels_tab.dart';
import '../run/run_sources.dart' show LiveRunChannels;
import '../ui/action_button.dart';
import '../ui/menu.dart';
import '../ui/popover.dart' show PopoverAlign;
import '../ui/stage.dart' show stageGroundColor;
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'mail_view.dart';
import 'open_world.dart';
import 'platform/studio_platform.dart';
import 'world_messages.dart';
import 'world_person.dart';
import 'world_trace.dart';

/// One person in focus: their device as large as the room allows, on the
/// stage's ground, and beside it their panel — who they are, what the
/// servers sent them, and Run's own Network, App and Logs views of their
/// app, the same panes Run shows for any app.
class PersonFocus extends StatefulWidget {
  const PersonFocus({
    super.key,
    required this.world,
    required this.person,
    required this.color,
    required this.run,
    required this.reading,
    required this.onRead,
    required this.onScale,
  });

  final OpenWorld world;
  final WorldPerson person;
  final Color color;

  /// Run's core, whose views the panel shows of the person's app; null where
  /// the project declares no run plugin.
  final RunCore? run;

  /// The mail being read, by its message id.
  final String? reading;

  /// Opens a mail to read, or — with null — goes back to the messages.
  final ValueChanged<String?> onRead;

  /// Told the scale the device is drawn at, so it renders for it.
  final void Function(double scale) onScale;

  @override
  State<PersonFocus> createState() => _PersonFocusState();
}

class _PersonFocusState extends State<PersonFocus> {
  var _tab = 'messages';

  /// The panel never narrower than this: the device yields first.
  static const _panelMinimum = 420.0;

  static const _around = FwSpacing.xxxl;

  @override
  Widget build(BuildContext context) {
    var person = widget.person;
    var size = personSize(person);
    return LayoutBuilder(
      builder: (context, constraints) {
        var app = hasApp(person);
        var scale = app
            ? [
                1.0,
                (constraints.maxHeight - 2 * FwSpacing.xl) / size.height,
                (constraints.maxWidth - _panelMinimum - 2 * _around) /
                    size.width,
              ].reduce(min).clamp(0.1, 1.0)
            : 1.0;
        if (app) widget.onScale(scale);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: stageGroundColor(context.colors),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _around),
                child: Center(
                  child: app
                      ? ScaledBox(
                          size: size,
                          scale: scale,
                          child: PersonDevice(
                            person: person,
                            scale: scale,
                            ignores: (_) => false,
                          ),
                        )
                      : HeadlessCard(
                          name: person.name,
                          actions: actionsFor(
                            person.name,
                            widget.world.actions.keys,
                          ),
                        ),
                ),
              ),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.colors.bg,
                  border: Border(left: BorderSide(color: context.colors.line)),
                ),
                child: _panel(context),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context) {
    var world = widget.world;
    var person = widget.person;
    var messages =
        world.tracer?.trace.outbox(person: person.name, limit: 60) ??
        const <OutboxMessage>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PersonHeader(
          person: person,
          color: widget.color,
          sync: world.tracer?.syncOf(person.name),
        ),
        InspectTabStrip(
          tabs: [
            InspectDockTab(
              id: 'messages',
              label: 'Messages',
              badge: messages.length,
              body: _noBody,
            ),
            const InspectDockTab(
              id: 'network',
              label: 'Network',
              body: _noBody,
            ),
            const InspectDockTab(id: 'app', label: 'App', body: _noBody),
            const InspectDockTab(id: 'logs', label: 'Logs', body: _noBody),
          ],
          current: _tab,
          onSelect: (tab) {
            setState(() => _tab = tab);
            // A mail is read in the messages; leaving them closes it.
            if (tab != 'messages') widget.onRead(null);
          },
        ),
        Expanded(child: _pane(context, messages)),
      ],
    );
  }

  Widget _pane(BuildContext context, List<OutboxMessage> messages) {
    var world = widget.world;
    var person = widget.person;
    var trace = world.tracer?.trace;
    Widget note(String text) => Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Text(text, style: context.type.bodyMuted),
    );
    Future<void> Function(String how)? deliverTo(OutboxMessage message) =>
        person.running
        ? (how) => world.deliver(message.id, how: how, actor: 'human')
        : null;
    if (_tab == 'messages') {
      if (widget.reading case var id?) {
        if (trace?.messageById(id) case var mail?) {
          return MailView(
            message: mail,
            snapshots: world.snapshots,
            cause: causeOf(mail, trace),
            deliveries: [
              for (var delivery
                  in world.deliveries[mail.id] ?? const <WorldDelivery>[])
                if (delivery.how == 'open') delivery,
            ],
            claims: (link) => trace?.claims(person.name, link) ?? false,
            onBack: () => widget.onRead(null),
            onDeliver: person.running
                ? (link) => world.deliver(mail.id, link: link, actor: 'human')
                : null,
          );
        }
      }
      if (messages.isEmpty) {
        return note('No server has sent ${person.name} anything yet.');
      }
      var posted =
          person.platform?.notifications.shown ?? const <GuestNotification>[];
      return ListView(
        children: [
          for (var message in messages)
            MessageRow(
              message: message,
              cause: causeOf(message, trace),
              shown: wasShown(message, posted),
              onDeliver: deliverTo(message),
              onRead: () => widget.onRead(message.id),
            ),
        ],
      );
    }
    if (!hasApp(person)) return note('${person.name} has no app.');
    var handle = person.running ? person.handle : null;
    if (handle == null) return note("${person.name}'s app is not running.");
    var run = widget.run;
    // Keyed by the app as it runs now: a world restarted gives the person
    // the same run key and a new app, which is another app to attach to.
    var app = ValueKey((handle.key, handle.startedAt));
    return switch (_tab) {
      'network' => NetworkTab(key: app, handle: handle),
      'app' when run != null => PanelsTab(
        key: app,
        handle: handle,
        channels: const LiveRunChannels(),
        memory: FlagMemory(run.runDir, files: run.files),
      ),
      'logs' when run != null => LogsTab(key: app, core: run, handle: handle),
      _ => note('This project declares no run plugin to read it with.'),
    };
  }
}

/// A strip draws the tabs; the pane below is the panel's own.
Widget _noBody(BuildContext _) => const SizedBox.shrink();

/// Who the panel is about: their colour and name, how the world knows them
/// and what they use, their synced database's state for an app with one —
/// and, under `⋯`, what the studio can do to their app as its platform.
class _PersonHeader extends StatefulWidget {
  const _PersonHeader({
    required this.person,
    required this.color,
    required this.sync,
  });

  final WorldPerson person;
  final Color color;

  /// The app's database panel's `sync` state, as the world last read it.
  final Map<String, Object?>? sync;

  @override
  State<_PersonHeader> createState() => _PersonHeaderState();
}

class _PersonHeaderState extends State<_PersonHeader> {
  @override
  Widget build(BuildContext context) {
    var person = widget.person;
    var spec = person.spec;
    var colors = context.colors;
    var lines = [
      [?spec.email, ?spec.phone, appLine(person)].join(' · '),
      if (widget.sync case var sync?) _syncLine(sync),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.lg,
        FwSpacing.xl,
        FwSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PersonDot(widget.color),
                    const SizedBox(width: FwSpacing.md),
                    Flexible(
                      child: Text(
                        person.name,
                        style: context.type.heading,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FwSpacing.xxs),
                for (var line in lines)
                  SelectableText(
                    line,
                    style: context.type.caption.copyWith(color: colors.mut),
                    maxLines: 1,
                  ),
              ],
            ),
          ),
          if (person.platform case var platform? when person.running)
            _PlatformMenu(person: person.name, platform: platform),
        ],
      ),
    );
  }

  /// `Synced at 12:03:04 · nothing to upload`: a clock time rather than an
  /// age, since nothing redraws this while nothing changes.
  static String _syncLine(Map<String, Object?> state) {
    var synced = switch (state['lastSyncedAt']) {
      String at when DateTime.tryParse(at) != null =>
        'Synced at ${clockOf(DateTime.parse(at))}',
      _ => 'Not synced yet',
    };
    var pending = state['pendingUploads'];
    var client = state['clientId'];
    return [
      synced,
      pending is int && pending > 0
          ? '$pending to upload'
          : 'nothing to upload',
      if (client is String) 'client ${client.split('-').first}',
    ].join(' · ');
  }
}

/// What the studio, standing in for the platform, can do to one person's
/// app — open a link in it, where the OS would deliver one; show what it
/// posted and opened; send it to the background — behind a `⋯`.
class _PlatformMenu extends StatefulWidget {
  const _PlatformMenu({required this.person, required this.platform});

  final String person;
  final StudioPlatform platform;

  @override
  State<_PlatformMenu> createState() => _PlatformMenuState();
}

class _PlatformMenuState extends State<_PlatformMenu> {
  @override
  Widget build(BuildContext context) {
    var platform = widget.platform;
    var person = widget.person;
    var posted = platform.notifications.shown;
    var opened = platform.urls.opened;
    var background = platform.system.inBackground;
    return Menu(
      align: PopoverAlign.end,
      minWidth: 240,
      entries: [
        MenuItem(
          "Open a link in $person's app…",
          icon: Icons.link,
          onSelected: _openLink,
        ),
        MenuItem(
          'Notifications posted',
          icon: Icons.notifications_none,
          shortcut: '${posted.length}',
          onSelected: posted.isEmpty ? null : _notifications,
        ),
        if (opened.isNotEmpty)
          MenuItem(
            'Pages it opened',
            icon: Icons.open_in_browser,
            shortcut: '${opened.length}',
            onSelected: _pages,
          ),
        const MenuDivider(),
        MenuItem(
          background ? 'Bring to the front' : 'Send to the background',
          icon: background ? Icons.open_in_new : Icons.home_outlined,
          // What a phone does to an app it no longer shows: the framework
          // stops asking for frames, and its memory is given back.
          onSelected: () =>
              setState(() => platform.system.inBackground = !background),
        ),
      ],
      builder: (context, controller) => Tooltip(
        message: "$person's app, as its platform",
        child: Tappable(
          onTap: controller.toggle,
          borderRadius: BorderRadius.circular(context.radii.radius),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(context.radii.radius),
              border: Border.all(color: context.colors.line),
            ),
            child: Icon(
              Icons.more_horiz,
              size: FwIconSize.md,
              color: context.colors.ink2,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openLink() async {
    var platform = widget.platform;
    var link = TextEditingController();
    String? said;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          void open() {
            if (platform.links.open(link.text.trim())) {
              Navigator.of(context).pop();
            } else {
              setDialog(
                () => said =
                    "${widget.person}'s app is not listening for links: it "
                    'registers no handler with app_links, or has not '
                    'started it yet.',
              );
            }
          }

          return AlertDialog(
            title: Text("Open a link in ${widget.person}'s app"),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Delivered where the OS would deliver it: to the app’s '
                    'link handler.',
                    style: context.type.bodyMuted,
                  ),
                  const SizedBox(height: FwSpacing.md),
                  TextField(
                    controller: link,
                    autofocus: true,
                    onSubmitted: (_) => open(),
                  ),
                  if (said case var said?) ...[
                    const SizedBox(height: FwSpacing.sm),
                    Text(said, style: context.type.bodyMuted),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(onPressed: open, child: const Text('Open')),
            ],
          );
        },
      ),
    );
    link.dispose();
  }

  Future<void> _notifications() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text("Notifications ${widget.person}'s app posted"),
      content: SizedBox(
        width: 460,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var notification in widget.platform.notifications.shown)
              Padding(
                padding: const EdgeInsets.only(bottom: FwSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notification.title ?? '',
                            style: context.type.bodyStrong,
                          ),
                          if (notification.body case var body?)
                            Text(body, style: context.type.body),
                          Text(
                            clockOf(notification.at),
                            style: context.type.caption,
                          ),
                        ],
                      ),
                    ),
                    FwActionButton(
                      label: 'Tap it',
                      onPressed: () async {
                        widget.platform.notifications.tap(notification);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _pages() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text("Pages ${widget.person}'s app opened"),
      content: SizedBox(
        width: 460,
        child: SelectableText(
          widget.platform.urls.opened.join('\n'),
          style: context.type.body,
        ),
      ),
    ),
  );
}

/// The column's way back — to the messages, or to what a view was opened
/// from.
class ColumnBack extends StatelessWidget {
  const ColumnBack(this.label, {super.key, required this.onBack});

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.md,
      FwSpacing.md,
      FwSpacing.lg,
      FwSpacing.xs,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Tappable(
        onTap: onBack,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.sm,
            vertical: FwSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_back,
                size: FwIconSize.sm,
                color: context.colors.mut,
              ),
              const SizedBox(width: FwSpacing.xs),
              Text(label, style: context.type.bodyMuted),
            ],
          ),
        ),
      ),
    ),
  );
}
