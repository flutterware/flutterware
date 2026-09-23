import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/address/address_scope.dart';
import 'package:flutterware_app/src/changes/change_set.dart';
import 'package:flutterware_app/src/changes/changes_controller.dart';
import 'package:flutterware_app/src/changes/changes_screen.dart';
import 'package:flutterware_app/src/changes/patch_index.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/manifest_loader.dart';
import 'package:flutterware_app/src/plugins/native_plugin.dart';
import 'package:flutterware_app/src/plugins/native/run_core.dart'
    show runPluginId;
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/plugins/registry.dart';
import 'package:flutterware_app/src/run/handle.dart';
import 'package:flutterware_app/src/run/inventory.dart';
import 'package:flutterware_app/src/shell/device_desk.dart';
import 'package:flutterware_app/src/shell/shell_controller.dart';
import 'package:flutterware_app/src/utils/fitted_app.dart';
import 'package:flutterware_app/src/shell/shell_search.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:flutterware_app/src/ui/command_palette.dart';
import 'package:flutterware_app/src/shell/worktree_discovery.dart';
import 'package:flutterware_app/src/shell/config_load.dart';
import 'package:flutterware_app/src/shell/config_screen.dart';
import 'package:flutterware_app/src/utils/daemon/device.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';

const _listing =
    'worktree /repo\nbranch refs/heads/main\n\n'
    'worktree /repo-explorer\nbranch refs/heads/feature/explorer\n';

const _manifestJson =
    '{"version":1,"plugins":['
    '{"id":"a.deps","label":"Dependencies"},'
    '{"id":"a.tests","label":"Tests"}]}';

class _FakeCore extends PluginCore {
  _FakeCore(super.host, {this.status = Status.none, this.children = const []});

  Status status;
  final List<PluginChild> children;

  /// Moves a plugin from quiet to loud, which is the only way to watch what a
  /// row or a tab does when a status *arrives* rather than what it looks like
  /// once one is there.
  void say(Status value) {
    status = value;
    notifyChanged();
  }

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    status: status,
    children: children,
  );
}

class _Fake extends NativePlugin<_FakeCore> {
  _Fake(super.core);

  /// Reports every segment it was given, so a test can see what survived the
  /// trip from the address to the panel — which is exactly what used to be
  /// truncated to one.
  @override
  Widget buildPanel(BuildContext context) {
    var segments = AddressScope.segments(context);
    return Center(
      child: Text('panel:$id/${segments.isEmpty ? '-' : segments.join('/')}'),
    );
  }
}

/// A core whose panel starts work on mount — the shape every real plugin has,
/// and the one that crashed the app: notifying from initState marks the shell's
/// AnimatedBuilder dirty during build.
class _EagerCore extends PluginCore {
  _EagerCore(super.host);

  var tracked = false;

  void track() {
    tracked = true;
    notifyChanged();
  }

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    status: Status.neutral(tracked ? 'tracking' : '—'),
  );
}

class _EagerPanelPlugin extends NativePlugin<_EagerCore> {
  _EagerPanelPlugin(super.core);

  @override
  Widget buildPanel(BuildContext context) => _EagerPanel(this);
}

class _EagerPanel extends StatefulWidget {
  const _EagerPanel(this.plugin);
  final _EagerPanelPlugin plugin;

  @override
  State<_EagerPanel> createState() => _EagerPanelState();
}

class _EagerPanelState extends State<_EagerPanel> {
  @override
  void initState() {
    super.initState();
    widget.plugin.core.track();
  }

  @override
  Widget build(BuildContext context) => const Text('eager');
}

PluginRegistry _panels(Iterable<String> ids) =>
    PluginRegistry({for (var id in ids) id: panelFor<_FakeCore>(_Fake.new)});

class _StubLoader implements ManifestLoader {
  @override
  String? get flutterRoot => null;

  _StubLoader();

  String manifest = _manifestJson;
  bool broken = false;

  @override
  Future<PluginManifest?> load(String path) async {
    if (broken) {
      throw ManifestLoadException(
        'tool/flutterware.dart exited with 1.',
        details: "lib/config.dart:4:3: Error: Expected ';'.",
      );
    }
    return PluginManifest.parse(manifest);
  }

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async {
    try {
      return (manifest: await load(path), error: null);
    } on ManifestLoadException catch (e) {
      return (manifest: null, error: '$e');
    }
  }

  @override
  String get dartExecutable => 'dart';

  @override
  Duration get timeout => Duration.zero; // Unused: no stub spawns a process.
}

late _StubLoader _loader;

ShellController _controller({String listing = _listing}) {
  _loader = _StubLoader();
  return ShellController(
    appContext: AppContext(logger: LogClient.print()),
    flutterSdk: FlutterSdkPath('/tmp/flutter'),
    registry: _panels(const ['a.deps', 'a.tests']),
    coreRegistry: PluginCoreRegistry({
      'a.deps': (h) => _FakeCore(h, status: const Status.neutral('170 direct')),
      'a.tests': (h) => _FakeCore(h, status: const Status.error('3 failing')),
    }),
    manifestLoader: _loader,
    discovery: WorktreeDiscovery(
      runProcess: (_, _, {workingDirectory}) async =>
          ProcessResult(0, 0, listing, ''),
    ),
  );
}

