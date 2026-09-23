import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/server.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../address/address_scope.dart';
import '../../inspect/inspect_dock.dart';
import '../../ui/code_block.dart';
import '../../ui/filter_bar.dart';
import '../../ui/http_row.dart';
import '../../ui/json_view.dart';
import '../../ui/panel_header.dart';
import '../../ui/popover.dart';
import '../../ui/popover_menu.dart';
import '../../ui/split_pane.dart';
import '../../ui/syntax.dart';
import '../../ui/tappable.dart';
import '../native_plugin.dart';
import 'server_address.dart';
import 'server_core.dart';
import '../../ui/design/design.dart';
import '../../ui/loading_state.dart';
import '../../ui/empty_state.dart';

export 'server_core.dart' show ServerCore, serverPluginId;

/// The GUI half of server inspection: server chips, the request list with its
/// N+1 badges, a waterfall per request, and the raw timeline behind it all.
///
/// Everything the plugin *knows* — which servers announce themselves, their
/// events, what repeats inside a request — is in [ServerCore] and
/// [repeatedQueries], so `fw` and an agent reach the same answers. This class
/// exists because `buildPanel` returns a `Widget`.
class ServerPlugin extends NativePlugin<ServerCore> {
  ServerPlugin(super.core);

  @override
  Widget buildPanel(BuildContext context) => _ServerPanel(this);
}

/// Owns the subscription: mounting is what starts tracking. Position comes
/// from the address — `<name>/req/<eventId>` — so a request row is a place
/// search can land on and a capture can name.
class _ServerPanel extends StatefulWidget {
  const _ServerPanel(this.plugin);

  final ServerPlugin plugin;

  @override
  State<_ServerPanel> createState() => _ServerPanelState();
}

class _ServerPanelState extends State<_ServerPanel> {
  ServerCore get _core => widget.plugin.core;

  /// The request list's filter, held here rather than in the list.
  ///
  /// Selecting a request swaps the child of the `switch` below from a bare
  /// [_RequestList] to a [FwSplitPane] wrapping one — a different runtime type
  /// in the same slot, so the element is thrown away and any state inside it
  /// with it. Held in the list, the filter and the typed path reset on every
  /// selection *and* again on every deselection, which is the one moment a
  /// person is most sure they did not change them.
  var _requestFilter = _RequestFilter.all;

  /// The path box's text. A controller, not a `String`, because the field's
  /// own state dies with the same element — see [FwSearchBox.controller].
  final _requestPath = TextEditingController();

  @override
  void initState() {
    super.initState();
    _core.track();
  }

  @override
  void dispose() {
    _requestPath.dispose();
    super.dispose();
  }

  /// Mounting starts tracking, and a config reload is not a mount: the session
  /// is rebuilt under a panel that keeps its position, so this `State` is
  /// reused and the new core is never tracked. The panel then reports on a
  /// core nothing has ever looked at.
  @override
  void didUpdateWidget(_ServerPanel old) {
    super.didUpdateWidget(old);
    if (old.plugin != widget.plugin) _core.track();
  }

  /// One [_RequestList], wherever the switch puts it, reading the filter this
  /// `State` owns.
  Widget _requestList({
    required TrackedServer server,
    required List<ServerEvent> requests,
    required Map<String, List<ServerEvent>> byRid,
    required int? selectedId,
    bool oneLine = false,
  }) => _RequestList(
    server: server,
    requests: requests.reversed.toList(),
    byRid: byRid,
    selectedId: selectedId,
    oneLine: oneLine,
    filter: _requestFilter,
    onFilter: (it) => setState(() => _requestFilter = it),
    path: _requestPath,
    onPath: () => setState(() {}),
  );

  ServerPlace? _resolve(BuildContext context) => serverPlace(
    [for (var i = 0; i < 3; i++) AddressScope.segment(context, i) ?? '']
      ..removeWhere((s) => s.isEmpty),
  );

