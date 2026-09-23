import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/motion.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

import 'raster_fixture.dart';

/// A widget whose *paint* depends on work that resolves on the real event
/// loop, mounted mid-scenario — and the step that photographs it.
///
/// `vector_graphics` is the instance this was found through: a consumer's
/// scenario captured every screen as it arrived and every one of them was
/// missing its illustration, one step late. But nothing here is about SVG.
/// Lottie, a PDF or thumbnail renderer, an `ImageProvider` decoding off the
/// fake clock and a `FutureBuilder` on a real future all have the same shape —
/// a decode that finishes on the **real** event loop and schedules no frame
/// while it is in flight.
///
/// The work is a root-zone timer rather than an asset read on purpose. Under a
/// bare `flutter test` an asset read is not real-loop work at all:
/// `UNIT_TEST_ASSETS` makes `flutter_test` answer `flutter/assets` from a
/// `readAsBytesSync`, so it completes under FakeAsync and this file would be
/// green while the runner's lane — which spawns `flutter_tester` directly and
/// gets the engine's answer — stayed red. `Zone.root` is the one spelling of
/// "off the fake clock" that both lanes agree on.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  group('the step that mounts the artwork is the step that shows it', () {
    scenario('so a screen after it has nothing new to photograph', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Show');
      await s.screen('one step later');
    });
    // Two steps, and the second is the tap's own wearing the name — which is
    // a stronger claim than the byte comparison this used to make. Adoption is
    // refused the moment a frame is drawn between the two, so a mounting step
    // that photographed a frame the tree was about to replace would leave the
    // decode to land in this screen's settle, draw there, and split back into
    // two pictures. That is precisely what happened before the landing fix —
    // and why one more step always fixed it while more pumping inside the step
    // never did.
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures.last.name, 'one step later');
      expect(captures.last.verb, 'tap');
    });
  });

  group('nothing a scenario can assert says the picture is short', () {
    scenario('every flag reads the same either way', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Show');

      expect(find.byType(_Art), findsOneWidget);
    });
    // The trap, and why this cost a consumer an afternoon: every one of these
    // was already true on the step whose picture was missing the artwork. Only
    // the pixels differed, and nothing was watching them.
    tearDown(() {
      expect(captures.last.settled, isTrue);
      expect(captures.last.strayFrames, 0);
    });
  });

  // The same shape with an `ImageProvider` on the end of it — the half of the
  // class the timer above does not cover, and the half a consumer hit next.
  //
  // **Size is the discriminator, and a counted bound is why.** The decode is
  // the same code either way; what differs is how long it runs, and a turn of
  // the real loop is not a wait — it yields once while the engine's decoder
  // works on another thread. So the old twelve-turn ceiling was really
  // "however much wall time twelve yields happen to cost here", and the payload
  // that fits under it is a property of the machine. Measured under it: 8×8 and
  // 780×609 land, 1500×1200 does not, and a bigger image only moves that line.
  // Both ends are here so a fix that merely buys headroom fails the large one,
  // and one that reintroduces the cliff further out fails both on a slower
  // machine.
  for (var (label, width, height) in [
    ('8×8', 8, 8),
    ('2400×1800', 2400, 1800),
  ]) {
    group('a $label image lands on the step that mounts it', () {
      scenario('leaving the screen after it nothing to add', (s) async {
        var bytes = rasterFixture(width, height);
        await s.pumpWidget(_ImageApp(bytes));
        await s.tap('Show');
        await s.screen('one step later');
      });
      tearDown(() {
        // Adopted rather than photographed again: nothing was drawn between
        // the two, which is what "the decode already landed" looks like from
        // the frame counter.
        expect(captures, hasLength(2));
        expect(captures.last.name, 'one step later');
        // `pendingImageCount` is what was waited on, so a step that gave up
        // says so — the whole point of the flag is that this cannot go wrong
        // quietly.
        expect(captures.last.landed, isTrue);
      });
    });
  }

  // **A still that is right does not make the movie behind it right**, and the
  // difference is what a reader actually looks at: the recording is what the
  // GUI plays when you hover a step.
  //
  // A landing that happens *after* the settle loop puts the artwork in the last
  // frame and no earlier one. Measured before this: a tap whose ripple runs 21
  // recorded frames produced `[0, 0, 0, …, 0, present]` — one frame of artwork
  // at the very end of a movie that is otherwise a hole, which plays as never
  // having decoded at all. Fake time is why the app never catches up: a
  // transition of several hundred fake milliseconds is spent in a few real
  // ones, so a decode a device would have finished inside the first frame
  // cannot finish inside any of them.
  //
  // So the frames are counted, not compared. Two captures that are both missing
  // the artwork are equal, and the equality assertion this replaces was passing
  // on exactly that.
  group('the transition, recorded', () {
    setUp(() {
      scenarioRunArgs = const ScenarioRunArgs(
        captureRaw: true,
        record: MotionRecording(
          interval: Duration(milliseconds: 33),
          scale: 0.5,
        ),
      );
    });
    tearDown(() => scenarioRunArgs = null);

    scenario('carries the image, not just the frame it ends on', (s) async {
      await s.pumpWidget(_ImageApp(solidRed(400, 400)));
      await s.tap('Show');
      await s.screen('one step later');
    });
    tearDown(() {
      // The tap's own step, wearing the name the `screen` gave it — the movie
      // behind a merged step is the one its verb recorded.
      var motion = captures[1].motion;
      var blank = motion.bytes.where((frame) => _redPixels(frame) == 0);
      expect(motion.bytes, hasLength(greaterThan(10)));
      // Two frames legitimately have no artwork and no more: the screen as it
      // stood before the tap, banked so the movie opens on where it came from,
      // and the pump that mounts the widget — which is where the decode starts,
      // so no frame drawn at that instant could show it.
      expect(blank, hasLength(2));
      expect(_redPixels(motion.bytes.last), greaterThan(0));
    });
  });

  group('a decode that never arrives', () {
    scenario('is reported, not waited on forever', (s) async {
      await s.pumpWidget(const _ImageApp.provider(_NeverDecodes()));
      await s.tap('Show');
    });
    // The one case the ceiling exists for. It is still photographed — a picture
    // of a screen that never filled in is the evidence — but it no longer
    // claims to be finished.
    tearDown(() {
      expect(captures.last.landed, isFalse);
      expect(captures.last.settled, isTrue);
    });
  });

  // **A screen that is still animating lands its work too.**
  //
  // `settled: false` used to skip the landing entirely, and the reasoning was
  // that such a step is of a moving picture anyway. But a moving picture is
  // exactly where the artwork goes missing: a spinner, a ripple or any other
  // indefinite animation keeps a frame scheduled, so the flag says nothing at
  // all about whether the decode finished — and every one of those steps was
  // photographed with a hole in it and reported `landed: true`.
  //
  // What makes the tree busy is deliberately mundane in the first two: a
  // `TextButton`'s ink ripple is still running when a `Settle.none` step reads
  // `hasScheduledFrame`, which is enough on its own. Nobody writing that step
  // thinks of it as animating.
  group('an unsettled tree', () {
    // Pixels are the question here, so the captures have to be raw: what the
    // file records by default is PNG, and nothing about a step that lost its
    // artwork is visible in the encoded bytes without decoding them back.
    setUp(() {
      scenarioRunArgs = const ScenarioRunArgs(captureRaw: true);
    });
    tearDown(() => scenarioRunArgs = null);

    for (var (label, busy) in [
      ('a ripple is running', _Busy.ripple),
      ('a spinner is on screen', _Busy.spinner),
    ]) {
      group('lands an announced decode while $label', () {
        scenario('with the artwork in the picture', (s) async {
          await s.pumpWidget(_ImageApp(solidRed(400, 400), busy: busy));
          await s.tap('Show', settle: Settle.none);
        });
        tearDown(() {
          var step = captures.last;
          expect(step.settled, isFalse, reason: 'the fixture must be busy');
          expect(step.landed, isTrue);
          expect(_redPixels(step.bytes!), greaterThan(0));
        });
      });

      group('lands a guessed decode while $label', () {
        scenario('with the artwork in the picture', (s) async {
          await s.pumpWidget(_ImageApp.art(busy: busy));
          await s.tap('Show', settle: Settle.none);
        });
        tearDown(() {
          var step = captures.last;
          expect(step.settled, isFalse, reason: 'the fixture must be busy');
          expect(_redPixels(step.bytes!), greaterThan(0));
        });
      });
    }

    // **The links are what a fix here is measured against.** A decode that
    // announces nothing arrives in links — a read completes, the app builds,
    // the build starts the next read — and on a busy tree there is no signal
    // that says a link landed, so the turns have to be spent flat. A fix that
    // merely re-applies the caller's policy once buys exactly one of them:
    // measured, it carries this fixture at one link and loses it at six —
    // shallower than the deepest decode a real suite has produced here, which
    // is the whole reason `realWorkTurns` is not one.
    group('carries a decode six links deep', () {
      scenario('to the step that mounts it', (s) async {
        await s.pumpWidget(const _ImageApp.art(busy: _Busy.spinner, links: 6));
        await s.tap('Show', settle: Settle.none);
      });
      tearDown(() => expect(_redPixels(captures.last.bytes!), greaterThan(0)));
    });

    // The honesty half. Skipping the landing reported `landed: true` on a step
    // that had not tried, so the flag could not be read at all; now it says
    // what it always meant.
    group('still reports a decode that never arrives', () {
      scenario('as unlanded rather than as finished', (s) async {
        await s.pumpWidget(
          const _ImageApp.provider(_NeverDecodes(), busy: _Busy.spinner),
        );
        await s.tap('Show', settle: Settle.none);
      });
      tearDown(() {
        expect(captures.last.landed, isFalse);
        expect(captures.last.settled, isFalse);
      });
    });

    // The movie has to end where the still is. The turns above all draw the
    // same fake instant, so the recording takes one frame from them and not a
    // dozen — but it has to take that one: measured without it, the still came
    // out with the artwork and the last frame behind it did not, which is the
    // same hole one step further in.
    group('recorded', () {
      setUp(() {
        scenarioRunArgs = const ScenarioRunArgs(
          captureRaw: true,
          record: MotionRecording(
            interval: Duration(milliseconds: 33),
            scale: 0.5,
          ),
        );
      });

      scenario('ends on the frame the still was taken from', (s) async {
        await s.pumpWidget(_ImageApp(solidRed(400, 400), busy: _Busy.spinner));
        await s.tap('Show', settle: Settle.none);
      });
      tearDown(() {
        var step = captures.last;
        expect(_redPixels(step.bytes!), greaterThan(0));
        expect(_redPixels(step.motion.bytes.last), greaterThan(0));
      });
    });
  });
}

