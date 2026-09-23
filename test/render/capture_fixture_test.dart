import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/render/pdf_writer.dart';
import 'package:flutterware/src/render/svg_writer.dart';

final _boundaryKey = GlobalKey();

void main() {
  testWidgets('render capture: one screen to SVG and PDF', (tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var robotoRegular = _fileBytes(
      'fixtures/probe_app/assets/fonts/Roboto-Regular.ttf',
    );
    var robotoBold = _fileBytes(
      'fixtures/probe_app/assets/fonts/Roboto-Bold.ttf',
    );
    var robotoItalic = _fileBytes(
      'app/lib/src/utils/fonts/Roboto/Roboto-Italic.ttf',
    );
    var materialIcons = _materialIconsBytes();

    ui.Image? photo;
    await tester.runAsync(() async {
      await (FontLoader('Roboto')
            ..addFont(_asByteData(robotoRegular))
            ..addFont(_asByteData(robotoBold))
            ..addFont(_asByteData(robotoItalic)))
          .load();
      if (materialIcons != null) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(_asByteData(materialIcons))).load();
      }
      photo = await _makePhoto();
    });

    await tester.pumpWidget(_Fixture(photo: photo!));

    var boundary =
        tester.renderObject(find.byKey(_boundaryKey)) as RenderRepaintBoundary;
    var recording = captureVector(boundary);

    var fonts = [
      RenderFont(family: 'Roboto', bytes: robotoRegular),
      RenderFont(family: 'Roboto', bytes: robotoBold, bold: true),
      RenderFont(family: 'Roboto', bytes: robotoItalic, italic: true),
      if (materialIcons != null)
        RenderFont(family: 'MaterialIcons', bytes: materialIcons),
    ];

    var outDir = Directory('build/render_capture')..createSync(recursive: true);
    await tester.runAsync(() async {
      await recording.rasterizeUnsupported();
      await recording.encodeImages();

      var size = boundary.size;
      var svg = writeSvg(recording, size, fonts);
      File('${outDir.path}/spike.svg').writeAsStringSync(svg);

      var outlineSvg = writeSvg(
        recording,
        size,
        fonts,
        options: CaptureOptions(text: (_) => TextPolicy.vectorize),
      );
      File('${outDir.path}/spike_outline.svg').writeAsStringSync(outlineSvg);

      // Per-run policy: icons stay vector, ordinary text trusts the viewer's
      // own fonts.
      var systemSvg = writeSvg(
        recording,
        size,
        fonts,
        options: CaptureOptions(
          text: (run) => run.fontFamily == 'MaterialIcons'
              ? TextPolicy.vectorize
              : TextPolicy.systemFont,
        ),
      );
      File('${outDir.path}/spike_system.svg').writeAsStringSync(systemSvg);
      print(
        'svg embedded fonts: ${svg.length ~/ 1024}KB, '
        'vectorized: ${outlineSvg.length ~/ 1024}KB, '
        'system fonts: ${systemSvg.length ~/ 1024}KB',
      );

      var pdfWarnings = <RenderWarning>[];
      var pdf = await writePdf(recording, size, fonts, warnings: pdfWarnings);
      File('${outDir.path}/spike.pdf').writeAsBytesSync(pdf);
      if (pdfWarnings.isNotEmpty) {
        print('pdf warnings: $pdfWarnings');
      }

      var truth = await boundary.toImage(pixelRatio: 2);
      var png = await truth.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/ground_truth.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    });

    var textOps = recording.ops.whereType<VgDrawText>().toList();
    var runCount = textOps.fold(0, (sum, op) => sum + op.runs.length);
    print(
      'captured ${recording.ops.length} ops, '
      '$runCount text runs in ${textOps.length} paragraphs',
    );
    print('unhandled canvas ops: ${recording.unhandled}');
    var unknown = recording.ops.whereType<VgDrawUnknownParagraph>().length;
    print('paragraphs with unrecoverable text: $unknown');

    expect(recording.ops, isNotEmpty);
    expect(runCount, greaterThan(5));
  });
}

Uint8List _fileBytes(String path) => File(path).readAsBytesSync();

Future<ByteData> _asByteData(Uint8List bytes) async =>
    bytes.buffer.asByteData();

