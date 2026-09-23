import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/log_client.dart';
import 'package:flutterware_app/src/context.dart';
import 'package:flutterware_app/src/plugins/manifest_loader.dart';
import 'package:flutterware_app/src/plugins/plugin_core.dart';
import 'package:flutterware_app/src/plugins/registry.dart';
import 'package:flutterware_app/src/shell/shell_controller.dart';
import 'package:flutterware_app/src/shell/shell_view.dart';
import 'package:flutterware_app/src/shell/worktree_discovery.dart';
import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:flutterware_app/src/worktrees/facts.dart';
import 'package:flutterware_app/src/worktrees/facts_controller.dart';
import 'package:flutterware_app/src/worktrees/facts_probe.dart';
import 'package:flutterware_app/src/worktrees/facts_store.dart';
import 'package:flutterware_app/src/worktrees/providers/agent.dart';
import 'package:flutterware_app/src/worktrees/providers/forge.dart';
import 'package:flutterware_app/src/worktrees/providers/git.dart';
import 'package:flutterware_app/src/worktrees/watchers.dart';
import 'package:path/path.dart' as p;

const _listing =
    'worktree /repo\nbranch refs/heads/main\n\n'
    'worktree /repo-explorer\nbranch refs/heads/feature/explorer\n';

/// A probe with no git, no `~/.claude` and no home directory behind it.
///
/// The store especially: the default writes to the developer's real
/// `~/.flutterware`, and opening a worktree records a clock — so a shell test
/// without this injected is a test that edits your home directory.
class _StubAgent implements AgentProbe {
  _StubAgent(this.waiting);

  final bool waiting;
  var calls = 0;

  @override
  Future<AgentFacts?> probe(String worktreePath) async =>
      _counted(worktreePath);

  AgentFacts _counted(String worktreePath) {
    calls++;
    return AgentFacts(
      state: waiting && worktreePath == '/repo-explorer'
          ? AgentState.waiting
          : AgentState.none,
      title: 'Something being worked on',
      at: DateTime(2026, 8, 10, 14),
    );
  }
}

/// A forge that never leaves the process, and counts what it was asked.
class _StubForge implements ForgeProbe {
  var calls = 0;

  @override
  Future<ForgeReport> probe(String repoRoot) async {
    calls++;
    // Green on purpose: a failing check is a `needsYou`, and the badge test
    // next door is about the agent. What makes the badge light up is pinned in
    // facts_probe_test, where it costs no widgets.
    return const ForgeReport.ready({
      'feature/explorer': ForgeFacts(
        number: 79,
        title: 'The explorer is a place in the shell',
        state: PrState.open,
        checks: ChecksState.passing,
      ),
    });
  }
}

/// A config that declares no plugins. The explorer is shell chrome and does not
/// go through one, which is the point — a closed worktree has no session at all.
class _StubLoader implements ManifestLoader {
  @override
  String? get flutterRoot => null;

  @override
  Future<PluginManifest?> load(String path) async => const PluginManifest([]);

  @override
  Future<({PluginManifest? manifest, String? error})> tryLoad(
    String path,
  ) async => (manifest: await load(path), error: null);

  @override
  String get dartExecutable => 'dart';

  @override
  Duration get timeout => Duration.zero;
}

late Directory _temp;
late _StubForge _forge;
late _StubAgent _agent;
late Directory _watchedRepo;
late StreamController<String> _gitEvents;
late StreamController<String> _agentEvents;
late int _discoveries;

/// The real watcher, with its filesystem replaced.
///
/// Not a fake: the coalescing rules are the part that decides how often the
/// screen refreshes, and a fake would have tested a mock of them. What is
/// substituted is only where the paths come from.
WorktreeWatcher _watcher(String _) => WorktreeWatcher(
  repoRoot: _watchedRepo.path,
  agentRoot: p.join(_watchedRepo.path, 'agents'),
  debounce: Duration.zero,
  minInterval: Duration.zero,
  watch: (path, {required recursive}) =>
      path.contains('agents') ? _agentEvents.stream : _gitEvents.stream,
);

