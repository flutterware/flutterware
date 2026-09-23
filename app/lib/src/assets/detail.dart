import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../ui/field_row.dart';
import '../ui/empty_state.dart';
import '../ui/theme.dart';
import 'model/asset_catalog.dart';
import 'model/asset_scan.dart';
import 'preview.dart';
import '../ui/error_state.dart';

/// The right half: one asset, drawn, and then said in words.
///
/// A view. Everything it shows arrives as data and everything it changes leaves
/// as a callback, because the state it appears to own — which density, which
/// background, which frame — lives in the address, and the address belongs to
/// the screen above it.
class AssetDetailView extends StatelessWidget {
  const AssetDetailView({
    super.key,
    required this.asset,
    required this.file,
    required this.bytes,
    required this.error,
    required this.dimensions,
    required this.background,
    required this.onBackground,
    required this.zoom,
    required this.onZoom,
    required this.onDensity,
    this.frame,
    this.onFrame,
  });

  final ResolvedAsset asset;

  /// Which of the asset's files is on screen — the main one, or a density
  /// variant the reader asked for.
  final AssetFile file;

  /// Null while reading.
  final Uint8List? bytes;

  /// Set when the file could not be read at all, which is a different failure
  /// from bytes that will not decode.
  final Object? error;

  /// Pixel dimensions, once known. Null for anything not a raster.
  final Size? dimensions;

  final PreviewBackground background;
  final ValueChanged<PreviewBackground> onBackground;

  final double zoom;
  final ValueChanged<double> onZoom;

  final ValueChanged<AssetFile> onDensity;

  final int? frame;
  final ValueChanged<int>? onFrame;

  static const _zooms = [1.0, 2.0, 4.0, 8.0];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(context),
        Expanded(child: _preview(context)),
        const Divider(height: 1),
        Expanded(child: _metadata(context)),
      ],
    );
  }

  Widget _preview(BuildContext context) {
    if (error case var failure?) {
      return ErrorState(title: 'Could not read this file', message: '$failure');
    }
    var data = bytes;
    if (data == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return AssetPreview(
      // Keyed by what is being drawn, so switching density or asset rebuilds
      // the specimen and the player rather than reusing one mid-animation.
      key: ValueKey(file.key),
      bytes: data,
      kind: assetKindOf(asset.key),
      name: asset.key,
      background: background,
      zoom: zoom,
      frame: frame,
      onFrame: onFrame,
    );
  }

  Widget _toolbar(BuildContext context) {
    var colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FwSpacing.md,
        vertical: FwSpacing.sm,
      ),
      // Wraps rather than fills: the pane is half a window and can be dragged
      // narrower than three control groups, and a toolbar that overflows is
      // worse than one on two lines.
      child: Wrap(
        spacing: FwSpacing.lg,
        runSpacing: FwSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (asset.files.length > 1) _densities(context),
          _segmented(context, [
            for (var option in PreviewBackground.values)
              (option.label, option == background, () => onBackground(option)),
          ]),
          // Magnification only means something for a thing drawn at a size. A
          // font specimen is set in points and an animation fills the pane, so
          // offering either a zoom offers a control that does nothing.
          if (_zoomable)
            _segmented(context, [
              for (var option in _zooms)
                (
                  // Per cent, not `×`. `2×` next to the density switcher's `2×`
                  // reads as the same thing said twice, and they are not even
                  // the same kind of thing: one picks a file, the other magnifies
                  // whichever file that picked.
                  '${(option * 100).toInt()}%',
                  option == zoom,
                  () => onZoom(option),
                ),
            ], label: 'Zoom'),
        ],
      ),
    );
  }

  /// Whether magnifying this asset would show anything a reader cannot already
  /// see. True for the two kinds that are drawn at a size.
  bool get _zoomable => switch (assetKindOf(asset.key)) {
    AssetKind.image || AssetKind.vector => true,
    AssetKind.font ||
    AssetKind.data ||
    AssetKind.media ||
    AssetKind.other => false,
  };

  /// The density switcher. Only shown when there is something to switch
  /// between — which in practice means a raster, since nothing else ships
  /// resolution variants — and labelled with the scale the engine reads rather
  /// than the directory name.
  Widget _densities(BuildContext context) => _segmented(context, [
    for (var candidate in asset.files)
      (
        candidate.scale == null ? '1×' : '${_trim(candidate.scale!)}×',
        candidate.key == file.key,
        () => onDensity(candidate),
      ),
  ], label: 'Density');

  Widget _segmented(
    BuildContext context,
    List<(String, bool, VoidCallback)> options, {
    String? label,
  }) {
    var colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: FwSpacing.xs,
      children: [
        if (label != null) Text(label, style: context.type.micro),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(context.radii.radius),
            border: Border.all(color: colors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var (option, selected, onTap) in options)
                InkWell(
                  onTap: onTap,
                  child: Container(
                    color: selected ? colors.accentSoft : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: FwSpacing.md,
                      vertical: FwSpacing.xxs,
                    ),
                    child: Text(
                      option,
                      style: context.type.caption.copyWith(
                        color: selected ? colors.accent : colors.mut,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metadata(BuildContext context) {
    var relative = p.relative(file.path, from: asset.packageRoot);
    return ListView(
      padding: const EdgeInsets.all(FwSpacing.xl),
      children: [
        SelectableText(asset.key, style: context.type.heading),
        const Gap(FwSpacing.lg),
        FieldRow('Kind', assetKindOf(asset.key).label),
        if (dimensions case var size?)
          FieldRow(
            'Dimensions',
            '${size.width.toInt()} × ${size.height.toInt()}',
          ),
        FieldRow('Size', formatBytes(file.length)),
        if (asset.files.length > 1)
          FieldRow('Total, all densities', formatBytes(asset.totalBytes)),
        FieldRow(
          'Package',
          asset.package == null ? 'this package' : 'package:${asset.package}',
        ),
        const Gap(FwSpacing.xl),
        Text('Where it comes from', style: context.type.sectionLabel),
        const Gap(FwSpacing.md),
        // The declaration, not just the file: a directory declaration is the
        // only answer to "why is this in my bundle", and it is not derivable
        // from the path.
        FieldRow('Declared as', asset.declaration),
        FieldRow('File', relative),
        if (asset.files.length > 1) ...[
          const Gap(FwSpacing.xl),
          Text('Densities', style: context.type.sectionLabel),
          const Gap(FwSpacing.md),
          for (var variant in asset.files)
            FieldRow(
              variant.scale == null ? '1×' : '${_trim(variant.scale!)}×',
              '${p.relative(variant.path, from: asset.packageRoot)}'
              '   ${formatBytes(variant.length)}',
            ),
        ],
      ],
    );
  }
}

/// `2.0` reads as `2`, `1.5` stays `1.5`.
String _trim(double scale) =>
    scale == scale.roundToDouble() ? '${scale.toInt()}' : '$scale';

/// Shown when the panel has a package but no asset selected yet.
class AssetDetailEmpty extends StatelessWidget {
  const AssetDetailEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.image_outlined,
      title: 'Pick an asset',
      message:
          'Opening one shows where it came from, what densities it has, '
          'and the Dart that loads it.',
    );
  }
}
