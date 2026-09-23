import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

import '../../address/address_scope.dart';
import '../../splash/model/surface.dart';
import '../../splash/screen.dart';
import '../../splash/ui/splash_render.dart'
    show SplashImage, SplashImages, fileSplashImage;
import '../native_plugin.dart';
import 'splash_address.dart';
import 'splash_core.dart';
import 'no_packages.dart';

export 'splash_core.dart' show SplashCore, splashPluginId;

/// The GUI half of the splash previewer: a panel, and nothing else.
///
/// What the plugin *knows* — what each surface resolves to, which key won, what
/// the generator would refuse — is all in [SplashCore], so `fw` and an agent
/// reach the same answers. This class exists because `buildPanel` returns a
/// `Widget`.
class SplashPlugin extends NativePlugin<SplashCore> {
  SplashPlugin(super.core, {this.image = fileSplashImage});

  /// The picture at a path the scan found — a file on disk, unless a
  /// recording is standing in for one.
  final SplashImage image;

  @override
  Widget buildPanel(BuildContext context) =>
      SplashImages(image: image, child: _SplashPanel(this));
}

/// Owns the subscription: mounting starts the scan, and only the package the
/// address names is tracked.
class _SplashPanel extends StatefulWidget {
  const _SplashPanel(this.plugin);

  final SplashPlugin plugin;

  @override
  State<_SplashPanel> createState() => _SplashPanelState();
}

class _SplashPanelState extends State<_SplashPanel> {
  String? _tracked;
  SplashPlace? _place;

  /// Released on dispose, which is what stops a closed panel from going on
  /// `stat`ing a package nobody is looking at.
  void Function()? _releasePolling;

  SplashCore get _core => widget.plugin.core;

  @override
  void initState() {
    super.initState();
    _releasePolling = _core.retain();
  }

  @override
  void dispose() {
    _releasePolling?.call();
    super.dispose();
  }

  /// Where the address points, or the first declared package when it names
  /// none — which is where selecting the plugin off the rail leaves you.
  ///
  /// Read at the grain the panel needs: the package decides what to scan, and
  /// the axes only decide which tile is outlined, so a change of surface must
  /// not re-track anything.
  SplashPlace? _resolve() {
    var segment = AddressScope.segment(context, 0);
    var package = segment ?? _core.packages.firstOrNull;
    if (package == null) return null;
    return SplashPlace(
      package,
      flavor: AddressScope.segment(context, 1),
      surface: SplashSurface.byName(
        AddressScope.param(context, 'surface') ?? '',
      ),
      theme: SplashTheme.byName(AddressScope.param(context, 'theme') ?? ''),
      size: AddressScope.param(context, 'size'),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _place = _resolve();
    _retrack();
  }

  @override
  void didUpdateWidget(_SplashPanel old) {
    super.didUpdateWidget(old);
    _place = _resolve();
    _retrack();
  }

  void _retrack() {
    var wanted = _place?.package;
    if (wanted == _tracked) return;
    _tracked = wanted;
    if (wanted != null) _core.track(wanted);
  }

  @override
  Widget build(BuildContext context) {
    var place = _place ?? _resolve();
    if (place == null) {
      return const NoPackagesConfigured(icon: Icons.smartphone_outlined);
    }

    // Rebuilds when a scan lands: the core notifies, the plugin forwards.
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) => SplashScreen(
        _core,
        key: ValueKey(place.package),
        package: place.package,
        flavor: place.flavor,
        surface: place.surface,
        theme: place.theme,
        size: SplashScreenSize.byId(place.size ?? ''),
        // The address is written from here rather than from the screen: this is
        // the half that lives inside an `AddressScope`, and keeping the screen
        // free of it is what lets a test mount it with no address at all.
        onSelectCell: (surface, theme) =>
            AddressScope.write(context)
                .setParams({'surface': surface.name, 'theme': theme.name}),
        onShowAll: () =>
            AddressScope.write(context)
                .setParams({'surface': null, 'theme': null}),
        onSelectSize: (size) =>
            AddressScope.write(context).setParams({'size': size?.id}),
        // The flavor is a segment, not an axis: it selects a different config
        // file, and everything below it — every cell, every problem, every
        // generated file — belongs to that file rather than to this one.
        onSelectFlavor: (name) =>
            AddressScope.write(context).setSegments([place.package, ?name]),
      ),
    );
  }
}
