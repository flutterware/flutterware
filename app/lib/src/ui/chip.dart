import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// A short fact set apart from the text around it: what caused a message
/// (`↳ action "Rush hour"`), a kind, a state.
///
/// Bordered on the panel grey, at the caption's size. [mono] for what is
/// quoted from a machine — a step, an id — rather than said in words.
class FwChip extends StatelessWidget {
  const FwChip(
    this.label, {
    super.key,
    this.icon,
    this.mono = false,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final bool mono;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var type = context.type;
    var style = mono
        ? type.mono.copyWith(
            fontSize: type.caption.fontSize,
            color: colors.ink2,
          )
        : type.caption.copyWith(color: colors.ink2);
    Widget chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.sm,
        vertical: FwSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(context.radii.micro),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case var icon?) ...[
            Icon(icon, size: FwIconSize.xs, color: colors.mut),
            const SizedBox(width: FwSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return switch (tooltip) {
      var tooltip? => Tooltip(message: tooltip, child: chip),
      null => chip,
    };
  }
}
