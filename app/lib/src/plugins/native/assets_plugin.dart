import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../address/address_scope.dart';
import '../../assets/screen.dart';
import '../native_plugin.dart';
import 'assets_core.dart';
import 'no_packages.dart';

export 'assets_core.dart' show AssetsCore, assetsPluginId;

/// The GUI half of the asset inspector: a panel, and nothing else.
///
/// What the plugin *knows* — which keys resolve, what is wrong with the ones
/// that do not, where each file came from — is all in [AssetsCore], so `fw` and
/// an agent reach the same answers. This class exists because `buildPanel`
/// returns a `Widget`.
class AssetsPlugin extends NativePlugin<AssetsCore> {
  AssetsPlugin(super.core);

  @override
  Widget buildPanel(BuildContext context) => _AssetsPanel(this);
}

/// Owns the subscription: mounting starts the scan, and only the package the
/// address names is tracked.
class _AssetsPanel extends StatefulWidget {
  const _AssetsPanel(this.plugin);

  final AssetsPlugin plugin;

  @override
  State<_AssetsPanel> createState() => _AssetsPanelState();
}

class _AssetsPanelState extends State<_AssetsPanel> {
  String? _tracked;
  String? _path;

  AssetsCore get _core => widget.plugin.core;

  /// The package the address names, or the first declared one when it names
  /// none — which is where selecting the plugin off the rail leaves you.
  String? _resolve() =>
      AddressScope.segment(context, 0) ?? _core.packages.firstOrNull;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _path = _resolve();
    _retrack();
  }

  @override
  void didUpdateWidget(_AssetsPanel old) {
    super.didUpdateWidget(old);
    _path = _resolve();
    _retrack();
  }

  void _retrack() {
    var wanted = _path;
    if (wanted == _tracked) return;
    _tracked = wanted;
    if (wanted != null) _core.track(wanted);
  }

  @override
  Widget build(BuildContext context) {
    var path = _path ?? _resolve();
    if (path == null) {
      return const NoPackagesConfigured(icon: Icons.image_outlined);
    }

    // Rebuilds when a scan lands: the core notifies, the plugin forwards.
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) =>
          AssetsScreen(_core, package: path, key: ValueKey(path)),
    );
  }
}
