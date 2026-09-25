import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
import 'package:flutterware_app/src/run/entrypoint_knobs.dart';
import 'package:flutterware_app/src/utils/parameter_knobs.dart';
import 'package:flutterware_app/src/world/open_world.dart';
import 'package:flutterware_app/src/world/world_files.dart';
import 'package:path/path.dart' as p;

void main() {
  group('scanWorlds', () {
    late Directory package;

    setUp(() {
      package = Directory.systemTemp.createTempSync('worlds_scan');
      Directory(p.join(package.path, 'worlds', 'src'))
          .createSync(recursive: true);
    });

    tearDown(() => package.deleteSync(recursive: true));

    test('finds the files that call World.run, named from the file', () {
      File(p.join(package.path, 'worlds', 'pickup_order.dart'))
          .writeAsStringSync('''
import 'package:flutterware/world.dart';

/// A barista and a regular.
///
/// Leo signs up himself.
void main(List<String> args) => World.run(args, (w) {});
''');
      File(p.join(package.path, 'worlds', 'helpers.dart'))
          .writeAsStringSync('int twice(int x) => 2 * x;');
      File(p.join(package.path, 'worlds', 'src', 'nested.dart'))
          .writeAsStringSync('void main() => World.run([], (w) {});');

      var [world] = scanWorlds(
        package: 'server',
        packageRoot: package.path,
        directory: 'worlds',
      );
      expect(world.id, 'pickup_order');
      expect(world.name, 'Pickup order');
      expect(world.path, 'worlds/pickup_order.dart');
      expect(
        world.description,
        'A barista and a regular.\n\nLeo signs up himself.',
      );
    });

    test('a package with no worlds folder has no worlds', () {
      expect(
        scanWorlds(package: 'x', packageRoot: package.path, directory: 'nope'),
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
    );
    await world.open();
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    var first = world.id;
    expect(world.people.keys, ['Ana']);
    expect(world.people['Ana']!.phase, PersonPhase.headless);
    expect(world.people['Ana']!.spec.email, 'ana.$first@example.com');
    expect(world.knobs['mood']!.options, ['calm', 'busy']);
    expect(world.log, contains('Mood is calm'));

    var wave = await world.invoke('Wave');
    expect(wave.running, isFalse);
    expect(wave.progress, 'Ana waves');
    expect(() => world.invoke('Dance'), throwsA(isA<WorldRefusal>()));

    await world.restart({'mood': 'busy'});
    expect(world.phase, WorldPhase.open, reason: world.log.join('\n'));
    expect(world.id, isNot(first));
    expect(world.people.keys, ['Ana', 'Leo']);
    expect(world.log, contains('closing $first'));

    await world.close();
    expect(world.phase, WorldPhase.closed);
    expect(world.people, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
