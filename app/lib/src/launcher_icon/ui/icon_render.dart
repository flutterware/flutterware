/// Applying the operating system's own rules to a file that already exists.
///
/// This is the whole reason the plugin is more than a file browser. A PNG in
/// `mipmap-xxhdpi/ic_launcher_foreground.png` is a big square with a logo
/// floating in the middle; the launcher shows a circle with a third of it gone.
/// A notification icon is a white-on-transparent silhouette that renders as
/// literally nothing against a pale background. Neither fact is visible in a
/// table of thumbnails, and neither depends on how the files were made.
///
/// Nothing here simulates a generator. Every transformation below is something
/// **Android or Apple** does at display time, and would do to any file you put
/// in that slot.
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ui/theme.dart';
import '../model/role.dart';

/// The clip an OS applies, as a path in [size].
///
/// Returns null where nothing is clipped — including, deliberately, the web
/// maskable case: the spec lets a user agent apply "a mask of any size", so
/// drawing one particular shape would assert a certainty that does not exist.
/// The safe zone is drawn instead.
Path? maskPath(IconMask mask, Size size, {AdaptiveMask? adaptive}) {
  var rect = Offset.zero & size;
  return switch (mask) {
    IconMask.none || IconMask.maskableCircle => null,
    IconMask.adaptive => _adaptivePath(adaptive ?? AdaptiveMask.squircle, rect),
    // Apple's corner is a continuous curve rather than a circular arc; an
    // `RRect` is visibly wrong at icon sizes, which is the size this is always
    // drawn at.
    IconMask.iosSquircle => squirclePath(rect, 5),
    // macOS composites the artwork as authored — the rounded rect is painted
    // into the PNG, not applied by the system. The guide is drawn as an
    // outline instead; see [IconMask.macosGuide].
    IconMask.macosGuide => null,
  };
}

Path _adaptivePath(AdaptiveMask mask, Rect rect) => switch (mask) {
  AdaptiveMask.circle => Path()..addOval(rect),
  AdaptiveMask.squircle => squirclePath(rect, 4),
  AdaptiveMask.roundedSquare =>
    Path()..addRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.25)),
    ),
  // Three corners at full radius and one left sharp, which is what the
  // teardrop shape is.
  AdaptiveMask.teardrop =>
    Path()..addRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: Radius.circular(rect.width * 0.08),
        topRight: Radius.circular(rect.width / 2),
        bottomLeft: Radius.circular(rect.width / 2),
        bottomRight: Radius.circular(rect.width / 2),
      ),
    ),
};

/// Stand-in colours for values the system decides at display time.
///
/// Android derives a themed icon's pair from the wallpaper through Material
/// You, so there is no correct answer to hard-code and no way to read the
/// user's. What matters is the *relationship* — a flat fill on a flat ground —
/// which is what makes a colourful monochrome layer come out as a blob. The
/// captions say the colour is illustrative, so it is not read as a promise.
const themedIconForeground = Color(0xFFD3E3FD);
const themedIconBackground = Color(0xFF0B57D0);

/// The same stand-in for iOS's tinted appearance, where the hue comes from the
/// user's accent.
const tintedIconAccent = Color(0xFF8AB4F8);

/// A superellipse — |x/a|^n + |y/b|^n = 1 — sampled as a closed path.
///
/// The shape both Apple and Android reach for, and the reason a rounded
/// rectangle looks subtly wrong next to a real icon: the curvature is
/// continuous into the straight edge rather than meeting it at a tangent
/// discontinuity.
Path squirclePath(Rect rect, double n, {int samples = 96}) {
  var a = rect.width / 2;
  var b = rect.height / 2;
  var center = rect.center;
  var path = Path();

  for (var i = 0; i <= samples; i++) {
    var t = (i / samples) * 2 * math.pi;
    var cos = math.cos(t);
    var sin = math.sin(t);
    var x = a * _signedPow(cos, 2 / n);
    var y = b * _signedPow(sin, 2 / n);
    if (i == 0) {
      path.moveTo(center.dx + x, center.dy + y);
    } else {
      path.lineTo(center.dx + x, center.dy + y);
    }
  }

  return path..close();
}

