import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutterware/plugins.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../changes/changes_config_cache.dart';
import '../changes/changes_sources.dart';
import '../context.dart';
import '../identity/project_face.dart';
import '../plugins/manifest_loader.dart';
import '../plugins/plugin_core.dart';
import '../plugins/registry.dart';
import '../worktrees/facts_controller.dart';
import '../worktrees/watchers.dart';
import '../plugins/worktree_session.dart';
import '../ui/aside.dart';
import '../utils/flutter_sdk.dart';
import 'config_load.dart';
import 'config_watcher.dart';
import 'workspace.dart';
import 'worktree.dart';
import 'worktree_discovery.dart';
import '../run/run_sources.dart';

final _logger = Logger('shell');

/// What the rail is worth, in the app's own pixels.
///
/// [defaultSidebarWidth] is what it has always been. [minSidebarWidth] is where
/// a row stops saying anything at all: the name ellipsises long before this and
/// that is allowed — a rail dragged this narrow is a rail somebody is using as a
/// strip of icons, and the point of the floor is only that the rows keep their
/// geometry. [maxSidebarWidth] is where it stops being a rail.
///
/// Nothing here is clamped against the window. A wider rail is a wider window
/// minimum, and a window that cannot hold the minimum scales — which is the
/// answer this app gives to every other shortage of room, and the reason a drag
/// keeps working when it is already scaling.
const defaultSidebarWidth = 232.0;
const minSidebarWidth = 100.0;
const maxSidebarWidth = 400.0;

/// Why a worktree could not be opened. Kept per worktree so a broken config in
/// one checkout never takes down the shell.
class WorktreeError {
  const WorktreeError(this.worktree, this.message);
  final Worktree worktree;
  final String message;
}

/// The shell opened a checkout other than the one it was launched in.
///
/// Not an error — [ShellController.start] has to open *something*, and the list
/// git reports is all it has to choose from. But it has to be *said*. Every
/// surface downstream is convincing: the tab is a real branch, the panels are
/// real code, and a screenshot minted from any of it looks exactly like the
/// answer to the question you asked and is about a different checkout.
class LaunchFallback {
  const LaunchFallback({required this.launchDirectory, required this.opened});

  /// Where flutterware was actually run.
  final String launchDirectory;

  /// What was opened instead: git's first worktree, which is always the main
  /// checkout.
  final Worktree opened;

  String get message =>
      'Opened ${opened.path}, which is not where flutterware was started. '
      'No worktree git reports contains $launchDirectory.';
}

/// What a worktree's sidebar is pointed at. A null [pluginId] is the worktree's
/// home screen, which is where a freshly opened worktree lands.
/// Owns the shell's state: which worktrees exist, which are open, and what is
/// selected.
///
/// Only *open* worktrees have a [WorktreeSession] and a [Project]; the rest are
/// names in the switcher and cost nothing. Closing releases both, which is what
/// makes the open/close lifecycle real rather than cosmetic.
class ShellController extends ChangeNotifier {
  ShellController({
    required this.appContext,
    required this.flutterSdk,
    required this.registry,
    required this.manifestLoader,
    this.coreRegistry,
    WorktreeDiscovery? discovery,
    WorktreeFactsController Function(String repoRoot)? worktreeFacts,
    WorktreeWatcher Function(String repoRoot)? worktreeWatcher,
    Stream<WatchEvent> Function(String directory)? watchEvents,
    Duration? watchDebounce,
    this.changes,
    this.runs = const RunSources.live(),
  }) : _discovery = discovery ?? WorktreeDiscovery(),
       // ignore: prefer_initializing_formals
       _buildWorktreeFacts = worktreeFacts,
       // ignore: prefer_initializing_formals
       _buildWorktreeWatcher = worktreeWatcher,
       // ignore: prefer_initializing_formals
       _watchEvents = watchEvents,
       // ignore: prefer_initializing_formals
       _watchDebounce = watchDebounce;

  /// How the explorer's facts are built, once the main checkout is known.
  ///
  /// Injectable because the default writes to the real `~/.flutterware`.
  /// Opening a worktree records the "you opened this" clock, so a widget test
  /// that pumped the shell was touching the developer's home directory — and
  /// would have raced any other test doing the same.
  final WorktreeFactsController Function(String repoRoot)? _buildWorktreeFacts;

  final WorktreeWatcher Function(String repoRoot)? _buildWorktreeWatcher;

  /// Injectable so a test can drive a save without a filesystem.
  final Stream<WatchEvent> Function(String directory)? _watchEvents;
  final Duration? _watchDebounce;

  final AppContext appContext;
  final FlutterSdkPath flutterSdk;

  /// Where the changes screen reads from, when not from the checkout: the
  /// studio's recordings. Null is the checkout — git, the working tree, the
  /// review log under the home directory.
  final ChangesSources? changes;

  /// Where the chrome's device button reads which devices are busy — the
  /// machine's run dir, or a recording's. The run plugin's core takes the
  /// same sources, so the two never disagree about what is running.
  final RunSources runs;

  /// Which panels this build can draw.
  final PluginRegistry registry;

  /// Which cores this build can run. Null means the default set — the same one
  /// `fw` and MCP link, which is what keeps the three from drifting.
  final PluginCoreRegistry? coreRegistry;
  final ManifestLoader manifestLoader;
  final WorktreeDiscovery _discovery;

  var _worktrees = <Worktree>[];

  /// Every open worktree, in the order they were opened.
  ///
  /// One map, not nine. This was nine collections keyed by the same path —
  /// session, workspace, error, remembered address, load generation, manifest,
  /// log, watcher, pending flag — with a 24-line `_closeAt` that had to remember
  /// every one of them. Nothing typed the relationship; a tenth piece of
  /// per-worktree state was one forgotten line away from a leak no test would
  /// notice. Insertion order is the tab order, so the separate path list went
  /// with them.
  final _open = <String, _Open>{};

  /// The directory whose changes reach [worktree], or null when nothing is
  /// watched — the answer to "why did it not notice my edit".
  String? watchingFor(Worktree worktree) =>
      _open[worktree.path]?.watcher?.watching;

  void _startWatching(Worktree worktree) {
    var open = _open[worktree.path];
    if (open == null || open.watcher != null) return;
    var watcher = ConfigWatcher(
      worktreePath: worktree.path,
      onChanged: () => _onConfigChanged(worktree),
      onError: (e) => _logger.severe('config reload failed: $e'),
      watch: _watchEvents,
      debounce: _watchDebounce ?? const Duration(milliseconds: 250),
    );
    open.watcher = watcher;
    // A watcher that failed to start must not stay in the map: `watchingFor`
    // reads the directory off the filesystem, so it would keep reporting the
    // config as watched while nothing was listening — and `_startWatching`
    // refuses to retry an id it already holds, so the state would be permanent.
    unawaited(
      watcher.start().catchError((Object e) {
        _logger.warning('config watch failed for ${worktree.path}: $e');
        if (identical(open.watcher, watcher)) open.watcher = null;
        unawaited(watcher.dispose());
        notifyListeners();
      }),
    );
  }

