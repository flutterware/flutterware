import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';

import 'design/design.dart';
import 'empty_state.dart';
import 'menu.dart';
import 'popover.dart';
import 'tappable.dart';

/// A column in a [FwTable].
///
/// Two kinds, distinguished by [sortKey]: an *accessor* column has a sort key
/// (it maps to a data field, so it can be sorted), a *display* column does not
/// (actions, derived widgets). The view derives sortability from this rather
/// than a separate flag.
///
/// Width is either [fixed] pixels or a [flex] share of the space left after the
/// fixed columns. Flex columns expand to fill the viewport; when the columns
/// outgrow it they clamp to [minWidth] and the table scrolls horizontally.
///
/// [pinned] columns freeze during horizontal scroll and must be the leading
/// columns of the list.
class FwTableColumn<T> {
  /// Stable identifier, independent of the [label] — the key a [ColumnLayout]
  /// persists. Defaults to [label].
  final String? id;
  final String label;
  final Widget Function(T row) cell;
  final double? fixed;
  final int flex;
  final double minWidth;
  final Alignment align;

  /// What this column sorts by, or null for a display column. An opaque string
  /// the caller interprets — the table only reports it back through
  /// [FwTable.onSort].
  final String? sortKey;

  final bool pinned;

  /// Whether the user can drag this column's trailing edge to resize it. Only
  /// honoured when the table has an [FwTable.onColumnResize] callback.
  final bool resizable;

  /// Whether the header menu may offer "Hide column" for this column. Off for
  /// an anchor/identity column that should always stay visible. Only relevant
  /// when the table has an [FwTable.onHideColumn] callback.
  final bool hideable;

  const FwTableColumn({
    this.id,
    required this.label,
    required this.cell,
    this.fixed,
    this.flex = 1,
    this.minWidth = 80,
    this.align = Alignment.centerLeft,
    this.sortKey,
    this.pinned = false,
    this.resizable = true,
    this.hideable = true,
  });

  /// The persisted key — explicit [id] or the [label] as a fallback.
  String get key => id ?? label;

  bool get sortable => sortKey != null;
}

/// The active sort: which column [key] and direction. The view is controlled —
/// it renders this and reports changes through [FwTable.onSort]; it never
/// reorders [FwTable.rows] itself.
class FwTableSort {
  final String key;
  final bool ascending;
  const FwTableSort(this.key, {this.ascending = true});
}

/// A presentational, virtualized data table built on `TableView`
/// (two_dimensional_scrollables): pinned header, optional pinned leading
/// columns, fixed + flex column widths, sortable headers, row hover/tap, zebra.
///
/// Pure View: plain [rows] in, intent out via callbacks. No fetching, no global
/// reads. Row height is fixed ([rowHeight]) — cells truncate rather than wrap.
///
/// Why not `DataTable`. Material's builds every row eagerly and has no
/// pinned header, so showing 170 dependencies meant a fixed-height `SizedBox`
/// wrapping a horizontal `CustomScrollView` and hoping. This virtualizes.
///
/// Ported from `cms/packages/admin_ui/lib/src/collection/ui/collection_table.dart`
/// and adapted: the original's inline cell editing and row selection are gone,
/// since nothing in flutterware writes through a table. Re-adding selection is
/// a synthetic leading column and a select-all — small, and in git history.
class FwTable<T> extends StatefulWidget {
  final List<T> rows;
  final List<FwTableColumn<T>> columns;
  final FwTableSort? sort;
  final void Function(String key, bool ascending)? onSort;
  final void Function(T row)? onRowTap;

  /// Explicit per-column pixel widths, keyed by [FwTableColumn.key]. A key
  /// present here overrides the column's declared sizing; keys absent fall back
  /// to it. Pair with [onColumnResize] to let the user drag column edges.
  final Map<String, double>? columnWidths;

  /// Fires while the user drags a resizable column's trailing edge, with the
  /// column key and its new (clamped) width. Enables resize handles.
  final void Function(String key, double width)? onColumnResize;

  /// Hides the column with this key. Enables a "Hide column" entry in each
  /// hideable column's header menu. The parent applies it (typically
  /// `ColumnLayout.withVisible(key, false)`).
  final void Function(String key)? onHideColumn;

