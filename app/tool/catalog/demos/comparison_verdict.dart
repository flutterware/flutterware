import 'package:flutterware/comparison_report.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/comparison/ui/state_chip.dart';
import 'package:flutterware_app/src/comparison/ui/verdict.dart';
import 'package:flutterware_app/src/ui/count_badge.dart';
import 'package:flutterware_app/src/ui/filter_bar.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// Four ways the Changes screen could say what a branch did, side by side.
///
/// Drawn to be chosen between rather than shipped. Every one is built out of
/// what the studio already has — `StateChip`, `CountBadge`, `FwFilterBar`, the
/// events pane's channel chip — because the question is composition, not new
/// components.
@Preview(
  name: 'Comparison verdict · options',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictOptions() => const _Options();

@Preview(
  name: 'Comparison verdict · options · dark',
  group: 'Comparison',
  wrapper: wrapInDarkTheme,
)
Widget verdictOptionsDark() => const _Options();

/// The studio's own filter bar, alone, so its behaviour in a narrow pane can
/// be seen rather than inferred.
@Preview(
  name: 'Comparison verdict · C alone',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictOptionC() =>
    const Padding(padding: EdgeInsets.all(FwSpacing.md), child: _OptionC());

/// The recommendation, alone.
@Preview(
  name: 'Comparison verdict · E alone',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictOptionE() =>
    const Padding(padding: EdgeInsets.all(FwSpacing.md), child: _OptionE());

/// How the summary line declines: all of them, most of them, and neither.
@Preview(
  name: 'Comparison verdict · how the line declines',
  group: 'Comparison',
  wrapper: wrapInAppTheme,
)
Widget verdictDeclension() => const _Declension();

class _Declension extends StatelessWidget {
  const _Declension();

  static ComparedItem _autofill(String hash) => ComparedItem.of(
    id: 'autofill-$hash',
    baseEvents: [
      {
        'channel': 'system',
        'title': 'flutter/textinput TextInput.setClient',
        'data': {
          'arguments': [
            1,
            {
              'autofill': {'uniqueIdentifier': 'EditableText-$hash'},
            },
          ],
        },
      },
    ],
    headEvents: [
      {
        'channel': 'system',
        'title': 'flutter/textinput TextInput.setClient',
        'data': {
          'arguments': [
            1,
            {
              'autofill': {'uniqueIdentifier': 'EditableText-'},
            },
          ],
        },
      },
    ],
  );

  static ComparedItem _other(int i) => ComparedItem.of(
    id: 'other-$i',
    baseTexts: const ['Save'],
    headTexts: ['Pay $i'],
  );

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        _Case(
          'all of them — one change, and nothing else',
          ComparisonVerdict(
            findings: [for (var i = 0; i < 4; i++) _autofill('$i')],
            unit: 'step',
          ),
        ),
        _Case(
          'most of them — one change, and a few others worth reading',
          ComparisonVerdict(
            findings: [for (var i = 0; i < 3; i++) _autofill('$i'), _other(0)],
            unit: 'step',
          ),
        ),
        _Case(
          'neither — no summary, because there is none to give',
          ComparisonVerdict(
            findings: [
              for (var i = 0; i < 2; i++) _autofill('$i'),
              for (var i = 0; i < 3; i++) _other(i),
            ],
            unit: 'step',
          ),
        ),
      ],
    ),
  );
}

class _Options extends StatelessWidget {
  const _Options();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: const [
        _Case(
          'A · state chips only — today’s vocabulary, nothing new',
          _OptionA(),
        ),
        _Case('B · counts by channel, as toggles', _OptionB()),
        _Case(
          'C · FwFilterBar — pills pick the half, toggles narrow',
          _OptionC(),
        ),
        _Case('D · one sentence, folded', _OptionD()),
        _Case('E · the synthesis — D says it, B is clickable', _OptionE()),
      ],
    ),
  );
}

