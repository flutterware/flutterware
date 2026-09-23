import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// An icon with a count pinned to its top-right corner.
///
/// The chrome's way of saying *N things here want a look* without spending a
/// row on it — the explorer tab counts worktrees waiting on you, the device
/// desk counts busy devices. Zero draws the bare icon: a badge that is always
/// lit gets ignored, so the count only appears when there is one.
///
/// One widget because the pill's geometry is easy to drift — the explorer tab
/// and the desk button hand-rolling their own corners is how two counts end up
/// two sizes.
class BadgedIcon extends StatelessWidget {
  const BadgedIcon(
    this.icon, {
    super.key,
    required this.count,
    this.size,
    this.color,
  });

  final IconData icon;
  final int count;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: size, color: color),
        if (count > 0)
          Positioned(
            right: -5,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              constraints: const BoxConstraints(minWidth: 11),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(context.radii.radiusSmall),
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: context.type.micro.copyWith(
                  color: colors.onPrimary,
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
