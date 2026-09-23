import 'package:flutterware/app_events.dart';
import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/menu.dart';
import '../../ui/popover.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../rules.dart';

/// What moved, on every channel that had something to say.
///
/// **What the percentage cannot say.** A pixel fraction says something moved
/// and roughly how much of the screen; it never says that a padding went from
/// 12 to 20, and that line is usually the whole finding.
///
/// The idiom is the diff's, because it is the one every reader already has:
/// the value a step used to carry sits on the removed tint, the value it
/// carries now sits on the added tint — the exact recipe the files tab uses
/// one tab away. The subject leads the line in ink, because `POST /session`
/// is what a reader recognises and `detail` is only which of its fields; the
/// old order led with the field name, which filled the scan column with
/// `detail`, `moved` and `cart.id` — words from the wire, not the app.
class ChannelLines extends StatefulWidget {
  const ChannelLines(this.item, {super.key, this.onRule, this.ruled = true});

  final ComparedItem item;

  /// Lets a reader hide what a row shows, from the row — "remove this little
  /// log call from the list" is asked while looking at the log call, not at a
  /// category vocabulary. Null draws the rows without the affordance.
  final ValueChanged<ComparisonRule>? onRule;

  /// Whether a rule separates this from what is drawn above it. False where it
  /// stands beside the stage instead, and the column's own edge does that.
  final bool ruled;

  /// How many rows one channel draws before it stops and says how many it cut.
  ///
  /// One number for all three, where the tree took 20 and the events channel
  /// inherited the model's 50 — two cap regimes on one screen, expressed two
  /// ways.
  static const _max = 24;

  @override
  State<ChannelLines> createState() => _ChannelLinesState();
}

class _ChannelLinesState extends State<ChannelLines> {
  /// Every row rather than the first [ChannelLines._max] of each channel.
  var _all = false;

  ComparedItem get item => widget.item;
  ValueChanged<ComparisonRule>? get onRule => widget.onRule;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var cap = _all ? 1 << 30 : ChannelLines._max;
    // Already cause-first: `TreeDiff.of` ranks them before anything takes a
    // page's worth, which is where the order has to be decided.
    var tree = [
      for (var delta in item.tree?.diff.deltas ?? const <TreeDelta>[])
        if (delta.kind == TreeDeltaKind.changed) delta,
    ];
    var came = [
      for (var delta in item.tree?.diff.deltas ?? const <TreeDelta>[])
        if (delta.kind == TreeDeltaKind.added ||
            delta.kind == TreeDeltaKind.removed)
          delta,
    ];
    // Folded like the events channel, and sorted so like sits with like: a
    // step whose network, database and log all moved was interleaving them in
    // capture order, which is the order nobody reads in.
    var events =
        foldChannelDeltas([
          [
            for (var delta in item.deltas)
              if (delta.channel == 'events' &&
                  delta.property != 'added' &&
                  delta.property != 'removed')
                delta,
          ],
        ])..sort((a, b) {
          var by = (a.delta.subchannel ?? '').compareTo(
            b.delta.subchannel ?? '',
          );
          return by != 0
              ? by
              : (a.delta.subject ?? '').compareTo(b.delta.subject ?? '');
        });

