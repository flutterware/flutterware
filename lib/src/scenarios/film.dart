import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'aim.dart';
import 'cues.dart';
import 'film_settings.dart';
import 'motion.dart';
import 'mouse.dart';
import 'reel.dart';
import 'stage.dart';
import 'take.dart';

export 'cues.dart';
export 'film_settings.dart';

/// Records a scenario as a film: every pumped frame, the cursor over it, and
/// the beats that say what each stretch of it is.
///
/// The one sink that is also a *scheduler*. [ScenarioMotionRecorder] follows a
/// settle loop it does not own; this one both follows the settle loops — the
/// same `record:` hook, so no verb had to learn anything — and drives loops of
/// its own between them, which is where a pause, a travel and a press come
/// from. Those beats pump the clock without acting, so a spinner keeps
/// spinning and a game keeps playing while the "user" is doing nothing. That
/// is the whole reason a film is a re-run rather than a post-process: a hold
/// over a run that already happened is one still repeated.
class ScenarioFilm implements ScenarioFrameSink {
  ScenarioFilm(
    this.settings, {
    required this.scenario,
    this.touch = true,
    this.beforePump,
    this.stage = const BareStage(),
    this.reel,
    this.edit,
  }) {
    // The checked-mode banner is the app's own widget and a film is of the
    // app, so this is the one thing a film run turns off in the tree it is
    // filming: nobody puts a debug ribbon on a landing page, and asking every
    // project to set `debugShowCheckedModeBanner: false` to be filmable would
    // be asking them to change their app for our benefit. Put back by
    // [finish], because a scenario run after this one is evidence again.
    WidgetsApp.debugAllowBannerOverride = false;
    var directory = Directory(settings.directory);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    directory.createSync(recursive: true);
  }

  final FilmSettings settings;

  /// The scenario being filmed, for the timeline and for the refusal a second
  /// one earns.
  final String scenario;

  /// Whether the stage is touched or pointed at — a fingertip or an arrow.
  /// The stage's own answer, never a setting: a film showing an arrow on a
  /// phone is showing something that never happens.
  final bool touch;

  /// Run before every frame the film pumps of its own — the same hook the
  /// settle policies give the keyboard, and for the same reason: a slab that
  /// only moves between a *policy's* frames does not move at all during a
  /// beat, and the keyboard would arrive after the typing it is for.
  final void Function()? beforePump;

  /// What the frames are drawn through — the cursor, and whatever else the
  /// picture is. [BareStage] is the app with a cursor over it, which is what
  /// a film was before a stage existed.
  final ReelStage stage;

  /// The stage in force: the reel's when there is a reel, because an edit
  /// that built a picture built it for its own timing.
  ReelStage get _stageInForce => reel?.stage ?? stage;

  /// What the output shows and when, or null for a film that is one output
  /// frame per pumped frame — which is what a film was before a reel existed.
  final Reel? reel;

  /// How the scenario asked to be cut, or null where it said nothing.
  ///
  /// Carried and not used: a film pumps what it is told and an edit runs
  /// *between* two films. It rides here so that whoever ran the dry pass
  /// finds the edit beside the take it is for, without having to know how
  /// `scenario()` resolved it.
  final ScenarioReelEdit? edit;

  /// The timeline [finish] wrote, or null until then.
  Map<String, Object?>? _timeline;

  /// What this film knows about the run it filmed, as types — the dry pass's
  /// whole product, and what an edit is handed.
  ///
  /// Only after [finish]; asked earlier it refuses, because a take of a film
  /// still running would be a take with no end.
  Take get take {
    var timeline = _timeline;
    if (timeline == null) {
      throw StateError('the film has not finished, so there is no take yet');
    }
    return Take.decode(timeline, cues: said);
  }

  late final _projector = reel == null
      ? null
      : _Projector(reel!, fps: settings.fps);

  MountedStage? _stage;

  /// The frame a freeze repeats.
  ///
  /// Held rather than re-read: a frozen shot shows the last thing the app
  /// drew, and by the time it is written the source frame it came from has
  /// been rasterised and let go.
  ui.Image? _held;

  /// The app's own frame in logical pixels, read off the view the first time
  /// one is captured.
  Size? _screenSize;

  @override
  Duration get interval => settings.frame;

  /// Frames kept so far, which is also the next frame's number.
  int get frames => _frames;
  var _frames = 0;

  /// Frames refused by [FilmSettings.maxFrames].
  int get dropped => _dropped;
  var _dropped = 0;

  final _banked = <_Banked>[];
  final _samples = <Map<String, Object?>>[];
  final _beats = <Map<String, Object?>>[];
  Map<String, Object?>? _beat;

  /// Where the pointer is, in the view's logical pixels — the space
  /// [ScenarioAim] is in, so a target's point needs no transform.
  ///
  /// Null until the first beat gives it somewhere to be: a film that opens on
  /// a cursor parked in the middle of the screen opens on a lie about a user
  /// who has not arrived yet.
  Offset? _pointer;
  var _down = false;

