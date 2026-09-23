/// The composition a store screenshot is: an app's own pixels, arranged on the
/// canvas a store will take.
///
/// **Published API.** A project subclasses [StoreFrame], so a field renamed
/// here breaks somebody's listing — the same weight `lib/flutter_test.dart`
/// carries.
///
/// A frame is an ordinary widget rendered in an ordinary localized tree at the
/// set's locale, which is the whole reason it is a widget rather than a
/// template format. RTL flips because the locale is in the tree; a dark variant
/// works because the theme is; fonts are the project's own because the harness
/// loaded them. Nothing here invents a layout language, and nothing here knows
/// where a project keeps its marketing copy — see the design's §2.
library;

import 'package:material_ui/material_ui.dart';

import '../devices.dart';
import '../plugins/store.dart';
import 'status_chrome.dart';

/// What a frame is handed: everything only flutterware knows, and nothing else.
///
/// No headline. What words to draw is the frame's business, and being a widget
/// in a localized tree it can reach them however the project keeps them —
/// generated l10n, a catalog, a map, a file a copywriter edits.
class StoreShot {
  const StoreShot({
    required this.image,
    this.set = const [],
    required this.imageSize,
    required this.slug,
    required this.index,
    required this.total,
    required this.locale,
    required this.device,
    required this.canvas,
    this.statusBrightness = Brightness.dark,
    this.navBrightness = Brightness.dark,
  });

  /// The app's own pixels, as captured.
  final ImageProvider image;

  /// **Every** shot of this set, in the order the store will show them —
  /// including this one, at `set[index - 1]`.
  ///
  /// Here because a composition is not always about one screenshot. A device
  /// body tilted across a listing has to *start* in one canvas and continue in
  /// the next, so the frame drawing shot 2 paints part of shot 1 — with shot
  /// 1's real pixels in it, or the join is a grey rectangle.
  ///
  /// Lazy, as any `ImageProvider` is: nothing here decodes until the widget
  /// that holds it is painted, so a frame that ignores this pays nothing for
  /// it, and one that reaches for a neighbour pays for that neighbour. Reach
  /// far and you pay far — a set is up to ten canvases of several megapixels
  /// each.
  ///
  /// The harness precaches whatever the frame actually placed, so an `Image`
  /// widget from this list arrives painted. A provider handed to something
  /// that is not an `Image` — a `DecorationImage`, a custom painter — is not
  /// found and will capture as a hole.
  final List<ImageProvider> set;

  /// What [image] is, in the device's logical pixels — the size the app laid
  /// itself out at, not the size of the file.
  final Size imageSize;

  /// The shot's name, slugged — `order-placed`. An identifier: it is the file
  /// name and the step's address, and it is deliberately *not* display copy.
  final String slug;

  /// 1-based position in the set, and how many there are. A frame that wants
  /// to number its shots, or treat the first differently, has these rather
  /// than having to be told twice.
  final int index;
  final int total;

  /// The set's locale — the app's tag, as the declaration spells it.
  final Locale locale;

  /// What the app rendered as.
  final Device device;

  /// What has to be filled, and at what scale — see [StoreCanvas.pixelRatio].
  final StoreCanvas canvas;

  /// What the app declared through `SystemUiOverlayStyle` when this shot was
  /// captured, naming the **icons** — [Brightness.dark] is dark icons, over a
  /// light app.
  ///
  /// Recorded per step rather than per set, because an app that turns one
  /// screen dark turns its status bar light with it, and a set drawn at one
  /// brightness throughout would be wrong on exactly that screen. Defaulted
  /// rather than required: an app that declares no style leaves nothing to
  /// record, and dark icons are what a light app wants.
  final Brightness statusBrightness;
  final Brightness navBrightness;

  /// How wide a scene spanning the whole set is, in the canvas's logical
  /// units — [total] canvases side by side.
  ///
  /// With [panoramaOffset], this is the whole of a continuous background: draw
  /// something [panoramaWidth] wide, translate it by [panoramaOffset], and
  /// each shot lands on its own slice of it. Every shot is still rendered on
  /// its own and knows nothing of the others; the arithmetic is the only thing
  /// that joins them.
  ///
  /// ```dart
  /// Positioned(
  ///   left: shot.panoramaOffset,
  ///   top: 0,
  ///   width: shot.panoramaWidth,
  ///   height: shot.canvas.logicalHeight,
  ///   child: theScene,
  /// )
  /// ```
  ///
  /// **`Positioned`, not a translated `SizedBox`.** Under a `StackFit.expand`
  /// stack every non-positioned child is forced to the canvas's size, so a
  /// `SizedBox` asking for [panoramaWidth] silently gets one canvas and every
  /// shot but the first translates an empty strip off its own edge. It looks
  /// exactly like a frame that forgot to draw.
  double get panoramaWidth => total * canvas.logicalWidth;

  /// How far left to move a [panoramaWidth]-wide scene so this shot shows its
  /// own part of it. Negative for every shot but the first.
  double get panoramaOffset => -(index - 1) * canvas.logicalWidth;
}

