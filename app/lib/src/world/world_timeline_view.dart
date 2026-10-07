import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
// ignore: implementation_imports
import 'package:flutterware/src/world/step_names.dart' show worldActionsOwner;
import 'package:material_ui/material_ui.dart';

import '../ui/panel_header.dart' show panelGutter;
import '../ui/segmented.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'world_person.dart' show PersonDot;
import 'world_timeline.dart';
import 'world_timeline_detail.dart';
import 'world_trace.dart';

/// The open world as a sequence diagram: a column for each person and each
/// part of the system, time running down, a pill for something someone did
/// and an arrow for something that reached someone — in the colour of
/// whoever caused it. Product, System or Wire picks how far into the system
/// the rows go; a column's name shows only what touches it; a row opens in
/// place onto its data, its step lit and the rest faded.
class WorldTimelineView extends StatefulWidget {
  const WorldTimelineView({
    super.key,
    required this.trace,
    required this.people,
    required this.colorOf,
    required this.onFocus,
    this.actions = false,
    this.focus,
    this.sources,
  });

  final WorldTrace trace;

  /// Where an opened row reads what the trace does not keep; null reads
  /// nothing more.
  final TimelineSources? sources;

  /// Everyone in the world, in its order: their columns.
  final List<String> people;

  /// Whether the world has actions of its own, which have a column of
  /// their own before the people's.
  final bool actions;
  final Color Function(String? person) colorOf;

  /// The column shown alone — a person's name, or a part of the system's
  /// id — or null for everything.
  final String? focus;
  final ValueChanged<String?> onFocus;

  @override
  State<WorldTimelineView> createState() => _WorldTimelineViewState();
}

class _WorldTimelineViewState extends State<WorldTimelineView> {
  var _level = TraceLevel.product;
  final _unfolded = <String>{};

  /// The row open, by [_keyOf].
  String? _open;
  final _scroll = ScrollController();

  /// Whether the newest row is in view, and so stays in view as rows
  /// arrive; scrolling up to read stops it.
  var _following = true;