  /// The tracked session the place names. By name, preferring the one still
  /// running — after a restart the stopped session and its successor share a
  /// name, and a pasted address should mean the live one.
  TrackedServer? _select(List<TrackedServer> servers, ServerPlace? place) {
    var candidates = place == null
        ? servers
        : [
            for (var server in servers)
              if (server.handle.name == place.server) server,
          ];
    if (candidates.isEmpty) candidates = servers;
    return candidates.where((s) => !s.stopped).firstOrNull ??
        candidates.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) {
        var servers = _core.servers;
        if (servers.isEmpty) return const _EmptyHint();
        var place = _resolve(context);
        var server = _select(servers, place);
        if (server == null) return const _EmptyHint();

        var events = server.events;
        // One pass: every correlated event, keyed by the request it belongs
        // to — the request list needs it for badges, the detail for spans.
        var byRid = <String, List<ServerEvent>>{};
        for (var event in events) {
          if (event.rid != null && event.channel != 'http') {
            byRid.putIfAbsent(event.rid!, () => []).add(event);
          }
        }
        var requests = [
          for (var event in events)
            if (event.channel == 'http') event,
        ];
        var selected = place?.requestId == null
            ? null
            : requests
                  .where((r) => r.id == place!.requestId)
                  .cast<ServerEvent?>()
                  .firstOrNull;

        var view = place?.view ?? ServerViewKind.overview;
        var info = server.info;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FwPanelHeader(
              server.handle.name,
              badge: _Identity(server: server, info: info),
              subtitle: [
                'pid ${server.handle.pid}',
                if (server.stopped)
                  'no longer announcing'
                else if (!server.connected)
                  'attaching',
              ],
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (info.baseUrl case var it?) _UrlLink(it),
                  const Gap(FwSpacing.md),
                  _InfoButton(info),
                ],
              ),
              // The rail already lists every server, so one healthy server
              // needs no switcher. Two do: the rail row beside this one cannot
              // say which of them the panel is showing.
              below: servers.length > 1
                  ? _ServerBar(servers, shown: server)
                  : null,
              toolbar: _ViewTabs(
                server: server,
                view: view,
                requests: requests.length,
              ),
            ),
            Divider(height: 1, color: context.colors.line),
            Expanded(
              child: switch (view) {
                // No selection: the list has the whole width. With one, the
                // list narrows and the detail opens beside it — the same
                // shape as Requests below, because a panel that opens a
                // detail two different ways is a panel you have to learn
                // twice. The SQL half used to replace the pane outright and
                // hand back a ✕.
                ServerViewKind.sql =>
                  place?.queryKey == null
                      ? _SqlView(server: server, selectedKey: null)
                      : FwSplitPane(
                          key: const ValueKey('sql'),
                          list: _SqlView(
                            server: server,
                            selectedKey: place!.queryKey,
                            narrow: true,
                          ),
                          // Keyed by the shape, so clicking another one in
                          // the list beside it builds a *new* detail. Without
                          // it the same `State` is reused and its explain
                          // result — which belongs to the shape you just left
                          // — stays on screen under the new statement.
                          detail: _QueryDetail(
                            key: ValueKey(place.queryKey),
                            server: server,
                            queryKey: place.queryKey!,
                          ),
                        ),
                ServerViewKind.events => _EventTimeline(server, events),
                // The raw stream lives under Events, not behind an unselected
                // detail.
                _ when selected == null => _requestList(
                  server: server,
                  requests: requests,
                  byRid: byRid,
                  selectedId: null,
                  oneLine: true,
                ),
                _ => FwSplitPane(
                  key: const ValueKey('requests'),
                  list: _requestList(
                    server: server,
                    requests: requests,
                    byRid: byRid,
                    selectedId: selected.id,
                  ),
                  detail: _RequestDetail(
                    server: server,
                    request: selected,
                    caused: byRid[selected.rid] ?? const [],
                  ),
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

/// What the panel is showing, beside its name: the session's state and, when
/// the server declared one, the environment it is pointed at.
class _Identity extends StatelessWidget {
  const _Identity({required this.server, required this.info});

  final TrackedServer server;
  final ServerInfo info;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _StatePill(server),
      if (info.environment case var it?) ...[
        const Gap(FwSpacing.sm),
        _EnvironmentChip(it),
      ],
    ],
  );
}

/// Running, attaching, or gone — the one thing a row of numbers cannot say.
class _StatePill extends StatelessWidget {
  const _StatePill(this.server);

  final TrackedServer server;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var (label, color) = server.stopped
        ? ('stopped', colors.mut3)
        : server.connected
        ? ('running', colors.grn)
        : ('reconnecting', colors.amber);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        label,
        style: context.type.micro.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ServerBar extends StatelessWidget {
  const _ServerBar(this.servers, {required this.shown});

  final List<TrackedServer> servers;
  final TrackedServer shown;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Wrap(
      spacing: FwSpacing.md,
      runSpacing: FwSpacing.xs,
      children: [
        for (var server in servers)
          Tappable(
            onTap: () =>
                AddressScope.write(context)
                    .setSegments(serverSegments(server.handle.name)),
            borderRadius: BorderRadius.circular(context.radii.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.lg,
                vertical: FwSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: identical(server, shown) ? colors.accentSoft : null,
                borderRadius: BorderRadius.circular(context.radii.pill),
                border: Border.all(
                  color: identical(server, shown)
                      ? colors.accentSoft2
                      : colors.line,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.circle,
                    size: FwIconSize.xs - 4,
                    color: server.stopped
                        ? colors.mut3
                        : server.connected
                        ? colors.grn
                        : colors.amber,
                  ),
                  const Gap(FwSpacing.sm),
                  Text(
                    server.stopped
                        ? '${server.handle.name} (stopped)'
                        : server.connected
                        ? '${server.handle.name} · pid ${server.handle.pid}'
                        : '${server.handle.name} · reconnecting',
                    style: context.type.bodySmall,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Requests | SQL | Info | Events — which pane of the shown server, written
/// into the address.
///
/// [InspectTabStrip] rather than a row of `TextButton`s, for the reason the run
/// cockpit swapped first: this was the app's second hand-rolled strip, and two
/// panels showing tabs in two designs is a difference the reader has to spend
/// attention ruling out. Which server, and where it points, moved up into the
/// header — it is context for every pane, not a member of the strip.
class _ViewTabs extends StatelessWidget {
  const _ViewTabs({
    required this.server,
    required this.view,
    required this.requests,
  });

  final TrackedServer server;
  final ServerViewKind view;

  /// Badged on the Requests tab. Free — the panel counted them to draw the
  /// list. The SQL count deliberately is not: it costs a normalisation pass
  /// over every event, which is not a thing to pay for on every frame.
  final int requests;

  @override
  Widget build(BuildContext context) {
    var name = server.handle.name;
    var current = switch (view) {
      ServerViewKind.overview || ServerViewKind.request => 'requests',
      ServerViewKind.sql => 'sql',
      ServerViewKind.events => 'events',
    };
    return InspectTabStrip(
      tabs: [
        InspectDockTab(
          id: 'requests',
          label: 'Requests',
          badge: requests,
          body: _unused,
        ),
        const InspectDockTab(id: 'sql', label: 'SQL', body: _unused),
        const InspectDockTab(id: 'events', label: 'Events', body: _unused),
      ],
      current: current,
      onSelect: (id) => AddressScope.write(context).setSegments(switch (id) {
        'sql' => sqlSegments(name),
        'events' => eventsSegments(name),
        _ => serverSegments(name),
      }),
    );
  }

  /// The strip reads ids, labels and badges and never builds a body — the
  /// panel keeps its panes, which are switched on the address.
  static Widget _unused(BuildContext context) => const SizedBox.shrink();
}

/// [InspectTabStrip] over a plain id → label map, for the request detail's own
/// strip. The panel has two strips and they must not drift apart again.
class _InspectStrip extends StatelessWidget {
  const _InspectStrip({
    required this.tabs,
    required this.current,
    required this.onSelect,
    this.badges = const {},
  });

  final Map<String, String> tabs;
  final String current;
  final Map<String, int> badges;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => InspectTabStrip(
    tabs: [
      for (var tab in tabs.entries)
        InspectDockTab(
          id: tab.key,
          label: tab.value,
          badge: badges[tab.key] ?? 0,
          body: _ViewTabs._unused,
        ),
    ],
    current: current,
    onSelect: onSelect,
  );
}

/// What the server says about itself, on the header rather than in a tab.
///
/// It was a quarter of the tab strip and it is not a working surface: three
/// links, a DSN and a handful of config values that do not change while you
/// work. Worse, it is context for *every* pane — checking which database you
/// are pointed at meant leaving Requests and coming back. On the header it is
/// one click from wherever you are, and the strip is down to the three panes
/// that are actually panes.
class _InfoButton extends StatelessWidget {
  const _InfoButton(this.info);

  final ServerInfo info;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Popover(
      align: PopoverAlign.end,
      anchor: (context, controller) => Tooltip(
        message: 'What this server says about itself',
        child: Tappable.builder(
          onTap: controller.toggle,
          borderRadius: BorderRadius.circular(context.radii.pill),
          builder: (context, hovered) => Container(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.md,
              vertical: FwSpacing.xs,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(context.radii.pill),
              border: Border.all(
                color: controller.isOpen
                    ? colors.accent
                    : hovered
                    ? colors.mut3
                    : colors.line,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: FwIconSize.sm,
                  color: controller.isOpen ? colors.accent : colors.mut,
                ),
                const Gap(FwSpacing.sm),
                Text('Details', style: context.type.bodySmall),
              ],
            ),
          ),
        ),
      ),
      content: (context, controller) => PopoverMenuSurface(
        width: 520,
        maxHeight: 480,
        // Something in the card has to be able to hold focus or Escape never
        // reaches the overlay that listens for it: the content is a list of
        // text and icon buttons, none of which takes focus on its own, so
        // opening moved focus nowhere and the key went to the root scope.
        child: Focus(autofocus: true, child: _InfoView(info: info)),
      ),
    );
  }
}

/// The declared environment, colored by how much it should worry you: quiet
/// for dev-shaped names, loud for production-shaped ones — an inspector
/// forced on with `FW_SERVER_INSPECT=1` should say where it is pointed.
class _EnvironmentChip extends StatelessWidget {
  const _EnvironmentChip(this.environment);

  final String environment;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var lower = environment.toLowerCase();
    var color = const {'prod', 'production', 'live'}.contains(lower)
        ? colors.red
        : const {'dev', 'development', 'local', 'debug', 'test'}.contains(lower)
        ? colors.mut
        : colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        environment,
        style: context.type.micro.copyWith(color: color),
      ),
    );
  }
}

/// A heading inside a pane — *Headers*, *Occurrences*, *Links*.
///
/// Uppercase `fieldLabel`, which is what the dev stack's panel next door
/// already uses for the same job. These were Material's `titleSmall`: a
/// sentence-case 14 px semibold that reads as a title rather than as a label,
/// and is the only such face in the app.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label.toUpperCase(),
    style: context.type.fieldLabel.copyWith(color: context.colors.mut),
  );
}

/// An absolute URL as a clickable piece of text.
class _UrlLink extends StatelessWidget {
  const _UrlLink(this.url, {this.label});

  final String url;