  Future<void> _onConfigChanged(Worktree worktree) async {
    // Closed between the save and the debounce settling.
    if (!_open.containsKey(worktree.path)) return;
    // Awaited so the watcher knows a reload is in flight and folds anything
    // that lands during it into one follow-up.
    await _load(worktree);
  }

  /// What the last load of [worktree]'s config did, or null before the first.
  ConfigLoad? lastLoad(Worktree worktree) => _open[worktree.path]?.lastLoad;

  /// What [worktree]'s config resolved to — the manifest its plugins were built
  /// from, and what the next load is compared against.
  ///
  /// Null when no load has succeeded yet, which is not the same as a worktree
  /// with no plugins: that one has an empty manifest.
  PluginManifest? manifestFor(Worktree worktree) =>
      _open[worktree.path]?.session?.session.manifest;

  void _record(_Open open, ConfigLoad load) {
    open.lastLoad = load;

    // Also to the terminal that launched the GUI. The band line is the surface
    // for someone looking at the window; this is the one for someone whose
    // config just reloaded while they were watching a log scroll past, and it
    // is how a reload is observable at all without a window in front of you.
    // It is also the only place a load older than the last one survives, which
    // is the whole of the history now that every row would say the same three
    // things.
    _logger.info(
      'config ${p.basename(open.worktree.path)}: ${load.summary} '
      '(${load.duration.inMilliseconds}ms)'
      '${load.error == null ? '' : '\n${load.error}'}',
    );
  }

  /// Where the shell is. The one piece of navigation state; everything
  /// below is read off it, and every way of moving is a write to it.
  ///
  /// Always present, though it may name nothing — `fw:///` before the first
  /// worktree opens, and again if the last one closes. A nullable address would
  /// make every reader below handle two empties.
  ///
  /// Its `worktree` is git's own name for the checkout (see [Worktree.name])
  /// rather than a path, because that is what an address carries and what makes
  /// one pasted from `fw` or an artifact resolve here.
  Address get address => _address.value;

  /// The address on its own, for widgets that want to rebuild when it moves and
  /// not when a session finishes loading.
  ///
  /// What `AddressRoot` listens to. Separate from [notifyListeners] on purpose:
  /// this notifier is how a change reaches exactly the widgets that read the
  /// part that changed, and routing it through the shell's blanket
  /// notification instead would rebuild the window for a slider.
  ValueListenable<Address> get addressListenable => _address;

  final _address = ValueNotifier<Address>(Address());

  /// Every worktree git reports, main first.
  List<Worktree> get worktrees => List.unmodifiable(_worktrees);

  /// The main checkout's path — what every repository-wide cache is keyed by.
  ///
  /// Deliberately the same value [WorktreeFactsController] is built with, and
  /// read from the same place, so the changes screen and the explorer cannot
  /// end up looking at two different cache files for one repository.
  String? get repoRoot => _worktrees.firstOrNull?.path;

  /// The open ones, in the order they were opened — including those still
  /// loading.
  List<Worktree> get openWorktrees => [
    for (var open in _open.values) open.worktree,
  ];

  List<Worktree> get closedWorktrees => [
    for (var w in _worktrees)
      if (!_open.containsKey(w.path)) w,
  ];

  bool isOpen(Worktree worktree) => _open.containsKey(worktree.path);

  /// Open, but its config has not finished running yet. The tab exists; the
  /// session does not.
  /// Open, but its config has not finished running yet.
  ///
  /// Tracked rather than inferred from a missing session. Inferring it meant a
  /// first load that *failed* looked like one still running — a permanent
  /// spinner — and the workaround was to build an empty session purely so the
  /// inference came out right.
  bool isLoading(Worktree worktree) => _open[worktree.path]?.hasLoaded == false;

  WorktreeSession? sessionFor(Worktree worktree) =>
      _open[worktree.path]?.session;

  WorktreeError? errorFor(Worktree worktree) => _open[worktree.path]?.error;

  Workspace? workspaceFor(Worktree worktree) => _open[worktree.path]?.workspace;

  /// The open worktree the address names, or null when it names none.
  ///
  /// Resolved by name, so an address that arrived from outside — pasted, or
  /// carried by an artifact — lands on the right tab without the writer having
  /// known this machine's paths.
  Worktree? get selected {
    var name = address.worktree;
    return name == null ? null : worktreeNamed(name, among: openWorktrees);
  }

  /// The worktree [name] refers to, by [Worktree.name] first and by branch
  /// second.
  ///
  /// Forgiving input, canonical output. Nothing ever *writes* a branch into
  /// an address — that would be an address that silently retargets when the
  /// branch is checked out somewhere else. But a branch is what a tab shows and
  /// therefore what someone types, so an address naming one still lands.
  ///
  /// Identity is checked across the whole set before any branch is, so a name
  /// that is one worktree's identity and another's branch resolves to the
  /// identity. The canonical form always wins, whichever order the list is in.
  Worktree? worktreeNamed(String name, {Iterable<Worktree>? among}) {
    var candidates = among ?? _worktrees;
    return candidates.where((w) => w.name == name).firstOrNull ??
        candidates.where((w) => w.branch == name).firstOrNull;
  }

  WorktreeSession? get selectedSession {
    var path = selected?.path;
    return path == null ? null : _open[path]?.session;
  }

  /// True while the window is showing the explorer — `fw:///worktrees`, the
  /// worktrees space with nothing selected inside it.
  bool get isExplorer =>
      address.worktree == null && address.space == Address.worktreesSpace;

  /// Moves to the explorer.
  void selectExplorer() => go(Address(space: Address.worktreesSpace));

  /// The explorer's facts, or null before the first discovery has run.
  ///
  /// Built once the main checkout is known, because branch diffs are
  /// repository-wide and their cache is keyed by it.
  ///
  /// **Listened to where it is drawn, never forwarded to [notifyListeners].**
  /// These facts are live by design — an agent appending to its session file
  /// moves one worktree's "active 3s ago" every couple of seconds, and the
  /// watchers floor that at one refresh per two seconds *per kind*. Forwarding
  /// it here made every one of those a whole-window rebuild: measured on this
  /// app, an idle window with no plugin panel mounted rebuilt the band, the
  /// rail and the panel about twice a second for a timestamp on a screen that
  /// was not even on. The three places that draw facts subscribe to this
  /// directly instead, so a cell that ticks costs the cell.
  WorktreeFactsController? get worktreeFacts => _worktreeFacts;
  WorktreeFactsController? _worktreeFacts;

