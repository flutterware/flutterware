import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// When `screen` names the picture the verb before it took, and when it takes
/// one of its own.
///
/// The rule is a frame count, backed by the bytes: nothing drawn since the
/// last capture means the screen is still as that capture photographed it,
/// and where frames *were* drawn, a picture that renders byte-identical
/// adopts all the same — the render was already paid, and bytes are proof
/// where the count was a prediction. Everything else here is a reason the
/// answer is still no.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() => scenarioRunListener = null);

  List<String> shape() => [
    for (var capture in captures) capture.name ?? '${capture.verb}',
  ];

  group('a screen after a verb that settled', () {
    scenario('names that verb’s capture instead of taking another', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      await s.screen('Added');
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Added']);
      // The merged step keeps the verb that drew the frame, so a comparison
      // reads the strongest signature available and the weaker one too.
      expect(captures.last.verb, 'tap');
      expect(captures.last.target, '"Add"');
    });
  });

  group('a screen whose frame has moved on', () {
    scenario('takes a picture of its own', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      // Outside the verbs, so the flow has no picture of it — which is
      // precisely the case a name must not be allowed to swallow.
      await s.tester.tap(find.text('Add'));
      await s.tester.pump();
      await s.screen('Added twice');
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'tap', 'Added twice']);
      expect(captures.last.verb, 'screen');
      expect(captures.last.strayFrames, greaterThan(0));
    });
  });

  group('a name never overwrites a name', () {
    scenario('so two screens on one frame stay two steps', (s) async {
      await s.pumpWidget(const _App());
      await s.screen('First');
      await s.screen('Second');
    });
    // The first adopts `pumpWidget`'s capture; the second finds a step that is
    // already named and takes its own picture rather than renaming it.
    tearDown(() => expect(shape(), ['First', 'Second']));
  });

  group('force declines the adoption outright', () {
    scenario('for a deliberate second picture of the same frame', (s) async {
      await s.pumpWidget(const _App());
      await s.screen('Home', force: true);
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Home']);
      expect(captures.last.verb, 'screen');
    });
  });

  group('a verb that never settled', () {
    scenario('keeps its own picture, and the screen takes another', (s) async {
      await s.pumpWidget(const _SpinnerApp());
      // A spinner is still turning when the settle gives up, so this frame is
      // one pump away from a different one — which is what the screen's own
      // settle is about to do.
      await s.tap('Start');
      await s.screen('Spinning');
    });
    tearDown(() {
      expect(captures[1].settled, isFalse);
      expect(shape(), ['pumpWidget', 'tap', 'Spinning']);
    });
  });

  group('a screen parked mid-flight on purpose', () {
    var fired = <String>[];
    scenario('says so on the name as well as on the verb', (s) async {
      fired.clear();
      await s.pumpWidget(const _SpinnerApp());
      Timer(const Duration(seconds: 3), () => fired.add('the flight ends'));
      // Both halves. A bounded policy never sees a quiet frame on a screen
      // that animates indefinitely, so it spends its whole budget — and a
      // spent budget under fake time is a clock that moved. A `screen` left
      // on the scenario's policy would run the thing being photographed to
      // completion, exactly as any other verb written here would.
      await s.tap('Start', settle: Settle.none);
      await s.screen('Mid-flight', settle: Settle.none);
      expect(fired, isEmpty);
      await s.wait(const Duration(seconds: 3));
      expect(fired, ['the flight ends']);
    });
    // And the name still lands on the tap's frame rather than on a second
    // picture of it: the frame count cannot promise a spinner held still, but
    // the bytes of a pump that moved no clock can.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Mid-flight', 'wait']);
      expect(captures[1].verb, 'tap');
    });
  });

  group('a branch’s first screen', () {
    scenario('does not put its name on the step before the fork', (s) async {
      await s.pumpWidget(const _App());
      await s.split({
        'left': () => s.screen('Left'),
        'right': () => s.screen('Right'),
      });
    });
    // Three steps, and the shared one is still anonymous: `pumpWidget`'s
    // capture is on every path, and a name belonging to one branch has no
    // business on a step the others also show.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Left', 'Right']);
      expect(captures.first.name, isNull);
    });
  });

  group('an adopted step on a shared prefix', () {
    scenario('is recognised by the replay, not captured again', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      await s.screen('Added');
      await s.split({
        'left': () => s.screen('Left'),
        'right': () => s.screen('Right'),
      });
    });
    // The adoption is keyed like an emitted step, at the index it landed on,
    // so the second replay walks the same positions and recognises both of
    // them. Without that the replay would find nothing at the screen's
    // position and emit a fresh step for it, and the branches would hang off
    // different parents.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Added', 'Left', 'Right']);
      var merged = captures[1];
      expect(merged.verb, 'tap');
      expect(captures[2].parent, merged.index);
      expect(captures[3].parent, merged.index);
    });
  });

  group('a step whose shot was skipped', () {
    scenario('is not a frame a later screen may claim', (s) async {
      await s.pumpWidget(const _App());
      // Captures nothing, but draws: the frame the screen below would name is
      // no longer the one `pumpWidget` photographed. Under this binding's
      // box-glyph font the count change rasters to the very same bytes, so
      // the visible words are the half of the proof refusing the adoption
      // here — under real fonts the pixels would refuse it too.
      await s.tap('Add', shot: Shot.skip);
      await s.screen('Added');
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Added']);
      expect(captures.last.verb, 'screen');
    });
  });

  group('a scenario that ends on an adopted screen', () {
    scenario('still hands its last step over', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      await s.screen('Added');
    });
    // The capture is held one step so this adoption can happen at all; nothing
    // follows it to force the hand-over, so the end of the body has to.
    tearDown(() {
      expect(captures, hasLength(2));
      expect(captures.last.name, 'Added');
    });
  });

  // A suite migrating from the old harness settles by hand between a verb and
  // its name. Usually that draws nothing and the frame count already says
  // yes; when it redraws the screen *identically*, only the bytes can.
  group('a screen across drawn but identical frames', () {
    scenario('still names the verb’s capture, proven on the bytes', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      // A frame the verbs did not draw, changing nothing on screen.
      s.tester.binding.scheduleFrame();
      await s.tester.pump();
      await s.screen('Added');
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Added']);
      expect(captures.last.verb, 'tap');
    });
  });

  group('a screen that never settled over identical pixels', () {
    scenario('adopts anyway — the bytes answer what settling predicted', (
      s,
    ) async {
      await s.pumpWidget(const _BusyIdleApp());
      await s.screen('Home');
    });
    // A ticker that repaints nothing: every settle gives up, frames keep
    // being drawn, and every one of them is the same picture. Emitting the
    // unsettled duplicate here would say strictly less than adopting.
    tearDown(() {
      expect(shape(), ['Home']);
      expect(captures.single.verb, 'pumpWidget');
      expect(captures.single.settled, isFalse);
    });
  });

  group('a name never overwrites a name, even byte-identical', () {
    scenario('so the second screen still takes its own picture', (s) async {
      await s.pumpWidget(const _App());
      await s.screen('First');
      s.tester.binding.scheduleFrame();
      await s.tester.pump();
      await s.screen('Second');
    });
    tearDown(() => expect(shape(), ['First', 'Second']));
  });

  group('a byte-adopted step on a shared prefix', () {
    scenario('is recognised by the replay, not captured again', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      s.tester.binding.scheduleFrame();
      await s.tester.pump();
      await s.screen('Added');
      await s.split({
        'left': () => s.screen('Left'),
        'right': () => s.screen('Right'),
      });
    });
    // The adoption consumes the screen's position exactly as the frame-exact
    // kind does, so the second replay recognises it and the branches hang off
    // the merged step.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'Added', 'Left', 'Right']);
      var merged = captures[1];
      expect(merged.verb, 'tap');
      expect(captures[2].parent, merged.index);
      expect(captures[3].parent, merged.index);
    });
  });

  // A beat consumes the branch label, but not the branch: the capture still
  // pending is the shared step before the fork, and a branch-local name has
  // no business on it however the label moved. The guard is the capture's
  // own segment, not `_pendingBranch`.
  group('a branch that opens with a beat', () {
    scenario('cannot put its name on the step before the fork', (s) async {
      await s.pumpWidget(const _App());
      await s.split({
        'left': () async {
          await s.document('note', const [1, 2, 3]);
          await s.screen('Left result');
        },
        'right': () => s.screen('Right'),
      });
    });
    tearDown(() {
      expect(shape(), ['pumpWidget', 'note', 'Left result', 'Right']);
      expect(captures.first.name, isNull);
    });
  });

  // The stretch between the verb and its name really happened — a flash that
  // came and went on provably identical end pixels — and the adopted step
  // now stands for it, so its facts merge on rather than vanishing with the
  // second picture.
  group('a real transition between the verb and its name', () {
    scenario('adopts when it lands back on the same pixels', (s) async {
      await s.pumpWidget(const _FlashApp());
      await s.tester.tap(find.text('flash'));
      await s.tester.pumpAndSettle();
      await s.screen('Home');
    });
    tearDown(() {
      expect(shape(), ['Home']);
      expect(captures.single.verb, 'pumpWidget');
      // The frames outside the verbs stay on the record.
      expect(captures.single.strayFrames, greaterThan(0));
    });
  });

  group('a screen that stopped settling after a settled verb', () {
    scenario('adopts, and the merged step keeps the truer flag', (s) async {
      await s.pumpWidget(const _LateBusyApp());
      // Fires the timer that starts an invisible ticker: from here on every
      // settle gives up, while every frame is the same picture.
      await s.tester.pump(const Duration(seconds: 3));
      await s.screen('Home');
    });
    tearDown(() {
      expect(shape(), ['Home']);
      expect(captures.single.verb, 'pumpWidget');
      expect(captures.single.settled, isFalse);
    });
  });

  group('a probe pass captures no pixels', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.none),
    );
    tearDown(() => scenarioRunArgs = null);
    scenario('so there are no bytes to prove an adoption on', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      s.tester.binding.scheduleFrame();
      await s.tester.pump();
      await s.screen('Added');
    });
    // Every probe capture holds the same empty bytes — equality there proves
    // nothing, so the screen emits as it did before the byte comparison
    // existed. Frame-exact adoption needs no pixels and still works.
    tearDown(() {
      expect(shape(), ['pumpWidget', 'tap', 'Added']);
    });
  });
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Count: $_count'),
            TextButton(
              onPressed: () => setState(() => _count++),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// An app whose tap plays a flash — an overlay fading in and straight back
/// out — so frames genuinely differ mid-way and the screen ends byte-identical
/// to where it started.
class _FlashApp extends StatefulWidget {
  const _FlashApp();

  @override
  State<_FlashApp> createState() => _FlashAppState();
}

class _FlashAppState extends State<_FlashApp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash;

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
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          GestureDetector(onTap: _flash.forward, child: const Text('flash')),
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

/// An app that is quiet at first and starts an invisible ticker on a timer —
/// the settled verb, then the screen whose settle gives up over the same
/// picture.
class _LateBusyApp extends StatefulWidget {
  const _LateBusyApp();

  @override
  State<_LateBusyApp> createState() => _LateBusyAppState();
}

class _LateBusyAppState extends State<_LateBusyApp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _busy;
  Timer? _later;

  @override
  void initState() {
    super.initState();
    _busy = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    );
    _later = Timer(const Duration(seconds: 2), () => _busy.repeat());
  }

  @override
  void dispose() {
    _later?.cancel();
    _busy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Text('Home')));
}

/// An app whose ticker runs forever and paints nothing: every settle gives
/// up, and every frame it forces is byte-identical to the last — the shape of
/// a periodic timer repainting a screen that is not changing.
class _BusyIdleApp extends StatefulWidget {
  const _BusyIdleApp();

  @override
  State<_BusyIdleApp> createState() => _BusyIdleAppState();
}

class _BusyIdleAppState extends State<_BusyIdleApp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _busy;

  @override
  void initState() {
    super.initState();
    _busy = AnimationController(vsync: this, duration: const Duration(hours: 1))
      ..repeat();
  }

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Scaffold(body: Text('Home')));
}

/// An app that puts a spinner on screen and leaves it there — so the settle
/// policy gives up rather than finishing, and the step says so.
class _SpinnerApp extends StatefulWidget {
  const _SpinnerApp();

  @override
  State<_SpinnerApp> createState() => _SpinnerAppState();
}

class _SpinnerAppState extends State<_SpinnerApp> {
  var _busy = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: _busy
            ? const CircularProgressIndicator()
            : TextButton(
                onPressed: () => setState(() => _busy = true),
                child: const Text('Start'),
              ),
      ),
    ),
  );
}
