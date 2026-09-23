import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/delta/branch_delta.dart';
import 'package:flutterware_app/src/delta/change_marks.dart';
import 'package:flutterware_app/src/ui/design/design.dart';

import 'app_theme.dart';

/// The marks a tree wears for what the branch changed, and the toggle that
/// narrows it — every state each can be in, on one canvas, light and dark.

@Preview(name: 'Toggle states', group: 'Change marks', wrapper: wrapInAppTheme)
Widget changeMarksToggles() => const _Toggles();

@Preview(
  name: 'Toggle states (dark)',
  group: 'Change marks',
  wrapper: wrapInDarkTheme,
)
Widget changeMarksTogglesDark() => const _Toggles();

@Preview(name: 'Row marks', group: 'Change marks', wrapper: wrapInAppTheme)
Widget changeMarksRows() => const _Rows();

@Preview(
  name: 'Row marks (dark)',
  group: 'Change marks',
  wrapper: wrapInDarkTheme,
)
Widget changeMarksRowsDark() => const _Rows();

BranchDelta _delta({bool base = true}) => BranchDelta(
  worktreePath: '/w',
  base: base ? 'main' : null,
  mergeBase: base ? 'abcdef0123456789' : null,
  head: 'fedcba9876543210',
  readAt: DateTime(2026, 9, 2),
  files: {
    'demo/tiles.dart': const DeltaFile(
      path: 'demo/tiles.dart',
      status: ChangeStatus.modified,
      added: [LineRange(12, 14)],
    ),
    'lib/shared.dart': const DeltaFile(
      path: 'lib/shared.dart',
      status: ChangeStatus.modified,
      added: [LineRange(3, 3)],
    ),
  },
  untracked: {'demo/fresh.dart'},
  reach: {
    'demo/cards.dart': ['lib/shared.dart'],
  },
);

EntrySpan _span(String id, String file) =>
    EntrySpan(id: id, file: file, line: 10, endLine: 20);

/// One of each: a fresh entry, an edited one, one that reads a changed file,
/// and enough untouched ones to keep the reach under a quarter.
EntryChanges _changes() => EntryChanges.of([
  _span('fresh', 'demo/fresh.dart'),
  _span('tiles', 'demo/tiles.dart'),
  _span('cards', 'demo/cards.dart'),
  for (var i = 0; i < 5; i++) _span('plain$i', 'demo/plain$i.dart'),
], _delta());

/// Reach on most of the tree, which is withheld.
EntryChanges _suppressed() => EntryChanges.of([
  _span('tiles', 'demo/tiles.dart'),
  for (var i = 0; i < 3; i++) _span('r$i', 'demo/cards.dart'),
], _delta());

class _Toggles extends StatelessWidget {
  const _Toggles();

  @override
  Widget build(BuildContext context) {
    var none = EntryChanges.of([_span('a', 'demo/plain.dart')], _delta());
    var noBase = EntryChanges.of([
      _span('a', 'demo/fresh.dart'),
    ], _delta(base: false));
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'Reading the delta', null, on: false),
          _row(context, 'No base branch', noBase, on: false),
          _row(context, 'Nothing changed here', none, on: false),
          _row(context, 'Changes, off', _changes(), on: false),
          _row(context, 'Changes, on', _changes(), on: true),
          _row(context, 'Reach withheld', _suppressed(), on: false),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    EntryChanges? changes, {
    required bool on,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.md),
    child: Row(
      children: [
        ChangedOnlyButton(changes: changes, on: on, onChanged: (_) {}),
        const Gap(FwSpacing.md),
        Text(label, style: context.type.body),
      ],
    ),
  );
}

class _Rows extends StatelessWidget {
  const _Rows();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var changes = _changes();
    var rows = [
      ('Fresh tile', changes['fresh']),
      ('Edited tile', changes['tiles']),
      ('Reads a changed file', changes['cards']),
      ('Untouched', changes['plain0']),
    ];
    return Padding(
      padding: const EdgeInsets.all(FwSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var (label, change) in rows)
            SizedBox(
              height: 26,
              child: Row(
                children: [
                  SizedBox(
                    width: 180,
                    child: Text(
                      label,
                      style: context.type.bodySmall.copyWith(
                        color: changeInk(context, change?.kind) ?? colors.ink,
                      ),
                    ),
                  ),
                  if (change?.kind == EntryChangeKind.reached)
                    const ChangeDot(EntryChangeKind.reached),
                  const Gap(FwSpacing.lg),
                  Text(
                    change?.why ?? '',
                    style: context.type.caption.copyWith(color: colors.mut),
                  ),
                ],
              ),
            ),
          const Gap(FwSpacing.lg),
          Text('Folded branch dots', style: context.type.sectionLabel),
          const Gap(FwSpacing.sm),
          Row(
            children: [
              for (var kind in EntryChangeKind.values) ...[
                ChangeDot(kind),
                const Gap(FwSpacing.xs),
                Text(kind.name, style: context.type.caption),
                const Gap(FwSpacing.lg),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
