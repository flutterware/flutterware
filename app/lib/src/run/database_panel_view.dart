import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/channels.dart';

import 'panel_client.dart';
import '../ui/design/design.dart';
import '../ui/loading_state.dart';
import '../ui/empty_state.dart';

/// The cockpit's bespoke renderer for `db:*` panels — a database browser, not
/// a descriptor dump.
///
/// The generic [PanelView] renders any panel and stays the surface for `fw`
/// and agents, but S-DB1's human review was blunt: empty feed panes and a
/// "Controls" form are not how a person meets a database. This view spends the
/// same wire — `schema` state, `query`/`watch`/`unwatch`/`execute` actions,
/// the `changes` and `watch` feeds — on the screen a person expects: tables on
/// the left with live row counts, a data grid that follows the app's writes,
/// a SQL editor, and the live activity stream.
class DatabasePanelView extends StatefulWidget {
  const DatabasePanelView({
    super.key,
    required this.panels,
    required this.descriptor,
    required this.events,
    required this.details,
  });

  final RunPanels panels;
  final PanelDescriptor descriptor;

  /// Feed id → events held by this attachment, oldest first.
  final Map<String, List<InspectorEvent>> events;

  /// Fetches a ring event's lazily-held details — a watch snapshot's rows.
  final Future<Map<String, Object?>?> Function(int eventId) details;

  @override
  State<DatabasePanelView> createState() => _DatabasePanelViewState();
}

/// What the main pane shows: a table's data, the SQL editor, or the activity
/// stream.
sealed class _Pane {
  const _Pane();
}

class _TablePane extends _Pane {
  const _TablePane(this.table);

  final String table;
}

class _SqlPane extends _Pane {
  const _SqlPane();
}

class _ActivityPane extends _Pane {
  const _ActivityPane();
}

class _TableInfo {
  _TableInfo(this.name, this.type, this.rows, this.columns);

  final String name;

  /// `table` or `view`, straight from sqlite_master.
  final String type;

  final int? rows;
  final String columns;

  bool get isView => type == 'view';
}

class _DatabasePanelViewState extends State<DatabasePanelView> {
  List<_TableInfo> _tables = const [];
  String? _schemaError;
  var _loadingSchema = true;

  _Pane _pane = const _SqlPane();

  /// The grid the main pane shows for [_TablePane], keyed by table so
  /// switching tables never shows another table's rows under this header.
  final _tableData = <String, Map<String, Object?>>{};
  final _tableErrors = <String, String>{};
  DateTime? _refreshedAt;

