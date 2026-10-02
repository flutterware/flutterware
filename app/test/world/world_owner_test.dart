import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/worlds_results.dart';
import 'package:flutterware_app/src/world/world_owner.dart';

/// A world belongs to the process that opened it; these are how every other
/// process finds that one and asks it.
void main() {
  late Directory runDir;

  setUp(() => runDir = Directory.systemTemp.createTempSync('world_owner'));
  tearDown(() => runDir.deleteSync(recursive: true));

  /// Where an owner listens: a file is all [WorldHandle.read] looks for.
  String socket(String name) =>
      (File('${runDir.path}/$name')..createSync()).path;

  WorldHandle handle({required int owner}) => WorldHandle(
    worktree: '/work/shop',
    world: 'pickup_order',
    name: 'Pickup order',
    pid: owner,
    socket: socket('world-owner.sock'),
  );

  test('a live owner is found by its worktree', () {
    handle(owner: pid).write(directory: runDir.path);
    var found = WorldHandle.read('/work/shop', directory: runDir.path)!;
    expect(found.name, 'Pickup order');
    expect(found.pid, pid);
    expect(WorldHandle.read('/work/other', directory: runDir.path), isNull);

    handle(owner: pid).delete(directory: runDir.path);
    expect(WorldHandle.read('/work/shop', directory: runDir.path), isNull);
  });

  test('an owner whose socket is gone is forgotten: nobody can ask it', () {
    var owner = handle(owner: pid)..write(directory: runDir.path);
    File(owner.socket).deleteSync();
    expect(WorldHandle.read('/work/shop', directory: runDir.path), isNull);
    expect(
      File(WorldHandle.pathFor('/work/shop', directory: runDir.path))
          .existsSync(),
      isFalse,
    );
  });

  test('an owner that died without closing is forgotten', () async {
    var gone = await Process.start('true', const []);
    await gone.exitCode;
    handle(owner: gone.pid).write(directory: runDir.path);

    expect(WorldHandle.read('/work/shop', directory: runDir.path), isNull);
    expect(
      File(WorldHandle.pathFor('/work/shop', directory: runDir.path))
          .existsSync(),
      isFalse,
    );
  });

  test(
    "the owner answers in its result's words, and refuses in its own",
    () async {
      var server = await WorldOwnerServer.start((action, arguments) async {
        if (action == 'close') throw StateError('Already closing.');
        return {'asked': action, 'with': arguments};
      });
      addTearDown(server.close);

      expect(
        await askWorldOwner(
          server.socket,
          'invoke',
          arguments: {'action': 'Wave'},
        ),
        {
          'asked': 'invoke',
          'with': {'action': 'Wave'},
        },
      );
      expect(
        () => askWorldOwner(server.socket, 'close'),
        throwsA(
          isA<WorldOwnerRefusal>().having(
            (e) => e.message,
            'message',
            contains('Already closing.'),
          ),
        ),
      );
    },
  );

  test('an owner that went says so', () async {
    var server = await WorldOwnerServer.start((_, _) async => const {});
    var socket = server.socket;
    await server.close();
    expect(
      () => askWorldOwner(socket, 'status'),
      throwsA(isA<WorldOwnerGone>()),
    );
  });

  test("a studio's door is found by its worktree while the studio lives, "
      'and forgotten once it does not', () async {
    WorldDoor door({required int studio}) => WorldDoor(
      worktree: '/work/shop',
      pid: studio,
      socket: socket('world-door.sock'),
    );
    door(studio: pid).write(directory: runDir.path);
    expect(WorldDoor.read('/work/shop', directory: runDir.path)!.pid, pid);
    expect(WorldDoor.read('/work/other', directory: runDir.path), isNull);
    // Its own file, beside the world's handle rather than in its place.
    expect(WorldHandle.read('/work/shop', directory: runDir.path), isNull);
    door(studio: pid).delete(directory: runDir.path);
    expect(WorldDoor.read('/work/shop', directory: runDir.path), isNull);

    var gone = await Process.start('true', const []);
    await gone.exitCode;
    door(studio: gone.pid).write(directory: runDir.path);
    expect(WorldDoor.read('/work/shop', directory: runDir.path), isNull);
    expect(
      File(WorldDoor.pathFor('/work/shop', directory: runDir.path))
          .existsSync(),
      isFalse,
    );
  });

  test('a state read back is the state sent', () {
    const sent = WorldStateResult(
      world: 'pickup_order',
      name: 'Pickup order',
      phase: 'open',
      id: 'k3f9x2',
      people: [
        WorldPersonEntry(
          name: 'Ana',
          phase: 'running',
          device: 'studio-ana',
          email: 'ana.k3f9x2@example.com',
          knobs: {'session': 'abc'},
          unanswered: ['com.example.scale (connect)'],
        ),
      ],
      actions: [WorldActionEntry('Wave', description: 'Ana waves')],
      knobs: [
        WorldKnobEntry(
          'Leo',
          'signed out',
          options: ['signed out', 'signed in'],
        ),
      ],
      log: ['0.0s  Starting'],
    );
    expect(WorldStateResult.fromJson(sent.toJson()).toJson(), sent.toJson());

    const ran = WorldActionResult(
      action: 'Wave',
      run: 3,
      running: false,
      progress: 'Ana waves',
    );
    expect(WorldActionResult.fromJson(ran.toJson()).toJson(), ran.toJson());
  });
}
