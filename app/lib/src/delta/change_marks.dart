/// How a tree paints what the branch changed: one colour per kind, a dot for
/// a folded branch, and the toggle that narrows the tree to it.
///
/// Shared by the previews and scenarios lists so the two trees say the same
/// thing the same way.
library;

import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';
import 'branch_delta.dart';

/// The row's ink for [kind], or null for an unchanged row. Green for new,
/// amber for edited; a reached row keeps its own ink and gets [ChangeDot].
Color? changeInk(BuildContext context, EntryChangeKind? kind) => switch (kind) {
  EntryChangeKind.added => context.colors.grn,
  EntryChangeKind.edited => context.colors.amber,
  EntryChangeKind.reached || null => null,
};

/// A 6px dot in the kind's colour — what a reached row carries, and what a
/// folded branch shows for the changed rows under it.
class ChangeDot extends StatelessWidget {
  const ChangeDot(this.kind, {super.key});

  final EntryChangeKind kind;

  @override
  Widget build(BuildContext context) {
    var color = switch (kind) {
      EntryChangeKind.added => context.colors.grn,
      EntryChangeKind.edited => context.colors.amber,
      EntryChangeKind.reached => context.colors.mut2,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The strongest kind among [ids]' changes, or null when none changed — what
/// a branch row shows for what is under it.
EntryChangeKind? strongestChange(EntryChanges? changes, Iterable<String> ids) {
  if (changes == null) return null;
  EntryChangeKind? strongest;
  for (var id in ids) {
    var kind = changes[id]?.kind;
    if (kind == null) continue;
    if (strongest == null || kind.index < strongest.index) strongest = kind;
  }
  return strongest;
}

/// The filter-row button that narrows the tree to what the branch changed.
///
/// Disabled with a reason while there is nothing to narrow to: no delta yet,
/// no base, or a branch that touched none of these. The tooltip carries what
/// the tint is measured against, because a colour that does not say what it
/// is relative to is a colour you stop trusting.
class ChangedOnlyButton extends StatelessWidget {
  const ChangedOnlyButton({
    super.key,
    required this.changes,
    required this.on,
    required this.onChanged,
  });

  final EntryChanges? changes;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var changes = this.changes;
    var enabled = changes != null && !changes.isEmpty;
    return IconButton(
      icon: Icon(
        Icons.difference_outlined,
        size: FwIconSize.md,
        color: on
            ? colors.accent
            : enabled
            ? colors.mut
            : colors.mut3,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      tooltip: _tooltip(changes),
      onPressed: enabled || on ? () => onChanged(!on) : null,
    );
  }

  String _tooltip(EntryChanges? changes) {
    if (changes == null) return 'Reading what this branch changed…';
    var delta = changes.delta;
    if (!delta.hasBase) return 'No base branch to compare against';
    var base = 'vs ${delta.describeBase()}';
    if (changes.isEmpty && changes.suppressedReach == 0) {
      return 'Nothing here changed on this branch · $base';
    }
    var parts = <String>[
      if (changes.count(EntryChangeKind.added) case var n when n > 0) '$n new',
      if (changes.count(EntryChangeKind.edited) case var n when n > 0)
        '$n edited',
      if (changes.count(EntryChangeKind.reached) case var n when n > 0)
        '$n reading a changed file',
    ];
    var shared = changes.suppressedReach > 0
        ? '\n${changes.suppressedReach} of ${changes.total} read a shared '
              'file that changed — not marked'
        : '';
    return '${on ? 'Showing only' : 'Show only'} what this branch changed · '
        '$base\n${parts.join(', ')}$shared';
  }
}