double _signedPow(double value, double exponent) => value.isNegative
    ? -math.pow(-value, exponent).toDouble()
    : math.pow(value, exponent).toDouble();

/// One icon, drawn the way the OS draws it.
class IconRender extends StatelessWidget {
  const IconRender({
    super.key,
    required this.image,
    required this.role,
    this.size = 96,
    this.mask,
    this.adaptiveMask = AdaptiveMask.squircle,
    this.backgroundImage,
    this.backgroundColor,
    this.showSafeZone = false,
    this.inspector = true,
  });

  final ImageProvider image;
  final IconRole role;
  final double size;

  /// The clip to apply, overriding the role's own.
  ///
  /// Exists so the detail view can draw the same file unmasked beside the
  /// masked version. What matters is seeing what a mask *removes*; a masked
  /// icon on its own just looks like an icon.
  final IconMask? mask;

  /// Which launcher shape to clip an adaptive icon to. Ignored elsewhere.
  final AdaptiveMask adaptiveMask;

  /// The adaptive background layer, so a foreground is composited over what it
  /// will actually sit on rather than over nothing.
  final ImageProvider? backgroundImage;
  final Color? backgroundColor;

  /// Draw the guaranteed-visible region over the top.
  final bool showSafeZone;

  /// Whether this is being drawn to be *examined* or to be *seen*.
  ///
  /// The inspector reports facts about the file: transparency gets a
  /// checkerboard, and the region a mask removes gets dimmed out. Neither
  /// belongs on a home screen, which should show what the launcher actually
  /// shows — a checkerboard paints a light frame around every icon the
  /// mask does not reach into, and a scrim over a dark icon on a dark wallpaper
  /// makes the whole thing unreadable. In situ the safe zone is an outline and
  /// nothing else.
  final bool inspector;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var applied = mask ?? role.mask;
    var clip = maskPath(applied, Size(size, size), adaptive: adaptiveMask);

    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        // Inside the clip, not under it. The ground the OS puts behind a
        // stencil is part of the icon's own composition, so the mask takes it
        // too — left outside, a themed icon's blue shows in the corners the
        // launcher actually fills with wallpaper.
        _Backing(treatment: role.treatment, checkerboard: inspector),
        if (backgroundColor != null) ColoredBox(color: backgroundColor!),
        if (backgroundImage != null)
          Image(image: backgroundImage!, fit: BoxFit.cover),
        _treated(context),
      ],
    );

    if (clip != null) {
      content = ClipPath(clipper: _PathClipper(clip), child: content);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (showSafeZone && role.safeFraction != null)
            CustomPaint(
              painter: _SafeZonePainter(
                fraction: role.safeFraction!,
                circular: applied == IconMask.maskableCircle,
                // Intersected with the mask, or the scrim paints a square halo
                // around a circular icon and hides the very clip it is there to
                // explain.
                clip: clip,
                // Dim what is lost, outline what is merely unconventional. On
                // macOS nothing outside the guide is removed, and scrimming it
                // would say the system destroys artwork it draws untouched.
                scrim: applied.clips && inspector,
                color: colors.accent,
              ),
            ),
        ],
      ),
    );
  }

  /// The image with whatever the OS does to its pixels applied.
  Widget _treated(BuildContext context) {
    var picture = Image(image: image, fit: BoxFit.contain);

    return switch (role.treatment) {
      IconTreatment.asAuthored => picture,

      // Android keeps the alpha channel and throws the colour away. `srcIn`
      // paints white through the shape, which is exactly the rule.
      IconTreatment.whiteSilhouette => ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        child: picture,
      ),

      // The same stencil, in a colour the wallpaper decides. Painting *through*
      // the alpha rather than tinting the image is the whole point: a colourful
      // monochrome layer comes out flat, which is the surprise worth showing.
      IconTreatment.alphaTinted => ColorFiltered(
        colorFilter: const ColorFilter.mode(
          themedIconForeground,
          BlendMode.srcIn,
        ),
        child: picture,
      ),

      // iOS keeps luminance, so light and dark regions of the source stay
      // distinguishable. Greyscale then modulate is that, approximately; the
      // hue is the user's accent and cannot be known here.
      IconTreatment.luminanceTinted => ColorFiltered(
        colorFilter: const ColorFilter.matrix(_greyscaleMatrix),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(tintedIconAccent, BlendMode.modulate),
          child: picture,
        ),
      ),
    };
  }
}

