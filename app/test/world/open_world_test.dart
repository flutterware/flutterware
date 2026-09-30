import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/server/attach_session.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
import 'package:flutterware_app/src/plugins/native/worlds_results.dart';
import 'package:flutterware_app/src/run/entrypoint_knobs.dart';
import 'package:flutterware_app/src/utils/parameter_knobs.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/world_files.dart';
import 'package:flutterware_app/src/world/world_script.dart';
import 'package:path/path.dart' as p;

void main() {
  late String emptyRunDir;
  setUp(() async {
    var dir = await Directory.systemTemp.createTemp('fw_world_run');
    addTearDown(() => dir.delete(recursive: true));
    emptyRunDir = dir.path;
  });

  group('declaredWorlds', () {
    late Directory package;

    setUp(() {
      package = Directory.systemTemp.createTempSync('worlds_declared');
      Directory(p.join(package.path, 'tool', 'worlds'))
          .createSync(recursive: true);
      File(p.join(package.path, 'tool', 'worlds', 'pickup_order.dart'))
          .writeAsStringSync('void main(List<String> args) {}');
    });

    tearDown(() => package.deleteSync(recursive: true));

    test('lists what the config declares, named by it or by the file', () {
      var worlds = declaredWorlds(
        config: {
          'path': 'server',
          'worlds': [
            {
              'path': 'tool/worlds/pickup_order.dart',
              'description': 'A barista and a regular.',
            },
            {'path': 'tool/worlds/team_invite.dart', 'name': 'Invite'},
          ],
        },
        packageRoot: package.path,
      );
      var [pickup, invite] = worlds;
      expect(pickup.id, 'pickup_order');
      expect(pickup.name, 'Pickup order');
      expect(pickup.description, 'A barista and a regular.');
      expect(pickup.problem, isNull);
      expect(invite.name, 'Invite');
      expect(
        invite.problem,
        'server/tool/worlds/team_invite.dart does not exist.',
      );
    });

    test('off macOS each world says why it cannot open', () {
      var [pickup, missing] = declaredWorlds(
        config: {
          'path': 'server',
          'worlds': [
            {'path': 'tool/worlds/pickup_order.dart'},
            {'path': 'tool/worlds/team_invite.dart'},
          ],
        },
        packageRoot: package.path,
        unsupported: worldsUnsupported(macOS: false),
      );
      expect(pickup.problem, startsWith('Worlds open on macOS only'));
      // The more specific reason wins.
      expect(missing.problem, endsWith('does not exist.'));
      expect(worldsUnsupported(macOS: true), isNull);
    });

    test('a package that declares none has none', () {
      expect(
        declaredWorlds(config: {'path': 'x'}, packageRoot: package.path),
        isEmpty,
      );
    });
  });

  group('knobsForMain', () {
    var scan = EntrypointKnobs(
      knobs: [
        for (var (name, kind) in [
          ('server', KnobKind.string),
          ('port', KnobKind.integer),
          ('staff', KnobKind.boolean),
          ('scale', KnobKind.number),
          ('backend', KnobKind.picker),
        ])
          ParameterKnob(
            KnobDescriptor(
              name: name,
              kind: kind,
              value: null,
              defaultValue: null,
            ),
          ),
      ],
      undrawable: [(name: 'timeout', reason: 'is a Duration')],
    );

    test('passes values in the types main declares', () {
      expect(
        knobsForMain('Ana', 'Lab', {
          'server': 8090,
          'port': '8090',
          'staff': 'true',
          'scale': 2,
        }, scan),
        {'server': '8090', 'port': 8090, 'staff': true, 'scale': 2.0},
      );
    });

    test('refuses a knob main does not take, and says what it takes', () {
      expect(
        () => knobsForMain('Ana', 'Lab', {'sesion': 'x'}, scan),
        throwsA(
          isA<WorldRefusal>().having(
            (e) => e.message,
            'message',
            allOf(contains('sesion'), contains('server, port, staff')),
          ),
        ),
      );
    });

    test('refuses a value of the wrong type, an enum, and a Duration', () {
      for (var knobs in [
        {'port': 'eighty'},
        {'backend': 'staging'},
        {'timeout': 5},
      ]) {
        expect(
          () => knobsForMain('Ana', 'Lab', knobs, scan),
          throwsA(isA<WorldRefusal>()),
          reason: '$knobs',
        );
      }
    });

    test('refuses a main with a required parameter', () {
      expect(
        () => knobsForMain(
          'Ana',
          'Lab',
          const {},
          const EntrypointKnobs(required: ['session']),
        ),
        throwsA(isA<WorldRefusal>()),
      );
    });
  });

  test("`dart run`'s notes about itself leave the script's log", () {
    expect(withoutToolNoise('Running build hooks...'), isNull);
    // No newline after it: it arrives glued to the script's first line.
    expect(
      withoutToolNoise('Running build hooks...Running build hooks...Serving'),
      'Serving',
    );
    expect(withoutToolNoise(''), '');
  });

  test('opens a script in its own process, restarts it with new people, and '
      'closes it', () async {
    var worktree = p.dirname(Directory.current.path);
    var world = OpenWorld(
      file: const WorldFile(
        package: 'app',
        path: 'test/world/fixtures/headless_world.dart',
        name: 'Headless',
      ),
      worktree: worktree,
      // `flutter test` names it; this suite runs under nothing else.
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      appRoot: Directory.current.path,
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here has an app'),
      // Not the machine's: the servers running under this worktree are
      // somebody's, and a test attaching to them is no business of theirs.
      runDir: () => emptyRunDir,
    );
    await world.open();
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    var first = world.id;
    expect(world.people.keys, ['Ana']);
    expect(world.people['Ana']!.phase, PersonPhase.headless);
    expect(world.people['Ana']!.spec.email, 'ana.$first@example.com');
    expect(world.knobs['mood']!.options, ['calm', 'busy']);
    // Each line stamped with the seconds since the opening started.
    expect(world.log, contains(matches(r'^\d+\.\ds  Mood is calm$')));

    var wave = await world.invoke('Wave');
    expect(wave.running, isFalse);
    expect(wave.step, 'world.1');
    expect(wave.progress, 'Ana waves, as ${wave.step}');
    expect(() => world.invoke('Dance'), throwsA(isA<WorldRefusal>()));
    // Nothing was sent, and the refusal says so rather than failing blind.
    await expectLater(
      world.deliver('lab/1'),
      throwsA(
        isA<WorldRefusal>().having(
          (refusal) => refusal.message,
          'message',
          contains('No server has sent one yet'),
        ),
      ),
    );

    await world.restart({'mood': 'busy'});
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    expect(world.log, contains(endsWith('  Restart 1')));
    expect(world.id, isNot(first));
    expect(world.people.keys, ['Ana', 'Leo']);
    expect(world.log, contains(endsWith('  closing $first')));
    // The trace started afresh; so do the world's own steps.
    expect((await world.invoke('Wave')).step, 'world.1');

    await world.close();
    expect(world.phase, WorldPhase.closed);
    expect(world.people, isEmpty);
    // The script's resident compiler went with it.
    expect(
      Directory(flutterwareRunDir()).listSync().map((e) => p.basename(e.path)),
      isNot(contains(startsWith('world-compiler-$pid-'))),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('knows its people without an app by their user id, phone and address, '
      'and knows the new ones after a restart', () async {
    var world = OpenWorld(
      file: const WorldFile(
        package: 'app',
        path: 'test/world/fixtures/headless_world.dart',
        name: 'Headless',
      ),
      worktree: p.dirname(Directory.current.path),
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      appRoot: Directory.current.path,
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here has an app'),
      runDir: () => emptyRunDir,
    );
    addTearDown(world.close);
    var sent = 0;
    void lab(String channel, Map<String, Object?> payload) =>
        world.tracer!.trace.addServerEvent(
          'lab',
          InspectorEvent(
            channel: channel,
            id: sent++,
            time: DateTime.now(),
            payload: payload,
            isReplay: false,
          ),
        );
    List<String> traced(String step) =>
        WorldTraceResult.of(world.tracer!.trace.steps(step: step))
            .steps
            .single
            .then;

    await world.open();
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    expect(world.people['Ana']!.phase, PersonPhase.headless);

    // What the world does as Ana is Ana's, by the name the script gave.
    var wave = await world.invoke('Wave');
    lab('identify', {'user': 'u1', 'step': wave.step});
    lab('write', {
      'table': 'orders',
      'key': 'o1',
      'op': 'insert',
      'customer': 'u1',
      'step': wave.step,
    });
    expect(traced(wave.step), [
      matches(r'^\+\d+ ms  lab  knows Ana as u1$'),
      matches(r'^\+\d+ ms  lab  wrote orders/o1 \(insert · customer Ana\)$'),
    ]);
    lab('mail', {'to': 'ana.${world.id}@example.com', 'subject': 'Receipt'});
    expect(world.tracer!.trace.outbox().single.person, 'Ana');

    await world.restart({'mood': 'busy'});
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    expect(world.people['Leo']!.phase, PersonPhase.headless);
    lab('sms', {'to': '+447700900001', 'body': 'Your code is 4821'});
    lab('mail', {'to': 'ana.${world.id}@example.com', 'subject': 'Receipt'});
    expect(
      [for (var message in world.tracer!.trace.outbox()) message.person],
      ['Ana', 'Leo'],
    );
    expect(world.tracer!.trace.personOfUser('u1'), 'Ana');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('reloads its script with the same people: what an action calls runs '
      'the new code, and a compile error changes nothing', () async {
    var script = File('test/world/fixtures/reloading_world.dart');
    var original = script.readAsStringSync();
    addTearDown(() => script.writeAsStringSync(original));
    var world = OpenWorld(
      file: const WorldFile(
        package: 'app',
        path: 'test/world/fixtures/reloading_world.dart',
        name: 'Reloading',
      ),
      worktree: p.dirname(Directory.current.path),
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      appRoot: Directory.current.path,
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here has an app'),
      runDir: () => emptyRunDir,
    );
    addTearDown(world.close);
    await world.open();
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    var id = world.id;
    // The VM's banner about its service is not the script's to say.
    expect(world.log, isNot(contains(contains('VM service'))));

    Future<String?> said(String action) async =>
        (await world.invoke(action)).progress;
    expect(await said('Greet'), 'hello, v1');
    expect(await said('Route'), '/health, reloadable, v1');

    script.writeAsStringSync(original.replaceAll('v1', 'v2'));
    var reload = await world.reload();
    expect(reload.apps, isEmpty);
    // A moment in the trace, which says what came after it ran.
    expect(reload.step, 'reload.1');
    expect(world.id, id);
    expect(await said('Greet'), 'hello, v2');
    // A router's handlers are closures made when it was built: served
    // through `reloadable` they are built again, and without it they keep
    // their old bodies.
    expect(await said('Route'), '/health, reloadable, v2');
    expect(await said('Route once'), '/health, built once, v1');
    expect(world.log.last, contains('Reloaded in'));
    // The time, split: the code, then what rebuilt on it.
    expect(reload.script, greaterThan(Duration.zero));
    expect(
      reload.elapsed,
      greaterThanOrEqualTo(reload.script + reload.reassemble),
    );
    expect(world.log.last, contains('its onReassemble in'));

    // Two at once — the Reload button and `worlds reload`, a save and a
    // click — reload one after the other, where the VM would refuse one.
    script.writeAsStringSync(original.replaceAll('v1', 'v4'));
    int reloads() => world.log.where((l) => l.contains('Reloaded in')).length;
    var before = reloads();
    var both = [world.reload(), world.reload()];
    expect(world.reloading, isTrue);
    await Future.wait(both);
    expect(world.reloading, isFalse);
    expect(reloads(), before + 2);
    expect(await said('Greet'), 'hello, v4');
    script.writeAsStringSync(original.replaceAll('v1', 'v2'));
    await world.reload();

    script.writeAsStringSync(
      original.replaceAll('v1', 'v2').replaceFirst("'hello, v2';", "'v3'"),
    );
    await expectLater(
      world.reload(),
      throwsA(
        isA<WorldRefusal>().having(
          (refusal) => refusal.message,
          'message',
          allOf(contains('did not compile'), contains('reloading_world.dart')),
        ),
      ),
    );
    expect(await said('Greet'), 'hello, v2');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a script that dies on the resident compiler is started once more, '
      'with a fresh compiler', () async {
    var marker = File('build/flaky_world.marker');
    if (marker.existsSync()) marker.deleteSync();
    addTearDown(() {
      if (marker.existsSync()) marker.deleteSync();
    });
    var world = OpenWorld(
      file: const WorldFile(
        package: 'app',
        path: 'test/world/fixtures/flaky_world.dart',
        name: 'Flaky',
      ),
      worktree: p.dirname(Directory.current.path),
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      appRoot: Directory.current.path,
      entrypoints: const [],
      guests: (_) => throw StateError('nobody here has an app'),
      // Not the machine's: the servers running under this worktree are
      // somebody's, and a test attaching to them is no business of theirs.
      runDir: () => emptyRunDir,
    );
    await world.open();
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    expect(
      world.log,
      contains(
        endsWith('The resident compiler was gone; starting a fresh one'),
      ),
    );
    expect(world.people.keys, ['Ana']);
    await world.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