  /// The frame the current press went down on, kept after the finger lifts:
  /// the ripple outlives the press, which is what makes a tap read as a tap
  /// rather than as a cursor that flickered.
  int? _pressedAt;

  int? _width;
  int? _height;

  /// Keeps whatever is on screen, at the film's scale.
  ///
  /// Sync, and deliberately: `toImageSync` rasterises without leaving
  /// `FakeAsync`, so the pump loop pays for a frame's pixels once, later, in
  /// the `runAsync` [flush] opens for a whole batch of them.
  @override
  void capture(WidgetTester tester) {
    if (_frames >= settings.maxFrames) {
      _dropped++;
      return;
    }
    var view = tester.binding.renderViews.singleOrNull;
    if (view == null) return;
    // No root layer before the first paint, which is not an error: it is the
    // film not having started yet.
    var layer = view.debugLayer;
    if (layer is! OffsetLayer) return;
    _screenSize ??= view.size;
    if (_pointer case var at?) {
      _samples.add({
        'frame': _frames,
        'x': _round(at.dx),
        'y': _round(at.dy),
        if (_down) 'down': true,
      });
    }
    if (settings.pixels) {
      var dpr = view.flutterView.devicePixelRatio;
      var image = layer.toImageSync(
        Offset.zero & (view.size * dpr),
        pixelRatio: settings.scale / dpr,
      );
      _banked.add(
        _Banked(_frames, image, _pointer, _down, switch (_pressedAt) {
          null => null,
          var at => (_frames - at) / settings.fps,
        }),
      );
    } else {
      // A dry pass measures the frame it is not drawing. The size is the one
      // thing about a film only a rasterised frame usually knows, and an edit
      // lays its stage out against it — so it is asked of the stage instead,
      // which is where the answer comes from when there are pixels too.
      var output = _stageInForce.sizeFor(view.size);
      _width ??= (output.width * settings.scale).round();
      _height ??= (output.height * settings.scale).round();
    }
    _frames++;
  }

  /// Writes the bank out when it is full enough to be worth a turn of the real
  /// event loop. Called by the settle loops after every frame they capture.
  @override
  Future<void> flush(WidgetTester tester) async {
    if (_banked.length < settings.batch) return;
    await _write(tester);
  }

  /// The opening hold: the app is on screen and nothing has been touched.
  Future<void> open(WidgetTester tester) async {
    _mark('open');
    await _hold(tester, settings.open);
  }

  /// Flies the cursor to what the verb is about to act on, and presses — once,
  /// twice for a `doubleTap`, and not at all for a `hover` or a wheel `scroll`.
  ///
  /// Runs *between* the target resolving and the gesture firing, which is the
  /// only moment both facts are true: the box has been measured, and the app
  /// has not yet been touched. The frames it pumps are the app's own — it is
  /// still running, and on a screen that animates by itself the travel is not
  /// a still with a dot sliding over it.
  Future<void> approach(
    WidgetTester tester,
    ScenarioAim aim, {
    String? verb,
    String? target,
  }) async {
    var (x, y) = aim.point;
    var to = Offset(x, y);
    var from = _pointer ?? _offstage(tester, to);
    _mark('travel', verb: verb, target: target, aim: aim);
    // What separates a hand from a `lerp`: how long the reach takes, and how
    // the speed is spent along it. See [_travelFor] and [_reach].
    await _hold(
      tester,
      _travelFor((to - from).distance),
      move: (t) => _pointer = _reach(from, to, t),
      // A mouse really moves, and a desktop app answers: rows highlight and
      // buttons tint as the pointer crosses them, which is most of what makes
      // a desktop reel look like somebody using the app rather than a
      // slideshow with an arrow on it. A phone has no hover, so nothing is
      // dispatched there and the mark is the whole of it.
      hover: touch ? null : tester,
    );
    _pointer = to;
    // Arrived, not yet pressed. See [FilmSettings.aim].
    _mark('aim', verb: verb, target: target, aim: aim);
    await _hold(tester, settings.aim);
    switch (verb) {
      // Nothing goes down. A hover *is* the arrival, and a wheel turns under a
      // resting hand — a press drawn here would be a click that never happened.
      case 'hover' || 'scroll':
        break;
      // Two presses with the lift between them visible, or the film shows a
      // tap: the pair is what makes it a double tap.
      case 'doubleTap':
        var half = settings.press * 0.5;
        await _press(tester, half, verb: verb, target: target, aim: aim);
        _down = false;
        await _hold(tester, half);
        await _press(tester, half, verb: verb, target: target, aim: aim);
      // A held press is held. `tester.longPress` spends no fake time — it
      // dispatches a down, a delay the fake clock swallows and an up — so
      // without this the two verbs are the same picture, and which one it was
      // is the whole difference between opening a menu and pressing a button.
      case 'longPress' when settings.press < _longPress:
        await _press(tester, _longPress, verb: verb, target: target, aim: aim);
      case _:
        await _press(
          tester,
          settings.press,
          verb: verb,
          target: target,
          aim: aim,
        );
    }
    _mark('act', verb: verb, target: target, aim: aim);
  }