  /// Shown instead of the URL itself when given.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Tappable.builder(
      onTap: () => launchUrl(Uri.parse(url)),
      builder: (context, hovered) => Text(
        label ?? url,
        style: context.type.mono.copyWith(
          color: context.colors.accent,
          decoration: hovered ? TextDecoration.underline : null,
        ),
      ),
    );
  }
}

/// The aggregate: every query shape this server ran, heaviest first.
class _SqlView extends StatelessWidget {
  const _SqlView({
    required this.server,
    required this.selectedKey,
    this.narrow = false,
  });

  final TrackedServer server;

  /// The shape the detail beside this list is showing, or null when the list
  /// has the whole width.
  final String? selectedKey;

  /// True in the split's left column. Only `total` survives the narrowing:
  /// avg and max are numbers you read once you have chosen a shape, and the
  /// detail states all four anyway.
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var stats = sqlStats(server.events);
    if (stats.isEmpty) {
      return const EmptyState(
        icon: Icons.storage_outlined,
        title: 'No queries recorded',
      );
    }
    var header = context.type.micro.copyWith(color: colors.mut2);
    var numbers = context.type.mono;
    var gutter = narrow ? FwSpacing.lg : panelGutter;

    Widget number(String text) => SizedBox(
      width: 70,
      child: Text(text, style: numbers, textAlign: TextAlign.right),
    );
    Widget headerCell(String text) => SizedBox(
      width: 70,
      child: Text(text, style: header, textAlign: TextAlign.right),
    );

    // **Not selectable, deliberately.** Every row here is a tap target, and a
    // row that is both shows a text caret over a control that responds to a
    // click — two affordances on one target, and the caret wins because
    // Flutter's own text region sits below [Tappable]'s (see its doc comment).
    // Copying a statement happens in the detail beside this, where the block
    // has a button for it.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: gutter,
            vertical: FwSpacing.xs,
          ),
          child: Row(
            children: [
              SizedBox(width: 44, child: Text('count', style: header)),
              Expanded(child: Text('query shape', style: header)),
              headerCell('total'),
              if (!narrow) ...[headerCell('avg'), headerCell('max')],
            ],
          ),
        ),
        Divider(height: 1, color: colors.line),
        for (var shape in stats)
          Tappable(
            onTap: () => AddressScope.write(
              context,
            ).setSegments(sqlSegments(server.handle.name, queryKey: shape.key)),
            child: Container(
              color: shape.key == selectedKey ? colors.accentSoft : null,
              padding: EdgeInsets.symmetric(
                horizontal: gutter,
                vertical: FwSpacing.sm,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text('${shape.count}×', style: numbers),
                  ),
                  Expanded(child: _Sql(shape.normalized)),
                  number(_ms(shape.totalMs)),
                  if (!narrow) ...[
                    number(_ms(shape.averageMs)),
                    number(_ms(shape.maxMs)),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A statement, coloured.
///
/// One line, ellipsised, for a list row; [maxLines] opens it up for a detail.
/// The tokeniser is `syntax.dart`'s and it already speaks SQL — every place a
/// query appeared in this panel was drawing it as prose in `mono`, which is
/// what makes a column of `select … from … where …` unscannable.
class _Sql extends StatelessWidget {
  const _Sql(this.query, {this.maxLines = 1, this.color});

  final String query;
  final int maxLines;

  /// Overrides the colour of text no rule claimed — for a row that is already
  /// tinted, where the palette's plain ink would fight it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    var style = context.type.mono;
    return Text.rich(
      TextSpan(
        children: codeSpans(
          context,
          // A list row is one line whatever the source did. Collapsing here
          // rather than leaning on maxLines keeps the ellipsis at the end of
          // the *statement* instead of at the end of its first line.
          maxLines == 1 ? query.replaceAll(RegExp(r'\s+'), ' ').trim() : query,
          language: 'sql',
        ),
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: color == null ? style : style.copyWith(color: color),
    );
  }
}

/// One query shape: its stats, its occurrences with their parameters, and
/// the two commands that run inside the live server — explain and requery.
class _QueryDetail extends StatefulWidget {
  const _QueryDetail({super.key, required this.server, required this.queryKey});

  final TrackedServer server;
  final String queryKey;

  @override
  State<_QueryDetail> createState() => _QueryDetailState();
}

class _QueryDetailState extends State<_QueryDetail> {
  String? _resultTitle;

  /// The decoded response map on success, the error text on failure.
  Object? _result;
  var _busy = false;

  Future<void> _run(String method, ServerEvent occurrence) async {
    setState(() {
      _busy = true;
      _resultTitle = method;
      _result = null;
    });
    Object? result;
    try {
      result = await sqlCommand(widget.server, method, occurrence);
    } on Object catch (e) {
      // A missing handler or a failing one — an answer, not a crash. The
      // hint names the fix because "no handler for sql.explain" alone reads
      // as our bug rather than a snippet not yet pasted.
      result =
          '$e\n\nThe server registers command handlers itself — see the '
          'sql adapter snippets in doc/server_inspection.md.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var stats = sqlStats(widget.server.events)
        .where((s) => s.key == widget.queryKey)
        .firstOrNull;
    if (stats == null) {
      return const EmptyState(
        icon: Icons.history_toggle_off,
        title: 'Outside the recorded window',
        message: 'This query shape is no longer being kept.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                '${stats.count}× · total ${_ms(stats.totalMs)} · '
                'avg ${_ms(stats.averageMs)} · max ${_ms(stats.maxMs)}',
                style: context.type.caption,
              ),
            ),
            _SmallIconButton(
              Icons.close,
              tooltip: 'Back to all queries',
              onTap: () =>
                  AddressScope.write(context)
                      .setSegments(sqlSegments(widget.server.handle.name)),
            ),
          ],
        ),
        const Gap(FwSpacing.sm),
        // The shape as a block rather than as a heading: it is the one thing
        // on this pane somebody wants in an editor a moment later, and a long
        // statement scrolls here instead of being ellipsised out of reach.
        FwCodeBlock(stats.normalized, language: 'sql'),
        const Gap(FwSpacing.lg),
        Row(
          children: [
            for (var method in ['explain', 'requery'])
              Padding(
                padding: const EdgeInsets.only(right: FwSpacing.md),
                child: OutlinedButton(
                  onPressed: _busy || !widget.server.connected
                      ? null
                      // The latest occurrence, which is a statement the
                      // database has really seen — the `?`-shape above it is a
                      // grouping key and would not run.
                      : () => _run(method, stats.latest),
                  child: Text(method),
                ),
              ),
            if (!widget.server.connected)
              Text(
                'not attached',
                style: context.type.caption.copyWith(color: colors.mut2),
              ),
          ],
        ),
        if (_resultTitle != null) ...[
          const Gap(FwSpacing.lg),
          _SectionLabel(_resultTitle!),
          const Gap(FwSpacing.xs),
          _busy
              ? const Padding(
                  padding: EdgeInsets.all(FwSpacing.md),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _CommandResult(_result),
        ],
        const Gap(FwSpacing.xl),
        const _SectionLabel('Occurrences'),
        const Gap(FwSpacing.xs),
        // Newest first, and every one of them — the ring already bounds it.
        SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var occurrence in stats.occurrences.reversed)
                _OccurrenceRow(server: widget.server, occurrence: occurrence),
            ],
          ),
        ),
      ],
    );
  }
}

/// One raw execution: when, how long, the exact SQL and its parameters, and
/// the way back to the request that caused it.
class _OccurrenceRow extends StatelessWidget {
  const _OccurrenceRow({required this.server, required this.occurrence});

