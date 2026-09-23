import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/native/previews_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/previews/compiler_daemon_client.dart';
import 'package:flutterware_app/src/previews/protocol.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/ui/theme.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// What a config reload does to a panel that stays mounted through it.
///
/// Saving `tool/flutterware.dart` throws the whole plugin graph away and builds
/// it again, so the panel's plugin — and the [PreviewsCore] and every
/// `CatalogSession` under it — is a different object afterwards. The shell
/// keys the panel on the worktree and the plugin *id*, neither of which moves,
/// so Flutter keeps this `State` across the swap. It therefore woke up holding
/// a session its owner had already disposed, went on rendering it, and the
/// entry list's `addListener` threw: *A CatalogSession was used after being
/// disposed*, three times, and a canvas that stayed blank until a hot restart.
///
/// Driven through [PreviewsPlugin.connectToDaemon], which is why that parameter
/// exists: the real connect compiles a snapshot and spawns a compiler, and a
/// panel that cannot be mounted cannot have its wiring tested. The connector
/// here never answers, which is enough — the bug is in what the panel *binds
/// to*, and binding happens long before a daemon says anything.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_previews_reload_test');
    File(p.join(root.path, 'tool', 'catalog', 'button.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
@Preview(name: 'Button')
Widget button() => const Placeholder();
''');
    // A daemon address is derived from the resolution, so a package without
    // one never reaches the connector at all — it fails building the address.
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// A core over the temp worktree, declaring one package with one demo in it.
  PreviewsCore core() => PreviewsCore(
    PluginHost(
      id: uiCatalogPluginId,
      label: 'Previews',
      worktree: Worktree(path: root.path),
      workspace: Workspace(
        root: root.path,
        declared: const [Pkg('.')],
        discovered: const ['.'],
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/tmp/flutter'),
      ),
      config: const {
        'packages': [
          {'path': '.', 'directory': 'tool/catalog'},
        ],
      },
    ),
  );

  testWidgets('a config reload rebinds the panel to the plugin it built', (
    tester,
  ) async {
    // Which plugin's sessions actually got built. The whole assertion: before
    // the fix the second one built none, because the panel still held the
    // first one's.
    var connected = <String>[];
    DaemonConnector connector(String owner) =>
        ({required dartExecutable, required config, onLog, onProgress}) {
          connected.add(owner);
          // Never answers. A session left `starting` still mounts the view,
          // which is where the disposed one was used.
          return Completer<(CompilerDaemonClient, DaemonReady)>().future;
        };

    var first = core();
    var plugin = PreviewsPlugin(first, connectToDaemon: connector('first'));
    // The scan reads files off an isolate, so it cannot run inside the fake
    // async zone the pumps below live in.
    await tester.runAsync(first.computeAll);

    var address = ValueNotifier(
      Address(worktree: 'wt', plugin: uiCatalogPluginId, segments: const ['.']),
    );
    Future<void> pump(PreviewsPlugin plugin) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: AddressRoot(
          address: address,
          onChanged: (a) => address.value = a,
          child: Builder(builder: plugin.buildPanel),
        ),
      ),
    );

    await pump(plugin);
    await tester.pump();
    expect(connected, ['first'], reason: 'the panel started its compile loop');

    // The reload, in the order the shell does it: `open.release()` disposes
    // the graph, `_build` makes a new one, and the rebuild that follows hands
    // the panel a plugin whose predecessor is already gone.
    var second = core();
    var rebuilt = PreviewsPlugin(second, connectToDaemon: connector('second'));
    plugin.dispose();
    first.dispose();
    await tester.runAsync(second.computeAll);
    await pump(rebuilt);
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the disposed session must not be rendered',
    );
    expect(connected, [
      'first',
      'second',
    ], reason: 'the panel followed the swap onto the new plugin');

    rebuilt.dispose();
    second.dispose();
  });
}