  /// The last `changes` event already folded into the grids, so a rebuild
  /// with the same events does not re-query.
  int _seenChange = 0;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSchema(selectFirst: true));
  }

  @override
  void didUpdateWidget(DatabasePanelView old) {
    super.didUpdateWidget(old);
    _followChanges();
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    super.dispose();
  }

  List<InspectorEvent> _feed(String id) => widget.events[id] ?? const [];

  /// A write happened in the app: refresh the row counts and, if the visible
  /// table was touched, its grid — debounced so a burst costs one refresh.
  void _followChanges() {
    var changes = _feed('changes');
    if (changes.isEmpty || changes.last.id == _seenChange) return;
    var touched = <String>{};
    for (var event in changes) {
      if (event.id <= _seenChange) continue;
      touched.addAll('${event.payload['tables']}'.split(' '));
    }
    _seenChange = changes.last.id;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_loadSchema());
      var pane = _pane;
      if (pane is _TablePane && touched.contains(pane.table)) {
        unawaited(_loadTable(pane.table));
      }
    });
  }

  Future<void> _loadSchema({bool selectFirst = false}) async {
    try {
      var schema = await widget.panels.state(widget.descriptor.id, 'schema');
      if (!mounted) return;
      var tables = [
        for (var table in schema['tables'] as List? ?? const [])
          _TableInfo(
            '${(table as Map)['name']}',
            '${table['type'] ?? 'table'}',
            table['rows'] as int?,
            '${table['columns'] ?? ''}',
          ),
      ];
      setState(() {
        _tables = tables;
        _loadingSchema = false;
        _schemaError = null;
        if (selectFirst && tables.isNotEmpty) {
          _pane = _TablePane(tables.first.name);
        }
      });
      var pane = _pane;
      if (selectFirst && pane is _TablePane) {
        await _loadTable(pane.table);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSchema = false;
        _schemaError = '$e';
      });
    }
  }

  Future<void> _loadTable(String table) async {
    try {
      var reply = await widget.panels.invoke(widget.descriptor.id, 'query', {
        'sql': 'SELECT * FROM "${table.replaceAll('"', '""')}"',
        'limit': 200,
      });
      if (!mounted) return;
      setState(() {
        _tableData[table] = reply;
        _tableErrors.remove(table);
        _refreshedAt = DateTime.now();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _tableErrors[table] = '$e');
    }
  }

  void _open(_Pane pane) {
    setState(() => _pane = pane);
    if (pane is _TablePane && !_tableData.containsKey(pane.table)) {
      unawaited(_loadTable(pane.table));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 220, child: _sidebar(context)),
        VerticalDivider(width: 1, color: context.colors.line),
        Expanded(child: _main(context)),
      ],
    );
  }

  // --- Sidebar -------------------------------------------------------------

  Widget _sidebar(BuildContext context) {
    var pane = _pane;
    var activity = _feed('changes').length + _feed('watch').length;
    return Container(
      color: context.colors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.lg,
              FwSpacing.lg,
              FwSpacing.md,
              FwSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'TABLES & VIEWS',
                    style: context.type.sectionLabel,
                  ),
                ),
                _IconAction(
                  icon: Icons.refresh,
                  tooltip: 'Refresh row counts',
                  onTap: () => unawaited(_loadSchema()),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loadingSchema
                ? const Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _schemaError != null
                ? Padding(
                    padding: const EdgeInsets.all(FwSpacing.lg),
                    child: Text(
                      _schemaError!,
                      style: context.type.caption.copyWith(
                        color: context.colors.red,
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      if (_tables.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(FwSpacing.lg),
                          child: Text(
                            'No tables or views yet.',
                            style: context.type.bodyMuted,
                          ),
                        ),
                      for (var table in _tables)
                        _SidebarItem(
                          selected:
                              pane is _TablePane && pane.table == table.name,
                          onTap: () => _open(_TablePane(table.name)),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  table.name,
                                  style: context.type.body,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (table.isView) ...[
                                const Gap(FwSpacing.sm),
                                const _TypeBadge('view'),
                              ],
                              const Gap(FwSpacing.md),
                              Text(
                                table.rows == null ? '' : '${table.rows}',
                                style: context.type.caption.copyWith(
                                  color: context.colors.mut2,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          Divider(height: 1, color: context.colors.line),
          _SidebarItem(
            selected: pane is _SqlPane,
            onTap: () => _open(const _SqlPane()),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: FwIconSize.md,
                  color: pane is _SqlPane
                      ? context.colors.accent
                      : context.colors.mut,
                ),
                const Gap(FwSpacing.md),
                Text('Query', style: context.type.body),
              ],
            ),
          ),
          _SidebarItem(
            selected: pane is _ActivityPane,
            onTap: () => _open(const _ActivityPane()),
            child: Row(
              children: [
                Icon(
                  Icons.bolt,
                  size: FwIconSize.md,
                  color: pane is _ActivityPane
                      ? context.colors.accent
                      : context.colors.mut,
                ),
                const Gap(FwSpacing.md),
                Expanded(child: Text('Activity', style: context.type.body)),
                if (activity > 0)
                  Text(
                    '$activity',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut2,
                    ),
                  ),
              ],
            ),
          ),
          const Gap(FwSpacing.sm),
        ],
      ),
    );
  }

  // --- Main pane -----------------------------------------------------------

  Widget _main(BuildContext context) => switch (_pane) {
    _TablePane(:var table) => _TableView(
      key: ValueKey('table:$table'),
      table: table,
      info: _tables.where((t) => t.name == table).firstOrNull,
      reply: _tableData[table],
      error: _tableErrors[table],
      refreshedAt: _refreshedAt,
      onRefresh: () => unawaited(_loadTable(table)),
    ),
    _SqlPane() => _SqlView(
      key: const ValueKey('sql'),
      panels: widget.panels,
      descriptor: widget.descriptor,
    ),
    _ActivityPane() => _ActivityView(
      key: const ValueKey('activity'),
      changes: _feed('changes'),
      snapshots: _feed('watch'),
      details: widget.details,
      onUnwatch: (id) => unawaited(
        widget.panels.invoke(widget.descriptor.id, 'unwatch', {'id': id}),
      ),
    ),
  };
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: context.colors.line,
        borderRadius: BorderRadius.circular(context.radii.micro),
      ),
      child: Text(
        label,
        style: context.type.micro.copyWith(color: context.colors.mut2),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? context.colors.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.lg,
            vertical: FwSpacing.sm + 1,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radii.micro),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xs),
          child: Icon(icon, size: FwIconSize.md, color: context.colors.mut),
        ),
      ),
    );
  }
}

