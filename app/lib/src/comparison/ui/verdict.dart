import 'package:flutterware/comparison_report.dart';
import 'package:flutter/material.dart';

import '../../ui/popover.dart';
import '../../ui/popover_menu.dart';
import '../../ui/tappable.dart';
import '../../ui/theme.dart';
import '../comparison_controller.dart';
import '../rules.dart';
import 'channel_lines.dart';

/// What *kind* of change this branch made, above both panes.
///
/// **Not the counts.** The receipt strip directly above already says
/// `7 changed · 9 unchanged`, and drawing them twice was the first thing
/// building this got wrong — worse, the two disagreed, because a scenario
/// half counts flows in the list and the channels live on the steps inside
/// them: three numbers with two meanings on one screen. So this says only
/// what the receipt cannot — which channels spoke, which stayed silent, and
/// what the findings are mostly made of.
///
/// **Full width, in the header slot**, because the files tab already puts
/// `0 files +0 -0` there and because a verdict is about both panes. Drawn
/// inside the 320px index instead, the chips wrap to a second row, the shape
/// line truncates and it costs the list ~110px of height. Design:
/// `docs/superpowers/specs/2026-08-30-comparison-ui-pass-design.md` §1.
///
/// **Counted over findings, never over every row.** A comparison is hundreds
/// of rows and a handful of findings, so everything here is O(findings) by
/// construction — the same reason `ComparisonIndex.ok` is a scan rather than a
/// built list.
class ComparisonVerdict extends StatelessWidget {
  const ComparisonVerdict({
    super.key,
    required this.findings,
    required this.unit,
    this.newCount,
    this.rules = const [],
    this.onToggle,
  });

  /// The things whose channels are counted. For the scenario half these are
  /// its **steps**, not its flows: a flow's verdict is a roll-up, and the
  /// channels live underneath it.
  final List<ComparedItem> findings;

  /// What one of [findings] is called, singular — `step`, `entry`.
  ///
  /// The counts here are over these and the receipt strip's are over what the
  /// list shows, so the noun is the thing that keeps a reader from reading one
  /// as the other.
  final String unit;

  /// How many rows the list shows were not in the previous comparison. Null
  /// before there has ever been one, which is not the same as zero and must
  /// not read as it.
  final int? newCount;

  /// What this reader has excluded. Every one of them is drawn, struck
  /// through, carrying the count it is suppressing — a rule you cannot see is
  /// a rule that lies to you on the next comparison.
  final List<ComparisonRule> rules;

  /// Null draws the chips as labels rather than as controls, which is what v1
  /// did: a chip that looks pressable and is not is worse than one that does
  /// not.
  final ValueChanged<ComparisonRule>? onToggle;

  /// The verdict of one [ComparisonHalf], built the same wherever the half is
  /// drawn — the panel and the exported page both wire [onToggle] to the
  /// half's own rules.
  ///
  /// The scenario half's findings are its **steps**, not its flows: a flow's
  /// verdict is a roll-up of the steps inside it, and the channels live on the
  /// steps. Counting flows would say `7 findings` and then be unable to name a
  /// single channel.
  static ComparisonVerdict ofHalf(
    ComparisonHalf half, {
    ValueChanged<ComparisonRule>? onToggle,
  }) {
    var findings = switch (half.kind) {
      ComparisonHalfKind.previews => [
        for (var row in half.rows)
          if (row.state.isFinding) row,
      ],
      ComparisonHalfKind.scenarios => [
        for (var scenario in half.scenarios)
          for (var step in scenario.items)
            if (step.state.isFinding) step,
      ],
    };
    return ComparisonVerdict(
      findings: findings,
      rules: half.rules,
      onToggle: onToggle,
      unit: switch (half.kind) {
        ComparisonHalfKind.previews => 'entry',
        ComparisonHalfKind.scenarios => 'step',
      },
      newCount: switch (half.previousFindingIds) {
        var previous? => switch (half.kind) {
          ComparisonHalfKind.previews =>
            half.rows
                .where(
                  (row) => row.state.isFinding && !previous.contains(row.id),
                )
                .length,
          ComparisonHalfKind.scenarios =>
            half.scenarios
                .where(
                  (scenario) =>
                      scenario.state.isFinding &&
                      !previous.contains(scenario.scenario),
                )
                .length,
        },
        null => null,
      },
    );
  }

  static const _channels = ['pixels', 'tree', 'texts', 'events'];

  /// Subchannel keys are prefixed so one map can hold both without a
  /// subchannel named `tree` ever colliding with the channel called `tree`.
  static const _subPrefix = 'events/';