/// What keeps a fixture's tree asking for frames when a step declines to pump
/// it out — the two shapes that make a step report `settled: false` without
/// anybody having written an animation.
///
/// [ripple] is the button's own ink splash and needs nothing added; [spinner]
/// puts a `CircularProgressIndicator` beside it, which never stops.
enum _Busy { ripple, spinner }

/// Pixels close to pure red in an rgba8888 frame — "is the artwork in this
/// picture", asked of a fixture chosen so that counting answers it.
int _redPixels(Uint8List raw) {
  var found = 0;
  for (var i = 0; i + 3 < raw.length; i += 4) {
    if (raw[i] > 200 &&
        raw[i + 1] < 60 &&
        raw[i + 2] < 60 &&
        raw[i + 3] > 200) {
      found++;
    }
  }
  return found;
}

/// An `ImageProvider` whose codec never arrives — `pendingImageCount` stays at
/// one for as long as anybody is willing to wait.
class _NeverDecodes extends ImageProvider<_NeverDecodes> {
  const _NeverDecodes();

  @override
  Future<_NeverDecodes> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_NeverDecodes key, ImageDecoderCallback _) =>
      MultiFrameImageStreamCompleter(
        codec: Completer<Codec>().future,
        scale: 1,
      );

  @override
  bool operator ==(Object other) => other is _NeverDecodes;

  @override
  int get hashCode => (_NeverDecodes).hashCode;
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _shown = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => setState(() => _shown = true),
            child: const Text('Show'),
          ),
          if (_shown) const Expanded(child: _Art()),
        ],
      ),
    ),
  );
}

