import 'package:flutter/foundation.dart';
import 'package:flutterware/plugins.dart';

import '../session/job.dart';
import '../identity/project_face.dart';
import '../session/session.dart';
import '../shell/workspace.dart';
import '../shell/worktree.dart';
import 'native_plugin.dart';
import 'plugin_core.dart';
import 'registry.dart';

/// One *open* worktree in the GUI: a [Session], and a panel for each of its
/// plugins.
///
/// It wraps a session rather than being one. The two used to be parallel
/// implementations — same plugin list in the same order, same `reports`, same
/// lookup, one over panels and one over cores — and parallel implementations
/// of the same thing are how a GUI ends up able to do something no other
/// renderer can. Everything below the panels now comes from [session], so the
/// sidebar and `fw` cannot disagree, and [invoke] is the same single door the
/// CLI and MCP go through.
///
/// The unit of the open/close lifecycle. Closing a worktree disposes this,
/// which disposes every panel and then the session's cores — that is what makes
/// closing a tab release watchers and subscriptions rather than merely hide
/// them.
///
/// Worktrees that are known but not open have no session at all; anything the
/// switcher shows for them has to come from somewhere cheaper.
class WorktreeSession extends ChangeNotifier {
  WorktreeSession({required this.session, required List<NativePlugin> plugins})
    : plugins = List.unmodifiable(plugins) {
    for (var plugin in this.plugins) {
      plugin.peer = pluginById;
      plugin.addListener(notifyListeners);
      // Every panel, not the ones that remembered to ask. A capture must not
      // photograph a worktree whose panels are still filling in, and which
      // plugins can be slow is not knowable from here — `NativePlugin.busyWith`
      // answers null unless the plugin overrides it, so this costs nothing for
      // the ones that are always ready.
      plugin.host.workspace.appContext.settle.add(plugin);
    }
  }

  /// Resolves a manifest into cores, then draws a panel over each.
  ///
  /// The order matters and is not an accident: cores first, because which
  /// plugins exist is not the GUI's decision to make.
  factory WorktreeSession.resolve({
    required Worktree worktree,
    required PluginManifest manifest,
    required PluginRegistry registry,
    required Workspace workspace,
    PluginCoreRegistry? coreRegistry,
  }) {
    var session = Session.resolved(
      worktree: worktree,
      workspace: workspace,
      manifest: manifest,
      registry: coreRegistry,
    );
    return WorktreeSession(
      session: session,
      plugins: registry.resolve(session.cores),
    );
  }

  /// The plugin behaviour, shared with every other renderer.
  final Session session;

  Worktree get worktree => session.worktree;

  /// The picture that stands for this project, or null when it has none.
  ///
  /// Lazy on purpose: resolving it walks a package's platform directories, and
  /// most of what builds a session — every widget test in this suite — never
  /// asks. Computed once per session, so a reload is what re-reads it, which is
  /// also the moment the icon on disk could have changed.
  late final ProjectFace? face = resolveProjectFace(
    worktreeRoot: session.root,
    manifest: session.manifest,
  );

  /// The resolved panels, in the order `tool/flutterware.dart` declared them.
  final List<NativePlugin> plugins;

  bool get isDisposed => _disposed;
  var _disposed = false;

  NativePlugin? pluginById(String id) =>
      plugins.where((p) => p.id == id).firstOrNull;

  /// Every plugin's contract, in declared order — what the sidebar renders and
  /// what `fw` / an agent read for this worktree. The same objects, from the
  /// same cores.
  List<PluginReport> get reports => session.reports;

  /// Runs one of the declared actions.
  ///
  /// Straight through to [Session.invoke], deliberately without a GUI-specific
  /// path: a button and `fw run` must be the same call, or the parity rule is
  /// enforced for two renderers out of three.
  Job invoke(
    String plugin,
    String action, {
    Map<String, Object?> arguments = const {},
  }) => session.invoke(plugin, action, arguments: arguments);

  /// The worktree's own reduced state: the most severe plugin status wins, so
  /// the tab and the switcher row can show one glyph.
  Status get status {
    Status? worst;
    for (var report in reports) {
      if (report.status.isEmpty) continue;
      if (worst == null || report.status.tone.index > worst.tone.index) {
        worst = report.status;
      }
    }
    return worst ?? Status.none;
  }

  /// Teardown steps from every plugin, ordered by phase then declaration.
  List<TeardownStep> get teardownSteps {
    var steps = [for (var report in reports) ...report.teardown];
    steps.sort((a, b) => a.phase.index.compareTo(b.phase.index));
    return steps;
  }

  /// Every plugin's objection to closing this worktree.
  List<Guard> get guards => [for (var report in reports) ...report.guards];

  /// True when some plugin hard-blocks teardown.
  bool get isBlocked => guards.any((g) => g.level == GuardLevel.block);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Panels first, then the behaviour under them: a panel disposing after its
    // core would be drawing something already torn down.
    for (var plugin in plugins) {
      plugin.removeListener(notifyListeners);
      plugin.host.workspace.appContext.settle.remove(plugin);
      plugin.dispose();
    }
    session.dispose();
    super.dispose();
  }
}