Future<ShellController> _pumpShell(WidgetTester tester) async {
  var shell = _controller();
  await shell.start('/repo');
  await tester.pumpWidget(ShellApp(shell));
  await tester.pumpAndSettle();
  return shell;
}

void main() {
  testWidgets('renders a tab for the open worktree only', (tester) async {
    var shell = await _pumpShell(tester);

    expect(find.byKey(worktreeTabKey(shell.worktrees.first)), findsOneWidget);
    // feature/explorer is discovered but not open, so it gets no tab.
    expect(find.byKey(worktreeTabKey(shell.worktrees.last)), findsNothing);
  });

  testWidgets('a worktree opens on its home screen', (tester) async {
    await _pumpShell(tester);

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('main checkout'), findsOneWidget);
    // No plugin panel is mounted until you pick one.
    expect(find.textContaining('panel:'), findsNothing);
    // Launched where it opened, so nothing to say.
    expect(find.byKey(launchFallbackBannerKey), findsNothing);
  });

  testWidgets('a checkout opened in place of the launch directory says so', (
    tester,
  ) async {
    var shell = _controller();
    await shell.start('/elsewhere/project');
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(launchFallbackBannerKey),
        matching: find.textContaining('/elsewhere/project'),
      ),
      findsOneWidget,
    );

    // Only on the checkout it is about: opening another one is a deliberate
    // act, and warning there would be warning about the wrong thing.
    await shell.open(shell.closedWorktrees.first);
    await tester.pumpAndSettle();
    expect(find.byKey(launchFallbackBannerKey), findsNothing);
  });

  testWidgets('the sidebar shows each plugin with its status', (tester) async {
    await _pumpShell(tester);

    expect(find.text('Dependencies'), findsOneWidget);
    expect(find.text('Tests'), findsOneWidget);
    expect(find.text('170 direct'), findsOneWidget);
    expect(find.text('3 failing'), findsOneWidget);
  });

  testWidgets('the desk lists devices and jumps to the holding worktree', (
    tester,
  ) async {
    var runDir = Directory.systemTemp.createTempSync('fw-desk-');
    DeskButton.runDirProvider = () => runDir.path;
    addTearDown(() {
      DeskButton.runDirProvider = flutterwareRunDir;
      runDir.deleteSync(recursive: true);
    });
    DeviceCache.write(runDir.path, const [
      DaemonDevice(id: 'phone', name: 'Xavier iPhone'),
    ]);
    // A run announced by a checkout this window has never opened: the desk is
    // the one surface that still shows it, and its row is the way there.
    RunHandle(
      worktree: '/repo-explorer',
      worktreeName: 'feature-explorer',
      device: 'phone',
      entrypoint: 'lib/main.dart',
      entrypointName: 'App',
      launcherPid: 1,
      startedAt: DateTime.now(),
    ).publish(runDir.path);

    var shell = await _pumpShell(tester);
    await tester.tap(find.byType(DeskButton));
    await tester.pumpAndSettle();

    expect(find.text('Xavier iPhone'), findsOneWidget);
    expect(find.text('App · feature-explorer'), findsOneWidget);

    // The jump lands on the run's own page in the worktree that can drive
    // it — opening that worktree, since it was closed.
    await tester.tap(find.text('App · feature-explorer'));
    await tester.pumpAndSettle();

    expect(shell.selected?.path, '/repo-explorer');
    expect(shell.address.plugin, runPluginId);
  });

  testWidgets('the desk points at the panel it cannot be', (tester) async {
    // This menu reads files and starts no daemon, so it can say a device is
    // free and can never offer to use it. The Run panel is where booting,
    // refreshing and launching live, and until this row existed the two
    // surfaces over the same machines read as unrelated lists.
    var runDir = Directory.systemTemp.createTempSync('fw-desk-');
    DeskButton.runDirProvider = () => runDir.path;
    addTearDown(() {
      DeskButton.runDirProvider = flutterwareRunDir;
      runDir.deleteSync(recursive: true);
    });
    DeviceCache.write(runDir.path, const [
      DaemonDevice(id: 'phone', name: 'Xavier iPhone'),
    ]);

    var shell = await _pumpShell(tester);
    await tester.tap(find.byType(DeskButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start one, or boot an emulator'));
    await tester.pumpAndSettle();

    // The plugin's own page — no run named, which is what the panel reads as
    // *the page that starts one*.
    expect(shell.address.plugin, runPluginId);
    expect(shell.address.segments, isEmpty);
  });

  testWidgets('mounts the selected plugin panel and switches', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.text('Dependencies'));
    await tester.pumpAndSettle();

    expect(find.text('panel:a.deps/-'), findsOneWidget);
    expect(find.text('panel:a.tests/-'), findsNothing);

    await tester.tap(find.text('Tests'));
    await tester.pumpAndSettle();

    expect(find.text('panel:a.tests/-'), findsOneWidget);
    expect(find.text('panel:a.deps/-'), findsNothing);
  });

  testWidgets('a panel is given every segment below the plugin', (
    tester,
  ) async {
    // The bug this contract was widened for: an address naming a package *and*
    // an entry used to reach the panel as the package alone, so a search hit
    // opened the right plugin showing the wrong thing.
    var shell = await _pumpShell(tester);

    shell.go(
      Address(
        worktree: '~',
        plugin: 'a.deps',
        segments: ['app', 'demo/avatar.dart#members'],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('panel:a.deps/app/demo/avatar.dart#members'),
      findsOneWidget,
    );
  });

  testWidgets('moving within a plugin does not remount its panel', (
    tester,
  ) async {
    // A compile loop lives in the panel's plugin; remounting for a click in its
    // own tree would tear one down and start another.
    var shell = await _pumpShell(tester);
    shell.selectChild('a.deps', 'app');
    await tester.pumpAndSettle();
    var before = tester.state(find.byType(Scaffold));

    shell.selectChild('a.deps', 'fixtures/probe_app');
    await tester.pumpAndSettle();

    expect(find.text('panel:a.deps/fixtures/probe_app'), findsOneWidget);
    expect(tester.state(find.byType(Scaffold)), same(before));
  });

  testWidgets('the switcher lists worktrees that are not open', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();

    expect(find.text('OPEN · 1'), findsOneWidget);
    expect(find.text('NOT OPEN · 1'), findsOneWidget);
    expect(find.text('feature/explorer'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('a long status yields to the worktree name in the switcher', (
    tester,
  ) async {
    // What a plugin forwarding a log line did to this row: the status took
    // its natural width, the name column collapsed to a few pixels, and
    // `main` came down the menu one letter per line.
    var shell = ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: _panels(const ['a.deps', 'a.tests']),
      coreRegistry: PluginCoreRegistry({
        'a.deps': (h) => _FakeCore(
          h,
          status: const Status.info(
            '[tester] flutterware previews harness ready — 133 entries, '
            'fonts: MaterialIcons',
          ),
        ),
        'a.tests': _FakeCore.new,
      }),
      manifestLoader: _StubLoader(),
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, _listing, ''),
      ),
    );
    await shell.start('/repo');
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();

    var row = find.byKey(switcherRowKey(shell.worktrees.first));
    var name = find.descendant(of: row, matching: find.text('main'));
    expect(name, findsOneWidget);
    // Laid out on one line — the letter-per-line column was four of them.
    expect(tester.getSize(name).height, lessThan(24));
    // And the status took a slice of the row rather than the row.
    var said = find.descendant(
      of: row,
      matching: find.textContaining('[tester]'),
    );
    expect(tester.getSize(said).width, lessThanOrEqualTo(120));
  });

  testWidgets('opening from the switcher adds a tab', (tester) async {
    var shell = await _pumpShell(tester);

    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feature/explorer'));
    await tester.pumpAndSettle();

    expect(shell.openWorktrees, hasLength(2));
    expect(find.byKey(worktreeTabKey(shell.worktrees.last)), findsOneWidget);
  });

  testWidgets('the switcher filters, and an emptied section disappears', (
    tester,
  ) async {
    await _pumpShell(tester);
    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'expl');
    await tester.pumpAndSettle();

    // `main` matched nothing, so the OPEN section has nothing to head.
    expect(find.text('OPEN · 1'), findsNothing);
    expect(find.text('NOT OPEN · 1'), findsOneWidget);
    expect(find.text('feature/explorer'), findsOneWidget);
  });

  testWidgets('a branch that moved under an open tab is still findable', (
    tester,
  ) async {
    // The report: a branch the worktrees screen listed could not be found in
    // the switcher, in the same window at the same moment. The checkout was
    // open, and an open tab used to keep the worktree it was opened with — so
    // the filter searched the name the branch had that morning.
    var listing = _listing;
    _loader = _StubLoader();
    var shell = ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: _panels(const ['a.deps', 'a.tests']),
      coreRegistry: PluginCoreRegistry({
        'a.deps': _FakeCore.new,
        'a.tests': _FakeCore.new,
      }),
      manifestLoader: _loader,
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, listing, ''),
      ),
    );
    await shell.start('/repo');
    await shell.open(shell.closedWorktrees.first);
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();
    expect(find.text('feature/explorer'), findsWidgets);

    // The agent working in that checkout moved it to another branch.
    listing =
        'worktree /repo\nbranch refs/heads/main\n\n'
        'worktree /repo-explorer\nbranch refs/heads/claude/split-button-rework\n';

    // Opening the switcher rescans, which is what makes the menu current.
    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'claude/split-button-rework',
    );
    await tester.pumpAndSettle();

    expect(find.text('No worktree matches.'), findsNothing);
    expect(find.text('OPEN · 1'), findsOneWidget);
    // And the tab behind the menu says the new name too.
    expect(find.text('feature/explorer'), findsNothing);
  });

  testWidgets('↵ in the switcher filter opens the first match', (tester) async {
    var shell = await _pumpShell(tester);
    await tester.tap(find.byTooltip('Switch worktree'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'expl');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(shell.openWorktrees, hasLength(2));
  });

  testWidgets('closing a tab removes it and releases the session', (
    tester,
  ) async {
    var shell = await _pumpShell(tester);
    await shell.open(shell.closedWorktrees.first);
    await tester.pumpAndSettle();
    expect(shell.openWorktrees, hasLength(2));

    // The second tab's close button. Scrolled to first: the tab strip is a
    // horizontal ListView by design, and at the 800px test surface a second
    // tab no longer fits beside the rest of the band.
    var close = find.byIcon(Icons.close).last;
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pumpAndSettle();

    expect(shell.openWorktrees, hasLength(1));
    expect(find.byKey(worktreeTabKey(shell.worktrees.last)), findsNothing);
  });

  group('children', () {
    ShellController childShell() => ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: _panels(const ['a.deps', 'a.tests']),
      coreRegistry: PluginCoreRegistry({
        'a.deps': (h) => _FakeCore(
          h,
          status: const Status.neutral('2 packages'),
          children: const [
            PluginChild(id: 'app', label: 'app', status: Status.neutral('58')),
            PluginChild(id: 'ui', label: 'ui', status: Status.error('failed')),
          ],
        ),
        'a.tests': _FakeCore.new,
      }),
      manifestLoader: _StubLoader(),
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, _listing, ''),
      ),
    );

    testWidgets('a long status cannot squeeze out the name', (tester) async {
      var shell = ShellController(
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/tmp/flutter'),
        registry: _panels(const ['a.deps', 'a.tests']),
        coreRegistry: PluginCoreRegistry({
          'a.deps': (h) => _FakeCore(
            h,
            children: const [
              PluginChild(
                id: 'fixtures/probe_app',
                label: 'fixtures/probe_app',
                status: Status.warn('10 assets · 347 kB · 2 problems'),
              ),
            ],
          ),
          'a.tests': _FakeCore.new,
        }),
        manifestLoader: _StubLoader(),
        discovery: WorktreeDiscovery(
          runProcess: (_, _, {workingDirectory}) async =>
              ProcessResult(0, 0, _listing, ''),
        ),
      );
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      // The row used to give the status all the width it asked for, leaving
      // the `Expanded` label at zero — a row that says how much and not *what*.
      var label = find.descendant(
        of: find.byKey(sidebarKey),
        matching: find.text('fixtures/probe_app'),
      );
      expect(label, findsOneWidget);
      expect(tester.getSize(label).width, greaterThan(0));
    });

    testWidgets('expands under the selected plugin only', (tester) async {
      var shell = childShell();
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      // Children show only under the selected plugin, with their status.
      // Scoped to the rail: `app` is also a segment of the address, which the
      // bar along the bottom now spells out.
      var inRail = find.descendant(
        of: find.byKey(sidebarKey),
        matching: find.text('app'),
      );
      expect(inRail, findsOneWidget);
      expect(find.text('58'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);

      // Selecting the other plugin collapses them.
      await tester.tap(find.text('Tests'));
      await tester.pumpAndSettle();
      expect(inRail, findsNothing);
    });

    testWidgets('the first child is selected with its plugin', (tester) async {
      var shell = childShell();
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      expect(shell.selectedChildId, 'app');
      expect(find.text('panel:a.deps/app'), findsOneWidget);
    });

    testWidgets('a row does not repeat what the row under it is saying', (
      tester,
    ) async {
      // Previews reduces to whatever its busy package reports, so a compile
      // used to write `compiling` twice, one line directly above the other.
      var shell = ShellController(
        appContext: AppContext(logger: LogClient.print()),
        flutterSdk: FlutterSdkPath('/tmp/flutter'),
        registry: _panels(const ['a.deps', 'a.tests']),
        coreRegistry: PluginCoreRegistry({
          'a.deps': (h) => _FakeCore(
            h,
            status: const Status.info('compiling'),
            children: const [
              PluginChild(
                id: 'app',
                label: 'app',
                status: Status.info('compiling'),
              ),
            ],
          ),
          'a.tests': _FakeCore.new,
        }),
        manifestLoader: _StubLoader(),
        discovery: WorktreeDiscovery(
          runProcess: (_, _, {workingDirectory}) async =>
              ProcessResult(0, 0, _listing, ''),
        ),
      );
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();

      var word = find.descendant(
        of: find.byKey(sidebarKey),
        matching: find.text('compiling'),
      );
      // Collapsed, the plugin row is the only thing that can say it.
      expect(word, findsOneWidget);

      // Expanded, the child says it and the row above goes quiet — still once.
      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();
      expect(word, findsOneWidget);
      expect(
        find.descendant(of: find.byKey(sidebarKey), matching: find.text('app')),
        findsOneWidget,
        reason: 'the child is the one still saying it',
      );
    });

    testWidgets('but a summary no child makes survives the expansion', (
      tester,
    ) async {
      // The other half of the rule, and what keeps it from hiding anything: a
      // parent status is suppressed on an exact match, not on having children.
      var shell = childShell();
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      expect(find.text('2 packages'), findsOneWidget);
    });

    testWidgets('selecting a child switches the panel', (tester) async {
      var shell = childShell();
      await shell.start('/repo');
      await tester.pumpWidget(ShellApp(shell));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dependencies'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ui'));
      await tester.pumpAndSettle();

      expect(shell.selectedChildId, 'ui');
      expect(find.text('panel:a.deps/ui'), findsOneWidget);
    });
  });

  testWidgets('a panel may start work in initState without crashing', (
    tester,
  ) async {
    var shell = ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: PluginRegistry({
        'a.deps': panelFor<_EagerCore>(_EagerPanelPlugin.new),
      }),
      coreRegistry: PluginCoreRegistry({'a.deps': _EagerCore.new}),
      manifestLoader: _StubLoader(),
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, _listing, ''),
      ),
    );
    await shell.start('/repo');
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dependencies'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('eager'), findsOneWidget);
    // The deferred notification still lands.
    expect(find.text('tracking'), findsOneWidget);
  });

  testWidgets('a worktree with no plugins explains itself', (tester) async {
    var shell = ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: PluginRegistry(),
      manifestLoader: _EmptyLoader(),
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, _listing, ''),
      ),
    );
    await shell.start('/repo');
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    expect(find.textContaining('No plugins declared'), findsOneWidget);
  });

  testWidgets('a long worktree name does not stretch its tab', (tester) async {
    // A tab wide enough to hold the whole name is a tab wide enough to push
    // the switcher off screen; the tooltip is where the full name lives.
    var shell = _controller(
      listing:
          'worktree /repo/a-very-long-worktree-name-that-keeps-going-and-going\n'
          'branch refs/heads/main\n\n',
    );
    await shell.start(
      '/repo/a-very-long-worktree-name-that-keeps-going-and-going',
    );
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    var label = find.descendant(
      of: find.byKey(worktreeTabKey(shell.worktrees.first)),
      matching: find.byType(Text),
    );
    expect(tester.getSize(label.first).width, lessThanOrEqualTo(180));
  });

  testWidgets('a status arriving on a tab moves nothing', (tester) async {
    // The dot used to be inserted into the tab's row, so it arrived by
    // *widening* the tab: the branch name shifted along and re-ellipsised to
    // announce something that is often over in a tenth of a second. Measured
    // on the real studio before the fix — a 121ms reload took the tab from
    // 224px to 237px and back.
    late _FakeCore deps;
    var shell = ShellController(
      appContext: AppContext(logger: LogClient.print()),
      flutterSdk: FlutterSdkPath('/tmp/flutter'),
      registry: _panels(const ['a.deps', 'a.tests']),
      coreRegistry: PluginCoreRegistry({
        'a.deps': (h) => deps = _FakeCore(h),
        'a.tests': _FakeCore.new,
      }),
      manifestLoader: _StubLoader(),
      discovery: WorktreeDiscovery(
        runProcess: (_, _, {workingDirectory}) async =>
            ProcessResult(0, 0, _listing, ''),
      ),
    );
    await shell.start('/repo');
    await tester.pumpWidget(ShellApp(shell));
    await tester.pumpAndSettle();

    var worktree = shell.worktrees.first;
    var tab = find.byKey(worktreeTabKey(worktree));
    var label = find.descendant(of: tab, matching: find.byType(Text)).first;
    var quietTab = tester.getRect(tab);
    var quietLabel = tester.getRect(label);
    expect(shell.sessionFor(worktree)!.status.tone, Tone.neutral);

    deps.say(const Status.error('3 failing'));
    await tester.pumpAndSettle();

    expect(
      shell.sessionFor(worktree)!.status.tone,
      Tone.error,
      reason: 'the tab has something to show now, or this proves nothing',
    );
    expect(tester.getRect(tab), quietTab);
    expect(tester.getRect(label), quietLabel);
  });

  testWidgets('clickable rows take the pointer cursor', (tester) async {
    await _pumpShell(tester);

    var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(() => mouse.removePointer());
    await tester.pump();

    await mouse.moveTo(tester.getCenter(find.text('Overview')));
    await tester.pump();

    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
      reason: 'a row that does not answer the mouse reads as decoration',
    );
  });

  testWidgets('the sidebar can be hidden and brought back', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpShell(tester);
    expect(find.text('Overview'), findsOneWidget);

    var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    /// The chevron is on the rail's seam and only under the pointer, so a test
    /// has to go and hover it like a hand would.
    Future<void> hover(Offset where) async {
      await mouse.moveTo(where);
      await tester.pumpAndSettle();
    }

    await hover(const Offset(defaultSidebarWidth - 4, 400));
    await tester.tap(find.byTooltip(RegExp('Hide the sidebar')));
    await tester.pumpAndSettle();
    expect(
      find.text('Overview'),
      findsNothing,
      reason: 'the rail goes to nothing, not to a strip',
    );

    // And the way back is where the rail was, not in the chrome.
    expect(find.byTooltip(RegExp('Show the sidebar')), findsNothing);
    await hover(const Offset(4, 400));
    await tester.tap(find.byTooltip(RegExp('Show the sidebar')));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);
  });

  testWidgets('the rail can be dragged wider, and the minimum follows it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = await _pumpShell(tester);
    expect(tester.getSize(find.byKey(sidebarKey)).width, defaultSidebarWidth);

    // From the seam itself, which is where the handle sits. The first 20 of the
    // 80 go to the touch slop, as they would under a real finger.
    await tester.dragFrom(
      const Offset(defaultSidebarWidth - 4, 400),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(shell.sidebarWidth, defaultSidebarWidth + 60);
    expect(
      tester.getSize(find.byKey(sidebarKey)).width,
      defaultSidebarWidth + 60,
    );

    // And the window it refuses to go below went with it: a wider rail is a
    // wider window, because the pane's floor is not the rail's to spend.
    tester.view.physicalSize = const Size(1100, 800);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      moreOrLessEquals(
        shellPaneMinimumSize.width + shell.sidebarWidth,
        epsilon: 0.01,
      ),
    );
  });

  testWidgets('and it can still be dragged once the window is scaling', (
    tester,
  ) async {
    // 900 is short of 848 + the rail, so the app is already scaled: by the
    // measure that used to bound the drag there is no room here at all, and the
    // seam would not move.
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = await _pumpShell(tester);
    var scale = 900 / tester.getSize(find.byType(MaterialApp)).width;
    expect(scale, lessThan(1), reason: 'the premise of this test');

    // In window pixels, which is what a pointer moves in: the seam is at the
    // rail's edge times the scale.
    await tester.dragFrom(
      Offset(defaultSidebarWidth * scale - 2, 400),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    // How much it grew depends on the scale, which the growth itself changes —
    // that it grew at all is the whole of the claim.
    expect(shell.sidebarWidth, greaterThan(defaultSidebarWidth));
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      moreOrLessEquals(
        shellPaneMinimumSize.width + shell.sidebarWidth,
        epsilon: 0.01,
      ),
      reason: 'the minimum kept following it, so the app scaled a bit further',
    );
  });

  testWidgets('the rail can be dragged narrower than a label needs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = await _pumpShell(tester);
    await tester.dragFrom(
      const Offset(defaultSidebarWidth - 4, 400),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();

    expect(shell.sidebarWidth, minSidebarWidth);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the rows ellipsise rather than overflowing',
    );
    expect(
      find.text('Overview'),
      findsOneWidget,
      reason: 'still a rail, however little of each word is left',
    );
  });

  testWidgets('the band clears the traffic lights at any scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    /// Where the band's content starts. `getTopLeft` is global, so it comes
    /// back in the *window's* pixels with the scale already applied — which is
    /// the space the traffic lights are drawn in, and the only one they can be
    /// cleared in.
    Future<double> bandStartsAt(Size window) async {
      tester.view.physicalSize = window;
      await _pumpShell(tester);
      return tester.getTopLeft(find.byKey(bandContentKey)).dx;
    }

    expect(
      await bandStartsAt(const Size(1200, 800)),
      moreOrLessEquals(78, epsilon: 0.01),
    );
    expect(
      await bandStartsAt(const Size(900, 700)),
      moreOrLessEquals(78, epsilon: 0.01),
      reason:
          'the buttons are the window and keep their size, so a band at 0.83 '
          'reserving 78 of its own pixels would be reserving 65 of theirs',
    );
  });

  testWidgets('hiding the rail stops the window being scaled for it', (
    tester,
  ) async {
    // Room for the pane's 848 and not for the rail as well: the one window
    // where the difference is visible.
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = await _pumpShell(tester);
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      moreOrLessEquals(1080, epsilon: 0.01),
      reason: 'the rail is drawn, so the window is short of it and scales',
    );

    shell.toggleSidebar();
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      900,
      reason:
          'nothing is charged for the rail that is not there — 900 clears the '
          'pane on its own, so ⌘B gives back the room *and* the scale',
    );
  });

  testWidgets('cmd+B works without clicking the window first', (tester) async {
    // The binding existed but nothing in the shell held focus, so key events
    // went to the root scope — an ancestor of the shortcuts, never a
    // descendant — and no binding was reached until something was clicked.
    await _pumpShell(tester);
    expect(find.text('Overview'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsNothing);
  });

  group('search', () {
    /// Scoped to the palette: the sidebar shows the same plugin names, so an
    /// unscoped finder would pass whether the palette opened or not.
    Finder inPalette(String text) => find.descendant(
      of: find.byType(CommandPalette),
      matching: find.text(text, findRichText: true),
    );

    testWidgets('the trigger opens it', (tester) async {
      await _pumpShell(tester);
      expect(find.byType(CommandPalette), findsNothing);

      await tester.tap(find.byType(SearchTrigger));
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsOneWidget);
      expect(inPalette('Type to search'), findsOneWidget);
    });

    testWidgets('cmd+K opens it', (tester) async {
      await _pumpShell(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsOneWidget);
    });

    testWidgets('typing finds a plugin by name', (tester) async {
      await _pumpShell(tester);
      await tester.tap(find.byType(SearchTrigger));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'depend');
      await tester.pumpAndSettle();

      expect(inPalette('Dependencies'), findsOneWidget);
      expect(
        inPalette('Tests'),
        findsNothing,
        reason: 'the query filters; it does not just list everything',
      );
    });

    testWidgets('a hit navigates to its plugin and closes', (tester) async {
      await _pumpShell(tester);
      expect(find.text('panel:a.deps/-'), findsNothing);

      await tester.tap(find.byType(SearchTrigger));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'depend');
      await tester.pumpAndSettle();

      await tester.tap(inPalette('Dependencies'));
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsNothing);
      expect(
        find.text('panel:a.deps/-'),
        findsOneWidget,
        reason: 'the address is the instruction — it selected the plugin',
      );
    });

    testWidgets('escape closes without navigating', (tester) async {
      await _pumpShell(tester);
      await tester.tap(find.byType(SearchTrigger));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsNothing);
      expect(find.text('panel:a.deps/-'), findsNothing);
      expect(find.text('Overview'), findsOneWidget);
    });

    testWidgets('a query that matches nothing says so', (tester) async {
      await _pumpShell(tester);
      await tester.tap(find.byType(SearchTrigger));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();

      expect(inPalette('No results for “zzzz”'), findsOneWidget);
    });
  });

  group('the config surfaces', () {
    /// Scoped, so a phrase found somewhere else on screen cannot pass for the
    /// band line saying it.
    Finder inLine(String text) => find.descendant(
      of: find.byKey(configLoadLineKey),
      matching: find.textContaining(text),
    );
    Finder inBanner(String text) => find.descendant(
      of: find.byKey(configErrorBannerKey),
      matching: find.textContaining(text),
    );
    Finder inConfig(String text) => find.descendant(
      of: find.byKey(configScreenKey),
      matching: find.textContaining(text),
    );
    Future<void> openConfig(WidgetTester tester) async {
      await tester.tap(find.byKey(configButtonKey));
      await tester.pumpAndSettle();
    }

    const changedTests =
        '{"version":1,"plugins":['
        '{"id":"a.deps","label":"Dependencies"},'
        '{"id":"a.tests","label":"Tests","config":{"dir":"unit"}}]}';

    testWidgets('opening a worktree says nothing in the band', (tester) async {
      var shell = await _pumpShell(tester);

      // The tab appearing is already the feedback; announcing it would make
      // every worktree switch chatty. It still reaches the terminal.
      expect(find.byKey(configLoadLineKey), findsNothing);
      expect(shell.lastLoad(shell.selected!)!.outcome, ConfigLoadOutcome.built);
    });

    testWidgets('the band button navigates rather than reloading', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      var before = shell.lastLoad(shell.selected!);

      await openConfig(tester);

      expect(shell.isConfigScreen, isTrue);
      expect(shell.isHome, isFalse);
      expect(shell.selectedPluginId, isNull, reason: 'config is not a plugin');
      expect(shell.address.plugin, 'config');
      expect(
        identical(shell.lastLoad(shell.selected!), before),
        isTrue,
        reason: 'clicking it must not re-run the config any more',
      );
    });

    testWidgets('Reload on the screen re-runs the config', (tester) async {
      var shell = await _pumpShell(tester);
      await openConfig(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Reload'));
      await tester.pumpAndSettle();

      expect(
        shell.lastLoad(shell.selected!)!.outcome,
        ConfigLoadOutcome.unchanged,
      );
      expect(inLine('no changes'), findsOneWidget);
    });

    testWidgets('the screen names the directory it watches', (tester) async {
      await _pumpShell(tester);
      await openConfig(tester);

      // This harness's worktree path is not a real directory, so there is
      // genuinely nothing to watch — and saying so is the point. "It did not
      // notice my edit" is the standard complaint about file watching, and the
      // standard cause is a watched set that does not contain what you edited.
      expect(inConfig('Nothing to watch'), findsOneWidget);
    });

    testWidgets('the screen says what the config resolved to', (tester) async {
      await _pumpShell(tester);
      await openConfig(tester);

      expect(inConfig('Resolved'), findsOneWidget);
      expect(inConfig('a.deps'), findsOneWidget);
      expect(inConfig('a.tests'), findsOneWidget);
    });

    testWidgets('an address naming the config screen lands on it', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);

      shell.go(Address(worktree: shell.selected!.name, plugin: 'config'));
      await tester.pumpAndSettle();

      expect(find.byKey(configScreenKey), findsOneWidget);
    });

    testWidgets('a reload that changed nothing still says so', (tester) async {
      var shell = await _pumpShell(tester);

      await shell.reloadConfig();
      await tester.pump();

      // The whole point: silence would be indistinguishable from a reload that
      // never fired.
      expect(inLine('no changes'), findsOneWidget);
    });

    testWidgets('the line says what the reload did, then fades', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);

      _loader.manifest = changedTests;
      await shell.reloadConfig();
      await tester.pump();

      expect(inLine('rebuilt, 2 plugins'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(configLoadLineKey), findsNothing);
    });

    testWidgets('a faded line does not return on an unrelated notification', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);

      _loader.manifest = changedTests;
      await shell.reloadConfig();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(configLoadLineKey), findsNothing);

      // Anything that notifies the shell — a plugin finishing a load, a save
      // some plugin watched, navigation — used to find `lastLoad` still
      // recorded and the line hidden, and put the old load back up for another
      // four seconds. From the outside that is a config re-running on every
      // unrelated edit.
      await openConfig(tester);

      expect(find.byKey(configLoadLineKey), findsNothing);
      expect(
        shell.lastLoad(shell.selected!)!.outcome,
        ConfigLoadOutcome.rebuilt,
        reason: 'still recorded — it is the announcing that must not repeat',
      );
    });

    testWidgets('a failed load shows a banner and keeps the plugins', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      var before = shell.selectedSession!.plugins.first;

      _loader.broken = true;
      await shell.reloadConfig();
      await tester.pumpAndSettle();

      expect(inBanner('exited with 1'), findsOneWidget);
      // Still there, still the same objects — the banner is the only symptom.
      expect(identical(shell.selectedSession!.plugins.first, before), isTrue);

      // The compiler's own output is not duplicated into the band; Details
      // goes to the one screen that renders it.
      expect(inBanner("Expected ';'"), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(configErrorBannerKey),
          matching: find.text('Details'),
        ),
      );
      await tester.pumpAndSettle();

      expect(shell.isConfigScreen, isTrue);
      expect(inConfig("Expected ';'"), findsOneWidget);
      // And it is redundant while you are looking at the explanation.
      expect(find.byKey(configErrorBannerKey), findsNothing);
    });

    testWidgets('the band button shows a dot while the config is failing', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      _loader.broken = true;
      await shell.reloadConfig();
      await tester.pumpAndSettle();

      var button = find.byKey(configButtonKey);
      expect(
        find.descendant(of: button, matching: find.byType(Stack)),
        findsOneWidget,
      );
      expect(shell.errorFor(shell.selected!), isNotNull);
    });

    testWidgets('the banner clears when a load succeeds', (tester) async {
      var shell = await _pumpShell(tester);

      _loader.broken = true;
      await shell.reloadConfig();
      await tester.pumpAndSettle();
      expect(find.byKey(configErrorBannerKey), findsOneWidget);

      _loader.broken = false;
      await shell.reloadConfig();
      await tester.pumpAndSettle();
      expect(find.byKey(configErrorBannerKey), findsNothing);
    });
  });

  /// The screen that renders for a checkout nobody has opened. Every other
  /// place in the window needs a session; this one reads git, so the chrome
  /// around it has to admit that there is no tab to be in.
  group('the changes screen, on a closed worktree', () {
    setUp(() {
      debugChangesLoader = (path) async => ChangeSet(
        worktreePath: path,
        patch: PatchIndex.empty,
        files: const [
          FileChange(
            path: 'lib/agent_wrote_this.dart',
            status: ChangeStatus.added,
            added: 12,
            removed: 0,
            hunks: [],
            byteStart: 0,
            byteEnd: 0,
          ),
        ],
        base: 'main',
        baseSource: BaseSource.inferred,
      );
      addTearDown(() => debugChangesLoader = null);
    });

    testWidgets('draws without opening the checkout', (tester) async {
      var shell = await _pumpShell(tester);
      var closed = shell.closedWorktrees.single;

      shell.selectChanges(closed);
      await tester.pumpAndSettle();

      expect(find.byKey(changesScreenKey), findsOneWidget);
      expect(find.text('agent_wrote_this.dart'), findsOneWidget);
      expect(shell.isOpen(closed), isFalse, reason: 'and still no tab for it');
      expect(find.byKey(worktreeTabKey(closed)), findsNothing);
    });

    testWidgets('picking a file in it reaches the address bar', (tester) async {
      // **Pumped through the shell, not on its own**, which is the lesson of
      // the keyboard this screen briefly had: it worked in every test that
      // built the panel directly and did nothing in a window, because the
      // shell around it was taking the keys first. A panel tested only in
      // isolation is a panel tested against a stage set.
      var shell = await _pumpShell(tester);
      var closed = shell.closedWorktrees.single;
      shell.selectChanges(closed);
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byKey(changesListKey),
          matching: find.text('agent_wrote_this.dart'),
        ),
      );
      await tester.pumpAndSettle();

      expect(shell.address.segments, ['lib', 'agent_wrote_this.dart']);
      expect(
        find.descendant(
          of: find.byKey(changesFileKey),
          matching: find.textContaining('No text changed'),
        ),
        findsOneWidget,
        reason: 'and the right pane is showing that file',
      );
    });

    testWidgets('hides the rail, since there is no session to list', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      expect(find.byKey(sidebarKey), findsOneWidget);

      shell.selectChanges(shell.closedWorktrees.single);
      await tester.pumpAndSettle();

      expect(find.byKey(sidebarKey), findsNothing);

      // And the window preference was not clobbered on the way through: going
      // back to a checkout with a session brings the rail with it.
      shell.select(shell.worktrees.first);
      await tester.pumpAndSettle();
      expect(find.byKey(sidebarKey), findsOneWidget);
    });

    testWidgets('lights the pinned tab, because this is that space', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);

      shell.selectChanges(shell.closedWorktrees.single);
      await tester.pumpAndSettle();

      expect(shell.inWorktreesSpace, isTrue);
      expect(find.byKey(explorerTabKey), findsOneWidget);
    });

    testWidgets('escape goes back to the list', (tester) async {
      var shell = await _pumpShell(tester);
      shell.selectChanges(shell.closedWorktrees.single);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(shell.isExplorer, isTrue);
    });

    testWidgets('the same address inside an open checkout keeps its rail', (
      tester,
    ) async {
      var shell = await _pumpShell(tester);
      var other = shell.closedWorktrees.single;
      await shell.open(other);
      await tester.pumpAndSettle();

      shell.selectChanges(other);
      await tester.pumpAndSettle();

      expect(find.byKey(changesScreenKey), findsOneWidget);
      expect(
        find.byKey(sidebarKey),
        findsOneWidget,
        reason: 'an open checkout has plugins to list',
      );
      expect(shell.inWorktreesSpace, isFalse);
    });
  });
}

class _EmptyLoader implements ManifestLoader {
  @override
  String? get flutterRoot => null;

  @override
  Future<PluginManifest?> load(String path) async => null;

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async => (manifest: null, error: null);

  @override
  String get dartExecutable => 'dart';

  @override
  Duration get timeout => Duration.zero; // Unused: no stub spawns a process.
}