  final TrackedServer server;
  final ServerEvent occurrence;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    var params = occurrence.payload['params'];
    var request = occurrence.rid == null
        ? null
        : server.events
              .where((e) => e.channel == 'http' && e.rid == occurrence.rid)
              .firstOrNull;
    var time = occurrence.time;
    var query = '${occurrence.payload['query']}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}',
            style: mono.copyWith(color: colors.mut2),
          ),
          const Gap(FwSpacing.md),
          SizedBox(
            width: 60,
            child: Text(_ms(occurrence.payload['ms']), style: mono),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Not ellipsised: this is the statement the database really
                // ran, and a row of the shape above it already says what it
                // looks like. If it wraps, that is the length it is.
                _Sql(query, maxLines: 3),
                if (params != null)
                  Text(
                    'params: ${jsonEncode(params)}',
                    style: mono.copyWith(color: colors.mut2),
                  ),
              ],
            ),
          ),
          CopyIconButton(query, tooltip: 'Copy this statement'),
          if (request != null)
            _SmallIconButton(
              Icons.north_east,
              tooltip:
                  '${request.payload['method']} ${request.payload['path']}',
              onTap: () => AddressScope.write(context).setSegments(
                serverSegments(server.handle.name, requestId: request.id),
              ),
            ),
        ],
      ),
    );
  }
}

/// What a request list is showing.
///
/// Three, not a dozen: this is a filter for the two questions anybody asks a
/// request list — *what broke* and *what is slow because it queries in a
/// loop*. Everything finer is what the path box is for.
enum _RequestFilter {
  all('All'),
  failed('Errors'),
  repeated('N+1');

  const _RequestFilter(this.label);

  final String label;

  bool matches(ServerEvent request, int repeatedCount) => switch (this) {
    _RequestFilter.all => true,
    _RequestFilter.failed => _failed(request),
    _RequestFilter.repeated => repeatedCount > 0,
  };
}

/// The request list. **Stateless on purpose** — see [_ServerPanelState] for
/// where the filter lives and why it cannot live here.
class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.server,
    required this.requests,
    required this.byRid,
    required this.selectedId,
    required this.filter,
    required this.onFilter,
    required this.path,
    required this.onPath,
    this.oneLine = false,
  });

  final TrackedServer server;

  /// Newest first.
  final List<ServerEvent> requests;
  final Map<String, List<ServerEvent>> byRid;
  final int? selectedId;

  final _RequestFilter filter;
  final ValueChanged<_RequestFilter> onFilter;

  /// The path box's text, owned above so it survives a selection.
  final TextEditingController path;

  /// Called when [path] changes, so the owner can rebuild.
  final VoidCallback onPath;

  /// True in the full-width form, where the row can be one line.
  final bool oneLine;

  @override
  Widget build(BuildContext context) {
    // The repeat count is what the N+1 badge and the N+1 filter both read, so
    // it is computed once per row here rather than twice.
    var rows = [
      for (var request in requests)
        (
          request,
          () {
            var caused = request.rid == null
                ? const <ServerEvent>[]
                : byRid[request.rid] ?? const [];
            var repeated = repeatedQueries(caused);
            return repeated.isEmpty
                ? 0
                : repeated.values.reduce((a, b) => a > b ? a : b);
          }(),
        ),
    ];
    var needle = path.text.trim().toLowerCase();
    var shown = [
      for (var (request, repeated) in rows)
        if (filter.matches(request, repeated) &&
            (needle.isEmpty ||
                '${request.payload['method']} ${request.payload['path']}'
                    .toLowerCase()
                    .contains(needle)))
          (request, repeated),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwFilterBar(
          pills: [
            for (var it in _RequestFilter.values)
              (it.label, it == filter, () => onFilter(it)),
          ],
          hint: 'Filter paths…',
          searchController: path,
          onSearch: (_) => onPath(),
          count: '${shown.length} of ${rows.length}',
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyState(
                  icon: Icons.swap_vert,
                  title: rows.isEmpty
                      ? 'No requests yet'
                      : 'Nothing matches this filter',
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    var (request, repeated) = shown[index];
                    return _RequestRow(
                      server: server,
                      request: request,
                      selected: request.id == selectedId,
                      oneLine: oneLine,
                      repeatedCount: repeated,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.server,
    required this.request,
    required this.selected,
    required this.repeatedCount,
    this.oneLine = false,
  });

  final TrackedServer server;
  final ServerEvent request;
  final bool selected;

  /// One line at full width, two in the split's column.
  ///
  /// Narrowing used to *drop* the timestamp, which is the one column that
  /// lines a request up against a log — so selecting a request cost you the
  /// thing you selected it to correlate. A second line gives the path its
  /// width back and keeps the time, the status and the badge.
  final bool oneLine;

  /// The largest repeat count among this request's queries; 0 for none.
  final int repeatedCount;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    var p = request.payload;
    var status = p['status'];
    var time = Text(
      oneLine ? _timestamp(request.time) : _clock(request.time),
      style: mono.copyWith(color: colors.mut2),
    );
    var path = Text(
      '${p['path']}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: mono,
    );
    var duration = Text(_ms(p['ms']), style: mono.copyWith(color: colors.mut2));

    return Tappable(
      onTap: () => AddressScope.write(
        context,
      ).setSegments(serverSegments(server.handle.name, requestId: request.id)),
      child: Container(
        color: selected ? colors.accentSoft : null,
        padding: EdgeInsets.symmetric(
          // The full-width list sits on the panel gutter like everything else;
          // the column beside a detail cannot afford it.
          horizontal: oneLine ? panelGutter : FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        child: oneLine
            ? Row(
                children: [
                  time,
                  const Gap(FwSpacing.lg),
                  HttpMethodToken('${p['method']}'),
                  const Gap(FwSpacing.md),
                  Expanded(child: path),
                  if (repeatedCount > 0) ...[
                    const Gap(FwSpacing.sm),
                    _NPlusOneBadge(repeatedCount),
                  ],
                  const Gap(FwSpacing.md),
                  HttpStatusCode(status),
                  const Gap(FwSpacing.md),
                  duration,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      HttpMethodToken('${p['method']}'),
                      const Gap(FwSpacing.md),
                      Expanded(child: path),
                      const Gap(FwSpacing.md),
                      duration,
                    ],
                  ),
                  const Gap(2),
                  Row(
                    children: [
                      time,
                      const Gap(FwSpacing.md),
                      HttpStatusCode(status),
                      if (repeatedCount > 0) ...[
                        const Gap(FwSpacing.sm),
                        _NPlusOneBadge(repeatedCount),
                      ],
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// The one finding this list makes on its own: a query the request ran over
/// and over.
class _NPlusOneBadge extends StatelessWidget {
  const _NPlusOneBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tooltip(
      message: 'A query repeats $count× in this request — the N+1 shape.',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.sm,
          vertical: 1,
        ),
        decoration: BoxDecoration(
          color: colors.amber.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(context.radii.micro),
        ),
        child: Text(
          'N+1',
          style: context.type.micro.copyWith(color: colors.warningText),
        ),
      ),
    );
  }
}

/// The selected request, in tabs: the waterfall (with its N+1 warnings),
/// its queries, the request and response messages, and its logs.
///
/// The tab is an axis (`?tab=`), not a segment — the same request seen
/// differently, which is the framework's own distinction.
class _RequestDetail extends StatelessWidget {
  const _RequestDetail({
    required this.server,
    required this.request,
    required this.caused,
  });

  final TrackedServer server;
  final ServerEvent request;
  final List<ServerEvent> caused;

  /// Ids and their labels. The ids are the address's — a link somebody pasted
  /// says `?tab=waterfall` — while the labels are the strip's, and the strip
  /// spells a label the way every other tab in the app is spelled.
  static const _tabs = {
    'waterfall': 'Waterfall',
    'sql': 'SQL',
    'request': 'Request',
    'response': 'Response',
    'logs': 'Logs',
  };

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var p = request.payload;
    var tab = AddressScope.param(context, 'tab') ?? 'waterfall';
    if (!_tabs.containsKey(tab)) tab = 'waterfall';
    var queries = [
      for (var event in caused)
        if (event.channel == 'sql') event,
    ];
    var logs = [
      for (var event in caused)
        if (event.channel == 'log') event,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xl,
            FwSpacing.lg,
            FwSpacing.md,
            FwSpacing.md,
          ),
          child: Row(
            children: [
              HttpMethodToken('${p['method']}'),
              const Gap(FwSpacing.sm),
              // Scrolled rather than `maxLines: 1`: `SelectableText` takes
              // no `overflow`, so one line clips mid-character and says
              // nothing about the tail it dropped.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    '${p['path']}',
                    maxLines: 1,
                    style: context.type.mono.copyWith(fontSize: 14),
                  ),
                ),
              ),
              const Gap(FwSpacing.md),
              HttpStatusCode(p['status']),
              const Gap(FwSpacing.md),
              Text(
                _ms(p['ms']),
                style: context.type.mono.copyWith(fontSize: 14),
              ),
              const Gap(FwSpacing.md),
              // The whole URL, which the curl button buries inside a command.
              // Pasting a path into a browser is the other thing people do
              // with a request row.
              if (requestUrl(server.info, request) case var url?)
                CopyIconButton(url, tooltip: 'Copy the URL'),
              _CopyAsCurlButton(server: server, request: request),
              IconButton(
                icon: const Icon(Icons.close, size: FwIconSize.lg),
                tooltip: 'Back to the request list',
                onPressed: () =>
                    AddressScope.write(context)
                        .setSegments(serverSegments(server.handle.name)),
              ),
            ],
          ),
        ),
        if (p['error'] != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xl,
              0,
              FwSpacing.xl,
              FwSpacing.md,
            ),
            child: Text(
              '${p['error']}',
              style: context.type.bodySmall.copyWith(color: colors.red),
            ),
          ),
        _InspectStrip(
          tabs: _tabs,
          current: tab,
          badges: {'sql': queries.length, 'logs': logs.length},
          onSelect: (name) => AddressScope.write(context).setParam('tab', name),
        ),
        Divider(height: 1, color: colors.line),
        Expanded(
          child: switch (tab) {
            'sql' => _RequestSqlTab(server: server, queries: queries),
            'request' => _HttpMessageTab(
              server: server,
              request: request,
              response: false,
            ),
            'response' => _HttpMessageTab(
              server: server,
              request: request,
              response: true,
            ),
            'logs' => _RequestLogsTab(logs),
            _ => _WaterfallTab(
              server: server,
              request: request,
              caused: caused,
            ),
          },
        ),
      ],
    );
  }
}