/// The base a project's own composition extends.
///
/// ```dart
/// class CoffeeFrame extends StoreFrame {
///   const CoffeeFrame(super.shot, {super.key});
///
///   @override
///   Widget build(BuildContext context) => ...;
/// }
/// ```
///
/// Rendered at [StoreShot.canvas]'s logical size, on an **opaque** ground: the
/// image is encoded without an alpha channel, which is what Google Play
/// requires, so anything a frame leaves unpainted is white rather than
/// transparent.
abstract class StoreFrame extends StatelessWidget {
  const StoreFrame(this.shot, {super.key});

  final StoreShot shot;
}

/// The frame a project that declares none gets: chrome everywhere, a
/// composition only where geometry forces one.
///
/// The rule decision 7 settles, and it turns on a distinction that decision
/// did not originally draw. Inventing a ground and a device body is a
/// **marketing** decision and stays opt-in — but a status bar is not marketing.
/// It is the one piece of a real screenshot a `flutter_tester` cannot draw, and
/// a store set without one reads as a mockup of the app rather than a picture
/// of it. So every set is framed now; what a declaration decides is whether the
/// frame is a composition or a pane of glass.
///
/// Apple's sets keep their exact pixels either way: an uncomposed canvas *is*
/// its device's, so [PlainStoreFrame] draws the capture 1:1 and adds the bar.
StoreFrame defaultStoreFrame(StoreShot shot) =>
    shot.canvas == StoreCanvas.of(shot.device)
    ? PlainStoreFrame(shot)
    : DefaultStoreFrame(shot);

/// The app's own pixels, edge to edge, wearing the chrome a real screenshot
/// would have. No ground, no device body, no rounding.
///
/// What a set gets where the store's canvas is already the device's own output,
/// which is both of Apple's classes and Play's tablet. The image is drawn at
/// its own size onto a canvas of that size, so nothing is resampled and the
/// bytes under the bar are the ones the app painted.
class PlainStoreFrame extends StoreFrame {
  const PlainStoreFrame(super.shot, {super.key});

  @override
  Widget build(BuildContext context) {
    var canvas = shot.canvas;
    // One where this frame applies at all. Computed rather than assumed
    // because nothing stops a project naming it in `frame:`, and a chrome
    // drawn at the wrong scale is worse than none.
    var scale = canvas.logicalWidth / shot.imageSize.width;
    return SizedBox(
      width: canvas.logicalWidth,
      height: canvas.logicalHeight,
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
        ],
      ),
    );
  }
}

/// The composition a project gets when it declares no frame of its own.
///
/// Deliberately a real design rather than a placeholder, and deliberately a
/// **plain** one. The hand-drawn device bodies live behind `flutter_svg`, and a
/// published package does not get a new dependency so that a default can have
/// artwork — a rounded body is also what most listings actually ship, and
/// Apple's own guidance is against a device frame that is not the device.
///
/// Where this applies at all is decided elsewhere and narrowly: a project that
/// declares no frame keeps getting raw app pixels wherever a store accepts
/// them, so this composes only what geometry forces — see decision 7.
///
/// The headline band is **empty unless the project fills it**. Passing a
/// builder is three lines and produces the composition everybody recognises;
/// passing nothing produces a clean, legal, unlabelled one. It is never
/// invented here, because a headline is a marketing decision.
class DefaultStoreFrame extends StoreFrame {
  const DefaultStoreFrame(
    super.shot, {
    super.key,
    this.headline,
    this.ground = const Color(0xFFF3F1EC),
    this.ink = const Color(0xFF1B1B19),
  });

  /// What to write above the device, or null for a band that draws nothing.
  final String? headline;

  /// The canvas behind everything. Opaque by contract.
  final Color ground;

  /// The headline's colour, and the device body's edge.
  final Color ink;

  /// The body's corner, in the **device's** own logical pixels.
  ///
  /// A corner belongs to the phone, not to the canvas it is drawn on, so this
  /// is scaled with the body like every other device measurement — see
  /// [_Body]. Declared in canvas units it was a constant while the thing it
  /// rounded changed size, which is a corner that grows tighter the larger the
  /// device is drawn.
  ///
  /// Keyed on the platform as well as the kind because the two phone families
  /// genuinely differ: an iPhone 16's corner is about an eighth of its width,
  /// an Android's nearer a sixteenth, and one number for both gives the
  /// Android a silhouette twice as round as the device it claims to be.
  double get _radius => switch ((shot.device.kind, shot.device.platform)) {
    (DeviceKind.phone, DevicePlatform.ios) => 55,
    (DeviceKind.phone, _) => 26,
    (DeviceKind.tablet, _) => 18,
    (DeviceKind.desktop, _) => 8,
  };

