import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../address/address_scope.dart';
import '../../launcher_icon/model/role.dart';
import '../../launcher_icon/screen.dart';
import '../native_plugin.dart';
import 'icon_address.dart';
import 'icon_core.dart';
import 'no_packages.dart';

export 'icon_core.dart' show LauncherIconCore, launcherIconPluginId;

/// The GUI half of the launcher-icon viewer: a panel, and nothing else.
///
/// What the plugin *knows* — which files exist, which the project references,
/// what each OS does with them — is all in [LauncherIconCore], so `fw` and an
/// agent reach the same answers. This class exists because `buildPanel` returns
/// a `Widget`.
class LauncherIconPlugin extends NativePlugin<LauncherIconCore> {
  LauncherIconPlugin(super.core, {this.image = fileIconImage});

  /// How the panel turns a scanned file into a picture. The live panel reads
  /// the file; a panel over a recorded core reads wherever the recording
  /// keeps its files. See [LauncherIconScreen.image].
  final IconImage image;

  @override
  Widget buildPanel(BuildContext context) => _LauncherIconPanel(this);
}

/// Owns the subscription: mounting starts the scan, and only the package the
/// address names is tracked.
class _LauncherIconPanel extends StatefulWidget {
  const _LauncherIconPanel(this.plugin);

  final LauncherIconPlugin plugin;

  @override
  State<_LauncherIconPanel> createState() => _LauncherIconPanelState();
}

class _LauncherIconPanelState extends State<_LauncherIconPanel> {
  String? _tracked;
  IconPlace? _place;

  LauncherIconCore get _core => widget.plugin.core;

  /// Where the address points, or the first declared package when it names
  /// none — which is where selecting the plugin off the rail leaves you.
  ///
  /// Read at the grain the panel needs: the package and flavour decide what to
  /// scan, and the role and mask only decide which tile is outlined, so
  /// changing either must not re-track anything.
  IconPlace? _resolve() {
    var segment = AddressScope.segment(context, 0);
    var package = segment ?? _core.packages.firstOrNull;
    if (package == null) return null;
    return IconPlace(
      package,
      flavor: AddressScope.segment(context, 1),
      role: IconRole.byId(AddressScope.param(context, 'role') ?? ''),
      mask: AdaptiveMask.byName(AddressScope.param(context, 'mask') ?? ''),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _place = _resolve();
    _retrack();
  }

  @override
  void didUpdateWidget(_LauncherIconPanel old) {
    super.didUpdateWidget(old);
    _place = _resolve();
    _retrack();
  }

  /// A flavour is a different set of files, so it is part of what is tracked —
  /// unlike the role and mask, which are the same scan seen differently.
  void _retrack() {
    var place = _place;
    if (place == null) return;
    var wanted = place.flavor == null
        ? place.package
        : '${place.package} ${place.flavor}';
    if (wanted == _tracked) return;
    _tracked = wanted;
    _core.track(place.package, flavor: place.flavor);
  }

  @override
  Widget build(BuildContext context) {
    var place = _place ?? _resolve();
    if (place == null) {
      return const NoPackagesConfigured(icon: Icons.apps_outlined);
    }

    // Rebuilds when a scan lands: the core notifies, the plugin forwards.
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) => LauncherIconScreen(
        _core,
        key: ValueKey('${place.package}/${place.flavor}'),
        package: place.package,
        flavor: place.flavor,
        role: place.role,
        mask: place.mask,
        image: widget.plugin.image,
      ),
    );
  }
}