  /// Dims the body and shows a top progress bar; prior [rows] stay visible.
  final bool loading;

  /// Shown in the body (under the header) when [rows] is empty and not
  /// [loading]/[error].
  final Widget? empty;

  /// Shown in the body (under the header) when set, taking precedence over
  /// [loading] and [empty].
  final Widget? error;

  final double rowHeight;
  final double headerHeight;

  const FwTable({
    super.key,
    required this.rows,
    required this.columns,
    this.sort,
    this.onSort,
    this.onRowTap,
    this.columnWidths,
    this.onColumnResize,
    this.onHideColumn,
    this.loading = false,
    this.empty,
    this.error,
    this.rowHeight = 44,
    this.headerHeight = 40,
  });

  @override
  State<FwTable<T>> createState() => _FwTableState<T>();
}

class _FwTableState<T> extends State<FwTable<T>> {
  int? _hovered;

  /// Loading visuals (dim + top bar) are gated behind a short delay so a
  /// sub-perceptual load never flashes them.
  bool _showLoading = false;
  Timer? _loadingTimer;

  void _syncLoading() {
    if (widget.loading) {
      _loadingTimer ??= Timer(const Duration(milliseconds: 150), () {
        _loadingTimer = null;
        if (mounted) setState(() => _showLoading = true);
      });
    } else {
      _loadingTimer?.cancel();
      _loadingTimer = null;
      _showLoading = false;
    }
  }

  /// Live-drag width layer, keyed by column key. Sits over
  /// [FwTable.columnWidths] so a resize is responsive without requiring the
  /// parent to rebuild, and persists across unrelated rebuilds when the parent
  /// is uncontrolled.
  final Map<String, double> _resized = {};

  bool get _resizable => widget.onColumnResize != null;

  double? _overrideWidth(FwTableColumn<T> column) =>
      _resized[column.key] ?? widget.columnWidths?[column.key];

  @override
  void initState() {
    super.initState();
    _syncLoading();
  }

  @override
  void didUpdateWidget(covariant FwTable<T> old) {
    super.didUpdateWidget(old);
    if (widget.loading != old.loading) _syncLoading();
  }

  @override
  void dispose() {
    _loadingTimer?.cancel();
    super.dispose();
  }

  /// A column is sized either by an explicit width (a resize override or its
  /// declared [FwTableColumn.fixed]) or by flex. An override turns a flex
  /// column into a pinned-width one for layout purposes.
  double? _explicitWidth(FwTableColumn<T> column) =>
      _overrideWidth(column) ?? column.fixed;

  List<double> _widths(double available) {
    var fixedTotal = widget.columns.fold(
      0.0,
      (total, column) => total + (_explicitWidth(column) ?? 0),
    );
    var flexTotal = widget.columns
        .where((column) => _explicitWidth(column) == null)
        .fold(0, (total, column) => total + column.flex);
    var remaining = available - fixedTotal;
    return [
      for (var column in widget.columns)
        if (_explicitWidth(column) case var width?)
          width
        else
          (flexTotal == 0
                  ? column.minWidth
                  : remaining * column.flex / flexTotal)
              .clamp(column.minWidth, double.infinity),
    ];
  }

  /// Width of the in-progress column drag, in pixels. Tracked absolutely so a
  /// drag past [FwTableColumn.minWidth] clamps without losing the pointer
  /// offset.
  double _dragWidth = 0;

  void _dragColumnTo(int index, double target) {
    var column = widget.columns[index];
    var next = target.clamp(column.minWidth, double.infinity);
    _dragWidth = next;
    setState(() => _resized[column.key] = next);
    widget.onColumnResize!(column.key, next);
  }