  /// Watches the repository, so the explorer is a cockpit rather than a
  /// snapshot.
  ///
  /// The shell does this rather than the facts controller because a git
  /// event can mean a worktree appeared, and the list of worktrees is the
  /// shell's. So a git event is a rescan *and* a re-probe: `git worktree list`
  /// is 10 ms, which is noise beside the sweep that follows it, and it is what
  /// makes a checkout you just created show up without touching anything.
  ///
  /// An agent event refreshes agents only — no subprocesses. A stack event
  /// refreshes stacks only, and is cheaper still: one small file read per
  /// worktree. See [WorktreeWatcher] for why the three kinds are not one
  /// signal.
  void _startWatchingRepo(String repoRoot) {
    // One per shell. A second `start` would otherwise leave the first watcher
    // holding its streams with nothing to cancel it.
    if (_worktreeWatcher != null) return;
    var watcher =
        (_buildWorktreeWatcher ??
        (root) => WorktreeWatcher(
          repoRoot: root,
          onFailure: (what, error) =>
              // Losing a watch costs liveness, never correctness: the screen
              // still refreshes on arrival and on the button.
              _logger.fine('not watching $what: $error'),
        ))(repoRoot);
    _worktreeWatcher = watcher;
    _watcherEvents = watcher.changes.listen((change) async {
      switch (change) {
        case WorktreeChange.git:
          if (!_gitMoved.isClosed) _gitMoved.add(null);
          // A commit or a branch switch moves the merge-base, which is what
          // every open worktree's delta is measured from. Only the ones with
          // a tree on screen: a panel that mounts later asks for itself.
          for (var open in _open.values) {
            var delta = open.session?.session.branchDelta;
            if (delta != null && delta.isAttached) unawaited(delta.refresh());
          }
          await rescanWorktrees();
          await refreshWorktreeFacts();
        case WorktreeChange.agent:
          await _worktreeFacts?.refreshAgents(_worktrees);
        case WorktreeChange.stack:
          await _worktreeFacts?.refreshStacks(_worktrees);
      }
    });
    watcher.start();
  }

  WorktreeWatcher? _worktreeWatcher;
  StreamSubscription<WorktreeChange>? _watcherEvents;

  /// A commit, a staging change, a branch switch, or a worktree appearing —
  /// **repository-wide**, already coalesced by [WorktreeWatcher].
  ///
  /// Exposed because the changes screen needs it and cannot get it from a
  /// working-tree watch: `git add` and `git commit` write a linked worktree's
  /// index and HEAD under `<main>/.git/worktrees/<name>/`, which is nowhere
  /// near the checkout. Committing does not change one byte of the delta —
  /// it changes which files are marked *uncommitted*, and that is on screen.
  ///
  /// A stream rather than a listener list because it must be **live from the
  /// first frame**: the watcher is built once the main checkout is known,
  /// which may be after the screen subscribing to this is mounted.
  Stream<void> get gitMoved => _gitMoved.stream;
  final _gitMoved = StreamController<void>.broadcast();

  /// Re-probes every worktree. What the explorer calls when it appears and when
  /// its refresh button is pressed.
  ///
  /// [force] is the button. Arriving on the screen settles for the last pull
  /// request answer if it is minutes old; pressing refresh means you want to
  /// know now, and pays the round trip for it.
  Future<void> refreshWorktreeFacts({bool force = false}) async {
    if (_worktreeFacts case var facts?) {
      await facts.refresh(_worktrees, force: force);
    }
  }

  /// True while the address names the shell's own config screen.
  ///
  /// It occupies the plugin slot but is not a plugin, so it is neither
  /// [selectedPluginId] nor [isHome] — a third place, and the only one the
  /// shell itself owns.
  bool get isConfigScreen => address.plugin == Address.shellConfig;

  /// Moves to `fw:///worktrees/<worktree>/config`.
  void selectConfig() {
    if (address.worktree case var name?) {
      go(Address(worktree: name, plugin: Address.shellConfig));
    }
  }

  /// True while the address names the shell's own changes screen.
  bool get isChangesScreen => address.plugin == Address.shellChanges;

  /// The worktree the address names, open or not.
  ///
  /// [selected] deliberately resolves `among: openWorktrees`, because every
  /// other screen in the window needs a session and a worktree without one has
  /// nothing to show. The changes screen is the first that reads git rather
  /// than the project, so for it the open ones are the wrong set — and the
  /// checkout you most want to look at is precisely the one you have not
  /// opened.
  Worktree? get addressedWorktree {
    var name = address.worktree;
    return name == null ? null : worktreeNamed(name);
  }

  /// True while the window is showing the worktrees *space* rather than a
  /// checkout you have open: the explorer itself, or a shell-owned screen about
  /// a worktree that has no tab.
  ///
  /// One concept rather than two tests, because three things derive from it —
  /// the rail, which pseudo-tab is lit, and what Escape means — and they must
  /// not be able to disagree.
  bool get inWorktreesSpace => isExplorer || isUnopenedScreen;

  /// A shell-owned screen showing a worktree that is not open.
  bool get isUnopenedScreen {
    var worktree = addressedWorktree;
    return Address.shellSessionless.contains(address.plugin) &&
        worktree != null &&
        !isOpen(worktree);
  }

  /// Moves to `fw:///worktrees/<worktree>/changes/<path…>`, naming one file.
  ///
  /// A null [path] is the screen with nothing expanded. The segments are the
  /// panel's own, as they are for every plugin — the shell splits and joins
  /// them and reads nothing into them.
  ///
  void selectChangesFile(Worktree worktree, String? path) => go(
    Address(
      worktree: worktree.name,
      plugin: Address.shellChanges,
      segments: path == null || path.isEmpty ? const [] : path.split('/'),
    ),
  );

  /// Moves to `fw:///worktrees/<worktree>/changes`.
  ///
  /// [worktree] names one explicitly — which is how the explorer reaches a
  /// checkout that is not the one the window is on. Without it, the one the
  /// address already names.
  void selectChanges([Worktree? worktree]) {
    var name = worktree?.name ?? address.worktree;
    if (name == null) return;
    go(Address(worktree: name, plugin: Address.shellChanges));
  }

