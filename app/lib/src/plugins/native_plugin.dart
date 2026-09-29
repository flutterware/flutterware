import 'dart:async';

import 'package:flutter/widgets.dart';

import '../capture/settle.dart';
import 'plugin_core.dart';
import 'plugin_host.dart';

/// The GUI-side runtime of a native plugin — one instance per open worktree.
///
/// A panel over a [PluginCore], and nothing more. The core holds the
/// behaviour: the report, the actions, what `reload` does. This class exists
/// because `buildPanel` returns a `Widget` and a `Widget` cannot be linked into
/// `fw`.
///
/// There is deliberately no `report` on this class. Callers read
/// `plugin.core.report`. Dart cannot seal a member, so the only way to stop a
/// panel overriding the report — becoming a second, disagreeing answer to what
/// the sidebar shows — is not to give it one to override.
///
/// A panel calls its core directly, and no panel invokes an action.
/// `Session.invoke` has two callers, `fw` and MCP; a dialog that configures a
/// run, streams its output for tens of seconds and then offers to open the
/// result is not a shape that method can express — `JobEvent` has no log or
/// progress case, and `PluginCore.invoke` has no sink to report one through.
///
/// What the split does forbid is a capability that exists *only* here.
/// `web_build_dialog.dart` calls `core.buildWeb`, and `build-web` is a declared
/// action the other two surfaces reach on their own — which is also why that
/// dialog can print the equivalent command. A panel holding behaviour its core
/// does not have is the drift this arrangement exists to prevent.
abstract class NativePlugin<C extends PluginCore> extends ChangeNotifier
    implements SettleSource {
  NativePlugin(this.core) {
    // `skip(1)` drops the replay. A ValueStream hands every new subscriber the
    // value that was already current, and "what it already was" is not a
    // change — without this, constructing a panel notifies the shell that
    // something moved before the panel has drawn anything at all.
    _changes = core.changes.stream.skip(1).listen((_) => notifyListeners());
  }

  /// The behaviour this panel draws. Owned by the [Session] that resolved it,
  /// not by this — closing the worktree disposes the session, which disposes
  /// the cores.
  final C core;

  late final StreamSubscription<int> _changes;

  PluginHost get host => core.host;

  String get id => core.id;

  /// Another panel of the same worktree, by its plugin's id; null when the
  /// project declares none. For a panel that shows another plugin's views —
  /// Worlds shows Run's of each person's app — rather than drawing its own
  /// copy of them. Set by the [WorktreeSession] that holds them both.
  NativePlugin? Function(String id) peer = (_) => null;

  /// What this plugin is still working on, or null when it has nothing in
  /// flight.
  ///
  /// Read by a window capture, which must not photograph a panel that is still
  /// filling in — see [SettleSource]. **Null by default, deliberately**: a
  /// plugin that never answers is treated as settled, so the cost of not
  /// implementing this is a picture taken slightly early rather than a capture
  /// that never returns.
  ///
  /// That default is not free, and this getter exists because it was paid: the
  /// first generated screenshot of the dependencies panel caught it mid-resolve
  /// — an empty table under the word "loading…", reported as a success.
  ///
  /// Answer from the same state the panel draws from, not from a second flag.
  /// A plugin whose idea of busy can disagree with what it renders will
  /// eventually be photographed at exactly the moment they differ.
  @override
  String? get busyWith => null;

  /// The panel mounted when this plugin is selected. Real Flutter, no limits.
  ///
  /// Takes no selection argument. Where the panel is comes from the
  /// address, which it reads through `AddressScope` — installed by the shell
  /// directly above this widget, already past the worktree and the plugin id,
  /// so segment 0 is the plugin's own first segment.
  ///
  /// It used to be handed one `childId`, and that was the bug rather than a
  /// simplification: an address naming a package *and* an entry arrived here as
  /// the package alone, so a search hit opened the right plugin showing the
  /// wrong thing. A parameter can only carry what the shell thought to put in
  /// it, and the shell deliberately does not understand what is below the
  /// plugin segment.
  ///
  /// Read at the grain you need — `AddressScope.segment(context, 0)` for a
  /// package, `AddressScope.param(context, …)` for one control's value — and
  /// the panel rebuilds for the part that moved rather than for the fact that
  /// something did.
  Widget buildPanel(BuildContext context);

  /// Commands offered on one of this plugin's sidebar rows, behind a ⋮ that
  /// appears on hover. Empty for most plugins, and then no ⋮ is drawn.
  ///
  /// [childId] is the [PluginChild.id] the row stands for — a package path, for
  /// every plugin that has children today.
  ///
  /// Built during the row's build, so a command may close over [context] to put
  /// something on screen when it is chosen.
  List<PluginChildCommand> childCommands(
    BuildContext context,
    String childId,
  ) => const [];

  /// Openings offered on the plugin's *own* sidebar row, drawn as icon buttons
  /// that appear on hover — the `+` beside `Run` that starts one.
  ///
  /// Distinct from [childCommands], which hangs a menu off one child. This is
  /// about the plugin as a whole, and it is deliberately narrower than a
  /// callback: a command here names a **place**, and the shell navigates to it.
  /// That keeps the rail out of the business of running plugin code, and it
  /// means the affordance and a typed address do the same thing.
  ///
  /// Added when the run cockpit's run list moved into the rail and its `+ New
  /// run` chip needed somewhere to go. The rail is ours to teach; there was no
  /// reason to design around it.
  List<PluginRowCommand> rowCommands() => const [];

  /// Where the rail's row for this plugin lands, as address segments.
  ///
  /// Null means *the child you were last in, or the first one*, which is
  /// `ShellController.selectPlugin`'s fill-in and is right for every plugin
  /// whose children are **packages**: a stable set, where landing on one is
  /// landing somewhere.
  ///
  /// It is wrong for a plugin whose children are **instances**. The run
  /// cockpit's children are its runs, and its failures, and clicking `Run`
  /// therefore opened whichever run sorted first — so the launch form, the
  /// device desk and the only emulator-boot control in the GUI had no row at
  /// all for as long as anything was running, and one undismissed failure did
  /// the same. `_RunPanel` had always handled the empty address correctly; it
  /// was simply never given it, and the test that closed the question asserted
  /// against the *panel* rather than against the rail that decides.
  ///
  /// Answer with the plugin's own landing when "the first one" is not a place.
  List<String>? get railLanding => null;

  /// Schedules a change notification, coalescing bursts into one.
  ///
  /// Prefer this over [notifyListeners]. A plugin's work starts when a widget
  /// subscribes, and that happens in `initState` — inside the build phase,
  /// where marking the shell dirty synchronously throws
  /// "setState() called during build". Deferring by a microtask makes the
  /// common case safe instead of leaving every plugin to remember.
  ///
  /// Changes originating in the core already arrive this way, so this is for
  /// state the *panel* owns.
  @protected
  void notifyChanged() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  var _notifyScheduled = false;
  var _disposed = false;

  /// Called when the worktree is closed. Release whatever the *panel* holds —
  /// the core is released by the session.
  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes.cancel());
    super.dispose();
  }
}

