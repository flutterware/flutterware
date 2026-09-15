import 'dart:typed_data';

import '../inspect/node.dart';
import 'aim.dart';
import '../app_events/events.dart';
import 'motion.dart';
import 'notification.dart';

/// What a step is a picture *of* — the tester's half of
/// `ScenarioStepKind`, so the capture and the report cannot drift apart.
enum ScenarioCaptureKind { screen, document, notification }

/// One captured step, handed from [ScenarioTester]'s capture to whoever is
/// listening — the harness, when a scenario runs under the flutterware
/// runner.
class ScenarioStepCapture {
  ScenarioStepCapture({
    required this.index,
    required this.position,
    required this.parent,
    required this.branch,
    required this.name,
    required this.tags,
    this.kind = ScenarioCaptureKind.screen,
    this.bytes,
    this.format,
    this.width,
    this.height,
    this.texts = const [],
    this.screen,
    this.statusBrightness,
    this.navBrightness,
    this.payload,
    this.fileName,
    this.mimeType,
    this.notification,
    this.verb,
    this.target,
    this.aim,
    this.events = const [],
    this.eventsDropped = 0,
    this.motion = ScenarioMotionFrames.empty,
    this.motionInterval,
    this.settled = true,
    this.waited = true,
    this.landed = true,
    this.strayFrames = 0,
    this.failure,
    this.overflowErrors = 0,
    this.guessed,
    this.keyboard,
  });

  /// 1-based position in the scenario's capture sequence.
  final int index;

  /// Where this step sits in the scenario's *shape*: the split choices taken
  /// to reach it, then the count since the last one — `'#2'` on the trunk,
  /// `'0.1#3'` two splits deep.
  ///
  /// A choice is a branch's **index** in its `split`, not its label, so
  /// renaming a branch leaves every position under it untouched.
  ///
  /// [index] counts captures and so shifts for every step after an insertion;
  /// this shifts only within its own branch segment, which is what makes it
  /// worth writing down beside the index rather than instead of it.
  final String position;

  /// The [index] of the step this one follows, or null for the first. A
  /// linear scenario chains; a `split` gives one parent several children —
  /// the flow graph's edges, exactly.
  final int? parent;

  /// The `split` branch label when this is a branch's first capture; null
  /// everywhere else.
  final String? branch;

  /// The [Shot]'s name, or null for an automatic capture.
  final String? name;

  final List<String> tags;

  /// What this step is a picture of. A document and a notification carry no
  /// [bytes] and no [texts]: neither has a frame, so neither is rendered.
  final ScenarioCaptureKind kind;

  /// The image, in [format]: `png`, or `raw` — bare rgba8888 rows,
  /// [width]×[height]×4 bytes. Raw exists to skip the encoder, which costs
  /// ~7.5ms a picture; what that is worth against ~80× the bytes is measured
  /// on `ScenarioRunArgs.captureRaw`.
  ///
  /// Null on a step that is not a screen.
  final Uint8List? bytes;

  final String? format;
  final int? width;
  final int? height;

  /// A [ScenarioCaptureKind.document]'s bytes — the PDF, the email body, the
  /// payload the flow produced.
  final Uint8List? payload;

  /// What to call [payload] on disk, extension included. Defaults to the
  /// step's name made file-safe, which leaves a viewer nothing to go on — so
  /// a project that knows the extension should say it.
  final String? fileName;

  /// What [payload] is — `application/pdf`, `text/plain`. What a viewer
  /// switches on; a missing one means "offer it as a download".
  final String? mimeType;

  /// The push a [ScenarioCaptureKind.notification] step is.
  final ScenarioNotification? notification;

  /// The visible `Text` widgets, in tree order — the text projection.
  final List<String> texts;

  /// The widget tree and the semantics behind the picture, read where the
  /// picture was taken. Null under a bare `flutter test`, where nobody asked
  /// for either and nothing pays to read them.
  final ScenarioScreenRead? screen;

  /// The verb that produced this step (`tap`, `enterText`, `screen`, …) and
  /// what it was aimed at, when it was aimed at anything. Together they say
  /// what the transition *into* this step was, which is what turns an edge in
  /// the flow from an arrow into a sentence.
  final String? verb;
  final String? target;

  /// Where the verb's finger went, for the pointer verbs that have one — see
  /// [ScenarioAim].
  final ScenarioAim? aim;

  /// How [target] was named — a key, visible text, a type. What a comparison
  /// reads to know how far it can trust the label: an author's key is theirs
  /// alone, and visible text is translated, so `tap "Pay"` and `tap "Payer"`
  /// are one step run under two languages.
  /// What the app did on the way here: everything recorded between the
  /// previous capture and this one, in the order it happened.
  final List<AppEvent> events;

  /// Events dropped to stay inside the per-step or per-run cap. Reported
  /// rather than swallowed — silence would read as "the app did nothing".
  final int eventsDropped;

  /// What the transition *looked like* on the way here — every frame between
  /// the previous step and this one, when the run was recording. Empty
  /// otherwise, which is every run that did not ask.
  ///
  /// The same lifetime as [events], and for the same reason: both describe
  /// the edge into this step rather than the step itself.
  final ScenarioMotionFrames motion;

  /// The fake time between two of [motion]'s frames — what a player runs at
  /// to show the animation at its real speed. Null when nothing recorded.
  final Duration? motionInterval;

