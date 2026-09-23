import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/ui/selectable_line.dart';

/// Where in a line's box a drag should start or stop.
///
/// The boxes are as wide as the list, so their centres are usually well past
/// the last glyph — a drag from one would start at the end of the line and
/// select nothing of it. These aim at the text instead.
Offset _in(WidgetTester tester, Finder line, {double x = 1}) =>
    tester.getTopLeft(line) + Offset(x, 8);

Offset _pastEndOf(WidgetTester tester, Finder line) =>
    tester.getTopRight(line) - const Offset(1, -8);

void main() {
  /// Drags from one point to another with a mouse, copies, and answers with
  /// what reached the clipboard.
  Future<String?> select(
    WidgetTester tester, {
    required Offset from,
    required Offset to,
  }) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    var gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // Copied through the region rather than by sending a chord, so the test
    // does not have to know which platform's shortcut this build binds.
    var region = tester.state(find.byType(SelectableRegion));
    (region as dynamic).copySelection(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
    return copied;
  }

  Future<void> pumpLines(
    WidgetTester tester,
    List<Widget> lines, {
    double width = 300,
    double height = 600,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: SelectionArea(
              child: ListView.builder(
                itemCount: lines.length,
                itemBuilder: (context, index) =>
                    FwSelectableLine(child: lines[index]),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpText(
    WidgetTester tester,
    List<String> lines, {
    double width = 300,
  }) => pumpLines(tester, [for (var line in lines) Text(line)], width: width);

  testWidgets('whole lines paste back as lines', (tester) async {
    await pumpText(tester, ['alpha', 'bravo', 'charlie', 'delta']);
    var copied = await select(
      tester,
      from: _in(tester, find.text('alpha')),
      to: _pastEndOf(tester, find.text('delta')),
    );
    expect(copied, 'alpha\nbravo\ncharlie\ndelta\n');
  });

  testWidgets('a selection stopping inside a line stops there', (tester) async {
    await pumpText(tester, ['alpha', 'bravo', 'charlie', 'delta']);
    var copied = await select(
      tester,
      from: _in(tester, find.text('alpha')),
      to: _in(tester, find.text('delta'), x: 20),
    );
    expect(copied, startsWith('alpha\nbravo\ncharlie\n'));
    expect(copied, isNot(endsWith('\n')));
  });

  testWidgets('a word out of one line copies without a terminator', (
    tester,
  ) async {
    await pumpText(tester, ['alpha bravo charlie']);
    var line = find.text('alpha bravo charlie');
    var copied = await select(
      tester,
      from: _in(tester, line),
      to: _in(tester, line, x: 20),
    );
    expect(copied, isNotNull);
    expect(copied, isNotEmpty);
    expect(copied, isNot(contains('\n')));
  });

  testWidgets('a wrapped line copies as one line', (tester) async {
    var long = 'LONG ${'wrap ' * 40}END';
    await pumpText(tester, ['before', long, 'after']);
    // It really is wrapped: many visual rows, one logical line.
    expect(tester.getSize(find.text(long)).height, greaterThan(100));
    var copied = await select(
      tester,
      from: _in(tester, find.text('before')),
      to: _pastEndOf(tester, find.text('after')),
    );
    expect(copied, 'before\n$long\nafter\n');
  });

  testWidgets('a line carrying its own newlines keeps them', (tester) async {
    var trace = 'Unhandled exception\n  #0 one\n  #1 two';
    await pumpText(tester, ['before', trace, 'after']);
    var copied = await select(
      tester,
      from: _in(tester, find.text('before')),
      to: _pastEndOf(tester, find.text('after')),
    );
    expect(copied, 'before\n$trace\nafter\n');
  });

  testWidgets('a gutter kept out of the selection stays out of the clipboard', (
    tester,
  ) async {
    await pumpLines(tester, [
      for (var index = 0; index < 3; index++)
        Row(
          children: [
            SelectionContainer.disabled(
              child: SizedBox(width: 40, child: Text('${index + 1}')),
            ),
            Text('line-$index'),
          ],
        ),
    ]);
    var copied = await select(
      tester,
      from: _in(tester, find.text('line-0')),
      to: _pastEndOf(tester, find.text('line-2')),
    );
    expect(copied, 'line-0\nline-1\nline-2\n');
  });

  testWidgets('a blank line does not survive, and this is where that is said', (
    tester,
  ) async {
    // Written down rather than wished away. An empty [Text] reports no
    // content, so the enclosing region never calls the container that holds it
    // — measured: three rows, two calls — which leaves nothing here to tell a
    // blank line inside the selection from a line outside it. Copying a
    // stretch of a diff closes up its blank lines. Pinned so that a Flutter
    // that starts asking is noticed rather than quietly relied upon.
    await pumpText(tester, ['alpha', '', 'charlie']);
    var copied = await select(
      tester,
      from: _in(tester, find.text('alpha')),
      to: _pastEndOf(tester, find.text('charlie')),
    );
    expect(copied, 'alpha\ncharlie\n');
  });

  testWidgets('a drag beginning on a line edge does not take the line above', (
    tester,
  ) async {
    await pumpText(tester, ['alpha', 'bravo', 'charlie']);
    var copied = await select(
      tester,
      // The very top of the row, which rests on the end of the one above.
      from: tester.getTopLeft(find.text('bravo')) + const Offset(1, 0),
      to: _pastEndOf(tester, find.text('charlie')),
    );
    expect(copied, isNot(startsWith('\n')));
    expect(copied, 'bravo\ncharlie\n');
  });
}
