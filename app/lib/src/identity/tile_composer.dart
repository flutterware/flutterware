import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'tile_slot.dart';

/// Draws the app's tile with a project's icon in the chip slot, and returns it
/// as PNG bytes for whatever wants to be that picture.
///
/// One image, not a set, and that is a measured constraint rather than a
/// simplification. `applicationIconImage` ignores per-size representations: an
/// `NSImage` carrying 16/32/128/512 art renders the *largest* downsampled in
/// both the Dock and the ⌘-Tab switcher, even though `bestRepresentation`
/// answers correctly in-process. So there is nothing to gain from composing a
/// ladder.
///
/// [size] is therefore chosen for the largest place it lands, not the smallest.
class TileComposer {
  static const _baseAsset = 'assets/fw_tile_base.png';

  /// Composites [icon] into the tile. Returns null only if the base asset
  /// cannot be decoded, which would mean a broken build rather than a project
  /// without an icon.
  static Future<Uint8List?> compose(Uint8List icon, {int size = 512}) async {
    var base = await _decode(await rootBundle.load(_baseAsset));
    if (base == null) return null;
    var chip = await _decode(ByteData.sublistView(icon));

    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    var scale = size / tileCanvas;
    canvas.scale(scale);

    var full = ui.Rect.fromLTWH(0, 0, tileCanvas, tileCanvas);
    canvas.drawImageRect(
      base,
      ui.Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble()),
      full,
      ui.Paint(),
    );

    if (chip != null) {
      var slot = ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(
          tileChipLeft,
          tileChipTop,
          tileChipSize,
          tileChipSize,
        ),
        const ui.Radius.circular(tileChipRadius),
      );
      canvas
        ..save()
        ..clipRRect(slot, doAntiAlias: true)
        // `slice`: a project's icon is square in practice, and cropping a
        // wrong-shaped one is better than letterboxing it into a square that
        // then reads as a mistake in *our* tile.
        ..drawImageRect(
          chip,
          _cover(chip),
          ui.Rect.fromLTWH(
            tileChipLeft,
            tileChipTop,
            tileChipSize,
            tileChipSize,
          ),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        )
        ..restore()
        // The hairline last, so it sits over the icon's own edge rather than
        // under it.
        ..drawRRect(
          slot,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = tileChipHairlineWidth
            ..color = const ui.Color(0xFFFFFFFF)
                .withValues(alpha: tileChipHairlineOpacity),
        );
    }

    var picture = recorder.endRecording();
    var composed = await picture.toImage(size, size);
    try {
      var png = await composed.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      picture.dispose();
      composed.dispose();
      base.dispose();
      chip?.dispose();
    }
  }

  /// The square of [image] a `cover` fit would show.
  static ui.Rect _cover(ui.Image image) {
    var side = image.width < image.height ? image.width : image.height;
    var dx = (image.width - side) / 2;
    var dy = (image.height - side) / 2;
    return ui.Rect.fromLTWH(dx, dy, side.toDouble(), side.toDouble());
  }

  static Future<ui.Image?> _decode(ByteData data) async {
    try {
      var codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      var frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } on Exception {
      // A project icon that will not decode is not worth failing a launch over.
      return null;
    }
  }
}