    var shownCame = came.take(cap).toList();
    var shownTree = tree.take(cap - shownCame.length).toList();
    var cut = came.length + tree.length - shownCame.length - shownTree.length;
    void showAll() => setState(() => _all = true);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.ruled
            ? Border(top: BorderSide(color: colors.line))
            : const Border(),
      ),
      child: ListView(
        padding: const EdgeInsets.all(FwSpacing.xl),
        children: [
          if (came.isNotEmpty || tree.isNotEmpty) ...[
            _Header('TREE', dropped: cut, onShowAll: showAll),
            ..._folded([
              for (var delta in shownCame)
                (_where(delta.path), delta.kind == TreeDeltaKind.added),
            ]),
            for (var delta in shownTree)
              _Moved(
                subject: _where(delta.path),
                property: delta.property ?? '',
                base: delta.base,
                head: delta.head,
              ),
            const Gap(FwSpacing.lg),
          ],
          if (item.texts case var texts?) ...[
            _Header('TEXTS', dropped: 0),
            ..._folded([
              for (var text in texts.removed) (text, false),
              for (var text in texts.added) (text, true),
            ]),
            const Gap(FwSpacing.lg),
          ],
          if (item.events case var found?) ...[
            _Header(
              'EVENTS',
              dropped: events.length - events.take(cap).length,
              // Dropped by the capture itself, not by this list: there is
              // nothing more to show, only a number to say.
              gone: found.deltasDropped,
              onShowAll: showAll,
            ),
            ..._folded([
              for (var event in found.removed) (event, false),
              for (var event in found.added) (event, true),
            ]),
            for (var row in events.take(cap))
              _Moved(
                channel: row.delta.subchannel,
                // When the title is what moved it is already the `base`
                // column, and naming the event by it as well printed one long
                // statement twice on one line.
                subject: row.delta.property == 'title'
                    ? null
                    : row.delta.subject,
                property: row.delta.property == 'title'
                    ? 'title'
                    : shortProperty(row.delta.property ?? ''),
                base: row.delta.base,
                head: row.delta.head,
                times: row.repeated ? row.count : null,
                delta: row.delta,
                onRule: onRule,
              ),
          ],
        ],
      ),
    );
  }

  /// Identical came-and-went lines folded to one row with a count — the same
  /// move `foldChannelDeltas` makes for moved fields. Seven `+ Padding › Row`
  /// in a column is one fact and six lines of noise, and it was the first
  /// thing this widget printed about its own redesign.
  static List<Widget> _folded(List<(String, bool)> lines) {
    var counts = <(String, bool), int>{};
    for (var line in lines) {
      counts[line] = (counts[line] ?? 0) + 1;
    }
    return [
      for (var MapEntry(key: (text, added), value: count) in counts.entries)
        _Gone(text, added: added, times: count == 1 ? null : count),
    ];
  }

  /// A tree path trimmed to its last two names: the whole thing is every
  /// widget from the root down, which is a line of chrome per finding before
  /// anything that changed. The full path stays in `index.json`.
  static String _where(String path) {
    var parts = path.split(' › ');
    return (parts.length <= 2 ? parts : parts.sublist(parts.length - 2)).join(
      ' › ',
    );
  }
}

const channelShowAllKey = Key('comparison.channels.show-all');

class _Header extends StatelessWidget {
  const _Header(
    this.label, {
    required this.dropped,
    this.gone = 0,
    this.onShowAll,
  });

  final String label;

  /// Rows this list has and is not drawing yet.
  final int dropped;

  /// Rows the capture never kept, so nothing can show them.
  final int gone;

  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Row(
        children: [
          Text(label, style: context.type.micro.copyWith(color: colors.mut)),
          if (dropped > 0) ...[
            const Gap(FwSpacing.sm),
            Tappable(
              key: channelShowAllKey,
              onTap: onShowAll,
              child: Text(
                'Show $dropped more',
                style: context.type.micro.copyWith(color: colors.accentDark),
              ),
            ),
          ],
          if (gone > 0) ...[
            const Gap(FwSpacing.sm),
            Text(
              '$gone not captured',
              style: context.type.micro.copyWith(color: colors.mut3),
            ),
          ],
        ],
      ),
    );
  }
}

/// One field that moved, drawn as a diff: subject, field, then the old value
/// on the removed tint and the new one on the added tint.
///
/// The tint is what makes the row scannable without alignment — subjects and
/// field names vary too much in length for the values to share an x, so the
/// values share a colour instead, the one colour pair every developer already
/// reads as *was → is*.
class _Moved extends StatefulWidget {
  const _Moved({
    this.channel,
    this.subject,
    required this.property,
    required this.base,
    required this.head,
    this.times,
    this.delta,
    this.onRule,
  });

  /// The event lane — `network`, `db`, `system` — drawn in the lane's own
  /// colour in a fixed column, exactly as the events view draws a transition.
  /// Null on the tree channel, where the section already names the lane.
  final String? channel;
  final String? subject;
  final String property;
  final String? base;
  final String? head;
  final int? times;

  /// The delta behind the row, for the hide ladder — and the ladder only
  /// draws when both this and [onRule] are given.
  final ChannelDelta? delta;
  final ValueChanged<ComparisonRule>? onRule;

  @override
  State<_Moved> createState() => _MovedState();
}