/// Rec. 601 luma weights, which is what "greyscale" means everywhere it is
/// applied to an icon.
const _greyscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
];

class _PathClipper extends CustomClipper<Path> {
  const _PathClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(_PathClipper old) => old.path != path;
}

/// A checkerboard, so transparency reads as transparency.
/// What sits behind the artwork.
///
/// Not decoration: a stencil treatment throws away everything but the shape, so
/// against nothing there is nothing to see. Android draws a notification icon
/// on the status bar and a themed icon on a wallpaper-derived ground, and these
/// stand in for both. Everything else gets a checkerboard, so transparency
/// reads as transparency rather than as white.
class _Backing extends StatelessWidget {
  const _Backing({required this.treatment, this.checkerboard = true});

  final IconTreatment treatment;
  final bool checkerboard;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return switch (treatment) {
      IconTreatment.whiteSilhouette => const ColoredBox(
        color: Color(0xFF202124),
      ),
      IconTreatment.alphaTinted => const ColoredBox(
        color: themedIconBackground,
      ),
      // The stencil grounds stay either way: they are what the OS puts behind
      // the shape, not an inspector affordance.
      _ when !checkerboard => const SizedBox.shrink(),
      _ => CustomPaint(
        painter: _CheckerPainter(light: colors.panel, dark: colors.panel2),
      ),
    };
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.light, required this.dark});

  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 8.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    var paint = Paint()..color = dark;
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isEven) continue;
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) =>
      old.light != light || old.dark != dark;
}

/// The region guaranteed to survive whatever mask is applied.
class _SafeZonePainter extends CustomPainter {
  const _SafeZonePainter({
    required this.fraction,
    required this.circular,
    required this.scrim,
    required this.color,
    this.clip,
  });

  /// The fraction of the canvas that is safe — the diameter for [circular],
  /// the side otherwise.
  final double fraction;

  final bool circular;

  /// Whether to dim the region outside — true only when the OS really removes
  /// it. See the call site.
  final bool scrim;

  /// The mask the icon itself is clipped to; the scrim never paints outside it.
  final Path? clip;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    var full = Offset.zero & size;
    var safe = Path();
    if (circular) {
      safe.addOval(
        Rect.fromCircle(
          center: size.center(Offset.zero),
          radius: size.shortestSide * fraction / 2,
        ),
      );
    } else {
      safe.addRect(full.deflate(size.width * (1 - fraction) / 2));
    }

    // Scrim everything *outside* the safe zone rather than outlining it. The
    // question the overlay answers is "what gets cut", and a hairline ring
    // leaves you to work that out; a dimmed margin shows it.
    if (scrim) {
      var outside = Path.combine(
        PathOperation.difference,
        clip ?? (Path()..addRect(full)),
        safe,
      );
      canvas.drawPath(outside, Paint()..color = const Color(0x66000000));
    }
    canvas.drawPath(
      safe,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SafeZonePainter old) =>
      old.fraction != fraction ||
      old.circular != circular ||
      old.scrim != scrim ||
      old.clip != clip ||
      old.color != color;
}
