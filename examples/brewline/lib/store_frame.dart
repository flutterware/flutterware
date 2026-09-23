/// The coffee shop's own store frame — the demo, and the argument.
///
/// Two things here are not expressible in a screenshot pipeline that
/// composites images, which `fastlane frameit` does and which is why it offers
/// straight-on portrait and landscape and nothing else:
///
/// * **The devices are tilted**, body and shadow and pixels together, because
///   they are one subtree under one `Transform`.
/// * **The scene runs behind the whole listing.** Shot 3's hills continue shot
///   2's, and the device from shot 2 leans into shot 3's left edge — with shot
///   2's real screenshot inside it, not a grey placeholder.
///
/// Neither costs machinery. A frame is handed `index`, `total` and the whole
/// [StoreShot.set]; [StoreShot.panoramaOffset] does the arithmetic; every shot
/// is still rendered on its own, knowing nothing about the others.
///
/// That is the point the demo exists to make: **a composition is a widget**,
/// so the ceiling is Flutter's rather than a template format's.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/store.dart';

import 'src/store_copy.dart';

/// What `tool/flutterware.dart` names as the package's `frame:`.
StoreFrame storeFrame(StoreShot shot) => CoffeeStoreFrame(shot);

class CoffeeStoreFrame extends StoreFrame {
  const CoffeeStoreFrame(super.shot, {super.key});

  static const _sky = Color(0xFF2C1B14);
  static const _skyLow = Color(0xFF6B3F2A);
  static const _hill = Color(0xFF48281B);
  static const _ink = Color(0xFFFDF3EC);

  /// How far the device leans, in radians. Small: past about eight degrees the
  /// app's own text starts to read as decoration rather than as an app.
  static const _tilt = 0.06;

  /// How wide a device is, as a fraction of one canvas.
  ///
  /// Wide enough to reach the boundary, and no wider. At 0.68 every device
  /// sat well inside its own canvas with a margin either side, so no body ever
  /// reached an edge and the listing was five separate pictures that happened
  /// to share a background. At 1.04 they crossed, and read as slabs rather
  /// than phones. Here a device's shoulder arrives on the next screenshot —
  /// which is the pattern being demonstrated, and the reason [StoreShot.set]
  /// exists — while each still reads as a phone.
  static const _deviceWidth = 0.86;

  /// Alternate devices sit a little left and right of their canvas's centre,
  /// so the row reads as a scattering rather than as a rank of identical
  /// phones — and so the crossing happens on one side at a time.
  static const _stagger = 0.055;

