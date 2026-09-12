/// The project the studio opens when it is showing a recording rather than a
/// checkout: its own catalog demos of whole panels, its own scenario tests,
/// and the web demo.
///
/// Everything the shell would learn from the machine is answered here instead
/// — the worktree list git would report, the manifest `tool/flutterware.dart`
/// would produce, the facts the explorer would probe — and every plugin's core
/// is either the live core over recorded readers (launcher icon, scenarios,
/// server, dev stack, translations, store, dependencies, splash) or a quiet
/// [RecordedCore] whose panel says so. Nothing below runs a process, opens a
/// socket or walks a directory; the one filesystem touch left, the facts
/// store, points at a path that is not there and is built to shrug.
///
/// The recorded project is **`examples/brewline`, the demo app, as if it were
/// its own repository** — one package at `.`, which is what a reader's project
/// usually is and what keeps the workspace free of anything the disk would
/// have to confirm. See `tool/demo/record.dart` for how the recording is
/// made.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';

import '../context.dart';
import '../plugins/manifest_loader.dart';
import '../plugins/native/dependencies_plugin.dart';
import '../plugins/native/dev_stack_core.dart';
import '../plugins/native/dev_stack_plugin.dart';
import '../plugins/native/icon_plugin.dart';
import '../plugins/native/previews_plugin.dart';
import '../plugins/native/scenarios_plugin.dart';
import '../plugins/native/server_plugin.dart';
import '../plugins/native/splash_plugin.dart';
import '../plugins/native/store_plugin.dart';
import '../plugins/native/translations_plugin.dart';
import '../previews/discovery.dart' show ScanResult;
import '../previews/inline_guest.dart';
import '../plugins/native_plugin.dart';
import '../plugins/plugin_core.dart';
import '../plugins/registry.dart';
import '../shell/shell_controller.dart';
import '../shell/worktree_discovery.dart';
import '../ui/empty_state.dart';
import '../utils/flutter_sdk.dart';
import '../worktrees/facts.dart';
import '../worktrees/facts_controller.dart';
import '../worktrees/facts_probe.dart';
import '../worktrees/facts_store.dart';
import '../worktrees/providers/agent.dart';
import '../worktrees/providers/forge.dart';
import '../worktrees/providers/git.dart';
import '../worktrees/watchers.dart';
import 'recorded_config.dart';
import 'recorded_dependencies.dart';
import 'recorded_scenarios.dart';
import 'recorded_server.dart';
import 'recorded_splash.dart';
import 'recorded_stack.dart';
import 'recorded_store.dart';
import 'recorded_translations.dart';
import 'recording.dart';

/// What the recorded project's `tool/flutterware.dart` would declare.
///
/// Written with the same classes a project writes its config with, so the
/// recording's rail is a rail a real config could produce. The launcher icon
/// and the scenarios have a recording behind them; the rest are declared so
/// the rail reads as a project rather than as two plugins, and their panels
/// say what they are.
PluginManifest recordedManifest() {
  const root = Pkg('.');
  var fw = FlutterwareConfig();
  fw.use(Dependencies(packages: const [DependenciesPackage(root)]));
  fw.use(Assets(packages: const [AssetsPackage(root)]));
  // A phone app: its previews open on a phone, as the root manifest says.
  fw.use(
    Previews(packages: const [PreviewsPackage(root, device: Devices.iphone16)]),
  );
  fw.use(Scenarios(packages: const [ScenariosPackage(root)]));
  fw.use(LauncherIcon(packages: const [LauncherIconPackage(root)]));
  fw.use(NativeSplash(packages: const [NativeSplashPackage(root)]));
  // The words, as the demo app declares them — see `recorded_config.dart`
  // for why the list lives apart — and an export the recorder ran over its
  // whole suite; see `recorded_translations.dart`.
  fw.use(
    Translations(
      packages: const [
        TranslationsPackage(root, catalogs: recordedTranslationCatalogs),
      ],
    ),
  );
  // The store listing, as the demo app declares it, over an export the
  // recorder ran — see `recorded_store.dart`. Named, because the name is the
  // tree's own segment and the recording has no pubspec to read it from.
  fw.use(
    StoreShots(
      apps: [
        StoreShotsApp(
          root,
          name: 'brewline',
          file: 'test/scenarios/mobile/shop_test.dart',
          frame: 'lib/store_frame.dart',
          listings: [
            Listing.appStore(locales: const {'en': 'en-US', 'fr': 'fr-FR'}),
          ],
        ),
      ],
    ),
  );
  // The orders server, as its ring was recorded — see `recorded_server.dart`.
  fw.use(ServerInspection());
  // The stack around it, as its script's answers were recorded — see
  // `recorded_stack.dart`. Commands rather than scripts: a script is checked
  // for on disk before it runs, and there is no disk.
  fw.use(
    DevStack.background(
      label: 'Orders server',
      probe: Probe.json(
        StackRun.command(['dart', 'tool/stack.dart', 'status', '--json']),
      ),
      start: StackRun.command(['dart', 'tool/stack.dart', 'up']),
      stop: StackRun.command(['dart', 'tool/stack.dart', 'down']),
      poll: const Duration(seconds: 15),
      commands: [
        StackCommand(
          'logs',
          'Logs',
          StackRun.command(['dart', 'tool/stack.dart', 'logs']),
          description: 'The last 40 lines the server logged.',
        ),
        StackCommand(
          'hit',
          'Send a request',
          StackRun.command(['dart', 'tool/stack.dart', 'hit']),
          argument: 'path',
          description:
              'Requests a path — /menu, /slow, /error — so the Server panel '
              'has traffic to show. Defaults to /menu.',
        ),
      ],
    ),
  );
  return fw.toManifest();
}