  /// The pointer goes down where it is, and stays down for [length].
  Future<void> _press(
    WidgetTester tester,
    Duration length, {
    String? verb,
    String? target,
    ScenarioAim? aim,
  }) async {
    _mark('press', verb: verb, target: target, aim: aim);
    _down = true;
    _pressedAt = _frames;
    await _hold(tester, length);
  }

  /// Names the stretch about to be filmed — the verb's own frames.
  ///
  /// Marked by every verb, including the ones with no finger: a beat is how
  /// the timeline says what a stretch of film *is*, and a `scrollTo` that
  /// named nothing would leave its frames belonging to whatever came before.
  void act({String? verb, String? target, ScenarioAim? aim}) {
    _verbTarget = target;
    _mark('act', verb: verb, target: target, aim: aim);
  }

  /// What the verb now running named, kept from [act].
  ///
  /// [approach] runs *inside* the verb and is told the aim but not the word
  /// the author wrote, and its marks are the ones that survive — the mark
  /// [act] makes before it covers no frames and is dropped. Without this a
  /// take reads back a tap that named nothing.
  String? _verbTarget;

  /// How long a `longPress` is held for, when the beat is shorter.
  ///
  /// Material's own threshold is 500ms and this is what a viewer has to *see*
  /// to read the press as held, so it is the floor rather than a setting.
  static const _longPress = Duration(milliseconds: 550);

  /// Types [text] into whatever [set] puts it in, a character at a time.
  ///
  /// `enterText` sets the whole value in one pump, which in a film reads as a
  /// paste — the single most obviously synthetic moment there is. So the verb
  /// hands its setter over and the pacing is decided here, where every other
  /// beat's is.
  ///
  /// The finger lifts first: it tapped the field, and what types is not it.
  Future<void> type(
    WidgetTester tester,
    String text,
    Future<void> Function(String value) set, {

    /// Where the field is *now* — asked every frame while the keyboard
    /// arrives, because it does not arrive alone. A keyboard takes a third of
    /// the screen and the form goes up with it, and a finger left at the
    /// coordinate it tapped ends up parked in the middle of the keyboard,
    /// about to press a key it never presses. It rides the field instead.
    Offset? Function()? follow,
  }) async {
    _down = false;
    // **Focus first, and let the keyboard arrive.** On a phone the field is
    // tapped, the keyboard slides up, and *then* the words appear; typing into
    // a screen with no keyboard on it and raising one afterwards is the order
    // nothing does. The empty value is what focuses the editable — the same
    // call the characters go in through, so there is no second way in.
    await set('');
    _mark('focus', verb: 'enterText');
    await _untilQuiet(tester, follow: follow);
    _mark('type', verb: 'enterText', target: text);
    for (var i = 1; i <= text.length; i++) {
      await set(text.substring(0, i));
      // A word gap. The cheapest unevenness there is, and unevenness is most
      // of what separates typing from a ticker.
      await _hold(
        tester,
        text[i - 1] == ' ' ? settings.typing * 1.6 : settings.typing,
      );
    }
    // Whatever the field does about the text it now has belongs to the verb,
    // not to the typing — the same handover [approach] makes after its press.
    _mark('act', verb: 'enterText');
  }

  /// Drags the finger by [by], a frame at a time, from wherever it is.
  ///
  /// The app moves *because* the finger does, so the two have to move
  /// together: a scenario's own drag dispatches down, move and up with no
  /// frames between them, and a film of it shows a list that teleports.
  ///
  /// [over] is the author's own duration where the verb named one — a fling,
  /// where the velocity is the point — and null otherwise. That difference is
  /// the whole of what happens at the end: a fling lifts while still moving,
  /// and a plain drag holds still first, reporting the same position for long
  /// enough that the velocity tracker estimates zero and the list stops where
  /// the suite's own drag stopped it.
  Future<void> dragBy(WidgetTester tester, Offset by, {Duration? over}) async {
    if (_pointer == null) return;
    _mark('drag', verb: 'drag');
    // The verb's own pointer: on a desktop the drag is the mouse the travel
    // hovered with, not a finger that appears for it.
    await _swipe(tester, by, over: over, mouse: !touch);
    _mark('act', verb: 'drag');
  }

