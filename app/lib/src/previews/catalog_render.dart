import 'dart:io';
import 'dart:typed_data';

// The knob types, not the umbrella `ui_catalog.dart`: that one exports the
// demo annotations, which reach `package:flutter/widgets.dart` and would make
// `fw` unlinkable.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/log.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axis.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';

import 'devices.dart';

/// Everything asked about **one** rendered build.
///
/// **What to render and what to read are one request on purpose.** `tree`,
/// `find`, `at`, `errors` and `logs` are not five capabilities — they are five
/// projections of one observation, with the same inputs and the same
/// precondition, and each used to pay a full compile-launch-render to answer
/// one question about a frame the others also had to produce. Three questions
/// was three renders, which for an agent in an edit loop is the dominant
/// per-iteration cost.
///
/// It also removes an assumption rather than only a cost. `screenshot
/// --annotate` read its own tree, so a caller that ran `tree` and then
/// `screenshot --annotate` got two trees from two processes; the ids on the
/// picture matched the ids in the tree because the build is deterministic, not
/// because they were the same object. Closing that loop was the entire point
/// of `--annotate`. One render, one tree, both projections off it.
///
/// A request is validated by whoever builds it, before anything is scanned or
/// compiled: a typo in a flag should cost nothing, and a compile-and-render is
/// the most expensive thing in the plugin.
class CatalogRender {
  const CatalogRender({
    required this.entryId,
    this.viewport = CaptureViewport.panel,
    this.knobs = const {},
    this.axes = const {},
    this.debug = const {},
    this.wantTree = false,
    this.wantLogs = false,
    this.wantKnobs = false,
    this.wantAxes = false,
    this.at,
    this.screenshot,
    this.annotate = false,
    this.cropNode,
    this.motionT,
    this.steps = const [],
    this.full = false,
  });

  final String entryId;

  /// The screen to stage: its size, its pixel ratio, its safe areas, its
  /// keyboard.
  final CaptureViewport viewport;

  /// Values the *preview* asked for while it built, as raw strings — a flag
  /// and a JSON object both arrive as text, and only the entry knows what kind
  /// each one is.
  final Map<String, String> knobs;

  /// Values for the shell *around* the preview — theme, locale, flavour.
  final Map<String, String> axes;

  /// The framework's own switches: `paint`, `brightness`, `timeDilation`.
  /// Neither the preview's nor the shell's, and a fixed set either way.
  final Map<String, String> debug;

  final bool wantTree;
  final bool wantLogs;
  final bool wantKnobs;
  final bool wantAxes;

  /// A point to hit-test, in logical pixels.
  final (double, double)? at;

  /// Where to write the picture. Null takes none.
  final String? screenshot;

  /// Draw a box and its node id over every widget.
  final bool annotate;

  /// Cut the picture down to one widget, by name or by tree id.
  final String? cropNode;

  /// Where to park the entry's motion, 0..1.
  final double? motionT;

  /// Drive verbs to run before anything is read or photographed, each in
  /// `act`'s wire spelling — every value a string.
  final List<Map<String, String>> steps;

  /// Grow the screen to what its lists hold, so one picture — and one
  /// tree — has all of them; a picture taller than the screen it started as
  /// is also cut into pages of that screen.
  final bool full;

  /// Whether the tree has to be read, which is more often than the caller
  /// asked for it: a hit resolves ids against a tree, a crop needs a node's
  /// rect, and an annotation needs every node's.
  ///
  /// Worked out here rather than by each backend, because a backend that
  /// disagreed about this would answer a question nobody could see it had been
  /// asked. A full picture is cut into pages between the rows the tree
  /// places.
  bool get needsTree =>
      wantTree || at != null || framed || (full && screenshot != null);

  /// Whether the picture has to be cut or drawn on after it is taken — which
  /// is what decides whether the shutter can *be* the settling frame.
  bool get framed => annotate || (cropNode?.isNotEmpty ?? false);

