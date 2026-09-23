/// A [FeedDescriptor] rendered: rows on the left, the selected event on the
/// right.
///
/// Master/detail, following the server panel's Requests tab — which is the
/// announced reference (`2026-07-31-run-cockpit-panel-design.md`) — but written
/// against the descriptor rather than extracted from it. Extraction waits for
/// a second real consumer to prove the generalisation against.
library;

import 'package:material_ui/material_ui.dart';

import '../../server/attach_session.dart';
import '../descriptor.dart';
import 'style.dart';

class FeedView extends StatelessWidget {
  const FeedView({
    super.key,
    required this.feed,
    required this.events,
    this.selected,
    this.onSelect,
    this.onItemAction,
  });

  final FeedDescriptor feed;

  /// Oldest first, as the ring replays them. Drawn newest first.
  final List<InspectorEvent> events;

  final int? selected;
  final ValueChanged<int>? onSelect;

  /// `(actionId, eventId)` — the event's id travels as `event`, which is what
  /// lets the handler reach the details the ring is holding.
  final void Function(String actionId, int eventId)? onItemAction;

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    if (events.isEmpty) {
      return _Empty(
        label: 'Nothing on ${feed.label} yet',
        hint: feed.description,
      );
    }
    var chosen = events.where((e) => e.id == selected).firstOrNull;
    var rows = events.reversed.toList();
    return PanelSurface(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The same breakpoint the cockpit's own master/detail panes use: below
          // it there is no room for two columns, so the detail replaces the list.
          var wide = constraints.maxWidth >= 640;
          var list = _Rows(
            feed: feed,
            rows: rows,
            selected: selected,
            onSelect: onSelect,
            style: style,
          );
          if (chosen == null) return list;
          var detail = _Detail(
            feed: feed,
            event: chosen,
            onItemAction: onItemAction,
            onClose: () => onSelect?.call(-1),
            style: style,
            showClose: !wide,
          );
          if (!wide) return detail;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              Container(width: 1, color: style.line),
              SizedBox(width: 340, child: detail),
            ],
          );
        },
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows({
    required this.feed,
    required this.rows,
    required this.selected,
    required this.onSelect,
    required this.style,
  });

  final FeedDescriptor feed;
  final List<InspectorEvent> rows;
  final int? selected;
  final ValueChanged<int>? onSelect;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    var longest = 0.0;
    if (feed.durationKey != null) {
      for (var event in rows) {
        var value = event.payload[feed.durationKey];
        if (value is num && value > longest) longest = value.toDouble();
      }
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => _Row(
        feed: feed,
        event: rows[index],
        selected: rows[index].id == selected,
        onTap: onSelect == null ? null : () => onSelect!(rows[index].id),
        longest: longest,
        style: style,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.feed,
    required this.event,
    required this.selected,
    required this.onTap,
    required this.longest,
    required this.style,
  });

  final FeedDescriptor feed;
  final InspectorEvent event;
  final bool selected;
  final VoidCallback? onTap;
  final double longest;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    // No declared fields is a real answer, not a broken feed: show the payload
    // as it came rather than an empty row.
    var fields = feed.fields.isNotEmpty
        ? feed.fields
        : [for (var key in event.payload.keys) FieldDescriptor(key, key)];
    var duration = event.payload[feed.durationKey];
    // Exactly one cell flexes, and something must: a feed that declared no
    // primary — every synthesised field is one — would otherwise lay a 90
    // character SQL string out at its natural width and overflow the row. The
    // first field identifies the row when nobody said which one does.
    var primary = fields.indexWhere((f) => f.primary);
    if (primary < 0) primary = 0;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PanelStyle.lg,
            vertical: PanelStyle.md,
          ),
          decoration: BoxDecoration(
            color: selected ? style.accent.withValues(alpha: 0.10) : null,
            border: Border(bottom: BorderSide(color: style.line)),
          ),
          child: Row(
            children: [
              for (var (index, field) in fields.indexed)
                if (index == primary)
                  Expanded(
                    child: Text(
                      formatFieldValue(field, event.payload[field.key]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.bodyStrong,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: PanelStyle.lg),
                    child: ConstrainedBox(
                      // Secondary values are read at a glance, not studied —
                      // the detail pane is where the whole value lives.
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        formatFieldValue(field, event.payload[field.key]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.caption,
                      ),
                    ),
                  ),
              if (duration is num && longest > 0) ...[
                const PanelGap(PanelStyle.lg),
                _DurationBar(
                  fraction: duration / longest,
                  label: formatDuration(duration),
                  style: style,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The waterfall, one row at a time — a bar proportional to the slowest event
/// in view, which is what makes an outlier findable by eye.
class _DurationBar extends StatelessWidget {
  const _DurationBar({
    required this.fraction,
    required this.label,
    required this.style,
  });

  final double fraction;
  final String label;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: style.line,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.02, 1),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: style.accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const PanelGap(PanelStyle.sm),
          SizedBox(
            // Wide enough for `1.18s` and `412ms` at every font the hosts use;
            // `softWrap: false` because a label that wrapped made every row
            // with a slow request taller than its neighbours — visible in the
            // preview shots before this line existed.
            width: 64,
            child: Text(
              label,
              style: style.micro,
              textAlign: TextAlign.right,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.feed,
    required this.event,
    required this.onItemAction,
    required this.onClose,
    required this.style,
    required this.showClose,
  });

  final FeedDescriptor feed;
  final InspectorEvent event;
  final void Function(String actionId, int eventId)? onItemAction;
  final VoidCallback onClose;
  final PanelStyle style;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: style.raised,
      child: ListView(
        padding: const EdgeInsets.all(PanelStyle.lg),
        children: [
          Row(
            children: [
              Expanded(child: Text('Event ${event.id}', style: style.heading)),
              if (showClose)
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          Text(
            '${event.time.toIso8601String()}'
            '${event.rid == null ? '' : ' · ${event.rid}'}',
            style: style.caption,
          ),
          const PanelGap(PanelStyle.lg),
          for (var entry in event.payload.entries)
            _DetailRow(
              label: _labelFor(entry.key),
              value: formatFieldValue(_fieldFor(entry.key), entry.value),
              style: style,
            ),
          if (feed.itemActions.isNotEmpty) ...[
            const PanelGap(PanelStyle.xl),
            Wrap(
              spacing: PanelStyle.md,
              runSpacing: PanelStyle.md,
              children: [
                for (var action in feed.itemActions)
                  OutlinedButton(
                    onPressed: onItemAction == null
                        ? null
                        : () => onItemAction!(action.id, event.id),
                    child: Text(action.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  FieldDescriptor _fieldFor(String key) =>
      feed.fields.where((f) => f.key == key).firstOrNull ??
      FieldDescriptor(key, key);

  String _labelFor(String key) => _fieldFor(key).label;
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.style,
  });

  final String label;
  final String value;
  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PanelStyle.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: style.micro),
          const PanelGap(PanelStyle.xxs),
          SelectableText(value, style: style.mono),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.label, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    var style = PanelStyle.of(context);
    return PanelSurface(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: style.body.copyWith(color: style.muted)),
            if (hint != null) ...[
              const PanelGap(PanelStyle.xs),
              Text(hint!, style: style.caption),
            ],
          ],
        ),
      ),
    );
  }
}

/// One payload value as text, according to its declared [FieldKind].
///
/// A kind a renderer does not know falls back to text rather than refusing the
/// row — the vocabulary is allowed to grow without every host being updated
/// first.
String formatFieldValue(FieldDescriptor field, Object? value) {
  if (value == null) return '—';
  switch (field.kind) {
    case FieldKind.duration:
      return value is num ? formatDuration(value) : '$value';
    case FieldKind.bytes:
      return value is num ? formatBytes(value) : '$value';
    case FieldKind.timestamp:
      if (value is! num) return '$value';
      return DateTime.fromMillisecondsSinceEpoch(value.toInt())
          .toIso8601String();
    case FieldKind.json:
    case FieldKind.number:
    case FieldKind.text:
      return '$value';
  }
}

String formatDuration(num ms) {
  if (ms < 1) return '${(ms * 1000).round()}µs';
  if (ms < 1000) return '${ms.toStringAsFixed(ms < 10 ? 1 : 0)}ms';
  return '${(ms / 1000).toStringAsFixed(2)}s';
}

String formatBytes(num bytes) {
  const units = ['B', 'kB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