// --- Table view ------------------------------------------------------------

class _TableView extends StatelessWidget {
  const _TableView({
    super.key,
    required this.table,
    required this.info,
    required this.reply,
    required this.error,
    required this.refreshedAt,
    required this.onRefresh,
  });

  final String table;
  final _TableInfo? info;
  final Map<String, Object?>? reply;
  final String? error;
  final DateTime? refreshedAt;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FwSpacing.xl,
            FwSpacing.lg,
            FwSpacing.xl,
            FwSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(table, style: context.type.heading),
              if (info?.isView ?? false) ...[
                const Gap(FwSpacing.sm),
                const _TypeBadge('view'),
              ],
              const Gap(FwSpacing.md),
              Expanded(
                child: Text(
                  info?.columns ?? '',
                  style: context.type.caption.copyWith(
                    color: context.colors.mut2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _IconAction(
                icon: Icons.refresh,
                tooltip: 'Refresh',
                onTap: onRefresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: error != null
              ? _ErrorPane(error!)
              : reply == null
              ? const LoadingState(title: 'Running the query…')
              : _ResultGrid(reply: reply!),
        ),
        if (reply != null) _footer(context),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    var total = reply!['rowCount'] ?? 0;
    var shown = (reply!['rows'] as List? ?? const []).length;
    var truncated = reply!['truncated'] == true;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.colors.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            truncated ? 'First $shown of $total rows' : '$total rows',
            style: context.type.caption.copyWith(color: context.colors.mut),
          ),
          const Spacer(),
          if (refreshedAt != null)
            Text(
              'refreshed ${_ago(refreshedAt!)} · follows writes',
              style: context.type.caption.copyWith(color: context.colors.mut2),
            ),
        ],
      ),
    );
  }
}

// --- SQL view --------------------------------------------------------------

class _SqlView extends StatefulWidget {
  const _SqlView({super.key, required this.panels, required this.descriptor});

  final RunPanels panels;
  final PanelDescriptor descriptor;

  @override
  State<_SqlView> createState() => _SqlViewState();
}

class _SqlViewState extends State<_SqlView> {
  final _sql = TextEditingController();
  Map<String, Object?>? _reply;
  String? _error;
  String? _notice;
  var _running = false;

  bool get _canExecute =>
      widget.descriptor.actions.any((action) => action.id == 'execute');

