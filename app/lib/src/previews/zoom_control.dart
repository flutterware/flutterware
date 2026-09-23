/// The magnification capsule in the preview panel's top bar.
///
/// Its own file for the reason [StagedDevice] gives: a control that cannot be
/// reached from outside `catalog_view.dart` cannot be put in the catalog, and
/// this one is a number and a cross where everything interesting is a glyph or
/// a pixel. `demos/zoom_control.dart` renders it in every state it takes.
///
/// Where it sits says what it is. The bar's own rule is that the device
/// capsule and the axis strip say what the guest *is*, and everything right of
/// the strip acts on the picture. Magnification acts on the picture — it
/// changes nothing the demo can see, not its size, not its layout — so it
/// belongs beside the capture button and not beside the phone.
///
/// A readout that is also the way out, rather than a readout beside a
/// button: the number is the only thing worth showing at rest, and at rest it
/// is dim and does nothing. There is no third state where you want to know the
/// magnification but not be able to leave it.
library;

import 'package:material_ui/material_ui.dart';

import '../ui/design/design.dart';
import '../ui/tappable.dart';
import 'stage_zoom.dart';

/// Frame-the-selection and the scale readout, sharing one border.
///
/// Nothing here is ever hidden, which is the rule the device capsule
/// already follows: a segment goes dim rather than absent, so magnifying does
/// not reflow the bar under the pointer that was about to click something else.
///
/// Values and callbacks, not the session, so it can be one: a control that
/// needed a `CatalogSession` would need a guest, a compiler and a daemon to
/// render, which is the same as saying it could never be looked at except by
/// reloading the whole studio and squinting at a corner of the bar. Two
/// arguments cost the caller one line and buy `demos/zoom_control.dart`.
class ZoomControl extends StatelessWidget {
  const ZoomControl({
    super.key,
    required this.scale,
    required this.atRest,
    required this.onReset,
  });

  /// What the stage is drawing at. 1 is life-size.
  final double scale;

  /// Whether the stage is life-size *and* centred.
  ///
  /// Not `scale == 1`, which is what this asked before and is a way to be
  /// stuck: a stage can sit at life-size and translated, and a control that
  /// went dim there is a control that refuses to undo the only thing left to
  /// undo.
  final bool atRest;

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var zoomed = !atRest;
    return Tooltip(
      // The gesture is on the tooltip rather than written on the bar, because
      // the capsule is 22pt and the rule is a sentence. Discoverable where you
      // are already pointing when you wonder — which is at the number.
      message: zoomed
          ? 'Back to 1×  ·  ⌘-scroll or pinch to zoom, drag to pan'
          : '⌘-scroll or pinch over the preview to zoom',
      child: Tappable(
        onTap: zoomed ? onReset : null,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            color: colors.bg,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radii.radiusSmall),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Text(
                describeZoom(scale),
                style: context.type.caption.copyWith(
                  fontFamily: 'monospace',
                  color: zoomed ? colors.ink : colors.mut3,
                ),
              ),
              Icon(
                Icons.close,
                size: 11,
                color: zoomed ? colors.mut : colors.line,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The magnification as it is written on the bar.
///
/// Fewer digits as it grows, because the digits stop meaning anything: at
/// 1.4× a tenth is a visible difference and at 37× it is not, and a readout
/// that keeps two decimals through a pinch is a column of noise flickering in
/// the corner of the screen. The widths are stable enough not to shove the
/// capsule about as the number climbs.
String describeZoom(double scale) {
  if (scale <= zoomFloor) return '1×';
  if (scale < 10) return '${scale.toStringAsFixed(1)}×';
  return '${scale.round()}×';
}