/// One click from "I see the request" to "I can reproduce it in a terminal":
/// copies a curl built from the event summary plus the lazily-held headers
/// and body ([curlCommand]). Needs the server to have published its base URL
/// — a relative path is not a runnable command — and says so when it has not.
class _CopyAsCurlButton extends StatelessWidget {
  const _CopyAsCurlButton({required this.server, required this.request});

  final TrackedServer server;
  final ServerEvent request;

  @override
  Widget build(BuildContext context) {
    var enabled =
        server.info.baseUrl != null && request.payload['path'] is String;
    // Wrapped manually because a disabled IconButton swallows its tooltip,
    // and the disabled state is exactly when the tooltip has to explain.
    return Tooltip(
      message: enabled
          ? 'Copy as curl'
          : 'Copy as curl — needs a published baseUrl '
                '(FlutterwareServer.info)',
      child: IconButton(
        icon: const Icon(Icons.terminal, size: FwIconSize.lg),
        onPressed: !enabled
            ? null
            : () async {
                var details = await server.detailsFor(request);
                var command = curlCommand(
                  server.info,
                  request,
                  details: details,
                );
                if (command == null) return;
                await Clipboard.setData(ClipboardData(text: command));
              },
      ),
    );
  }
}

class _WaterfallTab extends StatelessWidget {
  const _WaterfallTab({
    required this.server,
    required this.request,
    required this.caused,
  });

  final TrackedServer server;
  final ServerEvent request;
  final List<ServerEvent> caused;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var repeated = repeatedQueries(caused);
    var spans = [
      for (var event in caused)
        if (event.payload['ms'] is num) event,
    ];
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        for (var entry in repeated.entries)
          Container(
            margin: const EdgeInsets.only(bottom: FwSpacing.lg),
            padding: const EdgeInsets.all(FwSpacing.lg),
            decoration: BoxDecoration(
              color: colors.amber.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              border: Border.all(color: colors.amber.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: FwIconSize.sm,
                    color: colors.warningText,
                  ),
                ),
                const Gap(FwSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'N+1: this query runs ${entry.value}× in this request',
                        style: context.type.bodySmall.copyWith(
                          color: colors.warningText,
                        ),
                      ),
                      const Gap(FwSpacing.xxs),
                      // Tinted to the banner rather than to the palette: the
                      // plain ink the highlighter leaves unclaimed reads as a
                      // second voice on an amber card.
                      _Sql(entry.key, maxLines: 3, color: colors.warningText),
                    ],
                  ),
                ),
              ],
            ),
          ),
        _Waterfall(server: server, request: request, spans: spans),
      ],
    );
  }
}

/// The request's own queries, each expandable to its parameters, row count
/// and an inline explain — the "simple case" viewer, one tap from a request.
class _RequestSqlTab extends StatefulWidget {
  const _RequestSqlTab({required this.server, required this.queries});

  final TrackedServer server;
  final List<ServerEvent> queries;

  @override
  State<_RequestSqlTab> createState() => _RequestSqlTabState();
}

class _RequestSqlTabState extends State<_RequestSqlTab> {
  final _expanded = <int>{};
  final _explained = <int, Object?>{};
  final _busy = <int>{};