/// One command on a sidebar child's ⋮ menu.
///
/// Deliberately not a [PluginAction]. An action is behaviour every renderer
/// can reach by name; these are the GUI's own affordances — a form to fill in
/// first, a log to watch while it runs, somewhere to go when it finishes. None
/// of that survives being described to `fw`.
///
/// It is not a way to put behaviour in a panel either. What a command drives
/// still belongs on the [PluginCore], where `fw` and MCP reach the same method
/// by their own route; the difference is only that the GUI can hand it a
/// progress callback, which an invocation across a process cannot carry.
class PluginChildCommand {
  const PluginChildCommand({
    required this.label,
    required this.onSelected,
    this.icon,
    this.danger = false,
  });

  final String label;
  final IconData? icon;

  /// Destroys data. The row is tinted for it.
  final bool danger;

  final void Function(BuildContext context) onSelected;
}

/// A place inside a plugin, offered as a button on its sidebar row.
///
/// It names where to go rather than what to run, so the same button and the
/// same typed address land in the same state — and the shell needs no way to
/// call back into a plugin to draw it.
class PluginRowCommand {
  const PluginRowCommand({
    required this.label,
    required this.icon,
    required this.opens,
  });

  /// The tooltip. There is no room for it on the row itself.
  final String label;

  final IconData icon;

  /// The first segment under the plugin — what an address would carry there.
  /// `new`, for the run cockpit's page that starts one.
  final String opens;
}

/// Builds a plugin's panel over the core the session already resolved.
typedef NativePluginFactory = NativePlugin Function(PluginCore core);

/// Adapts a panel that wants a specific core to the registry's untyped factory.
///
/// The cast is checked rather than assumed. The two registries are separate
/// maps — one produces panels, one produces behaviour — so a panel registered
/// for an id whose core is missing or is somebody else's must degrade to a
/// visible [MissingPlugin] rather than throw halfway through opening a
/// worktree.
NativePluginFactory panelFor<C extends PluginCore>(
  NativePlugin Function(C core) build,
) =>
    (core) => core is C
    ? build(core)
    : MissingPlugin(
        core,
        reason:
            'The panel registered for "${core.id}" needs a $C, but this build '
            'resolved a ${core.runtimeType}.',
      );

/// Stands in for a plugin the project declared but this build has no panel for.
///
/// Deliberately visible rather than skipped: a declaration that silently
/// vanishes looks like a config bug that never surfaces, and after the
/// declarative tier lands, an unknown id is the normal symptom of a version
/// mismatch. It must be legible.
///
/// Its [report] is still the core's. When the core exists and only the panel is
/// missing, the sidebar shows the plugin's real status and only the panel says
/// anything is wrong — which is true, and more useful than hiding a working
/// plugin behind an error.
class MissingPlugin extends NativePlugin {
  MissingPlugin(super.core, {this.reason});

  /// Why there is no panel, when it is more specific than "none registered".
  final String? reason;

  @override
  Widget buildPanel(BuildContext context) =>
      _MissingPanel(host: host, reason: reason);
}

class _MissingPanel extends StatelessWidget {
  const _MissingPanel({required this.host, this.reason});

  final PluginHost host;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          reason ??
              'No native plugin is registered for "${host.id}".\n'
                  'It is declared in tool/flutterware.dart but this build does '
                  'not implement it.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
