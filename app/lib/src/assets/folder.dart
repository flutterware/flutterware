import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../ui/design/design.dart';
import '../ui/tappable.dart';
import '../ui/theme.dart';
import 'font_face.dart';
import 'kind_icon.dart';
import 'model/asset_catalog.dart';
import 'model/asset_scan.dart';
import 'model/asset_tree.dart';

/// A directory, as pictures.
///
/// **The tree picks what this shows.** They are not two views of the same
/// list: one is the selector, the other is what was selected. That is the
/// catalog's arrangement and the reason for it holds here too — a folder is a
/// place, so it has to be somewhere you can *be*, not just a fold in a rail.
///
/// What this answers that a tree row cannot: what is actually in the folder. A
/// row can say `images · 1.0 MB · 6`, and six numbers do not tell you that two
/// of the six are the same logo at different crops. A bundle is the one kind
/// of directory where a contact sheet is the whole point, because every file
/// in it was put there to be looked at.
class AssetFolderView extends StatelessWidget {
  const AssetFolderView({
    super.key,
    required this.node,
    required this.path,
    required this.onSelect,
    this.bytesFor,
  });

  /// The directory, with its rollups already counted.
  final AssetNode node;

  /// What the address names — shown as the heading, since [AssetNode.name] is
  /// only the segments this row added.
  final String path;

  /// Opening a tile, by the same path grammar the list uses: an asset key for a
  /// tile, a directory path for a folder.
  final ValueChanged<String> onSelect;

  /// Bytes for an asset, for a demo with no filesystem under it. Null — the
  /// app — lets each tile read its own file, which is what keeps a folder of
  /// two hundred rasters from being two hundred `Uint8List`s held at once.
  final Uint8List? Function(ResolvedAsset asset)? bytesFor;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var sections = assetSheetSections(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          padding: const EdgeInsets.all(FwSpacing.md),
          child: Row(
            spacing: FwSpacing.md,
            children: [
              Icon(
                Icons.folder_outlined,
                size: FwIconSize.md,
                color: colors.mut,
              ),
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.body,
                ),
              ),
              Text(
                '${node.totalCount} ${node.totalCount == 1 ? 'asset' : 'assets'}'
                ' · ${formatBytes(node.totalBytes)}',
                style: context.type.micro,
              ),
            ],
          ),
        ),
        Expanded(
          child: sections.isEmpty
              ? Center(
                  child: Text(
                    'This folder holds no assets.',
                    style: context.type.bodyMuted,
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    for (var section in sections)
                      SliverMainAxisGroup(
                        slivers: [
                          if (section.label.isNotEmpty)
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: _Heading(
                                label: section.label,
                                colors: colors,
                                style: context.type.sectionLabel,
                                onTap: () => onSelect(section.path),
                              ),
                            ),
                          SliverPadding(
                            padding: const EdgeInsets.all(FwSpacing.md),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    // By extent rather than a column count:
                                    // this pane is resized by a splitter, and a
                                    // count that suited one width would be four
                                    // enormous tiles or twelve unreadable ones
                                    // at another.
                                    maxCrossAxisExtent: 150,
                                    childAspectRatio: 0.8,
                                    mainAxisSpacing: FwSpacing.md,
                                    crossAxisSpacing: FwSpacing.md,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                at,
                              ) {
                                var asset = section.assets[at];
                                return _AssetTile(
                                  asset: asset,
                                  bytes: bytesFor?.call(asset),
                                  onTap: () => onSelect(asset.key),
                                );
                              }, childCount: section.assets.length),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A section's heading, pinned so the folder a tile belongs to is on screen
/// however far down its own grid you have read.
///
/// Tappable, unlike the catalog's, and for a reason the catalog does not have:
/// an asset folder *is* an address. A heading that names a place you can go to
/// and does not take you there is a dead affordance.
class _Heading extends SliverPersistentHeaderDelegate {
  _Heading({
    required this.label,
    required this.colors,
    required this.style,
    required this.onTap,
  });

  final String label;
  final FwPalette colors;
  final TextStyle style;
  final VoidCallback onTap;

  /// Fixed, because a pinned header has to declare its extent before anything
  /// is laid out.
  static const _height = 28.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      Tappable(
        onTap: onTap,
        child: Container(
          color: colors.panel2,
          padding: const EdgeInsets.symmetric(horizontal: FwSpacing.md),
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      );

  @override
  bool shouldRebuild(_Heading old) =>
      old.label != label || old.colors != colors;
}

/// One asset, at thumbnail size.
///
/// Deliberately not [AssetPreview]. That widget is the *detail* view — exact
/// pixels, a zoom, a chosen backdrop — and it takes the whole file as bytes to
/// do it. A contact sheet wants the opposite of all three: many of them, small,
/// and cheap. So a raster goes through [ResizeImage], which decodes to roughly
/// the size it will be drawn at and lets Flutter's own image cache hold it,
/// and everything that is not a picture stays an icon.
class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.bytes,
    required this.onTap,
  });

  final ResolvedAsset asset;

  /// Supplied by a demo; null in the app, where the file is read from disk.
  final Uint8List? bytes;

  final VoidCallback onTap;

  /// Roughly the drawn size at 2×, which is as much resolution as a 150px tile
  /// can show and a great deal less than a print-size export carries.
  static const _decodeTo = 300;

  @override
  Widget build(BuildContext context) {
    return _Tile(
      onTap: onTap,
      label: p.basename(asset.key),
      detail: formatBytes(asset.totalBytes),
      child: _picture(context),
    );
  }

  Widget _picture(BuildContext context) {
    var colors = context.colors;
    var supplied = bytes;
    var glyph = Icon(
      assetKindIcon(assetKindOf(asset.key)),
      size: FwIconSize.xl,
      color: colors.mut,
    );
    switch (assetKindOf(asset.key)) {
      case AssetKind.image:
        return Image(
          image: ResizeImage(
            supplied == null
                ? FileImage(File(asset.main.path))
                : MemoryImage(supplied),
            width: _decodeTo,
            allowUpscaling: false,
          ),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) =>
              Icon(Icons.broken_image_outlined, color: colors.red),
        );
      case AssetKind.vector:
        return SvgPicture(
          supplied == null
              ? SvgFileLoader(File(asset.main.path))
              : SvgBytesLoader(supplied),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) =>
              Icon(Icons.broken_image_outlined, color: colors.red),
        );
      case AssetKind.font:
        // Two letters in the face itself. A sheet of fonts that all draw the
        // same `Tt` glyph is a sheet that cannot be used for the one thing a
        // sheet of fonts is for.
        return AssetFontFace(
          asset: asset,
          bytes: supplied,
          fallback: glyph,
          builder: (context, family) => FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Ag',
              style: TextStyle(
                fontFamily: family,
                fontSize: 44,
                color: colors.ink,
              ),
            ),
          ),
        );
      case AssetKind.media:
      case AssetKind.data:
      case AssetKind.other:
        return glyph;
    }
  }
}

/// The frame every tile shares: a picture over two lines that never wrap.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.onTap,
    required this.label,
    required this.detail,
    required this.child,
  });

  final VoidCallback onTap;
  final String label;
  final String detail;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return Tappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.radiusSmall),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        ),
        padding: const EdgeInsets.all(FwSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: Center(child: child)),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.type.caption,
            ),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.type.micro,
            ),
          ],
        ),
      ),
    );
  }
}