  Future<void> _explain(ServerEvent event) async {
    setState(() => _busy.add(event.id));
    Object? result;
    try {
      result = await sqlCommand(widget.server, 'explain', event);
    } on Object catch (e) {
      result =
          '$e\n\nThe server registers command handlers itself — see the '
          'sql adapter snippets in doc/server_inspection.md.';
    }
    if (!mounted) return;
    setState(() {
      _busy.remove(event.id);
      _explained[event.id] = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    if (widget.queries.isEmpty) {
      return const EmptyState(
        icon: Icons.storage_outlined,
        title: 'No queries in this request',
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
      children: [
        for (var event in widget.queries) ...[
          Tappable(
            onTap: () => setState(() {
              _expanded.contains(event.id)
                  ? _expanded.remove(event.id)
                  : _expanded.add(event.id);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.xl,
                vertical: FwSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded.contains(event.id)
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: FwIconSize.md,
                    color: colors.mut3,
                  ),
                  const Gap(FwSpacing.xs),
                  Expanded(child: _Sql('${event.payload['query']}')),
                  if (event.payload['rows'] is int) ...[
                    const Gap(FwSpacing.md),
                    Text(
                      '${event.payload['rows']} rows',
                      style: context.type.caption.copyWith(color: colors.mut2),
                    ),
                  ],
                  const Gap(FwSpacing.md),
                  Text(_ms(event.payload['ms']), style: mono),
                ],
              ),
            ),
          ),
          if (_expanded.contains(event.id))
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FwSpacing.xxxl + FwSpacing.xs,
                0,
                FwSpacing.xl,
                FwSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FwCodeBlock(
                    '${event.payload['query']}',
                    language: 'sql',
                    padding: const EdgeInsets.all(FwSpacing.md),
                  ),
                  if (event.payload['params'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: FwSpacing.xxs),
                      child: Text(
                        'params: ${jsonEncode(event.payload['params'])}',
                        style: mono.copyWith(color: colors.mut2),
                      ),
                    ),
                  const Gap(FwSpacing.sm),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed:
                            _busy.contains(event.id) || !widget.server.connected
                            ? null
                            : () => _explain(event),
                        child: const Text('explain'),
                      ),
                      const Gap(FwSpacing.md),
                      TextButton(
                        onPressed: () => AddressScope.write(context)
                            .setSegments(
                              sqlSegments(
                                widget.server.handle.name,
                                queryKey: queryShapeKey(
                                  normalizeSql(
                                    event.payload['query']! as String,
                                  ),
                                ),
                              ),
                            ),
                        child: const Text('all occurrences'),
                      ),
                    ],
                  ),
                  if (_busy.contains(event.id))
                    const Padding(
                      padding: EdgeInsets.all(FwSpacing.md),
                      child: CircularProgressIndicator(),
                    ),
                  if (_explained[event.id] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: FwSpacing.sm),
                      child: _CommandResult(_explained[event.id]),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// An explain/requery answer: structured responses fold like any JSON, an
/// error reads as text.
class _CommandResult extends StatelessWidget {
  const _CommandResult(this.result);

  final Object? result;

  @override
  Widget build(BuildContext context) {
    var result = this.result;
    if (result is Map || result is List) {
      return JsonView(
        data: result,
        initialExpandDepth: 3,
        searchable: false,
        maxHeight: 360,
      );
    }
    // An error rather than a result — plain, and worth copying into a search.
    return FwCodeBlock('$result', maxHeight: 360);
  }
}

/// One side of the HTTP exchange: headers and body, fetched lazily from the
/// server's detail store the first time this tab opens.
class _HttpMessageTab extends StatelessWidget {
  const _HttpMessageTab({
    required this.server,
    required this.request,
    required this.response,
  });

  final TrackedServer server;
  final ServerEvent request;

  /// False for the request side, true for the response side.
  final bool response;

  @override
  Widget build(BuildContext context) {
    var mono = context.type.mono;
    return FutureBuilder(
      future: server.detailsFor(request),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingState(title: 'Reading the request…');
        }
        var details = snapshot.data;
        var headers = details?[response ? 'responseHeaders' : 'requestHeaders'];
        var body = details?[response ? 'responseBody' : 'requestBody'];
        if (details == null || headers is! Map) {
          return const EmptyState(
            icon: Icons.visibility_off_outlined,
            title: 'Not captured',
            message:
                'The middleware decides what to record — see the capturing '
                'version in doc/server_inspection.md.',
          );
        }
        var headerText = [
          for (var entry in headers.entries) '${entry.key}: ${entry.value}',
        ].join('\n');
        return ListView(
          padding: const EdgeInsets.all(FwSpacing.xl),
          children: [
            Row(
              children: [
                const Expanded(child: _SectionLabel('Headers')),
                // Selecting twenty headers by hand is the thing this replaces.
                CopyIconButton(headerText, tooltip: 'Copy every header'),
              ],
            ),
            const Gap(FwSpacing.sm),
            // One region over the block: a header list is read whole, and a
            // selection that stops at the end of `content-type:` is no use.
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var entry in headers.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text('${entry.key}: ${entry.value}', style: mono),
                    ),
                ],
              ),
            ),
            const Gap(FwSpacing.xl),
            const _SectionLabel('Body'),
            const Gap(FwSpacing.sm),
            body is! String
                ? Text(
                    'Not captured — binary, streamed, or over the size cap.',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut2,
                    ),
                  )
                // A JSON body folds; anything else stays plain text. Sniffing
                // the first character beats trusting content-type, which lies.
                : body.trimLeft().startsWith(RegExp(r'[\[{]'))
                ? JsonView.source(body, maxHeight: 520)
                // Wrapped, unlike a statement: a form-urlencoded or
                // single-line text body is one line as wide as it is long,
                // and scrolling 140,000px sideways is not reading it.
                : FwCodeBlock(body, maxHeight: 520, wrap: true),
          ],
        );
      },
    );
  }
}

/// How loud a log line is, and what a filter pill means by it.
///
/// `package:logging`'s names, folded to the three bands anybody filters on.
/// An unknown word is [info] rather than dropped: the level is whatever the
/// adapter put in the payload, and this panel does not own that vocabulary.
enum _LogBand {
  error,
  warning,
  info;

  static _LogBand of(Object? level) => switch ('$level'.toUpperCase()) {
    'SEVERE' || 'SHOUT' || 'ERROR' || 'FATAL' => _LogBand.error,
    'WARNING' || 'WARN' => _LogBand.warning,
    _ => _LogBand.info,
  };

  Color color(BuildContext context) => switch (this) {
    _LogBand.error => context.colors.red,
    _LogBand.warning => context.colors.amber,
    _LogBand.info => context.colors.mut,
  };
}

/// One log line, wherever it appears.
///
/// The per-request Logs tab and the raw Events stream draw the same row, which
/// they did not: one was a bare `SelectableText` of `"INFO: listed 3 users"`
/// and the other a plain `Text` of the same string, coloured by *channel* — so
/// a `SEVERE` and an `INFO` came out the same grey. The level was in the
/// payload the whole time.
class _LogRow extends StatelessWidget {
  const _LogRow(this.event, {this.showLogger = true});

  final ServerEvent event;

  /// False when every line in the list came from the same logger.
  ///
  /// A column that says `example_server` on all eleven rows is 85px of the
  /// message's width spent saying nothing — and in a request's own Logs tab,
  /// beside a detail, that is a third of what the message had.
  final bool showLogger;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    var p = event.payload;
    var band = _LogBand.of(p['level']);
    var color = band.color(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _timestamp(event.time),
            style: mono.copyWith(color: colors.mut2),
          ),
          const Gap(FwSpacing.md),
          SizedBox(
            width: 62,
            child: Text(
              '${p['level'] ?? 'LOG'}',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: context.type.micro.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p['message']}',
                  style: mono.copyWith(
                    color: band == _LogBand.info ? colors.ink : color,
                  ),
                ),
                // Never shown before, in either surface — a log line that
                // carried an exception said only its message.
                if (p['error'] case var error?)
                  Text('$error', style: mono.copyWith(color: colors.red)),
              ],
            ),
          ),
          if (showLogger)
            if (p['logger'] case var logger? when '$logger'.isNotEmpty) ...[
              const Gap(FwSpacing.md),
              Text(
                '$logger',
                style: context.type.micro.copyWith(color: colors.mut3),
              ),
            ],
        ],
      ),
    );
  }
}

class _RequestLogsTab extends StatefulWidget {
  const _RequestLogsTab(this.logs);

  final List<ServerEvent> logs;

  @override
  State<_RequestLogsTab> createState() => _RequestLogsTabState();
}

class _RequestLogsTabState extends State<_RequestLogsTab> {
  /// Null for all of them.
  _LogBand? _band;
  var _needle = '';

