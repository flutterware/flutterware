import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/native/run_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/journal.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:vm_service/vm_service.dart' show RPCError;

/// The act action: guest bundle in (through the [RunCore.debugAct] seam),
/// result + journal + artifacts out. The guest side itself is exercised over
/// the real wire by the drive spike.
void main() {
  late Directory runDir;
  late Directory worktree;
  late RunCore core;
  late RunHandle handle;

  setUp(() {
    runDir = Directory.systemTemp.createTempSync('fw-act-');
    worktree = Directory.systemTemp.createTempSync('fw-act-wt-');
    RunCore.runDirProvider = () => runDir.path;
    var tree = Worktree(path: worktree.path, isMain: true);
    core = RunCore(
      PluginHost(
        id: runPluginId,
        label: 'Run',
        worktree: tree,
        config: const {},
        workspace: Workspace(
          root: tree.path,
          declared: [],
          discovered: [],
          appContext: AppContext(logger: LogClient.print()),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
      ),
    );
    // No device on the other end of these tests, so the native layer is not
    // one of the answers — said here rather than discovered by `adb` and
    // `xcrun` being run for every refusal.
    core.debugNativeAvailable = false;
    handle = RunHandle(
      worktree: worktree.path,
      worktreeName: '~',
      device: 'macos',
      entrypoint: 'lib/main.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
  });

  tearDown(() {
    core.dispose();
    RunCore.runDirProvider = flutterwareRunDir;
    for (var dir in [runDir, worktree]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('a landed tap: result, artifact, journal entry', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'tap',
          'target': '"Pay"',
          'attempts': 2,
          'elapsedMs': 450,
          'settle': {
            'settled': true,
            'frames': 12,
            'forcedFrames': 0,
            'framesEnabled': true,
            'elapsedMs': 300,
          },
        },
        'lifecycle': 'resumed',
        'texts': ['Pay', 'Receipt'],
        // Boxes, and different ones: the host runs the noise filter over
        // whatever the guest sends, and two nodes that share a box are one
        // node with a wrapper on it — which is exactly what that filter is
        // for, and would make this a one-node tree.
        'tree': {
          'root': {
            'id': '',
            'type': 'MyApp',
            'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
            'children': [
              {
                'id': '0',
                'type': 'Receipt',
                'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 40},
              },
            ],
          },
        },
        'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
        'logs': [
          {'sequence': 1, 'text': 'paid'},
        ],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'tap', 'target': 'Pay', 'tree': true},
            ))!
            as RunActResult;

    expect(wire!['verb'], 'tap');
    expect(wire!['target'], 'Pay');
    expect(wire!.containsKey('tree'), isFalse, reason: 'tree was asked for');
    expect(result.ok, isTrue);
    expect(result.verb, 'tap');
    expect(result.target, '"Pay"');
    expect(result.attempts, 2);
    expect(result.settled, isTrue);
    expect(result.texts, ['Pay', 'Receipt']);
    expect(result.nodes, 2);
    expect(result.logs!.single.text, 'paid');
    expect(File(result.screenshot!).existsSync(), isTrue);

    var entry = readJournal(handle).single;
    expect(entry.verb, 'tap');
    expect(entry.actor, 'agent');
    expect(entry.target, '"Pay"');
    expect(entry.settled, isTrue);
    expect(entry.screenshot, result.screenshot);
    expect(entry.logLines, 1);
  });

  test('every step archives the whole moment, whatever it returned', () async {
    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'observe',
        'settle': {'settled': true},
      },
      'lifecycle': 'resumed',
      'texts': ['Pay', 'Receipt'],
      // Two nodes sharing a box: the noise filter reports one and the
      // archive must still hold both.
      'tree': {
        'root': {
          'id': '',
          'type': 'MyApp',
          'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
          'children': [
            {
              'id': '0',
              'type': 'Receipt',
              'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
            },
          ],
        },
      },
      'semantics': {
        'rect': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
        'label': 'Pay',
        'children': <Object?>[],
      },
      'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
    };

    // Nothing asked for: no tree inline, no picture returned.
    var result =
        (await core.invoke('act', arguments: {'verb': 'observe'}))!
            as RunActResult;

    expect(result.tree, isNull, reason: 'the reply carries no tree');
    expect(
      result.screenshotArtifact,
      isNull,
      reason: 'no picture was asked for, so none is shown',
    );
    expect(result.capture, contains('/steps/'));

    // …and all four legs are on disk anyway, with a manifest naming them.
    var stem = result.screenshot!.replaceAll('.png', '');
    for (var leg in ['.png', '.tree.json', '.semantics.json', '.texts.json']) {
      expect(File('$stem$leg').existsSync(), isTrue, reason: leg);
    }

    var manifest = jsonDecode(
      File('$stem.capture.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['capture'], result.capture);
    expect(manifest['verb'], 'observe');
    expect(
      (manifest['tree']! as Map)['nodes'],
      2,
      reason: 'the archived tree is the whole one, not the filtered one',
    );
    expect(manifest['reported'], [
      'screen',
    ], reason: 'the testimony says what came back, which was not the picture');

    // The journal points at the same moment, and says the same thing.
    var entry = readJournal(handle).single;
    expect(entry.capture, result.capture);
    expect(entry.reported, ['screen']);
    expect(entry.semantics, '$stem.semantics.json');
  });

  group('acting on a screen item', () {
    /// One observation, so there is a numbered screen to act against.
    Future<RunActResult> observe() async {
      core.debugAct = (handle, args) async => {
        'step': {
          'verb': 'observe',
          'settle': {'settled': true},
        },
        'lifecycle': 'resumed',
        'texts': ['Pay'],
        'tree': {
          'root': {
            'id': '',
            'type': 'Column',
            'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
            'children': [
              {
                'id': '0',
                'type': 'InkWell',
                'label': 'Pay',
                'layout': {'x': 10, 'y': 20, 'width': 40, 'height': 30},
              },
              {
                'id': '1',
                'type': 'IconButton',
                'layout': {'x': 60, 'y': 20, 'width': 20, 'height': 20},
              },
            ],
          },
        },
        'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
      };
      return (await core.invoke('act', arguments: {'verb': 'observe'}))!
          as RunActResult;
    }

    test('becomes a point at the centre of its box', () async {
      var seen = await observe();
      expect(seen.screen!.items.map((i) => i.words), ['Pay', null]);

      Map<String, String>? wire;
      core.debugAct = (handle, args) async {
        wire = args;
        return {
          'step': {
            'verb': 'tap',
            'settle': {'settled': true},
          },
          'lifecycle': 'resumed',
          'texts': ['Pay'],
        };
      };

      var result =
          (await core.invoke('act', arguments: {'verb': 'tap', 'item': 1}))!
              as RunActResult;

      expect(result.ok, isTrue);
      expect(
        wire!['target'],
        '{"at":{"x":30.0,"y":35.0}}',
        reason: 'the centre of [10, 20, 40, 30]',
      );
      // What was aimed at, in words, so the journal is not a list of numbers.
      expect(readJournal(handle).last.target, 'item 1 "Pay"');
    });

    test('reaches a control that has no words at all', () async {
      await observe();
      Map<String, String>? wire;
      core.debugAct = (handle, args) async {
        wire = args;
        return {
          'step': {
            'verb': 'tap',
            'settle': {'settled': true},
          },
          'lifecycle': 'resumed',
        };
      };

      await core.invoke('act', arguments: {'verb': 'tap', 'item': 2});
      expect(wire!['target'], '{"at":{"x":70.0,"y":30.0}}');
      expect(readJournal(handle).last.target, 'item 2');
    });

    test(
      'a number the screen does not have is refused with the count',
      () async {
        await observe();
        var result =
            (await core.invoke('act', arguments: {'verb': 'tap', 'item': 9}))!
                as RunActResult;

        expect(result.ok, isFalse);
        expect(result.error, contains('no item 9'));
        expect(result.error, contains('it had 2'));
      },
    );

    test('an item before anything was observed says so', () async {
      var result =
          (await core.invoke('act', arguments: {'verb': 'tap', 'item': 1}))!
              as RunActResult;

      expect(result.ok, isFalse);
      expect(result.error, contains('nothing has observed this app yet'));
    });
  });

  group('a screen that cannot be projected', () {
    /// The refusal the guest sends when a target matched twice, on a frame
    /// whose screen the host then fails to build.
    void refuses() {
      core.debugAct = (handle, args) async => {
        'error': '2 widgets match "Log In", and `tap` needs one.',
        'failure': 'multiple',
        'lifecycle': 'resumed',
        'texts': ['Log In', 'Log in'],
        'tree': {
          'root': {
            'id': '',
            'type': 'Column',
            'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
            'children': [
              {
                'id': '0',
                'type': 'Text',
                'description': 'Text("Log In")',
                'layout': {'x': 0, 'y': 0, 'width': 40, 'height': 20},
              },
            ],
          },
        },
        'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
      };
    }

    setUp(() => Screen.debugFailProjection = StateError('Too many elements'));
    tearDown(() => Screen.debugFailProjection = null);

    test('costs the screen and nothing else', () async {
      refuses();

      var result =
          (await core.invoke(
                'act',
                arguments: {'verb': 'tap', 'target': 'Log In'},
              ))!
              as RunActResult;

      // The refusal survives the projection that failed around it — which it
      // did not before: the `StateError` came out of the action instead, and
      // an agent was told `Bad state: Too many elements` about a target that
      // had been refused for a reason it could have acted on.
      expect(result.failure, 'multiple');
      expect(result.error, contains('2 widgets match'));
      expect(result.screen, isNull);
      expect(result.note, contains('the screen could not be projected'));
      expect(result.note, contains('Too many elements'));
      // Everything else came off the same frame and is unharmed.
      expect(result.texts, ['Log In', 'Log in']);
      expect(result.screenshotArtifact, isNotNull);

      // And the step is in the journal, which is where it was missing
      // entirely: an exception took the record with it.
      var entry = readJournal(handle).single;
      expect(entry.failure, 'multiple');
      expect(entry.screenshot, isNotNull);
    });

    test('`item:` says so rather than throwing', () async {
      refuses();
      await core.invoke('act', arguments: {'verb': 'observe'});

      var result =
          (await core.invoke('act', arguments: {'verb': 'tap', 'item': 1}))!
              as RunActResult;

      expect(result.ok, isFalse);
      expect(result.failure, 'notFound');
      expect(result.error, contains('the screen could not be projected'));
    });
  });

  group('the lens', () {
    void observes() {
      core.debugAct = (handle, args) async => {
        'step': {
          'verb': 'observe',
          'settle': {'settled': true},
        },
        'lifecycle': 'resumed',
        'texts': ['Pay'],
        'tree': {
          'root': {
            'id': '',
            'type': 'Column',
            'layout': {'x': 0, 'y': 0, 'width': 100, 'height': 100},
            'children': [
              {
                'id': '0',
                'type': 'Text',
                'description': 'Text("Pay")',
                'layout': {'x': 0, 'y': 0, 'width': 40, 'height': 20},
                'properties': {'size': '12.5', 'color': '#111111'},
              },
            ],
          },
        },
        'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
      };
    }

    Future<RunActResult> act([Map<String, Object?> extra = const {}]) async =>
        (await core.invoke('act', arguments: {'verb': 'observe', ...extra}))!
            as RunActResult;

    test('act is the default, and says so', () async {
      observes();
      var result = await act();
      expect(result.lens, 'act');
      expect(result.screen, isNotNull);
      expect(result.screenshotArtifact, isNull);
      expect(result.styles, isNull);
      expect(result.tree, isNull);
    });

    test(
      'design brings the picture and the styles, raw brings the tree',
      () async {
        observes();
        var design = await act({'lens': 'design'});
        expect(design.lens, 'design');
        expect(design.screenshotArtifact, isNotNull);
        expect(design.styles, isNotEmpty);
        expect(design.tree, isNull);

        var raw = await act({'lens': 'raw'});
        expect(raw.lens, 'raw');
        expect(raw.tree, isNotNull);
      },
    );

    test('a flag the caller named beats the lens', () async {
      observes();
      var result = await act({'lens': 'look', 'screenshot': false});
      expect(
        result.screenshotArtifact,
        isNull,
        reason: 'look wants a picture; this call said not to',
      );
    });

    test('a pin lasts, and every reply marks it as one', () async {
      observes();
      var set =
          (await core.invoke('lens', arguments: {'lens': 'design'}))!
              as RunLensResult;
      expect(set.lens, 'design');
      expect(set.pinned, isTrue);
      expect(set.was, 'act');

      var result = await act();
      expect(
        result.lens,
        'design (pinned)',
        reason: 'somebody else may have set it; the reply has to say so',
      );
      expect(result.styles, isNotEmpty);

      // Naming one for a call does not disturb the pin, and is not marked.
      expect((await act({'lens': 'act'})).lens, 'act');
      expect((await act()).lens, 'design (pinned)');

      var cleared =
          (await core.invoke('lens', arguments: {'lens': 'none'}))!
              as RunLensResult;
      expect(cleared.pinned, isFalse);
      expect(cleared.was, 'design');
      expect((await act()).lens, 'act');
    });

    test('reading the lens changes nothing and lists the choices', () async {
      var report = (await core.invoke('lens', arguments: {}))! as RunLensResult;
      expect(report.lens, 'act');
      expect(report.pinned, isFalse);
      expect(report.was, isNull, reason: 'nothing changed');
      expect(report.lenses.map((l) => l['lens']), [
        'act',
        'look',
        'design',
        'raw',
      ]);
    });

    test('an unknown lens is refused with the list', () async {
      observes();
      var result = await act({'lens': 'pretty'});
      expect(result.ok, isFalse);
      expect(result.error, contains('no lens "pretty"'));
      expect(result.error, contains('act, look, design, raw'));
    });
  });

  test('the picture shows itself when a step goes wrong', () async {
    core.debugAct = (handle, args) async => {
      'error': 'nothing matches "Nope", which `tap` needs.',
      'failure': 'notFound',
      'lifecycle': 'resumed',
      'texts': ['Pay'],
      'screenshot': {'base64': base64Encode(_tinyPng), 'width': 1},
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'tap', 'target': 'Nope'},
            ))!
            as RunActResult;

    expect(result.ok, isFalse);
    expect(
      result.screenshotArtifact,
      isNotNull,
      reason: 'nobody asked, but looking is the useful thing to do here',
    );
  });

  test('a refusal is not ok, and still observes', () async {
    core.debugAct = (handle, args) async => {
      'error': 'nothing matches "Nope", which `tap` needs.',
      'failure': 'notFound',
      'lifecycle': 'resumed',
      'texts': ['Pay'],
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'tap', 'target': 'Nope'},
            ))!
            as RunActResult;

    expect(result.ok, isFalse);
    expect(result.failure, 'notFound');
    expect(result.texts, ['Pay'], reason: 'a refusal still shows the screen');
    expect(readJournal(handle).single.failure, 'notFound');
  });

  test('a refusal teaches the native layer, but only where there is one', () async {
    core.debugAct = (handle, args) async => {
      'error': 'nothing matches "Allow"',
      'failure': 'notFound',
      'texts': <String>['Pay'],
    };

    // How an agent finds this layer at all: not from documentation it read
    // once, but at the moment it is looking for something the widget tree does
    // not have.
    core.debugNativeAvailable = true;
    var taught =
        (await core.invoke(
              'act',
              arguments: {'verb': 'tap', 'target': 'Allow'},
            ))!
            as RunActResult;
    expect(taught.error, contains('layer: native'));

    // And silence where the advice would fail: a device with no native driver
    // must not be told to try one.
    core.debugNativeAvailable = false;
    var quiet =
        (await core.invoke(
              'act',
              arguments: {'verb': 'tap', 'target': 'Allow'},
            ))!
            as RunActResult;
    expect(quiet.error, isNot(contains('layer: native')));
  });

  test('a native step journals as its own layer', () async {
    // The native path refuses without a device, which is the point: the
    // refusal is still a step, and the story records which tree it addressed.
    var result =
        (await core.invoke(
              'act',
              arguments: {
                'verb': 'observe',
                'layer': 'native',
                'device': 'macos',
              },
            ))!
            as RunActResult;

    expect(result.ok, isFalse);
    expect(result.layer, 'native');
    expect(result.error, contains('no driver'));
    var entry = readJournal(handle).single;
    expect(entry.layer, 'native');
    expect(entry.verb, 'observe');
  });

  test('observe and navigate funnel into act with the verb fixed', () async {
    var verbs = <String>[];
    core.debugAct = (handle, args) async {
      verbs.add(args['verb']!);
      return {'texts': <String>[]};
    };

    await core.invoke('observe');
    await core.invoke('navigate', arguments: {'route': 'shop/cart'});

    expect(verbs, ['observe', 'navigate']);
  });

  test('a guest-less app is named as such, not as a fault', () async {
    core.debugAct = (handle, args) async =>
        throw RPCError('callServiceExtension', -32601, 'Method not found');

    var result =
        (await core.invoke('act', arguments: {'verb': 'tap', 'target': 'Pay'}))!
            as RunActResult;

    expect(result.ok, isFalse);
    expect(result.error, contains('without the drive guest'));
    expect(readJournal(handle).single.error, contains('drive guest'));
  });

  test('human actions ride the reply, and journal ahead of the step', () async {
    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'observe',
        'settle': {'settled': true, 'elapsedMs': 50},
      },
      'human': [
        {'at': '2026-08-11T10:00:00.000Z', 'verb': 'tap', 'target': '"Pay"'},
        {
          'at': '2026-08-11T10:00:02.000Z',
          'verb': 'longPress',
          'target': "key 'cart'",
        },
      ],
      'texts': <String>[],
    };

    var result = (await core.invoke('observe'))! as RunActResult;

    expect(result.human, ['tap "Pay"', "longPress key 'cart'"]);

    var entries = readJournal(handle);
    expect(entries, hasLength(3));
    expect(entries[0].actor, 'human');
    expect(entries[0].verb, 'tap');
    expect(entries[0].target, '"Pay"');
    expect(entries[0].at, '2026-08-11T10:00:00.000Z');
    expect(entries[1].actor, 'human');
    expect(entries[1].verb, 'longPress');
    expect(entries[2].verb, 'observe', reason: 'the step closes the story');
    expect(entries[2].actor, 'agent');
  });

  test('what the poller collected is told to the next act, once', () async {
    // The poller wins the race for the guest's buffer almost every time — it
    // asks once a second — so without this an agent's `human` field would come
    // back empty and the facts would only be in the journal.
    core.debugCollectBeats(handle, [
      {'at': '2026-08-24T10:00:00.000Z', 'verb': 'tap', 'target': '"Previews"'},
    ]);
    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'observe',
        'settle': {'settled': true, 'elapsedMs': 5},
      },
      'human': [
        {'at': '2026-08-24T10:00:05.000Z', 'verb': 'tap', 'target': '"Assets"'},
      ],
      'texts': <String>[],
    };

    var first = (await core.invoke('observe'))! as RunActResult;
    expect(first.human, [
      'tap "Previews"',
      'tap "Assets"',
    ], reason: 'what the poller saw, then what this call took, in order');

    // Journaled once each: the poller wrote its own when it collected it, and
    // the act path must not write it a second time.
    var human = readJournal(handle).where((e) => e.actor == 'human').toList();
    expect(human.map((e) => e.target), ['"Previews"', '"Assets"']);

    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'observe',
        'settle': {'settled': true, 'elapsedMs': 5},
      },
      'texts': <String>[],
    };
    var second = (await core.invoke('observe'))! as RunActResult;
    expect(
      second.human,
      isNull,
      reason: 'told once — a second act must not re-report the same taps',
    );
  });

  test('a sibling worktree running the same device/entrypoint pair does not '
      'make selection ambiguous', () async {
    var sibling = Directory.systemTemp.createTempSync('fw-act-sibling-');
    addTearDown(() => sibling.deleteSync(recursive: true));
    RunHandle(
      worktree: sibling.path,
      worktreeName: 'sibling',
      device: 'macos',
      entrypoint: 'lib/main.dart',
      launcherPid: pid,
      startedAt: DateTime.now(),
    ).publish(runDir.path);
    core.debugAct = (handle, args) async => {'texts': <String>[]};

    var result = (await core.invoke('observe'))! as RunActResult;

    expect(result.ok, isTrue, reason: 'the sibling run is not a subject here');
    expect(result.worktree, '~');
  });

  test('a hidden window is said out loud', () async {
    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'observe',
        'settle': {'settled': true, 'framesEnabled': false, 'elapsedMs': 50},
      },
      'texts': <String>[],
    };

    var result = (await core.invoke('observe'))! as RunActResult;

    expect(result.framesEnabled, isFalse);
    expect(result.note, contains('hidden or occluded'));
  });

  group('a step that drew no frame', () {
    Future<RunActResult> tapWith(
      Map<String, Object?> settle, {
      String? lifecycle,
    }) async {
      core.debugAct = (handle, args) async => {
        'step': {'verb': 'tap', 'target': '"Pay"', 'settle': settle},
        'lifecycle': ?lifecycle,
        'texts': ['Pay'],
      };
      return (await core.invoke(
            'act',
            arguments: {'verb': 'tap', 'target': 'Pay'},
          ))!
          as RunActResult;
    }

    /// The case a consumer spent several steps diagnosing: an iOS simulator
    /// booted with the Simulator app closed, where the app is `inactive`,
    /// frames stay enabled and none is ever drawn.
    test('on an inactive app, says so and names the way out', () async {
      core.debugNativeAvailable = true;
      var result = await tapWith({
        'settled': false,
        'frames': 0,
        'unansweredFrames': 3,
        'framesEnabled': true,
        'elapsedMs': 800,
      }, lifecycle: 'inactive');

      expect(result.ok, isTrue, reason: 'the tap was delivered');
      expect(result.frames, 0);
      expect(result.note, contains('drew no frame'));
      expect(result.note, contains('`inactive`'));
      expect(result.note, contains('Simulator app is not running'));
      expect(result.note, contains('act {verb: foreground, layer: native}'));
    });

    test('without a native driver, the way out is said in words', () async {
      var result = await tapWith({
        'settled': false,
        'frames': 0,
        'unansweredFrames': 3,
        'framesEnabled': true,
        'elapsedMs': 800,
      }, lifecycle: 'inactive');

      expect(result.note, contains('Open that device in the Simulator app'));
      expect(result.note, isNot(contains('layer: native')));
    });

    test(
      'replaces the hidden-window note rather than contradicting it',
      () async {
        var result = await tapWith({
          'settled': false,
          'frames': 0,
          'unansweredFrames': 2,
          'forcedFrames': 2,
          'framesEnabled': false,
          'elapsedMs': 800,
        }, lifecycle: 'paused');

        expect(result.note, contains('drew no frame'));
        expect(result.note, contains('`paused`'));
        expect(result.note, isNot(contains('every frame this step saw')));
      },
    );

    test('is silent when a frame was drawn, even after a missed one', () async {
      var result = await tapWith({
        'settled': true,
        'frames': 1,
        'unansweredFrames': 1,
        'framesEnabled': true,
        'elapsedMs': 400,
      }, lifecycle: 'resumed');

      expect(result.note, isNull);
    });

    test('is silent when nothing needed a frame', () async {
      var result = await tapWith({
        'settled': true,
        'frames': 0,
        'framesEnabled': true,
        'elapsedMs': 20,
      }, lifecycle: 'inactive');

      expect(result.note, isNull);
    });
  });

  /// The hold is the whole reason `hover` is not just a tap with a different
  /// event, and it is spent inside the guest — so the host's only job is to
  /// let the number through. A key missing from the wire allowlist is a
  /// parameter that is documented, accepted and silently dropped.
  test('hover carries its hold across the wire', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'hover',
          'target': '"Save"',
          'settle': {'settled': true, 'elapsedMs': 40},
        },
        'texts': ['Save', 'Saves the document'],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'hover', 'target': 'Save', 'holdMs': 250},
            ))!
            as RunActResult;

    expect(wire!['verb'], 'hover');
    expect(wire!['holdMs'], '250');
    expect(result.ok, isTrue);
    expect(
      result.texts,
      contains('Saves the document'),
      reason: 'a tooltip is an OverlayEntry, so it rides the texts',
    );
    expect(readJournal(handle).single.verb, 'hover');
  });

  /// `unhover` takes no target, and the step names what it released — so the
  /// journal line reads `unhover "Save"` rather than a bare verb, and a
  /// reviewer can see which hover ended.
  test('unhover journals what the guest released', () async {
    core.debugAct = (handle, args) async => {
      'step': {
        'verb': 'unhover',
        'target': '"Save"',
        'settle': {'settled': true, 'elapsedMs': 30},
      },
      'texts': ['Save'],
    };

    var result =
        (await core.invoke('act', arguments: {'verb': 'unhover'}))!
            as RunActResult;

    expect(result.ok, isTrue);
    expect(result.verb, 'unhover');
    expect(result.target, '"Save"');
    expect(readJournal(handle).single.target, '"Save"');
  });

  /// `keys` is the second parameter the guest cannot invent for itself. Same
  /// hole as `holdMs`: declared, accepted, and dropped on the floor unless the
  /// wire allowlist names it too.
  test('key carries its chord across the wire', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'key',
          'target': 'meta+k',
          'settle': {'settled': true, 'elapsedMs': 40},
        },
        'texts': ['Search plugins, entries and actions…'],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'key', 'keys': 'meta+k'},
            ))!
            as RunActResult;

    expect(wire!['verb'], 'key');
    expect(wire!['keys'], 'meta+k');
    expect(result.ok, isTrue);
    expect(readJournal(handle).single.target, 'meta+k');
  });

  /// `gapMs` is the third parameter that only reaches the guest if the wire
  /// allowlist names it — and the one whose absence is hardest to see, because
  /// a doubleTap with no gap still returns ok and simply is not a double tap.
  test('doubleTap carries its gap across the wire', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'doubleTap',
          'target': '"Handle"',
          'settle': {'settled': true, 'elapsedMs': 90},
        },
        'texts': <String>[],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {
                'verb': 'doubleTap',
                'target': 'Handle',
                'gapMs': 120,
              },
            ))!
            as RunActResult;

    expect(wire!['verb'], 'doubleTap');
    expect(wire!['gapMs'], '120');
    expect(result.ok, isTrue);
    expect(readJournal(handle).single.verb, 'doubleTap');
  });

  test('secondaryTap reaches the guest as its own verb', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'secondaryTap',
          'target': '"Row"',
          'settle': {'settled': true, 'elapsedMs': 40},
        },
        'texts': ['Copy', 'Paste'],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'secondaryTap', 'target': 'Row'},
            ))!
            as RunActResult;

    expect(wire!['verb'], 'secondaryTap');
    expect(result.ok, isTrue);
    expect(result.verb, 'secondaryTap');
    expect(readJournal(handle).single.target, '"Row"');
  });

  /// `scroll` reuses `dx`/`dy`, which `drag` already put on the wire — so this
  /// is about the verb reaching the guest with its delta intact, and about the
  /// journal naming the pane rather than the numbers.
  test('scroll carries its delta and journals its target', () async {
    Map<String, String>? wire;
    core.debugAct = (handle, args) async {
      wire = args;
      return {
        'step': {
          'verb': 'scroll',
          'target': '"Rules"',
          'settle': {'settled': true, 'elapsedMs': 60},
        },
        'texts': <String>[],
      };
    };

    var result =
        (await core.invoke(
              'act',
              arguments: {'verb': 'scroll', 'target': 'Rules', 'dy': 600},
            ))!
            as RunActResult;

    expect(wire!['verb'], 'scroll');
    expect(wire!['dy'], '600');
    expect(result.ok, isTrue);
    expect(readJournal(handle).single.target, '"Rules"');
  });
}

/// A 1×1 transparent PNG.
final _tinyPng = Uint8List.fromList([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, //
  0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, //
  120, 156, 99, 250, 207, 192, 240, 31, 0, 5, 5, 2, 0, 95, 132, 84, 96, 0, //
  0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);
