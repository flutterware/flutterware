/// The silhouette for an iPhone `device_frame` has no artwork for.
///
/// The vendored bodies stop at the iPhone 13 generation, and everything after
/// it used to fall through to `DeviceInfo.genericPhone` — a lozenge with an
/// 80pt forehead, a 60pt chin and a camera dot punched above the glass. That is
/// a 2016 Android reference phone, and reading it as an iPhone 16 is the whole
/// complaint: the outline is half of what says *iPhone*.
///
/// So this draws one, from the [Device]'s own numbers rather than from a second
/// set of measurements: an edge-to-edge screen at the device's size, a thin
/// uniform surround, and the Dynamic Island as a hole in the screen — a hole,
/// not a painted pill, so it is the body showing through and nothing renders
/// over it.
library;

import 'package:device_frame/device_frame.dart' hide Devices;
import 'package:flutter/widgets.dart';

import 'devices.dart';

/// A modern iPhone's body, sized to [device].
///
/// Takes the device upright, like everything else that hands a body to
/// `DeviceFrame`: the artwork is portrait and the widget turns it.
DeviceInfo islandPhoneFrame(Device device) {
  var body = Rect.fromLTWH(
    _buttonDepth,
    0,
    device.width + 2 * (_bezel + _band),
    device.height + 2 * (_bezel + _band),
  );
  var screen = Rect.fromLTWH(
    body.left + _bezel + _band,
    body.top + _bezel + _band,
    device.width,
    device.height,
  );

  // The island is a subpath *inside* the screen rect under an even-odd fill,
  // which makes it a hole in the clip rather than a shape drawn on top: the
  // black under it is the body, exactly like the notch the hand-drawn iPhone 13
  // cuts out of its own screen path.
  var island = Rect.fromCenter(
    center: Offset(
      screen.center.dx,
      screen.top + _islandTop + _island.height / 2,
    ),
    width: _island.width,
    height: _island.height,
  );
  var screenPath = Path()
    ..addRRect(
      RRect.fromRectAndRadius(screen, const Radius.circular(_screenRadius)),
    )
    ..addRRect(
      RRect.fromRectAndRadius(island, Radius.circular(_island.height / 2)),
    )
    ..fillType = PathFillType.evenOdd;

  var rotated = device.rotated();
  return DeviceInfo(
    identifier: DeviceIdentifier(
      TargetPlatform.iOS,
      DeviceType.phone,
      device.id,
    ),
    name: device.label,
    pixelRatio: device.pixelRatio,
    frameSize: Size(body.width + 2 * _buttonDepth, body.height),
    screenSize: Size(device.width, device.height),
    safeAreas: EdgeInsets.fromLTRB(
      device.insetLeft,
      device.insetTop,
      device.insetRight,
      device.insetBottom,
    ),
    // Non-null is what `canRotate` is, and the generic builder's doc names the
    // trap: left to its default this would claim it rotates and then draw
    // landscape with no island and no home indicator at all.
    rotatedSafeAreas: EdgeInsets.fromLTRB(
      rotated.insetLeft,
      rotated.insetTop,
      rotated.insetRight,
      rotated.insetBottom,
    ),
    framePainter: IslandPhoneFramePainter(body: body),
    screenPath: screenPath,
  );
}

/// The outline of the body [islandPhoneFrame] draws for [device], in the
/// frame's own coordinates — for a ring drawn around the phone, which has to
/// follow the metal rather than the frame's bounding box.
RRect islandBodyOutline(Device device) => RRect.fromRectAndRadius(
  Rect.fromLTWH(
    _buttonDepth,
    0,
    device.width + 2 * (_bezel + _band),
    device.height + 2 * (_bezel + _band),
  ),
  const Radius.circular(_screenRadius + _bezel + _band),
);

/// Paints the body [islandPhoneFrame] laid out: the buttons, the metal edge,
/// and the black the screen's island hole shows through.
class IslandPhoneFramePainter extends CustomPainter {
  const IslandPhoneFramePainter({required this.body});

  /// The phone itself, inside the frame — which is wider by [_buttonDepth] on
  /// each side, because the buttons stand proud of it.
  final Rect body;

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()..style = PaintingStyle.fill;

    // Under the body, so only the half that stands proud of the edge shows.
    for (var button in _leftButtons) {
      _button(canvas, paint, body.left, button);
    }
    for (var button in _rightButtons) {
      _button(canvas, paint, body.right, button);
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body,
        const Radius.circular(_screenRadius + _bezel + _band),
      ),
      paint..color = GenericPhoneFramePainter.defaultOuterBodyColor,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        body.deflate(_band),
        const Radius.circular(_screenRadius + _bezel),
      ),
      paint..color = GenericPhoneFramePainter.defaultInnerBodyColor,
    );
  }

  void _button(
    Canvas canvas,
    Paint paint,
    double edge,
    (double, double) button,
  ) {
    var (top, length) = button;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          edge - _buttonDepth,
          body.top + top,
          _buttonDepth * 2,
          length,
        ),
        const Radius.circular(_buttonDepth),
      ),
      paint..color = GenericPhoneFramePainter.defaultButtonColor,
    );
  }

  @override
  bool shouldRepaint(covariant IslandPhoneFramePainter oldDelegate) =>
      oldDelegate.body != body;
}

/// The black glass between the picture and the metal.
///
/// A drawing choice rather than a measurement — the real border is under 2mm,
/// which at preview scale is a hairline that reads as a rendering artifact.
const _bezel = 10.0;

/// The metal edge outside the glass.
const _band = 4.0;

/// How far a button stands proud of the body. Its rounded rect is twice this
/// wide and half of it is covered.
const _buttonDepth = 3.0;

/// The corner radius this generation's display is drawn with. Close rather than
/// exact — no physical phone was measured — and it matters more than a
/// decoration: the screen path is what clips the preview, so a layout running
/// to its own corners is cut on this curve.
const _screenRadius = 55.0;

/// The Dynamic Island. One size on every model that has one, which is why it is
/// a constant and not a fraction of the screen: it does not grow with a Max.
const _island = Size(125, 36.7);

/// How far below the top of the glass the island floats.
const _islandTop = 11.0;

/// `(top, length)` from the top of the body, in logical pixels — absolute
/// rather than proportional, because a button is the same physical size on a
/// 16 and on a 16 Pro Max.
const _leftButtons = [(150.0, 32.0), (204.0, 56.0), (276.0, 56.0)];
const _rightButtons = [(214.0, 100.0)];