  /// Moves to one of the changes screen's tabs, and to what it addresses.
  ///
  /// The tab is a segment rather than a query parameter because it is
  /// *identity*: `changes/previews/demo/card.dart#card` names one preview's
  /// comparison, and there is nothing that address could mean on another tab.
  ///
  /// Distinct from [selectChangesFile], which names a path with no tab in front
  /// of it — the grammar the file diff had before there were tabs, and which
  /// still resolves to it. The tabs read anything that is not one of their own
  /// ids as a path, so both spellings keep working.
  void selectChangesTab({
    required String tab,
    List<String> segments = const [],
  }) {
    if (address.worktree case var name?) {
      go(
        Address(
          worktree: name,
          plugin: Address.shellChanges,
          segments: [tab, ...segments],
        ),
      );
    }
  }

  /// The plugin whose panel is mounted, or null when the home or config screen
  /// is.
  String? get selectedPluginId {
    var id = address.plugin;
    if (id == null || Address.shellOwned.contains(id)) return null;
    // A reloaded config may no longer declare it; fall back to home rather than
    // to a panel that cannot be built.
    var session = selectedSession;
    if (session != null && session.pluginById(id) == null) return null;
    return id;
  }

  /// What the window is showing in the plugin slot, whether or not it is a
  /// plugin.
  ///
  /// [selectedPluginId] answers a narrower question — *which plugin's panel is
  /// mounted* — and deliberately returns null for the shell's own screens, so
  /// the rail does not light a plugin row for them. Anything asking "did we land
  /// where we were sent" wants this one instead: `fw capture` compared against
  /// [selectedPluginId] and therefore could never photograph `config`, which was
  /// a real gap long before a second shell screen existed.
  String? get shownScreenId => Address.shellOwned.contains(address.plugin)
      ? address.plugin
      : selectedPluginId;

  /// The selected sub-entry of that plugin — a package path — or null.
  ///
  /// The first segment after the plugin. Anything deeper belongs to the plugin
  /// and the shell does not read it: a catalog entry is the catalog's business,
  /// which is what keeps this from growing a case per plugin.
  String? get selectedChildId =>
      selectedPluginId == null ? null : address.segments.firstOrNull;

  /// True while the selected worktree is showing its home screen.
  bool get isHome =>
      !isConfigScreen && !isChangesScreen && selectedPluginId == null;

  /// Whether the plugin rail is showing.
  ///
  /// Hiding it gives the whole window to the panel, which is what a catalog
  /// wants once you are looking at a device rather than choosing what to look
  /// at. Not per worktree: it is a preference about the window, and having it
  /// come back on every tab switch would be its own small annoyance.
  bool get sidebarVisible => _sidebarVisible;
  var _sidebarVisible = true;

  void toggleSidebar() {
    _sidebarVisible = !_sidebarVisible;
    notifyListeners();
  }

  /// The panel's own navigation column, and the one verb over both it and the
  /// rail.
  ///
  /// Held here because the macro needs both halves and only the shell has the
  /// rail; handed to the panel through an `AsideScope`, so a plugin can fold
  /// its list without knowing what a [ShellController] is.
  late final aside = AsideVisibility(
    railVisible: () => _sidebarVisible,
    setRailVisible: (value) {
      if (value == _sidebarVisible) return;
      _sidebarVisible = value;
      notifyListeners();
    },
  );

  /// How wide the rail is drawn, in the app's own pixels.
  ///
  /// A preference like [sidebarVisible], and held the same way: about the
  /// window, not the worktree, and not written to disk. Dragging it wider raises
  /// the window minimum with it, and a window already below that minimum simply
  /// scales a little further — the drag is never refused. It used to be clamped
  /// to the room the pane was not using, which meant a scaled window, where
  /// there is none, could not be resized at all.
  double get sidebarWidth => _sidebarWidth;
  var _sidebarWidth = defaultSidebarWidth;

  /// [width] clamped to what a rail can be, and nothing else.
  void resizeSidebar(double width) {
    var next = width.clamp(minSidebarWidth, maxSidebarWidth).toDouble();
    if (next == _sidebarWidth) return;
    _sidebarWidth = next;
    notifyListeners();
  }

  /// True while a drag on the seam is in flight.
  ///
  /// The window minimum is animated, which is what stops ⌘B from arriving as a
  /// 20% jump — but a drag is already continuous, and tweening towards a target
  /// that moves every frame turns the pointer's own gesture into something that
  /// lags behind it. So the shell says when it is dragging and the animation
  /// stands down.
  bool get sidebarResizing => _sidebarResizing;
  var _sidebarResizing = false;

  void setSidebarResizing(bool value) {
    if (value == _sidebarResizing) return;
    _sidebarResizing = value;
    notifyListeners();
  }

  /// Whether the rail is in the layout: the window preference, *and* whether
  /// the space being shown has a rail to give at all.
  ///
  /// Read by the row that lays the rail out and by the window minimum both, so
  /// the two cannot drift — a rail that is not drawn must not be paid for in
  /// the width the shell refuses to go below.
  bool get railInFlow => sidebarVisible && !inWorktreesSpace;

  Worktree? _worktreeAt(String path) =>
      _worktrees.where((w) => w.path == path).firstOrNull;

  /// The checkout that was not where we were launched, when [start] had to give
  /// up and open one anyway. Null in the ordinary case.
  LaunchFallback? get launchFallback => _launchFallback;
  LaunchFallback? _launchFallback;

