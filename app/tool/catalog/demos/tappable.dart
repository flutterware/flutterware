import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware_app/src/ui/tappable.dart';
import 'package:flutterware_app/src/ui/theme.dart';

import 'shell.dart';

/// Every state the house tap target has, next to each other.
///
/// This one has to be driven by hand. Hover, press and focus are exactly
/// the states that leave nothing behind for a screenshot to catch or a drive
/// step to read — there is no hover verb in either harness — so the alternative
/// to a page you move a pointer across is that nobody ever sees four of the
/// primitive's five states at once. Move the mouse down the column, hold a
/// press, then Tab through it.
@Preview(name: 'Tappable', group: 'Controls', wrapper: wrapInApp)
Widget tappable() => const _Tappables();

class _Tappables extends StatelessWidget {
  const _Tappables();

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: ListView(
        padding: const EdgeInsets.all(FwSpacing.xxl),
        children: [
          _Case(
            'The four washes',
            'overlay is the default and is neutral ink; onFill is white, for a '
                'control laid over a dark or accent fill; link is accent-tinted; '
                'none paints nothing.',
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chip('overlay', feedback: TapFeedback.overlay),
                const Gap(FwSpacing.md),
                _Chip(
                  'onFill',
                  feedback: TapFeedback.onFill,
                  fill: colors.primary,
                  ink: colors.onPrimary,
                ),
                const Gap(FwSpacing.md),
                _Chip('link', feedback: TapFeedback.link),
                const Gap(FwSpacing.md),
                _Chip('none', feedback: TapFeedback.none),
              ],
            ),
          ),
          _Case(
            'Pressed is deeper than hovered',
            'Hold the press: the wash goes from hoverOverlay to pressedOverlay '
                'and back on release, so a click that ran nothing visible still '
                'said it landed.',
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chip('Press and hold'),
                const Gap(FwSpacing.md),
                _Chip('Disabled', onTap: null),
              ],
            ),
          ),
          _Case(
            'A label inside a SelectionArea',
            'The bug this fixed: a Text under a selection registrar wraps '
                'itself in a text-cursor MouseRegion below the button. Hover '
                'both — the left keeps the click cursor, the right is the '
                'I-beam it used to be, and drag-selects its own words.',
            SelectionArea(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Chip('Delete'),
                  const Gap(FwSpacing.md),
                  _Chip('Delete', selectable: true),
                  const Gap(FwSpacing.xxl),
                  Text(
                    'selectable prose, for the drag to run into',
                    style: context.type.caption.copyWith(color: colors.mut2),
                  ),
                ],
              ),
            ),
          ),
          _Case(
            'Focus is keyboard-only',
            'Tab into the row: the ring appears. Click one instead and it does '
                'not — a pointer never takes focus, which is what keeps the '
                'ring meaningful. Enter or Space on a focused one taps it.',
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chip('First'),
                const Gap(FwSpacing.md),
                _Chip('Second'),
                const Gap(FwSpacing.md),
                _Chip('Skipped', focusable: false),
              ],
            ),
          ),
          _Case(
            'The builder draws its own',
            'Tappable.builder gets the flag and paints nothing itself, because '
                'a caller that swaps a colour does not want a second wash under '
                'it. Passing feedback: overlay hands the job back.',
            Tappable.builder(
              onTap: () {},
              builder: (context, hovered) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: FwSpacing.lg,
                  vertical: FwSpacing.sm,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: hovered ? colors.accent : colors.line,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  hovered ? 'a brighter rail' : 'a rail',
                  style: context.type.body,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
    this.label, {
    this.feedback = TapFeedback.overlay,
    this.fill,
    this.ink,
    this.selectable = false,
    this.focusable = true,
    this.onTap = _noop,
  });

  static void _noop() {}

  final String label;
  final TapFeedback feedback;
  final Color? fill;
  final Color? ink;
  final bool selectable;
  final bool focusable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var radius = BorderRadius.circular(context.radii.radius);
    return Tappable(
      onTap: onTap,
      feedback: feedback,
      borderRadius: radius,
      selectableChild: selectable,
      focusable: focusable,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FwSpacing.lg,
          vertical: FwSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.all(color: colors.line),
        ),
        child: Text(
          label,
          style: context.type.caption.copyWith(
            color: onTap == null ? colors.mut3 : (ink ?? colors.ink),
          ),
        ),
      ),
    );
  }
}

class _Case extends StatelessWidget {
  const _Case(this.title, this.note, this.child);

  final String title;
  final String note;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FwSpacing.xxxl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.type.sectionLabel),
        const Gap(FwSpacing.xxs),
        Text(
          note,
          style: context.type.caption.copyWith(color: context.colors.mut2),
        ),
        const Gap(FwSpacing.md),
        Align(alignment: Alignment.centerLeft, child: child),
      ],
    ),
  );
}