  static const _gutter = 88.0;
  static const _end = FwSpacing.xxl;
  static const _minColumn = 72.0;
  static const _maxColumn = 150.0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      var position = _scroll.position;
      _following = position.pixels >= position.maxScrollExtent - 4;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var timeline = Timeline.of(
      widget.trace.steps(limit: WorldTrace.cap),
      people: widget.people,
      servers: widget.trace.servers,
      level: _level,
      actions: widget.actions,
    );
    var columns = timeline.columns;
    var focus = columns.any((column) => column.id == widget.focus)
        ? widget.focus
        : null;
    var entries = timeline.entries(focus: focus, unfolded: _unfolded);
    // The open row, while it is shown: a level or a focus that hides it
    // closes it.
    var open = [
      for (var entry in entries)
        if (entry case TimelineLine(:var row) when _keyOf(row) == _open) row,
    ].firstOrNull;
    var items = <Object>[
      for (var entry in entries) ...[
        entry,
        if (entry case TimelineLine(:var row) when row == open) _Opened(row),
      ],
    ];
    // What a focused column is joined to by what is shown stays lit.
    var linked = focus == null
        ? null
        : {
            focus,
            for (var entry in entries)
              if (entry case TimelineLine(:var row)) ...[row.from, ...row.to],
          };
    if (_following) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bar(context, timeline, columns, focus),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              var width = constraints.maxWidth;
              var n = max(columns.length, 1);
              var column = ((width - _gutter - _end) / n).clamp(
                _minColumn,
                _maxColumn,
              );
              var layout = _Layout(columns, column, linked);
              var content = max(width, layout.width);
              Widget body = SizedBox(
                width: content,
                height: constraints.maxHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      layout: layout,
                      focus: focus,
                      colorOf: _columnColor,
                      onFocus: (id) => widget.onFocus(id == focus ? null : id),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _Lifelines(layout, context.colors.line2),
                            ),
                          ),
                          if (items.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                _gutter,
                                FwSpacing.xxl,
                                FwSpacing.xxl,
                                0,
                              ),
                              child: Text(
                                _empty(columns, focus),
                                style: context.type.bodyMuted,
                              ),
                            )
                          else
                            ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.only(
                                bottom: FwSpacing.xxl,
                              ),
                              itemCount: items.length,
                              itemBuilder: (context, i) => switch (items[i]) {
                                TimelineGap(:var length) => _GapRow(
                                  length,
                                  dimmed: open != null,
                                ),
                                TimelineLine line => _LineRow(
                                  line: line,
                                  layout: layout,
                                  since: widget.trace.since,
                                  color: widget.colorOf(line.row.step.person),
                                  open: line.row == open,
                                  dimmed:
                                      open != null &&
                                      line.row.step != open.step,
                                  onOpen: () => setState(() {
                                    var key = _keyOf(line.row);
                                    _open = key == _open ? null : key;
                                    // Reading a row is not waiting for the
                                    // next one.
                                    _following = false;
                                  }),
                                  onFold: () => setState(() {
                                    var key = line.fold!;
                                    if (!_unfolded.remove(key)) {
                                      _unfolded.add(key);
                                    }
                                  }),
                                ),
                                _Opened(:var row) => TimelineDetail(
                                  key: ValueKey(_keyOf(row)),
                                  row: row,
                                  trace: widget.trace,
                                  sources: widget.sources,
                                  onClose: () => setState(() => _open = null),
                                ),
                                _ => const SizedBox.shrink(),
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              if (content > width) {
                body = SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: body,
                );
              }
              return body;
            },
          ),
        ),
      ],
    );
  }

  /// What names a row across rebuilds: every build makes new ones.
  static String _keyOf(TimelineRow row) =>
      '${row.step.id}|${row.at.microsecondsSinceEpoch}|${row.from}|'
      '${row.label}';

  Color _columnColor(TimelineColumn column) => switch (column.side) {
    TimelineSide.people => widget.colorOf(column.id),
    TimelineSide.system => context.colors.mut3,
  };

  String _empty(List<TimelineColumn> columns, String? focus) {
    if (focus == null) {
      return 'Nothing yet. Taps in the apps and actions you run appear here, '
          'with what they caused.';
    }
    var name = columns.firstWhere((column) => column.id == focus).name;
    return 'Nothing for $name at the ${_level.name.capitalized} level.';
  }

  /// What the rows mean, what is shown alone, and how far into the system.
  Widget _bar(
    BuildContext context,
    Timeline timeline,
    List<TimelineColumn> columns,
    String? focus,
  ) {
    var colors = context.colors;
    var focused = focus == null
        ? null
        : columns.firstWhere((column) => column.id == focus);
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: panelGutter, right: FwSpacing.lg),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Newest at the bottom. A pill is something someone did; an '
              'arrow is something that reached someone.',
              style: context.type.bodySmall.copyWith(color: colors.mut),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (focused != null) ...[
            const SizedBox(width: FwSpacing.lg),
            Tappable(
              onTap: () => widget.onFocus(null),
              borderRadius: BorderRadius.circular(context.radii.pill),
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(context.radii.pill),
                  border: Border.all(color: colors.accent),
                ),
                child: Text(
                  'Only ${focused.name} · Show all',
                  style: context.type.bodySmall.copyWith(
                    color: colors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: FwSpacing.lg),
          FwSegmented<TraceLevel>(
            segments: [
              for (var level in TraceLevel.values)
                FwSegment(
                  level,
                  level.name.capitalized,
                  count: timeline.counts[level],
                  tooltip: _levelTips[level],
                ),
            ],
            selected: _level,
            onChanged: (level) => setState(() => _level = level),
          ),
        ],
      ),
    );
  }

  static const _levelTips = {
    TraceLevel.product:
        'What people did and what reached others: messages, updates, '
        'records arriving on a phone',
    TraceLevel.system: 'Also server calls and background jobs',
    TraceLevel.wire: 'Also database writes, SQL and sync',
  };
}

/// The detail under an open row.
class _Opened {
  const _Opened(this.row);

  final TimelineRow row;
}

extension on String {
  String get capitalized => '${this[0].toUpperCase()}${substring(1)}';
}

/// Where the columns stand: the width of each, and which are lit.
class _Layout {
  _Layout(this.columns, this.column, this.linked);

  final List<TimelineColumn> columns;

  /// Each column's width.
  final double column;

  /// The columns a focus lights; null when nothing is in focus.
  final Set<String>? linked;

  double get width =>
      _WorldTimelineViewState._gutter +
      column * columns.length +
      _WorldTimelineViewState._end;

  late final _index = {for (var (i, column) in columns.indexed) column.id: i};

  /// The middle of [id]'s column.
  double centre(String id) =>
      _WorldTimelineViewState._gutter + column * (_index[id] ?? 0) + column / 2;

  /// Where the system's columns start.
  double get system =>
      _WorldTimelineViewState._gutter +
      column *
          columns.where((column) => column.side == TimelineSide.people).length;

  double opacity(String id) => linked == null || linked!.contains(id) ? 1 : 0.3;
}

