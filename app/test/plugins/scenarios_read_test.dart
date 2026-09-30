import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_core.dart';
import 'package:flutterware_app/src/plugins/native/scenarios_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// `scenarios read`: a run's archive in, the same screen every other surface
/// answers with out. The tree here is a fixture rather than a real capture —
/// what a real one produces is exercised against `fixtures/probe_app` by hand;
/// this pins the reading, the selector and the refusals.
void main() {
  late Directory worktree;
  late ScenariosCore core;

  /// `<worktree>/build/flutterware/scenario_runs/<stamp>` with one scenario in
  /// it, laid out exactly as a run writes it.
  String writeRun({
    required String stamp,
    required bool ok,
    int steps = 3,
    bool withTrees = true,
    Map<int, List<Map<String, Object?>>> events = const {},
  }) {
    var runDir = p.join(
      worktree.path,
      'build',
      'flutterware',
      'scenario_runs',
      stamp,
    );
    var stepsDir = p.join(runDir, 'checkout_test.dart', 'Checkout');
    Directory(stepsDir).createSync(recursive: true);

    var records = <Map<String, Object?>>[];
    for (var index = 1; index <= steps; index++) {
      var base = p.join(stepsDir, '$index-step');
      File('$base.png').writeAsBytesSync(const [1, 2, 3]);
      if (withTrees) {
        File('$base.tree.json').writeAsStringSync(
          jsonEncode({
            'root': {
              'id': '',
              'type': 'Shop',
              'layout': {'x': 0, 'y': 0, 'width': 300, 'height': 600},
              'children': [
                {
                  'id': '0',
                  'type': 'Text',
                  'description': 'Text("Total: $index")',
                  'layout': {'x': 0, 'y': 0, 'width': 300, 'height': 20},
                },
                {
                  'id': '1',
                  'type': 'ElevatedButton',
                  'label': 'Pay',
                  'layout': {'x': 0, 'y': 40, 'width': 120, 'height': 40},
                },
              ],
            },
          }),
        );
      }
      var stepEvents = events[index];
      if (stepEvents != null) {
        File('$base.events.json').writeAsStringSync(jsonEncode(stepEvents));
      }
      records.add({
        'index': index,
        'position': '#$index',
        'auto': false,
        if (stepEvents != null) ...{
          'events': p.relative('$base.events.json', from: worktree.path),
          'eventCount': stepEvents.length,
          'eventChannels': <String, int>{
            for (var event in stepEvents)
              '${event['channel']}': stepEvents
                  .where((e) => e['channel'] == event['channel'])
                  .length,
          },
        },
        'image': p.relative('$base.png', from: worktree.path),
        'format': 'png',
        'width': 300,
        'height': 600,
        'tree': p.relative('$base.tree.json', from: worktree.path),
        'texts': ['Total: $index', 'Pay'],
        'address': 'fw:///worktrees/wt/flutterware.scenarios/./x/$index',
        if (!ok && index == steps) 'failure': 'Expected "Total: 9"',
      });
    }

    File(p.join(runDir, scenarioRunReportFile)).writeAsStringSync(
      jsonEncode({
        'packages': [
          {
            'path': '.',
            'output': runDir,
            'ms': 5,
            'scenarios': [
              {
                'file': 'test/checkout_test.dart',
                'name': 'Checkout',
                'ok': ok,
                'ms': 5,
                'steps': records,
                'stepCount': records.length,
                'errors': [
                  if (!ok) {'error': 'Expected "Total: 9"'},
                ],
              },
            ],
          },
        ],
      }),
    );
    return runDir;
  }

  Future<ScenarioReadResult> read([
    Map<String, Object?> arguments = const {},
  ]) => core
      .invoke('read', arguments: arguments)
      .then((r) => r! as ScenarioReadResult);

  setUp(() {
    worktree = Directory.systemTemp.createTempSync('fw-scenarios-read-');
    var tree = Worktree(path: worktree.path, isMain: true);
    core = ScenariosCore(
      PluginHost(
        id: scenariosPluginId,
        label: 'Scenarios',
        worktree: tree,
        config: const {
          'packages': [
            {'path': '.'},
          ],
        },
        workspace: Workspace(
          root: tree.path,
          declared: [],
          discovered: [],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
      ),
    );
  });

  tearDown(() {
    core.dispose();
    worktree.deleteSync(recursive: true);
  });

  test('with nothing said it takes the step the scenario failed on', () async {
    writeRun(stamp: '100', ok: false);

    var result = await read();

    expect(result.index, 3);
    expect(result.scenario, 'Checkout');
    expect(result.file, 'test/checkout_test.dart');
    expect(result.failure, 'Expected "Total: 9"');
    expect(result.lens, 'act');
    // The screen, which is the whole point of the action.
    expect(result.screen!.items, hasLength(2));
    expect(
      result.screen!.toJson().toString(),
      contains('Total: 3'),
      reason: 'it read the failing step, not the first one',
    );
    // And the handles for going on: what else to ask, and where the other
    // steps of the same flow are.
    expect(result.next, contains('find'));
    expect(result.steps, [
      '1-step.tree.json',
      '2-step.tree.json',
      '3-step.tree.json',
    ], reason: 'names beside `step`, not the same directory five times');
  });

  test('a failing step with no tree still answers with its failure', () async {
    // The step a timed-out scenario never took: no picture, no tree, just
    // the diagnosis and what the app printed on the way there.
    var runDir = writeRun(stamp: '100', ok: false, steps: 1);
    var stepsDir = p.join(runDir, 'checkout_test.dart', 'Checkout');
    var base = p.join(stepsDir, '2-failed');
    File('$base.events.json').writeAsStringSync(
      jsonEncode([
        {'channel': 'print', 'title': 'about to hang'},
      ]),
    );
    var report = File(p.join(runDir, scenarioRunReportFile));
    var json = (jsonDecode(report.readAsStringSync()) as Map)
        .cast<String, Object?>();
    var scenario =
        (((json['packages']! as List).first as Map)['scenarios'] as List).first
            as Map;
    (scenario['steps'] as List).add({
      'index': 2,
      'position': '#2',
      'parent': 1,
      'auto': true,
      'format': 'none',
      'texts': <String>[],
      'events': p.relative('$base.events.json', from: worktree.path),
      'eventCount': 1,
      'eventChannels': {'print': 1},
      'eventTitles': ['about to hang'],
      'settled': false,
      'failure': 'the scenario did not finish within 30s.',
    });
    scenario['stepCount'] = 2;
    report.writeAsStringSync(jsonEncode(json));

    var result = await read({'events': 'true'});

    expect(result.index, 2);
    expect(result.failure, contains('did not finish'));
    expect(result.screen, isNull);
    expect(result.note, contains('no screen'));
    expect(result.events!.single.title, 'about to hang');
  });

  test('the address run prints on a step names that step', () async {
    writeRun(stamp: '100', ok: true);

    var result = await read({
      'step':
          'fw:///worktrees/wt/flutterware.scenarios/./test/checkout_test.dart'
          '/Checkout/2',
    });

    expect(result.index, 2);
    expect(result.scenario, 'Checkout');
    expect(result.screen!.toJson().toString(), contains('Total: 2'));
  });

  test('an address naming a step the run does not have is refused', () async {
    writeRun(stamp: '100', ok: true);

    await expectLater(
      read({
        'step':
            'fw:///worktrees/wt/flutterware.scenarios/./test/checkout_test.dart'
            '/Checkout/9',
      }),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('no step 9'), contains('Checkout')),
        ),
      ),
    );
    await expectLater(
      read({'step': 'fw:///worktrees/wt/flutterware.scenarios/.'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('names one step of one scenario'),
        ),
      ),
    );
  });

  test('the newest run is the one read', () async {
    writeRun(stamp: '100', ok: false);
    writeRun(stamp: '200', ok: false, steps: 2);

    expect((await read()).step, contains('/200/'));
  });

  test('a green run refuses, and the refusal is the listing', () async {
    writeRun(stamp: '100', ok: true);

    await expectLater(
      read(),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(
            contains('nothing failed'),
            contains('Checkout'),
            contains('3 steps'),
            // The value to pass next, so browsing costs a refusal not a guess.
            contains('3-step.tree.json'),
          ),
        ),
      ),
    );
  });

  test('a step is named by any leg of its capture, or by its index', () async {
    var runDir = writeRun(stamp: '100', ok: true);
    var base = p.join(runDir, 'checkout_test.dart', 'Checkout', '2-step');

    for (var named in [
      p.relative('$base.tree.json', from: worktree.path),
      p.relative('$base.png', from: worktree.path),
      '$base.tree.json',
      '2',
    ]) {
      var result = await read({'step': named});
      expect(result.index, 2, reason: named);
      expect(result.screen!.toJson().toString(), contains('Total: 2'));
    }
  });

  test('naming a directory lists what is in it', () async {
    var runDir = writeRun(stamp: '100', ok: true);

    await expectLater(
      read({'step': p.join(runDir, 'checkout_test.dart', 'Checkout')}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('3 captures'), contains('1-step.tree.json')),
        ),
      ),
    );
    await expectLater(
      read({'step': p.join(runDir, 'checkout_test.dart')}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('directories there'),
        ),
      ),
    );
  });

  test('the queries run over the same capture', () async {
    writeRun(stamp: '100', ok: true);

    var result = await read({
      'step': '1',
      'screen': false,
      'find': 'Pay',
      'at': '10,50',
      'styles': true,
      'texts': true,
    });

    expect(result.screen, isNull);
    expect(result.find!.single['type'], 'ElevatedButton');
    // Innermost last, and the button is what is at that point.
    expect(result.at!.last['type'], 'ElevatedButton');
    expect(result.styles, isEmpty);
    expect(result.texts, ['Total: 1', 'Pay']);
  });

  test('a point that is not one rides the note, not an error', () async {
    writeRun(stamp: '100', ok: true);

    var result = await read({'step': '1', 'at': 'the button'});

    expect(result.screen, isNotNull, reason: 'the read still happened');
    expect(result.note, contains('not a point'));
  });

  test('the lens sets what nobody said, and names itself', () async {
    writeRun(stamp: '100', ok: true);

    var act = await read({'step': '1'});
    expect(act.lens, 'act');
    expect(act.tree, isNull);
    expect(act.styles, isNull);
    expect(act.artifacts, isEmpty);

    var look = await read({'step': '1', 'lens': 'look'});
    expect(look.lens, 'look');
    expect(look.artifacts.single.path, endsWith('1-step.png'));
    expect(look.tree, isNull);

    var raw = await read({'step': '1', 'lens': 'raw'});
    expect(raw.tree, isNotNull);
    expect(raw.styles, isNotNull);

    // Explicit always beats the preset.
    var quiet = await read({'step': '1', 'lens': 'raw', 'tree': false});
    expect(quiet.tree, isNull);
    expect(quiet.nodes, isNotNull, reason: 'the count is free either way');
  });

  test('an unknown lens is refused with the four that exist', () async {
    writeRun(stamp: '100', ok: true);

    await expectLater(
      read({'step': '1', 'lens': 'pretty'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('act'), contains('look'), contains('raw')),
        ),
      ),
    );
  });

  test('a capture with no tree says which lane drops it', () async {
    writeRun(stamp: '100', ok: true, withTrees: false);

    await expectLater(
      read({'step': '1'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('no widget tree'), contains('shots')),
        ),
      ),
    );
  });

  test('no run at all says to make one', () async {
    await expectLater(
      read(),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('no scenario run on disk'),
        ),
      ),
    );
  });

  group('what the app did on the way here', () {
    /// One busy step: the shape a real transition has — a couple of things
    /// the app reported, and a pile of framework chatter around them.
    Map<int, List<Map<String, Object?>>> busyStep() => {
      3: [
        {'channel': 'system', 'title': 'flutter/textinput TextInput.show'},
        {'channel': 'system', 'title': 'flutter/accessibility'},
        {
          'channel': 'network',
          'title': 'POST /pay',
          'detail': '500',
          'error': true,
          'body': '{"reason":"card_declined"}',
        },
        {'channel': 'db', 'title': 'SELECT * FROM cart', 'detail': '3 rows'},
        {'channel': 'log', 'title': 'paying', 'level': 'INFO'},
      ],
    };

    test(
      'a read that did not ask still says there is something to ask',
      () async {
        // The regression this whole lane exists for: an agent that does not
        // already know events are a thing has to be told by the reply, on the
        // step that has them. `next` is where it looks on step forty.
        writeRun(stamp: '100', ok: false, events: busyStep());

        var result = await read();

        expect(result.events, isNull, reason: 'not paid for unless asked');
        expect(result.eventCount, 5);
        expect(result.eventChannels, {
          'system': 2,
          'network': 1,
          'db': 1,
          'log': 1,
        });
        expect(result.next, contains('events: true'));
        expect(result.next, contains('5 on'));
      },
    );

    test('a step with none says nothing about them', () async {
      writeRun(stamp: '100', ok: false);

      var result = await read();

      expect(result.eventCount, isNull);
      expect(result.eventChannels, isNull);
      expect(result.next, isNot(contains('events')));
    });

    test('events: true hands back the payload, without the chatter', () async {
      writeRun(stamp: '100', ok: false, events: busyStep());

      var result = await read({'events': true});

      expect(
        [for (var event in result.events!) event.channel],
        ['network', 'db', 'log'],
        reason: '`system` is most of the volume and none of the signal',
      );
      // The part that was unreachable before without opening the raw file.
      expect(result.events!.first.body, '{"reason":"card_declined"}');
      expect(result.events!.first.error, isTrue);
      // The count still describes the whole capture, as `run` reports it.
      expect(result.eventCount, 5);
    });

    test('channel narrows, and is the only way to see system', () async {
      writeRun(stamp: '100', ok: false, events: busyStep());

      var network = await read({'channel': 'network'});
      expect([for (var e in network.events!) e.title], ['POST /pay']);

      var system = await read({'channel': 'system'});
      expect(system.events, hasLength(2));

      var both = await read({'channel': 'db,log'});
      expect([for (var e in both.events!) e.channel], ['db', 'log']);

      // Repeatable, so a list is what a caller reading the listing sends —
      // and it used to fall through to "no filter" without a word.
      var listed = await read({
        'channel': ['db', 'log'],
      });
      expect([for (var e in listed.events!) e.channel], ['db', 'log']);
    });

    test('errors: true is the first question to ask of a red step', () async {
      writeRun(stamp: '100', ok: false, events: busyStep());

      var result = await read({'errors': true});

      expect([for (var e in result.events!) e.title], ['POST /pay']);
    });

    test(
      'a filter that matches nothing says why, rather than going quiet',
      () async {
        writeRun(stamp: '100', ok: false, events: busyStep());

        var result = await read({'channel': 'analytics'});

        expect(result.events, isEmpty);
        expect(result.note, contains('This step recorded 5'));
        expect(result.note, contains('network'));
      },
    );

    test('naming a channel implies events, without also saying so', () async {
      writeRun(stamp: '100', ok: false, events: busyStep());

      expect((await read({'channel': 'db'})).events, isNotNull);
      expect((await read({'errors': true})).events, isNotNull);
    });

    test('pointing step at the events leg answers about events', () async {
      // It used to answer about the widget tree instead — silently, with
      // `step` rewritten to the `.tree.json`. A reply may not substitute a
      // different question for the one it was asked.
      var runDir = writeRun(stamp: '100', ok: false, events: busyStep());
      var leg = p.join(
        runDir,
        'checkout_test.dart',
        'Checkout',
        '3-step.events.json',
      );

      var result = await read({'step': leg});

      expect(result.events, isNotNull);
      expect(
        [for (var e in result.events!) e.channel],
        ['network', 'db', 'log'],
      );
    });

    test('a step whose events file is gone says so', () async {
      writeRun(stamp: '100', ok: false);

      var result = await read({'events': true});

      expect(result.events, isNull);
      expect(result.note, contains('no events'));
    });
  });
}