ShellController _controller({bool agentWaiting = false}) => ShellController(
  appContext: AppContext(logger: LogClient.print()),
  flutterSdk: FlutterSdkPath('/tmp/flutter'),
  registry: PluginRegistry(),
  coreRegistry: PluginCoreRegistry(),
  manifestLoader: _StubLoader(),
  discovery: WorktreeDiscovery(
    runProcess: (_, _, {workingDirectory}) async {
      _discoveries++;
      return ProcessResult(0, 0, _listing, '');
    },
  ),
  worktreeWatcher: _watcher,
  worktreeFacts: (root) => WorktreeFactsController(
    repoRoot: root,
    probe: WorktreeFactsProbe(
      repoRoot: root,
      store: WorktreeFactsStore.open(
        root,
        at: File('${_temp.path}/worktrees.json'),
      ),
      agent: _agent = _StubAgent(agentWaiting),
      forge: _forge,
      git: GitProbe(
        runProcess: (_, arguments, {workingDirectory}) async => ProcessResult(
          0,
          0,
          arguments.contains('status')
              ? '# branch.oid abc\n# branch.head feature/explorer\n'
              : '',
          '',
        ),
      ),
    ),
  ),
);

Future<ShellController> _pump(
  WidgetTester tester, {
  bool agentWaiting = false,
}) async {
  var shell = _controller(agentWaiting: agentWaiting);
  await shell.start('/repo');
  await tester.pumpWidget(ShellApp(shell));
  await tester.pumpAndSettle();
  return shell;
}

