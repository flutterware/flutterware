import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/ui/state_chip.dart';
import 'package:flutterware_app/src/ui/count_badge.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// Where the verdict goes, drawn in the layout it would go in.
///
/// The floating strip on its own could not answer this, which is the whole
/// reason for these two. The previews tab is the files tab's shape: a
/// full-width header, a divider, then a 320px index beside a detail — so the
/// question is only whether the verdict belongs in the header slot that
/// already exists, or inside the index column above the rows.
@Preview(
  name: 'Verdict in place · full width',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictFullWidth() => const _Screen(overIndexOnly: false);

@Preview(
  name: 'Verdict in place · over the list',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictOverList() => const _Screen(overIndexOnly: true);

const _indexWidth = 320.0;

class _Screen extends StatelessWidget {
  const _Screen({required this.overIndexOnly});

  final bool overIndexOnly;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ColoredBox(
      color: colors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TabStrip(),
          Divider(height: 1, color: colors.line),
          if (!overIndexOnly) ...[
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
          ],
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _indexWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (overIndexOnly) ...[
                        const Padding(
                          padding: EdgeInsets.all(FwSpacing.md),
                          child: _Verdict(),
                        ),
                        Divider(height: 1, color: colors.line),
                      ],
                      const Expanded(child: _IndexRows()),
                    ],
                  ),
                ),
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

class _TabStrip extends StatelessWidget {
  const _TabStrip();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xl),
      child: Row(
        children: [
          for (var (label, on) in const [
            ('files', false),
            ('previews', false),
            ('scenarios', true),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FwSpacing.sm,
                vertical: FwSpacing.md,
              ),
              child: Text(
                label,
                style: context.type.caption.copyWith(
                  color: on ? colors.ink : colors.mut,
                  fontWeight: on ? FontWeight.w600 : null,
                ),
              ),
            ),
          const Spacer(),
          Text(
            'this worktree ⇄ origin/master @b7af38a',
            style: context.type.micro.copyWith(color: colors.mut),
          ),
        ],
      ),
    );
  }
}

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
              '9 findings',
              style: context.type.body.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const StateChip(ComparedState.changed, count: 7),
            const StateChip(ComparedState.added, count: 2),
            Text(
              '1 new',
              style: context.type.caption.copyWith(color: colors.amber),
            ),
            const _ChannelToggle(label: 'events', count: 7, on: true),
            const _ChannelToggle(label: 'system', count: 11, on: false),
          ],
        ),
        const Gap(FwSpacing.xs),
        Text(
          'nothing moved on pixels, tree or texts',
          style: context.type.caption.copyWith(color: colors.mut),
        ),
        const Gap(FwSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                'system · TextInput.setClient · autofill.uniqueIdentifier',
                style: context.type.caption.copyWith(color: colors.mut),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(FwSpacing.sm),
            const CountBadge(11, active: false),
          ],
        ),
      ],
    );
  }
}

/// Placeholder rows, so the panes read as panes rather than as empty boxes.
class _IndexRows extends StatelessWidget {
  const _IndexRows();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: FwSpacing.sm),
      children: [
        for (var (name, state) in const [
          ('Counter', ComparedState.changed),
          ('Signing in', ComparedState.changed),
          ('Signing in over http', ComparedState.changed),
          ('Naming the cup', ComparedState.changed),
          ('Signing up on a phone', ComparedState.changed),
          ('Around the shop', ComparedState.changed),
          ('Order a cappuccino', ComparedState.changed),
          ('Empty cart', ComparedState.same),
          ('Checkout', ComparedState.same),
        ])
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
                    style: context.type.caption.copyWith(
                      color: state == ComparedState.same
                          ? colors.mut
                          : colors.ink,
                    ),
                  ),
                ),
                if (state != ComparedState.same) ...[
                  Text(
                    'events',
                    style: context.type.micro.copyWith(color: colors.mut),
                  ),
                  const Gap(FwSpacing.sm),
                ],
                StateChip(state),
              ],
            ),
          ),
      ],
    );
  }
}

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
          Row(
            children: [
              for (var (label, on) in const [
                ('side by side', true),
                ('slider', false),
                ('onion', false),
                ('blink', false),
                ('pixels', false),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: FwSpacing.md),
                  child: Text(
                    label,
                    style: context.type.micro.copyWith(
                      color: on ? colors.accentDark : colors.mut,
                    ),
                  ),
                ),
            ],
          ),
          const Gap(FwSpacing.md),
          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < 2; i++) ...[
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.panel2,
                        border: Border.all(color: colors.line),
                      ),
                    ),
                  ),
                  if (i == 0) const Gap(FwSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelToggle extends StatelessWidget {
  const _ChannelToggle({
    required this.label,
    required this.count,
    required this.on,
  });

  final String label;
  final int count;
  final bool on;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: () {},
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
              label,
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