  @override
  Widget build(BuildContext context) {
    if (widget.logs.isEmpty) {
      return const EmptyState(
        icon: Icons.article_outlined,
        title: 'No logs in this request',
      );
    }
    var needle = _needle.trim().toLowerCase();
    var shown = [
      for (var log in widget.logs)
        if ((_band == null || _matchesBand(log, _band!)) &&
            (needle.isEmpty || _summary(log).toLowerCase().contains(needle)))
          log,
    ];
    var manyLoggers =
        {for (var log in widget.logs) '${log.payload['logger']}'}.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwFilterBar(
          pills: [
            ('All', _band == null, () => setState(() => _band = null)),
            for (var band in [_LogBand.warning, _LogBand.error])
              (
                band == _LogBand.error ? 'Errors' : 'Warnings+',
                _band == band,
                () => setState(() => _band = band),
              ),
          ],
          hint: 'Filter lines…',
          onSearch: (value) => setState(() => _needle = value),
          count: '${shown.length} of ${widget.logs.length}',
        ),
        Expanded(
          child: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.xl,
                vertical: FwSpacing.sm,
              ),
              children: [
                for (var log in shown) _LogRow(log, showLogger: manyLoggers),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// `Warnings+` includes errors, the way a level threshold does — a filter that
/// hid the errors when you asked for warnings would be a trap.
bool _matchesBand(ServerEvent log, _LogBand band) {
  var it = _LogBand.of(log.payload['level']);
  return band == _LogBand.error ? it == _LogBand.error : it != _LogBand.info;
}

/// Spans as bars over the request's duration.
///
/// An event carries its *end* (the event time) and its duration, so each bar
/// is `[time - ms, time]`, laid out against the request's own interval and
/// clamped — clock skew between an event and its request is possible and must
/// not push a bar off the canvas.
class _Waterfall extends StatelessWidget {
  const _Waterfall({
    required this.server,
    required this.request,
    required this.spans,
  });

  final TrackedServer server;
  final ServerEvent request;
  final List<ServerEvent> spans;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var requestMs = (request.payload['ms'] as num?)?.toDouble() ?? 0;
    var end = request.time.millisecondsSinceEpoch.toDouble();
    var start = end - requestMs;
    var total = requestMs <= 0 ? 1.0 : requestMs;

    Widget row(String label, double fromMs, double widthMs, Color color) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
        child: Row(
          children: [
            SizedBox(
              width: 260,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.mono,
              ),
            ),
            const Gap(FwSpacing.md),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  var left =
                      (fromMs / total).clamp(0.0, 1.0) * constraints.maxWidth;
                  var width =
                      (widthMs / total).clamp(0.0, 1.0) * constraints.maxWidth;
                  return Stack(
                    children: [
                      Container(height: 14),
                      Positioned(
                        left: left,
                        width: width < 2 ? 2 : width,
                        child: Container(
                          height: 14,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(
                              context.radii.micro,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Waterfall'),
        const Gap(FwSpacing.sm),
        // The request is the ruler the spans are read against, so it is the
        // accent; what it caused is quieter than it, and a query is told from
        // anything else by hue rather than by weight.
        row(
          'request (${_ms(request.payload['ms'])})',
          0,
          total,
          colors.accent.withValues(alpha: 0.55),
        ),
        for (var span in spans)
          // A sql span is a door into its shape's detail — same query, seen
          // from the aggregate side.
          Tappable(
            onTap: span.channel != 'sql' || span.payload['query'] is! String
                ? null
                : () => AddressScope.write(context).setSegments(
                    sqlSegments(
                      server.handle.name,
                      queryKey: queryShapeKey(
                        normalizeSql(span.payload['query']! as String),
                      ),
                    ),
                  ),
            child: row(
              _summary(span),
              ((span.time.millisecondsSinceEpoch -
                          (span.payload['ms']! as num)) -
                      start)
                  .toDouble(),
              (span.payload['ms']! as num).toDouble(),
              span.channel == 'sql' ? colors.grn : colors.info,
            ),
          ),
      ],
    );
  }
}

/// The per-server flat timeline — what the panel shows when no request is
/// selected, so events outside any request (startup logs, background work)
/// stay visible.
/// The self-description pane — what the server published with
/// `FlutterwareServer.info`, made actionable: links open in the browser,
/// DSN passwords and secret-like config values are masked until clicked,
/// copy always copies the real value.
class _InfoView extends StatefulWidget {
  const _InfoView({required this.info});

  final ServerInfo info;

  @override
  State<_InfoView> createState() => _InfoViewState();
}

class _InfoViewState extends State<_InfoView> {
  /// What the user chose to see in the clear — masking guards screen shares,
  /// so it yields to one deliberate click, per value.
  final _revealed = <String>{};

  @override
  Widget build(BuildContext context) {
    var info = widget.info;
    if (info.isEmpty) return const _NoInfoHint();
    var links = info.links ?? const [];
    var connections = info.connections ?? const [];
    var config = info.config ?? const {};
    // Shrink-wrapped: the card is bounded but most servers publish a dozen
    // lines, and a 480px card holding fourteen of content is a card with a
    // hole in it. It scrolls when a real config outgrows the bound.
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        if (links.isNotEmpty) ...[
          const _SectionLabel('Links'),
          const Gap(FwSpacing.sm),
          for (var link in links) _LinkRow(link, baseUrl: info.baseUrl),
          const Gap(FwSpacing.xl),
        ],
        if (connections.isNotEmpty) ...[
          const _SectionLabel('Connections'),
          const Gap(FwSpacing.sm),
          for (var (index, connection) in connections.indexed)
            _connectionRow(context, 'conn-$index', connection),
          const Gap(FwSpacing.xl),
        ],
        for (var group in config.entries) ...[
          _SectionLabel(group.key),
          const Gap(FwSpacing.sm),
          for (var entry in group.value.entries)
            _configRow(context, '${group.key}/${entry.key}', entry),
          const Gap(FwSpacing.xl),
        ],
      ],
    );
  }

  Widget _connectionRow(
    BuildContext context,
    String key,
    ServerConnection connection,
  ) {
    var masked = maskDsn(connection.dsn);
    var secret = masked != connection.dsn;
    var revealed = _revealed.contains(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
      child: Row(
        children: [
          _KindChip(connection.kind),
          const Gap(FwSpacing.md),
          if (connection.label != null) ...[
            Text(connection.label!, style: context.type.bodySmall),
            const Gap(FwSpacing.md),
          ],
          Flexible(
            child: SelectableText(
              revealed ? connection.dsn : masked,
              maxLines: 1,
              style: context.type.mono,
            ),
          ),
          if (secret)
            _SmallIconButton(
              revealed ? Icons.visibility_off : Icons.visibility,
              tooltip: revealed ? 'Mask' : 'Reveal',
              onTap: () => setState(() {
                revealed ? _revealed.remove(key) : _revealed.add(key);
              }),
            ),
          _SmallIconButton(
            Icons.copy,
            tooltip: 'Copy',
            onTap: () => Clipboard.setData(ClipboardData(text: connection.dsn)),
          ),
        ],
      ),
    );
  }

  Widget _configRow(
    BuildContext context,
    String key,
    MapEntry<String, Object?> entry,
  ) {
    var value = entry.value;
    var secret = isSecretLikeKey(entry.key);
    var revealed = _revealed.contains(key);
    if (secret && !revealed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            Text('${entry.key}: ••••', style: context.type.mono),
            _SmallIconButton(
              Icons.visibility,
              tooltip: 'Reveal',
              onTap: () => setState(() => _revealed.add(key)),
            ),
          ],
        ),
      );
    }
    if (value is Map || value is List) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${entry.key}:', style: context.type.mono),
            Padding(
              padding: const EdgeInsets.only(left: FwSpacing.xl),
              child: JsonView(
                data: value,
                showToolbar: false,
                searchable: false,
                maxHeight: 240,
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Flexible(
            child: SelectableText(
              '${entry.key}: $value',
              maxLines: 1,
              style: context.type.mono,
            ),
          ),
          if (secret)
            _SmallIconButton(
              Icons.visibility_off,
              tooltip: 'Mask',
              onTap: () => setState(() => _revealed.remove(key)),
            ),
        ],
      ),
    );
  }
}

/// One published link: the label opens it, the resolved URL sits beside it.
/// A relative URL with no base to resolve against renders as plain text —
/// an honest "the server did not say where it listens".
class _LinkRow extends StatelessWidget {
  const _LinkRow(this.link, {required this.baseUrl});

