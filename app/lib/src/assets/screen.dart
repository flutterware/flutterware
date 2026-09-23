import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../address/address_scope.dart';
import '../plugins/native/assets_address.dart';
import '../plugins/native/assets_core.dart';
import 'detail.dart';
import 'folder.dart';
import 'list.dart';
import 'model/asset_catalog.dart';
import 'model/asset_scan.dart';
import 'model/asset_tree.dart';
import 'preview.dart';
import '../ui/error_state.dart';

/// The asset inspector, wired up.
///
/// The screen half of the split: it reads the address, reads the core's scan,
/// pulls the bytes off disk, and hands plain data to two views that know
/// nothing about any of that.
///
/// Every piece of state that names something is in the address — which
/// asset, which density, which frame, which backdrop. That is not tidiness: an
/// address with its axes resolved is what a preview will be captured *by* once
/// rendering moves into the guest, so a control whose value lives in a `State`
/// field is a control that cannot appear in an artifact.
class AssetsScreen extends StatefulWidget {
  const AssetsScreen(this.core, {required this.package, super.key});

  final AssetsCore core;

  /// The package whose bundle is on screen — the plugin's first segment, and
  /// the head of every segment list written from here.
  final String package;

  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  /// What the address names, whether or not anything answers to it. Held as
  /// well as [_asset] because it is what the list highlights: a directory is a
  /// selection too, and it has no [ResolvedAsset] to be.
  String? _key;

  ResolvedAsset? _asset;
  AssetFile? _file;

  /// The directory the address names, when it names one instead of an asset.
  AssetNode? _directory;

  /// Whether [_sync] has run against a scan yet.
  ///
  /// Held separately because `null` is a real address — the package with no
  /// key, which is where the rail leaves you — so "the key has not changed"
  /// and "nothing has been read yet" are otherwise the same two nulls, and the
  /// guard below returned early on the first build and left the pane blank.
  var _synced = false;

  Uint8List? _bytes;
  Object? _error;
  Size? _dimensions;

