# Renders

Turn a Flutter widget into a file: SVG, PNG or PDF. Draw a chart, an invoice
or a certificate with your app's widgets, then render it from a script, from
the command line, or from a Dart server that has no screen.

The SVG and PDF are real vector documents: text stays text, and anything a
vector format can't express is reported rather than silently dropped.

## Declare what can be rendered

A **render point** is a named, typed entry: what it's called and what
arguments it takes. The app then says how to draw each one:

```dart
// lib/renders.dart
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/render.dart';

final monthlyChart = WidgetRender<ChartRequest>(
  'charts/monthly',
  encodeArgs: (args) => args.toJson(),
  decodeArgs: ChartRequest.fromJson,
);

@RenderRegistry()
void registerRenders(RenderHost host) {
  host.widget(monthlyChart, (context, args) => MonthlyChart(args));
}
```

`DocumentRender` works the same way for a multi-page PDF built with
[`package:pdf`](https://pub.dev/packages/pdf), and a document can include a
widget captured as SVG.

## Turn it on

```dart
// tool/flutterware.dart
fw.use(Renders(packages: [.new(app)]));
```

The registrar is looked for in `lib/renders.dart`; `target:` points elsewhere.

In the studio, the **Renders** panel lists the points and renders them live.

## From the command line

```shell
fw render charts/monthly --as=svg --size=400x200 \
    --args='{"title": "March", "values": [3, 5, 2]}' -o chart.svg
fw render reports/chart --as=pdf --args=@request.json -o report.pdf
```

## From a server

A server can't run Flutter itself, so the render points are compiled into a
bundle that a pool of background renderers loads:

```shell
fw render bundle --out=build/render-bundle
```

```dart
import 'package:flutterware/render_client.dart';

var pool = await RenderPool.start(bundle: 'build/render-bundle');
var chart = await pool.svg(
  monthlyChart,
  ChartRequest(title: 'March', values: [3, 5, 2]),
  size: RenderSize(400, 200),
);
print(chart.text);
```

`render_client.dart` doesn't import Flutter. Keep the render points in a file
that imports only `package:flutterware/render_contract.dart`, so the server
and the app share them. The deployed server needs the bundle directory, not a
Flutter SDK.

## Render any widget, in your own code

Without declaring anything, `package:flutterware/render.dart` also has
`captureWidgetSvg`, `captureWidgetPdf` and `captureWidgetPng`, which render a
widget offscreen from inside a Flutter app or test.

## Reference

[`flutterware.render` in the capabilities reference](../docs/capabilities.md#flutterwarerender),
and `fw help render`.