  /// Every field, so a field added and forgotten here is a compile error
  /// rather than a value that silently stops travelling.
  CatalogRender copyWith({
    String? entryId,
    CaptureViewport? viewport,
    Map<String, String>? knobs,
    Map<String, String>? axes,
    Map<String, String>? debug,
    bool? wantTree,
    bool? wantLogs,
    bool? wantKnobs,
    bool? wantAxes,
    (double, double)? at,
    String? screenshot,
    bool? annotate,
    String? cropNode,
    double? motionT,
    List<Map<String, String>>? steps,
    bool? full,
  }) => CatalogRender(
    entryId: entryId ?? this.entryId,
    viewport: viewport ?? this.viewport,
    knobs: knobs ?? this.knobs,
    axes: axes ?? this.axes,
    debug: debug ?? this.debug,
    wantTree: wantTree ?? this.wantTree,
    wantLogs: wantLogs ?? this.wantLogs,
    wantKnobs: wantKnobs ?? this.wantKnobs,
    wantAxes: wantAxes ?? this.wantAxes,
    at: at ?? this.at,
    screenshot: screenshot ?? this.screenshot,
    annotate: annotate ?? this.annotate,
    cropNode: cropNode ?? this.cropNode,
    motionT: motionT ?? this.motionT,
    steps: steps ?? this.steps,
    full: full ?? this.full,
  );
}

/// How each stop of a [CatalogWalk] is reached.
///
/// The distinction is the one the whole export rests on: a screen that reads
/// its playhead and draws is a **scene**, and a screen that reads its playhead
/// and then starts an animation of its own is a **state machine**. Both are
/// legitimate; they need different clocks.
enum WalkMode {
  /// Set the playhead, draw one frame, keep it.
  ///
  /// No time passes. Right for anything that is a function of `t` — which is
  /// what a motion is supposed to be, and what [CatalogWalk] checks by being
  /// renderable in any order.
  playhead,

  /// Set the playhead, then advance the clock by one frame of [CatalogWalk.fps]
  /// and let the screen settle.
  ///
  /// Right for a screen with animation of its own — an `AnimationController`,
  /// an implicit animation, a scroll physics simulation. Under a fake clock
  /// that advance is *exact* rather than however long the machine took, so a
  /// spring resolves to the same pixel every run. No real-time renderer can
  /// offer this, which is why the alternatives forbid such screens instead of
  /// rendering them.
  time,
}

/// A walk of one entry's playhead, and everything needed to reproduce it.
///
/// A walk is a **projection of many renders** exactly as [CatalogRenderer.capture]
/// is a projection of one, which is why it lives here beside [CatalogRender]
/// rather than on whichever backend happens to perform it.
class CatalogWalk {
  const CatalogWalk({
    required this.entryId,
    this.stops,
    this.viewport = CaptureViewport.panel,
    this.knobs = const {},
    this.axes = const {},
    this.scope,
    this.mode = WalkMode.playhead,
    this.fps = 30,
  });

  final String entryId;

  /// Playhead positions, 0..1, **in the order they are to be taken**, or null
  /// for the whole motion at [fps].
  ///
  /// Order is part of the request rather than a detail of the loop because it
  /// is the one thing that tells a scene from a state machine: taken
  /// backwards, a scene renders the same pictures and a state machine does
  /// not. `walk_determinism_test` is that comparison.
  ///
  /// Null is the ordinary case for a clip, and it is not a convenience: only
  /// the running motion knows how long it is, so a caller that computed stops
  /// itself would have to render once to ask. See `videoStops`, which is what
  /// answers it on the other side.
  final List<double>? stops;

  final CaptureViewport viewport;
  final Map<String, String> knobs;
  final Map<String, String> axes;

  /// Which mounted scope to drive; the only one when omitted.
  final String? scope;

  final WalkMode mode;

  /// Frames a second — what a stop is worth in [WalkMode.time], and what the
  /// clip is encoded at.
  final int fps;
}

/// A walk, and what the running motion said about itself while it was taken.
///
/// The facts ride with the frames rather than being asked for separately,
/// because only a mounted motion knows them: how long it is, and which
/// playhead was driven when the screen has more than one.
class CatalogWalkResult {
  const CatalogWalkResult({
    required this.frames,
    required this.durationMs,
    this.scope,
    this.scopes = const [],
  });

  /// The frames, in the order the stops were asked for.
  ///
  /// A stream because a clip is bigger than memory: sixty frames of a phone at
  /// 3x is about a gigabyte, and an encoder wants them one at a time anyway.
  final Stream<WalkFrame> frames;

