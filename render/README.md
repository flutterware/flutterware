# flutterware_render

Turn a Flutter widget into a file: SVG, PNG or PDF. The SVG and PDF are real
vector documents: text stays text, and anything a vector format can't express
is reported in the result's warnings.

This is the drawing half of [flutterware](https://pub.dev/packages/flutterware)'s
renders. Add it to the app that draws:

```shell
flutter pub add flutterware_render
```

## Render a widget

```dart
import 'package:flutterware_render/flutterware_render.dart';

var svg = await captureWidgetSvg(MonthlyChart(data), size: Size(400, 200));
var pdf = await captureWidgetPdf(MonthlyChart(data), size: Size(400, 200));
```

`captureSvg` and `capturePdf` do the same for a widget that is already laid
out on screen, from its `RenderObject`.

## Render from a server

Declare render points and bind them in a function marked `@RenderRegistry()`.
`fw render bundle` compiles them into a directory that a pure Dart server
drives with `RenderPool`, from `package:flutterware/render_client.dart`.

The [Renders guide](https://flutterware.dev/docs/renders/) covers both.
