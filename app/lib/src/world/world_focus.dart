import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../inspect/inspect_dock.dart' show InspectDockTab, InspectTabStrip;
import '../plugins/native/run_core.dart' show RunCore;
import '../run/flag_memory.dart';
import '../run/logs_tab.dart';
import '../run/network_tab.dart';
import '../run/panels_tab.dart';
import '../run/run_sources.dart' show LiveRunChannels;
import '../ui/menu.dart';
import '../ui/popover.dart' show PopoverAlign;
import '../ui/stage.dart' show stageGroundColor;
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'guest_platform.dart';
import 'mail_view.dart';
import 'open_world.dart';
import 'platform/studio_platform.dart';
import 'world_messages.dart';
import 'world_person.dart';
import 'world_trace.dart';

/// One person in focus, the way a call shows whoever is speaking: their
/// device as large as the room allows, up to its own size, on the stage's
/// ground; the others with an app in a column of live thumbnails beside it,
/// where a click moves the focus; and their panel — who they are, what
/// reached them, and Run's own Network, App and Logs views of their app, the
/// same panes Run shows for any app — which folds away to give the device
/// the room.
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
    required this.others,
    required this.colorOf,
    required this.countsOf,
    required this.onFocus,
    required this.panel,
    required this.onPanel,
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

  /// Told the scale each device is drawn at, so its app renders for it.
  final void Function(WorldPerson person, double scale) onScale;

  /// Everyone else with an app, drawn small and live at the side.
  final List<WorldPerson> others;

  final Color Function(String person) colorOf;

  /// What each of [others] was sent, by kind, for their tag.
  final Map<String, int> Function(String person) countsOf;

  /// Puts someone else in focus: a click on their thumbnail.
  final ValueChanged<String> onFocus;

  /// Whether the panel is beside the device, rather than folded to a strip.
  final bool panel;
  final ValueChanged<bool> onPanel;

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
    var others = widget.others;
    return LayoutBuilder(
      builder: (context, constraints) {
        var app = hasApp(person);
        var beside =
            (others.isEmpty ? 0 : _Thumbnails.width) +
            (widget.panel ? _panelMinimum : _PanelGutter.width);
        var scale = app
            ? [
                1.0,
                (constraints.maxHeight - 2 * FwSpacing.xl) / size.height,
                (constraints.maxWidth - beside - 2 * _around) / size.width,
              ].reduce(min).clamp(0.1, 1.0)
            : 1.0;
        if (app) widget.onScale(person, scale);
        Widget stage = ColoredBox(
          color: stageGroundColor(context.colors),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _around),
            child: Center(
              child: app
                  ? ScaledBox(
                      size: size,
                      scale: scale,
                      child: PersonDevice(
                        world: widget.world,
                        person: person,
                        scale: scale,
                        ignores: (_) => false,
                        onRead: (id) {
                          setState(() => _tab = 'messages');
                          widget.onRead(id);
                        },
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
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (others.isNotEmpty)
              _Thumbnails(
                world: widget.world,
                people: others,
                colorOf: widget.colorOf,
                countsOf: widget.countsOf,
                onFocus: widget.onFocus,
                onScale: widget.onScale,
              ),
            if (widget.panel) ...[
              stage,
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.colors.bg,
                    border: Border(
                      left: BorderSide(color: context.colors.line),
                    ),
                  ),
                  child: _panel(context),
                ),
              ),
            ] else ...[
              Expanded(child: stage),
              _PanelGutter(
                person: person.name,
                onShow: () => widget.onPanel(true),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context) {
    var world = widget.world;
    var person = widget.person;
    var received = receivedBy(
      world.tracer?.trace.outbox(person: person.name, limit: 60) ??
          const <OutboxMessage>[],
      person.platform?.notifications.shown ?? const <GuestNotification>[],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PersonHeader(
          person: person,
          color: widget.color,
          sync: world.tracer?.syncOf(person.name),
          openLink: (link) => world.openLink(person.name, link, actor: 'human'),
          onHide: () => widget.onPanel(false),
        ),
        if (person.platform?.platform.unanswered case var unanswered?
            when person.running && unanswered.isNotEmpty)
          _Unanswered(person: person.name, plugins: unanswered),
        InspectTabStrip(
          tabs: [
            InspectDockTab(
              id: 'messages',
              label: 'Messages',
              badge: received.length,
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
        Expanded(child: _pane(context, received)),
      ],
    );
  }

  Widget _pane(BuildContext context, List<Received> received) {
    var world = widget.world;
    var person = widget.person;
    var trace = world.tracer?.trace;
    Widget note(String text) => Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: Text(text, style: context.type.bodyMuted),
    );
    if (_tab == 'messages') {
      if (widget.reading case var id?) {
        if (trace?.messageById(id) case var mail?) {
          return MailView(
            message: mail,
            snapshots: world.snapshots,
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
      if (received.isEmpty) {
        return note('No messages for ${person.name} yet.');
      }
      var app = person.spec.app?.entrypoint ?? person.name;
      var platform = person.running ? person.platform : null;
      return ListView(
        children: [
          for (var each in received)
            MessageRow(
              key: ValueKey(each.id),
              received: each,
              app: app,
              unread: !world.opened.contains(each.id),
              onDeliver: person.running && each.message != null
                  ? (how) => world.deliver(each.id, how: how, actor: 'human')
                  : null,
              onOpenNotification: switch ((platform, each.notification)) {
                (var platform?, var notification?) => () {
                  platform.notifications.tap(notification);
                  world.markOpened(each.id);
                },
                _ => null,
              },
              onRead: () {
                world.markOpened(each.id);
                widget.onRead(each.id);
              },
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
      _ => note('Add the Run plugin to see this.'),
    };
  }
}

/// A strip draws the tabs; the pane below is the panel's own.
Widget _noBody(BuildContext _) => const SizedBox.shrink();

/// The others in the world, small beside the one in focus: each with their
/// tag above a device that is still live, so what they see and the banners
/// that reach them stay in view. A click on one puts them in focus.
class _Thumbnails extends StatelessWidget {
  const _Thumbnails({
    required this.world,
    required this.people,
    required this.colorOf,
    required this.countsOf,
    required this.onFocus,
    required this.onScale,
  });

  final OpenWorld world;
  final List<WorldPerson> people;
  final Color Function(String person) colorOf;
  final Map<String, int> Function(String person) countsOf;
  final ValueChanged<String> onFocus;
  final void Function(WorldPerson person, double scale) onScale;

  /// The most room a device takes here: a window fills the width, a phone
  /// the height.
  static const _deviceWidth = 160.0;
  static const _deviceHeight = 200.0;

  static const width = _deviceWidth + 2 * FwSpacing.sm + 2 * FwSpacing.md + 1;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: stageGroundColor(colors),
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: FwSpacing.lg,
          ),
          child: ConstrainedBox(
            // Centred down the side while they fit; scrolled once they don't.
            constraints: BoxConstraints(
              minHeight: max(0, constraints.maxHeight - 2 * FwSpacing.lg),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var (i, person) in people.indexed) ...[
                  if (i > 0) const SizedBox(height: FwSpacing.md),
                  _thumbnail(context, person),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail(BuildContext context, WorldPerson person) {
    var size = personSize(person);
    var scale = min(_deviceWidth / size.width, _deviceHeight / size.height);
    onScale(person, scale);
    var name = person.name;
    return Tooltip(
      message: 'Show $name',
      child: Tappable(
        onTap: () => onFocus(name),
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: PersonTag(
                  name: name,
                  color: colorOf(name),
                  counts: countsOf(name),
                ),
              ),
              const SizedBox(height: FwSpacing.md),
              // Seen, not used: a click here is a click on the thumbnail.
              AbsorbPointer(
                child: ScaledBox(
                  size: size,
                  scale: scale,
                  child: PersonDevice(
                    world: world,
                    person: person,
                    scale: scale,
                    ignores: (_) => true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// All that is left of a folded panel: the way back to it.
class _PanelGutter extends StatelessWidget {
  const _PanelGutter({required this.person, required this.onShow});

  final String person;
  final VoidCallback onShow;

  static const width = _PanelButton.size + 2 * FwSpacing.sm + 1;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.only(top: FwSpacing.lg),
    alignment: Alignment.topCenter,
    decoration: BoxDecoration(
      color: context.colors.bg,
      border: Border(left: BorderSide(color: context.colors.line)),
    ),
    child: _PanelButton(
      icon: Icons.chevron_left,
      tooltip: "Show $person's panel",
      onTap: onShow,
    ),
  );
}

/// A square icon button in the panel's header, and in its folded strip.
class _PanelButton extends StatelessWidget {
  const _PanelButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  static const size = 28.0;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radius),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: context.colors.line),
        ),
        child: Icon(icon, size: FwIconSize.md, color: context.colors.ink2),
      ),
    ),
  );
}

/// Who the panel is about: their colour and name, how the world knows them
/// and what they use, their synced database's state for an app with one —
/// and, under `⋯`, what the studio can do to their app as its platform.
class _PersonHeader extends StatefulWidget {
  const _PersonHeader({
    required this.person,
    required this.color,
    required this.sync,
    required this.openLink,
    required this.onHide,
  });

  final WorldPerson person;
  final Color color;

  /// Opens a link in the person's app; see [OpenWorld.openLink].
  final Future<String> Function(String link) openLink;

  /// Folds the panel away.
  final VoidCallback onHide;

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
          if (person.platform case var platform? when person.running) ...[
            _PlatformMenu(
              person: person.name,
              platform: platform,
              openLink: widget.openLink,
            ),
            const SizedBox(width: FwSpacing.sm),
          ],
          _PanelButton(
            icon: Icons.chevron_right,
            tooltip: 'Hide the panel',
            onTap: widget.onHide,
          ),
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

/// The plugins a person's app asked that nothing answers in a world, and
/// what to do about it: each one a call that already failed in the app, and
/// answering it the project's own job, not the studio's.
class _Unanswered extends StatelessWidget {
  const _Unanswered({required this.person, required this.plugins});

  final String person;

  /// Channel to the method it asked first, as [GuestPlatform.unanswered].
  final Map<String, String?> plugins;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var named = [
      for (var MapEntry(key: channel, value: method) in plugins.entries)
        GuestPlatform.describe(channel, method),
    ];
    var one = named.length == 1;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        border: Border.symmetric(horizontal: BorderSide(color: colors.warning)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.warning_amber_outlined,
              size: FwIconSize.sm,
              color: colors.amber,
            ),
          ),
          const SizedBox(width: FwSpacing.sm),
          Expanded(
            child: SelectableText(
              'Not available in a world: ${named.join(', ')}. Calls to '
              "${one ? 'it' : 'them'} fail in $person's app. To use "
              "${one ? 'it' : 'them'}, add a fake in the app's entry point.",
              style: context.type.caption.copyWith(color: colors.warningText),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the studio, standing in for the platform, can do to one person's
/// app — open a link in it, where the OS would deliver one; show the pages
/// it opened; send it to the background — behind a `⋯`.
class _PlatformMenu extends StatefulWidget {
  const _PlatformMenu({
    required this.person,
    required this.platform,
    required this.openLink,
  });

  final String person;
  final StudioPlatform platform;
  final Future<String> Function(String link) openLink;

  @override
  State<_PlatformMenu> createState() => _PlatformMenuState();
}

class _PlatformMenuState extends State<_PlatformMenu> {
  @override
  Widget build(BuildContext context) {
    var platform = widget.platform;
    var person = widget.person;
    var opened = platform.urls.opened;
    var background = platform.system.inBackground;
    return Menu(
      align: PopoverAlign.end,
      minWidth: 240,
      entries: [
        MenuItem('Open a link…', icon: Icons.link, onSelected: _openLink),
        if (opened.isNotEmpty)
          MenuItem(
            'Opened pages',
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
      builder: (context, controller) => _PanelButton(
        icon: Icons.more_horiz,
        tooltip: "More for $person's app",
        onTap: controller.toggle,
      ),
    );
  }

  Future<void> _openLink() => showDialog<void>(
    context: context,
    builder: (context) =>
        _OpenLink(person: widget.person, open: widget.openLink),
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

/// Asks for a link and hands it to [person]'s app where the OS would.
///
/// Its own widget so the field's controller lives exactly as long as the
/// dialog: `showDialog` returns when the route is popped, and the dialog
/// goes on drawing the field through its closing animation — a controller
/// disposed on return was read after its disposal, and took the studio's
/// whole overlay down with it.
class _OpenLink extends StatefulWidget {
  const _OpenLink({required this.person, required this.open});

  final String person;
  final Future<String> Function(String link) open;

  @override
  State<_OpenLink> createState() => _OpenLinkState();
}

class _OpenLinkState extends State<_OpenLink> {
  final _link = TextEditingController();
  String? _said;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await widget.open(_link.text.trim());
    } on WorldRefusal catch (refusal) {
      if (mounted) setState(() => _said = refusal.message);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text("Open a link in ${widget.person}'s app"),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The app receives it as if the phone opened the link.',
            style: context.type.bodyMuted,
          ),
          const SizedBox(height: FwSpacing.md),
          TextField(
            controller: _link,
            autofocus: true,
            onSubmitted: (_) => _open(),
          ),
          if (_said case var said?) ...[
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
      TextButton(onPressed: _open, child: const Text('Open')),
    ],
  );
}
