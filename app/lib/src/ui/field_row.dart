import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// A label and its value, on one line, in a column of them.
///
/// The house alternative to a two-cell table for the handful of facts a detail
/// pane states about the thing it is showing. The label column is fixed so the
/// values line up down the pane — the thing that makes a stack of these read as
/// a table rather than as sentences.
///
/// [note] is the provenance slot: where the value came from, set small and
/// muted at the end of the row. The splash panel puts the config key that won
/// the cascade there, which is the answer to "why is it that colour" and is a
/// different kind of thing from the value itself.
///
/// Extracted from the asset inspector, which had it privately and first.
class FieldRow extends StatelessWidget {
  const FieldRow(
    this.label,
    this.value, {
    super.key,
    this.note,
    this.leading,
    this.labelWidth = defaultLabelWidth,
  });

  final String label;
  final String value;

  /// Where the value came from — a config key, a file. Optional.
  final String? note;

  /// A swatch, an icon, anything that belongs immediately before the value.
  final Widget? leading;

  /// How much of the row the label takes.
  ///
  /// Narrow it in a narrow pane. At 150 in a 380px inspector every value wrapped
  /// to two lines, which is the opposite of what a fixed column is for.
  final double labelWidth;

  /// Wide enough for the longest label a half-window detail pane uses.
  static const defaultLabelWidth = 150.0;

  @override
  Widget build(BuildContext context) {
    var type = context.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: FwSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: type.bodyMuted),
          ),
          if (leading != null) ...[leading!, const Gap(FwSpacing.xs)],
          Expanded(child: SelectableText(value, style: type.body)),
          if (note != null) ...[
            const Gap(FwSpacing.md),
            Text(note!, style: type.micro.copyWith(color: context.colors.mut3)),
          ],
        ],
      ),
    );
  }
}
