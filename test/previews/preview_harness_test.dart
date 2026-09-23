import 'dart:async';

import 'package:clock/clock.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
// The half of the harness `flutter_test.dart` does not re-export.
import 'package:flutterware/src/clock.dart';
import 'package:flutterware/src/previews/harness.dart';
import 'package:flutterware/ui_catalog.dart';

/// Exercises the harness the way `flutter test` does — this file *is* the
/// `flutter test` lane, so the entries below are declared as real tests and
/// their passing is half the assertion.
void main() {
  var size = <String, Size>{};
  var knob = <String, String>{};
  var loaded = false;
  var decoded = false;
  var trackedDrawn = false;
  var clockAt = <String, DateTime>{};

  Widget probe(String id) => Builder(
    builder: (context) {
      size[id] = MediaQuery.of(context).size;
      clockAt[id] = clock.now();
      // A preview reading a knob with nothing hosting it answers the default
      // rather than throwing — but under `CatalogGuest` there *is* something
      // hosting it, and that is the path worth proving.
      knob[id] = context.knobs.string('label', 'unanswered');
      return const SizedBox.shrink();
    },
  );

  runPreviewHarness(
    [
      PreviewEntry(
        id: 'demo/phone.dart#phone',
        path: 'demo/phone.dart',
        name: 'Phone',
        build: () => probe('phone'),
      ),
      PreviewEntry(
        id: 'demo/desktop/wide.dart#wide',
        path: 'demo/desktop/wide.dart',
        name: 'Wide',
        build: () => probe('wide'),
      ),
      PreviewEntry(
        id: 'demo/plain.dart#plain',
        path: 'demo/plain.dart',
        name: 'Plain',
        build: () => probe('plain'),
      ),
      PreviewEntry(
        id: 'demo/slow.dart#slow',
        path: 'demo/slow.dart',
        name: 'Slow',
        build: () => _SlowLoad(onLoaded: () => loaded = true),
      ),
      PreviewEntry(
        id: 'demo/decoding.dart#decoding',
        path: 'demo/decoding.dart',
        name: 'Decoding',
        build: () => _LateDecode(onDecoded: () => decoded = true),
      ),
      PreviewEntry(
        id: 'demo/tracked.dart#tracked',
        path: 'demo/tracked.dart',
        name: 'Tracked',
        build: () => _TrackedLoad(onDrawnLoaded: () => trackedDrawn = true),
      ),
    ],
    canvases: const [
      PreviewCanvas('demo', devices: [Devices.iphoneSe]),
      PreviewCanvas('demo/desktop', devices: [Devices.wideWindow]),
    ],
  );

  // Declared after the entries, so it runs after them: what the entries saw is
  // what these assert on.
  test('each entry is framed by the canvas its own path resolves to', () {
    // Longest prefix wins, which is the whole reason `canvasFor` is shared
    // rather than re-implemented per caller.
    expect(size['phone']!.width, Devices.iphoneSe.width);
    expect(
      size['wide']!.width,
      previewPanelWidth.toDouble(),
      reason:
          'a declared window is offered rather than staged, here as well as '
          'in the panel — see PreviewCanvas.defaultDevice',
    );
    expect(
      size['plain']!.width,
      Devices.iphoneSe.width,
      reason: 'demo/plain.dart is under `demo`, not under `demo/desktop`',
    );
  });

  test('a preview builds under the same host the guest entrypoint mounts', () {
    // `CatalogGuest` is what puts the knobs provider up. Without it every read
    // answers the written default, which looks identical until somebody sets
    // one — so this is the assertion that says the two backends mount the same
    // tree rather than merely both rendering something.
    expect(knob, hasLength(3));
    expect(knob['phone'], 'unanswered');
  });

  test('an entry reads the pinned clock rather than the wall clock', () {
    // The bug this closes: `runPreviewHarness` mounted the entries and pinned
    // nothing, so `clock.now()` fell through to `DateTime.now()`. Every
    // picture of an entry showing a date was then a picture of the minute it
    // was taken — the audit and the comparison both read this lane, so a
    // branch that touched no widget still reported those entries as changed.
    //
    // Asserted per entry rather than once: the pin is mounted inside the body
    // `_declare` writes, so an entry left outside it would be the one that
    // still drifts.
    expect(clockAt, hasLength(3));
    for (var MapEntry(key: id, value: at) in clockAt.entries) {
      expect(at, pinnedClockOrigin, reason: '$id rendered off the wall clock');
    }
  });

  test('an entry that waits on a timer is given the clock to finish', () {
    // The entry above passing at all is half the assertion: a frame-driven
    // settle returns 100ms in and the tree is disposed with the load's timer
    // pending, which `flutter_test` fails the test for. This is the other half
    // — the load finished, rather than the timer having been merely drained.
    expect(loaded, isTrue);
  });

  test('a decode that starts mid-settle is landed before the entry is judged', () {
    // The blind spot the audit shared with a scenario's capture: the harness
    // turns the real event loop once, at boot, and a demo that holds a
    // placeholder for half a second starts its load *after* that — on fake
    // time, which the real loop never sees. Anything the load then reported —
    // the whole point of an audit — arrived after the errors were read.
    //
    // Measured on `fixtures/probe_app/demo/vector_smoke.dart`: with this entry
    // shaped as a `VectorGraphic` pointing at an asset no build ships, the
    // audit reported it clean, because the read that would have thrown never
    // completed.
    expect(decoded, isTrue);
  });

  test('a tracked load is drawn loaded however long it takes', () {
    // Longer than the second the lane used to allow, which is what made the
    // picture depend on the machine: a load that fit on an idle one did not
    // on a busy one, and the entry was photographed on its spinner.
    expect(auditTrackedWait, greaterThan(_TrackedLoad.duration));
    expect(trackedDrawn, isTrue);
  });

  test('a row says the harness ran out of clock, not that the entry leaks', () {
    expect(
      auditFailureMessage(
        'A Timer is still pending even after the widget tree was disposed.',
      ),
      allOf(
        contains('${auditBudget.inSeconds}s'),
        contains('the audit clock'),
        isNot(contains('binding.dart')),
      ),
    );
  });

  test('every other failure is passed through as the framework wrote it', () {
    expect(
      auditFailureMessage('A RenderFlex overflowed by 3.5 pixels'),
      'A RenderFlex overflowed by 3.5 pixels',
    );
  });

  test('the real fonts were loaded, not the fallback', () {
    // Under `flutter test` this is the FontLoader half only — the engine still
    // has `--use-test-fonts` forced on it, so the families below are the
    // project's own, loaded from its manifest.
    expect(loadedScenarioFonts, isNotNull);
  });

  testWidgets('text naming no family is measured in something real too', (
    tester,
  ) async {
    // Most of a catalog names no family, and `--use-test-fonts` gives every
    // glyph of an unloaded family the same advance — so a narrow string and a
    // wide one agreeing is the fingerprint of a catalog measured in boxes.
    // Nothing here loads them: the harness's own `setUpAll` did, which is the
    // claim.
    Future<Size> measure(String text) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Text(text))));
      return tester.getSize(find.text(text));
    }

    expect(
      (await measure('iiiii')).width,
      lessThan((await measure('WWWWW')).width),
    );
  });
}