  /// Discovers the project's worktrees and opens **only** the one the app was
  /// launched in. Everything else is opened deliberately from the switcher.
  ///
  /// The launch worktree is the one that *contains* the launch directory,
  /// not the one whose path equals it. A launch directory is hardly ever a
  /// checkout root: it is a package, or a nested project with a config of its
  /// own, and `findRepoRoot` deliberately stops at that nested config rather
  /// than at the checkout. An equality test therefore matched nothing and fell
  /// through to "git's first worktree" — the main checkout, always, from every
  /// linked worktree. That is a wrong window that looks entirely right, and it
  /// is the reason this resolves by containment.
  ///
  /// The deepest containing worktree wins, so a checkout parked inside another
  /// opens itself rather than its host.
  ///
  /// [landing] is somewhere to arrive instead of the launch worktree's home — a
  /// link the page was opened on. Gone to rather than gone to *afterwards*, so
  /// the window never draws the home screen on its way there. One that names
  /// no worktree git reports is ignored, and the launch worktree opens as usual.
  Future<void> start(String launchDirectory, {Address? landing}) async {
    // Still walked up: this is what [WorktreeDiscovery] runs git in, and in a
    // directory that is not a repository at all it is the single worktree the
    // discovery falls back to — so it wants the project root, not `lib/src`.
    var root = findRepoRoot(launchDirectory) ?? launchDirectory;
    _worktrees = await _discovery.discover(root);

    // The main checkout, which discovery always reports first — not the
    // launch directory. The facts cache is keyed by it because what it holds
    // (a diff between two commits) is repository-wide, and keying it by the
    // current checkout would give every worktree its own permanently cold copy.
    if (_worktrees.firstOrNull case var main?) {
      // Replaced, so the one it replaces goes with it. A facts controller
      // registers itself with the window's settle registry, which holds a
      // reference until it is disposed — so an abandoned one would sit in
      // there for the life of the process, invisible, being asked whether it
      // is busy. `_startWatchingRepo` guards itself for the same reason.
      _worktreeFacts?.dispose();
      _worktreeFacts =
          (_buildWorktreeFacts ??
          (root) => WorktreeFactsController(
            repoRoot: root,
            settle: appContext.settle,
          ))(main.path);
      _startWatchingRepo(main.path);
    }
    notifyListeners();

    var launch = _worktreeContaining(launchDirectory);
    if (launch == null) {
      launch = _worktrees.firstOrNull;
      if (launch != null) {
        var fallback = LaunchFallback(
          launchDirectory: p.normalize(p.absolute(launchDirectory)),
          opened: launch,
        );
        _launchFallback = fallback;
        _logger.warning(fallback.message);
      }
    }

    if (landing != null) {
      var name = landing.worktree;
      var worktree = name == null ? null : worktreeNamed(name);
      // The tab opened here rather than by `go`, so its load can be awaited
      // like [open]'s is: a caller of `start` expects a session to be there.
      var loaded =
          worktree != null &&
              !isOpen(worktree) &&
              !Address.shellSessionless.contains(landing.plugin)
          ? _openTab(worktree)
          : null;
      if (go(landing) != GoResult.worktreeUnknown) {
        await loaded;
        return;
      }
    }
    if (launch != null) await open(launch);
  }

  /// The worktree holding [directory], deepest first.
  ///
  /// Deepest rather than first because containment nests: a vendored repo, or a
  /// worktree someone parked under the main checkout, is inside another
  /// worktree and is still the one you launched from.
  Worktree? _worktreeContaining(String directory) {
    var target = p.canonicalize(directory);
    Worktree? best;
    var bestDepth = -1;
    for (var worktree in _worktrees) {
      var candidate = p.canonicalize(worktree.path);
      // Component-wise, so `/repo` does not claim `/repo-explorer/lib`.
      if (candidate != target && !p.isWithin(candidate, target)) continue;
      var depth = p.split(candidate).length;
      if (depth > bestDepth) {
        best = worktree;
        bestDepth = depth;
      }
    }
    return best;
  }

  /// Re-reads `git worktree list`. Open worktrees that disappeared are closed,
  /// and the ones still there are re-pointed at what git just said.
  ///
  /// Cheap enough to run whenever the switcher is opened, which is what keeps
  /// the list current without a watcher.
  Future<void> rescanWorktrees() async {
    if (_worktrees.isEmpty) return;
    var before = _worktrees;
    _worktrees = await _discovery.discover(_worktrees.first.path);
    var closed = false;
    for (var path in _open.keys.toList()) {
      var fresh = _worktreeAt(path);
      if (fresh == null) {
        _closeAt(path);
        closed = true;
      } else {
        // **A tab's worktree is not a copy it keeps.** [openWorktrees] reads
        // these, so a checkout that changed branch under an open tab used to
        // keep the name it was opened with — on the tab, in both switchers'
        // filters, and in the address a branch resolves through — while the
        // explorer, which reads [worktrees], showed the new one. One window,
        // two answers, and a branch you could find in the list and not in the
        // switcher.
        _open[path]!.worktree = fresh;
      }
    }
    // **A git event is rarely news.** The watch fires for any write under
    // `.git` — a commit, an index refresh, another window's `git status` — and
    // is floored at one signal every two seconds, so on a machine with a few
    // Studios open it arrives more or less continuously. The list it
    // re-derives is the same list almost every time. Notifying regardless made
    // each of those a whole-window rebuild, which is what an idle window was
    // spending 15–40 ms on twice a second.
    if (closed || !_sameWorktrees(before, _worktrees)) notifyListeners();
  }

