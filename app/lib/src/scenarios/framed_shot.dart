// Theirs hidden, as everywhere but the one file that borrows their bodies:
// `Devices` here is our offered table, which is what a shot is filed under.
import 'package:device_frame/device_frame.dart' hide Devices;
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/store.dart' show StatusChrome;

import '../previews/catalog_devices.dart';
import '../plugins/native/scenarios_results.dart';
import '../ui/theme.dart';
import 'artifacts.dart';

/// A captured step, in the silhouette of the device it ran as, wearing the
/// status chrome a real screenshot would have.
///
/// The silhouette is [deviceFrameFor]'s, the same one the preview canvas
/// draws — hand-drawn where a body exists, generic where none does. It used to
/// keep its own named-body mapping here, which is how the same iPhone came to
/// wear a notch in the flow and a lozenge in previews. Desktop sizes and the
/// bare test surface get a plain border: a monitor body around a rectangle
/// explains nothing.
///
/// Over the screen, the **fake status bar** (time, network, battery) and the
/// home indicator, tinted by the `SystemUiOverlayStyle` the app declared at
/// capture time — dev_studio's trick, kept because a status bar of the wrong
/// brightness is a shipped bug a screenshot exists to catch. Drawn by
/// `StatusChrome`, which the store frame draws too: this was a copy of it
/// until the two disagreed about how big an Android clock is.
///
/// Reads the frame through the [ScenarioArtifactsScope] above it, which is
/// what lets the same widget draw a step off a worktree's disk in the panel
/// and off an HTTP server on the exported page.
///
/// Unconstrained: renders at the device's logical size plus bezels. Put it in
/// a `FittedBox` (the flow graph does) or size it from outside.
class FramedShot extends StatelessWidget {
  const FramedShot({
    super.key,
    required this.step,
    required this.device,
    this.orientation,
    this.fallbackBrightness = Brightness.dark,
    this.screenOverlay,
    this.image,
  });

  final ScenarioRunStep step;

  /// What to draw on the screen instead of the step's own shot — a frame of
  /// the recorded transition, while one is playing.
  ///
  /// Only the pixels change: the device body, the status chrome and the
  /// screen's logical size all stay the step's, which is what lets a node on
  /// the flow canvas play in place without a single pixel of layout moving.
  /// A recording is captured at half scale and stretched back over the same
  /// box — the frame is the motion, the shot is the evidence.
  final ImageProvider? image;

  /// The device the run was framed as, **upright**, or null for the bare
  /// surface. [orientation] turns it.
  final Device? device;

  /// Which way up the run was, or null for portrait.
  ///
  /// Kept apart from [device] all the way down here because the two halves of
  /// the picture want different answers: the *body* is drawn from the upright
  /// device and rotated by `DeviceFrame` — which is what makes a hand-drawn
  /// iPhone work, its artwork being portrait — while the *screen* is sized and
  /// its chrome placed from the rotated one.
  final ScreenOrientation? orientation;

  /// Drawn over the screen, inside the frame — **in the screen's own logical
  /// coordinates**, which are exactly the guest coordinates a capture and its
  /// tree were taken in. The inspector's highlight and picker live here, and
  /// because the box is the guest's logical size they need no transform: they
  /// inherit the `FittedBox` and the device body above, like the catalog's
  /// overlay does.
  final Widget? screenOverlay;

  /// Icon brightness when the app declared no `SystemUiOverlayStyle` —
  /// derived from the brightness axis by the caller, so a dark-mode run
  /// defaults to light icons.
  final Brightness fallbackBrightness;

  Brightness _brightness(String? declared) => switch (declared) {
    'light' => Brightness.light,
    'dark' => Brightness.dark,
    _ => fallbackBrightness,
  };

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: this.image ?? ScenarioArtifactsScope.of(context).imageOf(step),
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
      // A frame that has not decoded yet holds the one before it rather than
      // blinking the screen out — the only thing that makes playback survive
      // a cold image cache.
      gaplessPlayback: true,
    );
    var resolved = device;
    if (resolved == null) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.line),
        ),
        child: SizedBox(
          width: (step.width ?? 0).toDouble(),
          height: (step.height ?? 0).toDouble(),
          child: Stack(fit: StackFit.expand, children: [image, ?screenOverlay]),
        ),
      );
    }
    // The screen is the *rotated* device: `DeviceFrame` hands its child a box
    // that has already traded width for height, so a portrait-shaped one would
    // be stretched to fill it — a landscape shot squashed back into a portrait
    // aspect, distorted without erroring.
    var effective = resolved.oriented(orientation);
    var screen = SizedBox(
      width: effective.width,
      height: effective.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          StatusChrome(
            // Rotated too, which is the whole of what landscape chrome needs:
            // an iPhone's landscape `insetTop` is 0, so `StatusChrome` draws
            // no status bar — exactly what the real thing does — while the
            // home indicator keeps its 21 at the interface bottom.
            device: effective,
            statusBrightness: _brightness(step.statusBrightness),
            navBrightness: _brightness(step.navBrightness),
          ),
          ?screenOverlay,
        ],
      ),
    );
    // Upright: the body is artwork, and `DeviceFrame` turns it.
    var chrome = deviceFrameFor(resolved);
    if (chrome == null) {
      // A desktop size: a hairline, not a monitor body. Nothing to rotate —
      // `canRotate` already told [effective] as much.
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.line),
        ),
        child: screen,
      );
    }
    return DeviceFrame(
      device: chrome,
      screen: screen,
      orientation: orientation == ScreenOrientation.landscape
          ? Orientation.landscape
          : Orientation.portrait,
    );
  }
}