  /// Guards against an earlier, slower read landing after a later one.
  var _reads = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AssetsScreen old) {
    super.didUpdateWidget(old);
    // The scan can arrive after the address did, and the asset this names only
    // exists once it has.
    _sync();
  }

  AssetScan? get _scan => widget.core.scanFor(widget.package);

  /// Reading the address at the grain each thing is used at, so moving the
  /// frame does not re-read the file.
  void _sync() {
    var key = assetPlace(AddressScope.segments(context))?.assetKey;
    var density = AddressScope.param(context, 'density');

    var asset = key == null ? null : _scan?.catalog.byKey[key];
    var file = asset == null ? null : _fileFor(asset, density);

    // Nothing this address names has changed. Guarded on the key rather than on
    // the resolved asset because resolving a *directory* means folding the
    // bundle into a tree, and a change of zoom must not pay for that.
    if (_synced && key == _key && file?.key == _file?.key) return;
    if (_scan == null) return;

    _synced = true;
    _key = key;
    _asset = asset;
    _file = file;
    // A key that resolves to no asset may still name a place: `assets/images`
    // is the same address grammar as `assets/images/logo.png`, and the tree is
    // the only thing that knows which of the two it is.
    // A key that resolves to no asset may still name a place: `assets/images`
    // is the same address grammar as `assets/images/logo.png`. And *no* key is
    // a place too — the whole of this package's bundle, which is what the
    // panel should open on rather than an empty pane telling you to pick
    // something.
    _directory = asset != null
        ? null
        : key == null
        ? _rootNode()
        : _directoryFor(key);
    // Assigned rather than `setState`d: this runs from `didChangeDependencies`,
    // which is inside the build phase, and a rebuild is already coming. The
    // read below is what needs `setState`, and it only reaches one after its
    // first `await`.
    _bytes = null;
    _error = null;
    _dimensions = null;
    if (file != null) unawaited(_read(asset!, file, ++_reads));
  }

  /// The whole of this package's own bundle, folded — where the panel lands
  /// with nothing selected.
  ///
  /// Null when the package declares nothing, because a contact sheet of no
  /// assets says less than the empty state's sentence about what to do next.
  AssetNode? _rootNode() {
    var own = _scan?.own ?? const <ResolvedAsset>[];
    return own.isEmpty ? null : AssetTree.of(own).root;
  }

  /// The directory [key] names, in this package's own assets or in any
  /// dependency's.
  ///
  /// Each section is folded on its own, exactly as the list folds it, so a
  /// dependency's `packages/<name>/assets/images` is the node the reader
  /// clicked and not a lookalike under the root.
  AssetNode? _directoryFor(String key) {
    var scan = _scan;
    if (scan == null) return null;
    for (var assets in [
      scan.own,
      for (var owner in scan.fromPackages) owner.assets,
    ]) {
      if (AssetTree.of(assets).nodeAt(key) case var node?) return node;
    }
    return null;
  }

  /// The file the density axis names, falling back to the main asset — an
  /// address carrying a density the asset does not have should show the asset,
  /// not nothing.
  AssetFile _fileFor(ResolvedAsset asset, String? density) {
    var scale = density == null ? null : AssetCatalog.parseScale('$density/');
    if (scale == null) return asset.main;
    for (var file in asset.files) {
      if (file.scale == scale) return file;
    }
    return asset.main;
  }

  Future<void> _read(ResolvedAsset asset, AssetFile file, int token) async {
    try {
      var bytes = await File(file.path).readAsBytes();
      var size = assetKindOf(asset.key) == AssetKind.image
          ? await _measure(bytes)
          : null;
      if (!mounted || token != _reads) return;
      setState(() {
        _bytes = bytes;
        _dimensions = size;
      });
    } catch (e) {
      if (!mounted || token != _reads) return;
      setState(() => _error = e);
    }
  }

  /// Pixel dimensions, decoded here rather than read from the core.
  ///
  /// The core could answer this — `image` is pure Dart — and one day should, so
  /// `fw describe` can too. Until then the panel is the only surface asking,
  /// and `dart:ui` is already decoding these bytes to draw them.
  Future<Size?> _measure(Uint8List bytes) async {
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      frame = await codec.getNextFrame();
      return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    } catch (_) {
      // A raster we cannot decode still has a preview to try and a size in
      // bytes to report; only the dimensions go missing.
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  void _select(String key) => AddressScope.write(context).update(
    segments: assetSegments(widget.package, key),
    // Density and frame belong to the asset they were chosen for. Carrying
    // `frame=42` onto a PNG would name a state that does not exist.
    params: {'density': null, 'frame': null},
  );

  @override
  Widget build(BuildContext context) {
    if (widget.core.failureFor(widget.package) case var failure?) {
      return ErrorState(
        title: 'Could not read the assets',
        message: failure,
        // The failure names its own fix — run pub get — and this is how coming
        // back from it lands without restarting the app.
        onRetry: () => unawaited(widget.core.reload(widget.package)),
      );
    }
    var scan = _scan;
    if (scan == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 320,
          child: AssetListView(
            own: scan.own,
            fromPackages: scan.fromPackages,
            problems: scan.problems,
            selected: _key,
            onSelect: _select,
            onReload: () => unawaited(widget.core.reload(widget.package)),
            scanning: widget.core.isScanning(widget.package),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _detail(context)),
      ],
    );
  }

  Widget _detail(BuildContext context) {
    if (_directory case var directory?) {
      return AssetFolderView(
        node: directory,
        // The node's own path when the address stopped at the package: the
        // heading names what is on screen, and an empty string names nothing.
        path: _key ?? directory.path,
        onSelect: _select,
      );
    }
    var asset = _asset;
    var file = _file;
    if (asset == null || file == null) return const AssetDetailEmpty();

    var address = AddressScope.of(context);
    return AssetDetailView(
      asset: asset,
      file: file,
      bytes: _bytes,
      error: _error,
      dimensions: _dimensions,
      background: _background(AddressScope.param(context, 'bg')),
      onBackground: (value) => address.setParam(
        'bg',
        value == PreviewBackground.checker ? null : value.name,
      ),
      zoom: double.tryParse(AddressScope.param(context, 'zoom') ?? '') ?? 1,
      onZoom: (value) =>
          address.setParam('zoom', value == 1 ? null : '${value.toInt()}'),
      onDensity: (value) => address.setParam(
        'density',
        value.scale == null ? null : '${value.scale}x',
      ),
      frame: int.tryParse(AddressScope.param(context, 'frame') ?? ''),
      onFrame: (value) => address.setParam('frame', '$value'),
    );
  }

  PreviewBackground _background(String? name) {
    for (var option in PreviewBackground.values) {
      if (option.name == name) return option;
    }
    return PreviewBackground.checker;
  }
}
