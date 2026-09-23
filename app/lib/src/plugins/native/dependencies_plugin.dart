import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../address/address_scope.dart';
import '../../dependencies/list.dart';
import '../native_plugin.dart';
import 'dependencies_core.dart';
import 'no_packages.dart';

export 'dependencies_core.dart' show DependenciesCore, dependenciesPluginId;

/// The GUI half of the dependencies plugin: a panel, and literally nothing
/// else.
///
/// Every decision — what the report says, which packages are declared, what
/// `reload` does — lives in [DependenciesCore], which is pure Dart so that
/// `fw` and an agent reach exactly the same behaviour. This class exists only
/// because `buildPanel` returns a `Widget`.
class DependenciesPlugin extends NativePlugin<DependenciesCore> {
  DependenciesPlugin(super.core);

  List<String> get packages => core.packages;

  /// Resolution is a `pub deps` subprocess, so the panel draws an empty table
  /// under the word "loading…" for a moment. Long enough that the first
  /// generated screenshot of it caught exactly that.
  @override
  String? get busyWith => core.isLoading ? 'resolving dependencies' : null;

  @override
  Widget buildPanel(BuildContext context) => _DependenciesPanel(this);
}

/// Owns the subscription: mounting starts the load, unmounting releases it.
/// With several packages it shows a picker and tracks only the visible one.
class _DependenciesPanel extends StatefulWidget {
  const _DependenciesPanel(this.plugin);

  final DependenciesPlugin plugin;

  @override
  State<_DependenciesPanel> createState() => _DependenciesPanelState();
}

class _DependenciesPanelState extends State<_DependenciesPanel> {
  String? _tracked;
  String? _path;

  DependenciesCore get _core => widget.plugin.core;

  /// The package the address names, or the first declared one when it names
  /// none — which is where selecting the plugin off the rail leaves you.
  String? _resolve() =>
      AddressScope.segment(context, 0) ?? _core.packages.firstOrNull;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Where the address arrives, and where a later move to another package
    // arrives too: reading segment 0 subscribes to segment 0 and nothing else.
    _path = _resolve();
    _retrack();
  }

  @override
  void didUpdateWidget(_DependenciesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The declared packages can change under a reload without the address
    // moving, and the fallback above is computed from them.
    _path = _resolve();
    _retrack();
  }

  /// Follows the address: only the visible package is subscribed, so moving to
  /// another stops the old load and starts the new one.
  void _retrack() {
    var wanted = _path;
    if (wanted == _tracked) return;
    if (_tracked != null) _core.untrack(_tracked!);
    _tracked = wanted;
    if (wanted != null) _core.track(wanted);
  }

  @override
  void dispose() {
    if (_tracked != null) _core.untrack(_tracked!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var path = _path ?? _resolve();
    if (path == null) {
      return const NoPackagesConfigured(icon: Icons.inventory_2_outlined);
    }

    // The package goes down with the service because everything below writes
    // whole plugin-level segment lists, and every one of them starts with it.
    return DependenciesScreen(
      _core.serviceFor(path),
      package: path,
      key: ValueKey(path),
    );
  }
}
