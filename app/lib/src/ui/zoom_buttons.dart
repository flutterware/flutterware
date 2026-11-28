import 'package:material_ui/material_ui.dart';

import 'tappable.dart';
import 'theme.dart';

/// A canvas's zoom control: out, the scale, in — and fit, where the canvas
/// knows how big its content is.
///
/// dev_studio's control, on the tokens. It was private to the scenario flow,
/// and the comparison's flow of the same run had no control at all: it opened
/// at 100% with the flow running off the right edge and nothing on screen
/// saying it could be zoomed.
class ZoomButtons extends StatelessWidget {
  const ZoomButtons({
    super.key,
    required this.value,
    required this.onScale,
    this.onFit,
    this.dense = false,
  });

  /// The current scale, 1 being actual size — or the whole content, where it
  /// is only ever shown fitted.
  final double value;

  /// Multiplies the scale by the factor given.
  final void Function(double factor) onScale;

  /// Puts the whole content in view. Null draws no fit button.
  final VoidCallback? onFit;

  /// Small and unframed, for a toolbar that has its own surface rather than a
  /// canvas this floats over.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(context, Icons.zoom_out, 'Zoom out', () => onScale(0.9)),
        Text(
          '${(value * 100).round()}%',
          style: dense
              ? context.type.micro.copyWith(color: colors.mut)
              : context.type.caption,
        ),
        _button(context, Icons.zoom_in, 'Zoom in', () => onScale(1.1)),
        if (onFit case var fit?)
          _button(context, Icons.fit_screen_outlined, 'Fit to view', fit),
      ],
    );
    if (dense) return buttons;
    return Container(
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(context.radii.radius),
        border: Border.all(color: colors.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: FwSpacing.xs),
      child: buttons,
    );
  }

  Widget _button(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) => Tooltip(
    message: tooltip,
    child: Tappable(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(dense ? FwSpacing.xs : FwSpacing.sm),
        child: Icon(
          icon,
          size: dense ? FwIconSize.sm : FwIconSize.lg,
          color: context.colors.mut,
        ),
      ),
    ),
  );
}