/// The same app with an `Image.memory` in place of [_Art] — mounted a step
/// after `pumpWidget`, because `pumpWidget` already takes a real turn for boot
/// and lands whatever the first frame asked for.
class _ImageApp extends StatefulWidget {
  _ImageApp(Uint8List bytes, {this.busy = _Busy.ripple})
    : image = MemoryImage(bytes),
      links = 1;

  const _ImageApp.provider(ImageProvider this.image, {this.busy = _Busy.ripple})
    : links = 1;

  /// [_Art] in the image's place — the same shape with work that announces
  /// nothing on the end of it, [links] deep.
  const _ImageApp.art({this.busy = _Busy.ripple, this.links = 1})
    : image = null;

  final ImageProvider? image;
  final _Busy busy;
  final int links;

  @override
  State<_ImageApp> createState() => _ImageAppState();
}

class _ImageAppState extends State<_ImageApp> {
  var _shown = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => setState(() => _shown = true),
            child: const Text('Show'),
          ),
          if (widget.busy == _Busy.spinner) const CircularProgressIndicator(),
          if (_shown)
            SizedBox(
              width: 200,
              height: 200,
              child: switch (widget.image) {
                var image? => Image(image: image),
                null => _Art(links: widget.links),
              },
            ),
        ],
      ),
    ),
  );
}

/// Paints nothing until a real-loop future hands it something to paint —
/// [links] of them in a chain, each started by the build the previous one
/// caused, which is the shape a decode actually arrives in.
///
/// Pure red rather than `Colors.red`, so `_redPixels` can count it: the
/// question these fixtures answer is whether the artwork is in the picture at
/// all, and material red is not far enough from the background to ask it with.
class _Art extends StatefulWidget {
  const _Art({this.links = 1});

  final int links;

  @override
  State<_Art> createState() => _ArtState();
}

class _ArtState extends State<_Art> {
  Color? _decoded;
  var _link = 0;

  @override
  void initState() {
    super.initState();
    _next(0);
  }

  void _next(int i) {
    // Root zone, so the timer is a real one: nothing FakeAsync flushes can
    // complete it, and it schedules no frame while it is in flight.
    Zone.root.run(() => Future<void>.delayed(Duration.zero)).then((_) {
      if (!mounted) return;
      if (i < widget.links - 1) {
        setState(() => _link = i + 1);
        _next(i + 1);
      } else {
        setState(() => _decoded = const Color(0xFFFF0000));
      }
    });
  }

  @override
  Widget build(BuildContext context) => _decoded == null
      ? SizedBox.expand(child: Text('$_link'))
      : ColoredBox(color: _decoded!);
}