/// The columns' names, under what side they stand on: a name shows only
/// what touches it.
class _Header extends StatelessWidget {
  const _Header({
    required this.layout,
    required this.focus,
    required this.colorOf,
    required this.onFocus,
  });

  final _Layout layout;
  final String? focus;
  final Color Function(TimelineColumn column) colorOf;
  final ValueChanged<String> onFocus;

  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var label = context.type.sectionLabel.copyWith(color: colors.mut);
    var people = layout.columns.any(
      (column) => column.side == TimelineSide.people,
    );
    var system = layout.columns.any(
      (column) => column.side == TimelineSide.system,
    );
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Stack(
        children: [
          if (people)
            Positioned(
              left: _WorldTimelineViewState._gutter + FwSpacing.sm,
              top: FwSpacing.md,
              child: Text('PEOPLE', style: label),
            ),
          if (system) ...[
            Positioned(
              left: layout.system + FwSpacing.sm,
              top: FwSpacing.md,
              child: Text('THE SYSTEM', style: label),
            ),
            if (people)
              Positioned(
                left: layout.system,
                top: FwSpacing.sm,
                bottom: FwSpacing.sm,
                child: Container(width: 1, color: colors.line),
              ),
          ],
          for (var column in layout.columns)
            Positioned(
              left: layout.centre(column.id) - layout.column / 2 + FwSpacing.xs,
              width: layout.column - 2 * FwSpacing.xs,
              top: 28,
              height: 28,
              child: Opacity(
                opacity: layout.opacity(column.id),
                child: Tooltip(
                  message: column.id == focus
                      ? 'Show all'
                      : 'Show only ${column.name}',
                  child: Tappable(
                    onTap: () => onFocus(column.id),
                    borderRadius: BorderRadius.circular(
                      context.radii.radiusSmall,
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: FwSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: column.id == focus
                            ? colors.accentSoft
                            : colors.bg,
                        borderRadius: BorderRadius.circular(
                          context.radii.radiusSmall,
                        ),
                        border: Border.all(
                          color: column.id == focus
                              ? colors.accent
                              : colors.line,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PersonDot(colorOf(column)),
                          const SizedBox(width: FwSpacing.sm),
                          Flexible(
                            child: Text(
                              column.name,
                              style: context.type.bodySmall.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A dashed line down the middle of every column.
class _Lifelines extends CustomPainter {
  _Lifelines(this.layout, this.color);

  final _Layout layout;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (var column in layout.columns) {
      var paint = Paint()
        ..color = color.withValues(alpha: color.a * layout.opacity(column.id))
        ..strokeWidth = 1;
      var x = layout.centre(column.id).roundToDouble() + 0.5;
      for (var y = 0.0; y < size.height; y += 7) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Lifelines old) =>
      old.layout.column != layout.column ||
      old.layout.columns != layout.columns ||
      old.layout.linked != layout.linked ||
      old.color != color;
}

/// A pause: *12.4 s later*.
class _GapRow extends StatelessWidget {
  const _GapRow(this.length, {this.dimmed = false});

  final Duration length;

  /// Whether another step is open.
  final bool dimmed;

  static const height = 24.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget gap = Padding(
      padding: const EdgeInsets.only(left: FwSpacing.lg),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(context.radii.pill),
            border: Border.all(color: colors.line),
          ),
          child: Text(
            '${lengthOf(length)} later',
            style: context.type.mono.copyWith(
              fontSize: context.type.micro.fontSize,
              color: colors.mut,
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      height: height,
      child: dimmed ? Opacity(opacity: 0.35, child: gap) : gap,
    );
  }
}

/// One row: a pill on its column, or an arrow from one column to the ones
/// it reached.
class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.layout,
    required this.since,
    required this.color,
    required this.onFold,
    required this.onOpen,
    this.open = false,
    this.dimmed = false,
  });

  final TimelineLine line;
  final _Layout layout;
  final DateTime since;

  /// Whoever caused it.
  final Color color;
  final VoidCallback onFold;
  final VoidCallback onOpen;

  /// Whether its detail is open under it.
  final bool open;

  /// Whether a row of another step is open: this one steps back.
  final bool dimmed;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var row = line.row;
    var clock = line.folded
        ? '${clockOf(row.at, since)}–${clockOf(line.until, since)}'
        : clockOf(row.at, since);
    var label = line.folded
        ? '${row.label} … ${line.alike.length - 1} more like it'
        : row.label;
    var style = context.type.bodySmall.copyWith(
      color: switch (row.level) {
        TraceLevel.product => colors.ink,
        TraceLevel.system => colors.ink2,
        TraceLevel.wire => colors.mut,
      },
      fontWeight: row.level == TraceLevel.product ? FontWeight.w600 : null,
    );
    var from = layout.centre(row.from);
    var room = layout.width - from;
    var ground = open ? colors.statusFill(colors.accent) : colors.bg;
    Widget drawn = Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: FwSpacing.xs,
          top: 12,
          width: _WorldTimelineViewState._gutter - FwSpacing.md - FwSpacing.xs,
          child: Text(
            clock,
            textAlign: TextAlign.right,
            maxLines: 1,
            style: context.type.mono.copyWith(
              fontSize: context.type.micro.fontSize,
              color: colors.mut2,
            ),
          ),
        ),
        if (row.to.isEmpty)
          Positioned(
            left: from - 14,
            top: 9,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: max(80, room)),
              child: _pill(context, row, label, style),
            ),
          )
        else ...[
          Positioned.fill(
            child: CustomPaint(
              painter: _Arrow(
                from: from,
                to: [for (var id in row.to) layout.centre(id)],
                color: color,
              ),
            ),
          ),
          _arrowLabel(context, row, label, style, ground),
        ],
      ],
    );
    if (dimmed) drawn = Opacity(opacity: 0.28, child: drawn);
    return Tappable(
      onTap: onOpen,
      child: Container(height: height, color: ground, child: drawn),
    );
  }

  /// Above the arrow, in its middle, over the lifelines it crosses.
  Widget _arrowLabel(
    BuildContext context,
    TimelineRow row,
    String label,
    TextStyle style,
    Color ground,
  ) {
    var from = layout.centre(row.from);
    var far = row.to
        .map(layout.centre)
        .reduce((a, b) => (a - from).abs() >= (b - from).abs() ? a : b);
    var middle = (from + far) / 2;
    const most = 420.0;
    return Positioned(
      left: middle - most / 2,
      width: most,
      top: 3,
      child: Center(
        child: Container(
          color: ground,
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
          child: _words(context, label, style),
        ),
      ),
    );
  }

  Widget _pill(
    BuildContext context,
    TimelineRow row,
    String label,
    TextStyle style,
  ) {
    var colors = context.colors;
    var (fill, edge, words) = switch (row) {
      // Something a person did: in their colour.
      TimelineRow(isStep: true, step: var step)
          when step.person != worldActionsOwner =>
        (
          colors.statusFill(color),
          colors.statusBorder(color),
          style.copyWith(color: colors.ink),
        ),
      TimelineRow(isStep: true) => (colors.panel2, colors.line, style),
      _ => (colors.panel, colors.line, style),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(context.radii.pill),
        border: Border.all(color: edge),
      ),
      child: _words(context, label, words),
    );
  }

  /// [label], and the count of its run when it folds one.
  Widget _words(BuildContext context, String label, TextStyle style) {
    var text = Text(
      label,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (line.fold == null) return text;
    var colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: text),
        const SizedBox(width: FwSpacing.sm),
        Tooltip(
          message: line.folded
              ? 'Show all ${line.alike.length}'
              : 'Collapse into one row',
          child: Tappable(
            onTap: onFold,
            borderRadius: BorderRadius.circular(context.radii.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.sm),
              decoration: BoxDecoration(
                color: colors.panel2,
                borderRadius: BorderRadius.circular(context.radii.pill),
                border: Border.all(color: colors.line),
              ),
              child: Text(
                line.folded ? '×${line.alike.length}' : 'collapse',
                style: context.type.micro.copyWith(
                  color: colors.ink2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// An arrow from [from] to the farthest of [to], with a dot on each of the
/// others it reached on the way.
class _Arrow extends CustomPainter {
  _Arrow({required this.from, required this.to, required this.color});

  final double from;
  final List<double> to;
  final Color color;

  static const _y = 27.0;

  @override
  void paint(Canvas canvas, Size size) {
    var far = to.reduce((a, b) => (a - from).abs() >= (b - from).abs() ? a : b);
    var right = far > from;
    var start = from + (right ? 5 : -5);
    var tip = far + (right ? -5 : 5);
    var paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(Offset(start, _y), Offset(tip, _y), paint);
    var back = right ? -9.0 : 9.0;
    canvas.drawPath(
      Path()
        ..moveTo(tip, _y)
        ..lineTo(tip + back, _y - 5)
        ..lineTo(tip + back, _y + 5)
        ..close(),
      Paint()..color = color,
    );
    for (var x in to) {
      if (x != far) canvas.drawCircle(Offset(x, _y), 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_Arrow old) =>
      old.from != from || old.color != color || !listEquals(old.to, to);
}
