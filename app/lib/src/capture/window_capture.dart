import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
// ignore: implementation_imports
import 'package:flutterware/src/offscreen_raster.dart';
import 'package:image/image.dart' as img;

import '../embedder/embedded_engine.dart';

/// A picture of the window, guests included.
///
/// Two captures composited, because the guest is not in the host's layer
/// tree. A catalog panel shows its guest through `Texture(textureId:)`, an
/// external texture the platform compositor resolves at raster time;
/// `RenderRepaintBoundary.toImage` rasterizes a layer tree offscreen. Measured
/// on macOS: the texture's rect comes back fully transparent, every sample,
/// zero alpha. So the host raster has a hole in it, and the guest's own frame
/// goes into that hole.
///
/// The hole is now dug on purpose. On Linux the same raster does not return an
/// empty rectangle but takes the process down, so [OffscreenRaster] lifts every
/// guest texture out of the tree for the frame this photographs — which leaves
/// exactly the hole macOS was leaving anyway, on every host.
///
/// The OS-level alternative, macOS `ScreenCaptureKit`, would need a Screen
/// Recording permission and a visible, unoccluded window; the composite needs
/// neither.
abstract final class WindowCapture {
  /// Rasterizes [boundary] at [pixelRatio] and composites every live guest
  /// under it into the hole it left.
  ///
  /// **Under, and it has to be literal.** A guest pasted *over* the host looks
  /// identical wherever the host is transparent, which is most of the hole and
  /// is why this read as correct for a long time. It differs exactly where the
  /// host draws something above the texture — and a device frame does: the
  /// screen is a rounded rect inside an opaque bezel, with a notch over it. The
  /// texture's rect is the full screen rectangle, so pasting it over the raster
  /// squared off the frame's corners, painted across the bezel and erased the
  /// notch. Every previews screenshot on a phone had it.
  ///
  /// So the guests go onto an empty canvas first and the host raster goes over
  /// them. The host's own alpha is then what decides where a guest shows, which
  /// is the same rule the compositor would have applied had the texture been in
  /// the layer tree at all. `package:image` has no `dstOver`, hence the canvas
  /// rather than a blend mode.
  static Future<img.Image> capture(
    RenderRepaintBoundary boundary, {
    required double pixelRatio,
  }) async {
    // **Read before the raster, not after.** [OffscreenRaster] takes every
    // guest out of the layer tree for the frame the raster photographs, and
    // reading here rather than around the loop is what keeps this independent
    // of *how*: `GuestTexture` withholds a paint today and leaves the
    // `TextureBox` in place, but a version that withheld the widget would take
    // the box with it, and this would then be filling holes it could no longer
    // find. Where each guest painted is the one thing that has to be known
    // first anyway.
    //
    // A texture nobody claims is left as the hole it is. It is not this
    // function's business to decide that is wrong — a host with a texture from
    // somewhere else is a legitimate thing to photograph.
    var guests = [
      for (var texture in _texturesUnder(boundary))
        if (EmbeddedEngine.withTexture(texture.textureId) case var engine?)
          (engine, _rectOf(texture, boundary, pixelRatio)),
    ];
    var host = await OffscreenRaster.around(
      () => _raster(boundary, pixelRatio),
    );
    if (guests.isEmpty) return host;

    var scene = img.Image(
      width: host.width,
      height: host.height,
      numChannels: 4,
    );
    for (var (engine, rect) in guests) {
      await _compositeGuest(scene, engine, rect);
    }
    img.compositeImage(scene, host);
    return scene;
  }

  static Future<img.Image> _raster(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) async {
    var image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: data!.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    } finally {
      image.dispose();
    }
  }

  static Future<void> _compositeGuest(
    img.Image scene,
    EmbeddedEngine engine,
    Rect rect,
  ) async {
    if (rect.isEmpty) return;
    var guest = await engine.captureImage();
    // **Resampled here rather than by the paste**, when the guest renders at
    // a size the panel does not. A device frame is exactly this: the guest's
    // window *is* the phone screen, at the phone's pixel ratio, and the panel
    // scales the result down. `compositeImage`'s own scaling is a nearest
    // sample, which turns 3x device pixels into aliased text.
    var width = rect.width.round();
    var height = rect.height.round();
    if (guest.width != width || guest.height != height) {
      guest = img.copyResize(
        guest,
        width: width,
        height: height,
        interpolation: img.Interpolation.average,
      );
    }
    img.compositeImage(
      scene,
      guest,
      dstX: rect.left.round(),
      dstY: rect.top.round(),
    );
  }

  /// Every external texture painted under [boundary].
  ///
  /// Found by walking the render tree rather than by panels registering their
  /// widgets, so a guest is composited wherever it ended up and at whatever
  /// size it was painted — including scaled inside a device frame, which a
  /// registry keyed on the panel would have had to be told about.
  static Iterable<TextureBox> _texturesUnder(RenderObject root) sync* {
    var found = <TextureBox>[];
    void walk(RenderObject node) {
      if (node is TextureBox) found.add(node);
      node.visitChildren(walk);
    }

    walk(root);
    yield* found;
  }

  /// Where [texture] painted, in the pixel coordinates `toImage` produced.
  static Rect _rectOf(
    TextureBox texture,
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) {
    var transform = texture.getTransformTo(boundary);
    var local = MatrixUtils.transformRect(
      transform,
      Offset.zero & texture.size,
    );
    return Rect.fromLTRB(
      local.left * pixelRatio,
      local.top * pixelRatio,
      local.right * pixelRatio,
      local.bottom * pixelRatio,
    );
  }
}