class _Case extends StatelessWidget {
  const _Case(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.type.micro.copyWith(color: context.colors.mut),
        ),
        const Gap(FwSpacing.sm),
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.panel,
            border: Border.all(color: context.colors.line),
            borderRadius: BorderRadius.circular(context.radii.radius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(FwSpacing.md),
            child: child,
          ),
        ),
      ],
    ),
  );
}

/// The chips the comparison already draws on every row, promoted to a header.
class _OptionA extends StatelessWidget {
  const _OptionA();

  @override
  Widget build(BuildContext context) => const Wrap(
    spacing: FwSpacing.sm,
    runSpacing: FwSpacing.xs,
    children: [
      StateChip(ComparedState.changed, count: 7),
      StateChip(ComparedState.added, count: 2),
      StateChip(ComparedState.same, count: 36),
      StateChip(ComparedState.skipped, count: 156),
    ],
  );
}

/// The events pane's channel chip, asked the comparison's question.
class _OptionB extends StatelessWidget {
  const _OptionB();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Wrap(
        spacing: FwSpacing.sm,
        runSpacing: FwSpacing.xs,
        children: [
          _ChannelToggle(label: 'pixels', count: 0, on: false),
          _ChannelToggle(label: 'tree', count: 0, on: false),
          _ChannelToggle(label: 'texts', count: 0, on: false),
          _ChannelToggle(label: 'events', count: 7, on: true),
          _ChannelToggle(label: 'system', count: 11, on: false),
        ],
      ),
      const Gap(FwSpacing.sm),
      Text(
        '7 findings · 1 new',
        style: context.type.caption.copyWith(color: context.colors.mut),
      ),
    ],
  );
}

/// The bar the run cockpit's logs and the server panel's lists already speak.
class _OptionC extends StatelessWidget {
  const _OptionC();

  @override
  Widget build(BuildContext context) => FwFilterBar(
    pills: [
      ('All', true, () {}),
      ('Previews', false, () {}),
      ('Scenarios', false, () {}),
    ],
    toggles: [('new', false, () {}), ('system', false, () {})],
    count: '9 of 201',
    hint: 'Filter findings',
    onSearch: (_) {},
  );
}

/// The fold, read out loud.
class _OptionD extends StatelessWidget {
  const _OptionD();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '9 findings',
                style: TextStyle(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: ' · 7 changed, 2 added · ',
                style: TextStyle(color: colors.mut),
              ),
              TextSpan(
                text: '1 new',
                style: TextStyle(color: colors.amber),
              ),
            ],
          ),
          style: context.type.body,
        ),
        const Gap(FwSpacing.xs),
        Text(
          'nothing moved on pixels, tree or texts',
          style: context.type.caption.copyWith(color: colors.mut),
        ),
        const Gap(FwSpacing.sm),
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors.mut3,
                shape: BoxShape.circle,
              ),
            ),
            const Gap(FwSpacing.sm),
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

/// D's sentence with B's controls, and the hierarchy put back.
///
/// Three things the first four each got half right. The counts are the
/// verdict, so they lead. The channels that *fired* are chips, because a
/// reader wants to click them; the channels that did not are a sentence,
/// because three chips reading zero spend three quarters of the strip saying
/// nothing — and the sentence says it better, since "nothing moved on pixels,
/// tree or texts" is the strongest line the comparison can print and no chip
/// can say it. `system` sits *inside* the events chip's group rather than
/// beside it, because it is a subchannel and drawing it as a sibling makes a
/// hierarchy read as a list.
class _OptionE extends StatelessWidget {
  const _OptionE();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `Wrap`, not `Row`, and the files tab's strip learned this first:
        // a Row of fixed chips overflows the moment the pane is narrow, and
        // this pane is sometimes a 320px column beside a detail. Measured
        // here — at 430px the Row threw two overflows before this changed.
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
        // Two facts, two lines. Joined by a `·` they read as one list, which
        // is what the first draft did and what rendering it exposed: the
        // quiet channels are a statement about coverage and the shape is a
        // statement about noise, and they have nothing to do with each other.
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
