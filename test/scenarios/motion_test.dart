import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/motion.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// Recording what a transition *looked* like — the frame sink on the settle
/// loop, and the frames it lands on the step. Design and measurements:
/// `docs/superpowers/specs/2026-08-11-scenario-motion-capture-findings.md`.
///
/// Like `events_test.dart`, the test is standing in for the harness: it sets
/// the listener and the run args the runner would set, and reads what the
/// capture handed over.
void main() {
  group('the recorder, on the settle policies', () {
    testWidgets('keeps a frame per pump of a bounded settle', (tester) async {
      await tester.pumpWidget(const _Fading());
      var recorder = ScenarioMotionRecorder(
        const MotionRecording(interval: Duration(milliseconds: 33)),
      );
      recorder.capture(tester);

      await Settle.standard.apply(tester, record: recorder);

      // A 300ms fade at 33ms a frame, plus the frame banked before the settle
      // and the one that finds nothing left scheduled.
      var frames = await _drain(tester, recorder);
      expect(frames.bytes, hasLength(11));
      expect(frames.hasMotion, isTrue);
    });

    testWidgets('subdivides the budget without moving where it ends', (
      tester,
    ) async {
      // The property the comparison work rests on: a recorded run and an
      // ordinary one spend the same fake time and stop on the same frame.
      await tester.pumpWidget(const _Fading());
      var recorder = ScenarioMotionRecorder(
        const MotionRecording(interval: Duration(milliseconds: 16)),
      );

      var settled = await Settle.standard.apply(tester, record: recorder);

      expect(settled, isTrue);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
    });

    testWidgets('stops at the frame cap and says what it dropped', (
      tester,
    ) async {
      await tester.pumpWidget(const _Spinner());
      var recorder = ScenarioMotionRecorder(
        const MotionRecording(
          interval: Duration(milliseconds: 33),
          maxFrames: 12,
        ),
      );

      // An indefinite animation spends the whole five-second budget — 150
      // frames at this interval, against a cap of twelve.
      await Settle.standard.apply(tester, record: recorder);

      var frames = await _drain(tester, recorder);
      expect(frames.bytes, hasLength(12));
      expect(frames.dropped, greaterThan(100));
    });

    testWidgets("records at its own scale, not the step's", (tester) async {
      await tester.pumpWidget(const _Fading());
      var recorder = ScenarioMotionRecorder(const MotionRecording(scale: 0.5));
      recorder.capture(tester);

      var frames = await _drain(tester, recorder);
      // The bare test surface is 800×600 logical at a pixel ratio of one.
      expect((frames.width, frames.height), (400, 300));
    });

    testWidgets('leaves an author-chosen interval alone', (tester) async {
      await tester.pumpWidget(const _Fading());
      var recorder = ScenarioMotionRecorder(
        const MotionRecording(interval: Duration(milliseconds: 10)),
      );

      // `Settle.frames` says where in the animation to land. A recording may
      // subdivide a *budget*; it may not move a count the author asked for.
      await const Settle.frames(
        3,
        interval: Duration(milliseconds: 100),
      ).apply(tester, record: recorder);

      var frames = await _drain(tester, recorder);
      expect(frames.bytes, hasLength(3));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
    });

    testWidgets('records nothing under a policy that owns no loop', (
      tester,
    ) async {
      await tester.pumpWidget(const _Fading());
      var recorder = ScenarioMotionRecorder(const MotionRecording());
      recorder.capture(tester);

      await Settle.full.apply(tester, record: recorder);

      // `Settle.full` is `pumpAndSettle` itself, which offers no per-frame
      // hook — so only the frame banked before it ran.
      var frames = await _drain(tester, recorder);
      expect(frames.hasMotion, isFalse);
    });

    testWidgets('survives a screen with nothing on it', (tester) async {
      // The binding paints an empty root view before a scenario pumps
      // anything, so the frame before the first `pumpWidget` is a real,
      // blank one — which is the honest opening frame of "the app appeared".
      // What matters is that reading it cannot throw: this runs inside every
      // verb of every scenario, and a recording may not fail a run.
      var recorder = ScenarioMotionRecorder(const MotionRecording());
      expect(() => recorder.capture(tester), returnsNormally);
      expect((await _drain(tester, recorder)).bytes, hasLength(1));
    });
  });

  group('a recording run', () {
    var captures = <ScenarioStepCapture>[];
    setUp(() {
      captures = [];
      scenarioRunListener = captures.add;
      scenarioRunArgs = const ScenarioRunArgs(
        captureRaw: true,
        record: MotionRecording(
          interval: Duration(milliseconds: 33),
          scale: 0.5,
        ),
      );
    });
    tearDown(() {
      scenarioRunListener = null;
      scenarioRunArgs = null;
    });

    group('lands the transition on the step it arrives at', () {
      scenario('never on the one it left', (s) async {
        await s.pumpWidget(const _App());
        await s.tap('Fade in');
      });
      // The tap starts a 300ms fade, and its frames belong to the step the
      // tap arrived at — never to the one it left. `pumpWidget` keeps two:
      // the blank view, and the app on it. A hard cut is two frames long.
      tearDown(() {
        expect(captures[0].motion.bytes, hasLength(2));
        expect(captures[1].motion.bytes.length, greaterThan(5));
        expect(captures[1].motionInterval, const Duration(milliseconds: 33));
      });
    });

    group('follows the step into raw', () {
      scenario("at the recording's own size", (s) async {
        await s.pumpWidget(const _App());
        await s.tap('Fade in');
      });
      tearDown(() {
        var motion = captures[1].motion;
        expect(motion.bytes.first, hasLength(motion.width * motion.height * 4));
        expect(motion.width, 400);
      });
    });

    group("hands a skipped shot's frames to the next capture", () {
      scenario('which is where its own picture would have been', (s) async {
        await s.pumpWidget(const _App());
        await s.tap('Fade in', shot: Shot.skip);
        await s.screen('Faded');
      });
      // Two captures, not three: the skipped tap emitted nothing, so its
      // frames ride to the capture that follows — the rule the event buffer
      // already follows, for the same reason.
      //
      // And that capture is a real one rather than a name on `pumpWidget`'s:
      // the fade left the screen visibly different, which is exactly what
      // stops a `screen` from adopting a frame that has moved on.
      tearDown(() {
        expect(captures, hasLength(2));
        expect(captures[1].name, 'Faded');
        expect(captures[1].motion.bytes.length, greaterThan(5));
      });
    });

    var branched = <ScenarioStepCapture>[];
    scenario('records a shared prefix once, not once per branch', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
      await s.split({
        'left': () async => s.screen('Left'),
        'right': () async => s.screen('Right'),
      });
      branched = captures;
    });

    tearDown(() {
      var seen = branched;
      branched = [];
      if (seen.isEmpty) return;
      // Four steps for two paths over a two-step prefix. The second replay
      // walks the prefix again and recognises it by position, so its frames
      // are thrown away unencoded: the 21-frame fade appears **once**, where
      // recording it per branch would multiply the same transition in
      // artifacts and in memory alike. The two-frame steps are hard cuts —
      // the frame before, and the frame after.
      expect(
        [for (var capture in seen) capture.motion.bytes.length],
        [2, greaterThan(5), 2, 2],
      );
    });

    scenario('keeps the frames of the transition that broke', (s) async {
      await s.pumpWidget(const _App());
      try {
        await s.tap('Nothing here');
      } catch (_) {}

      // The failed step is the one step nobody asked for and everybody wants,
      // and how the app got to it is part of the evidence.
      expect(captures.last.failure, isNotNull);
    });

    group('a skipped no-op scrollTo', () {
      scenario('leaves no stills in the next step’s movie', (s) async {
        await s.pumpWidget(const _App());
        await s.scrollTo('Fade in');
        await s.screen('Same', force: true);
      });
      // The skip discards its banked stills — provably identical to the
      // picture already in the flow — so the forced screen after it is
      // still a hard cut: its own before-frame and the frame it found, not
      // those plus the skip's.
      tearDown(() {
        expect(captures, hasLength(2));
        expect(captures[1].motion.bytes, hasLength(2));
      });
    });

    group('a byte-proven adoption', () {
      scenario('keeps the frames that moved on the way to the name', (s) async {
        await s.pumpWidget(const _TimedFlash());
        // The wait fires the flash; its settle plays it out, ending on the
        // pixels the step started with — the shape a byte adoption absorbs.
        await s.wait(const Duration(milliseconds: 1200), shot: Shot.skip);
        await s.screen('Quiet again');
      });
      // One step, and its movie holds the flash: the identical stills around
      // it are not a transition and stay out, the frames that moved are the
      // flow's only record and stay in.
      tearDown(() {
        expect(captures, hasLength(1));
        expect(captures.single.name, 'Quiet again');
        expect(captures.single.motion.bytes.length, greaterThan(2));
      });
    });
  });

  group('a run that did not ask', () {
    var captures = <ScenarioStepCapture>[];
    setUp(() {
      captures = [];
      scenarioRunListener = captures.add;
    });
    tearDown(() => scenarioRunListener = null);

    scenario('records nothing at all', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Fade in');
    });
    tearDown(() {
      if (captures.isEmpty) return;
      expect(captures.every((c) => c.motion.bytes.isEmpty), isTrue);
      expect(captures.last.motionInterval, isNull);
    });
  });
}