  final ServerLink link;
  final String? baseUrl;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var resolved = resolveLinkUrl(link.url, baseUrl: baseUrl);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.xxs),
      child: Row(
        children: [
          resolved == null
              ? Text(link.label, style: context.type.bodySmall)
              : _UrlLink(resolved, label: link.label),
          const Gap(FwSpacing.md),
          Flexible(
            child: Text(
              resolved ?? link.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.mono.copyWith(color: colors.mut2),
            ),
          ),
          if (link.description != null) ...[
            const Gap(FwSpacing.md),
            Flexible(
              child: Text(
                link.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.caption.copyWith(color: colors.mut2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A connection's kind — `postgres`, `redis` — as a colored tag. A word the
/// GUI does not need to understand, per [ServerConnection.kind].
class _KindChip extends StatelessWidget {
  const _KindChip(this.kind);

  final String kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: context.colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        kind,
        style: context.type.micro.copyWith(color: context.colors.accent),
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton(
    this.icon, {
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: FwSpacing.sm),
      child: Tooltip(
        message: tooltip,
        child: Tappable.builder(
          onTap: onTap,
          builder: (context, hovered) => Icon(
            icon,
            size: FwIconSize.sm,
            color: hovered ? context.colors.accent : context.colors.mut3,
          ),
        ),
      ),
    );
  }
}

class _NoInfoHint extends StatelessWidget {
  const _NoInfoHint();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.xl),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This server has not published anything about itself.',
              style: context.type.bodySmall.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.sm),
            Text(
              'It can, in one call after `serve` returns:',
              style: context.type.caption.copyWith(color: colors.mut2),
            ),
            const Gap(FwSpacing.lg),
            const FwCodeBlock(
              'FlutterwareServer.info(ServerInfo(\n'
              "  baseUrl: 'http://localhost:\$port',\n"
              "  environment: 'dev',\n"
              "  links: [ServerLink('Health', '/health')],\n"
              '));',
              language: 'dart',
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTimeline extends StatefulWidget {
  const _EventTimeline(this.server, this.events);

  final TrackedServer server;
  final List<ServerEvent> events;

  @override
  State<_EventTimeline> createState() => _EventTimelineState();
}

class _EventTimelineState extends State<_EventTimeline> {
  /// Null for every channel.
  String? _channel;
  var _needle = '';

  @override
  Widget build(BuildContext context) {
    if (widget.events.isEmpty) {
      return const LoadingState(
        title: 'Attached — waiting for events',
        message: 'Anything this server reports will land here.',
      );
    }
    var needle = _needle.trim().toLowerCase();
    var shown = [
      for (var event in widget.events.reversed)
        if ((_channel == null || event.channel == _channel) &&
            (needle.isEmpty || _summary(event).toLowerCase().contains(needle)))
          event,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FwFilterBar(
          pills: [
            ('All', _channel == null, () => setState(() => _channel = null)),
            for (var (id, label) in const [
              ('http', 'HTTP'),
              ('sql', 'SQL'),
              ('log', 'Logs'),
            ])
              (label, _channel == id, () => setState(() => _channel = id)),
          ],
          hint: 'Filter the stream…',
          onSearch: (value) => setState(() => _needle = value),
          count: '${shown.length} of ${widget.events.length}',
        ),
        // Not selectable, for the reason the SQL list gives: two thirds of
        // these rows open something, and a caret over a control that responds
        // to a click is one affordance too many. The per-request Logs tab is
        // where a log line is selectable, because nothing there is a target.
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, index) =>
                _EventRow(server: widget.server, event: shown[index]),
          ),
        ),
      ],
    );
  }
}

/// One event of the raw stream — and a door, when it has somewhere to go.
///
/// Every row here used to be an inert `Text`, though two of the three kinds
/// name a place this panel can already show: an `http` event is a request the
/// Requests tab has a detail for, and a `sql` event belongs to a shape the SQL
/// tab has an aggregate for. Only a `log` line is a leaf.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.server, required this.event});

  final TrackedServer server;
  final ServerEvent event;

  VoidCallback? _open(BuildContext context) {
    var address = AddressScope.write(context);
    var name = server.handle.name;
    return switch (event.channel) {
      'http' => () => address.setSegments(
        serverSegments(name, requestId: event.id),
      ),
      'sql' when event.payload['query'] is String => () => address.setSegments(
        sqlSegments(
          name,
          queryKey: queryShapeKey(
            normalizeSql(event.payload['query']! as String),
          ),
        ),
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var mono = context.type.mono;
    return Tappable(
      onTap: _open(context),
      // A log line is not a link, so it must not take the click cursor.
      cursor: _open(context) == null ? SystemMouseCursors.basic : null,
      feedback: _open(context) == null ? TapFeedback.none : TapFeedback.overlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: panelGutter,
          vertical: FwSpacing.xs,
        ),
        child: Row(
          children: [
            Text(
              _timestamp(event.time),
              style: mono.copyWith(color: colors.mut2),
            ),
            const Gap(FwSpacing.md),
            _ChannelChip(event),
            const Gap(FwSpacing.md),
            Expanded(
              child: switch (event.channel) {
                'sql' when event.payload['query'] is String => _Sql(
                  '${event.payload['query']}',
                ),
                'log' => Row(
                  children: [
                    SizedBox(
                      width: 62,
                      child: Text(
                        '${event.payload['level'] ?? 'LOG'}',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: context.type.micro.copyWith(
                          color: _LogBand.of(event.payload['level'])
                              .color(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${event.payload['message']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono,
                      ),
                    ),
                  ],
                ),
                _ => Text(
                  _summary(event),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip(this.event);

  final ServerEvent event;

  /// Fixed width, so the summaries beside them line up down the stream: the
  /// channel is a column, and a column whose left edge moves per row is one the
  /// eye cannot run down.
  static const _width = 34.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    // A log's colour is its level, not its channel. Painting every `log`
    // chip the same grey meant a SEVERE and an INFO were the same row until
    // you read the words.
    var color = _failed(event)
        ? colors.red
        : switch (event.channel) {
            'http' => colors.accent,
            'sql' => colors.grn,
            'log' => _LogBand.of(event.payload['level']).color(context),
            _ => colors.info,
          };
    return Container(
      width: _width,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        event.channel,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: context.type.micro.copyWith(color: color),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.dns_outlined,
      title: 'No servers are announcing themselves',
      message:
          'Report from one with package:flutterware/server.dart — an event, '
          'a span or a handler is enough; it publishes on first use.',
    );
  }
}

/// Whether a row should read as a failure.
///
/// `>= 400`, not `>= 500`. The dot used to go green on a 404, which is the
/// one status a request list is most often opened to find.
bool _failed(ServerEvent event) =>
    event.payload['error'] != null ||
    switch (event.payload['status']) {
      int status => status >= 400,
      _ => false,
    };

String _summary(ServerEvent event) {
  var p = event.payload;
  return switch (event.channel) {
    'http' => '${p['method']} ${p['path']} → ${p['status']} (${_ms(p['ms'])})',
    'sql' => '${p['query']} (${_ms(p['ms'])})',
    'log' => '${p['level']}: ${p['message']}',
    _ => p.toString(),
  };
}

String _ms(Object? value) =>
    value is num ? '${value.toStringAsFixed(1)}ms' : '';

/// `hh:mm:ss`, for a row with no width for the milliseconds.
String _clock(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String _timestamp(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}'
    '.${time.millisecond.toString().padLeft(3, '0')}';

String _two(int n) => n.toString().padLeft(2, '0');

extension<T> on Iterable<T> {
  T? get firstOrNull {
    var it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
