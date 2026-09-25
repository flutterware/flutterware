import 'dart:async';

import 'package:flutterware/plugins.dart';

import '../previews/catalog_roots.dart';
import '../shell/workspace.dart';
import '../shell/worktree.dart';
import '../utils/value_stream.dart';
import 'plugin_host.dart';

/// A plugin's behaviour, with no Flutter in it.
///
/// This is master-plan decision 2 made literal: `status`, `badge`, `actions`,
/// `teardown`, `guard` and the text projection are data, and **only the panel
/// forks**. Everything a renderer other than the GUI needs lives here, so the
/// same object serves the sidebar, `fw` and an agent.
///
/// The reason it is a separate type from `NativePlugin` rather than a
/// refactoring of it: `NativePlugin.buildPanel` returns a `Widget`, so that
/// class can never be linked into a pure-Dart entry point. `fw` links cores.
///
/// Change notification is a [ValueStream] rather than a `ChangeNotifier`, for
/// the same reason — see `2026-07-27-gui-cli-mcp-architecture.md`, decision 4.
abstract class PluginCore {
  PluginCore(this.host);

  final PluginHost host;

  String get id => host.id;
  String get label => host.label;

  /// Everything this plugin currently says about itself.
  ///
  /// A pure read of cached state — it must never start work. That is what
  /// makes it safe for the sidebar, a tab glyph, `fw` and an agent to call it
  /// for every plugin × package × worktree. A plugin with nothing cached
  /// reports "not computed" rather than computing on the spot.
  PluginReport get report;

  /// Runs one of [report]'s actions. [arguments] are keyed by
  /// `ActionParameter.id`, whether they came from a form, a flag or an agent.
  ///
  /// The failure names what *is* declared, like every other refusal on this
  /// surface — "no such device. Accepted: …", 'No plugin "nope". Declared: …'.
  /// This was the one that did not, and it is the one a caller most often
  /// reaches by guessing at a name.
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => throw unknownAction(id, actionId, report.actions);

  /// The refusal for an action a plugin does not declare.
  ///
  /// Shared, because the session refuses before dispatch and this refuses after
  /// it, and two spellings of one sentence would make the answer look like it
  /// depends on which door the caller came through. The session's check
  /// is the one that matters — see `Session.invoke` — and this stays as the
  /// backstop for a core invoked directly.
  static ArgumentError unknownAction(
    String pluginId,
    String actionId,
    List<PluginAction> actions,
  ) {
    var declared = actions.map((action) => action.id).toList();
    return ArgumentError.value(
      actionId,
      'actionId',
      'unknown action on $pluginId. '
          '${declared.isEmpty ? 'It declares none.' : 'Declared: ${declared.join(', ')}'}',
    );
  }

  /// What this plugin has that matches [query].
  ///
  /// A pure read, like [report], and for the same reason — it is called for
  /// every plugin on every keystroke. Loading happens once when a search
  /// surface opens, through [computeAll]; by the time this runs there is
  /// nothing left to fetch.
  ///
  /// The default walks [report], which is already all data, so **every plugin
  /// is searchable the day it reports** — including one written long after this
  /// method. The floor it establishes is real but blunt: a `ViewItem` has no
  /// address, so a hit found in the projection can name a row and only navigate
  /// to the plugin that drew it.
  ///
  /// Override to do better. A plugin that knows where its content lives — the
  /// catalog has `addressFor(package, entry)` — returns hits that address the
  /// thing itself, and should still call [searchReport] for the parts it has no
  /// opinion about rather than reimplementing the walk.
  List<SearchHit> search(String query) =>
      searchReport(report, query, worktree: host.worktree.name);

  /// Loads whatever [report] would otherwise call "not computed", and waits.
  ///
  /// It exists because a widget subscribing is what normally starts work, and
  /// `fw` and MCP have no widget. Both call this before reporting.
  ///
  /// The budget is parsing. Read files, parse them, cache the result. Do
  /// not compile, spawn a process, open a socket or hit the network — that
  /// work belongs behind an action, where a caller chose it by name and can be
  /// told what it costs. The catalog holds to it exactly: it parses its demo
  /// files and deliberately does not start the compile loop (see
  /// `PreviewsCore.track`).
  ///
  /// Dependencies is the one core that cannot, and shows what the exception
  /// has to cost. Only pub knows the resolution, so it shells out — but the
  /// answer is a pure function of the lockfile and the package config, so
  /// `PubDepsStore` caches it against a hash of both and the warm path is a
  /// file read. Before that store existed it was the largest cost in
  /// `fw status` by six times, because it ran the same subprocess once per
  /// declared package. A core that must spawn something owes the same two
  /// things — one process for the whole answer, and a cache keyed by what the
  /// answer actually depends on.
  ///
  /// The budget is what lets every surface call this freely — `fw status`, MCP,
  /// and search warming its index when the palette opens. A plugin that cannot
  /// answer within it should leave this a no-op and expose the slow path as an
  /// action rather than making those surfaces unpredictable.
  ///
  /// Idempotent: callers invoke it without knowing what has run before.
  ///
  /// Default: nothing. A plugin with nothing to load needs no override, and
  /// callers never have to ask which kind they have.
  Future<void> computeAll() async {}

