import 'package:material_ui/material_ui.dart';

import 'design/design.dart';

/// The floating card a popover menu sits in — the elevated, rounded, clipped
/// surface shared by the action [Menu] and anything else that drops down.
///
/// A popover loosens to the whole screen, so the content must declare its own
/// width. Two modes:
/// - pass [width] for a fixed surface, or to match the trigger via
///   `controller.anchorWidth`;
/// - leave [width] null to size to the content between [minWidth] and [maxWidth]
///   (an action menu) — rows are sized to the widest via [IntrinsicWidth].
///
/// Ported from `cms/packages/admin_ui/lib/src/common/ui/popover_menu.dart`.
class PopoverMenuSurface extends StatelessWidget {
  final double? width;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;
  final Widget child;

  const PopoverMenuSurface({
    super.key,
    this.width,
    this.minWidth = 0,
    this.maxWidth = double.infinity,
    this.maxHeight = 360,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    Widget inner;
    if (width != null) {
      inner = SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: child,
        ),
      );
    } else {
      inner = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minWidth,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        ),
        child: IntrinsicWidth(child: child),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        boxShadow: context.elevation.md,
      ),
      child: Material(
        elevation: 0,
        borderRadius: BorderRadius.circular(context.radii.radiusLarge),
        clipBehavior: Clip.antiAlias,
        child: inner,
      ),
    );
  }
}
