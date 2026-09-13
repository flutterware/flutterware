import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutterware/devices.dart';

import '../model/composition.dart';
import '../model/fit_check.dart';
import '../model/surface.dart';

/// A [SplashComposition], drawn.
///
/// Deliberately thin, and it must stay that way. Every decision about where
/// something goes — which key won the cascade, what `android_gravity` means,
/// how big the Android 12 mask is — has already been made by the time a
/// composition exists. This widget maps [SplashFit] onto `BoxFit` and
/// [SplashAlignment] onto `Alignment` and does nothing else.
///
/// That is what lets the same widget be mounted in the panel and in a headless
/// guest handed the same JSON: two hosts, one renderer, nothing to drift.
/// An image provider for a path the scan found a picture at —
/// `SplashPlugin(image: …)`.
typedef SplashImage = ImageProvider Function(String absolutePath);

/// Where the pictures below are read from, put in the tree once by the panel
/// so a layer three widgets down does not have to be handed it. Absent, the
/// disk: a preview and a test draw the same widgets over real files.
class SplashImages extends InheritedWidget {
  const SplashImages({super.key, required this.image, required super.child});

  final SplashImage image;

  static SplashImage of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SplashImages>()?.image ??
      fileSplashImage;

  @override
  bool updateShouldNotify(SplashImages old) => old.image != image;
}

/// The default: a file on disk.
ImageProvider fileSplashImage(String absolutePath) =>
    FileImage(File(absolutePath));

class SplashRender extends StatelessWidget {
  const SplashRender(
    this.composition, {
    super.key,
    this.device,
    this.showSafeAreas = false,
  });

  final SplashComposition composition;

  /// The screen this is being drawn as, when one was chosen. Only the safe-area
  /// overlay reads it — the canvas *size* is decided by the caller, which is
  /// what keeps this widget free of layout policy.
  final Device? device;

  /// Draw the notch and home-indicator bands.
  ///
  /// Off by default and off under capture, because it is annotation rather than
  /// splash: a screenshot with our overlay baked into it is not a picture of
  /// what ships.
  final bool showSafeAreas;

  @override
  Widget build(BuildContext context) {
    var background = composition.backgroundColor;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: background == null
                ? const Color(0xFF000000)
                : Color(background),
          ),
          if (composition.backgroundImage != null)
            _Layer(composition.backgroundImage!),
          if (composition.surface == SplashSurface.android12)
            _Android12Icon(composition)
          else if (composition.image != null)
            _Layer(composition.image!),
          if (composition.branding != null) _Branding(composition),
          if (!composition.fullscreen &&
              composition.surface != SplashSurface.web)
            _StatusBar(background: background, height: device?.insetTop),
          if (showSafeAreas && device != null)
            _SafeAreas(device!, background: background),
        ],
      ),
    );
  }
}

/// Where the parts of the screen the OS keeps begin — the notch band and the
/// home indicator.
///
/// A rule at the boundary, not a band over the content. The first version
/// filled both insets with a translucent grey, and on an iPhone that is a 59dp
/// slab across the top of an 852dp screen: it reads as part of the splash, which
/// is the one thing a preview must never make you believe. A hairline says the
/// same thing — "below here is yours" — without covering anything.
///
/// It is the only thing in this file that is not a claim about what the
/// generator produces, which is why it is opt-in and off under capture.
class _SafeAreas extends StatelessWidget {
  const _SafeAreas(this.device, {this.background});

  final Device device;
  final int? background;

  @override
  Widget build(BuildContext context) {
    var dark =
        background == null || Color(background!).computeLuminance() < 0.5;
    var line = dark ? const Color(0x59FFFFFF) : const Color(0x59000000);
    var wash = dark ? const Color(0x0DFFFFFF) : const Color(0x0D000000);

    Widget edge(double inset, {required bool top}) => Container(
      height: inset,
      decoration: BoxDecoration(
        color: wash,
        border: Border(
          top: top ? BorderSide.none : BorderSide(color: line),
          bottom: top ? BorderSide(color: line) : BorderSide.none,
        ),
      ),
    );

    return IgnorePointer(
      child: Column(
        children: [
          if (device.insetTop > 0) edge(device.insetTop, top: true),
          const Spacer(),
          if (device.insetBottom > 0) edge(device.insetBottom, top: false),
        ],
      ),
    );
  }
}

/// One placed image.
class _Layer extends StatelessWidget {
  const _Layer(this.layer);

  final SplashLayer layer;