void main() {
  setUp(() {
    _temp = Directory.systemTemp.createTempSync('fw-explorer-test');
    _forge = _StubForge();
    _agent = _StubAgent(false);
    _discoveries = 0;
    _gitEvents = StreamController<String>.broadcast();
    _agentEvents = StreamController<String>.broadcast();
    _watchedRepo = Directory('${_temp.path}/watched')..createSync();
    for (var dir in ['.git/worktrees', '.git/refs/heads', 'agents']) {
      Directory('${_watchedRepo.path}/$dir').createSync(recursive: true);
    }
  });

  tearDown(() {
    unawaited(_gitEvents.close());
    unawaited(_agentEvents.close());
  });
  tearDown(() => _temp.deleteSync(recursive: true));

  testWidgets('the explorer tab is pinned and cannot be closed', (
    tester,
  ) async {
    var shell = await _pump(tester);

    expect(find.byKey(explorerTabKey), findsOneWidget);
    // A worktree tab carries a close button; a pinned one must not, because
    // there is nothing to close and the band would be offering a dead control.
    expect(
      find.descendant(
        of: find.byKey(explorerTabKey),
        matching: find.byIcon(Icons.close),
      ),
      findsNothing,
    );
    expect(shell.isExplorer, isFalse, reason: 'the shell opens on a worktree');
  });

  testWidgets('it is a place, with an address', (tester) async {
    var shell = await _pump(tester);

    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    expect(shell.isExplorer, isTrue);
    expect(shell.address.toString(), 'fw:///worktrees');
    expect(find.text('Worktrees'), findsOneWidget);
  });

  testWidgets('every discovered worktree gets a row, open or not', (
    tester,
  ) async {
    var shell = await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    // The whole point: `feature/explorer` has no tab and no session, and still
    // reports. A screen that only listed open worktrees would be the switcher.
    expect(find.text('main'), findsWidgets);
    expect(find.text('feature/explorer'), findsWidgets);
    expect(shell.isOpen(shell.worktrees.last), isFalse);
  });

  testWidgets('the plugin rail goes away, and comes back', (tester) async {
    var shell = await _pump(tester);
    expect(find.byKey(sidebarKey), findsOneWidget);

    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();
    // Nothing to list: the rail is this worktree's plugins and the explorer is
    // about all of them.
    expect(find.byKey(sidebarKey), findsNothing);
    // The window preference is untouched, so leaving restores it rather than
    // silently having turned it off.
    expect(shell.sidebarVisible, isTrue);

    // Back via the tab, which is the only way back there is: `selectHome` reads
    // the address's worktree and the explorer's address names none, so from
    // here it is a no-op. That is correct — "this worktree's home" is not a
    // place the explorer can be said to have.
    await tester.tap(find.byKey(worktreeTabKey(shell.worktrees.first)));
    await tester.pumpAndSettle();
    expect(shell.isExplorer, isFalse);
    expect(find.byKey(sidebarKey), findsOneWidget);
  });

  testWidgets('and the window keeps its scale', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var shell = await _pump(tester);
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      moreOrLessEquals(1080, epsilon: 0.01),
    );

    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();
    expect(shell.isExplorer, isTrue);
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      moreOrLessEquals(1080, epsilon: 0.01),
      reason:
          'the minimum follows the sidebar preference, not the frame: '
          'crossing into the explorer must not zoom the window, so the '
          "rail's share stays charged and arrives as room for the explorer",
    );

    // ⌘B is the one thing that may move the minimum, and it still does —
    // from the explorer too.
    shell.toggleSidebar();
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(MaterialApp)).width,
      900,
      reason: 'the preference is off, so the pane stands alone and fits',
    );
  });

  testWidgets('a row expands rather than opening the worktree', (tester) async {
    var shell = await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    var closed = shell.worktrees.last;
    expect(shell.isOpen(closed), isFalse);

    await tester.tap(find.text('feature/explorer').first);
    await tester.pumpAndSettle();

    // The detail appeared and no config subprocess was spawned. Opening costs a
    // tab and a subprocess; this screen exists so the decision comes first.
    expect(find.text('PATH'), findsOneWidget);
    expect(shell.isOpen(closed), isFalse);

    await tester.tap(find.text('feature/explorer').first);
    await tester.pumpAndSettle();
    expect(find.text('PATH'), findsNothing);
  });

  testWidgets('arriving trusts the last pull requests; the button does not', (
    tester,
  ) async {
    var shell = await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    expect(_forge.calls, 1);
    // Both stub checkouts report the same branch, so both rows join it — which
    // is the join working, not a duplicate.
    expect(find.text('#79'), findsWidgets, reason: 'joined by branch');

    // Leaving and coming back is a glance, and a glance must not cost a round
    // trip to a server.
    await tester.tap(find.byKey(worktreeTabKey(shell.worktrees.first)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();
    expect(_forge.calls, 1, reason: 'still inside the TTL');

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(_forge.calls, 2, reason: 'the button means now');
  });

  testWidgets('a commit anywhere reaches the list without being asked', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    var discoveriesAtRest = _discoveries;
    var agentProbesAtRest = _agent.calls;

    // What `git commit` looks like from outside: a write under `.git`.
    _gitEvents.add('${_watchedRepo.path}/.git/refs/heads/feature/explorer');
    await tester.pumpAndSettle();

    // Rescan *and* re-probe. The rescan is what makes a worktree you just
    // created appear — `git worktree list` is 10 ms, noise beside the sweep it
    // precedes.
    expect(_discoveries, greaterThan(discoveriesAtRest));
    expect(_agent.calls, greaterThan(agentProbesAtRest));
  });

  testWidgets('an agent writing does not spawn a single git process', (
    tester,
  ) async {
    var shell = await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    var discoveriesAtRest = _discoveries;
    var agentProbesAtRest = _agent.calls;

    _agentEvents.add('${_watchedRepo.path}/agents/a-repo/session.jsonl');
    await tester.pumpAndSettle();

    // The agents were re-read — that is the cell worth being live for.
    expect(_agent.calls, greaterThan(agentProbesAtRest));
    // And nothing else was. An agent mid-answer writes continuously; if this
    // path ran git, a window left open in the background would spawn a sweep
    // every couple of seconds for as long as anybody was working.
    expect(_discoveries, discoveriesAtRest);
    expect(shell.isExplorer, isTrue);
  });

  testWidgets('the badge counts only what will not progress without you', (
    tester,
  ) async {
    var quiet = await _pump(tester);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();
    expect(quiet.worktreeFacts!.needsYou, 0);

    await tester.pumpWidget(const SizedBox());
    var waiting = await _pump(tester, agentWaiting: true);
    await tester.tap(find.byKey(explorerTabKey));
    await tester.pumpAndSettle();

    expect(waiting.worktreeFacts!.needsYou, 1);
    expect(
      find.descendant(of: find.byKey(explorerTabKey), matching: find.text('1')),
      findsOneWidget,
    );
  });
}
