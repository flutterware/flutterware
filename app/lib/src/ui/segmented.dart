import 'package:material_ui/material_ui.dart';

import 'tappable.dart';
import 'theme.dart';

/// One option of an [FwSegmented].
class FwSegment<T> {
  const FwSegment(this.value, this.label, {this.leading, this.tooltip});

  final T value;
  final String label;

  /// Before the label: a dot, a small icon.
  final Widget? leading;
  final String? tooltip;
}

/// One of a few, as a tray with the chosen one raised on it: *Everyone · Ana
/// · Leo*.
///
/// For a choice between views of the same thing. A row of pills reads as
/// filters that combine, and a picker hides the options this is meant to
/// show; a tray says *one of these, and this one*.
class FwSegmented<T> extends StatelessWidget {
  const FwSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.trailing,
  });

  final List<FwSegment<T>> segments;

  /// The chosen value; one no segment carries leaves none raised — the
  /// choice is in [trailing], say.
  final T? selected;
  final ValueChanged<T> onChanged;

  /// Inside the tray after the last segment: what did not fit, as a menu.
  final Widget? trailing;

  static const _height = 24.0;
  static const _inset = 2.0;
  static const _padding = FwSpacing.lg;

  /// How wide [segment] is drawn, for a caller deciding how many fit.
  static double widthOf(BuildContext context, FwSegment<Object?> segment) {
    var painter = TextPainter(
      text: TextSpan(text: segment.label, style: _style(context, true)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    var width = painter.width + 2 * _padding + _inset;
    painter.dispose();
    // Every leading thing this is given is a dot or a small icon.
    return segment.leading == null
        ? width
        : width + FwIconSize.sm + FwSpacing.sm;
  }

  /// The tray around the segments, without them.
  static const trayInset = 2 * (_inset + 1);

  static TextStyle _style(BuildContext context, bool chosen) =>
      context.type.bodySmall.copyWith(
        color: chosen ? context.colors.ink : context.colors.ink2,
        fontWeight: chosen ? FontWeight.w600 : null,
      );

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var radius = context.radii.radiusSmall;
    return Container(
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var (i, segment) in segments.indexed) ...[
            if (i > 0) const SizedBox(width: _inset),
            _segment(context, segment, radius - _inset),
          ],
          if (trailing case var trailing?) ...[
            const SizedBox(width: _inset),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, FwSegment<T> segment, double radius) {
    var colors = context.colors;
    var chosen = segment.value == selected;
    Widget face = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: _height,
      padding: const EdgeInsets.symmetric(horizontal: _padding),
      decoration: BoxDecoration(
        color: chosen ? colors.bg : null,
        borderRadius: BorderRadius.circular(radius),
        // Raised on the tray: a hairline and the smallest shadow, so the
        // chosen one reads as lifted rather than as tinted.
        boxShadow: chosen
            ? [
                BoxShadow(color: colors.line, spreadRadius: 1),
                ...context.elevation.sm,
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (segment.leading case var leading?) ...[
            leading,
            const SizedBox(width: FwSpacing.sm),
          ],
          Text(segment.label, style: _style(context, chosen), maxLines: 1),
        ],
      ),
    );
    face = Tappable(
      onTap: chosen ? null : () => onChanged(segment.value),
      borderRadius: BorderRadius.circular(radius),
      child: face,
    );
    return switch (segment.tooltip) {
      var tooltip? => Tooltip(message: tooltip, child: face),
      null => face,
    };
  }
}