  /// Everything about a worktree the shell itself draws: the tab's name comes
  /// from [Worktree.title] and [Worktree.branch], the switcher's from the path,
  /// and `head` is what tells a rescan that a commit landed.
  ///
  /// Not `==` on the list. [Worktree] is deliberately equal by path alone —
  /// that is its identity, and what the open map and `_worktreeAt` key on — so
  /// a list comparison through it would call a branch switch no change at all.
  static bool _sameWorktrees(List<Worktree> a, List<Worktree> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      var x = a[i], y = b[i];
      if (x.path != y.path ||
          x.gitName != y.gitName ||
          x.branch != y.branch ||
          x.head != y.head ||
          x.isMain != y.isMain ||
          x.title != y.title) {
        return false;
      }
    }
    return true;
  }

  /// Opens [worktree] at its home screen: the tab appears immediately, then its
  /// config runs and its plugins resolve.
  ///
  /// A worktree that fails to open is still selected, so the shell can show why
  /// rather than silently doing nothing.
  ///
  /// To open one *and* land somewhere inside it, pass the whole address to
  /// [go] — it opens what it needs to.
  Future<void> open(Worktree worktree) async {
    if (isOpen(worktree)) {
      select(worktree);
      return;
    }

    var loaded = _openTab(worktree);
    // Before the session exists: the tab and its address are what the loader
    // draws under.
    go(Address(worktree: worktree.name));
    await loaded;
  }

  /// Opens [worktree] **without going there** — a tab and a running config,
  /// and the address left exactly where it was.
  ///
  /// [open] navigates, which is right when opening *is* the intent and wrong
  /// when it is a means to something else. Removing a worktree needs its
  /// plugins resolved so the teardown checklist knows what is running, and
  /// navigating for that would take you off the screen you pressed the button
  /// on — the explorer would unmount mid-flow, taking the dialog with it.
  Future<void> openInBackground(Worktree worktree) =>
      isOpen(worktree) ? Future.value() : _openTab(worktree);

  /// Gives [worktree] a tab and starts its config running.
  ///
  /// Deliberately says nothing about the address. [open] lands on the home
  /// screen; [go] lands on wherever it was pointed, which is the whole reason
  /// this is separate from either.
  Future<void> _openTab(Worktree worktree) {
    _open[worktree.path] = _Open(worktree);
    // One of the three clocks the explorer takes the maximum of, and the only
    // one nothing else on the machine records.
    _worktreeFacts?.markOpened(worktree);
    _startWatching(worktree);
    // The tab is on screen before the manifest subprocess starts; everything
    // below it draws a loader until the session lands.
    notifyListeners();
    return _load(worktree);
  }

  /// Re-runs the selected worktree's config and applies whatever moved.
  ///
  /// Never refuses. A reload used to answer to the same teardown guards a
  /// close does, and defer itself until they cleared — a whole mechanism
  /// protecting state that a config change is allowed to cost. Closing still
  /// asks, because closing is a deliberate act on a worktree; reloading is what
  /// the file you just saved asked for.
  ///
  /// Does not release anything up front. Whether the graph pays for a
  /// reload is decided after the config has run and been compared; releasing
  /// first would make a config that fails to compile cost the whole worktree.
  Future<bool> reloadConfig() async {
    var worktree = selected;
    if (worktree == null) return false;
    await _load(worktree);
    return true;
  }

  /// Runs a worktree's config and applies whatever moved.
  ///
  /// One exit. Every branch below produces a [ConfigLoad] and returns it;
  /// this method records it and notifies, once. It used to be seven exits each
  /// repeating `record(...); notifyListeners(); return;`, which made "every load
  /// leaves exactly one row and one notification" a rule you had to remember
  /// rather than one the shape enforces — and a branch that forgot the notify
  /// was a frozen window.
  Future<void> _load(Worktree worktree) async {
    var open = _open[worktree.path];
    if (open == null) return;

    var generation = ++open.generation;
    var watch = Stopwatch()..start();

    var load = await _apply(open, generation, watch);
    // The one silent return: this load was superseded or its tab closed, so
    // there is nothing to say and nobody to say it to.
    if (load == null) return;

    _record(open, load);
    notifyListeners();
  }

  /// Decides what this load did, or null when it no longer matters.
  ///
  /// Four outcomes, and only one of them is a judgement call:
  ///
  /// - **failed** — nothing is torn down. The error surfaces and every plugin
  ///   keeps running, because a half-written file must not cost a worktree.
  /// - **unchanged** — the config declared what was already there, so not one
  ///   object moves. This is the case that matters; the rest is bookkeeping.
  /// - **built** / **rebuilt** — the graph is thrown away and made again.
  Future<ConfigLoad?> _apply(
    _Open open,
    int generation,
    Stopwatch watch,
  ) async {
    var worktree = open.worktree;

    ConfigLoad done(
      ConfigLoadOutcome outcome, {
      int plugins = 0,
      String? error,
    }) => ConfigLoad(
      duration: watch.elapsed,
      outcome: outcome,
      plugins: plugins,
      error: error,
    );

    PluginManifest? manifest;
    String? error;
    try {
      var result = await manifestLoader.tryLoad(worktree.path);
      manifest = result.manifest;
      error = result.error;
    } catch (e) {
      error = '$e';
    }

    // Closed, or superseded by a later load, while the config ran.
    if (!identical(_open[worktree.path], open) ||
        open.generation != generation) {
      return null;
    }
    open.hasLoaded = true;

    if (error != null) {
      // Before any release, and leaving the session alone: the plugins built
      // from the last config that loaded are still the ones running, and the
      // next success compares against the config they came from.
      open.error = WorktreeError(worktree, error);
      return done(ConfigLoadOutcome.failed, error: error);
    }

    // No config file is not an error — the worktree opens with no plugins.
    manifest ??= const PluginManifest([]);
    open.error = null;

    // **The one writer.** Running this file is what "opening a worktree" costs,
    // and the changes screen has to rank checkouts nobody has opened — so the
    // value it produced is remembered here, stamped with the file it came from.
    // A manifest that declares no `ChangesConfig` is still worth writing: "this
    // project says nothing" is an answer.
    // **Through the explorer's store, never a second one.** See
    // [WorktreeFactsController.store]: two instances over one file are two
    // copies of it, and the sweep that runs a second later would write this
    // entry straight back out again.
    if (_worktreeFacts?.store case var store?) {
      rememberChangesConfig(worktree.path, manifest.changes, store);
    }

    var existing = open.session;
    if (existing != null &&
        !existing.isDisposed &&
        existing.session.declares(manifest)) {
      // The config did not move; the disk may have. This is the one check that
      // does not follow from the manifest, so an unchanged load still has to
      // make it — see [_checkDeclarations].
      _checkDeclarations(open, manifest);
      return done(
        ConfigLoadOutcome.unchanged,
        plugins: existing.plugins.length,
      );
    }

    var opening = existing == null;
    open.release();
    if (_build(open, manifest) case var failure?) {
      return done(ConfigLoadOutcome.failed, error: failure);
    }
    return done(
      opening ? ConfigLoadOutcome.built : ConfigLoadOutcome.rebuilt,
      plugins: manifest.plugins.length,
    );
  }

  /// Builds the workspace and session for a manifest, from nothing. Returns
  /// null on success, or the failure to report.
  ///
  /// Everything here touches the disk, and since `go` opens a worktree without
  /// awaiting the load, there is no caller left to catch what it throws.
  String? _build(_Open open, PluginManifest manifest) {
    var worktree = open.worktree;
    try {
      var workspace = Workspace(
        root: worktree.path,
        declared: manifest.packages.isEmpty
            // A project that declares nothing still has itself.
            ? const [Pkg('.')]
            : manifest.packages,
        discovered: discoverPackages(worktree.path),
        appContext: appContext,
        flutterSdk: flutterSdk,
      );
      open.workspace = workspace;
      _checkDeclarations(open, manifest);

      // **Not `..addListener(notifyListeners)`.** A session merges every
      // plugin's notifier, so forwarding it made any plugin's tick — a health
      // probe, a compile step, a log line — rebuild the entire window,
      // including the panels of the eleven plugins that did not move. The rail
      // is the only part of the shell that reads a plugin's report, and it
      // subscribes per row; a panel already listens to its own plugin.
      open.session = WorktreeSession.resolve(
        worktree: worktree,
        manifest: manifest,
        registry: registry,
        workspace: workspace,
        coreRegistry: coreRegistry,
      );
      return null;
    } catch (e) {
      // Returned rather than only recorded. A caller that logged "opened, 3
      // plugins" over this would be claiming a session that does not exist.
      open.error ??= WorktreeError(worktree, '$e');
      return '$e';
    }
  }

  /// Re-derives the errors about things the config named that are not there:
  /// a package, and the icon [ProjectIdentity] points at.
  ///
  /// Run on every load, including one that changed nothing. These are the
  /// errors whose truth lives on disk rather than in the config, so a load that
  /// skipped them would either keep a warning about a package you have since
  /// created, or — worse — drop a warning that is still true, because the load
  /// clears the error before deciding whether to rebuild.
  ///
  /// Never clobbers a config-load failure: that is the more useful error, and a
  /// broken config is often *why* the declarations look wrong.
  void _checkDeclarations(_Open open, PluginManifest manifest) {
    if (open.error != null) return;
    var unknown = open.workspace?.unknownDeclarations ?? const <String>[];
    if (unknown.isNotEmpty) {
      open.error = WorktreeError(
        open.worktree,
        'Declared package(s) not found on disk: ${unknown.join(', ')}',
      );
      return;
    }
    // Said out loud rather than left as a window with no chip: naming the file
    // is the whole of what identity asks for, so a name that goes nowhere is
    // the one thing it has to be able to report.
    var problem = projectFaceProblem(
      worktreeRoot: open.worktree.path,
      manifest: manifest,
    );
    if (problem != null) {
      open.error = WorktreeError(open.worktree, problem);
    }
  }

  /// Closes [worktree], disposing its plugins and its [Project].
  ///
  /// Refuses while a plugin hard-blocks teardown; the caller is expected to have
  /// shown the guard reasons already.
  bool close(Worktree worktree) {
    if (!isOpen(worktree)) return true;
    if (_open[worktree.path]?.session?.isBlocked ?? false) return false;
    _closeAt(worktree.path);
    notifyListeners();
    return true;
  }

  void _closeAt(String path) {
    // Read before the tab goes: `selected` resolves through `openWorktrees`,
    // so after the removal it can no longer recognise the worktree it names
    // and the address would be left pointing at a closed tab.
    var wasSelected = selected?.path == path;
    // One line, and it cannot forget a field. That is the whole reason the
    // per-worktree state is one object: teardown used to be nine removals that
    // a tenth piece of state would silently not join.
    _open.remove(path)?.close();
    if (wasSelected) {
      var fallback = _open.keys.lastOrNull;
      _address.value =
          (fallback == null ? null : _addressFor(fallback)) ?? Address();
    }
  }

  /// Where a tab should land: where it was left, else its home screen.
  ///
  /// Resolves against every *known* worktree, not just the open ones —
  /// [select] uses it to open a closed one, so scoping it to `_open` silently
  /// turned selecting a closed worktree into doing nothing.
  Address? _addressFor(String path) {
    var worktree = _open[path]?.worktree ?? _worktreeAt(path);
    if (worktree == null) return null;
    return _open[path]?.remembered ?? Address(worktree: worktree.name);
  }

  /// The one way the shell moves. Every `select…` below is a call to this,
  /// and so is opening a search hit or a pasted address.
  ///
  /// Opening is the navigation. An address naming a closed worktree opens
  /// it and lands inside it. This used to refuse, on the grounds that opening
  /// costs a subprocess and should be a deliberate act — but the cost is the
  /// user's to spend and they spent it by naming the worktree, and refusing to
  /// go where you were told is itself landing somewhere you were not.
  ///
  /// Still synchronous. The tab and the address are in place before the config
  /// starts, and everything under them draws a loader until the session lands —
  /// which is what [open] already did, and is why nothing here has to wait.
  ///
  /// A name matching no worktree git reports is the one refusal left, and it is
  /// reported rather than returning nothing: anything that lets you type an
  /// address has to explain what happened to it.
  ///
  /// The address is remembered against its worktree on the way through, so a
  /// tab switched away from and back comes home to the same place.
  GoResult go(Address destination) {
    var name = destination.worktree;

    // **A space with no worktree is the explorer**, and it is a real place —
    // the one destination in the shell that is about every checkout rather than
    // one. It has no tab to open and no session to wait for, so it lands
    // immediately and returns before any of the per-worktree machinery below.
    if (name == null && destination.space == Address.worktreesSpace) {
      if (destination == address) return GoResult.unchanged;
      _address.value = destination;
      notifyListeners();
      return GoResult.ok;
    }

    var worktree = name == null ? null : worktreeNamed(name);
    if (worktree == null) return GoResult.worktreeUnknown;

    // **The one destination that does not open what it names.** "Opening is the
    // navigation" holds for every address that needs a session to render, which
    // until now was all of them. A shell screen that reads git rather than the
    // project needs none — and the whole reason it exists is to answer a
    // question about a checkout *before* you decide to spend a subprocess on it.
    // Opening it here would make the cheap surface expensive, which is the
    // premise of the explorer the link comes from.
    //
    // Not a refusal: the address still resolves, still lands, still draws. It
    // simply does not grow a tab.
    var needsSession = !Address.shellSessionless.contains(destination.plugin);

    // The tab first, so the resolution below and everything that reads
    // `selected` afterwards can see it.
    if (needsSession && !isOpen(worktree)) unawaited(_openTab(worktree));

    // **Canonicalised on the way in**, so a branch is only ever input. Accepting
    // one and then keeping it would put a name that moves with `git checkout`
    // into the remembered address, into the bar, and into every artifact from
    // where the shell is — which is the retarget the identity rule exists to
    // prevent. This is the one place that can rewrite it, because it is the one
    // place that knows which worktree the name found.
    destination = destination.copyWith(worktree: worktree.name);

    if (destination == address) return GoResult.unchanged;

    // Read before the write, so the comparison is against where we were.
    var moved = destination.bare != address.bare;

    _address.value = destination;
    _open[worktree.path]?.remembered = destination;
    // Recorded on the way through, so every route to a sub-entry counts: the
    // rail, a search hit, the address bar, a panel writing back where it
    // landed. [selectPlugin] is the only reader.
    if (destination.plugin case var plugin?) {
      if (destination.segments.firstOrNull case var child?) {
        _lastChild[(worktree.path, plugin)] = child;
      }
    }

    // **Only when the shell's own reading of the address changed.** Everything
    // this notification serves — the tabs, the rail, which panel is mounted —
    // is derived from the identity: the worktree, the plugin, the segments.
    // Applied parameters are for whoever reads them, and they reach exactly
    // those readers through [addressListenable] and the address scope above
    // them.
    //
    // Not an optimisation. Dragging a slider writes a value per frame, and
    // rebuilding the window at the frame rate of a drag is what the per-key
    // scope exists to prevent — it cannot, while every write also marks the
    // whole shell dirty.
    if (moved) notifyListeners();
    return GoResult.ok;
  }

  /// Switches tabs, returning to wherever that tab was left — opening the
  /// worktree first if it was closed, since [go] does.
  void select(Worktree worktree) {
    var destination = _addressFor(worktree.path);
    if (destination != null) go(destination);
  }

  /// Returns the selected worktree to its home screen.
  void selectHome() {
    if (address.worktree case var name?) go(Address(worktree: name));
  }

  /// Which sub-entry each plugin was last on, so that coming back to it off
  /// the rail returns you there rather than to whichever one sorts first.
  ///
  /// Keyed by worktree *and* plugin: the same plugin id in two checkouts is two
  /// different sets of packages, and letting one inherit the other's choice is
  /// a rail link that opens a package this worktree may not have.
  ///
  /// In memory, and only ever consulted for the fill-in below. An address that
  /// names a sub-entry is obeyed, never overridden.
  final _lastChild = <(String, String), String>{};

  /// Selecting a plugin defaults to a child, so a panel always has a concrete
  /// sub-entry to render rather than an ambiguous null.
  ///
  /// Where you last were in that plugin, and its first child only if you have
  /// never been. Both are fill-ins, and the remembered one is simply the better
  /// guess: a rail that always reopened the first package sent you back to
  /// `app` every time you left the one you were working in.
  ///
  /// The remembered id is checked against the children the plugin reports
  /// *now*, so a package that a config edit removed cannot be navigated to.
  ///
  /// This is the one place navigation fills in something it was not told, and
  /// it is allowed here because choosing a plugin off the rail carries no
  /// deeper intent. An address that arrived *already* naming something is never
  /// completed or corrected — see [GoResult].
  void selectPlugin(String id) {
    var name = address.worktree;
    if (name == null) return;
    var plugin = selectedSession?.pluginById(id);
    // **The plugin's own landing beats the fill-in.** A plugin whose children
    // are instances rather than packages says where its row goes, because
    // "whichever one sorts first" is not a place — see
    // [NativePlugin.railLanding], which exists because `Run` opened a running
    // app instead of the page that starts one.
    if (plugin?.railLanding case var landing?) {
      go(Address(worktree: name, plugin: id, segments: landing));
      return;
    }
    var children = plugin?.core.report.children ?? const [];
    var remembered = _lastChild[(selected?.path ?? '', id)];
    var child = children.any((c) => c.id == remembered)
        ? remembered
        : children.firstOrNull?.id;
    go(Address(worktree: name, plugin: id, segments: [?child]));
  }

  /// Selects a plugin's sub-entry, and the plugin with it.
  void selectChild(String pluginId, String childId) {
    var name = address.worktree;
    if (name == null) return;
    go(Address(worktree: name, plugin: pluginId, segments: [childId]));
  }

  /// The same place, in another checkout.
  ///
  /// Everything except the worktree rides along — the plugin, the package, the
  /// entry, the device, the theme, the knobs — because all of it is in the one
  /// value being copied. That is what makes this a *comparison* rather than a
  /// navigation: the same demo, framed the same way, on another branch.
  ///
  /// Distinct from [select], which is the other thing you might mean. Switching
  /// tabs takes you to where that worktree was left; this brings where you are
  /// to that worktree. Both are wanted and they are not the same move.
  ///
  /// A worktree that does not have what the address names is *not* handled
  /// here. The panel reports it — the catalog already refuses to quietly repair
  /// an address naming an entry it has never heard of — and that complaint is
  /// the answer to "was this only ever on my branch?".
  GoResult goToWorktree(Worktree worktree) =>
      go(address.copyWith(worktree: worktree.name));

  /// Flicks to the next open worktree, keeping the address. Negative goes back.
  ///
  /// Open ones only, which is the difference between this and picking from
  /// the switcher. A keystroke that spawned a config subprocess would be a
  /// keystroke you learn not to press; the ones already open are free, and with
  /// two of them this is the A/B flick the whole feature is for. Opening a
  /// third is a deliberate act, and it joins the rotation once it is done.
  GoResult cycleWorktree(int delta) {
    var open = openWorktrees;
    if (open.length < 2) return GoResult.unchanged;
    var current = selected;
    var index = current == null ? -1 : open.indexOf(current);
    // Dart's `%` is never negative for a positive divisor, so stepping back
    // from the first wraps to the last without a special case.
    return goToWorktree(open[(index + delta) % open.length]);
  }

  /// Silent after disposal, rather than throwing.
  ///
  /// Half of what this class does is asynchronous and started by something
  /// outside it — a config save, a filesystem event, a config load that is still
  /// resolving plugins. Each of those resumes after an `await` and notifies, and
  /// a window closing in that window would take `notifyListeners` on a disposed
  /// notifier, which throws. Cancelling the subscriptions in [dispose] does not
  /// help: the callback has already started.
  ///
  /// The alternative is a `_disposed` check after every await in the class,
  /// which is the same rule enforced in more places and forgotten in one.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    for (var path in _open.keys.toList()) {
      _closeAt(path);
    }
    unawaited(_watcherEvents?.cancel());
    unawaited(_worktreeWatcher?.dispose());
    unawaited(_gitMoved.close());
    _worktreeFacts?.dispose();
    _address.dispose();
    super.dispose();
  }
}

