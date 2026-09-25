import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/constants.dart';
import 'package:flutterware_app/src/plugins/native/run_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/session/cli.dart';
import 'package:flutterware_app/src/session/mcp_server.dart';
import 'package:flutterware_app/src/shell/repo_layout.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';

/// What `tool/flutterware.dart` declares, in declared order.
///
/// One list, read by both tests that care: one checks the ids a client gets,
/// the other that a build with no cores still reports every one of them. Two
/// literals would mean the second silently stops covering the plugin the first
/// just gained.
const _declaredPlugins = [
  'flutterware.dependencies',
  'flutterware.assets',
  'flutterware.render',
  'flutterware.previews',
  'flutterware.scene',
  'flutterware.splash',
  'flutterware.launcher_icon',
  'flutterware.store',
  'flutterware.server',
  'flutterware.lints',
  'flutterware.dev_stack',
  'flutterware.run',
  'flutterware.worlds',
  'flutterware.scenarios',
  'flutterware.translations',
];

/// Drives the server through a real MCP client over an in-memory channel, so
/// what is asserted is what a client actually receives — tool schemas
/// included — rather than the shape of a Dart method.
void main() {
  late MCPClient client;
  late ServerConnection connection;

  late StreamController<String> toServer;
  late StreamController<String> toClient;

  setUp(() async {
    toServer = StreamController<String>();
    toClient = StreamController<String>();

    FlutterwareMcpServer(
      StreamChannel<String>(toServer.stream, toClient.sink),
      workingDirectory: Directory(findRepoRoot('..')!),
    );

    client = MCPClient(
      Implementation(name: 'flutterware test client', version: '1.0.0'),
    );
    connection = client.connectServer(
      StreamChannel<String>(toClient.stream, toServer.sink),
    );
    await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    connection.notifyInitialized();
  });

  tearDown(() async {
    await connection.shutdown();
    await toServer.close();
    await toClient.close();
  });

  test('the declared tool list is what a client receives', () async {
    // The capability document is generated from `FlutterwareMcpServer.tools`;
    // this is what stops that list describing a surface nobody serves.
    var listed = (await connection.listTools()).tools.map((t) => t.name);
    expect(listed, FlutterwareMcpServer.tools.map((t) => t.name));
  });

  test('exposes a small fixed tool set, not one tool per action', () async {
    var tools = (await connection.listTools()).tools
        .map((t) => t.name)
        .toList();
    expect(tools, [
      'flutterware_status',
      'flutterware_actions',
      'flutterware_invoke',
      'flutterware_act',
      // The one tool that reaches no plugin: notes are a feature of the shell,
      // so there is no core to hang them off and no action to invoke.
      'flutterware_review',
    ]);
  });

  test('every argument flutterware_act advertises is forwarded', () async {
    // The schema and the forwarding list are maintained by hand in the same
    // file, and only one of them is visible to a client. When they diverge the
    // dropped argument fails in the worst way: the ambiguity refusal tells the
    // agent to pass `run`, the agent passes it, and the identical refusal
    // comes back forever. (`run` was exactly that hole.)
    var act = (await connection.listTools()).tools.singleWhere(
      (t) => t.name == 'flutterware_act',
    );
    var advertised = (act.inputSchema.properties ?? {}).keys;
    expect(advertised, unorderedEquals(FlutterwareMcpServer.actArguments));
  });

  test('flutterware_act funnels into the run plugin and reports its refusal '
      'as a readable error', () async {
    // An empty run dir of its own, not the machine's: with a real app
    // running this would otherwise observe it — or flake on its presence.
    var runDir = Directory.systemTemp.createTempSync('fw-mcp-act-');
    RunCore.runDirProvider = () => runDir.path;
    addTearDown(() {
      RunCore.runDirProvider = flutterwareRunDir;
      runDir.deleteSync(recursive: true);
    });

    var result = await connection.callTool(
      CallToolRequest(name: 'flutterware_act', arguments: {'verb': 'observe'}),
    );

    expect(result.isError, isTrue);
    var text = (result.content.single as TextContent).text;
    expect(text.toLowerCase(), contains('no'));
    expect(text, isNot(contains('Unhandled')));
  });

  /// The outer layer had to learn what the inner one already knew. A call
  /// that misspells the *wrapper* key — `parameters:` for `arguments:` — used
  /// to run the action with its defaults and answer as if it had been asked,
  /// which is precisely the failure `Session._undeclared` exists to prevent one
  /// level in. Nothing downstream can catch a plausible answer to a question
  /// that was never asked.
  test('a top-level key the tool does not declare is refused', () async {
    var result = await connection.callTool(
      CallToolRequest(
        name: 'flutterware_invoke',
        arguments: {
          'plugin': 'previews',
          'action': 'list',
          'parameters': {'top': '3'},
        },
      ),
    );

    expect(result.isError, isTrue);
    var text = (result.content.single as TextContent).text;
    expect(text, contains('"parameters" is not an argument'));
    expect(
      text,
      contains('It takes: plugin, action, arguments, brief.'),
      reason: 'naming what it does take is what saves the round trip',
    );
  });

  test('and a near miss is named', () async {
    var result = await connection.callTool(
      CallToolRequest(
        name: 'flutterware_actions',
        arguments: {'plugins': 'run'},
      ),
    );
    expect(
      (result.content.single as TextContent).text,
      contains('did you mean "plugin"?'),
    );
  });

  test(
    'every tool closes its schema, not just the ones checked above',
    () async {
      // Declared as well as enforced, for whoever is holding the schema rather
      // than calling it — a client that validates can then refuse without a
      // round trip.
      for (var tool in (await connection.listTools()).tools) {
        expect(
          tool.inputSchema.additionalProperties,
          isFalse,
          reason: '${tool.name} accepts keys it does not document',
        );

        var result = await connection.callTool(
          CallToolRequest(name: tool.name, arguments: {'notAKey': 'x'}),
        );
        expect(result.isError, isTrue, reason: '${tool.name} took a bogus key');
        expect(
          (result.content.single as TextContent).text,
          contains('"notAKey" is not an argument of ${tool.name}'),
        );
      }
    },
  );

  test('the act tool teaches the layer it can address', () async {
    // The forwarding test above catches a dropped argument; it cannot catch a
    // parameter an agent never learns exists. `layer` reached the plugin
    // action before it reached this schema, and in that window the native
    // layer was built, working, and unaskable.
    var act = (await connection.listTools()).tools.singleWhere(
      (tool) => tool.name == 'flutterware_act',
    );
    expect(
      '${act.inputSchema.properties!['layer']}',
      contains('native'),
      reason: 'the tool description is where an agent learns the layer exists',
    );
  });

  test('status reports every declared plugin, loaded', () async {
    var result = await connection.callTool(
      CallToolRequest(name: 'flutterware_status'),
    );
    var payload = _decode(result);

    var plugins = (payload['plugins']! as List).cast<Map<String, Object?>>();
    expect(plugins.map((p) => p['id']), _declaredPlugins);
    // An MCP call starts cold, so a status that reported only cached state
    // would say "not computed" for every package on every call — the config
    // file read back rather than an answer. Both cores load first.
    expect(
      jsonEncode(payload),
      isNot(contains('not computed')),
      reason: 'every declared package is loaded, or says why it could not be',
    );
  });

  test('a plugin with no core is reported, not omitted', () async {
    // Both real plugins have cores now, so this needs a build that lacks one.
    // The behaviour still matters: a status that silently skipped a declared
    // plugin would read as "this project has fewer plugins than it does".
    var toServer = StreamController<String>();
    var toClient = StreamController<String>();
    FlutterwareMcpServer(
      StreamChannel<String>(toServer.stream, toClient.sink),
      workingDirectory: Directory(findRepoRoot('..')!),
      registry: PluginCoreRegistry(),
    );
    var bare = MCPClient(Implementation(name: 'bare', version: '1.0.0'));
    var bareConnection = bare.connectServer(
      StreamChannel<String>(toClient.stream, toServer.sink),
    );
    await bareConnection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: bare.capabilities,
        clientInfo: bare.implementation,
      ),
    );
    bareConnection.notifyInitialized();

    var payload = _decode(
      await bareConnection.callTool(
        CallToolRequest(name: 'flutterware_status'),
      ),
    );
    var plugins = (payload['plugins']! as List).cast<Map<String, Object?>>();
    // One per declaration, whatever the config declares — a registry with
    // nothing in it must not shrink the list, which is the whole point.
    expect(plugins, hasLength(_declaredPlugins.length));
    for (var plugin in plugins) {
      expect(
        (plugin['status']! as Map)['message'],
        contains('no implementation'),
      );
    }

    await bareConnection.shutdown();
    await toServer.close();
    await toClient.close();
  });

  group('what a reply does not repeat', () {
    // Every byte here is read by a model, and an action declaration is static:
    // the same list, in every reply, for the whole session. `flutterware_actions`
    // serves it once. Measured before this rule existed: 77% of a status and 94%
    // of a screenshot's reply were declarations, and an agent iterating on a
    // widget paid the second on every edit.

    test(
      'status describes the project, not what it can be told to do',
      () async {
        var payload = _decode(
          await connection.callTool(
            CallToolRequest(name: 'flutterware_status'),
          ),
        );
        var plugins = (payload['plugins']! as List)
            .cast<Map<String, Object?>>();
        expect(plugins, isNotEmpty);
        for (var plugin in plugins) {
          expect(
            plugin,
            isNot(contains('actions')),
            reason: '${plugin['id']} repeated its declarations into a status',
          );
        }
        // What a status is actually for is still there.
        expect(plugins.map((p) => p['id']), _declaredPlugins);
        expect(plugins.every((p) => p.containsKey('status')), isTrue);
      },
    );

    test(
      'the report after an invoke carries state, not declarations',
      () async {
        var payload = _decode(
          await connection.callTool(
            CallToolRequest(
              name: 'flutterware_invoke',
              arguments: {'plugin': 'dependencies', 'action': 'list'},
            ),
          ),
        );
        var report = payload['report']! as Map<String, Object?>;
        expect(report, isNot(contains('actions')));
        // The point of sending it at all: what changed.
        expect(report, contains('status'));
      },
    );

    test(
      'the projection after an invoke is capped, and brief drops it',
      () async {
        // The inventory is not what changed, and its rows are the expensive
        // kind: each carries a `fw://` address the result beside it does not. A
        // 63-scenario `run` with `steps: none` came back 50KB and blew the MCP
        // result limit — an 18KB result under a 34KB re-listing of scenarios
        // nobody had asked to see.
        Future<Map<String, Object?>> invoke({bool? brief}) async => _decode(
          await connection.callTool(
            CallToolRequest(
              name: 'flutterware_invoke',
              arguments: {
                'plugin': 'dependencies',
                'action': 'list',
                'brief': ?brief,
              },
            ),
          ),
        );

        var full = await invoke();
        var report = full['report']! as Map<String, Object?>;
        expect(report, contains('view'));
        for (var row in _rowsIn(report['view'])) {
          expect(
            row,
            lessThanOrEqualTo(10),
            reason:
                'the status tool caps at 10 and this one did not cap at all',
          );
        }

        var brief =
            (await invoke(brief: true))['report']! as Map<String, Object?>;
        expect(brief, isNot(contains('view')));
        // What a report is actually for survives the cut.
        expect(brief, contains('status'));
      },
    );

    test('an invoke warms the core its report is read from', () async {
      var runDir = Directory.systemTemp.createTempSync('fw-mcp-invoke-');
      RunCore.runDirProvider = () => runDir.path;
      addTearDown(() {
        RunCore.runDirProvider = flutterwareRunDir;
        runDir.deleteSync(recursive: true);
      });
      var payload = _decode(
        await connection.callTool(
          CallToolRequest(
            name: 'flutterware_invoke',
            arguments: {'plugin': 'run', 'action': 'apps'},
          ),
        ),
      );
      // The consumer symptom: a correct result beside a report still saying
      // "Not scanned yet." — every MCP call builds a fresh session, so a
      // report read without a load first is of a core that has seen nothing.
      expect('${payload['report']}', isNot(contains('Not scanned yet.')));
    });

    test('and the declarations are still one tool away', () async {
      var payload = _decode(
        await connection.callTool(CallToolRequest(name: 'flutterware_actions')),
      );
      var plugins = (payload['plugins']! as List).cast<Map<String, Object?>>();
      expect(plugins.every((p) => p.containsKey('actions')), isTrue);
    });

    /// The instructions say to start here, so every session pays it. The
    /// panel projection is the inventory and the inventory is nine tenths of
    /// the reply — measured on this repo at 19.2k of 21.7k characters, most of
    /// it rows naming every dependency of every package. `brief` answers the
    /// question the first call is actually asking — which plugins are there and
    /// which are unhappy — and each plugin's own actions still serve the rest.
    test('brief keeps the status lines and drops the inventory', () async {
      var full = _text(
        await connection.callTool(CallToolRequest(name: 'flutterware_status')),
      );
      var brief = _text(
        await connection.callTool(
          CallToolRequest(
            name: 'flutterware_status',
            arguments: {'brief': true},
          ),
        ),
      );

      expect(brief.length, lessThan(full.length ~/ 2));
      var plugins = ((jsonDecode(brief) as Map)['plugins']! as List)
          .cast<Map<String, Object?>>();
      expect(plugins, isNotEmpty);
      expect(
        plugins.every((p) => !p.containsKey('view')),
        isTrue,
        reason: 'the projection is what brief drops',
      );
      expect(
        plugins.every((p) => p.containsKey('status')),
        isTrue,
        reason: 'and the status line is what it keeps',
      );
    });

    test(
      'naming a plugin answers that one, and refuses an unknown one',
      () async {
        var one = _text(
          await connection.callTool(
            CallToolRequest(
              name: 'flutterware_status',
              arguments: {'plugin': 'previews'},
            ),
          ),
        );
        var plugins = ((jsonDecode(one) as Map)['plugins']! as List)
            .cast<Map>();
        expect(plugins, hasLength(1));
        expect(plugins.single['id'], 'flutterware.previews');

        var missing = await connection.callTool(
          CallToolRequest(
            name: 'flutterware_status',
            arguments: {'plugin': 'nope'},
          ),
        );
        expect(missing.isError, isTrue);
      },
    );

    test('replies are compact — indentation is bytes no model reads', () async {
      var text = _text(
        await connection.callTool(CallToolRequest(name: 'flutterware_status')),
      );
      expect(
        text,
        isNot(contains('\n')),
        reason:
            'Pretty-printing was 39% of a status and 47% of an actions reply. '
            '`fw --json` keeps its indentation; that one is read by a person.',
      );
    });
  });

  test('actions lists what can be invoked, with parameters', () async {
    var payload = _decode(
      await connection.callTool(CallToolRequest(name: 'flutterware_actions')),
    );
    var dependencies = (payload['plugins']! as List)
        .cast<Map<String, Object?>>()
        .firstWhere((p) => p['id'] == 'flutterware.dependencies');
    expect(
      (dependencies['actions']! as List).cast<Map<String, Object?>>().map(
        (a) => a['id'],
      ),
      ['list'],
    );
  });

  test('invoke runs the action and returns the report with it', () async {
    var payload = _decode(
      await connection.callTool(
        CallToolRequest(
          name: 'flutterware_invoke',
          arguments: {'plugin': 'dependencies', 'action': 'list'},
        ),
      ),
    );
    expect(payload['plugin'], 'flutterware.dependencies');
    expect(payload['action'], 'list');
    // Saves the agent a second round-trip to see what changed.
    expect(payload['report'], isA<Map<String, Object?>>());
  });

  group('errors come back as tool results, not protocol failures', () {
    test('unknown plugin', () async {
      var result = await connection.callTool(
        CallToolRequest(
          name: 'flutterware_invoke',
          arguments: {'plugin': 'nope', 'action': 'list'},
        ),
      );
      expect(result.isError, isTrue);
      expect(_text(result), contains('No plugin "nope"'));
      // The recovery path is in the message: it says what *is* declared.
      expect(_text(result), contains('flutterware.dependencies'));
    });

    test('unknown action', () async {
      var result = await connection.callTool(
        CallToolRequest(
          name: 'flutterware_invoke',
          arguments: {'plugin': 'dependencies', 'action': 'not-an-action'},
        ),
      );
      expect(result.isError, isTrue);
      expect(_text(result), contains('unknown action'));
      // Like every other refusal on this surface, it names what *is* there —
      // this was the one that did not, and it is the one a caller reaches by
      // guessing at a name.
      expect(_text(result), contains('list'));
    });

    test('missing required argument', () async {
      var result = await connection.callTool(
        CallToolRequest(
          name: 'flutterware_invoke',
          arguments: {'plugin': 'dependencies'},
        ),
      );
      expect(result.isError, isTrue);
    });
  });

  group('fw mcp', () {
    // The command is how a client reaches any of the above. `app/bin/mcp.dart`
    // only exists inside a checkout, so a server nobody can spawn is a server
    // that is not there.
    test('serves, rather than reporting an unknown command', () async {
      var served = false;
      var err = StringBuffer();
      var exit = await FwCli(
        openSession: () => throw StateError('mcp opens no session of its own'),
        out: StringBuffer(),
        err: err,
        serveMcp: () async => served = true,
      ).run(['mcp']);

      expect(served, isTrue);
      expect(exit, 0);
      expect(err.toString(), isEmpty);
    });

    test('writes nothing to stdout — that is the wire', () async {
      var out = StringBuffer();
      await FwCli(
        openSession: () => throw StateError('mcp opens no session of its own'),
        out: out,
        err: StringBuffer(),
        serveMcp: () async {},
      ).run(['mcp']);

      expect(out.toString(), isEmpty);
    });
  });

  /// A server is `exec`'d once and answers out of the code it was built from,
  /// while the project under it can be upgraded or switched to a path
  /// dependency at any point. A consumer met the two disagreeing: the server
  /// called a newly-added plugin "declared with no implementation" while `fw`
  /// in the same worktree listed it, and the message pointed at
  /// `tool/flutterware.dart`, which was the one file that was right.
  group('a server older than the project says so', () {
    /// A project rooted at [directory] resolving flutterware to [version],
    /// plus one unrelated package to be moved around independently.
    void resolve(
      Directory directory,
      String version, {
      String at = '.',
      String other = '1.0.0',
    }) {
      File(p.join(directory.path, at, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'collection',
                'rootUri': 'file:///pub/collection-$other',
              },
              {
                'name': 'flutterware',
                'rootUri': 'file:///pub/flutterware-$version',
              },
            ],
          }),
        );
    }

    test('reads what flutterware resolved to, or nothing at all', () {
      var directory = Directory.systemTemp.createTempSync('fw_res');
      addTearDown(() => directory.deleteSync(recursive: true));

      expect(FlutterwareMcpServer.resolvedFlutterware(directory.path), isNull);

      resolve(directory, '0.5.2');
      expect(
        FlutterwareMcpServer.resolvedFlutterware(directory.path),
        contains('flutterware-0.5.2'),
      );
    });

    // The false positive that would have made this unreadable: an IDE runs
    // `pub get` whenever a pubspec is saved, and a rebase moves one. Neither
    // makes the server stale, and a note nobody can dismiss on every reply for
    // the rest of a session is worse than no note.
    test('an unrelated dependency moving is not staleness', () {
      var directory = Directory.systemTemp.createTempSync('fw_res');
      addTearDown(() => directory.deleteSync(recursive: true));

      resolve(directory, '0.5.2');
      var seen = FlutterwareMcpServer.resolvedFlutterware(directory.path)!;
      resolve(directory, '0.5.2', other: '2.0.0');
      var after = FlutterwareMcpServer.resolvedFlutterware(directory.path)!;

      expect(
        FlutterwareMcpServer.staleResolutionNote(seen: seen, resolved: after),
        isNull,
      );
    });

    test('flutterware itself moving is', () {
      var directory = Directory.systemTemp.createTempSync('fw_res');
      addTearDown(() => directory.deleteSync(recursive: true));

      resolve(directory, '0.5.2');
      var seen = FlutterwareMcpServer.resolvedFlutterware(directory.path)!;
      resolve(directory, '0.5.3');
      var after = FlutterwareMcpServer.resolvedFlutterware(directory.path)!;

      var note = FlutterwareMcpServer.staleResolutionNote(
        seen: seen,
        resolved: after,
      );
      expect(note, isNotNull);
      expect(note, contains(flutterwareVersion));
      expect(note, contains('no implementation'));
      expect(note, contains('reconnect'));
    });

    // A repo may keep `tool/flutterware.dart` at the top and its app in a
    // subdirectory, so the root is not always a package. Looking only there
    // made the whole check a silent no-op in exactly those projects.
    test('finds the resolution when the root is not the package', () {
      var directory = Directory.systemTemp.createTempSync('fw_res');
      addTearDown(() => directory.deleteSync(recursive: true));
      File(p.join(directory.path, 'my_app', 'pubspec.yaml'))
          .createSync(recursive: true);
      resolve(directory, '0.5.2', at: 'my_app');

      expect(
        FlutterwareMcpServer.resolvedFlutterware(directory.path),
        contains('flutterware-0.5.2'),
      );
    });

    // The note is appended to a result somebody else built, and rebuilding
    // one field at a time is how the rest go missing.
    test('appending the note keeps everything else the result carried', () {
      var noted = FlutterwareMcpServer.withNote(
        CallToolResult(
          content: [TextContent(text: 'the answer')],
          structuredContent: {'plugins': 3},
          isError: true,
        ),
        'stale',
      );

      expect(noted.structuredContent, {'plugins': 3});
      expect(noted.isError, isTrue);
      expect((noted.content.first as TextContent).text, 'the answer');
      expect((noted.content.last as TextContent).text, 'stale');
    });

    test('half a file being written is not an answer', () {
      var directory = Directory.systemTemp.createTempSync('fw_res');
      addTearDown(() => directory.deleteSync(recursive: true));
      File(p.join(directory.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion": 2, "packa');

      expect(FlutterwareMcpServer.resolvedFlutterware(directory.path), isNull);
    });
  });
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;

Map<String, Object?> _decode(CallToolResult result) =>
    jsonDecode(_text(result)) as Map<String, Object?>;

/// How long every list and table in a view projection is, nested included.
List<int> _rowsIn(Object? node) => switch (node) {
  List list => [for (var entry in list) ..._rowsIn(entry)],
  Map map => [
    for (var entry in map.entries) ...[
      if ((entry.key == 'items' || entry.key == 'rows') && entry.value is List)
        (entry.value as List).length,
      ..._rowsIn(entry.value),
    ],
  ],
  _ => const [],
};
