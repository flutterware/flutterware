import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'popover.dart';
import 'popover_menu.dart';
import 'tappable.dart';

/// One choice, as a picker offers it: a bold name, a muted line under it, and
/// an optional dot.
class FwChoice<T> {
  const FwChoice({
    required this.value,
    required this.label,
    this.detail,
    this.dotColor,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// What the name does not say — `ios · iOS 26.5 · wireless`, or an entry
  /// point's description. The whole reason a picker beats a list of file names.
  final String? detail;

  final Color? dotColor;
  final bool enabled;
}

/// The house picker: a trigger that reads like a field, and a popover of rows
/// with room for a description.
///
/// Not `DropdownButton`. A Material dropdown sets its value in `titleMedium` —
/// three sizes off the ramp everything beside it uses — carries Material 3's
/// own paddings, and gives a row one line of text. This one is drawn from the
/// tokens, so it sits in a form column as the same control as the field above
/// it, and its rows have room for the detail that makes `Kiosk` and
/// `Onboarding` tellable apart.
///
/// Built on [Popover] and [PopoverMenuSurface]; the shape was ported from
/// `cms/packages/admin_ui` for the New run page and promoted here once three
/// panels had grown their own dropdowns.
///
/// The trigger fills the width it is given — cap it (the New run page's column
/// is 560, a knob's control is 340) rather than letting one word float in a
/// panel-wide box.
class FwPicker<T> extends StatelessWidget {
  const FwPicker({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
    this.empty = 'Nothing to choose from.',
  });

  final List<FwChoice<T>> choices;
  final T? selected;
  final ValueChanged<T> onChanged;

  /// Said instead of an empty box. Write a real one whenever the list can
  /// actually be empty — a device list still being read is a different thing
  /// from a project with no entry points.
  final String empty;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    if (choices.isEmpty) return Text(empty, style: context.type.bodyMuted);
    var current = choices
        .where((choice) => choice.value == selected)
        .firstOrNull;

    return Popover(
      anchor: (context, controller) => Tappable.builder(
        onTap: controller.toggle,
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.md,
            vertical: FwSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            borderRadius: BorderRadius.circular(context.radii.radius),
            border: Border.all(
              color: controller.isOpen
                  ? colors.accent
                  : hovered
                  ? colors.mut3
                  : colors.line,
            ),
          ),
          child: Row(
            children: [
              if (current?.dotColor case var color?) ...[
                Icon(Icons.circle, size: 8, color: color),
                const Gap(FwSpacing.sm),
              ],
              // Alone, the label takes the row and ellipsises when the field
              // is narrower than its words — a `Flexible(flex: 0)` beside a
              // Spacer was laid out unconstrained and overflowed by exactly
              // the words' excess. With a detail, the detail takes the room:
              // two flex children would split it, and a short detail's unused
              // half landed *after* the caret, floating it off the right edge.
              if (current?.detail case var detail?) ...[
                Flexible(
                  flex: 0,
                  child: Text(
                    current?.label ?? 'Choose…',
                    style: context.type.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Gap(FwSpacing.sm),
                Expanded(
                  child: Text(
                    detail,
                    style: context.type.caption.copyWith(color: colors.mut),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                Expanded(
                  child: Text(
                    current?.label ?? 'Choose…',
                    style: context.type.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Gap(FwSpacing.sm),
              Icon(Icons.expand_more, size: FwIconSize.md, color: colors.mut2),
            ],
          ),
        ),
      ),
      content: (context, controller) => PopoverMenuSurface(
        // The trigger's width, so the open list lines up under the field
        // rather than floating at whatever its longest row wants.
        width: controller.anchorWidth,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(FwSpacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var choice in choices)
                _PickerRow<T>(
                  choice: choice,
                  selected: choice.value == selected,
                  onTap: () {
                    controller.close();
                    onChanged(choice.value);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final FwChoice<T> choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: choice.enabled ? onTap : null,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : null,
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        child: Row(
          children: [
            if (choice.dotColor case var color?) ...[
              Icon(
                Icons.circle,
                size: 8,
                color: choice.enabled ? color : colors.mut3,
              ),
              const Gap(FwSpacing.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    choice.label,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodySmall.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? colors.accent
                          : choice.enabled
                          ? colors.ink
                          : colors.mut2,
                    ),
                  ),
                  if (choice.detail case var detail?)
                    Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.micro.copyWith(color: colors.mut),
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