  /// Swipes the pane until [until] says the target is there.
  ///
  /// `scrollTo` is the one verb that acts on a *region* rather than on a point,
  /// and the mark on the step says so — which is right for the step and wrong
  /// for a film: a list that scrolls itself is the one thing in a reel that
  /// reads as a bug rather than as a user. So the finger does what a thumb
  /// does, once per iteration of the walk the verb was going to take anyway:
  /// land in the pane, drag by the step, lift, reach back, again.
  ///
  /// Deliberately no velocity, exactly as [dragBy] has none by default: the
  /// walk moves the list by [by] per iteration and the suite's own does too, so
  /// a filmed `scrollTo` stops on the same iteration and leaves the list where
  /// the suite leaves it.
  Future<void> scroll(
    WidgetTester tester, {
    required Rect pane,
    required Offset by,
    required bool Function() until,
    required int maxScrolls,
  }) async {
    // Centred in the pane, so the whole swipe stays on the thing it scrolls.
    var start = Offset(
      (pane.center.dx - by.dx / 2).clamp(pane.left + 8, pane.right - 8),
      (pane.center.dy - by.dy / 2).clamp(pane.top + 8, pane.bottom - 8),
    );
    for (var swipe = 0; swipe < maxScrolls && !until(); swipe++) {
      var from = _pointer ?? _offstage(tester, start);
      _mark('travel', verb: 'scrollTo');
      await _hold(
        tester,
        // The reach back between swipes is shorter than a reach to a button:
        // the hand is already there, and a thumb returning to swipe again is
        // the quickest movement in the vocabulary.
        swipe == 0
            ? _travelFor((start - from).distance)
            : settings.travel * 0.5,
        move: (t) => _pointer = _reach(from, start, t),
      );
      _pointer = start;
      if (swipe == 0) {
        _mark('aim', verb: 'scrollTo');
        await _hold(tester, settings.aim);
      }
      _mark('swipe', verb: 'scrollTo');
      await _swipe(tester, by);
    }
    _mark('act', verb: 'scrollTo');
  }

  /// One drag: down where the cursor is, along [by] a frame at a time, and up.
  ///
  /// [over] is the author's own duration where the verb named one — a fling,
  /// where the velocity is the point — and null otherwise. That difference is
  /// the whole of what happens at the end: a fling lifts while still moving,
  /// and a plain drag holds still first, reporting the same position for long
  /// enough that the velocity tracker estimates zero and the list stops where
  /// the suite's own drag stopped it.
  ///
  /// [mouse] drags with the scenario's mouse rather than a finger, as a
  /// `drag` does on a desktop. A `scrollTo` never does: it walks a list with
  /// a finger wherever it is staged, because a mouse drag does not move one.
  Future<void> _swipe(
    WidgetTester tester,
    Offset by, {
    Duration? over,
    bool mouse = false,
  }) async {
    var start = _pointer;
    if (start == null) return;
    var length = over ?? settings.drag;
    var frames = math.max(
      1,
      (length.inMicroseconds / interval.inMicroseconds).round(),
    );
    _down = true;
    _pressedAt ??= _frames;
    Future<void> Function(Offset to) move;
    Future<void> Function() lift;
    if (mouse) {
      var pointer = ScenarioMouse.of(tester);
      await pointer.down(start);
      (move, lift) = (pointer.moveTo, pointer.up);
    } else {
      var finger = await tester.startGesture(start);
      (move, lift) = (finger.moveTo, finger.up);
    }
    try {
      for (var i = 1; i <= frames; i++) {
        // Eased like a reach, for the same reason: a finger starts and stops.
        var t = i / frames;
        var e = t * t * t * (10 - 15 * t + 6 * t * t);
        _pointer = start + by * e;
        await move(_pointer!);
        beforePump?.call();
        await tester.pump(interval);
        capture(tester);
        await flush(tester);
      }
      if (over == null) {
        for (var i = 0; i < _stillFrames; i++) {
          // Stationary *moves*, not stillness: a finger resting on glass keeps
          // reporting, and it is those samples that bring the estimate down.
          // Pumping without them leaves the tracker holding the last velocity
          // it saw and the list flies on.
          await move(_pointer!);
          beforePump?.call();
          await tester.pump(interval);
          capture(tester);
          await flush(tester);
        }
      }
    } finally {
      await lift();
      _down = false;
    }
  }

  /// How long the finger rests before it lifts from a drag that is not a
  /// fling. A velocity estimate looks back 100ms, so this covers it.
  static const _stillFrames = 4;

  /// The finger comes up. The verb's own frames — the transition it started —
  /// are captured by the settle loop that follows, through [capture].
  void release() => _down = false;

  /// The hold after a verb has settled.
  ///
  /// The first one is [FilmSettings.open] long rather than [FilmSettings.dwell]:
  /// the first verb of a scenario is the `pumpWidget` that puts the app on
  /// screen, and the pause a reader needs there is the one at the top of the
  /// film.
  Future<void> dwell(WidgetTester tester) async {
    var first = !_opened;
    _opened = true;
    _mark(first ? 'open' : 'dwell');
    // The one thing a reel asks of the *run*: more of the app, here, with
    // nothing being touched. The index is the beat this pause is about to
    // become — which is what an edit keyed its hold on when it read the take.
    var extra = reel?.holds[_beats.length] ?? Duration.zero;
    await _hold(tester, (first ? settings.open : settings.dwell) + extra);
  }