class _MovedState extends State<_Moved> {
  /// The ladder's trigger shows to a pointer, so a settled row costs no
  /// width — but the slot is always reserved, or the line would reflow under
  /// the mouse.
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var channel = widget.channel;
    var subject = widget.subject;
    var times = widget.times;
    var line = SelectableText.rich(
      TextSpan(
        children: [
          if (subject case var subject?) ...[
            TextSpan(
              text: subject,
              style: TextStyle(color: colors.ink2),
            ),
            const TextSpan(text: '  '),
          ],
          TextSpan(
            text: widget.property,
            style: TextStyle(color: colors.mut),
          ),
          const TextSpan(text: '  '),
          _value(widget.base, colors.red, colors),
          TextSpan(
            text: ' → ',
            style: TextStyle(color: colors.mut2),
          ),
          _value(widget.head, colors.grn, colors),
          if (times case var count?)
            TextSpan(
              text: '  × $count',
              style: TextStyle(color: colors.mut3),
            ),
        ],
      ),
      style: context.type.caption,
    );

    var row = channel == null
        ? line
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 74,
                child: Text(
                  channel,
                  style: context.type.caption.copyWith(
                    color: channelColor(context, channel),
                  ),
                ),
              ),
              Expanded(child: line),
            ],
          );

    var body = Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: widget.delta == null || widget.onRule == null
          ? row
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: row),
                SizedBox(
                  width: 20,
                  height: 16,
                  child: _hovered ? _ladder(context) : null,
                ),
              ],
            ),
    );
    if (widget.delta == null || widget.onRule == null) return body;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: body,
    );
  }

  /// The hide ladder: the same rule at two widths, each saying what it pins.
  /// Authored by pointing — the reader is looking at the change they want
  /// gone, so the menu never asks them to name it in category vocabulary.
  Widget _ladder(BuildContext context) {
    var delta = widget.delta!;
    var onRule = widget.onRule!;
    return Menu(
      align: PopoverAlign.end,
      entries: [
        MenuItem(
          'Hide this change',
          onSelected: () => onRule(shapeRule(delta)),
        ),
        if (delta.subchannel case var subchannel?)
          MenuItem(
            'Hide every $subchannel event',
            onSelected: () =>
                onRule(ComparisonRule.on('subchannel', subchannel)),
          ),
      ],
      builder: (context, controller) => Tappable(
        onTap: controller.toggle,
        child: Icon(
          Icons.visibility_off_outlined,
          size: 13,
          color: context.colors.mut2,
        ),
      ),
    );
  }

  TextSpan _value(String? value, Color tone, FwPalette colors) => TextSpan(
    text: ' ${value ?? '∅'} ',
    style: TextStyle(
      color: colors.ink,
      backgroundColor: tone.withValues(alpha: 0.12),
    ),
  );
}

/// Something that came or went, drawn as the diff line it is: the marker in
/// the tone, the words on the tone's tint, the same recipe as the files tab.
class _Gone extends StatelessWidget {
  const _Gone(this.text, {this.added = false, this.times});

  final String text;
  final bool added;
  final int? times;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var tone = added ? colors.grn : colors.red;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: added ? '+ ' : '- ',
              style: TextStyle(color: tone, fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: ' $text ',
              style: TextStyle(
                color: colors.ink,
                backgroundColor: tone.withValues(alpha: 0.12),
              ),
            ),
            if (times case var count?)
              TextSpan(
                text: '  × $count',
                style: TextStyle(color: colors.mut3),
              ),
          ],
        ),
        style: context.type.caption,
      ),
    );
  }
}

/// One colour per event lane, so a delta can be skimmed for its shape before
/// it is read — the same mapping the events view uses for a live transition,
/// legitimate here because events are the only subject on these rows.
Color channelColor(BuildContext context, String channel) {
  var colors = context.colors;
  return switch (channel) {
    AppChannel.network => colors.accent,
    AppChannel.analytics => colors.grn,
    AppChannel.db => colors.amber,
    AppChannel.system => colors.mut3,
    _ => colors.mut,
  };
}

/// A field path trimmed to its last two segments.
///
/// The same rule the verdict strip uses, in one place rather than two: the
/// strip was saying `autofill.uniqueIdentifier` while the line under it said
/// `data.arguments[1].autofill.uniqueIdentifier`, which is one fact wearing
/// two names on one screen. The first half of that path is wire plumbing.
String shortProperty(String property) {
  var parts = property.split('.');
  return parts.length <= 2
      ? property
      : parts.sublist(parts.length - 2).join('.');
}
