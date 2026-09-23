import 'package:material_ui/material_ui.dart';

import 'design/design.dart';
import 'popover.dart';
import 'popover_menu.dart';
import 'tappable.dart';

/// One entry in a [Menu]: a [MenuItem], a [MenuDivider], or a [MenuHeader].
sealed class MenuEntry {
  const MenuEntry();
}

/// A selectable row. A null [onSelected] renders it disabled; [danger] tints it
/// red for destructive actions; [shortcut] shows a muted hint on the right.
///
/// The original also rendered a row as a real `<a>` via `url_launcher`'s `Link`,
/// so a web build got middle-click and ⌘-click for free. Dropped in the port:
/// flutterware is a desktop app, and no menu row here navigates to a URL.
class MenuItem extends MenuEntry {
  final String label;
  final IconData? icon;
  final String? shortcut;
  final VoidCallback? onSelected;
  final bool danger;

  /// The pointer entering or leaving the row — for a host that previews the
  /// row's effect somewhere else on screen while you point at it.
  final ValueChanged<bool>? onHover;

  const MenuItem(
    this.label, {
    this.icon,
    this.shortcut,
    this.onSelected,
    this.danger = false,
    this.onHover,
  });
}

/// A hairline separating groups of items.
class MenuDivider extends MenuEntry {
  const MenuDivider();
}

/// A small uppercase caption labelling a group of items.
class MenuHeader extends MenuEntry {
  final String label;
  const MenuHeader(this.label);
}

/// A dropdown action menu anchored to a trigger.
///
/// The [builder] supplies the trigger and is handed the [PopoverController] so
/// it can toggle the menu. Selecting an item closes the menu, then fires its
/// callback.
///
/// Ported from `cms/packages/admin_ui/lib/src/common/ui/menu.dart`.
class Menu extends StatelessWidget {
  final List<MenuEntry> entries;
  final Widget Function(BuildContext context, PopoverController controller)
  builder;
  final PopoverSide side;
  final PopoverAlign align;
  final double minWidth;
  final double maxWidth;

  /// See [Popover.onClose].
  final VoidCallback? onClose;

  const Menu({
    super.key,
    required this.entries,
    required this.builder,
    this.side = PopoverSide.bottom,
    this.align = PopoverAlign.start,
    this.minWidth = 180,
    this.maxWidth = 320,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Popover(
      side: side,
      align: align,
      onClose: onClose,
      anchor: builder,
      content: (context, controller) => PopoverMenuSurface(
        minWidth: minWidth,
        maxWidth: maxWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Gap(FwSpacing.xs),
              for (var entry in entries) Menu.entry(context, entry, controller),
              const Gap(FwSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }

  /// Renders one [MenuEntry] row — shared with popovers that mix entries with
  /// non-menu content.
  static Widget entry(
    BuildContext context,
    MenuEntry entry,
    PopoverController controller,
  ) {
    return switch (entry) {
      MenuItem() => _MenuItemRow(item: entry, controller: controller),
      MenuDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: FwSpacing.xs),
        child: Divider(height: 1, color: context.colors.line2),
      ),
      MenuHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(
          FwSpacing.lg,
          FwSpacing.md,
          FwSpacing.lg,
          FwSpacing.xs,
        ),
        child: Text(entry.label.toUpperCase(), style: context.type.micro),
      ),
    };
  }
}

class _MenuItemRow extends StatelessWidget {
  final MenuItem item;
  final PopoverController controller;

  const _MenuItemRow({required this.item, required this.controller});

  @override
  Widget build(BuildContext context) {
    var enabled = item.onSelected != null;

    var fg = !enabled
        ? context.colors.mut2
        : item.danger
        ? context.colors.red
        : context.colors.ink;
    var hoverFill = item.danger
        ? context.colors.red.withValues(alpha: 0.08)
        : context.colors.panel;

    return Tappable.builder(
      onTap: enabled
          ? () {
              controller.close();
              item.onSelected!();
            }
          : null,
      // Closing the menu takes this MouseRegion with it and no exit event
      // follows, so a host previewing the hover pairs this with [Menu.onClose].
      onHover: item.onHover,
      builder: (context, hover) => Container(
        color: enabled && hover ? hoverFill : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: 9,
        ),
        child: Row(
          children: [
            if (item.icon != null) ...[
              Icon(item.icon, size: FwIconSize.md, color: fg),
              const Gap(FwSpacing.md),
            ],
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.body.copyWith(color: fg),
              ),
            ),
            if (item.shortcut != null) ...[
              const Gap(FwSpacing.lg),
              Text(item.shortcut!, style: context.type.caption),
            ],
          ],
        ),
      ),
    );
  }
}