  void _tapHeader(FwTableColumn<T> column) {
    if (!column.sortable || widget.onSort == null) return;
    var current = widget.sort;
    var ascending = (current != null && current.key == column.sortKey)
        ? !current.ascending
        : true;
    widget.onSort!(column.sortKey!, ascending);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var widths = _widths(constraints.maxWidth);
        var hasRows = widget.rows.isNotEmpty;

        Widget? overlayBody;
        if (widget.error != null) {
          overlayBody = widget.error!;
        } else if (!hasRows && !widget.loading) {
          overlayBody = widget.empty ?? const _DefaultEmpty();
        }

        var content = overlayBody != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _headerStrip(context, widths),
                  Expanded(child: overlayBody),
                ],
              )
            : _table(context, widths);

        return Stack(
          children: [
            Positioned.fill(child: content),
            if (_showLoading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopProgressBar(),
              ),
          ],
        );
      },
    );
  }

  Widget _headerStrip(BuildContext context, List<double> widths) {
    return Container(
      height: widget.headerHeight,
      decoration: BoxDecoration(
        color: context.colors.panel2,
        border: Border(bottom: BorderSide(color: context.colors.line)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < widget.columns.length; i++)
            SizedBox(
              width: widths[i],
              child: _headerCell(context, i, widths[i]),
            ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context, List<double> widths) {
    var rows = widget.rows;
    var pinned = widget.columns.where((column) => column.pinned).length;
    return Opacity(
      opacity: _showLoading ? 0.55 : 1,
      child: TableView.builder(
        pinnedRowCount: 1,
        pinnedColumnCount: pinned,
        columnCount: widget.columns.length,
        rowCount: rows.length + 1,
        columnBuilder: (i) =>
            TableSpan(extent: FixedTableSpanExtent(widths[i])),
        rowBuilder: (i) {
          if (i == 0) {
            return TableSpan(
              extent: FixedTableSpanExtent(widget.headerHeight),
              backgroundDecoration: TableSpanDecoration(
                color: context.colors.panel2,
                border: TableSpanBorder(
                  trailing: BorderSide(color: context.colors.line),
                ),
              ),
            );
          }
          var row = i - 1;
          var hovered = _hovered == row;
          var striped = row.isOdd;
          return TableSpan(
            extent: FixedTableSpanExtent(widget.rowHeight),
            // Guarded: the mouse tracker can deliver a hover callback in the
            // frame after this table is disposed (e.g. a row tap navigates
            // away), which would setState on a defunct State.
            onEnter: (_) {
              if (mounted) setState(() => _hovered = row);
            },
            onExit: (_) {
              if (mounted && _hovered == row) setState(() => _hovered = null);
            },
            backgroundDecoration: TableSpanDecoration(
              color: hovered
                  ? context.colors.line2
                  : (striped ? context.colors.accentSoft2 : context.colors.bg),
              border: TableSpanBorder(
                trailing: BorderSide(color: context.colors.line2),
              ),
            ),
          );
        },
        cellBuilder: (context, vicinity) {
          if (vicinity.row == 0) {
            return TableViewCell(
              child: _headerCell(
                context,
                vicinity.column,
                widths[vicinity.column],
              ),
            );
          }
          var column = widget.columns[vicinity.column];
          var row = rows[vicinity.row - 1];

          var cell = Padding(
            padding: _cellPad,
            child: Align(alignment: column.align, child: column.cell(row)),
          );

          if (widget.onRowTap == null) return TableViewCell(child: cell);
          // Wired per cell rather than as one row-wide recognizer, because a
          // TableView has no row widget to attach it to. Which is also why it
          // paints nothing and takes no focus: the row above already tints the
          // whole span, and a cell that washed or ringed itself would say the
          // cell is the target when the row is.
          return TableViewCell(
            child: Tappable(
              onTap: () => widget.onRowTap!(row),
              feedback: TapFeedback.none,
              focusable: false,
              child: cell,
            ),
          );
        },
      ),
    );
  }

  Widget _headerCell(BuildContext context, int index, double width) {
    var column = widget.columns[index];
    var canSort = column.sortable && widget.onSort != null;
    Widget header = _HeaderCell(
      label: column.label,
      align: column.align,
      sortable: column.sortable,
      active: column.sortable && widget.sort?.key == column.sortKey,
      ascending: widget.sort?.ascending ?? true,
      onTapSort: canSort ? () => _tapHeader(column) : null,
      onSort: canSort
          ? (ascending) => widget.onSort!(column.sortKey!, ascending)
          : null,
      onHide: column.hideable && widget.onHideColumn != null
          ? () => widget.onHideColumn!(column.key)
          : null,
    );
    if (!_resizable || !column.resizable) return header;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: header),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _handleHitWidth,
          child: _ResizeHandle(
            onStart: () => _dragWidth = width,
            onUpdate: (dx) => _dragColumnTo(index, _dragWidth + dx),
          ),
        ),
      ],
    );
  }
}

