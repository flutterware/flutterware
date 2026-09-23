import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'menu.dart';
import 'popover.dart';
import 'tappable.dart';
import 'theme.dart';

/// A primary action with its alternatives behind an attached chevron.
///
/// A click on the primary part runs [onPressed], the chevron opens a standard
/// [Menu] of [entries] — the same rows as every other dropdown in the app. For
/// the bar with one frequent action worth the room and variants that are not:
/// hot reload over hot restart, copy over save-as.
///
/// Two shapes: the default is a bordered capsule with a labelled primary, for
/// a header where the action is the subject of the row; [FwSplitButton.icon] is
/// two bare icons, for a toolbar where the whole affordance is a glyph.
///
/// A null [onPressed] disables the primary segment; the chevron follows the
/// entries and goes quiet only when none of them is selectable, so a menu of
/// alternatives can outlive a primary that is momentarily unavailable.
class FwSplitButton extends StatelessWidget {
  const FwSplitButton({
    super.key,
    required String this.label,
    this.icon,
    this.onPressed,
    this.entries = const [],
    this.tooltip,
    this.menuTooltip = 'More actions',
    this.onMenuClose,
  });

  /// The borderless shape: a bare icon and a chevron, sized for a toolbar.
  const FwSplitButton.icon({
    super.key,
    required IconData this.icon,
    this.onPressed,
    this.entries = const [],
    this.tooltip,
    this.menuTooltip = 'More actions',
    this.onMenuClose,
  }) : label = null;

  /// The primary segment's word. Null is the icon-only shape.
  final String? label;

  final IconData? icon;

  /// Awaited nowhere and guarded nowhere — like [MenuItem.onSelected], this is
  /// the caller's action. Null disables the primary segment.
  final VoidCallback? onPressed;

  /// The dropdown's rows. A [MenuItem] with a null `onSelected` renders
  /// disabled in place, so a variant that is momentarily unavailable stays
  /// visible rather than vanishing.
  final List<MenuEntry> entries;

  /// The primary segment's tooltip.
  final String? tooltip;

  /// The chevron's tooltip, since a bare `⌄` says nothing about what it holds.
  final String menuTooltip;

  /// See [Menu.onClose] — for a host whose rows preview their effect on hover.
  final VoidCallback? onMenuClose;

  bool get _menuEnabled =>
      entries.any((entry) => entry is MenuItem && entry.onSelected != null);

  Widget _withTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);

  Widget _menu(Widget Function(PopoverController controller) trigger) => Menu(
    entries: entries,
    align: PopoverAlign.end,
    onClose: onMenuClose,
    builder: (context, controller) =>
        _withTooltip(menuTooltip, trigger(controller)),
  );

  @override
  Widget build(BuildContext context) {
    return label == null ? _icons(context) : _capsule(context);
  }

  Widget _capsule(BuildContext context) {
    var colors = context.colors;
    var enabled = onPressed != null;

    Widget segment({
      required bool enabled,
      required VoidCallback? onTap,
      required Widget child,
    }) {
      return Tappable(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: FwSpacing.sm,
            vertical: 5,
          ),
          color: colors.bg,
          child: child,
        ),
      );
    }

    // The border is a **foreground** decoration, and it has to be. A
    // `Container` paints its `decoration` behind the child, and `Border.all`
    // strokes inside the clip path — so the segments' opaque fill lands on top
    // of the border and eats it, leaving the corners reading as a square block
    // poking out of a rounded outline. In front, the stroke is the last thing
    // painted and the corner is whole.
    var shape = BorderRadius.circular(context.radii.radiusSmall);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: shape),
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        border: Border.all(color: colors.line),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _withTooltip(
              tooltip,
              segment(
                enabled: enabled,
                onTap: onPressed,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        size: FwIconSize.sm,
                        color: enabled ? colors.accent : colors.mut3,
                      ),
                      const Gap(FwSpacing.xs),
                    ],
                    Text(
                      label!,
                      style: context.type.bodySmall.copyWith(
                        color: enabled ? colors.accent : colors.mut3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: colors.line),
            _menu(
              (controller) => segment(
                enabled: _menuEnabled,
                onTap: controller.toggle,
                child: Icon(
                  Icons.expand_more,
                  size: FwIconSize.sm,
                  color: _menuEnabled ? colors.accent : colors.mut3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icons(BuildContext context) {
    var colors = context.colors;
    var enabled = onPressed != null;

    Widget glyph({
      required bool enabled,
      required VoidCallback? onTap,
      required IconData icon,
      required double size,
      required double width,
    }) {
      return Tappable(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Container(
          width: width,
          height: 24,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: size,
            color: enabled ? colors.ink : colors.mut3,
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _withTooltip(
          tooltip,
          glyph(
            enabled: enabled,
            onTap: onPressed,
            icon: icon!,
            size: 15,
            width: 24,
          ),
        ),
        _menu(
          (controller) => glyph(
            enabled: _menuEnabled,
            onTap: controller.toggle,
            icon: Icons.expand_more,
            size: 14,
            width: 16,
          ),
        ),
      ],
    );
  }
}