  var _opened = false;

  /// The last hold, so the clip does not cut on the frame the last verb
  /// happened to land on.
  Future<void> close(WidgetTester tester) async {
    _mark('close');
    await _hold(tester, settings.close);
  }

  /// Writes what is left and the timeline beside it.
  ///
  /// The timeline is written whatever happened, a film cut short included: it
  /// is what the host reads to know how many frames to expect and what they
  /// are, and a run that failed halfway is a fact worth having in a file
  /// rather than a directory of numbers to guess at.
  Future<void> finish(WidgetTester tester) async {
    WidgetsApp.debugAllowBannerOverride = true;
    _closeBeat();
    await _write(tester, tail: true);
    // After the last write, which is what still needs it.
    _stage?.dispose();
    _stage = null;
    _timeline = {
      'version': 2,
      'scenario': scenario,
      if (settings.branches.isNotEmpty) 'branches': settings.branches,
      'fps': settings.fps,
      'scale': settings.scale,
      'width': _width ?? 0,
      'height': _height ?? 0,
      // The app's own frame in logical pixels — what a stage places, and what
      // every rect in a take is measured in. The output's size above is the
      // stage's answer and may be nothing like it.
      if (_screenSize case var screen?)
        'screen': {'width': screen.width, 'height': screen.height},
      'format': 'rgba8888',
      'pointer': touch ? 'touch' : 'mouse',
      // The film's frames — what is on disk, and what a drain counts to. The
      // same number as the pumped count for a plain film and for a dry pass
      // (which writes none, and whose frames *are* the pumps); under a reel
      // they part, and a drain reading the pumped count would stop early on
      // a reel that holds and wait forever on one that cuts.
      'frames': settings.pixels ? _written : _frames,
      'durationMs': _millis(settings.pixels ? _written : _frames),
      // How many frames the scenario really ran for — the source clock's.
      'pumped': _frames,
      if (!settings.pixels) 'dry': true,
      if (_dropped > 0) 'dropped': _dropped,
      'composeMs': _composing.elapsedMilliseconds,
      'writeMs': _writing.elapsedMilliseconds,
      'beats': _beats,
      if (_said.isNotEmpty)
        'cues': [
          for (var (frame, cue) in _said)
            {
              'atMs': _millis(frame),
              'type': cue.runtimeType.toString(),
              'label': '$cue',
              if (cue is ScenarioCueData) 'data': cue.toJson(),
            },
        ],
      'samples': _samples,
    };
    _writeJson(timelineFileName, _timeline!);
    // A finished film is not the film in progress any more. Without this a
    // second run in the same warm guest reuses the first one's object — and
    // so its directory, its scale and its frame count — which is a film
    // written where nobody asked for it and no error to say so.
    if (identical(_filming, this)) _filming = null;
    _finished = this;
  }

  /// The name of the timeline, beside the frames it describes. Written last:
  /// its existence is how a drain knows the film is complete.
  static const timelineFileName = 'film.json';

  /// The name of the head — the size and the pace, written with the first
  /// frame so an encoder can be opened while the rest are still being drawn.
  static const headFileName = 'film.head.json';

  /// Pumps [length] of film, a frame at a time, keeping every one of them.
  ///
  /// [move] is called *before* each pump with how far through the beat it is,
  /// so the cursor is where it should be on the frame that is about to be
  /// drawn rather than one frame behind it.
  Future<void> _hold(
    WidgetTester tester,
    Duration length, {
    void Function(double t)? move,
    WidgetTester? hover,
  }) async {
    var count = (length.inMicroseconds / interval.inMicroseconds).round();
    for (var i = 0; i < count; i++) {
      move?.call((i + 1) / count);
      if (hover != null && _pointer != null) await _hoverTo(hover, _pointer!);
      beforePump?.call();
      await tester.pump(interval);
      capture(tester);
      await flush(tester);
    }
  }

  /// Pumps until the screen stops asking for frames, or [ceiling] runs out.
  ///
  /// A beat that waits for something the app is *doing* rather than for a
  /// length of time — the keyboard sliding up is the one this exists for. The
  /// ceiling is not optional: a screen with a spinner on it never goes quiet,
  /// and a film must not hold on one until it does.
  Future<void> _untilQuiet(
    WidgetTester tester, {
    Duration ceiling = const Duration(milliseconds: 700),
    Offset? Function()? follow,
  }) async {
    var spent = Duration.zero;
    while (tester.binding.hasScheduledFrame && spent < ceiling) {
      if (follow?.call() case var at?) _pointer = at;
      beforePump?.call();
      await tester.pump(interval);
      spent += interval;
      capture(tester);
      await flush(tester);
    }
  }

