import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';

/// The filtering both worktree menus share — the switcher in the address bar
/// and the opener in the band. Each menu keeps its own rows and its own idea
/// of what picking means; what is common is how a query narrows the list, how
/// the match is lit, and what the field looks like.

/// Where a query was found: which of the names a row offered, and the run of
/// characters inside it, so the row can light exactly what matched.
class FilterMatch {
  const FilterMatch(this.field, this.start, this.end);

  /// Index into the candidate list handed to [matchWorktreeFilter].
  final int field;

  final int start;
  final int end;
}

/// Case-insensitive substring over the names a row is known by, first hit
/// wins. Null candidates are allowed — a detached worktree has no branch —
/// and a null return means the row leaves the list.
///
/// Substring rather than the palette's fuzzy scoring on purpose: a dozen
/// worktrees is not a corpus, and with rows this similar (`claude/…` ×10) a
/// fuzzy match lights coincidences faster than it finds checkouts.
FilterMatch? matchWorktreeFilter(String query, List<String?> candidates) {
  var needle = query.trim().toLowerCase();
  for (var i = 0; i < candidates.length; i++) {
    var candidate = candidates[i];
    if (candidate == null) continue;
    var at = candidate.toLowerCase().indexOf(needle);
    if (at >= 0) return FilterMatch(i, at, at + needle.length);
  }
  return null;
}

/// [text], with the matched run under the amber wash every search match in
/// the app wears (see the JSON view). Plain [Text] when the match is in some
/// other field — or nowhere — so an unfiltered list costs nothing.
Widget matchedName(
  BuildContext context,
  String text,
  TextStyle style, {
  FilterMatch? match,
  int field = 0,
}) {
  if (match == null || match.field != field) return Text(text, style: style);
  var wash = context.colors.amber.withValues(alpha: 0.3);
  return Text.rich(
    TextSpan(
      style: style,
      children: [
        TextSpan(text: text.substring(0, match.start)),
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(backgroundColor: wash),
        ),
        TextSpan(text: text.substring(match.end)),
      ],
    ),
  );
}

/// The field itself. The caller owns the controller and focus node because it
/// owns the menu: it clears on open, focuses once the overlay exists, and
/// decides what ↵ picks.
class WorktreeFilterField extends StatelessWidget {
  const WorktreeFilterField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.radii.radius),
      borderSide: BorderSide(color: color),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.md,
      ),
      child: SizedBox(
        width: 260,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: context.type.bodySmall,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colors.panel,
            hintText: 'Filter, ↵ picks the first',
            hintStyle: context.type.bodySmall.copyWith(color: colors.mut3),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.md,
              vertical: FwSpacing.sm,
            ),
            border: border(colors.line),
            enabledBorder: border(colors.line),
            focusedBorder: border(colors.accent),
          ),
        ),
      ),
    );
  }
}

/// What a filtered-empty menu says, the same in both menus.
class NoWorktreeMatches extends StatelessWidget {
  const NoWorktreeMatches({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: FwSpacing.md,
      vertical: FwSpacing.sm,
    ),
    child: Text(
      'No worktree matches.',
      style: context.type.caption.copyWith(color: context.colors.mut3),
    ),
  );
}