  /// Bumps whenever [report] would answer differently. A renderer subscribes;
  /// it carries no payload because the report is the payload.
  ValueStream<int> get changes => _changes;
  final _changes = ValueStream<int>(0);

  /// Schedules a change notification, coalescing bursts into one.
  ///
  /// Deferred by a microtask because work starts when a widget subscribes, and
  /// that happens in `initState` — inside the build phase, where marking the
  /// shell dirty synchronously throws "setState() called during build".
  void notifyChanged() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) _changes.value = _changes.value + 1;
    });
  }

  var _notifyScheduled = false;
  var _disposed = false;

  bool get isDisposed => _disposed;

  /// Release watchers, subscriptions and processes here — this is what makes
  /// closing a worktree free resources rather than just hide a tab.
  void dispose() {
    _disposed = true;
    unawaited(_changes.close());
  }
}

/// Builds a plugin's core for one worktree.
typedef PluginCoreFactory = PluginCore Function(PluginHost host);

/// Stands in for a plugin that is declared but has no core in this build.
///
/// Visible rather than skipped, for the same reason as `MissingPlugin`: a
/// declaration that silently vanishes looks like a config bug that never
/// surfaces. `fw` printing nothing for a declared plugin would be a lie.
class MissingPluginCore extends PluginCore {
  MissingPluginCore(super.host, {this.reason = 'no implementation'});

  final String reason;

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    status: Status.error(reason),
    badge: const StatusBadge.dot(Tone.error),
    view: PluginView([
      ViewText('No core is registered for "${host.id}" in this build.'),
      ViewField('Declared in', 'tool/flutterware.dart'),
    ]),
  );
}

/// Maps a declared plugin id to the core compiled into this binary.
///
/// The pure-Dart counterpart of `PluginRegistry`. They are deliberately
/// separate: the GUI's registry produces panels and cannot be linked into
/// `fw`, while this one produces behaviour and can be linked into both.
class PluginCoreRegistry {
  PluginCoreRegistry([Map<String, PluginCoreFactory>? factories])
    : _factories = {...?factories};

  final Map<String, PluginCoreFactory> _factories;

  Iterable<String> get ids => _factories.keys;

  void register(String id, PluginCoreFactory factory) {
    if (_factories.containsKey(id)) {
      throw StateError('A core is already registered for "$id".');
    }
    _factories[id] = factory;
  }

  bool knows(String id) => _factories.containsKey(id);

  PluginCore create(PluginHost host) =>
      (_factories[host.id] ?? MissingPluginCore.new)(host);

  /// Resolves a manifest into cores for one worktree, in declared order — the
  /// project's order, so `fw` prints the config file's shape.
  List<PluginCore> resolve(
    PluginManifest manifest,
    Worktree worktree,
    Workspace workspace,
  ) {
    // Resolved once and handed to every plugin: the catalog is one compiler
    // per package, and a plugin that works out its own roots forks it.
    var catalogRoots = catalogRootsFrom(manifest);
    var peers = {
      for (var declaration in manifest.plugins)
        declaration.id: declaration.config,
    };
    return [
      for (var declaration in manifest.plugins)
        create(
          PluginHost(
            id: declaration.id,
            label: declaration.label,
            worktree: worktree,
            workspace: workspace,
            config: declaration.config,
            projectClock: manifest.clock,
            projectNetwork: manifest.network,
            catalogRoots: catalogRoots,
            peers: peers,
          ),
        ),
    ];
  }
}

/// Warms every core, together.
///
/// Every surface that reports on all plugins at once wants this, and three of
/// them had written the `for … await` by hand.
///
/// Worth less than it looks, and the measurement is the interesting part.
/// Against the serial loop it was a third off — but nearly all of that was
/// three `pub deps` subprocesses overlapping, and `PubDepsStore` has since made
/// them one. What is left barely moves: 1390ms serial against 1300ms parallel,
/// measured 2026-09-09, because the remaining cores parse files on this isolate
/// and so queue behind each other whatever order they are started in.
/// Overlapping is still right — it costs nothing, and it is the honest shape of
/// "these are independent" — but a core that is slow is a core to make faster,
/// not one to hide behind a `Future.wait`.
///
/// A failure still surfaces, and surfaces better: `Future.wait` lets the rest
/// finish before it throws, where the serial loop abandoned every core after
/// the first one that failed.
Future<void> computeAllCores(Iterable<PluginCore> cores) =>
    Future.wait([for (var core in cores) core.computeAll()]);
