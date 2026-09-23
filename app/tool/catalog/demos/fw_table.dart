import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/table.dart';
import 'package:flutterware_app/src/ui/empty_state.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The table, in the states it actually reaches.
///
/// The largest shared widget with no preview until now, and the one that
/// owned a real bug: below a certain width its flex widths clamp at each
/// column's `minWidth`, so the table stops fitting and starts extending — three
/// columns off the edge with no scrollbar drawn and no fade to say so. The
/// *narrow* entry below is that case, pinned at the width the shell actually
/// guarantees, so it cannot come back unnoticed.
///
/// The rest are the states a list reaches on a slow morning: nothing yet,
/// nothing ever, and a resolve that failed.

class _Row {
  const _Row(this.name, this.kind, this.origin, this.constraint, this.resolved);

  final String name;
  final String kind;
  final String origin;
  final String constraint;
  final String resolved;
}

const _rows = [
  _Row('analyzer', 'Dev', 'pub.dev', 'any', '13.3.0'),
  _Row('built_value', 'Direct', 'pub.dev', '^8.3.0', '8.12.6'),
  _Row('collection', 'Direct', 'pub.dev', '^1.16.0', '1.19.1'),
  _Row('flutter', 'Direct', 'Flutter SDK', 'any', '—'),
  _Row('json_serializable', 'Dev', 'pub.dev', 'any', '6.14.0'),
  _Row('path', 'Direct', 'pub.dev', '^1.8.0', '1.9.1'),
  // The awkward one every table needs and few have: a name with nowhere to
  // break, next to an origin that is a URL rather than a word.
  _Row(
    'a_package_with_a_deliberately_unreasonable_name',
    'Direct',
    'git · someone/a-very-long-repository-name.dart',
    '>=0.6.0 <0.8.0',
    '0.7.12',
  ),
];

/// The seven columns of the real dependencies table, with the same declared
/// widths — 160 + 110 + 120 + 120 + 110 + 90 + 90 = 800, which is where
/// `shellPaneMinimumSize` comes from.
List<FwTableColumn<_Row>> _columns(BuildContext context) => [
  FwTableColumn(
    label: 'Package',
    flex: 3,
    minWidth: 160,
    sortKey: 'name',
    pinned: true,
    cell: (row) => Text(
      row.name,
      style: context.type.bodyStrong,
      overflow: TextOverflow.ellipsis,
    ),
  ),
  FwTableColumn(
    label: 'Type',
    fixed: 110,
    sortKey: 'kind',
    cell: (row) => _Pill(row.kind),
  ),
  FwTableColumn(
    label: 'Origin',
    flex: 2,
    minWidth: 120,
    sortKey: 'origin',
    cell: (row) => Text(
      row.origin,
      style: context.type.bodyMuted,
      overflow: TextOverflow.ellipsis,
    ),
  ),
  FwTableColumn(
    label: 'Constraint',
    fixed: 120,
    cell: (row) => Text(row.constraint, style: context.type.bodyMuted),
  ),
  FwTableColumn(
    label: 'Resolved',
    fixed: 110,
    sortKey: 'version',
    cell: (row) => Text(row.resolved, style: context.type.bodyMuted),
  ),
  FwTableColumn(
    label: 'Pub',
    fixed: 90,
    sortKey: 'pub',
    cell: (row) => Text('—', style: context.type.bodyMuted),
  ),
  FwTableColumn(
    label: 'Github',
    fixed: 90,
    sortKey: 'github',
    cell: (row) => Text('—', style: context.type.bodyMuted),
  ),
];

@Preview(name: 'Rows', group: 'Table', wrapper: wrapInAppTheme)
Widget tableRows() => const _Table(rows: _rows);

/// The tight case, at the one width that matters.
///
/// 800px is the whole content pane at `shellPaneMinimumSize` — both gutters
/// removed. Below the minimum the shell scales rather than narrowing,
/// so this is not "a small size", it is *the* small size and there is exactly
/// one of them. Seven columns at their declared minimums come to exactly 800,
/// so this entry sits on the knife edge deliberately: anything that widens a
/// column shows up here first.
@Preview(
  name: 'Narrow — the whole pane',
  group: 'Table',
  wrapper: wrapInAppTheme,
)
Widget tableNarrow() => const NarrowPane(child: _Table(rows: _rows));

@Preview(name: 'Loading over rows', group: 'Table', wrapper: wrapInAppTheme)
Widget tableLoading() => const _Table(rows: _rows, loading: true);

/// Loading with nothing yet — the state the dependencies panel actually shows
/// on open, and which renders as a bare header over an empty body because the
/// table has no loading placeholder of its own, only the top progress bar.
@Preview(name: 'Loading, nothing yet', group: 'Table', wrapper: wrapInAppTheme)
Widget tableLoadingEmpty() => const _Table(rows: [], loading: true);

@Preview(name: 'Empty', group: 'Table', wrapper: wrapInAppTheme)
Widget tableEmpty() => const _Table(rows: []);

@Preview(name: 'Failed', group: 'Table', wrapper: wrapInAppTheme)
Widget tableError() => const _Table(rows: [], failed: true);

@Preview(name: 'Rows · dark', group: 'Table', wrapper: wrapInDarkTheme)
Widget tableRowsDark() => const _Table(rows: _rows);

class _Table extends StatefulWidget {
  const _Table({required this.rows, this.loading = false, this.failed = false});

  final List<_Row> rows;
  final bool loading;
  final bool failed;

  @override
  State<_Table> createState() => _TableState();
}

class _TableState extends State<_Table> {
  var _sort = const FwTableSort('name');
  final _widths = <String, double>{};

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: FwTable<_Row>(
          rows: widget.rows,
          columns: _columns(context),
          sort: _sort,
          onSort: (key, ascending) =>
              setState(() => _sort = FwTableSort(key, ascending: ascending)),
          columnWidths: _widths,
          onColumnResize: (key, width) => setState(() => _widths[key] = width),
          onHideColumn: (_) {},
          onRowTap: (_) {},
          loading: widget.loading,
          empty: const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No dependencies',
            message: 'Nothing is declared in this package.',
          ),
          error: widget.failed
              ? const EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not resolve',
                  message: 'pub get failed — see the terminal for its output.',
                )
              : null,
        ),
      ),
    );
  }
}

/// Stands in for the real kind badge, so the row has something with a shape in
/// it rather than seven columns of grey text.
class _Pill extends StatelessWidget {
  const _Pill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    var dev = label == 'Dev';
    var accent = dev ? context.colors.amber : context.colors.grn;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: context.colors.statusFill(accent),
        border: Border.all(color: context.colors.statusBorder(accent)),
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      ),
      child: Text(label, style: context.type.micro.copyWith(color: accent)),
    );
  }
}