  /// A system delta counts toward the `events/system` row and nothing above
  /// it. It cannot make a finding ([EventChannel.significant]), so an `events`
  /// chip that counted it would claim more steps than the list shows — the
  /// subchannel row keeps the count, which is the door the design note wanted.
  static List<String> _facetsOf(ChannelDelta delta) => [
    if (!_isSystem(delta)) delta.channel,
    if (delta.subchannel case var sub?) '$_subPrefix$sub',
  ];

  static bool _isSystem(ChannelDelta delta) =>
      delta.channel == 'events' &&
      delta.subchannel == EventChannel.systemSubchannel;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;

    var set = RuleSet(rules);
    // Built **once**. `deltas` allocates a `ChannelDelta` per difference, and
    // this walked it three times over — for the counts, again inside
    // `hidesAll`, and a third time inside `visible` — in a build that runs
    // once per row as a comparison streams in. `ComparisonIndex.ok`'s own
    // docstring is about this shape.
    //
    // A tree read by two versions of the walk is left out here, ahead of
    // everything: it cannot make a finding (`TreeChannel.significant`), and a
    // `tree` chip counting it would claim a channel spoke that the verdict
    // did not listen to. The detail pages still draw it.
    var perFinding = [
      for (var item in findings)
        [
          for (var delta in item.deltas)
            if (delta.channel != 'tree' || !(item.tree?.skewed ?? false)) delta,
        ],
    ];

    // Counted twice on purpose. `fired` is what a reader can still see, and is
    // what the chips read; `total` ignores every rule, and is what an excluded
    // chip has to show — a chip reading `0` is one nobody would ever turn back
    // on, which `CountBadge`'s own doc is about.
    var fired = <String, int>{};
    var total = <String, int>{};
    var hidden = 0;
    var visible = <List<ChannelDelta>>[];
    for (var deltas in perFinding) {
      var seen = <String>{};
      var seenAll = <String>{};
      var mine = <ChannelDelta>[];
      // The signal is what decides `hidden` — system chatter can neither make
      // a finding nor keep one visible, so it is left out of both sides of
      // the ledger, the same arithmetic `RuleSet.hidesAll` runs.
      var signal = 0;
      var signalHidden = 0;
      for (var delta in deltas) {
        var system = _isSystem(delta);
        if (!system) signal++;
        seenAll.addAll(_facetsOf(delta));
        if (set.hides(delta)) {
          if (!system) signalHidden++;
          continue;
        }
        mine.add(delta);
        seen.addAll(_facetsOf(delta));
      }
      visible.add(mine);
      for (var key in seenAll) {
        total[key] = (total[key] ?? 0) + 1;
      }
      for (var key in seen) {
        fired[key] = (fired[key] ?? 0) + 1;
      }
      // A finding with no deltas at all is never hidden: `added` and `broke`
      // say something no channel does, and a rule about channels has no
      // opinion about them.
      if (signal > 0 && signal == signalHidden) hidden++;
    }

