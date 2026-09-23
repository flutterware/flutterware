import 'package:material_ui/material_ui.dart';
import 'package:flutterware/render.dart';
import 'package:pdf/widgets.dart' as pw;

/// The example app's render points — what `fw render bundle` compiles into
/// a server-side bundle, and what the integration test drives end to end.
///
/// In a real app the two descriptors below live in a pure-Dart contract
/// package shared with the server; the example keeps everything in one file.
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

@RenderRegistry()
void registerRenders(RenderHost host) {
  host.widget(monthlyChart, (context, args) => _Chart(args));

  host.document(chartReport, (context, args) async {
    var chart = await context.captureSvg(
      _Chart(args),
      size: const Size(400, 200),
    );
    return pw.Document()..addPage(
      pw.Page(
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Monthly report'),
            pw.SizedBox(height: 12),
            pw.SvgImage(svg: chart.text, width: 400, height: 200),
          ],
        ),
      ),
    );
  });
}

class _Chart extends StatelessWidget {
  const _Chart(this.args);

  final ChartRequest args;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              args.title,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF212121),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var value in args.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          height: value,
                          color: const Color(0xFF1E88E5),
                        ),
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