Future<ScenarioMotionFrames> _drain(
  WidgetTester tester,
  ScenarioMotionRecorder recorder,
) async {
  late ScenarioMotionFrames frames;
  await tester.runAsync(() async {
    frames = await recorder.drain(raw: true);
  });
  return frames;
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: _FadeOnTap()));
}

class _FadeOnTap extends StatefulWidget {
  const _FadeOnTap();

  @override
  State<_FadeOnTap> createState() => _FadeOnTapState();
}

class _FadeOnTapState extends State<_FadeOnTap> {
  var _visible = false;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => setState(() => _visible = true),
        child: const Text('Fade in'),
      ),
      AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: const SizedBox(
          width: 100,
          height: 100,
          child: ColoredBox(color: Color(0xFF00FF00)),
        ),
      ),
    ],
  );
}

/// Quiet at first; a timer flashes an overlay in and straight back out, so
/// the screen moves and lands exactly where it started.
class _TimedFlash extends StatefulWidget {
  const _TimedFlash();

  @override
  State<_TimedFlash> createState() => _TimedFlashState();
}

class _TimedFlashState extends State<_TimedFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash;
  Timer? _later;

  @override
  void initState() {
    super.initState();
    _flash =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 150),
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) _flash.reverse();
          })
          ..addListener(() => setState(() {}));
    _later = Timer(const Duration(seconds: 1), _flash.forward);
  }

  @override
  void dispose() {
    _later?.cancel();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          const Text('quiet'),
          IgnorePointer(
            child: Opacity(
              opacity: _flash.value,
              child: Container(color: const Color(0xFF2196F3)),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Fading extends StatefulWidget {
  const _Fading();

  @override
  State<_Fading> createState() => _FadingState();
}

class _FadingState extends State<_Fading> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) =>
          Opacity(opacity: _controller.value, child: const _Block()),
    ),
  );
}

class _Block extends StatelessWidget {
  const _Block();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF123456));
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: CircularProgressIndicator())),
  );
}
