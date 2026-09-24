/// The coffee shop's own store frame — the demo, and the argument.
///
/// Three things here are not expressible in a screenshot pipeline that
/// composites images, which `fastlane frameit` does and which is why it offers
/// a device, a caption and a background and nothing else:
///
/// * **The app's own widgets come out of the phone.** The menu shot holds the
///   seasonal card up beside the screen it sits on, bigger and in front — the
///   real `SeasonalCard`, laid out and painted again at the canvas's scale,
///   in the listing's language. A compositor could only crop a bitmap of it.
/// * **The devices lean**, body and shadow and pixels together, because they
///   are one subtree under one `Transform`.
/// * **The scene runs behind the whole listing.** Shot 3's hills continue shot
///   2's: a frame is handed `index` and `total`, [StoreShot.panoramaOffset]
///   does the arithmetic, and every shot is still rendered on its own.
///
/// That is the point the demo exists to make: **a composition is a widget**,
/// so the ceiling is Flutter's rather than a template format's.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware/store.dart';

import 'shop/shop_app.dart';
import 'src/store_copy.dart';

/// What `tool/flutterware.dart` names as the package's `frame:`.
StoreFrame storeFrame(StoreShot shot) => CoffeeStoreFrame(shot);

class CoffeeStoreFrame extends StoreFrame {
  const CoffeeStoreFrame(super.shot, {super.key});

  static const _roast = Color(0xFF21140E);
  static const _roastLow = Color(0xFF4B2C1D);
  static const _hill = Color(0xFF3A2217);
  static const _cream = Color(0xFFFFF4E8);
  static const _caramel = Color(0xFFE9B77C);

  /// How wide the phone is, as a fraction of the canvas. Wide enough that the
  /// app reads, narrow enough to leave a margin the lifted widget can cross.
  static const _phoneWidth = 0.74;

  /// How far the phone leans, in radians — alternating, so the listing reads
  /// as a hand-held row rather than a rank of identical phones.
  static const _tilt = 0.035;

