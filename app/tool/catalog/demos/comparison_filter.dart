import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/ui/state_chip.dart';
import 'package:flutterware_app/src/ui/count_badge.dart';
import 'package:flutterware_app/src/ui/popover_menu.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// Excluding *some* events from *one* file — the case the verdict alone cannot
/// reach, drawn so the interaction can be argued about before it is built.
///
/// Three questions this exists to answer, none of which prose settled:
/// where a rule is authored, where the chip then lives, and what happens to a
/// finding whose only delta a rule removed.
@Preview(
  name: 'Comparison filter · a rule in place',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget filterRuleInPlace() => const _Screen();

@Preview(
  name: 'Comparison filter · authoring a rule',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget filterAuthoring() => const _Authoring();

const _indexWidth = 320.0;

class _Screen extends StatelessWidget {
  const _Screen();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              FwSpacing.xl,
              FwSpacing.md,
              FwSpacing.xl,
              FwSpacing.md,
            ),
            child: _Verdict(),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: _indexWidth, child: _Index()),
                VerticalDivider(width: 1, color: colors.line),
                const Expanded(child: _Detail()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The verdict, now carrying what is *not* being looked at.
///
/// Rules live here rather than in the index, and the earlier note had this
/// wrong. `All · Important · Review` in the index is a **list scope** — which
/// rows to list. A rule is a statement about the whole comparison, it has to
/// sit beside the counts it changes (or a reader is quietly lied to), and it
/// does not fit in 320px beside a search box and three tabs.
class _Verdict extends StatelessWidget {
  const _Verdict();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: FwSpacing.sm,
          runSpacing: FwSpacing.xs,
          children: [
            Text(
              '2 findings',
              style: context.type.body.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const StateChip(ComparedState.changed, count: 2),
            Text(
              '1 new',
              style: context.type.caption.copyWith(color: colors.amber),
            ),
            const _Chip(label: 'events', count: 2, on: true),
            const _Chip(label: 'network', count: 2, on: true),
            const _Rule(label: 'db · cache.dart', count: 3),
            const _Rule(label: 'system', count: 11),
          ],
        ),
        const Gap(FwSpacing.xs),
        Row(
          children: [
            Text(
              '7 findings hidden by 2 rules',
              style: context.type.caption.copyWith(color: colors.amber),
            ),
            const Gap(FwSpacing.sm),
            Text(
              'show',
              style: context.type.caption.copyWith(color: colors.accentDark),
            ),
          ],
        ),
      ],
    );
  }
}

/// An exclusion, as a chip that says what it removed and can be undone.
///
/// Struck-through and muted rather than absent: a rule you cannot see is a
/// rule that lies to you on the next comparison, and the count is the reason
/// you would turn it back on.
class _Rule extends StatelessWidget {
  const _Rule({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.panel2,
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('−', style: context.type.micro.copyWith(color: colors.mut)),
          const Gap(FwSpacing.xs),
          Text(
            label,
            style: context.type.micro.copyWith(
              color: colors.mut,
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const Gap(FwSpacing.xs),
          CountBadge(count, active: false),
          const Gap(FwSpacing.xs),
          Icon(Icons.close, size: 11, color: colors.mut),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.count, required this.on});

  final String label;
  final int count;
  final bool on;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Container(
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
            label,
            style: context.type.micro.copyWith(
              color: on ? colors.ink : colors.mut,
            ),
          ),
          const Gap(FwSpacing.xs),
          CountBadge(count, active: on),
        ],
      ),
    );
  }
}

/// The list, with what the rules removed demoted rather than deleted.
///
/// The comparison design already decided this shape for `skipped`: a row that
/// is missing tells a reader nothing, and *skipped* tells them the tool looked.
/// A row a **rule** removed is the same claim about the reader instead of about
/// the tool, so it degrades the same way — greyed, collapsed under a count,
/// one click from being back.
class _Index extends StatelessWidget {
  const _Index();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      children: [
        for (var name in const ['Checkout', 'Signing in'])
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.md,
              vertical: FwSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: context.type.caption.copyWith(color: colors.ink),
                  ),
                ),
                Text(
                  'network',
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
                const Gap(FwSpacing.sm),
                const StateChip(ComparedState.changed),
              ],
            ),
          ),
        const Divider(height: FwSpacing.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
          child: Row(
            children: [
              Icon(Icons.chevron_right, size: 14, color: colors.mut),
              const Gap(FwSpacing.xs),
              Expanded(
                child: Text(
                  '7 hidden by your rules',
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The detail, where a delta row is what a rule is authored *from*.
class _Detail extends StatelessWidget {
  const _Detail();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ON THE WAY HERE',
            style: context.type.micro.copyWith(color: colors.mut),
          ),
          const Gap(FwSpacing.xs),
          for (var (line, dim) in const [
            ('network POST /login  detail  200 → 500', false),
            ('network GET /me  body.user.role  member → admin', false),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: context.type.caption.copyWith(
                  color: dim ? colors.mut : colors.ink2,
                ),
              ),
            ),
          const Gap(FwSpacing.md),
          Text(
            'right-click a line to exclude every delta like it',
            style: context.type.micro.copyWith(color: colors.mut),
          ),
        ],
      ),
    );
  }
}

/// The gesture: point at a delta, and choose how wide the rule should be.
///
/// A ladder from *this exact thing* to *this whole file*, because the fact a
/// reader wants to stop seeing is at a different width every time. Each row
/// says what it would remove, so nothing has to be tried to be understood —
/// and `MenuItem.onHover` already exists for previewing the effect in the list
/// behind while the pointer is on the row.
class _Authoring extends StatelessWidget {
  const _Authoring();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'db  select * from cache where key = ?  data.rows  3 → 4',
              style: context.type.caption.copyWith(color: colors.ink2),
            ),
            const Gap(FwSpacing.xs),
            Text(
              'package:app/src/data/cache.dart  Cache.read',
              style: context.type.micro.copyWith(color: colors.mut),
            ),
            const Gap(FwSpacing.sm),
            PopoverMenuSurface(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MenuHeader('Stop showing'),
                  for (var (label, detail) in const [
                    ('this field, on this statement', '1 delta'),
                    ('any field, on this statement', '3 deltas'),
                    ('db events from cache.dart', '3 deltas · 2 findings'),
                    ('everything from cache.dart', '3 deltas · 2 findings'),
                    ('every db event', '9 deltas · 4 findings'),
                  ])
                    _MenuRow(label: label, detail: detail),
                  Divider(height: 1, color: colors.line),
                  const _MenuRow(
                    label: 'Report this shape to flutterware…',
                    detail: '',
                    muted: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FwSpacing.md,
      FwSpacing.sm,
      FwSpacing.md,
      FwSpacing.xs,
    ),
    child: Text(
      label,
      style: context.type.micro.copyWith(color: context.colors.mut),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.detail,
    this.muted = false,
  });

  final String label;
  final String detail;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.md,
          vertical: 5,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: context.type.caption.copyWith(
                  color: muted ? colors.mut : colors.ink,
                ),
              ),
            ),
            if (detail.isNotEmpty)
              Text(
                detail,
                style: context.type.micro.copyWith(color: colors.mut),
              ),
          ],
        ),
      ),
    );
  }
}