  /// The app's declared `SystemUiOverlayStyle` icon brightness at capture
  /// time (`light`/`dark`), or null when it never declared one. What the
  /// GUI's fake status bar and home indicator tint themselves with — wrong
  /// status-bar brightness is a shipped bug a screenshot exists to catch.
  final String? statusBrightness;
  final String? navBrightness;

  /// False when the verb's settle policy gave up with frames still scheduled
  /// — an indefinite animation on screen, which is worth seeing rather than
  /// failing on.
  final bool settled;

  /// Whether the policy this step ran under was one that waits for the app to
  /// go quiet — see `Settle.waits`.
  ///
  /// False and [settled] false together is a capture parked mid-flight on
  /// purpose: nothing gave up, because nothing was asked to wait.
  final bool waited;

  /// False when the shutter fell with work still in flight that the step was
  /// waiting for — an image decode or an asset read that had not finished
  /// after `realWorkWait`. The picture is of a screen that was still filling
  /// in, and the artwork it is missing is on the next step.
  ///
  /// Only ever false for work that *announced* itself. A decode nothing counts
  /// — a `FutureBuilder` on a real future — is still landed as far as this
  /// flag knows, because nothing here can tell "it has not arrived" from
  /// "there was never anything coming".
  final bool landed;

  /// Frames drawn between the previous step and this one that no verb drew —
  /// so they came from the raw `tester`, and whatever they showed is missing
  /// from the flow. Zero in a scenario written in verbs alone.
  final int strayFrames;

  /// How tall the software keyboard was when the frame was taken, in logical
  /// pixels, or null when it was down.
  ///
  /// A note about the screen, not a node in it. A real phone's keyboard is
  /// not in the app's tree either; the only reason to say it at all is that
  /// an agent looking at a shot with the bottom third gone cannot otherwise
  /// tell why.
  final double? keyboard;

  /// Set on the one step a scenario captures when it breaks: the error, with
  /// its split branch. The frame is the state at the failure.
  final String? failure;

  /// Layout overflow errors swallowed on the way to this frame — nonzero only
  /// under a translation budget probe, where the expansion filter records them
  /// as data instead of letting them fail the scenario. The same lifetime as
  /// [events]: they describe the edge into this step.
  final int overflowErrors;

  /// The turn of the real event loop on which work nothing announced landed
  /// and was drawn on the way to this frame — the deepest, when several did —
  /// or null when nothing needed guessing at. A hazard: see
  /// `ScenarioRunStep.guessed`.
  final int? guessed;
}

/// The tree behind one capture, and the semantics behind it.
///
/// Read at the shutter and carried on the capture rather than read off the
/// live app when the capture is handed over. A capture is held for one step so
/// that a `screen` can name it instead of taking a second picture of the same
/// frame, and by hand-over the app has acted again: a read there describes the
/// frame *after* this one. Measured on the example counter, where a step's own
/// [texts] said `Count: 0` beside a tree that said `Count: 1`.
class ScenarioScreenRead {
  const ScenarioScreenRead({required this.tree, this.semantics});

  final InspectTree tree;

  /// What a screen reader gets, or null where there is no semantics tree to
  /// read — which under `testWidgets`'s default handle is never, but a
  /// capture must not invent a screen.
  final Map<String, Object?>? semantics;
}

/// Hands over whatever capture the running scenario is still holding — the
/// automatic step waiting to see whether the next verb names it. Set by the
/// scenario as its tester is made, read by the harness at a deadline: a body
/// that hangs never reaches the verb that would have flushed it, and the
/// last picture it took would otherwise go with it.
void Function()? scenarioFlushHeld;

/// Where a step the running scenario never took belongs — its parent, its
/// split branch and its position — for the harness's deadline to put its
/// invented step there. Armed beside [scenarioFlushHeld], for the same
/// reader: the body is suspended, and only the scenario knows where in its
/// shape it is.
({int? parent, String? branch, String position}) Function()?
scenarioBreakPlacement;

/// Set by the flutterware harness beside [scenarioRunListener]: reads the
/// screen a capture is photographing, at the moment it is photographed.
///
/// Null under a bare `flutter test` — nothing there writes a tree, so nothing
/// there pays the ~1.5ms a read costs.
ScenarioScreenRead Function()? scenarioScreenReader;

/// Set by the flutterware harness for the duration of one scenario run; null
/// under a bare `flutter test`, where captures go to
/// `SCREENSHOTS_DESTINATION` instead (or nowhere).
///
/// Deliberately not exported from `package:flutterware/flutter_test.dart` —
/// it is the seam between the authoring API and the runner, not part of the
/// authoring API.
void Function(ScenarioStepCapture capture)? scenarioRunListener;

/// One exception the running scenario saw, kept whole.
///
/// [exception] is the thrown object itself — identity is what lets a report
/// tell whether an error it holds elsewhere is already in this list.
class ScenarioCaughtError {
  ScenarioCaughtError(this.exception, this.description, this.stack);

  final Object exception;
  final String description;
  final StackTrace? stack;
}

/// Set by the flutterware harness around one scenario; null under a bare
/// `flutter test`.
///
/// Exists because the test binding aggregates: a test with two exceptions
/// reports the single sentence "Multiple exceptions (2) were detected…" — no
/// stack, no exceptions, just the count — and dumps the real ones to a
/// console the runner does not show. So the scenario body chains
/// `FlutterError.onError` into this buffer while it runs, and the harness
/// reports each exception with its own message and its own stack instead of
/// the counter.
List<ScenarioCaughtError>? scenarioCaughtErrors;