  @override
  Widget build(BuildContext context) {
    var canvas = shot.canvas;
    var w = canvas.logicalWidth;
    var h = canvas.logicalHeight;
    var phone = w * _phoneWidth;
    var lean = shot.index.isEven ? -_tilt : _tilt;
    return SizedBox(
      width: w,
      height: h,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The scene, one piece, as wide as the whole listing. Every shot
            // draws all of it and shows its own slice — which is what makes
            // the join exact rather than approximately aligned.
            //
            // **`Positioned`, not `Transform.translate` over a `SizedBox`.** A
            // stack forces every *non*-positioned child to its own size, so a
            // `SizedBox` asking for five canvases of width silently got one.
            Positioned(
              left: shot.panoramaOffset,
              top: 0,
              width: shot.panoramaWidth,
              height: h,
              child: CustomPaint(painter: _Scene(total: shot.total)),
            ),
            Positioned(
              left: w * 0.08,
              right: w * 0.08,
              top: h * 0.058,
              child: _Headline(shot: shot),
            ),
            ..._behind(shot, w: w, h: h),
            Positioned(
              left: (w - phone) / 2,
              top: h * 0.29,
              width: phone,
              child: Transform.rotate(
                angle: lean,
                child: _Phone(shot: shot),
              ),
            ),
            ..._lifted(shot, w: w, h: h, lean: lean),
          ],
        ),
      ),
    );
  }

  /// What stands behind the phone: on the first shot, the cup it is about.
  static List<Widget> _behind(
    StoreShot shot, {
    required double w,
    required double h,
  }) => [
    if (shot.slug == 'welcome')
      Positioned(
        right: -w * 0.22,
        top: h * 0.46,
        child: DrinkArt(drinks.first.look, size: w * 0.56, ground: false),
      ),
  ];

  /// The piece of the app this shot holds up, if it holds one up.
  ///
  /// Held clear of where it sits on the screen, over a part of the phone with
  /// little on it: a copy that half-covers its own original reads as a
  /// rendering fault rather than as a close-up.
  ///
  ///
  /// Laid out in the canvas's logical pixels, which on the App Store's phone
  /// are the device's own: the phone is drawn at three quarters of that, so a
  /// lifted widget comes out *bigger* than the screen it was lifted from —
  /// which is what makes it read as lifted.
  static List<Widget> _lifted(
    StoreShot shot, {
    required double w,
    required double h,
    required double lean,
  }) {
    Widget at({
      required double left,
      required double top,
      required double width,
      required Widget child,
      double turn = 0,
    }) => Positioned(
      left: w * left,
      top: h * top,
      width: w * width,
      child: _Lifted(locale: shot.locale, turn: turn, child: child),
    );

    return switch (shot.slug) {
      'menu' => [
        at(
          left: 0.04,
          top: 0.66,
          width: 0.92,
          turn: -lean * 1.4,
          child: SeasonalCard(onTap: () {}),
        ),
      ],
      'drink' => [
        at(
          left: 0.06,
          top: 0.72,
          width: 0.88,
          turn: -lean * 1.4,
          child: _Card(
            child: Builder(
              builder: (context) {
                var strings = ShopStrings.of(context);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      strings.milk,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ChoiceRow(
                      values: Milk.values,
                      selected: Milk.oat,
                      keyOf: (milk) => ValueKey(milk),
                      labelOf: (milk) => switch (milk) {
                        Milk.whole => strings.milkWhole,
                        Milk.oat => strings.milkOat,
                        Milk.almond => strings.milkAlmond,
                      },
                      onSelected: (_) {},
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
      'cart' => [
        at(
          left: 0.06,
          top: 0.66,
          width: 0.88,
          turn: -lean * 1.4,
          child: _Card(
            child: Builder(
              builder: (context) {
                var strings = ShopStrings.of(context);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      strings.pickup,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ChoiceRow(
                      values: Pickup.values,
                      selected: Pickup.in15,
                      keyOf: (pickup) => ValueKey(pickup),
                      labelOf: (pickup) => switch (pickup) {
                        Pickup.asap => strings.pickupAsap,
                        Pickup.in15 => strings.pickupIn15,
                        Pickup.in30 => strings.pickupIn30,
                      },
                      onSelected: (_) {},
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
      'order-placed' => [
        at(
          left: 0.05,
          top: 0.73,
          width: 0.9,
          turn: -lean * 1.4,
          child: _Card(
            child: Builder(
              builder: (context) {
                var strings = ShopStrings.of(context);
                return OrderProgress(
                  steps: [
                    strings.stepReceived,
                    strings.stepBrewing,
                    strings.stepReady,
                  ],
                  reached: 1,
                );
              },
            ),
          ),
        ),
      ],
      _ => const [],
    };
  }
}

/// The kicker and the headline, in the set's own language.
class _Headline extends StatelessWidget {
  const _Headline({required this.shot});

  final StoreShot shot;

  @override
  Widget build(BuildContext context) {
    var w = shot.canvas.logicalWidth;
    var kicker = storeKicker(shot.slug, shot.locale);
    var headline = storeHeadline(shot.slug, shot.locale);
    return Column(
      children: [
        if (kicker != null)
          Padding(
            padding: EdgeInsets.only(bottom: w * 0.03),
            child: Text(
              kicker.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CoffeeStoreFrame._caramel,
                fontSize: w * 0.034,
                fontWeight: FontWeight.w700,
                letterSpacing: w * 0.004,
              ),
            ),
          ),
        if (headline != null)
          Text(
            headline,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: CoffeeStoreFrame._cream,
              fontSize: w * 0.078,
              height: 1.08,
              fontWeight: FontWeight.w800,
              letterSpacing: -w * 0.002,
            ),
          ),
      ],
    );
  }
}

/// One phone: a body, the app's screen inside it, and the status bar a
/// capture does not have.
class _Phone extends StatelessWidget {
  const _Phone({required this.shot});

  final StoreShot shot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        var width = box.maxWidth;
        var bezel = width * 0.03;
        var screen = width - bezel * 2;
        var scale = screen / shot.imageSize.width;
        var screenHeight = shot.imageSize.height * scale;
        var ios = shot.device.platform == DevicePlatform.ios;
        // An iPhone's corner is about an eighth of its width, an Android's
        // nearer a sixteenth — and the clock sits closer to an Android's.
        var corner = width * (ios ? 0.15 : 0.08);
        return Container(
          width: width,
          height: screenHeight + bezel * 2,
          padding: EdgeInsets.all(bezel),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(corner),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4A4541), Color(0xFF151312), Color(0xFF34302C)],
              stops: [0, 0.5, 1],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: width * 0.1,
                offset: Offset(0, width * 0.05),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(corner - bezel),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(image: shot.image, fit: BoxFit.fill),
                StatusChrome(
                  device: shot.device,
                  scale: scale,
                  statusBrightness: shot.statusBrightness,
                  navBrightness: shot.navBrightness,
                ),
                if (!ios)
                  // The camera's punch hole.
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: EdgeInsets.only(top: 9 * scale),
                      width: 11 * scale,
                      height: 11 * scale,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (ios)
                  // The Dynamic Island, at the size and height the device
                  // really has it.
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: EdgeInsets.only(top: 11 * scale),
                      width: 125 * scale,
                      height: 37 * scale,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(20 * scale),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A widget of the app's, held out in front of the canvas: its theme, its
/// words in the listing's language, a shadow and a small counter-lean.
class _Lifted extends StatelessWidget {
  const _Lifted({required this.locale, required this.child, this.turn = 0});

  final Locale locale;
  final Widget child;
  final double turn;

  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      delegates: [_StringsNow(locale)],
      child: Theme(
        data: shopTheme(Brightness.light),
        child: Transform.rotate(
          angle: turn,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 40,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

/// The app's surface behind a lifted widget that has none of its own.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
    ),
    child: child,
  );
}

/// `ShopStrings`, already loaded — see [shopStringsFor].
class _StringsNow extends LocalizationsDelegate<ShopStrings> {
  const _StringsNow(this.locale);

  final Locale locale;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<ShopStrings> load(Locale _) =>
      SynchronousFuture(shopStringsFor(locale));

  @override
  bool shouldReload(_StringsNow old) => old.locale != locale;
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
          colors: [CoffeeStoreFrame._roast, CoffeeStoreFrame._roastLow],
        ).createShader(Offset.zero & size),
    );

    // A warm glow behind where each phone stands.
    var canvasWidth = size.width / total;
    for (var i = 0; i < total; i++) {
      var centre = Offset(canvasWidth * (i + 0.5), size.height * 0.62);
      canvas.drawCircle(
        centre,
        canvasWidth * 0.75,
        Paint()
          ..shader = RadialGradient(
            colors: [
              CoffeeStoreFrame._caramel.withValues(alpha: 0.22),
              CoffeeStoreFrame._caramel.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: canvasWidth)),
      );
    }

    // Steam, rising across the whole width — the one motif that makes the
    // panorama obvious at a glance, because it plainly does not restart.
    var steam = Paint()
      ..color = CoffeeStoreFrame._cream.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.005;
    for (var band = 0; band < 3; band++) {
      var path = Path();
      var y = size.height * (0.24 + band * 0.045);
      var amplitude = size.height * 0.03;
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
      var base = size.height * (0.8 + layer * 0.07);
      var amplitude = size.height * (0.045 - layer * 0.015);
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
            CoffeeStoreFrame._roast,
            layer * 0.5,
          )!,
      );
    }
  }

  @override
  bool shouldRepaint(_Scene old) => old.total != total;
}