  /// Moves a real mouse to [at], so the app under the cursor knows it is under
  /// the cursor.
  ///
  /// The scenario's own mouse rather than one of the film's: the verbs that
  /// are a mouse — `hover`, `secondaryTap`, `scroll` — move it too, and one
  /// of the film's own would be a second mouse to the app. See
  /// [ScenarioMouse].
  Future<void> _hoverTo(WidgetTester tester, Offset at) =>
      ScenarioMouse.of(tester).moveTo(at);

  /// How long a reach of [distance] takes.
  ///
  /// Fitts, roughly: pointing time grows with the *logarithm* of the distance,
  /// not with the distance. A cursor that spends the same 350ms crossing a
  /// whole screen and hopping to the chip beside it is the least human thing
  /// about it — the long move looks hurried and the short one looks like it is
  /// thinking about it.
  ///
  /// [FilmSettings.travel] names the nominal, which is a phone-screen sweep;
  /// the clamp keeps a hop from being instant and a diagonal from dawdling.
  Duration _travelFor(double distance) {
    var factor =
        math.log(1 + distance / 64) / math.log(1 + _nominalTravel / 64);
    return settings.travel * factor.clamp(0.45, 1.6);
  }

  /// The reach [FilmSettings.travel] is quoted for — about a phone screen.
  static const _nominalTravel = 400.0;

  /// Where the cursor is [t] of the way through a reach.
  ///
  /// The speed profile is the **minimum-jerk** polynomial — `10t³ − 15t⁴ +
  /// 6t⁵` — which is the classic model of a human reaching for something and
  /// is visibly gentler at both ends than the `easeInOut` this used to be: it
  /// leaves rest slowly, spends its speed in the middle, and settles onto the
  /// target rather than arriving at it.
  ///
  /// In a straight line, and that was tried the other way: an arm is a pair of
  /// hinges, so a real reach arcs, and a Bézier bowed 7% perpendicular to the
  /// line is what that looks like. Watched, it reads as a drift rather than as
  /// a hand — the owner's call, and the honest one, since the timing and the
  /// speed profile are what carry this and the bow was the least evidenced of
  /// the three.
  Offset _reach(Offset from, Offset to, double t) =>
      Offset.lerp(from, to, t * t * t * (10 - 15 * t + 6 * t * t))!;

  /// Where a cursor that has not arrived yet comes from: off the bottom edge,
  /// under the point it is heading for. A first tap then reads as a hand
  /// coming into frame rather than as a dot fading in over the button.
  Offset _offstage(WidgetTester tester, Offset toward) {
    var size = tester.binding.renderViews.firstOrNull?.size;
    return Offset(toward.dx, (size?.height ?? toward.dy) + 48);
  }

  void _mark(String kind, {String? verb, String? target, ScenarioAim? aim}) {
    _closeBeat();
    // A beat of the verb now running inherits what that verb named; a pause
    // or a hold names nothing, and must not inherit the last verb's word.
    var named = target ?? (verb == null ? null : _verbTarget);
    _beat = {
      'kind': kind,
      'frame': _frames,
      'atMs': _millis(_frames),
      'verb': ?verb,
      'target': ?named,
      if (aim != null) 'aim': aim.toJson(),
    };
  }

  void _closeBeat() {
    if (_beat case var beat?) {
      var length = _frames - (beat['frame']! as int);
      // A beat that drew nothing is not in the film — the frames are what a
      // beat is, and an entry claiming none of them would put a caption on a
      // moment nobody can see.
      if (length > 0) {
        _beats.add({...beat, 'frames': length, 'durationMs': _millis(length)});
      }
    }
    _beat = null;
  }

  /// Film time at [frames], in milliseconds.
  ///
  /// A pump advances the fake clock by exactly one frame, so the frame count
  /// *is* the clock and nothing has to be read off it. Written beside the
  /// frame index rather than instead of it, because an encoder counts frames
  /// and an edit counts time.
  int _millis(int frames) => (frames * 1000 / settings.fps).round();

  /// What the scenario said, in its own words, at the moment it said it.
  ///
  /// The value is the author's own object and is kept as one: an edit runs in
  /// this process and pattern-matches it. The timeline gets its type and its
  /// `toString` so a person reading the file sees something, and a
  /// [ScenarioCueData] gets its own fields written too.
  void say(Object cue) => _said.add((_frames, cue));

  final _said = <(int, Object)>[];

  /// Everything [say] was handed, in order, with the film time of each.
  List<(Duration, Object)> get said => [
    for (var (frame, cue) in _said)
      (Duration(milliseconds: _millis(frame)), cue),
  ];

