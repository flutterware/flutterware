import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;

import 'shell.dart';

/// A texture built on the GPU and drawn into the widget tree — the smallest
/// thing that only renders when Flutter GPU is actually on.
///
/// Deliberately uncaught. `gpu.gpuContext` throws unless the harness was given
/// **both** `--enable-impeller` and `--enable-flutter-gpu`, so an audit of this
/// catalog is what says whether the rasterizer this project renders on can
/// carry Flutter GPU at all — on every host CI runs. A caught exception would
/// turn that answer into a grey box nobody reads.
///
/// It needs no shader bundle, which is the reason it is a texture and not a
/// render pass: a bundle is produced by a build hook, and the previews asset
/// bundle does not run those yet.
@Preview(name: 'GPU smoke', wrapper: wrapInApp)
Widget gpuSmoke() => Scaffold(
  body: Center(
    child: SizedBox.square(
      dimension: 160,
      child: RawImage(
        image: _checkerboard(),
        // An 8×8 image asked to fill 160×160: without `fill` the default
        // scales *down* only and the texture arrives eight pixels wide, and
        // without `none` the upscale is smoothed into a gradient.
        fit: BoxFit.fill,
        filterQuality: FilterQuality.none,
      ),
    ),
  ),
);

/// An 8×8 checkerboard, uploaded to a GPU texture and handed back as an image.
ui.Image _checkerboard() {
  const size = 8;
  var texture = gpu.gpuContext.createTexture(
    gpu.StorageMode.hostVisible,
    size,
    size,
  );
  var pixels = ByteData(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var (r, g, b) = (x + y).isEven
          ? (0x6C, 0x4C, 0xFF) // violet
          : (0x1F, 0x29, 0x33); // slate
      var at = (y * size + x) * 4;
      pixels
        ..setUint8(at, r)
        ..setUint8(at + 1, g)
        ..setUint8(at + 2, b)
        ..setUint8(at + 3, 0xFF);
    }
  }
  // RGBA, whatever `gpuContext.defaultColorFormat` says. It reports
  // `b8g8r8a8UNormInt` here and the upload still wants red first — the format
  // names the texture's own layout, not the rows handed to `overwrite`.
  // Measured by writing 11 22 33 ff and reading it back as R=11 G=22 B=33.
  texture.overwrite(pixels);
  return texture.asImage();
}
