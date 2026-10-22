import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/render_contract.dart';
// ignore: implementation_imports
import 'package:flutterware/src/render/protocol.dart';

import 'host.dart';
import 'model.dart';
import 'render_capture.dart';

/// Runs the render guest: loads the bundle's fonts, runs [registrar], and
/// serves render requests over stdio until stdin closes.
///
/// The bundle's generated main is one line — `runRenderDriver(registerRenders)`
/// — and `RenderPool` is the other end of the wire. stdout is the protocol:
/// the app's own `print`s are redirected to stderr, and protocol lines carry
/// the marker so an unredirectable stray line cannot corrupt a reply.
Future<void> runRenderDriver(void Function(RenderHost host) registrar) async {
  WidgetsFlutterBinding.ensureInitialized();
  var bundleDir =
      Platform.environment['FW_RENDER_BUNDLE'] ?? Directory.current.path;
  var fonts = await _loadFonts(bundleDir);
  var bindings = RenderBindings();
  registrar(bindings);

  void reply(Map<String, Object?> message) {
    // The leading newline is insurance: app code that wrote to stdout
    // without a trailing newline would otherwise glue this reply onto its
    // line, and a marker that is not at line start is just a log to the
    // pool. The empty line it usually produces is dropped on the other end.
    stdout.write('\n$renderProtocolMarker${jsonEncode(message)}\n');
  }

  List<Map<String, Object?>> points() => [
    for (var bound in bindings.entries)
      RenderPointInfo(
        name: bound.point.name,
        kind: switch (bound) {
          BoundWidgetRender() => RenderPointKind.widget,
          BoundDocumentRender() => RenderPointKind.document,
        },
      ).toJson(),
  ];

  reply({
    'event': 'ready',
    'protocol': renderProtocolVersion,
    'points': points(),
  });

  await runZoned(
    () async {
      await for (var line
          in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
        Map<String, Object?> request;
        try {
          request = (jsonDecode(line) as Map).cast<String, Object?>();
        } catch (_) {
          continue;
        }
        var id = request['id'];
        switch (request['method']) {
          case 'exit':
            reply({'id': id, 'result': <String, Object?>{}});
            exit(0);
          case 'list':
            reply({
              'id': id,
              'result': {'points': points()},
            });
          case 'render':
            try {
              reply({
                'id': id,
                'result': await _render(bindings, fonts, request),
              });
            } catch (error, stack) {
              reply({
                'id': id,
                'error': {'message': '$error', 'stack': '$stack'},
              });
            }
          default:
            reply({
              'id': id,
              'error': {'message': 'unknown method "${request['method']}"'},
            });
        }
      }
      // stdin closed: the pool is gone.
      exit(0);
    },
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => stderr.writeln(line),
    ),
  );
}

Future<Map<String, Object?>> _render(
  RenderBindings bindings,
  List<RenderFont> fonts,
  Map<String, Object?> request,
) async {
  var pointName = request['point']! as String;
  var bound = bindings[pointName];
  if (bound == null) {
    throw StateError(
      'unknown render point "$pointName"; this bundle has: '
      '${bindings.entries.map((e) => e.point.name).join(', ')}',
    );
  }
  var format = request['as']! as String;
  var args = (request['args'] as Map? ?? const {}).cast<String, Object?>();
  var options = RenderOptions.fromJson(
    (request['options'] as Map? ?? const {}).cast<String, Object?>(),
  );
  var context = RenderContext(
    options: options.toCaptureOptions(),
    fonts: fonts,
  );

  List<Map<String, Object?>> warnings(List<RenderWarning> list) => [
    for (var warning in list) warning.toJson(),
  ];

  switch (bound) {
    case BoundWidgetRender():
      var sizeJson = request['size'];
      if (sizeJson == null) {
        throw StateError('a widget render needs a size');
      }
      var wireSize = RenderSize.fromJson(
        (sizeJson as Map).cast<String, Object?>(),
      );
      var size = Size(wireSize.width, wireSize.height);
      var widget = bound.buildFromJson(context, args);
      switch (format) {
        case 'svg':
          var result = await captureWidgetSvg(
            widget,
            size: size,
            fonts: fonts,
            options: context.options,
          );
          return {'svg': result.text, 'warnings': warnings(result.warnings)};
        case 'png':
          var result = await captureWidgetPng(
            widget,
            size: size,
            pixelRatio: (request['pixelRatio'] as num? ?? 3).toDouble(),
          );
          return {
            'bytes': base64Encode(result.bytes),
            'warnings': warnings(result.warnings),
          };
        case 'pdf':
          var result = await captureWidgetPdf(
            widget,
            size: size,
            fonts: fonts,
            options: context.options,
          );
          return {
            'bytes': base64Encode(result.bytes),
            'warnings': warnings(result.warnings),
          };
        default:
          throw StateError(
            'a widget render produces svg, png or pdf, '
            'not "$format"',
          );
      }
    case BoundDocumentRender():
      if (format != 'pdf') {
        throw StateError('a document render only produces pdf');
      }
      var document = await bound.buildFromJson(context, args);
      var bytes = await document.save();
      return {
        'bytes': base64Encode(bytes),
        'warnings': warnings(context.warnings),
      };
  }
}

Future<List<RenderFont>> _loadFonts(String bundleDir) async {
  var manifestFile = File('$bundleDir/manifest.json');
  if (!manifestFile.existsSync()) return const [];
  var manifest = RenderBundleManifest.fromJson(
    (jsonDecode(manifestFile.readAsStringSync()) as Map)
        .cast<String, Object?>(),
  );
  var fonts = <RenderFont>[];
  var loaders = <String, FontLoader>{};
  for (var font in manifest.fonts) {
    var bytes = File('$bundleDir/${font.path}').readAsBytesSync();
    fonts.add(
      RenderFont(
        family: font.family,
        bytes: bytes,
        bold: font.bold,
        italic: font.italic,
      ),
    );
    loaders
        .putIfAbsent(font.family, () => FontLoader(font.family))
        .addFont(Future.value(bytes.buffer.asByteData()));
  }
  await Future.wait([for (var loader in loaders.values) loader.load()]);
  return fonts;
}
