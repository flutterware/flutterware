import 'package:material_ui/material_ui.dart';
import 'package:flutterware/app_events.dart';

import '../ui/count_badge.dart';
import '../ui/json_view.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import '../ui/empty_state.dart';

/// The Events tab: what the app did on the way *into* this step.
///
/// The step's incoming edge and the step are the same object — a step has
/// exactly one parent — so the events key on the step and the header names the
/// transition. Rows are in the order they happened, across every lane at once:
/// a platform channel message, a `print` and a fake's reported request
/// interleave the way they occurred, which is the reading the tab exists for.
///
/// `system` (the `flutter/…` channels) is captured and hidden: one `enterText`
/// puts two dozen `flutter/textinput` messages on the transition, and on an
/// ordinary step they would be the only thing visible.
class ScenarioEventsView extends StatefulWidget {
  const ScenarioEventsView({
    super.key,
    required this.events,
    required this.transition,
    required this.dropped,
    required this.placeholder,
  });

  /// The transition's events, decoded from the step's `.events.json`.
  final List<Map<String, Object?>> events;

  /// What the verb was — `tap "Pay"` — or null on a step that predates the
  /// capture, or one taken at a failure.
  final String? transition;

  /// How many events the caps threw away. Shown, never swallowed.
  final int dropped;

  final String placeholder;

  @override
  State<ScenarioEventsView> createState() => _ScenarioEventsViewState();
}

class _ScenarioEventsViewState extends State<ScenarioEventsView> {
  /// Channels the reader has turned off. Seeded with `system` rather than
  /// filtered at the source, so the chip that reveals it carries its count and
  /// one click brings it back.
  var _hidden = {AppChannel.system};

  /// Expanded rows, by position — position rather than identity because two
  /// identical log lines are two rows.
  final _expanded = <int>{};

  @override
  void didUpdateWidget(ScenarioEventsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.events, widget.events)) _expanded.clear();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (widget.events.isEmpty) {
      return Container(
        color: colors.panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(FwSpacing.lg),
        child: Text(
          widget.placeholder,
          textAlign: TextAlign.center,
          style: context.type.caption.copyWith(color: colors.mut),
        ),
      );
    }

    var counts = <String, int>{};
    for (var event in widget.events) {
      var channel = '${event['channel'] ?? AppChannel.log}';
      counts[channel] = (counts[channel] ?? 0) + 1;
    }
    var channels = counts.keys.toList()..sort();
    var rows = [
      for (var (position, event) in widget.events.indexed)
        if (!_hidden.contains('${event['channel'] ?? AppChannel.log}'))
          (position, event),
    ];

    return Container(
      color: colors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.transition == null
                        ? 'ON THE WAY HERE'
                        : 'ON THE WAY HERE — ${widget.transition!.toUpperCase()}',
                    style: context.type.sectionLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                for (var channel in channels)
                  Padding(
                    padding: const EdgeInsets.only(left: FwSpacing.xs),
                    child: _ChannelChip(
                      channel: channel,
                      count: counts[channel]!,
                      on: !_hidden.contains(channel),
                      onTap: () => setState(() {
                        _hidden = {
                          for (var name in _hidden)
                            if (name != channel) name,
                          if (!_hidden.contains(channel)) channel,
                        };
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const EmptyState(
                    icon: Icons.filter_alt_off_outlined,
                    title: 'Every channel is filtered out',
                    message: 'Turn one back on above.',
                  )
                : ListView.builder(
                    primary: false,
                    itemCount: rows.length + (widget.dropped > 0 ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == rows.length) {
                        return Padding(
                          padding: const EdgeInsets.all(FwSpacing.lg),
                          child: Text(
                            '${widget.dropped} more events were dropped: this '
                            'transition hit the capture cap.',
                            style: context.type.caption.copyWith(
                              color: colors.amber,
                            ),
                          ),
                        );
                      }
                      var (position, event) = rows[index];
                      return _EventRow(
                        event: event,
                        expanded: _expanded.contains(position),
                        onTap: () => setState(() {
                          if (!_expanded.remove(position)) {
                            _expanded.add(position);
                          }
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// One event: the channel, the title, its trailing detail — and, expanded, the
/// payload. A row with nothing to expand does not offer to.
class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.expanded,
    required this.onTap,
  });

  final Map<String, Object?> event;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var channel = '${event['channel'] ?? AppChannel.log}';
    var error = event['error'] == true;
    var data = event['data'];
    var body = event['body'] as String?;
    var expandable = data != null || body != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tappable(
          onTap: expandable ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.lg,
              vertical: FwSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 14,
                  child: expandable
                      ? Icon(
                          expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: FwIconSize.sm,
                          color: colors.mut,
                        )
                      : null,
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    channel,
                    style: context.type.micro.copyWith(
                      color: _channelColor(context, channel),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${event['title']}',
                    style: context.type.bodySmall.copyWith(
                      color: error ? colors.red : null,
                    ),
                  ),
                ),
                if (event['detail'] case var detail?)
                  Padding(
                    padding: const EdgeInsets.only(left: FwSpacing.sm),
                    child: Text(
                      '$detail',
                      style: context.type.caption.copyWith(
                        color: error ? colors.red : colors.mut,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FwSpacing.xl,
              0,
              FwSpacing.lg,
              FwSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (body != null)
                  SelectableText(
                    body,
                    style: context.type.micro.copyWith(
                      fontFamily: 'monospace',
                      color: colors.ink2,
                    ),
                  ),
                if (data != null) ...[
                  if (body != null) const Gap(FwSpacing.sm),
                  JsonView(
                    data: data,
                    showToolbar: false,
                    searchable: false,
                    maxHeight: 240,
                  ),
                ],
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  /// One colour per lane, so a transition can be skimmed for its shape before
  /// it is read: the two that usually matter stand out, chatter recedes.
  Color _channelColor(BuildContext context, String channel) {
    var colors = context.colors;
    return switch (channel) {
      AppChannel.network => colors.accent,
      AppChannel.analytics => colors.grn,
      AppChannel.db => colors.amber,
      AppChannel.system => colors.mut3,
      _ => colors.mut,
    };
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip({
    required this.channel,
    required this.count,
    required this.on,
    required this.onTap,
  });

  final String channel;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: on ? colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(context.radii.radius),
          border: Border.all(color: on ? colors.accentSoft2 : colors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              channel,
              style: context.type.micro.copyWith(
                color: on ? colors.ink : colors.mut,
              ),
            ),
            const Gap(FwSpacing.xs),
            CountBadge(count, active: on),
          ],
        ),
      ),
    );
  }
}