Uint8List? _materialIconsBytes() {
  // flutter_tester lives at <sdk>/bin/cache/artifacts/engine/<platform>/;
  // the icon font ships two directories up.
  var engineDir = File(Platform.resolvedExecutable).parent;
  var file = File(
    '${engineDir.parent.parent.path}/material_fonts/MaterialIcons-Regular.otf',
  );
  return file.existsSync() ? file.readAsBytesSync() : null;
}

Future<ui.Image> _makePhoto() {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder);
  var colors = [Colors.orange, Colors.teal, Colors.indigo, Colors.pink];
  for (var i = 0; i < 4; i++) {
    canvas.drawRect(
      Rect.fromLTWH((i % 2) * 32, (i ~/ 2) * 32, 32, 32),
      Paint()..color = colors[i],
    );
  }
  canvas.drawCircle(const Offset(32, 32), 14, Paint()..color = Colors.white);
  return recorder.endRecording().toImage(64, 64);
}

class _Fixture extends StatelessWidget {
  const _Fixture({required this.photo});

  final ui.Image photo;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: RepaintBoundary(
          key: _boundaryKey,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 80,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3949AB), Color(0xFF00ACC1)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFF1A237E),
                      width: 2,
                    ),
                  ),
                  child: const Text(
                    'Vector Export',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF212121),
                      height: 1.4,
                    ),
                    children: [
                      const TextSpan(
                        text: 'Every paint call this screen makes is ',
                      ),
                      const TextSpan(
                        text: 'captured as a command',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const TextSpan(text: ' and replayed as '),
                      TextSpan(
                        text: 'real vector text',
                        style: TextStyle(color: Colors.deepOrange.shade700),
                      ),
                      const TextSpan(
                        text:
                            ', wrapping across lines exactly where the real '
                            'paragraph broke them.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.favorite, color: Colors.red, size: 28),
                    const SizedBox(width: 8),
                    const Icon(Icons.settings, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    Text(
                      'Icon glyphs are text runs too',
                      style: TextStyle(
                        fontSize: 15,
                        fontStyle: FontStyle.italic,
                        color: Colors.blueGrey.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CustomPaint(
                      size: const Size(110, 110),
                      painter: _ShapesPainter(),
                    ),
                    const SizedBox(width: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: RawImage(
                        image: photo,
                        width: 96,
                        height: 96,
                        fit: BoxFit.fill,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Transform.rotate(
                      angle: 0.35,
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          color: const Color(0xFF7CB342),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'tilt',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Opacity(
                  opacity: 0.45,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    color: const Color(0xFF1565C0),
                    child: const Text(
                      'half transparent group',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShapesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    var curve = Path()
      ..moveTo(5, size.height - 10)
      ..cubicTo(
        size.width * 0.3,
        -20,
        size.width * 0.7,
        size.height + 20,
        size.width - 5,
        10,
      );
    canvas.drawPath(
      curve,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF8E24AA),
    );
    var star = Path();
    const points = 5;
    var center = Offset(size.width / 2, size.height / 2);
    for (var i = 0; i < points * 2; i++) {
      var radius = i.isEven ? 34.0 : 14.0;
      var angle = i * 3.14159265 / points - 3.14159265 / 2;
      var p =
          center + Offset(radius * math.cos(angle), radius * math.sin(angle));
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    canvas.drawPath(star, Paint()..color = const Color(0xFFFFB300));
    canvas.drawCircle(center, 6, Paint()..color = const Color(0xFF6D4C41));

    // Two ops no vector writer can express: a shadow, and a shader the
    // capture cannot see through (sweep gradients only exist as opaque
    // ui.Shader objects). They exercise the unsupported-op policy.
    var badge = RRect.fromRectAndRadius(
      Rect.fromLTWH(4, size.height - 24, 84, 20),
      const Radius.circular(6),
    );
    canvas.drawShadow(
      Path()..addRRect(badge),
      const Color(0xFF000000),
      3,
      false,
    );
    canvas.drawRRect(
      badge,
      Paint()
        ..shader = ui.Gradient.sweep(
          badge.center,
          const [Color(0xFFE91E63), Color(0xFF2196F3), Color(0xFFE91E63)],
          const [0, 0.5, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
