import 'dart:convert';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/drive/resolve.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';

/// What one beat costs, part by part, on trees of increasing size.
///
/// Not an assertion — a measurement, printed. Run it with
/// `fvm flutter test test/drive/beat_cost_bench.dart`.
///
/// Named `_bench` rather than `_test` on purpose: there is no `dart_test.yaml`
/// to exclude a tag, and the runner collects `*_test.dart`, so this stays out
/// of the suite and runs only when it is named.
void main() {
  for (var rows in [100, 400, 1200]) {
    testWidgets('$rows rows', (tester) async {
      await tester.pumpWidget(_App(rows: rows));
      await tester.pumpAndSettle();

      var inspector = GuestInspector(
        rootOf: () => WidgetsBinding.instance.rootElement,
        entryIdOf: () => null,
      );

      var elements = 0;
      void count(Element e) {
        elements++;
        e.visitChildren(count);
      }

      WidgetsBinding.instance.rootElement!.visitChildren(count);

      Duration time(int reps, void Function() body) {
        for (var i = 0; i < 20; i++) {
          body(); // warm the JIT properly — the first call is 4x the steady one
        }
        var sw = Stopwatch()..start();
        for (var i = 0; i < reps; i++) {
          body();
        }
        sw.stop();
        return Duration(microseconds: sw.elapsedMicroseconds ~/ reps);
      }

      var treeMs = time(5, () => inspector.read());
      var jsonMs = time(5, () => jsonEncode(inspector.read().toJson()));
      var textsMs = time(5, () => visibleTextsOf(tester));
      var semanticsMs = time(5, () => inspector.readSemantics());

      // The picture, the way `_screenshot` takes it.
      var view = WidgetsBinding.instance.renderViews.first;
      var layer = view.debugLayer! as OffsetLayer;
      var physical = view.size * view.flutterView.devicePixelRatio;
      var longest = physical.longestSide;
      var scale = longest > 900 ? 900 / longest : 1.0;

      late Duration imageMs;
      late Duration pngMs;
      late Duration b64Ms;
      var bytes = 0;
      await tester.runAsync(() async {
        var sw = Stopwatch()..start();
        var image = await layer.toImage(
          Offset.zero & physical,
          pixelRatio: scale,
        );
        imageMs = sw.elapsed;
        sw
          ..reset()
          ..start();
        var data = await image.toByteData(format: ui.ImageByteFormat.png);
        pngMs = sw.elapsed;
        bytes = data!.lengthInBytes;
        sw
          ..reset()
          ..start();
        base64Encode(data.buffer.asUint8List());
        b64Ms = sw.elapsed;
        image.dispose();
      });

      String us(Duration d) =>
          '${(d.inMicroseconds / 1000).toStringAsFixed(2)}ms';

      // ignore: avoid_print
      print(
        '\n== $rows rows | $elements elements | '
        '${physical.width.toInt()}x${physical.height.toInt()} '
        'scaled ${scale.toStringAsFixed(2)}\n'
        '  tree walk        ${us(treeMs)}\n'
        '  tree walk+json   ${us(jsonMs)}\n'
        '  visibleTexts     ${us(textsMs)}\n'
        '  semantics        ${us(semanticsMs)}\n'
        '  toImage          ${us(imageMs)}\n'
        '  toByteData(png)  ${us(pngMs)}  -> ${(bytes / 1024).toStringAsFixed(1)}KB\n'
        '  base64           ${us(b64Ms)}',
      );
    });
  }
}

class _App extends StatelessWidget {
  const _App({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Beat cost')),
      // A Column, not a ListView: a lazy list builds only what is visible and
      // the tree stops growing, which is the opposite of what is measured here.
      body: SingleChildScrollView(
        child: Column(
          children: [
            for (var i = 0; i < rows; i++)
              ListTile(
                key: ValueKey('row-$i'),
                leading: const Icon(Icons.circle),
                title: Text('Order #$i'),
                subtitle: Text('Placed on day $i, awaiting pickup'),
                trailing: TextButton(
                  onPressed: () {},
                  child: const Text('Cancel'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