    var quiet = [
      for (var channel in _channels)
        if (!total.containsKey(channel)) channel,
    ];
    // Pixels are excluded from the fold on purpose. A pixel delta has no
    // subject and no field — its property is the word `changed` — so every
    // one of them groups together and the row comes out claiming *the same
    // field moved in 6 of 6 entries · changed*, which is nonsense wearing a
    // number. The percentage on each row is what says how much moved.
    // System is excluded for the opposite reason: it folds *too* well — a
    // router's `pageKey` rides every step, and the story line would lead
    // with the one change that is never the story.
    var shapes = foldChannelDeltas([
      for (var deltas in visible)
        [
          for (var delta in deltas)
            if (delta.channel != 'pixels' && !_isSystem(delta)) delta,
        ],
    ]);
    if (total.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FwSpacing.xl,
        FwSpacing.md,
        FwSpacing.xl,
        FwSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The four channels report; the knobs live in the Filter popover.
          // Subchannels used to sit here as sibling chips — ten equal-weight
          // pills, a hierarchy drawn as a list — and the row was unreadable
          // for exactly the reason option B was rejected in the design note.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // `Wrap`, not `Row`: this header is as wide as the window,
                // and a window can be narrow. The files tab's own strip
                // learned this the hard way and says so in its docstring.
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: FwSpacing.sm,
                  runSpacing: FwSpacing.xs,
                  children: [
                    for (var channel in _channels)
                      if (total[channel] case var count?)
                        _ChannelCount(
                          label: channel,
                          count: fired[channel] ?? 0,
                          hiddenCount: count,
                          unit: unit,
                          excluded: set.has('channel', channel),
                          onToggle: onToggle == null
                              ? null
                              : () => onToggle!(
                                  ComparisonRule.on('channel', channel),
                                ),
                        ),
                    if (newCount case var count? when count > 0)
                      Tooltip(
                        message: 'Not in the previous comparison',
                        waitDuration: const Duration(milliseconds: 400),
                        child: Text(
                          '$count new',
                          style: context.type.caption.copyWith(
                            color: colors.amber,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onToggle case var toggle?) ...[
                const Gap(FwSpacing.sm),
                _FilterButton(
                  rules: rules,
                  totals: total,
                  set: set,
                  unit: unit,
                  onToggle: toggle,
                ),
              ],
            ],
          ),
          if (hidden > 0) ...[
            const Gap(FwSpacing.xs),
            Text(
              '${plural(hidden, unit)} hidden by '
              '${plural(rules.length, 'rule')}',
              style: context.type.caption.copyWith(color: colors.amber),
            ),
          ],
          if (findings.isNotEmpty && quiet.isNotEmpty) ...[
            const Gap(FwSpacing.xs),
            // The strongest line the comparison can print, and no chip can
            // say it: every finding here was invisible to a screenshot.
            Text(
              'no changes on ${_list(quiet)}',
              style: context.type.caption.copyWith(color: colors.mut),
            ),
          ],
          // Only when one shape accounts for **most** of them. The line
          // answers *is this one thing or many*, so a shape covering two
          // findings in fifty answers "many" — and printing `2 of 50 are the
          // same change` puts the biggest minority cluster where a reader
          // looks for the story. Below a majority the honest summary is
          // silence: the chips said how much there is, and the list is where
          // a set of unrelated findings gets read.
          if (shapes.firstOrNull case var shape?
              when shape.items * 2 > findings.length && shape.repeated) ...[
            const Gap(FwSpacing.xs),
            _Shape(
              shape,
              of: findings.length,
              // Hiding the majority shape is the single biggest lever a
              // reviewer has, and the fold has already aimed it: one click,
              // the rule pins exactly the facets the shape groups on.
              onHide: onToggle == null
                  ? null
                  : () => onToggle!(shapeRule(shape.delta)),
            ),
          ],
        ],
      ),
    );
  }

  /// `pixels, tree or texts` — the last join is a word, because this is read
  /// as a sentence rather than scanned as a list.
  static String _list(List<String> names) => switch (names.length) {
    0 => '',
    1 => names.single,
    _ => '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}',
  };
}

/// `1 entry`, `10 entries`, `2 steps` — the strip was printing `10 entrys`.
String plural(int count, String unit) {
  var word = count == 1
      ? unit
      : unit.endsWith('y')
      ? '${unit.substring(0, unit.length - 1)}ies'
      : '${unit}s';
  return '$count $word';
}

/// What the comparison is mostly made of, when it is mostly made of one thing.
///
/// Drawn only when the top shape actually repeats: on a branch whose findings
/// are all different, this line would be one finding pretending to be a
/// summary.
/// Whether these are many problems or one problem many times.
///
/// The only question on this strip the chips cannot answer. `events · 11
/// steps` says eleven steps have something to say; it cannot say whether that
/// is eleven regressions or one fact repeated eleven times, and those are
/// completely different mornings. Without it a reader opens seven rows to find
/// out they were all the same thing, which is the skim-past-the-list failure
/// the whole strip exists to prevent.
///
/// **The values are shown, and they are the point.** `EditableText-1046586511
/// → EditableText-` reads as *a hash* at a glance, and reading it as a hash is
/// what lets a reader decide this is noise and exclude it. The field alone
/// cannot be judged, which is why the earlier drawing of this line — three
/// identifiers and a count — told nobody anything.
class _Shape extends StatelessWidget {
  const _Shape(this.row, {required this.of, this.onHide});

  final FoldedDelta row;

  /// Hides the shape from the list — the whole point of naming it.
  final VoidCallback? onHide;