  /// Rasterises the bank, draws the cursor on it, and writes one file per
  /// frame.
  ///
  /// Every frame is written to a `.part` name and renamed into place, because
  /// the host reads this directory while it is being written: a numbered file
  /// that exists is a whole frame, and there is no other agreement to keep.
  Future<void> _write(WidgetTester tester, {bool tail = false}) async {
    if (_banked.isEmpty && !tail) return;
    var banked = List.of(_banked);
    _banked.clear();
    _writing.start();
    await tester.runAsync(() async {
      for (var frame in banked) {
        // Without a reel a pumped frame is an output frame, which is what a
        // film is. With one, the reel says how many — none where it cut, one
        // where it plays, and a run of them where it froze.
        var plans =
            _projector?.accept() ??
            [_Plan(Duration(milliseconds: _millis(frame.frame)), false)];
        for (var plan in plans) {
          // A freeze holds the whole picture, cursor included. Handing it the
          // frame that is *arriving* would draw the hand at where it has got
          // to over a screen that stopped — a cursor sliding across a still.
          await _writeOne(
            plan.frozen ? _held : frame.image,
            plan.frozen ? null : frame,
            plan.at,
          );
        }
        if (_projector != null) {
          _held?.dispose();
          _held = frame.image.clone();
        }
        frame.image.dispose();
      }
      if (tail) {
        for (var plan in _projector?.flush() ?? const <_Plan>[]) {
          await _writeOne(_held, null, plan.at);
        }
        _held?.dispose();
        _held = null;
      }
    });
    _writing.stop();
  }

  /// Draws one output frame and puts it on disk.
  ///
  /// Every frame is written to a `.part` name and renamed into place, because
  /// the host reads this directory while it is being written: a numbered file
  /// that exists is a whole frame, and there is no other agreement to keep.
  Future<void> _writeOne(ui.Image? screen, _Banked? source, Duration at) async {
    _composing.start();
    var image = _compose(screen, source, at);
    _composing.stop();
    var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    _width ??= image.width;
    _height ??= image.height;
    image.dispose();
    if (data == null) {
      // Fatal rather than skipped. The frames are numbered without gaps and an
      // encoder drains them in order, so a missing one is not a frame lost —
      // it is the rest of the film never arriving.
      throw StateError(
        'frame $_written of the film rasterised to nothing, and a film '
        'with a hole in it cannot be encoded',
      );
    }
    // The first frame is the first moment anything knows how big this film
    // is, and an encoder has to be opened on a size before it can be fed. So
    // the head goes out here rather than waiting for the timeline at the end —
    // that is what lets the encode run *beside* the render instead of after
    // it.
    if (_written == 0) _writeHead();
    var path = p.join(
      settings.directory,
      '${_written.toString().padLeft(6, '0')}.raw',
    );
    File('$path.part')
      ..writeAsBytesSync(data.buffer.asUint8List())
      ..renameSync(path);
    _written++;
  }

  var _written = 0;

  /// What drawing the cursor over the frames costs.
  ///
  /// Reported rather than assumed: the cursor is painted onto the rasterised
  /// frame instead of into the app's tree, and the price of that separation is
  /// a second raster per frame. Worth knowing what it is before anyone trades
  /// it for a layer appended to the tree.
  final _composing = Stopwatch();

  /// And what the whole spill costs — rasterise, read back, write. The
  /// interesting half of [_composing], since `toImageSync` defers the raster
  /// itself to the read back.
  final _writing = Stopwatch();

  /// What an encoder needs before the film is finished: how to cut the stream
  /// into frames, and how fast to play them.
  ///
  /// Raw video carries no header, so a drain cannot open an encoder until it
  /// knows the size — and the timeline that would say so is written at the
  /// end. This is that size, written beside the first frame, and it is what
  /// lets the encode run *beside* the render rather than after it.
  void _writeHead() => _writeJson(headFileName, {
    'version': 1,
    'scenario': scenario,
    'fps': settings.fps,
    'scale': settings.scale,
    'width': _width ?? 0,
    'height': _height ?? 0,
    'format': 'rgba8888',
    'pointer': touch ? 'touch' : 'mouse',
  });

  void _writeJson(String name, Map<String, Object?> body) =>
      File(p.join(settings.directory, name))
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(body));

  /// The app's frame, drawn through the stage.
  ///
  /// **Through**, never inside: the stage is a tree of its own, mounted in its
  /// own pipeline, and the app's frame reaches it as an image. So a caption is
  /// not a widget a finder can match, a camera cannot change the app's layout,
  /// and nothing the stage draws is in the screenshot lane's trees. The cost
  /// is a second raster per frame, which is measured against the layer it
  /// could have been appended to instead.
  ui.Image _compose(ui.Image? screen, _Banked? source, Duration at) {
    var mounted = _stage ??= MountedStage(
      _stageInForce,
      screenSize: _screenSize ?? Size.zero,
      scale: settings.scale,
      touch: touch,
    );
    var composed = mounted.render(
      StageFrame(
        screen: screen,
        screenSize: _screenSize ?? Size.zero,
        at: at,
        // A frozen frame keeps the finger where it was: the picture is not
        // moving, so neither is the hand in it.
        pointer: source?.pointer ?? _lastPointer,
        down: source?.down ?? false,
        sincePress: source?.sincePress,
        touch: touch,
        cues: reel?.cuesAt(at) ?? const [],
      ),
    );
    if (source != null) _lastPointer = source.pointer;
    // A stage that throws renders as Flutter's error box, which is a picture
    // and would ship as one. Said once, with the first thing that went wrong.
    if (mounted.errors.isNotEmpty) {
      var first = mounted.errors.first;
      throw StateError(
        'the stage failed while drawing the frame at $at:\n'
        '${first.exceptionAsString()}',
      );
    }
    return composed;
  }

  Offset? _lastPointer;

  static double _round(double value) => (value * 10).roundToDouble() / 10;
}

