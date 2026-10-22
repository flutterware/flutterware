import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
// ignore: implementation_imports
import 'package:flutterware/src/render/offscreen.dart';

import 'capture.dart';
import 'model.dart';
import 'pdf_writer.dart';
import 'svg_writer.dart';

/// Captures [render]'s painted content as a self-contained SVG.
///
/// [render] must be laid out — typically a [RenderRepaintBoundary] found
/// through a [GlobalKey], in a test or a running app. [size] defaults to the
/// box's own size. The result's warnings say what the vector output does not
/// carry exactly (raster patches, dropped effects, unrecovered text).
Future<SvgResult> captureSvg(
  RenderObject render, {
  Size? size,
  List<RenderFont> fonts = const [],
  CaptureOptions? options,
}) async {
  var opts = options ?? CaptureOptions();
  var recording = await _capture(render, opts);
  var svg = writeSvg(recording, size ?? _sizeOf(render), fonts, options: opts);
  return SvgResult(svg, recording.collectWarnings(opts));
}

/// Captures [render]'s painted content as a single-page PDF.
Future<PdfResult> capturePdf(
  RenderObject render, {
  Size? size,
  List<RenderFont> fonts = const [],
  CaptureOptions? options,
}) async {
  var opts = options ?? CaptureOptions();
  var recording = await _capture(render, opts);
  var warnings = recording.collectWarnings(opts);
  var bytes = await writePdf(
    recording,
    size ?? _sizeOf(render),
    fonts,
    options: opts,
    warnings: warnings,
  );
  return PdfResult(bytes, warnings);
}

Future<VgRecording> _capture(RenderObject render, CaptureOptions opts) async {
  var recording = captureVector(render);
  if (opts.unsupported == UnsupportedPolicy.rasterize) {
    await recording.rasterizeUnsupported(pixelRatio: opts.rasterScale);
  }
  await recording.encodeImages();
  return recording;
}

Size _sizeOf(RenderObject render) {
  if (render is RenderBox && render.hasSize) return render.size;
  throw ArgumentError(
    'size is required when the render object is not a laid-out RenderBox',
  );
}

/// Renders [widget] offscreen at [size] and captures it as SVG — the
/// widget-first door for widgets that are not part of any running tree.
Future<SvgResult> captureWidgetSvg(
  Widget widget, {
  required Size size,
  List<RenderFont> fonts = const [],
  CaptureOptions? options,
}) async {
  var mounted = OffscreenWidget.mount(widget, size: size);
  try {
    var result = await captureSvg(
      mounted.boundary,
      size: size,
      fonts: fonts,
      options: options,
    );
    return SvgResult(result.text, [
      ..._buildWarnings(mounted),
      ...result.warnings,
    ]);
  } finally {
    mounted.dispose();
  }
}

/// Renders [widget] offscreen at [size] and captures it as a single-page
/// PDF.
Future<PdfResult> captureWidgetPdf(
  Widget widget, {
  required Size size,
  List<RenderFont> fonts = const [],
  CaptureOptions? options,
}) async {
  var mounted = OffscreenWidget.mount(widget, size: size);
  try {
    var result = await capturePdf(
      mounted.boundary,
      size: size,
      fonts: fonts,
      options: options,
    );
    return PdfResult(result.bytes, [
      ..._buildWarnings(mounted),
      ...result.warnings,
    ]);
  } finally {
    mounted.dispose();
  }
}

/// Renders [widget] offscreen at [size] and rasterizes it — the camera
/// lane, so its only possible warning is the widget throwing on the way to
/// the picture.
Future<PngResult> captureWidgetPng(
  Widget widget, {
  required Size size,
  double pixelRatio = 3,
}) async {
  var mounted = OffscreenWidget.mount(widget, size: size);
  try {
    var image = await mounted.boundary.toImage(pixelRatio: pixelRatio);
    var png = await image.toByteData(format: ui.ImageByteFormat.png);
    return PngResult(png!.buffer.asUint8List(), _buildWarnings(mounted));
  } finally {
    mounted.dispose();
  }
}

/// The framework caught an exception during the offscreen pass: the output
/// carries an error box where the widget should be, and pretending
/// otherwise would be the one lie this pipeline promised not to tell.
List<RenderWarning> _buildWarnings(OffscreenWidget mounted) => [
  for (var details in mounted.flutterErrors)
    RenderWarning(
      RenderWarningKind.buildError,
      'the widget threw while rendering: ${details.exception}',
    ),
];