  @override
  Widget build(BuildContext context) {
    var canvas = shot.canvas;
    return Container(
      width: canvas.logicalWidth,
      height: canvas.logicalHeight,
      color: ground,
      child: Column(
        children: [
          // The band is laid out whenever there are words for it, and not
          // otherwise. Reserving it either way keeps a mixed set's devices at
          // one height — but a set with *no* headlines anywhere is the common
          // case for a project that declared no frame, and there it is a
          // sixth of the canvas of nothing, with the device floating below it
          // looking like a mistake. A project mixing the two passes an empty
          // string for the ones it wants blank.
          SizedBox(
            height: canvas.logicalHeight * (headline == null ? 0.07 : 0.16),
            child: headline == null
                ? null
                : Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: canvas.logicalWidth * 0.09,
                    ),
                    child: Center(
                      child: Text(
                        headline!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: ink,
                          fontSize: canvas.logicalWidth * 0.072,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
          ),
          // Bleeding off the bottom edge, which is the standard composition
          // because it uses a very tall canvas without leaving the device
          // stranded in the middle of it.
          //
          // Whether it *does* bleed is a race between two numbers, and the
          // margins below are what settle it: the body is scaled to the width
          // its padding leaves, so a narrower pair of margins makes it taller.
          // A phone is taller than the space under the band on Play's canvas —
          // which is the only place this frame is forced — so at these values
          // it overflows and the overflow is clipped away. The headline-less
          // pair is the tighter of the two on purpose: with no caption to make
          // room for there is more width to spend, and at the 0.09 it used to
          // share with the caption case the body came out 16 logical pixels
          // *short* of the space — no bleed, and 42 physical pixels of ground
          // under the device, which is the stranded look this composition
          // exists to avoid, arrived at from the other side. What was actually
          // drawn there was worse still, and the `minHeight` below is that
          // half: the floor stretched those 16 pixels back out of the picture.
          //
          // A device shorter than the space cannot bleed at any margin — that
          // would mean scaling past the canvas width and cropping the picture
          // sideways, which is the one thing a store screenshot must not do.
          // There it sits at the top of the space, and `defaultStoreFrame`
          // keeps it out of that case by handing those targets a
          // [PlainStoreFrame] instead.
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal:
                    canvas.logicalWidth * (headline == null ? 0.07 : 0.11),
              ),
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  // Both ends, and `minHeight` is the load-bearing one.
                  // `OverflowBox` inherits whichever bounds it is not given,
                  // and the bound here comes from an `Expanded` — which is
                  // tight. So a body shorter than the space was being
                  // stretched to fill it, and [_Body] paints the capture with
                  // `BoxFit.fill`: the picture came out squashed by however
                  // much it was short, silently, which is the one failure a
                  // store screenshot cannot survive. Releasing the floor lets
                  // a short body stay its own height and sit at the top of the
                  // space — visibly imperfect, and imperfect beats wrong.
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: _Body(
                    shot: shot,
                    radius: _radius,
                    edge: ink.withValues(alpha: 0.16),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The device, its corners rounded, with the app's capture inside it.
///
/// Sized from the capture's own logical size rather than from the canvas, so
/// the picture is never stretched: a `BoxFit.fill` here would make a 20:9
/// screenshot fit a 2:1 canvas by squashing it, which is the one failure a
/// store screenshot cannot survive.
class _Body extends StatelessWidget {
  const _Body({required this.shot, required this.radius, required this.edge});

  final StoreShot shot;
  final double radius;
  final Color edge;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scaled to the width it has been given; the height follows and the
        // overflow is what bleeds off the bottom.
        var scale = constraints.maxWidth / shot.imageSize.width;
        // Every device measurement below is in the device's own logical pixels
        // and reaches the canvas through this one multiplication — the corner,
        // the safe area, the chrome inside it. That is what keeps a body drawn
        // at 0.8 looking like the same phone as one drawn at 1.
        var corner = radius * scale;
        return SizedBox(
          width: constraints.maxWidth,
          height: shot.imageSize.height * scale,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(corner),
              border: Border.all(color: edge, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(corner),
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// What a frame is rendered inside — the opaque ground and the locale.
///
/// Used by the frame pass and by anything that wants to look at a frame the way
/// the export will produce it, which is what makes a `@Preview` of a frame
/// trustworthy rather than approximate.
class StoreFrameStage extends StatelessWidget {
  const StoreFrameStage({
    super.key,
    required this.shot,
    required this.child,
    this.background = const Color(0xFFFFFFFF),
  });

  final StoreShot shot;
  final Widget child;

  /// What shows wherever the frame paints nothing. White, because that is what
  /// an unpainted pixel becomes when the alpha channel comes off.
  final Color background;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Localizations(
      locale: shot.locale,
      delegates: const [
        DefaultMaterialLocalizations.delegate,
        DefaultWidgetsLocalizations.delegate,
      ],
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(shot.canvas.logicalWidth, shot.canvas.logicalHeight),
          devicePixelRatio: shot.canvas.pixelRatio,
        ),
        child: ColoredBox(
          color: background,
          child: SizedBox(
            width: shot.canvas.logicalWidth,
            height: shot.canvas.logicalHeight,
            child: child,
          ),
        ),
      ),
    ),
  );
}
