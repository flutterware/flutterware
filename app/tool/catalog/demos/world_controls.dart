import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/browser_frame.dart';
import 'package:flutterware_app/src/ui/chip.dart';
import 'package:flutterware_app/src/ui/segmented.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'app_theme.dart';

/// The controls the open world is drawn with that the studio had no copy
/// of: the switch between everyone and one person, the chip that says what
/// caused a message, and the browser a desktop person's app stands in.

@Preview(name: 'Segmented', group: 'Worlds', wrapper: wrapInAppTheme)
Widget segmented() => const _Segmented();

@Preview(name: 'Segmented · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget segmentedDark() => const _Segmented();

@Preview(name: 'Chip', group: 'Worlds', wrapper: wrapInAppTheme)
Widget chip() => const _Chips();

@Preview(name: 'Chip · dark', group: 'Worlds', wrapper: wrapInDarkTheme)
Widget chipDark() => const _Chips();

@Preview(name: 'Browser frame', group: 'Worlds', wrapper: wrapInAppTheme)
Widget browserFrame() => const _Browser();

class _Segmented extends StatefulWidget {
  const _Segmented();

  @override
  State<_Segmented> createState() => _SegmentedState();
}

class _SegmentedState extends State<_Segmented> {
  String? _chosen;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    Widget dot(int i) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: colors.person(i),
        shape: BoxShape.circle,
      ),
    );
    return ColoredBox(
      color: colors.bg,
      child: Padding(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FwSegmented<String?>(
              segments: [
                FwSegment(
                  null,
                  'Everyone',
                  leading: Icon(
                    Icons.grid_view,
                    size: FwIconSize.sm,
                    color: colors.ink2,
                  ),
                ),
                for (var (i, name) in ['Ana', 'Cleo', 'Leo', 'Mia'].indexed)
                  FwSegment(name, name, leading: dot(i)),
              ],
              selected: _chosen,
              onChanged: (chosen) => setState(() => _chosen = chosen),
              trailing: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
                child: Text(
                  '+5',
                  style: context.type.bodySmall.copyWith(color: colors.ink2),
                ),
              ),
            ),
            const SizedBox(height: FwSpacing.lg),
            FwSegmented<bool>(
              segments: const [
                FwSegment(false, 'Mail'),
                FwSegment(true, 'Page'),
              ],
              selected: true,
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.bg,
    child: const Padding(
      padding: EdgeInsets.all(FwSpacing.xxl),
      child: Wrap(
        spacing: FwSpacing.md,
        runSpacing: FwSpacing.md,
        children: [
          FwChip(
            'action "The regulars order"',
            icon: Icons.subdirectory_arrow_right,
            mono: true,
          ),
          FwChip(
            'Leo: tap "Order a flat white"',
            icon: Icons.subdirectory_arrow_right,
            mono: true,
          ),
          FwChip('In words', icon: Icons.label_outline),
        ],
      ),
    ),
  );
}

class _Browser extends StatelessWidget {
  const _Browser();

  static const _screen = Size(1280, 800);

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.panel,
    child: Padding(
      padding: const EdgeInsets.all(FwSpacing.xxl),
      child: FittedBox(
        child: BrowserFrame(
          screen: _screen,
          title: 'Pickup · Counter',
          titleColor: const Color(0xFF8B4A1F),
          host: 'lab.localhost',
          path: '/orders/o3',
          onBack: () {},
          onGo: (_) {},
          child: const ColoredBox(
            color: Color(0xFFFDF6F3),
            child: Center(child: Text('The app')),
          ),
        ),
      ),
    ),
  );
}
