import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/worlds_core.dart';
import 'package:flutterware_app/src/plugins/native/worlds_results.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/world/open_world.dart' show WorldRefusal;
import 'package:flutterware_app/src/world/world_owner.dart';
import 'package:path/path.dart' as p;

/// Where a world opens when more than one process could own it: the studio,
/// where its people's apps are seen, over `fw` and the MCP server.
void main() {
  late Directory root;
  late WorldsCore core;
  late Process studio;

  /// The core as a surface has it: [mcp] for the MCP server's, whose session
  /// lasts one call.
  WorldsCore coreFor({bool mcp = false, List<String> needs = const []}) {
    var worktree = Worktree(path: root.path);
    return WorldsCore(
      PluginHost(
        id: worldsPluginId,
        label: 'Worlds',
        worktree: worktree,
        workspace: Workspace(
          root: worktree.path,
          declared: [Pkg('.')],
          discovered: const ['.'],
          appContext: AppContext(logger: LogClient.print(), mcp: mcp),
          flutterSdk: FlutterSdkPath('/tmp/flutter'),
        ),
        config: {
          'packages': [
            {
              'path': '.',
              'worlds': [
                {
                  'path': 'tool/worlds/lab.dart',
                  if (needs.isNotEmpty) 'needs': needs,
                },
              ],
            },
          ],
        },
      ),
    )..unsupported = null;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('worlds_core');
    File(p.join(root.path, 'tool', 'worlds', 'lab.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main(List<String> args) {}');
    core = coreFor();
    // Another process, alive for as long as the test: the studio, as far as
    // the files say.
    studio = await Process.start('sleep', const ['60']);
  });

  tearDown(() {
    core.dispose();
    studio.kill();
    WorldDoor.read(root.path)?.delete();
    WorldHandle.read(root.path)?.delete();
    for (var path in [
      WorldDoor.pathFor(root.path),
      WorldHandle.pathFor(root.path),
    ]) {
      if (File(path).existsSync()) File(path).deleteSync();
    }
    root.deleteSync(recursive: true);
  });

  const lab = WorldStateResult(world: 'lab', name: 'Lab', phase: 'open');

  test('an opening asked here is sent to the studio, which opens it live and '
      'owns it', () async {
    var asked = <Map<String, Object?>>[];
    var door = await WorldOwnerServer.start((action, arguments) async {
      asked.add({'action': action, ...arguments});
      return lab.toJson();
    });
    addTearDown(door.close);
    WorldDoor(
      worktree: root.path,
      pid: studio.pid,
      socket: door.socket,
    ).write();

    var opened =
        (await core.invoke(
              'open',
              arguments: {'world': 'lab', 'knobs': 'mood=busy'},
            ))!
            as WorldStateResult;
    expect(opened.phase, 'open');
    expect(opened.note, startsWith('Opened in the studio (pid ${studio.pid})'));
    expect(asked, [
      {'action': 'open', 'world': 'lab', 'knobs': 'mood=busy', 'from': pid},
    ]);
    // Nothing of it lives here.
    expect(core.open, isNull);
  });

  group('a world that needs dev stack services', () {
    setUp(() {
      core.dispose();
      core = coreFor(needs: ['server']);
    });

    test('lists what it needs', () async {
      var listed = (await core.invoke('list'))! as WorldListResult;
      expect(listed.toJson()['worlds'], [
        {
          'id': 'lab',
          'name': 'Lab',
          'package': '.',
          'path': 'tool/worlds/lab.dart',
          'needs': ['server'],
        },
      ]);
    });

    test('is refused before it starts in a project with no dev stack', () async {
      await expectLater(
        core.openWorld('lab'),
        throwsA(
          isA<WorldRefusal>().having(
            (e) => e.message,
            'message',
            'Lab needs server, but this project declares no dev stack. '
                'Declare them with DevStack in tool/flutterware.dart, or take '
                '`needs:` off the world.',
          ),
        ),
      );
      expect(core.open, isNull);
    });
  });

  group('over MCP', () {
    setUp(() {
      core.dispose();
      core = coreFor(mcp: true);
    });

    test(
      'a world nothing would keep open is refused before it starts',
      () async {
        await expectLater(
          core.invoke('open', arguments: {'world': 'lab'}),
          throwsA(
            isA<WorldRefusal>().having(
              (refusal) => refusal.message,
              'message',
              allOf(
                startsWith('No studio has this checkout open'),
                contains('--world=lab --hold=true'),
              ),
            ),
          ),
        );
        expect(core.open, isNull);
        expect(WorldHandle.read(root.path), isNull);
      },
    );

    test('hold is refused: it would keep the call waiting', () async {
      await expectLater(
        core.invoke('open', arguments: {'world': 'lab', 'hold': true}),
        throwsA(
          isA<WorldRefusal>().having(
            (refusal) => refusal.message,
            'message',
            startsWith('`hold` is for a terminal.'),
          ),
        ),
      );
    });

    test('the studio still opens it', () async {
      var door = await WorldOwnerServer.start((_, _) async => lab.toJson());
      addTearDown(door.close);
      WorldDoor(
        worktree: root.path,
        pid: studio.pid,
        socket: door.socket,
      ).write();
      var opened =
          (await core.invoke('open', arguments: {'world': 'lab'}))!
              as WorldStateResult;
      expect(opened.note, startsWith('Opened in the studio'));
    });
  });

  test("the studio's refusal is said in its words", () async {
    var door = await WorldOwnerServer.start(
      (_, _) async => throw WorldRefusal('No world is called "dance".'),
    );
    addTearDown(door.close);
    WorldDoor(
      worktree: root.path,
      pid: studio.pid,
      socket: door.socket,
    ).write();
    await expectLater(
      core.invoke('open', arguments: {'world': 'dance'}),
      throwsA(
        isA<WorldRefusal>().having(
          (refusal) => refusal.message,
          'message',
          'No world is called "dance".',
        ),
      ),
    );
  });

  test('a world open already, in another process, is the one opened', () async {
    var owner = await WorldOwnerServer.start((action, _) async {
      expect(action, 'status');
      return lab.toJson();
    });
    addTearDown(owner.close);
    WorldHandle(
      worktree: root.path,
      world: 'lab',
      name: 'Lab',
      pid: studio.pid,
      socket: owner.socket,
    ).write();
    var opened =
        (await core.invoke('open', arguments: {'world': 'lab'}))!
            as WorldStateResult;
    expect(opened.note, contains('is open in another process'));
  });

  test('the studio leaves its door for as long as it has the worktree, and '
      'takes openings there and nothing else', () async {
    await core.takeOpenings();
    var door = WorldDoor.read(root.path)!;
    expect(door.pid, pid);
    // Its own door is no other process's.
    expect(core.openingElsewhere(), isNull);
    await expectLater(
      askWorldOwner(door.socket, 'close'),
      throwsA(
        isA<WorldOwnerRefusal>().having(
          (refusal) => refusal.message,
          'message',
          contains('not "close"'),
        ),
      ),
    );
    core.dispose();
    expect(WorldDoor.read(root.path), isNull);
    // Disposed twice by tearDown: once here is what is under test.
    core = WorldsCore(core.host);
  });
}
