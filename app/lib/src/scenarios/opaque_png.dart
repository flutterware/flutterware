/// Turning a capture into a PNG a store will take.
///
/// A scenario capture comes off `Image.toByteData(format: png)`, which is
/// always RGBA — 32-bit, with an alpha channel, whether or not a single pixel
/// in it is transparent. **Neither store takes it**: Play's asset rules ask for
/// "JPEG or 24-bit PNG (no alpha)", and Apple's screenshot specifications say
/// no alpha channels or transparencies in as many words. So the debugging
/// lane's own artifact is the one thing a store lane may not ship as it stands,
/// and there is no listing anywhere that would have accepted it.
///
/// The debugging lane is left alone: `scenarios run` keeps its alpha, because
/// its artifact is read by an inspector rather than uploaded. So does
/// `previews screenshot`, unless it is asked for `opaque` — which is how store
/// artwork drawn as a preview gets here.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// White, which is what an unpainted pixel reads as on both stores' listings.
///
/// A parameter rather than a constant because a frame declares its own ground,
/// and when one does, its colour is the honest thing to show through.
final defaultOpaqueGround = img.ColorRgb8(255, 255, 255);

/// [png] with no alpha channel, composited over [ground].
///
/// Returns the bytes unchanged when there is nothing to do — a PNG that is
/// already three-channel, or one this build cannot decode, which is not ours to
/// repair and not ours to corrupt either.
///
/// **Two paths, and the fast one is the one that always runs.** A capture is
/// RGBA because `Image.toByteData(format: png)` gives no other shape, not
/// because anything in it is transparent — an app paints its background. So the
/// common case is an opaque image that needs its fourth channel dropped, and
/// dropping it is a byte copy.
///
/// Measured on a 2048×2732 capture: blending it over a ground with
/// `compositeImage` costs **481ms**, and copying three bytes in four out of the
/// decoded buffer costs **16ms** — the blend spends all of it multiplying by an
/// alpha of 255. The detection rides along in the same pass, so nothing is paid
/// to find out which case this is, and a genuinely transparent pixel still
/// falls through to the blend rather than losing what is under it.
Uint8List flattenPng(Uint8List png, {img.Color? ground}) {
  var decoded = img.decodePng(png);
  if (decoded == null || decoded.numChannels == 3) return png;
  var rgba = decoded.getBytes(order: img.ChannelOrder.rgba);
  var rgb = Uint8List(rgba.length ~/ 4 * 3);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
    if (rgba[i + 3] != 255) return _composited(decoded, ground);
    rgb[o] = rgba[i];
    rgb[o + 1] = rgba[i + 1];
    rgb[o + 2] = rgba[i + 2];
  }
  return img.encodePng(
    img.Image.fromBytes(
      width: decoded.width,
      height: decoded.height,
      bytes: rgb.buffer,
      numChannels: 3,
    ),
  );
}

/// The slow path, for an image that really does have something see-through in
/// it — a screen the app had not finished painting.
///
/// Composited rather than merely stripped. Dropping the channel keeps whatever
/// RGB sat under a transparent pixel, which is usually black, so the hole would
/// ship as a black patch instead of the ground the viewer saw.
Uint8List _composited(img.Image decoded, img.Color? ground) {
  var flat = img.Image(
    width: decoded.width,
    height: decoded.height,
    numChannels: 3,
  );
  img.fill(flat, color: ground ?? defaultOpaqueGround);
  img.compositeImage(flat, decoded);
  return img.encodePng(flat);
}

/// [flattenPng] from `from` to `to`, **off this isolate**.
///
/// The synchronous version is 250ms of PNG codec per image on a store canvas,
/// and a listing is dozens of them. Called inline that is half a minute of a
/// frozen window: no frame paints, so a progress bar cannot move and the panel
/// cannot fill in the sets as they land — the export appears to hang and then
/// finish. Which is what it did, until this existed.
///
/// The file is read *and written* inside the isolate, so two paths cross the
/// boundary rather than two copies of a five-megabyte image.
Future<void> flattenPngFile(String from, String to) => Isolate.run(() {
  var flat = flattenPng(File(from).readAsBytesSync());
  File(to).writeAsBytesSync(flat);
});

/// [flattenPngFile] over many, a few at a time.
///
/// Bounded rather than unbounded: one isolate per image would be a hundred
/// live PNG decoders competing for the same cores and the same memory. Four is
/// enough to keep a laptop busy and small enough that the peak is four decoded
/// canvases, not a listing's worth.
Future<void> flattenPngFiles(Iterable<(String, String)> pairs) async {
  var pending = pairs.toList();
  for (var start = 0; start < pending.length; start += _flattenLanes) {
    var batch = pending.skip(start).take(_flattenLanes);
    await Future.wait([for (var (from, to) in batch) flattenPngFile(from, to)]);
  }
}

const _flattenLanes = 4;
