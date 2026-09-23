import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../ui/anchored_card.dart';
import '../ui/design/design.dart';
import '../ui/theme.dart';
import 'font_face.dart';
import 'kind_icon.dart';
import 'model/asset_catalog.dart';
import 'model/asset_scan.dart';
import 'text_head.dart';

/// One asset, beside the row the pointer is on.
///
/// The catalog needed a whole thumbnail store to do this — one embedded guest,
/// one texture, so a picture of an entry that is not on the canvas has to be a
/// photograph taken earlier. An asset has no such problem: the file *is* the
/// picture, and Flutter's own image cache is the store. Which is why this is a
/// stateless widget and that one is 792 lines.
///
/// Deliberately answers less than the detail pane. No zoom, no backdrop
/// switch, no density picker — those are choices, and a card that appeared
/// under the pointer is no place to make one. What it is for is the question
/// you ask while skimming a list: *which* logo is that.
class AssetPopover extends StatelessWidget {
  const AssetPopover({
    super.key,
    required this.asset,
    required this.anchor,
    this.bytes,
  });

  final ResolvedAsset asset;

  /// The row, in global coordinates.
  final Rect anchor;

  /// Supplied by a demo; null in the app, where the file is read from disk.
  final Uint8List? bytes;

  /// Wide enough to tell two crops of the same logo apart, narrow enough to
  /// leave the list it came from readable.
  static const width = 260.0;

  /// The picture is at most this tall — a print-size export is not going to be
  /// judged in a hover card, and a card taller than the window cannot point at
  /// its own row.
  static const _maxPicture = 240.0;

  /// And at least this tall, so a 24px icon gets a card rather than a strip.
  /// The floor is the reason the box is not simply the picture's own size: a
  /// bundle's two most common assets are a wordmark and a 24px glyph, and one
  /// card shape has to hold both without either looking like a mistake.
  static const _minPicture = 120.0;

  /// Roughly the drawn size at 2×, so a 4096px raster is not decoded whole to
  /// fill 260 logical pixels.
  static const _decodeTo = 520;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var variants = asset.variants.length;
    return FwAnchoredCard(
      anchor: anchor,
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: colors.bg,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: _minPicture,
                maxHeight: _maxPicture,
              ),
              child: Padding(
                padding: const EdgeInsets.all(FwSpacing.md),
                child: Center(child: _picture(context)),
              ),
            ),
          ),
          Divider(height: 1, color: colors.line),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FwSpacing.md,
              vertical: FwSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.key,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.micro,
                ),
                Text(
                  [
                    formatBytes(asset.totalBytes),
                    if (variants > 0)
                      '$variants variant${variants == 1 ? '' : 's'}',
                  ].join(' · '),
                  style: context.type.micro.copyWith(color: colors.mut),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// What the asset actually is: the picture for the kinds that have one, the
  /// glyphs for a font, the document for anything textual.
  ///
  /// The glyph of a *kind* is the last resort and not a preview of anything —
  /// a card that answers "this is a font" has told you what the extension
  /// already did. A font is drawn in its own face and a config in its own
  /// words, which is the only version of this card worth summoning.
  ///
  /// The font is safe to draw here because [AssetFontCache] loads each file
  /// once: `FontLoader` publishes process-wide and never unregisters, so the
  /// ceiling is the project's font count rather than the hover count.
  Widget _picture(BuildContext context) {
    var colors = context.colors;
    var supplied = bytes;
    var broken = Icon(Icons.broken_image_outlined, color: colors.red);
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
          // At 1× the pixels on screen are the pixels in the file. A 16px icon
          // blown up to fill the card would be the card inventing resolution.
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stack) => broken,
        );
      case AssetKind.vector:
        return SvgPicture(
          supplied == null
              ? SvgFileLoader(File(asset.main.path))
              : SvgBytesLoader(supplied),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => broken,
        );
      case AssetKind.font:
        return AssetFontFace(
          asset: asset,
          bytes: supplied,
          fallback: _kindGlyph(colors),
          builder: (context, family) => FittedBox(
            fit: BoxFit.scaleDown,
            child: DefaultTextStyle(
              style: TextStyle(fontFamily: family, color: colors.ink),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Ag', style: TextStyle(fontSize: 56)),
                  Text('Handgloves', style: TextStyle(fontSize: 20)),
                  Text('0123456789', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
        );
      case AssetKind.data:
        return Align(
          alignment: Alignment.topLeft,
          child: AssetTextHead(asset: asset, bytes: supplied, lines: 10),
        );
      case AssetKind.media:
      case AssetKind.other:
        return _kindGlyph(colors);
    }
  }

  Widget _kindGlyph(FwPalette colors) => Icon(
    assetKindIcon(assetKindOf(asset.key)),
    size: FwIconSize.xl,
    color: colors.mut,
  );
}
