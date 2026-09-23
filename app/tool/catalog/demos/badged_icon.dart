import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/badged_icon.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'command_palette.dart' show wrapInAppTheme;

/// The chrome's count-on-an-icon, at the counts it actually shows.
///
/// Zero is a state, not an omission: the badge disappearing entirely is the
/// design — a device desk with nothing busy and an explorer with nothing
/// waiting both read as a plain icon. Two digits is the stretch case; the pill
/// widens rather than the digits shrinking.
@Preview(name: 'Badged icon', group: 'Chrome', wrapper: wrapInAppTheme)
Widget badgedIconStates() => const _Strip(
  children: [
    _Labelled('0 — bare', BadgedIcon(Icons.devices_outlined, count: 0)),
    _Labelled('1', BadgedIcon(Icons.devices_outlined, count: 1)),
    _Labelled('3', BadgedIcon(Icons.account_tree_outlined, count: 3)),
    _Labelled('12', BadgedIcon(Icons.devices_outlined, count: 12)),
  ],
);

class _Strip extends StatelessWidget {
  const _Strip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var child in children)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xxl),
              child: child,
            ),
        ],
      ),
    ),
  );
}

class _Labelled extends StatelessWidget {
  const _Labelled(this.caption, this.child);

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      const Gap(FwSpacing.lg),
      Text(
        caption,
        style: context.type.micro.copyWith(color: context.colors.mut3),
      ),
    ],
  );
}
