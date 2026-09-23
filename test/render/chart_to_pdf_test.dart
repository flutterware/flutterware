import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/render/svg_writer.dart';

/// The consumer story this proves: a report generated with package:pdf's
/// widget library wants a chart that is the app's own Flutter widget, not a
/// re-implementation in PDF primitives. The chart renders once in Flutter,
/// the capture turns its paint pass into a self-contained SVG (glyphs as
/// paths, painter-drawn labels as raster patches), and pw.SvgImage drops it
/// into the pw layout like any other block.
final _chartKey = GlobalKey();

void main() {
  testWidgets('a Flutter chart widget lands in a pw.Document page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(460, 340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var roboto = File('fixtures/probe_app/assets/fonts/Roboto-Regular.ttf')
        .readAsBytesSync();
    var robotoBold = File('fixtures/probe_app/assets/fonts/Roboto-Bold.ttf')
        .readAsBytesSync();
    await tester.runAsync(
      () =>
          (FontLoader('Roboto')
                ..addFont(Future.value(roboto.buffer.asByteData()))
                ..addFont(Future.value(robotoBold.buffer.asByteData())))
              .load(),
    );

    await tester.pumpWidget(const _ChartCard());

    var boundary =
        tester.renderObject(find.byKey(_chartKey)) as RenderRepaintBoundary;
    var recording = captureVector(boundary);
    var fonts = [
      RenderFont(family: 'Roboto', bytes: roboto),
      RenderFont(family: 'Roboto', bytes: robotoBold, bold: true),
    ];

    var outDir = Directory('build/render_capture')..createSync(recursive: true);
    await tester.runAsync(() async {
      await recording.rasterizeUnsupported();
      await recording.encodeImages();

      var size = boundary.size;
      var svg = writeSvg(
        recording,
        size,
        fonts,
        options: CaptureOptions(text: (_) => TextPolicy.vectorize),
      );
      File('${outDir.path}/chart.svg').writeAsStringSync(svg);

      var truth = await boundary.toImage(pixelRatio: 2);
      var png = await truth.toByteData(format: ui.ImageByteFormat.png);
      File('${outDir.path}/chart_truth.png')
          .writeAsBytesSync(png!.buffer.asUint8List());

      // The consumer side: an ordinary pw.Document, the chart dropped in as
      // one more block of the layout.
      var doc = pw.Document();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Quarterly report',
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                "The chart below is the app's own Flutter widget: rendered "
                'once, captured as vector commands, and placed here as SVG.',
                style: const pw.TextStyle(fontSize: 11),
              ),
              pw.SizedBox(height: 16),
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                padding: const pw.EdgeInsets.all(8),
                child: pw.SvgImage(
                  svg: svg,
                  width: size.width,
                  height: size.height,
                ),
              ),
              pw.SizedBox(height: 16),
              pw.Text(
                'Body text keeps flowing after the chart, laid out by the '
                'pdf widget library as usual.',
                style: const pw.TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      );
      File('${outDir.path}/chart_report.pdf')
          .writeAsBytesSync(await doc.save());
    });

    var unknown = recording.ops.whereType<VgDrawUnknownParagraph>().length;
    var texts = recording.ops.whereType<VgDrawText>().length;
    print(
      'chart capture: ${recording.ops.length} ops, $texts widget paragraphs, '
      '$unknown painter-drawn labels (rasterized)',
    );
    expect(unknown, greaterThan(0));
    expect(texts, greaterThan(0));
  });
}

class _ChartCard extends StatelessWidget {
  const _ChartCard();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: RepaintBoundary(
          key: _chartKey,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Monthly active devices',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _legendDot(const Color(0xFF1E88E5), 'phones'),
                    const SizedBox(width: 14),
                    _legendDot(const Color(0xFFFB8C00), 'tablets'),
                  ],
                ),
                const SizedBox(height: 8),
                const CustomPaint(
                  size: Size(412, 230),
                  painter: _LineChartPainter(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF546E7A)),
        ),
      ],
    );
  }
}

/// Painted the way chart libraries paint: geometry through the canvas, axis
/// labels through TextPainter — so the labels arrive as paragraphs no
/// render-tree join can read, exercising the rasterized-label road.
class _LineChartPainter extends CustomPainter {
  const _LineChartPainter();

  static const phones = <double>[42, 55, 48, 70, 66, 88];
  static const tablets = <double>[20, 24, 31, 28, 39, 35];
  static const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, right = 6.0, top = 8.0, bottom = 22.0;
    var plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );

    var grid = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = 1;
    var labelStyle = const TextStyle(
      fontSize: 10,
      color: Color(0xFF90A4AE),
      fontFamily: 'Roboto',
    );
    for (var i = 0; i <= 4; i++) {
      var y = plot.bottom - plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      var painter = TextPainter(
        text: TextSpan(text: '${i * 25}', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(plot.left - painter.width - 6, y - painter.height / 2),
      );
    }
    for (var i = 0; i < months.length; i++) {
      var x = plot.left + plot.width * i / (months.length - 1);
      var painter = TextPainter(
        text: TextSpan(text: months[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(x - painter.width / 2, plot.bottom + 6));
    }

    Offset at(int i, double value) => Offset(
      plot.left + plot.width * i / (phones.length - 1),
      plot.bottom - plot.height * value / 100,
    );

    var area = Path()..moveTo(at(0, phones[0]).dx, plot.bottom);
    for (var i = 0; i < phones.length; i++) {
      area.lineTo(at(i, phones[i]).dx, at(i, phones[i]).dy);
    }
    area.lineTo(at(phones.length - 1, 0).dx, plot.bottom);
    area.close();
    canvas.drawPath(area, Paint()..color = const Color(0x261E88E5));

    for (var (values, color) in [
      (phones, const Color(0xFF1E88E5)),
      (tablets, const Color(0xFFFB8C00)),
    ]) {
      var line = Path()..moveTo(at(0, values[0]).dx, at(0, values[0]).dy);
      for (var i = 1; i < values.length; i++) {
        line.lineTo(at(i, values[i]).dx, at(i, values[i]).dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
      for (var i = 0; i < values.length; i++) {
        canvas.drawCircle(at(i, values[i]), 3, Paint()..color = color);
        canvas.drawCircle(at(i, values[i]), 1.5, Paint()..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