/// A preview that shows a placeholder until a timer says otherwise — the shape
/// of every demo whose point is the placeholder, and the one nothing in the
/// frame loop can see waiting.
class _SlowLoad extends StatefulWidget {
  const _SlowLoad({required this.onLoaded});

  final VoidCallback onLoaded;

  @override
  State<_SlowLoad> createState() => _SlowLoadState();
}

class _SlowLoadState extends State<_SlowLoad> {
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 250)).then((_) {
        if (!mounted) return;
        widget.onLoaded();
        setState(() => _loaded = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Text(
    _loaded ? 'loaded' : 'placeholder',
    textDirection: TextDirection.ltr,
  );
}

/// A preview whose decode both *starts* on the fake clock and *finishes* on the
/// real event loop — `vector_graphics`, Lottie or an `ImageProvider` behind a
/// placeholder, which is where the two waits meet.
///
/// `Zone.root` rather than an asset read, for the reason
/// `test/scenarios/real_async_paint_test.dart` gives: under `flutter test` an
/// asset read is answered from a `readAsBytesSync` and completes under
/// FakeAsync, so it would prove nothing here and everything in the lane that
/// spawns its own tester.
class _LateDecode extends StatefulWidget {
  const _LateDecode({required this.onDecoded});

  final VoidCallback onDecoded;

  @override
  State<_LateDecode> createState() => _LateDecodeState();
}

class _LateDecodeState extends State<_LateDecode> {
  var _decoded = false;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      await Zone.root.run(() => Future<void>.delayed(Duration.zero));
      if (!mounted) return;
      widget.onDecoded();
      setState(() => _decoded = true);
    }());
  }

  @override
  Widget build(BuildContext context) =>
      Text(_decoded ? 'decoded' : 'decoding', textDirection: TextDirection.ltr);
}

/// A preview announcing a load that takes real seconds, behind a spinner — an
/// import of a real model, which is what a one-second allowance did not cover.
class _TrackedLoad extends StatefulWidget {
  const _TrackedLoad({required this.onDrawnLoaded});

  /// Twice the old allowance, so a lane that still gave up at one second
  /// could not land it by the time its turns add up.
  static const duration = Duration(seconds: 2);

  final VoidCallback onDrawnLoaded;

  @override
  State<_TrackedLoad> createState() => _TrackedLoadState();
}

class _TrackedLoadState extends State<_TrackedLoad> {
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      RealWork.run(
        () => Future<void>.delayed(_TrackedLoad.duration),
        label: 'model',
      ).then((_) {
        if (mounted) setState(() => _loaded = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    widget.onDrawnLoaded();
    return const Text('loaded', textDirection: TextDirection.ltr);
  }
}
