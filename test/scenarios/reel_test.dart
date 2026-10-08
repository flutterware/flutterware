import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/reel.dart';

/// Building a **reel** from a take: the output timeline, and the two clocks
/// that make one.
///
/// An edit is pure — a take in, a reel out — so all of this runs with no app,
/// no pixels and no process to spawn. That is most of the point of the shape.
void main() {
  Map<String, Object?> phase(
    String kind,
    int atMs,
    int durationMs, {
    String? verb,
    String? target,
  }) => {
    'kind': kind,
    'frame': atMs ~/ 33,
    'atMs': atMs,
    'frames': durationMs ~/ 33,
    'durationMs': durationMs,
    'verb': ?verb,
    'target': ?target,
  };

  Take takeOf(
    List<Map<String, Object?>> beats, {
    List<Map<String, Object?>> cues = const [],
  }) => Take.decode({
    'version': 2,
    'scenario': 'Order a cappuccino',
    'fps': 30,
    'scale': 1,
    'width': 100,
    'height': 200,
    'frames': 100,
    'durationMs': 3333,
    'beats': beats,
    if (cues.isNotEmpty) 'cues': cues,
  });

  var walk = [
    phase('open', 0, 500),
    phase('travel', 500, 300, verb: 'tap'),
    phase('act', 800, 200, verb: 'tap', target: 'Buy'),
    phase('dwell', 1000, 400),
  ];

  test('playing a take through is the take, end to end', () {
    var b = ReelBuilder(takeOf(walk));
    for (var beat in b.take.beats) {
      b.playBeat(beat);
    }
    var reel = b.build();
    expect(reel.duration, const Duration(milliseconds: 1400));
    expect(reel.shots.every((s) => !s.frozen), isTrue);
    // Contiguous by construction: a gap is a black frame nobody asked for.
    for (var i = 1; i < reel.shots.length; i++) {
      expect(reel.shots[i].at, reel.shots[i - 1].end);
    }
  });

  test('a freeze spends reel time and no scenario', () {
    var b = ReelBuilder(takeOf(walk))
      ..play(const Duration(seconds: 1))
      ..freeze(const Duration(milliseconds: 500))
      ..play(const Duration(seconds: 1));
    var reel = b.build();
    expect(reel.duration, const Duration(milliseconds: 2500));
    expect(reel.shots.map((s) => s.frozen), [false, true, false]);
  });

  test('a hold asks the run for more app, and shows it', () {
    var take = takeOf(walk);
    var tap = take.beats.whereType<Tapped>().single;
    var b = ReelBuilder(take);
    for (var beat in take.beats) {
      b.playBeat(beat);
      if (beat is Tapped) b.hold(const Duration(seconds: 2), after: beat);
    }
    var reel = b.build();
    // The ask lands on the pause after the tap, which is where the film has
    // the run in its hands with nothing being touched.
    expect(reel.holds, {
      tap.phase(PhaseKind.dwell)!.index: const Duration(seconds: 2),
    });
    // And the reel is two seconds longer, because those frames are real.
    expect(reel.duration, const Duration(milliseconds: 3400));
    expect(reel.shots.every((s) => !s.frozen), isTrue);
  });

  test('a beat that never paused cannot be held after', () {
    var take = takeOf([phase('act', 0, 100, verb: 'screen', target: 'basket')]);
    var b = ReelBuilder(take)
      ..hold(const Duration(seconds: 1), after: take.beats.single);
    expect(b.build().holds, isEmpty);
    expect(b.build().duration, Duration.zero);
  });

  test('a cue is laid over what plays, and moves neither clock', () {
    var b = ReelBuilder(takeOf(walk))
      ..play(const Duration(seconds: 1))
      ..say(
        const ScenarioTitle('Order a coffee'),
        over: const Duration(seconds: 2),
      )
      ..play(const Duration(seconds: 1));
    var reel = b.build();
    expect(reel.duration, const Duration(seconds: 2));
    expect(reel.cuesAt(const Duration(milliseconds: 500)), isEmpty);
    expect(reel.cuesAt(const Duration(milliseconds: 1500)), hasLength(1));
    // It outlives the shots it was laid over — reel time is the only clock a
    // cue is in.
    expect(reel.cuesAt(const Duration(milliseconds: 2500)), hasLength(1));
    expect(reel.cuesAt(const Duration(milliseconds: 3500)), isEmpty);
    // The span comes with it, so a stage can draw a fade from where it is.
    var span = reel.cuesAt(const Duration(milliseconds: 1500)).single;
    expect(span.progress(const Duration(milliseconds: 2000)), 0.5);
  });

  test('the stock edit plays it all, titles what was said, holds the end', () {
    var take = takeOf(
      walk,
      cues: [
        {
          'atMs': 400,
          'type': 'ScenarioTitle',
          'label': 'title: Order a coffee',
          'data': {'text': 'Order a coffee'},
        },
      ],
    );
    var reel = const StockReel().edit(take);
    // Every beat is played and the cue costs no time — the take's own length,
    // plus the tail.
    expect(reel.duration, const Duration(milliseconds: 1400 + 900));
    expect(reel.shots.last.frozen, isTrue);
    expect(
      reel.cuesAt(const Duration(milliseconds: 600)).single.cue,
      const ScenarioTitle('Order a coffee'),
    );
  });

  test('a stage sizes the output, and the default is the app', () {
    expect(
      const BareStage().sizeFor(const Size(390, 844)),
      const Size(390, 844),
    );
  });
}
