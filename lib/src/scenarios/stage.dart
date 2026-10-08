import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../render/offscreen.dart';
import 'film_cursor.dart';

export 'film_cursor.dart' show CursorLook;
import 'reel.dart';

/// What a reel is drawn *through*.
///
/// The film renders the app and nothing else. A stage is the picture around
/// it: the cursor, a caption, a frame, a camera, a second device beside it.
/// It is an ordinary widget tree, so it lays out with `Row` and reads its type
/// from a theme like anything else, and the app's frame is one widget in it —
/// [Screen].
///
/// Why a tree and not a canvas: the moment a stage can zoom, a cursor painted
/// onto the app's pixels grows with the app, and a caption hand-laid on a
/// canvas is a `TextPainter` and a stack of offsets. Both are free here.
abstract class ReelStage {
  const ReelStage();

  /// How big the output is, given the app's own frame in logical pixels.
  ///
  /// The default is the app's own size — a reel the size of the thing it is
  /// of. A stage that frames, letterboxes or lays two devices side by side
  /// says so here, and places [Screen] wherever it likes inside it.
  Size sizeFor(Size screen) => screen;

  /// Called with the moment before the tree is pumped for it.
  ///
  /// Where a stage that is *driven* moves its own state — a scene applying
  /// its motion at [StageFrame.at] — so that [build] stays what it looks
  /// like: a function of the frame, with no side effect in it.
  void before(StageFrame frame) {}

  /// The picture at this moment.
  Widget build(StageFrame frame);
}

/// One moment, as a stage sees it.
class StageFrame {
  const StageFrame({
    required this.screen,
    required this.screenSize,
    required this.at,
    required this.pointer,
    required this.down,
    required this.sincePress,
    required this.touch,
    this.cues = const [],
  });

  /// The app's own frame, rasterised at the film's scale. Null before the
  /// first one — a stage drawing a title card over nothing.
  final ui.Image? screen;

  /// The app's size in logical pixels. What [Screen] draws [screen] at, and
  /// what a camera's rects are in.
  final Size screenSize;

  /// Where this frame sits in the reel.
  final Duration at;

  /// Where the finger or the pointer is, in the app's logical pixels, or null
  /// before anything has been touched.
  final Offset? pointer;

  final bool down;

  /// Seconds since the press began, or null before the first one — what a
  /// ripple is drawn from.
  final double? sincePress;

  /// Whether the stage is touched or pointed at. The device's answer, never a
  /// setting: an arrow on a phone is showing something that never happens.
  final bool touch;

  /// What the reel is saying over this stretch of output, with the span of
  /// each — so a stage can draw a caption fading in from where it is inside
  /// one. Empty for a film with no reel.
  final List<CueSpan> cues;

  /// The live cue of type [T], or null.
  CueSpan? cue<T>() => cues.where((span) => span.cue is T).firstOrNull;
}

/// The app's frame, as a widget.
///
/// Drawn at the app's own logical size, so a stage positions it in logical
/// pixels and the film's scale is nothing the stage has to know about.
class Screen extends StatelessWidget {
  const Screen({super.key, this.filterQuality = FilterQuality.medium});

  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    var frame = StageScope.of(context);
    return SizedBox.fromSize(
      size: frame.screenSize,
      child: frame.screen == null
          ? null
          : RawImage(
              image: frame.screen,
              width: frame.screenSize.width,
              height: frame.screenSize.height,
              fit: BoxFit.fill,
              filterQuality: filterQuality,
            ),
    );
  }
}

/// The cursor, as a widget — a fingertip or an arrow, wherever the pointer is.
///
/// Positioned in the app's logical pixels, so a stage that moves or scales
/// [Screen] must put this under the same transform or the finger will point
/// somewhere the app is not.
class Pointer extends StatelessWidget {
  const Pointer({super.key, this.look = CursorLook.standard});

  /// What the cursor is drawn in. The default is the film's own; a reel
  /// hands one over through `PointerArgs`.
  final CursorLook look;

