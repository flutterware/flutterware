import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/render.dart';
import 'package:pdf/widgets.dart' as pw;

/// The whole app-side story of the render contract, in-process: a shared
/// contract package declares typed render points, a registrar binds
/// implementations, and both entry kinds execute — the widget one mounted
/// offscreen and captured, the document one composing a pw.Document with a
/// captured widget block inside.
// --- What the app team's pure-Dart contract package would hold -------------

class ChartRequest {
  ChartRequest({required this.title, required this.values});

  final String title;
  final List<double> values;

  Map<String, Object?> toJson() => {'title': title, 'values': values};

  static ChartRequest fromJson(Map<String, Object?> json) => ChartRequest(
    title: json['title']! as String,
    values: [for (var v in json['values']! as List) (v as num).toDouble()],
  );
}

final monthlyChart = WidgetRender<ChartRequest>(
  'charts/monthly',
  encodeArgs: (args) => args.toJson(),
  decodeArgs: ChartRequest.fromJson,
);

final chartReport = DocumentRender<ChartRequest>(
  'reports/chart',
  encodeArgs: (args) => args.toJson(),
  decodeArgs: ChartRequest.fromJson,
);

// --- What the app binds --------------------------------------------------

@RenderRegistry()
void registerRenders(RenderHost host) {
  host.widget(monthlyChart, (context, args) => _Chart(args));

  host.document(chartReport, (context, args) async {
    var chart = await context.captureSvg(
      _Chart(args),
      size: const Size(300, 150),
    );
    return pw.Document()..addPage(
      pw.Page(
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Report'),
            pw.SvgImage(svg: chart.text, width: 300, height: 150),
          ],
        ),
      ),
    );
  });
}

void main() {
  RenderBindings bind() {
    var bindings = RenderBindings();
    registerRenders(bindings);
    return bindings;
  }

  test('the registrar binds points, and a duplicate name refuses', () {
    var bindings = bind();
    expect(bindings.entries, hasLength(2));
    expect(bindings['charts/monthly'], isA<BoundWidgetRender<ChartRequest>>());
    expect(bindings['reports/chart'], isA<BoundDocumentRender<ChartRequest>>());
    expect(() => registerRenders(bindings), throwsStateError);
  });

  test(
    'render options roundtrip the wire and compile to the callback form',
    () {
      var options = const RenderOptions(
        text: TextPolicy.systemFont,
        textByFamily: {'MaterialIcons': TextPolicy.vectorize},
        unsupported: UnsupportedPolicy.skip,
        rasterScale: 2,
      );
      var decoded = RenderOptions.fromJson(
        jsonDecode(jsonEncode(options.toJson())) as Map<String, Object?>,
      );
      expect(decoded.textFor('MaterialIcons'), TextPolicy.vectorize);
      expect(decoded.textFor('Roboto'), TextPolicy.systemFont);
      expect(decoded.textFor(null), TextPolicy.systemFont);
      expect(decoded.unsupported, UnsupportedPolicy.skip);
      expect(decoded.rasterScale, 2);

      var capture = decoded.toCaptureOptions();
      TextRun run(String? family) => TextRun(
        text: 'x',
        x: 0,
        baseline: 10,
        fontFamily: family,
        fontSize: 12,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
        color: const Color(0xFF000000),
      );
      expect(capture.text(run('MaterialIcons')), TextPolicy.vectorize);
      expect(capture.text(run('Roboto')), TextPolicy.systemFont);
      expect(capture.unsupported, UnsupportedPolicy.skip);
    },
  );

  testWidgets('a widget render mounts offscreen through the json door', (
    tester,
  ) async {
    var bound = bind()['charts/monthly']! as BoundWidgetRender<ChartRequest>;
    var context = RenderContext();
    var args = ChartRequest(title: 'Devices', values: [30, 60, 45]);
    var widget = bound.buildFromJson(context, monthlyChart.encodeArgs(args));
    var svg = await context.captureSvg(widget, size: const Size(300, 150));
    expect(svg.text, contains('Devices'));
    expect(svg.text, contains('<rect'));
    expect(svg.warnings, isEmpty);
  });

  testWidgets('a document render composes a pw.Document around a captured '
      'widget block', (tester) async {
    var bound = bind()['reports/chart']! as BoundDocumentRender<ChartRequest>;
    var doc = await bound.build(
      RenderContext(),
      ChartRequest(title: 'Devices', values: [30, 60, 45]),
    );
    var bytes = await doc.save();
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(500));
  });

  testWidgets('unmounting an offscreen widget disposes its states', (
    tester,
  ) async {
    var disposed = false;
    var mounted = OffscreenWidget.mount(
      _DisposeProbe(onDispose: () => disposed = true),
      size: const Size(50, 50),
    );
    expect(disposed, isFalse);
    mounted.dispose();
    expect(
      disposed,
      isTrue,
      reason:
          'a resident guest mounts once per request; a State that never '
          'disposes is a leak per render',
    );
  });

  testWidgets('a widget that throws while building warns instead of '
      'passing as a clean success', (tester) async {
    var result = await captureWidgetSvg(
      const _Throws(),
      size: const Size(50, 50),
      // skip: the error box is a paragraph the capture cannot recover, and
      // rasterizing it would need the engine mid-fake-async.
      options: CaptureOptions(unsupported: UnsupportedPolicy.skip),
    );
    expect(
      result.warnings.map((w) => w.kind),
      contains(RenderWarningKind.buildError),
    );
  });
}

class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Throws extends StatelessWidget {
  const _Throws();

  @override
  Widget build(BuildContext context) => throw StateError('deliberately broken');
}

/// Raster-free on purpose: text and plain boxes, so the capture path stays
/// synchronous under the test binding's fake async.
class _Chart extends StatelessWidget {
  const _Chart(this.args);

  final ChartRequest args;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              args.title,
              style: const TextStyle(fontSize: 14, color: Color(0xFF212121)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var value in args.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        width: 30,
                        height: value,
                        color: const Color(0xFF1E88E5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
