import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/reel.dart';

/// Reading a film's timeline back as a **take** — the thing an edit plans
/// against.
///
/// The film marks what a stretch of frames *is*, at the grain a camera needs:
/// a travel, an aim, a press, the verb's own frames, the pause after it. An
/// edit wants a tap. These are the tests of that regrouping, and of the one
/// thing it must never do — read a verb back as a string at the call site.
void main() {
  Map<String, Object?> phase(
    String kind,
    int atMs,
    int durationMs, {
    String? verb,
    String? target,
    Rect? aim,
  }) => {
    'kind': kind,
    'frame': atMs ~/ 33,
    'atMs': atMs,
    'frames': durationMs ~/ 33,
    'durationMs': durationMs,
    'verb': ?verb,
    'target': ?target,
    if (aim != null)
      'aim': {'x': aim.left, 'y': aim.top, 'w': aim.width, 'h': aim.height},
  };

  Map<String, Object?> timeline(
    List<Map<String, Object?>> beats, {
    List<Map<String, Object?>> cues = const [],
  }) => {
    'version': 2,
    'scenario': 'Order a cappuccino',
    'fps': 30,
    'scale': 2,
    'width': 780,
    'height': 1688,
    'frames': 100,
    'durationMs': 3333,
    'beats': beats,
    if (cues.isNotEmpty) 'cues': cues,
  };

  test('a tap is one beat, whatever the camera did to reach it', () {
    var take = Take.decode(
      timeline([
        phase('open', 0, 500),
        phase('travel', 500, 350, verb: 'tap'),
        phase('aim', 850, 140, verb: 'tap'),
        phase('press', 990, 120, verb: 'tap'),
        phase(
          'act',
          1110,
          300,
          verb: 'tap',
          target: 'Cappuccino',
          aim: const Rect.fromLTWH(20, 100, 120, 40),
        ),
        phase('dwell', 1410, 600),
      ]),
    );

    expect(take.beats, hasLength(2));
    expect(take.beats.first, isA<Opened>());

    var tap = take.beats[1] as Tapped;
    expect(tap.label, 'Cappuccino');
    expect(tap.target, const Rect.fromLTWH(20, 100, 120, 40));
    expect(tap.held, isFalse);
    // The pause after the verb belongs to the verb: an edit holding on a tap
    // holds on the frames where the tap's own transition plays out.
    expect(tap.at, const Duration(milliseconds: 500));
    expect(tap.end, const Duration(milliseconds: 2010));
    // And the camera's own grain survives inside it, which is what lets an
    // edit start a push-in before the finger arrives.
    expect(tap.phase(PhaseKind.travel)!.at, const Duration(milliseconds: 500));
    expect(tap.phase(PhaseKind.press)!.at, const Duration(milliseconds: 990));
  });

  test('a long press is a tap that was held', () {
    var take = Take.decode(
      timeline([
        phase('travel', 0, 350, verb: 'longPress'),
        phase('act', 350, 200, verb: 'longPress', target: 'Row'),
      ]),
    );
    expect((take.beats.single as Tapped).held, isTrue);
  });

  // A point verb is the verb it says it is. `tapAt` reads back as a tap whose
  // label is the coordinate it was given, so an edit that holds on taps holds
  // on this one too — rather than falling through to the anonymous `Acted`.
  test('a tap at a point is a tap', () {
    var take = Take.decode(
      timeline([
        phase('travel', 0, 350, verb: 'tapAt'),
        phase('act', 350, 200, verb: 'tapAt', target: '200,500'),
      ]),
    );
    var tap = take.beats.single as Tapped;
    expect(tap.held, isFalse);
    expect(tap.label, '200,500');
  });

  test('typing carries the words, not a verb name', () {
    var take = Take.decode(
      timeline([
        phase(
          'focus',
          0,
          200,
          verb: 'enterText',
          aim: const Rect.fromLTWH(0, 0, 200, 44),
        ),
        phase('type', 200, 900, verb: 'enterText', target: 'Ada'),
        phase('act', 1100, 100, verb: 'enterText'),
      ]),
    );
    var typed = take.beats.single as Typed;
    expect(typed.text, 'Ada');
    expect(typed.field, const Rect.fromLTWH(0, 0, 200, 44));
  });

  test('a verb with no finger is its own beat, named by its verb', () {
    var take = Take.decode(
      timeline([
        phase('act', 0, 100, verb: 'screen', target: 'basket'),
        phase('act', 100, 100, verb: 'settle'),
      ]),
    );
    expect(take.beats.map((b) => (b as Acted).verb), ['screen', 'settle']);
    expect((take.beats.first as Acted).label, 'basket');
  });

  test('a pause with nothing before it stands alone', () {
    var take = Take.decode(timeline([phase('dwell', 0, 600)]));
    expect(take.beats.single, isA<Idled>());
  });

  test('a cue is a beat of no length, in the order it was said', () {
    var take = Take.decode(
      timeline(
        [
          phase('open', 0, 500),
          phase('travel', 500, 350, verb: 'tap'),
          phase('act', 850, 200, verb: 'tap', target: 'Buy'),
        ],
        cues: [
          {
            'atMs': 400,
            'type': 'ScenarioTitle',
            'label': 'title: Order a coffee',
            'data': {'text': 'Order a coffee'},
          },
        ],
      ),
    );
    expect(take.beats.map((b) => b.runtimeType.toString()), [
      'Opened',
      'Said',
      'Tapped',
    ]);
    var said = take.beats[1] as Said;
    expect(said.duration, Duration.zero);
    // A stock cue survives the file as itself, so an edit matches the class
    // rather than a string.
    expect(said.cue, const ScenarioTitle('Order a coffee'));
  });

  test('a cue the file cannot hold comes back as a record, not a guess', () {
    var take = Take.decode(
      timeline(
        [phase('open', 0, 100)],
        cues: [
          {
            'atMs': 50,
            'type': 'Basket',
            'label': 'Basket(3)',
            'data': {'count': 3},
          },
        ],
      ),
    );
    var cue = (take.beats.last as Said).cue as ScenarioCueRecord;
    expect(cue.type, 'Basket');
    expect(cue.data['count'], 3);
    expect('$cue', 'Basket(3)');
  });

  test('cues said in this process arrive as themselves', () {
    var take = Take.decode(
      timeline([phase('open', 0, 100)]),
      cues: [(const Duration(milliseconds: 50), const _Basket(3))],
    );
    // No codec, no registry: the edit runs where the scenario ran, so the
    // author's own class arrives whole.
    expect((take.beats.last as Said).cue, isA<_Basket>());
    expect(((take.beats.last as Said).cue as _Basket).count, 3);
  });

  test('the take says how big the frame is and how long it ran', () {
    var take = Take.decode(timeline([phase('open', 0, 100)]));
    expect(take.scenario, 'Order a cappuccino');
    expect(take.size, const Size(780, 1688));
    expect(take.scale, 2);
    expect(take.duration, const Duration(milliseconds: 3333));
  });
}

class _Basket {
  const _Basket(this.count);
  final int count;
}