/// What [ShellController.go] did with an address.
///
/// Exists so the address bar can say what happened. A navigation that silently
/// does nothing is indistinguishable from a broken app, and that is precisely
/// the case a pasted address hits most.
enum GoResult {
  ok,

  /// Already there. Not a failure — just nothing to do.
  unchanged,

  /// No worktree by that name, or the address named none at all.
  worktreeUnknown,
}

/// Everything one open worktree holds.
///
/// The reason this type exists is teardown. As nine maps keyed by path, the
/// contract "closing a worktree releases all of it" lived in one method that had
/// to name every one of them, and the tenth thing anyone added would have been a
/// leak with no test to notice. Here it is [close], and a new field joins it by
/// existing.
class _Open {
  _Open(this.worktree);

  /// The checkout this tab is of. Replaced by [rescanWorktrees] when git
  /// reports the same path with a different branch, head or name — the path is
  /// the identity ([Worktree] is equal by it, and this map is keyed by it), so
  /// everything else about it is news the tab has to take.
  Worktree worktree;

  WorktreeSession? session;
  Workspace? workspace;
  WorktreeError? error;

  /// Where this tab was left, so switching back returns to the same place.
  Address? remembered;

  /// Bumped on every load, so one whose tab was closed or which was superseded
  /// drops its result instead of committing it. Never reset: a counter that
  /// restarts lets a load from before a close collide with one from after a
  /// reopen, both holding generation 1 and both passing the guard.
  int generation = 0;

  /// What the most recent load did. One, not a history: with the reload no
  /// longer surgical every row said the same three things, and the terminal log
  /// keeps the ones before this.
  ConfigLoad? lastLoad;

  ConfigWatcher? watcher;

  /// Whether a load has finished, however it finished.
  bool hasLoaded = false;

  /// Drops what a load produced, keeping the tab and its place.
  void release() {
    session?.dispose();
    session = null;
    workspace?.dispose();
    workspace = null;
    error = null;
  }

  void close() {
    release();
    unawaited(watcher?.dispose());
    watcher = null;
  }
}