const _cellPad = EdgeInsets.symmetric(horizontal: FwSpacing.lg);
const _handleHitWidth = 9.0;

/// A header cell: the (optionally sort-toggling) label, plus a discreet ⋮ that
/// appears on hover and opens a per-column menu (sort, hide). The trigger slot
/// is always reserved so the label never reflows when the ⋮ fades in.
class _HeaderCell extends StatefulWidget {
  final String label;
  final Alignment align;
  final bool sortable;
  final bool active;
  final bool ascending;

  /// Quick sort toggle on the label itself.
  final VoidCallback? onTapSort;

  /// Explicit sort direction from the menu.
  final void Function(bool ascending)? onSort;
  final VoidCallback? onHide;

  const _HeaderCell({
    required this.label,
    required this.align,
    required this.sortable,
    required this.active,
    required this.ascending,
    this.onTapSort,
    this.onSort,
    this.onHide,
  });

  @override
  State<_HeaderCell> createState() => _HeaderCellState();
}

class _HeaderCellState extends State<_HeaderCell> {
  bool _hover = false;

  bool get _hasMenu => widget.onSort != null || widget.onHide != null;

  @override
  Widget build(BuildContext context) {
    var active = widget.active;
    var labelRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.type.micro.copyWith(
              color: active ? context.colors.ink2 : context.colors.mut,
            ),
          ),
        ),
        if (widget.sortable) ...[
          const Gap(FwSpacing.xxs),
          Icon(
            active
                ? (widget.ascending ? Icons.arrow_upward : Icons.arrow_downward)
                : Icons.unfold_more,
            size: FwIconSize.sm,
            color: active ? context.colors.accent : context.colors.mut3,
          ),
        ],
      ],
    );

    var labelArea = widget.onTapSort == null
        ? labelRow
        : Tappable(onTap: widget.onTapSort, child: labelRow);

    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: Padding(
        padding: _cellPad,
        child: Row(
          children: [
            Expanded(
              child: Align(alignment: widget.align, child: labelArea),
            ),
            // Reserve the trigger slot even when hidden so the label never
            // shifts.
            if (_hasMenu) SizedBox(width: 18, child: _trigger(context)),
          ],
        ),
      ),
    );
  }

  Widget _trigger(BuildContext context) {
    return Menu(
      side: PopoverSide.bottom,
      align: PopoverAlign.end,
      minWidth: 184,
      entries: [
        if (widget.onSort != null)
          MenuItem(
            'Sort ascending',
            icon: Icons.arrow_upward,
            onSelected: () => widget.onSort!(true),
          ),
        if (widget.onSort != null)
          MenuItem(
            'Sort descending',
            icon: Icons.arrow_downward,
            onSelected: () => widget.onSort!(false),
          ),
        if (widget.onSort != null && widget.onHide != null) const MenuDivider(),
        if (widget.onHide != null)
          MenuItem(
            'Hide column',
            icon: Icons.visibility_off_outlined,
            onSelected: widget.onHide,
          ),
      ],
      builder: (context, controller) {
        var visible = _hover || controller.isOpen;
        return IgnorePointer(
          ignoring: !visible,
          child: Opacity(
            opacity: visible ? 1 : 0,
            child: Tooltip(
              message: 'Column options',
              child: Tappable(
                onTap: controller.toggle,
                child: Icon(
                  Icons.more_vert,
                  size: FwIconSize.md,
                  color: context.colors.mut,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The draggable trailing edge of a resizable header cell: a wide invisible hit
/// target with a hairline that brightens on hover/drag.
class _ResizeHandle extends StatefulWidget {
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  const _ResizeHandle({required this.onStart, required this.onUpdate});

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => widget.onStart(),
        onHorizontalDragUpdate: (d) => widget.onUpdate(d.delta.dx),
        child: Center(
          child: Container(
            width: 2,
            color: _active ? context.colors.accent : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

class _TopProgressBar extends StatelessWidget {
  const _TopProgressBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: Colors.transparent,
        color: context.colors.accent,
      ),
    );
  }
}

class _DefaultEmpty extends StatelessWidget {
  const _DefaultEmpty();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(title: 'Nothing here yet');
  }
}