  @override
  Widget build(BuildContext context) {
    var canvas = shot.canvas;
    return SizedBox(
      width: canvas.logicalWidth,
      height: canvas.logicalHeight,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The scene, one piece, as wide as the whole listing. Every shot
            // draws all of it and shows its own slice — which is what makes
            // the join exact rather than approximately aligned.
            //
            // **`Positioned`, not `Transform.translate` over a `SizedBox`.**
            // The stack is `StackFit.expand`, which forces every *non*
            // -positioned child to the canvas's size — so a `SizedBox` asking
            // for five canvases of width silently got one, and every shot but
            // the first translated an empty strip off its own edge. Positioned
            // children are laid out at the size they are given.
            Positioned(
              left: shot.panoramaOffset,
              top: 0,
              width: shot.panoramaWidth,
              height: canvas.logicalHeight,
              child: CustomPaint(painter: _Scene(total: shot.total)),
            ),
            _Headline(shot: shot, color: _ink),
            // The devices, on the same coordinate system as the scene, so a
            // body that runs off this canvas arrives on the next one where it
            // left off.
            Positioned(
              left: shot.panoramaOffset,
              top: 0,
              width: shot.panoramaWidth,
              height: canvas.logicalHeight,
              child: Stack(
                children: [
                  for (var i = 0; i < shot.total; i++)
                    // Only this shot and the two beside it are placed. The
                    // rest are off-canvas and would decode a megapixel each
                    // to be clipped away — see [StoreShot.set].
                    if ((i - (shot.index - 1)).abs() <= 1)
                      Positioned(
                        left:
                            (i + (i.isEven ? _stagger : -_stagger)) *
                            canvas.logicalWidth,
                        top: canvas.logicalHeight * (i.isEven ? 0.3 : 0.26),
                        width: canvas.logicalWidth,
                        child: Center(
                          child: _Device(
                            image: i < shot.set.length
                                ? shot.set[i]
                                : shot.image,
                            imageSize: shot.imageSize,
                            width: canvas.logicalWidth * _deviceWidth,
                            tilt: i.isEven ? _tilt : -_tilt,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The words above the devices, in the set's own language.
class _Headline extends StatelessWidget {
  const _Headline({required this.shot, required this.color});

  final StoreShot shot;
  final Color color;

  @override
  Widget build(BuildContext context) {
    var text = storeHeadline(shot.slug, shot.locale);
    if (text == null) return const SizedBox.shrink();
    var canvas = shot.canvas;
    return Positioned(
      left: canvas.logicalWidth * 0.09,
      right: canvas.logicalWidth * 0.09,
      top: canvas.logicalHeight * 0.07,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: canvas.logicalWidth * 0.075,
          height: 1.15,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}

/// One phone: a rounded body with the app inside it, leaning.
///
/// The tilt is on the whole subtree, so the body, its edge, its shadow and the
/// app's own pixels lean together. Compositing two flat images cannot do this
/// — the shadow would be square to the page and the screen would shear.
class _Device extends StatelessWidget {
  const _Device({
    required this.image,
    required this.imageSize,
    required this.width,
    required this.tilt,
  });

  final ImageProvider image;
  final Size imageSize;
  final double width;
  final double tilt;

  @override
  Widget build(BuildContext context) {
    var height = width * imageSize.height / imageSize.width;
    var radius = width * 0.085;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        // A little perspective, so the lean has depth rather than being a
        // sticker rotated on the page.
        ..setEntry(3, 2, 0.0009)
        ..rotateY(tilt * 2.4)
        ..rotateZ(tilt),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF120A06).withValues(alpha: 0.45),
              blurRadius: width * 0.12,
              offset: Offset(0, width * 0.05),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(image: image, fit: BoxFit.cover),
              // The glass: a diagonal sheen, which is what makes a rectangle
              // read as a screen rather than as a picture of one.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.06),
                    ],
                    stops: const [0, 0.42, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The scene behind the whole listing.
///
/// Painted rather than an asset, so the demo needs no image files and the
/// width is whatever the set is — five shots or ten, the hills still meet.
class _Scene extends CustomPainter {
  const _Scene({required this.total});

  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [CoffeeStoreFrame._sky, CoffeeStoreFrame._skyLow],
        ).createShader(Offset.zero & size),
    );

    // Steam, rising across the whole width — the one motif that makes the
    // panorama obvious at a glance, because it plainly does not restart.
    var steam = Paint()
      ..color = CoffeeStoreFrame._ink.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.006;
    for (var band = 0; band < 3; band++) {
      var path = Path();
      var y = size.height * (0.16 + band * 0.05);
      var amplitude = size.height * 0.035;
      path.moveTo(0, y);
      for (var x = 0.0; x <= size.width; x += size.width / 240) {
        path.lineTo(
          x,
          y +
              math.sin(x / size.width * math.pi * total * 1.6 + band) *
                  amplitude,
        );
      }
      canvas.drawPath(path, steam);
    }

    // Hills, low and continuous.
    for (var layer = 0; layer < 2; layer++) {
      var path = Path()..moveTo(0, size.height);
      var base = size.height * (0.74 + layer * 0.07);
      var amplitude = size.height * (0.05 - layer * 0.015);
      for (var x = 0.0; x <= size.width; x += size.width / 300) {
        path.lineTo(
          x,
          base -
              math.sin(x / size.width * math.pi * total * 0.9 + layer * 1.7) *
                  amplitude,
        );
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            CoffeeStoreFrame._hill,
            CoffeeStoreFrame._sky,
            layer * 0.5,
          )!,
      );
    }
  }

  @override
  bool shouldRepaint(_Scene old) => old.total != total;
}