  /// How many findings there are in total — the denominator that turns a
  /// count into a proportion. *All of them* and *4 of 11* are different
  /// situations and a bare count says neither.
  final int of;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var delta = row.delta;
    // `all 11` and `8 of 11` are the two readings, and they are different
    // news: the first says there is one thing here, the second says there is
    // one thing *and a few others*, which is the reason to keep reading.
    var how = row.items >= of ? 'all $of' : '${row.items} of $of';
    var line = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'same change in $how — '),
          TextSpan(
            // A delta with no values — a node or an event that came or went —
            // is named by its subject: `added` alone says nothing, and the
            // subject is the only other thing all its occurrences share.
            text: delta.base == null && delta.subject != null
                ? '${_shortSubject(delta.subject!)} ${delta.property}'
                : shortProperty(delta.property ?? ''),
            style: TextStyle(color: colors.mut, fontWeight: FontWeight.w600),
          ),
          // The values wear the diff's own tints, the same recipe as the
          // delta rows below — the summary and the detail must not speak two
          // languages about one fact.
          if (delta.base case var base?) ...[
            const TextSpan(text: '  '),
            TextSpan(
              text: ' ${_short(base)} ',
              style: TextStyle(
                color: colors.ink,
                backgroundColor: colors.red.withValues(alpha: 0.12),
              ),
            ),
            TextSpan(
              text: ' → ',
              style: TextStyle(color: colors.mut2),
            ),
            TextSpan(
              text: ' ${_short(delta.head ?? '')} ',
              style: TextStyle(
                color: colors.ink,
                backgroundColor: colors.grn.withValues(alpha: 0.12),
              ),
            ),
          ],
        ],
      ),
      style: context.type.caption.copyWith(color: colors.mut),
      overflow: TextOverflow.ellipsis,
    );
    if (onHide == null) return line;
    return Row(
      children: [
        Flexible(child: line),
        const Gap(FwSpacing.sm),
        Tappable(
          onTap: onHide,
          child: Text(
            'Hide',
            style: context.type.caption.copyWith(color: colors.accentDark),
          ),
        ),
      ],
    );
  }

  /// One value, short enough to sit on a summary line. What is being judged
  /// here is the *shape* of the value — that it looks like a hash — and forty
  /// characters is more than enough to see that.
  static String _short(String value) =>
      value.length <= 40 ? value : '${value.substring(0, 39)}…';

  /// A subject trimmed the way a tree path is: its last two ` › ` names.
  static String _shortSubject(String subject) {
    var parts = subject.split(' › ');
    if (parts.length > 2) {
      return parts.sublist(parts.length - 2).join(' › ');
    }
    return _short(subject);
  }
}

/// The knobs: what is hidden, and the channel tree to hide more.
///
/// The chip row reports; this is where a reader *changes* what the list
/// shows. Rules authored anywhere — a chip, the shape line's Hide, a delta
/// row's ladder — land in the same ledger here, each with an undo, so a
/// filter in force is never more than one click from visible.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.rules,
    required this.totals,
    required this.set,
    required this.unit,
    required this.onToggle,
  });

  final List<ComparisonRule> rules;

  /// Findings per channel (`pixels`) and per event subchannel
  /// (`events/system`), ignoring every rule — an excluded row keeps the count
  /// it is hiding.
  final Map<String, int> totals;
  final RuleSet set;
  final String unit;
  final ValueChanged<ComparisonRule> onToggle;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Popover(
      align: PopoverAlign.end,
      anchor: (context, controller) => Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radius),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: controller.isOpen || rules.isNotEmpty
                ? colors.accentSoft
                : null,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radius),
          ),
          child: Text(
            rules.isEmpty ? 'Filter' : 'Filter · ${rules.length}',
            style: context.type.caption.copyWith(color: colors.ink),
          ),
        ),
      ),
      content: (context, controller) => PopoverMenuSurface(
        width: 320,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rules.isNotEmpty) ...[
                  Text(
                    'HIDING',
                    style: context.type.micro.copyWith(color: colors.mut),
                  ),
                  const Gap(FwSpacing.xs),
                  for (var rule in rules) _RuleRow(rule, onRemove: onToggle),
                  const Gap(FwSpacing.md),
                ],
                Text(
                  'CHANNELS',
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
                const Gap(FwSpacing.xs),
                // The events group is present whenever any subchannel spoke:
                // system does not count toward the channel — it cannot make a
                // finding — but its row is the one door to hiding the chatter
                // on detail pages, and a gate on the channel's own count
                // would close it exactly when system is all there is.
                for (var channel in ComparisonVerdict._channels)
                  if (totals.containsKey(channel) ||
                      (channel == 'events' && _subchannels.isNotEmpty)) ...[
                    _FacetRow(
                      label: channel,
                      count: totals[channel] ?? 0,
                      unit: unit,
                      excluded: set.has('channel', channel),
                      onToggle: () =>
                          onToggle(ComparisonRule.on('channel', channel)),
                    ),
                    if (channel == 'events')
                      for (var key in _subchannels)
                        _FacetRow(
                          label: key.substring(
                            ComparisonVerdict._subPrefix.length,
                          ),
                          count: totals[key]!,
                          unit: unit,
                          indented: true,
                          excluded: set.has(
                            'subchannel',
                            key.substring(ComparisonVerdict._subPrefix.length),
                          ),
                          onToggle: () => onToggle(
                            ComparisonRule.on(
                              'subchannel',
                              key.substring(
                                ComparisonVerdict._subPrefix.length,
                              ),
                            ),
                          ),
                        ),
                  ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Every subchannel the events channel actually produced, most-said first.
  /// `system` is the whole reason the tree goes a level down: it was 11 of 11
  /// findings here and 192 of 293 event differences on a consumer's suite,
  /// and it is a *sub*channel, so a row that stops at `events` cannot reach
  /// it.
  List<String> get _subchannels => [
    for (var key in totals.keys)
      if (key.startsWith(ComparisonVerdict._subPrefix)) key,
  ]..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
}

/// One rule in force: what it hides, and the way out.
class _RuleRow extends StatelessWidget {
  const _RuleRow(this.rule, {required this.onRemove});

  final ComparisonRule rule;
  final ValueChanged<ComparisonRule> onRemove;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.xs),
      child: Row(
        children: [
          Text('−', style: context.type.caption.copyWith(color: colors.mut)),
          const Gap(FwSpacing.sm),
          Expanded(
            child: Text(
              rule.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.caption.copyWith(color: colors.ink2),
            ),
          ),
          const Gap(FwSpacing.sm),
          Tappable(
            onTap: () => onRemove(rule),
            child: Icon(Icons.close, size: 13, color: colors.mut),
          ),
        ],
      ),
    );
  }
}