  /// The motion's own duration, which is what decides a clip's frame count.
  final int durationMs;

  /// The playhead that was driven.
  final String? scope;

  /// Every playhead that was mounted, when there was more than one — so a walk
  /// of the wrong one is visible rather than merely wrong.
  final List<String> scopes;
}

/// One frame of a walk, as packed RGBA.
///
/// Packed rather than the embedder's padded-and-headed `.rawframe`, and
/// unencoded rather than a PNG: a walk's consumer is an encoder or a contact
/// sheet, and both would immediately undo a PNG. See `decodeTesterFrame` for
/// turning one into an image.
class WalkFrame {
  const WalkFrame({
    required this.t,
    required this.width,
    required this.height,
    required this.pixels,
  });

  /// The playhead position this frame is of.
  ///
  /// Carried rather than inferred from position in the stream, because pairing
  /// a frame with a stop by position is exactly the assumption that made the
  /// embedder's clips wrong.
  final double t;

  final int width;
  final int height;

  /// `width * height * 4` bytes, RGBA.
  final Uint8List pixels;
}

/// Something that can render one entry and answer questions about that frame.
///
/// The interface exists so the answer's shape is fixed while the engine behind
/// it is not: the embedder guest renders what a person is watching, and a
/// `flutter_tester` harness renders everything nobody is. Both answer a
/// [CatalogObservation], so the plugin's projections — `screen`, `find`, `at`,
/// `styles` — read the same thing either way.
abstract class CatalogRenderer {
  const CatalogRenderer();

  Future<CatalogObservation> render(CatalogRender request);

  /// Walks one entry's playhead, yielding a frame per stop.
  ///
  /// **Refused by default, and that is the honest answer for the embedder.**
  /// A guest advances its playhead on the UI thread while its host writes
  /// whatever the *rasteriser* presents, and nothing joins the two: pairing a
  /// written frame with a stop is positional, and measured over six trials of
  /// one motion the same walk came out differently in four of them, frames
  /// offset by a stop. A clip made that way is of the wrong moments and looks
  /// entirely plausible.
  ///
  /// A harness under a fake clock has no second thread to lose — the picture
  /// is rasterised from the layer tree the pump just produced — so it
  /// overrides this. A backend that cannot promise one frame per stop should
  /// say so here rather than offer a second, wrong, implementation.
  Future<CatalogWalkResult> walk(CatalogWalk request) => throw UnsupportedError(
    'this backend cannot walk a playhead: it pairs written frames with stops '
    'by position, and nothing guarantees one presented frame per stop. Render '
    'the walk on the `flutter_tester` harness.',
  );

  /// A picture, and the knobs the build that produced it declared.
  ///
  /// Concrete rather than abstract, and here rather than in a backend: a
  /// capture is a projection of a render, so a second implementation of it is
  /// a second chance to disagree about what a picture of an entry *is*.
  Future<CatalogCapture> capture(CatalogRender request) async {
    if (request.screenshot == null) {
      throw ArgumentError.value(
        request.screenshot,
        'screenshot',
        'a capture needs somewhere to write the picture',
      );
    }
    // The declared knobs always, whatever the request said: a caller comparing
    // them with what it asked for is the only way to notice a demo clamping
    // one, and `screenshot` reports them for exactly that reason.
    var observed = await render(request.copyWith(wantKnobs: true));
    return CatalogCapture(
      // The render was asked for a screenshot, so it took one or threw.
      file: observed.screenshot!,
      knobs: observed.knobs?.knobs ?? const [],
      scrolled: observed.revealed?.scrolled ?? 0,
      grown: observed.grown,
      drawnAt: observed.drawnAt,
      pages: observed.pages,
      errors: observed.errors.errors,
    );
  }
}

/// One rendered build, and everything the call asked about it.
///
/// Nullable per section rather than empty-per-section, and the distinction is
/// load-bearing: null means *not asked for*, empty means *asked and there is
/// nothing*. A demo that printed nothing and a demo whose logs were not
/// requested are different answers, and a caller that could not tell them apart
/// would read the second as the first.
///
/// The same shape whether the reading came from a fresh guest, from the session
/// a person has open, or from a harness under `flutter_tester`, so the paths
/// cannot drift in what they can report.
class CatalogObservation {
  const CatalogObservation({
    required this.errors,
    this.tree,
    this.logs,
    this.knobs,
    this.axes,
    this.hits,
    this.screenshot,
    this.stagedOn,
    this.revealed,
    this.grown,
    this.drawnAt,
    this.pages = const [],
  });