/// A shell over [recording], started on nothing but memory.
///
/// [appContext] and [flutterSdk] default to values nothing here dereferences:
/// the recorded cores never build a daemon or spawn a tool, so the SDK path is
/// a label and the app-tool directory is never listed.
ShellController recordedShell({
  required Recording recording,
  InlinePreviews? previews,
  AppContext? appContext,
  FlutterSdkPath? flutterSdk,
  PluginManifest? manifest,
}) {
  var context =
      appContext ??
      AppContext(
        logger: LogClient.print(),
        appToolDirectory: Directory(recordedProjectRoot),
      );
  var declared = manifest ?? recordedManifest();
  return ShellController(
    appContext: context,
    flutterSdk: flutterSdk ?? FlutterSdkPath('$recordedProjectRoot/flutter'),
    registry: PluginRegistry({
      for (var plugin in declared.plugins)
        plugin.id: _recordedPanel(plugin.id, recording, previews),
    }),
    coreRegistry: PluginCoreRegistry({
      for (var plugin in declared.plugins)
        plugin.id: _recordedCore(plugin.id, recording, previews),
    }),
    manifestLoader: RecordedManifestLoader(declared),
    discovery: WorktreeDiscovery(runProcess: _recordedGit),
    worktreeFacts: (root) => WorktreeFactsController(
      repoRoot: root,
      probe: WorktreeFactsProbe(
        repoRoot: root,
        // A path that is not there: the store reads an empty cache from it and
        // swallows the write, which is the one filesystem touch left here.
        store: WorktreeFactsStore.open(root, at: File('$root/facts.json')),
        git: GitProbe(runProcess: _recordedGit),
        agent: const _NoAgents(),
        forge: const _NoForge(),
        stack: RecordedStacks(RecordedStack(recording)),
      ),
      settle: context.settle,
    ),
    worktreeWatcher: (root) => WorktreeWatcher(
      repoRoot: root,
      // Both default to paths under the home directory, which is read from the
      // environment — and a browser has neither. Nothing is watched anyway.
      agentRoot: '$root/agents',
      runDir: '$root/run',
      watch: (path, {required recursive}) => const Stream.empty(),
    ),
    watchEvents: (_) => const Stream.empty(),
  );
}

/// The one git answer a recording has: it is a repository with one worktree
/// on `main`. Anything else git is asked fails, quietly.
Future<ProcessResult> _recordedGit(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  if (arguments.take(2).join(' ') == 'worktree list') {
    return ProcessResult(
      0,
      0,
      'worktree $recordedProjectRoot\nbranch refs/heads/main\n',
      '',
    );
  }
  return ProcessResult(0, 1, '', 'not available in a recording');
}