/// A channel or subchannel row: shown or hidden, with the count it covers.
class _FacetRow extends StatelessWidget {
  const _FacetRow({
    required this.label,
    required this.count,
    required this.unit,
    required this.excluded,
    required this.onToggle,
    this.indented = false,
  });

  final String label;
  final int count;
  final String unit;
  final bool excluded;
  final VoidCallback onToggle;
  final bool indented;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.only(
          left: indented ? FwSpacing.xl : 0,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          children: [
            Icon(
              excluded
                  ? Icons.check_box_outline_blank
                  : Icons.check_box_outlined,
              size: 15,
              color: excluded ? colors.mut3 : colors.ink2,
            ),
            const Gap(FwSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: context.type.caption.copyWith(
                  color: excluded ? colors.mut : colors.ink,
                ),
              ),
            ),
            Text(
              plural(count, unit),
              style: context.type.micro.copyWith(color: colors.mut2),
            ),
          ],
        ),
      ),
    );
  }
}

/// A channel or subchannel, its count, and whether it is being looked at.
///
/// An excluded chip is struck through and keeps the count it is **hiding**,
/// not the zero it is showing: *"Off recedes rather than disappears — the
/// count is still the reason a reader would turn it back on."*
class _ChannelCount extends StatelessWidget {
  const _ChannelCount({
    required this.label,
    required this.count,
    required this.hiddenCount,
    required this.unit,
    required this.excluded,
    this.onToggle,
  });

  final String label;

  /// How many are visible under the rules in force.
  final int count;

  /// How many there are when nothing is excluded.
  final int hiddenCount;

  final String unit;
  final bool excluded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var shown = excluded ? hiddenCount : count;
    // A channel emptied *by a rule* is not a channel that was silent, and the
    // two must not read alike: `events · 0 steps` in full ink asserts the
    // events channel found nothing, when what happened is that everything it
    // found was on a subchannel this reader excluded.
    var emptied = !excluded && count == 0 && hiddenCount > 0;
    var chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: excluded ? colors.panel2 : null,
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (excluded) ...[
            Text('−', style: context.type.micro.copyWith(color: colors.mut)),
            const Gap(FwSpacing.xs),
          ],
          Text(
            '$label · ${plural(shown, unit)}',
            style: context.type.micro.copyWith(
              color: excluded || emptied ? colors.mut : colors.ink2,
              decoration: excluded ? TextDecoration.lineThrough : null,
            ),
          ),
          if (excluded) ...[
            const Gap(FwSpacing.xs),
            Icon(Icons.close, size: 11, color: colors.mut),
          ],
        ],
      ),
    );
    if (onToggle == null) return chip;
    return Tooltip(
      message: excluded ? 'Show $label again' : 'Stop showing $label',
      waitDuration: const Duration(milliseconds: 400),
      child: Tappable(onTap: onToggle, child: chip),
    );
  }
}