  /// Always read, whatever was asked for. It is the answer to "is this one
  /// broken", which is the question behind asking anything at all — and it
  /// costs a round trip against a guest that is already running.
  final InspectErrors errors;

  final InspectTree? tree;
  final InspectLogs? logs;

  /// The knobs the captured build declared, when they were asked for.
  ///
  /// Here rather than only on [CatalogRenderer.capture] because a picture and a
  /// list of the controls that produced it are two projections of one frame,
  /// like everything else here.
  final KnobReport? knobs;

  /// What the shell around the entry declared, when it was asked for — and
  /// which shell that was, which is the thing an entry with no shell answers
  /// `null` to.
  final AxisReport? axes;

  /// The node ids under the probed point, outermost first. Empty is an answer:
  /// there is nothing of the demo's there.
  final List<String>? hits;

  final File? screenshot;

  /// The screen it actually rendered on, as the backend read it back off its
  /// own binding — not what the request asked for.
  ///
  /// The one check on staging there is. Every other answer here looks exactly
  /// the same on the wrong surface as on the right one: the knobs a demo
  /// declares, the errors it reported, even a picture, which is only wrong in
  /// a way somebody has to already suspect. Null from a backend that does not
  /// report it.
  final StagedViewport? stagedOn;

  /// Where the `--node` ended up once it was brought on screen, when a
  /// backend did that. Null from one that does not, which crops the screen
  /// as it lay.
  final CatalogReveal? revealed;

  /// How far the screen grew for `--full`. Null when it was not asked for.
  final CatalogGrown? grown;

  /// The pixel ratio [screenshot] was drawn at, when it is lower than the
  /// screen's: a picture taller than the rasteriser's largest texture is
  /// drawn smaller rather than cut short. Null when it is the screen's own.
  final double? drawnAt;

  /// [screenshot], a screen at a time, when it is taller than one. Empty
  /// otherwise.
  final List<File> pages;
}

/// What growing the screen to its content did, as the backend reported it.
class CatalogGrown {
  const CatalogGrown({
    required this.from,
    required this.to,
    this.truncated = false,
  });

  /// The screen's height before and after, in logical pixels.
  final double from;
  final double to;

  /// Whether a list still had more to show when the screen stopped growing.
  final bool truncated;

  Map<String, Object?> toJson() => {
    'from': from.round(),
    'to': to.round(),
    if (truncated) 'truncated': true,
  };
}

/// What bringing a `--node` on screen did, as the backend reported it.
class CatalogReveal {
  const CatalogReveal({required this.id, required this.scrolled});

  /// The node in the tree *after* the scroll. What to crop and narrow to:
  /// the selector the caller passed may be an id, and an id is a position a
  /// scrolled list has since given to another row.
  final String? id;

  /// How far the lists moved, in logical pixels. Zero when it was already on
  /// screen.
  final double scrolled;
}

/// One picture, and what the build that produced it declared.
class CatalogCapture {
  CatalogCapture({
    required this.file,
    required this.knobs,
    this.scrolled = 0,
    this.grown,
    this.drawnAt,
    this.pages = const [],
    this.errors = const [],
  });

  final File file;

  /// How far `--full` grew the screen. Null when it was not asked for.
  final CatalogGrown? grown;

  /// The pixel ratio [file] was drawn at, when lower than the screen's.
  final double? drawnAt;

  /// [file], a screen at a time, when it is taller than one.
  final List<File> pages;

  /// How far the lists were scrolled to bring the `--node` on screen, in
  /// logical pixels — said, because a picture that is not of the entry at
  /// rest looks exactly like one that is.
  final double scrolled;

  /// What the entry reported *after* the values were applied — so a clamped or
  /// ignored value is visible rather than assumed.
  final List<KnobDescriptor> knobs;

  /// What the build complained about while it drew [file]. A picture of an
  /// entry that reported something is still a picture — often of the very
  /// thing that is wrong — so it is handed over with the complaint beside it
  /// rather than in place of it.
  final List<InspectError> errors;
}
