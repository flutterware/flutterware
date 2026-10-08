import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/embedder/tester_phase.dart';
import 'package:flutterware_app/src/plugins/native/previews_plugin.dart';
import 'package:flutterware_app/src/plugins/plugin_host.dart';
import 'package:flutterware_app/src/shell/workspace.dart';
import 'package:flutterware_app/src/shell/worktree.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// The harness lane of a first open, and the wiring that carries it.
///
/// **This is the half a live check cannot vouch for.** The hook is installed in
/// the plugin's constructor, which a hot reload does not re-run, so a
/// development session can show an empty strip through a forty-second compile
/// and prove nothing either way about the shipped code. The wiring is the
/// thing under test, not the phrasing.
///
/// What it carries is the whole vocabulary rather than the part a status row
/// uses: the rail shows nothing when nothing is happening, so
/// `previewsRunnerStatus` drops [TesterPhase.ready] — and a surface that has to
/// take *itself* down needs to be told the wait ended.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fw_previews_lanes_test');
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  PreviewsPlugin plugin() => PreviewsPlugin(
    PreviewsCore(
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
    ),
  );

  test('the harness lane reaches the package’s progress', () {
    var it = plugin();
    addTearDown(it.dispose);
    var report = it.core.onRunnerPhase;
    expect(report, isNotNull, reason: 'the constructor installs it');

    report!('.', (phase: TesterPhase.compiling, files: null));
    expect(it.startupFor('.').task?.label, 'Compiling the previews');

    report('.', (phase: TesterPhase.reloading, files: 1));
    expect(it.startupFor('.').task?.label, 'Reloading 1 edited file');

    report('.', (phase: TesterPhase.ready, files: null));
    expect(
      it.startupFor('.').task,
      isNull,
      reason: 'ready is the end of every wait here, and takes the lane down',
    );
  });

  test('one progress per package, and each is its own wait', () {
    var it = plugin();
    addTearDown(it.dispose);
    expect(it.startupFor('.'), same(it.startupFor('.')));
    expect(it.startupFor('.'), isNot(same(it.startupFor('other'))));
  });

  test('the session it builds reports into that same one', () {
    // The two lanes have to merge somewhere, and the plugin is the only place
    // that outlives both: a session is rebuilt every time the panel mounts, and
    // the harness is neither started nor stopped by the panel being open.
    var it = plugin();
    addTearDown(it.dispose);
    expect(it.sessionFor('.').startup, same(it.startupFor('.')));
  });
}