/// The live core over the recording, for a plugin with one behind it; a
/// quiet [RecordedCore] for the rest.
PluginCoreFactory _recordedCore(
  String pluginId,
  Recording recording,
  InlinePreviews? previews,
) => switch (pluginId) {
  launcherIconPluginId => (host) => LauncherIconCore(
    host,
    scan: recordedIconScanner(recording),
  ),
  scenariosPluginId => (host) => ScenariosCore(
    host,
    scan: recordedScenarioScan(recording),
    runner: recordedScenarioRunner(recording),
  ),
  serverPluginId => (host) => ServerCore(
    host,
    source: RecordedServerSource(recording),
  ),
  devStackPluginId => (host) => DevStackCore(
    host,
  )..runProcess = RecordedStack(recording).run,
  translationsPluginId => (host) => TranslationsCore(
    host,
    source: RecordedTranslationSource(recording),
  ),
  storePluginId => (host) => StoreCore(
    host,
    source: RecordedStoreSource(recording),
  ),
  dependenciesPluginId => (host) => DependenciesCore(
    host,
    source: RecordedDependencySource(recording),
  ),
  // No polling: nothing under a recording moves, and the poll would stat it.
  splashPluginId => (host) => SplashCore(
    host,
    files: RecordedSplashFiles(recording),
    pollInterval: Duration.zero,
  ),
  // Previews is not recorded: its entries are compiled into this program
  // and the scan is the table of them.
  uiCatalogPluginId when previews != null => (host) => PreviewsCore(
    host,
    scan: ({
      required projectRoot,
      required roots,
      required previewAnnotations,
    }) async => ScanResult(entries: previews.entries, diagnostics: const []),
  ),
  _ => RecordedCore.new,
};

/// The live panel, reading its pictures from the recording; [NotRecordedPlugin]
/// for a plugin with nothing behind it.
NativePluginFactory _recordedPanel(
  String pluginId,
  Recording recording,
  InlinePreviews? previews,
) => switch (pluginId) {
  launcherIconPluginId => panelFor<LauncherIconCore>(
    (core) => LauncherIconPlugin(core, image: recordedIconImage(recording)),
  ),
  scenariosPluginId => panelFor<ScenariosCore>(
    (core) => ScenariosPlugin(
      core,
      // Nothing on disk to watch, and no disk.
      watchSources: (path, {required recursive}) => const Stream.empty(),
      artifacts: recording,
      appIcon: recordedScenarioAppIcon(recording),
    ),
  ),
  // The live panel: the recorded source underneath answers every read.
  serverPluginId => panelFor<ServerCore>(ServerPlugin.new),
  devStackPluginId => panelFor<DevStackCore>(DevStackPlugin.new),
  translationsPluginId => panelFor<TranslationsCore>(TranslationsPlugin.new),
  storePluginId => panelFor<StoreCore>(
    (core) => StorePlugin(core, image: recordedStoreImage(recording)),
  ),
  dependenciesPluginId => panelFor<DependenciesCore>(DependenciesPlugin.new),
  splashPluginId => panelFor<SplashCore>(
    (core) => SplashPlugin(core, image: recordedSplashImage(recording)),
  ),
  uiCatalogPluginId when previews != null => panelFor<PreviewsCore>((core) {
    var inline = InlinePreviewsGuest(previews);
    return PreviewsPlugin(
      core,
      connectToDaemon: inline.connect,
      launchGuest: inline.launch,
      // Rendered by `flutter_tester`, which this host cannot spawn.
      thumbnails: false,
    );
  }),
  _ => panelFor<RecordedCore>(NotRecordedPlugin.new),
};

/// The manifest, without running anything.
class RecordedManifestLoader implements ManifestLoader {
  const RecordedManifestLoader(this.manifest);

  final PluginManifest manifest;

  @override
  Future<PluginManifest?> load(String path) async => manifest;

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async => (manifest: manifest, error: null);

  @override
  String get dartExecutable => 'dart';

  @override
  String? get flutterRoot => null;

  @override
  Duration get timeout => Duration.zero;
}

/// A plugin the recording declares but has nothing recorded for.
///
/// Quiet, with a row per declared package so the rail shows the project's
/// shape. [NotRecordedPlugin] is its panel.
class RecordedCore extends PluginCore {
  RecordedCore(super.host);

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    status: Status.none,
    children: [
      for (var path in host.packagePaths)
        PluginChild(id: path, label: path == '.' ? 'root' : path),
    ],
  );
}

class NotRecordedPlugin extends NativePlugin<RecordedCore> {
  NotRecordedPlugin(super.core);

  @override
  Widget buildPanel(BuildContext context) => EmptyState(
    icon: Icons.radio_button_unchecked,
    title: 'Not in this recording',
    message:
        '${host.label} reads a live project. This studio is showing a '
        'recording, and nothing has been recorded for it yet.',
  );
}

class _NoAgents implements AgentProbe {
  const _NoAgents();

  @override
  Future<AgentFacts?> probe(String worktreePath) async => null;
}

class _NoForge implements ForgeProbe {
  const _NoForge();

  @override
  Future<ForgeReport> probe(String repoRoot) async =>
      const ForgeReport.unavailable('This is a recording.');
}