class _Banked {
  _Banked(this.frame, this.image, this.pointer, this.down, this.sincePress);

  /// Which frame of the film this is — what the stage is told the time is.
  final int frame;

  final ui.Image image;
  final Offset? pointer;
  final bool down;

  /// Seconds since the last press began, or null before the first one.
  final double? sincePress;
}

/// The film this process is rendering, if any.
///
/// One per run and not one per scenario: the frames are numbered into a single
/// directory and encoded as one clip, so a request whose selector matched two
/// scenarios has asked for something that cannot be made. Refused here, by the
/// second scenario to start, rather than discovered as a video of two flows
/// spliced together.
ScenarioFilm? _filming;

/// Forgets the film in progress, so a test file can render more than one.
@visibleForTesting
void resetFilms() {
  _filming = null;
  _finished = null;
}

/// The film that last finished, once — and then nobody's.
///
/// How the dry pass hands its take to whoever runs the film pass: the harness
/// runs the body, the body films, the film finishes, and the harness collects
/// it here before it runs the body again. Taken rather than read so that a
/// take is never handed to the wrong second pass: a warm guest serves many
/// requests, and the film that finished under the previous one is not a fact
/// about this one.
ScenarioFilm? takeFinishedFilm() {
  var film = _finished;
  _finished = null;
  return film;
}

ScenarioFilm? _finished;

ScenarioFilm startFilm(
  FilmSettings settings, {
  required String scenario,
  required bool touch,
  void Function()? beforePump,
  Reel? reel,
  ReelStage stage = const BareStage(),
  ScenarioReelEdit? edit,
}) {
  if (_filming case var already? when already.scenario != scenario) {
    throw ScenarioFilmRefusal(
      'a film is one scenario, and this run matched both '
      '`${already.scenario}` and `$scenario`. Name one with `--scenario=`.',
    );
  }
  return _filming ??= ScenarioFilm(
    settings,
    scenario: scenario,
    touch: touch,
    beforePump: beforePump,
    reel: reel,
    stage: stage,
    edit: edit,
  );
}

/// One output frame, as the reel plans it.
class _Plan {
  _Plan(this.at, this.frozen);

  final Duration at;
  final bool frozen;
}

/// Turns pumped frames into output frames.
///
/// The reel is already decided, so this is a walk rather than a decision: each
/// arriving source frame flushes whatever frozen output stands before it, then
/// spends itself on one playing frame. A shot the source never reaches is
/// dropped — a run that ended early is not a reel that keeps going.
class _Projector {
  _Projector(this.reel, {required this.fps})
    : _left = [
        for (var shot in reel.shots)
          (
            frames: (shot.duration.inMicroseconds * fps / 1000000).round(),
            frozen: shot.frozen,
          ),
      ];

  final Reel reel;
  final int fps;
  final List<({int frames, bool frozen})> _left;
  var _shot = 0;
  var _out = 0;

  Duration _at(int index) =>
      Duration(microseconds: (index * 1000000 / fps).round());

  List<_Plan> accept() {
    var plans = <_Plan>[];
    while (_shot < _left.length) {
      var shot = _left[_shot];
      if (shot.frames <= 0) {
        _shot++;
        continue;
      }
      if (shot.frozen) {
        for (var i = 0; i < shot.frames; i++) {
          plans.add(_Plan(_at(_out++), true));
        }
        _left[_shot] = (frames: 0, frozen: true);
        _shot++;
        continue;
      }
      plans.add(_Plan(_at(_out++), false));
      _left[_shot] = (frames: shot.frames - 1, frozen: false);
      if (_left[_shot].frames == 0) _shot++;
      break;
    }
    return plans;
  }

  /// The frozen shots left when the source runs out — the tail an edit put
  /// after the last thing that happened.
  List<_Plan> flush() {
    var plans = <_Plan>[];
    for (; _shot < _left.length; _shot++) {
      var shot = _left[_shot];
      if (!shot.frozen) continue;
      for (var i = 0; i < shot.frames; i++) {
        plans.add(_Plan(_at(_out++), true));
      }
    }
    return plans;
  }
}
