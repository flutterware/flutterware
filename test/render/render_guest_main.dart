// The guest half of the server-side experiments: a plain runApp program for
// flutter_tester — no flutter_test, no widget tester. EXPORT_MODE=once
// renders one chart to SVG + PNG and exits (the container proof);
// EXPORT_MODE=loop renders EXPORT_ITER times and reports latency and RSS
// (the warm-pool proof).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutterware/src/render/capture.dart';
import 'package:flutterware/src/render/model.dart';
import 'package:flutterware/src/render/svg_writer.dart';

final _boundaryKey = GlobalKey();
final _data = ValueNotifier<List<double>>([42, 55, 48, 70, 66, 88]);

Future<void> main() async {
  var binding = WidgetsFlutterBinding.ensureInitialized();
  var env = Platform.environment;
  var mode = env['EXPORT_MODE'] ?? 'once';
  var outDir = Directory(env['EXPORT_OUT'] ?? 'out')
    ..createSync(recursive: true);
  var fontDir = env['EXPORT_FONTS'] ?? 'fonts';

  var roboto = File('$fontDir/Roboto-Regular.ttf').readAsBytesSync();
  var robotoBold = File('$fontDir/Roboto-Bold.ttf').readAsBytesSync();
  await (FontLoader('Roboto')
        ..addFont(Future.value(roboto.buffer.asByteData()))
        ..addFont(Future.value(robotoBold.buffer.asByteData())))
      .load();
  var fonts = [
    RenderFont(family: 'Roboto', bytes: roboto),
    RenderFont(family: 'Roboto', bytes: robotoBold, bold: true),
  ];

  runApp(const _App());
  await binding.endOfFrame;

  Future<VgRecording> capture() async {
    var boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    var recording = captureVector(boundary);
    await recording.rasterizeUnsupported();
    await recording.encodeImages();
    return recording;
  }

  const size = Size(436, 300);
  var options = CaptureOptions(text: (_) => TextPolicy.vectorize);

  if (mode == 'once') {
    var watch = Stopwatch()..start();
    var recording = await capture();
    var svg = writeSvg(recording, size, fonts, options: options);
    File('${outDir.path}/out.svg').writeAsStringSync(svg);
    var boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    var image = await boundary.toImage(pixelRatio: 2.0);
    var png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir.path}/out.png').writeAsBytesSync(png!.buffer.asUint8List());
    print(
      'once: ${recording.ops.length} ops, svg ${svg.length ~/ 1024}KB, '
      'png ${png.lengthInBytes ~/ 1024}KB, ${watch.elapsedMilliseconds}ms, '
      'os ${Platform.operatingSystem} '
      '(${File('/etc/os-release').existsSync() ? File('/etc/os-release').readAsLinesSync().first : 'not linux'})',
    );
  } else {
    var iterations = int.parse(env['EXPORT_ITER'] ?? '1000');
    var watch = Stopwatch()..start();
    var window = Stopwatch()..start();
    var lastSvgLength = 0;
    for (var i = 0; i < iterations; i++) {
      // New data every render: the frame is real, not a cached picture.
      _data.value = [
        for (var j = 0; j < 6; j++) 20 + ((i * 13 + j * 29) % 76).toDouble(),
      ];
      await binding.endOfFrame;
      var recording = await capture();
      var svg = writeSvg(recording, size, fonts, options: options);
      lastSvgLength = svg.length;
      if ((i + 1) % 100 == 0) {
        print(
          'iter ${i + 1}: ${window.elapsedMilliseconds / 100}ms/render, '
          'rss ${ProcessInfo.currentRss ~/ (1024 * 1024)}MB',
        );
        window.reset();
      }
    }
    print(
      'loop: $iterations renders in ${watch.elapsedMilliseconds}ms '
      '(${watch.elapsedMilliseconds / iterations}ms avg), '
      'last svg ${lastSvgLength ~/ 1024}KB, '
      'final rss ${ProcessInfo.currentRss ~/ (1024 * 1024)}MB',
    );
  }
  exit(0);
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Roboto', useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF37474F),
        body: Center(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: Container(
              width: 436,
              height: 300,
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Monthly active devices',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'rendered headless by flutter_tester',
                    style: TextStyle(fontSize: 11, color: Color(0xFF78909C)),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: _data,
                      builder: (context, values, _) => CustomPaint(
                        size: Size.infinite,
                        painter: _ChartPainter(values),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.values);

  final List<double> values;
  static const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'];

  @override
  void paint(Canvas canvas, Size size) {
    const left = 30.0, bottom = 18.0;
    var plot = Rect.fromLTRB(left, 4, size.width - 4, size.height - bottom);
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
        Offset(plot.left - painter.width - 5, y - painter.height / 2),
      );
    }
    Offset at(int i, double value) => Offset(
      plot.left + plot.width * i / (values.length - 1),
      plot.bottom - plot.height * value / 100,
    );
    for (var i = 0; i < months.length; i++) {
      var painter = TextPainter(
        text: TextSpan(text: months[i], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(at(i, 0).dx - painter.width / 2, plot.bottom + 4),
      );
    }
    var area = Path()..moveTo(at(0, values[0]).dx, plot.bottom);
    for (var i = 0; i < values.length; i++) {
      area.lineTo(at(i, values[i]).dx, at(i, values[i]).dy);
    }
    area.lineTo(at(values.length - 1, 0).dx, plot.bottom);
    area.close();
    canvas.drawPath(area, Paint()..color = const Color(0x261E88E5));
    var line = Path()..moveTo(at(0, values[0]).dx, at(0, values[0]).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(at(i, values[i]).dx, at(i, values[i]).dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF1E88E5),
    );
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(
        at(i, values[i]),
        3,
        Paint()..color = const Color(0xFF1E88E5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) =>
      oldDelegate.values != values;
}