  @override
  Widget build(BuildContext context) {
    var frame = StageScope.of(context);
    if (frame.pointer == null) return const SizedBox.shrink();
    return SizedBox.fromSize(
      size: frame.screenSize,
      child: CustomPaint(
        painter: _CursorPainter(
          ScenarioFilmCursor(touch: frame.touch, look: look),
          frame.pointer!,
          frame.down,
          frame.sincePress,
        ),
      ),
    );
  }
}

class _CursorPainter extends CustomPainter {
  _CursorPainter(this.cursor, this.at, this.down, this.sincePress);

  final ScenarioFilmCursor cursor;
  final Offset at;
  final bool down;
  final double? sincePress;

  @override
  void paint(Canvas canvas, Size size) =>
      cursor.paint(canvas, at, down: down, sincePress: sincePress);

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.at != at ||
      old.down != down ||
      old.sincePress != sincePress ||
      old.cursor.look != cursor.look ||
      old.cursor.touch != cursor.touch;
}

/// Hands the moment down the stage's tree.
class StageScope extends InheritedWidget {
  const StageScope({super.key, required this.frame, required super.child});

  final StageFrame frame;

  static StageFrame of(BuildContext context) {
    var scope = context.dependOnInheritedWidgetOfExactType<StageScope>();
    if (scope == null) {
      throw FlutterError(
        'Screen and Pointer only work inside a stage, because they draw the '
        'frame a reel is being rendered for.',
      );
    }
    return scope.frame;
  }

  @override
  bool updateShouldNotify(StageScope old) => old.frame != frame;
}

/// A stage, mounted once and pumped per frame.
///
/// Mounted once because a build is the expensive half: the tree is the same
/// tree every frame, and what changes is one [StageFrame] handed down an
/// inherited widget. Nothing here goes near the binding — the app's own tree
/// is the binding's, and a stage that shared it would put its captions where
/// a finder could match them.
class MountedStage {
  MountedStage(
    this.stage, {
    required this.screenSize,
    required this.scale,
    required this.touch,
  }) {
    size = stage.sizeFor(screenSize);
    _mounted = OffscreenWidget.mount(
      ValueListenableBuilder<StageFrame?>(
        valueListenable: _frame,
        builder: (context, frame, _) => frame == null
            ? const SizedBox.shrink()
            : StageScope(frame: frame, child: stage.build(frame)),
      ),
      size: size,
    );
  }

  final ReelStage stage;

  /// The app's frame in logical pixels.
  final Size screenSize;

  /// Output pixels per logical pixel.
  final double scale;

  final bool touch;

  /// The output's size in logical pixels — what [ReelStage.sizeFor] answered.
  late final Size size;

  late final OffscreenWidget _mounted;
  final _frame = ValueNotifier<StageFrame?>(null);

  /// What the framework caught while building the stage. A throwing stage
  /// renders as Flutter's error box and would otherwise be a clean-looking
  /// success.
  List<FlutterErrorDetails> get errors => _mounted.flutterErrors;

  /// Draws one moment.
  ///
  /// Sync, and deliberately: `toImageSync` defers the raster the way the
  /// film's own capture does, so the pixels are paid for once, later, in the
  /// `runAsync` a batch of them is written in.
  ui.Image render(StageFrame frame) {
    stage.before(frame);
    _frame.value = frame;
    _mounted.pump();
    return _mounted.boundary.toImageSync(pixelRatio: scale);
  }

  void dispose() {
    _mounted.dispose();
    _frame.dispose();
  }
}

/// The stage a film gets when nobody named one: the app, and a cursor over it.
///
/// What the video lane drew before a stage existed, expressed as one — which
/// is the parity check on the whole idea.
class BareStage extends ReelStage {
  const BareStage();

  @override
  Widget build(StageFrame frame) =>
      const Stack(children: [Screen(), Pointer()]);
}