  bool get _canWatch =>
      widget.descriptor.actions.any((action) => action.id == 'watch');

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  Future<void> _run(String action) async {
    var sql = _sql.text.trim();
    if (sql.isEmpty) return;
    setState(() {
      _running = true;
      _notice = null;
    });
    try {
      var reply = await widget.panels.invoke(widget.descriptor.id, action, {
        'sql': sql,
        'limit': 200,
      });
      if (!mounted) return;
      setState(() {
        if (action == 'watch') {
          _notice =
              'Watching as #${reply['watch']} — every change now lands in '
              'Activity.';
        } else {
          _reply = reply;
          _error = null;
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        if (action != 'watch') _reply = null;
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(FwSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    meta: true,
                  ): () =>
                      unawaited(_run('query')),
                },
                child: TextField(
                  key: const Key('db.sql'),
                  controller: _sql,
                  maxLines: 4,
                  minLines: 2,
                  style: context.type.mono.copyWith(
                    fontSize: context.type.body.fontSize,
                  ),
                  decoration: InputDecoration(
                    hintText: 'SELECT * FROM …',
                    hintStyle: context.type.mono.copyWith(
                      fontSize: context.type.body.fontSize,
                      color: context.colors.mut3,
                    ),
                    contentPadding: const EdgeInsets.all(FwSpacing.lg),
                  ),
                ),
              ),
              const Gap(FwSpacing.md),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _running ? null : () => unawaited(_run('query')),
                    icon: const Icon(Icons.play_arrow, size: FwIconSize.md),
                    label: const Text('Run'),
                  ),
                  const Gap(FwSpacing.md),
                  Text(
                    '⌘↵',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut3,
                    ),
                  ),
                  const Gap(FwSpacing.xl),
                  if (_canWatch)
                    OutlinedButton.icon(
                      onPressed: _running
                          ? null
                          : () => unawaited(_run('watch')),
                      icon: const Icon(
                        Icons.visibility_outlined,
                        size: FwIconSize.md,
                      ),
                      label: const Text('Watch'),
                    ),
                  const Spacer(),
                  if (_canExecute)
                    OutlinedButton.icon(
                      onPressed: _running
                          ? null
                          : () => unawaited(_run('execute')),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.colors.red,
                      ),
                      icon: const Icon(
                        Icons.warning_amber,
                        size: FwIconSize.md,
                      ),
                      label: const Text('Execute write'),
                    ),
                ],
              ),
              if (_notice != null) ...[
                const Gap(FwSpacing.md),
                Text(
                  _notice!,
                  style: context.type.caption.copyWith(
                    color: context.colors.grn,
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: context.colors.line),
        Expanded(
          child: _error != null
              ? _ErrorPane(_error!)
              : _reply == null
              ? const EmptyState(
                  icon: Icons.table_rows_outlined,
                  title: 'Results appear here',
                  message: 'Run a query above.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _ResultGrid(reply: _reply!)),
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: context.colors.line),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: FwSpacing.xl,
                        vertical: FwSpacing.sm,
                      ),
                      child: Text(
                        _reply!['truncated'] == true
                            ? 'First ${(_reply!['rows'] as List? ?? const []).length} '
                                  'of ${_reply!['rowCount']} rows'
                            : '${_reply!['rowCount']} rows',
                        style: context.type.caption.copyWith(
                          color: context.colors.mut,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

// --- Activity view ---------------------------------------------------------

class _ActivityView extends StatelessWidget {
  const _ActivityView({
    super.key,
    required this.changes,
    required this.snapshots,
    required this.details,
    required this.onUnwatch,
  });

  final List<InspectorEvent> changes;
  final List<InspectorEvent> snapshots;
  final Future<Map<String, Object?>?> Function(int eventId) details;
  final void Function(int watchId) onUnwatch;

  @override
  Widget build(BuildContext context) {
    var merged = [...changes, ...snapshots]
      ..sort((a, b) => b.id.compareTo(a.id));
    if (merged.isEmpty) {
      // This was EmptyState retyped: same xl icon in mut3, same md gap, same
      // two lines. It differed only in the details nobody chose on purpose —
      // an xs gap where the component uses xxs, and a caption where it uses
      // bodyMuted — which is exactly the drift a shared component exists to
      // stop.
      return const EmptyState(
        icon: Icons.bolt,
        title: 'Nothing yet',
        message:
            'Writes tick here as the app makes them; a watched query '
            'reports every result change.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      itemCount: merged.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, indent: FwSpacing.xl, color: context.colors.line),
      itemBuilder: (context, index) {
        var event = merged[index];
        return event.channel.endsWith('/changes')
            ? _ChangeRow(event)
            : _SnapshotRow(event, details: details, onUnwatch: onUnwatch);
      },
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow(this.event);

  final InspectorEvent event;

  @override
  Widget build(BuildContext context) {
    var transactions = event.payload['transactions'];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.xl,
        vertical: FwSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.edit_outlined,
            size: FwIconSize.md,
            color: context.colors.mut2,
          ),
          const Gap(FwSpacing.md),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${event.payload['tables']}',
                    style: context.type.bodyStrong,
                  ),
                  TextSpan(
                    text: transactions == 1
                        ? '  ·  1 write'
                        : '  ·  $transactions writes',
                    style: context.type.body.copyWith(
                      color: context.colors.mut,
                    ),
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _ago(event.time),
            style: context.type.caption.copyWith(color: context.colors.mut2),
          ),
        ],
      ),
    );
  }
}

class _SnapshotRow extends StatefulWidget {
  const _SnapshotRow(
    this.event, {
    required this.details,
    required this.onUnwatch,
  });

  final InspectorEvent event;
  final Future<Map<String, Object?>?> Function(int eventId) details;
  final void Function(int watchId) onUnwatch;

  @override
  State<_SnapshotRow> createState() => _SnapshotRowState();
}

class _SnapshotRowState extends State<_SnapshotRow> {
  Map<String, Object?>? _rows;
  var _open = false;
  var _evicted = false;

  Future<void> _toggle() async {
    setState(() => _open = !_open);
    if (_rows != null || !_open) return;
    var details = await widget.details(widget.event.id);
    if (!mounted) return;
    setState(() {
      if (details == null) {
        _evicted = true;
      } else {
        _rows = details;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    var payload = widget.event.payload;
    var error = payload['error'] as String?;
    var watchId = payload['watch'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: error == null ? () => unawaited(_toggle()) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.xl,
              vertical: FwSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  error == null ? Icons.visibility_outlined : Icons.error,
                  size: FwIconSize.md,
                  color: error == null
                      ? context.colors.accent
                      : context.colors.red,
                ),
                const Gap(FwSpacing.md),
                Expanded(
                  child: Text(
                    '${payload['sql']}',
                    style: context.type.mono,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Gap(FwSpacing.md),
                if (error == null)
                  Text(
                    payload['rows'] == 1 ? '1 row' : '${payload['rows']} rows',
                    style: context.type.caption.copyWith(
                      color: context.colors.mut,
                    ),
                  ),
                const Gap(FwSpacing.md),
                Text(
                  _ago(widget.event.time),
                  style: context.type.caption.copyWith(
                    color: context.colors.mut2,
                  ),
                ),
                if (watchId is int && error == null) ...[
                  const Gap(FwSpacing.sm),
                  _IconAction(
                    icon: Icons.close,
                    tooltip: 'Stop watching #$watchId',
                    onTap: () => widget.onUnwatch(watchId),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xxxl + FwSpacing.xs,
              0,
              FwSpacing.xl,
              FwSpacing.sm,
            ),
            child: Text(
              error,
              style: context.type.caption.copyWith(color: context.colors.red),
            ),
          ),
        if (_open)
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            margin: const EdgeInsets.fromLTRB(
              FwSpacing.xxxl,
              0,
              FwSpacing.xl,
              FwSpacing.md,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(context.radii.micro),
            ),
            child: _evicted
                ? Padding(
                    padding: const EdgeInsets.all(FwSpacing.lg),
                    child: Text(
                      'These rows have been evicted — only recent snapshots '
                      'keep their data.',
                      style: context.type.caption.copyWith(
                        color: context.colors.mut,
                      ),
                    ),
                  )
                : _rows == null
                ? const Padding(
                    padding: EdgeInsets.all(FwSpacing.lg),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : _ResultGrid(reply: _rows!),
          ),
      ],
    );
  }
}

// --- Shared pieces ---------------------------------------------------------

/// The one grid every pane uses: header row from `columns`, monospace cells,
/// nulls dimmed, numbers right-aligned, both axes scrollable.
class _ResultGrid extends StatelessWidget {
  const _ResultGrid({required this.reply});

  final Map<String, Object?> reply;

  @override
  Widget build(BuildContext context) {
    var columns = [
      for (var column in reply['columns'] as List? ?? const []) '$column',
    ];
    var rows = [
      for (var row in reply['rows'] as List? ?? const [])
        (row as Map).cast<String, Object?>(),
    ];
    if (columns.isEmpty) {
      return Center(child: Text('No rows.', style: context.type.bodyMuted));
    }
    var numeric = {
      for (var column in columns)
        column:
            rows.any((row) => row[column] is num) &&
            rows.every((row) => row[column] is num || row[column] == null),
    };
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: true),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xl),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder(
                horizontalInside: BorderSide(color: context.colors.line2),
              ),
              children: [
                TableRow(
                  children: [
                    for (var column in columns)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          FwSpacing.md,
                          FwSpacing.sm,
                          FwSpacing.xl,
                          FwSpacing.sm,
                        ),
                        child: Text(
                          column,
                          style: context.type.caption.copyWith(
                            color: context.colors.mut,
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: numeric[column]!
                              ? TextAlign.right
                              : TextAlign.left,
                        ),
                      ),
                  ],
                ),
                for (var row in rows)
                  TableRow(
                    children: [
                      for (var column in columns)
                        _cell(
                          context,
                          row[column],
                          alignRight: numeric[column]!,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    Object? value, {
    required bool alignRight,
  }) {
    var style = context.type.mono;
    if (value == null) {
      style = style.copyWith(
        color: context.colors.mut3,
        fontStyle: FontStyle.italic,
      );
    }
    var text = value == null ? 'NULL' : '$value';
    if (text.length > 120) text = '${text.substring(0, 120)}…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.md,
        FwSpacing.xs + 1,
        FwSpacing.xl,
        FwSpacing.xs + 1,
      ),
      child: Text(
        text,
        style: style,
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        margin: const EdgeInsets.all(FwSpacing.xl),
        padding: const EdgeInsets.all(FwSpacing.lg),
        decoration: BoxDecoration(
          color: context.colors.red.withValues(alpha: 0.06),
          border: Border.all(color: context.colors.red.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Text(
          message,
          style: context.type.mono.copyWith(color: context.colors.red),
        ),
      ),
    );
  }
}

String _ago(DateTime time) {
  var delta = DateTime.now().difference(time);
  if (delta.inSeconds < 5) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  return '${delta.inHours}h ago';
}
