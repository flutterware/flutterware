// A single choice, made from a short list that is all on screen at once.
//
// [FwPicker] is the control for a choice out of many, or one whose options are
// not worth the room; this is for the other kind — two to five options where
// seeing them together *is* the explanation. The scene's "where does this go"
// is the case it was built for: a folder list of three where one row has a
// text field under it, which a dropdown cannot hold and a segmented control
// has no room for.
//
// The rows take [FwChoice], the same description [FwPicker] takes, so a list
// that outgrows the room becomes a picker by changing the widget.
import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'tappable.dart';

/// A vertical list of choices, one selected, each a name over a caption.
///
/// [below] is the row's own extra: the control that only means anything while
/// that row is chosen — a path field under "A new folder…". It is built only
/// for the selected row, because an unselected row's field is a second answer
/// to a question that has one.
class FwChoiceList<T> extends StatelessWidget {
  const FwChoiceList({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
    this.below,
  });

  final List<FwChoiceRow<T>> choices;
  final T? selected;
  final ValueChanged<T> onChanged;

  /// What hangs under the selected row, indented to its text.
  final Widget Function(BuildContext context, T value)? below;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var choice in choices) ...[
        _Row<T>(
          choice: choice,
          selected: choice.value == selected,
          onTap: () => onChanged(choice.value),
        ),
        if (choice.value == selected && below != null)
          Padding(
            padding: const EdgeInsets.only(
              left: FwIconSize.md + FwSpacing.sm,
              bottom: FwSpacing.xs,
            ),
            child: below!(context, choice.value),
          ),
      ],
    ],
  );
}

/// One row: what it is, and what the name does not say.
class FwChoiceRow<T> {
  const FwChoiceRow({
    required this.value,
    required this.label,
    this.detail,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// The line under the name — a path, a count, whatever makes two rows
  /// tellable apart. Where a picker puts this beside the label, a list has
  /// the width to give it a line of its own.
  final String? detail;

  final bool enabled;
}

class _Row<T> extends StatelessWidget {
  const _Row({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final FwChoiceRow<T> choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    return Tappable(
      key: ValueKey('choice:${choice.value}'),
      onTap: choice.enabled ? onTap : null,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.xs,
          vertical: 6,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: FwSpacing.sm,
          children: [
            // The dot is the whole of the selected state: a filled row would
            // fight the field that hangs under it.
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: FwIconSize.md,
              color: choice.enabled
                  ? (selected ? colors.accent : colors.mut2)
                  : colors.mut3,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    choice.label,
                    style: choice.enabled
                        ? type.body
                        : type.body.copyWith(color: colors.mut2),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (choice.detail case var detail?)
                    Text(
                      detail,
                      style: type.caption.copyWith(color: colors.mut2),
                      overflow: TextOverflow.ellipsis,
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