  @override
  Widget build(BuildContext context) {
    if (layer.missing) return _MissingLayer(layer);

    var alignment = Alignment(layer.alignment.x, layer.alignment.y);
    var image = Image(
      image: SplashImages.of(context)(layer.absolutePath!),
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
      // A file that vanishes between the scan and the paint is a race, not a
      // config error, so it degrades to nothing rather than to a red box.
      errorBuilder: (context, _, _) => const SizedBox.shrink(),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // `splashDrawnSize` is the same arithmetic the fit sweep runs. Sharing
        // it is the point: a warning that says the logo is clipped and a picture
        // that shows it fitting would leave nobody able to tell which was
        // lying.
        var (width, height) = splashDrawnSize(
          fit: layer.fit,
          naturalWidth: layer.naturalWidth ?? constraints.maxWidth,
          naturalHeight: layer.naturalHeight ?? constraints.maxHeight,
          screenWidth: constraints.maxWidth,
          screenHeight: constraints.maxHeight,
        );

        return Align(
          alignment: alignment,
          child: SizedBox(width: width, height: height, child: image),
        );
      },
    );
  }
}

/// The hole where a referenced file should have been.
///
/// Drawn rather than skipped: a missing image that silently renders as an empty
/// splash looks like a splash with no image, which is a different bug with a
/// different fix.
class _MissingLayer extends StatelessWidget {
  const _MissingLayer(this.layer);

  final SplashLayer layer;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment(layer.alignment.x, layer.alignment.y),
      child: FractionallySizedBox(
        widthFactor: 0.5,
        heightFactor: 0.25,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x88C23F38), width: 1),
            color: const Color(0x11C23F38),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                layer.path,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 8,
                  color: Color(0xFFC23F38),
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Android 12 icon: a fixed slot, a circular mask, and an optional circle
/// behind it.
///
/// This surface exists to show that the icon is **not** screen-sized however
/// large the source is, and that a third of it is cut away. Drawing it any
/// other way would hide the two things people get wrong.
class _Android12Icon extends StatelessWidget {
  const _Android12Icon(this.composition);

  final SplashComposition composition;

  @override
  Widget build(BuildContext context) {
    var image = composition.image;
    if (image == null) return const SizedBox.shrink();

    var canvas = composition.iconCanvas ?? android12IconCanvasDp;
    var fraction = composition.iconMaskFraction ?? android12MaskFraction;
    var background = composition.iconBackgroundColor;

    return Center(
      child: SizedBox(
        width: canvas,
        height: canvas,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (background != null)
              Center(
                child: SizedBox(
                  width: canvas * fraction,
                  height: canvas * fraction,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(background),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ClipPath(
              clipper: _IconMask(fraction),
              child: image.missing
                  ? _MissingLayer(image)
                  : Image(
                      image: SplashImages.of(context)(image.absolutePath!),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, _, _) => const SizedBox.shrink(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A centred circle covering [fraction] of the box — the two-thirds Android
/// keeps.
class _IconMask extends CustomClipper<Path> {
  const _IconMask(this.fraction);

  final double fraction;

  @override
  Path getClip(Size size) => Path()
    ..addOval(
      Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: math.min(size.width, size.height) * fraction / 2,
      ),
    );

  @override
  bool shouldReclip(_IconMask old) => old.fraction != fraction;
}

class _Branding extends StatelessWidget {
  const _Branding(this.composition);

  final SplashComposition composition;

  @override
  Widget build(BuildContext context) {
    var branding = composition.branding!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: composition.brandingBottomPadding.toDouble(),
      ),
      child: _Layer(branding),
    );
  }
}

/// A schematic status bar, shown when `fullscreen` is not set.
///
/// Deliberately a plain translucent band rather than a mock clock and battery:
/// its only job is to make `fullscreen: true` visibly do something. Inventing
/// convincing chrome would be inventing pixels the generator never produces.
class _StatusBar extends StatelessWidget {
  const _StatusBar({this.background, this.height});

  final int? background;

  /// The chosen device's top inset, so the band is the height the OS actually
  /// takes rather than a guess. Falls back to 20 when no device is chosen.
  final double? height;

  @override
  Widget build(BuildContext context) {
    // Legible on both — a light band on a dark splash and vice versa.
    var dark =
        background == null || Color(background!).computeLuminance() < 0.5;

    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: height == null || height! <= 0 ? 20 : height!,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (var width in [10.0, 8.0, 14.0])
              Padding(
                padding: const EdgeInsets.only(right: 3, top: 6),
                child: Container(
                  width: width,
                  height: 5,
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0x66FFFFFF)
                        : const Color(0x55000000),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
