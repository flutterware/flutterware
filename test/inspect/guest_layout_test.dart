import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';

/// The space a box is reported in.
///
/// Logical pixels, whatever the screen's ratio — the space `{"at"}`, `at
/// "x,y"`, a drag's `dx` and every hit test take. A run guest and a scenario
/// root their walk at the view itself, and the view's own paint transform is
/// the device pixel ratio, so measuring up to it rather than to the window
/// reported every box ×3 on a phone: `item: N` then tapped off the screen.
void main() {
  testWidgets('a box rooted at the view is in logical pixels', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Padding(
          padding: EdgeInsets.only(left: 40, top: 100),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text('the box', key: Key('box')),
          ),
        ),
      ),
    );

    var tree = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => null,
    ).read();

    var box = tree.nodes
        .singleWhere(
          (node) => node.description == 'Text("the box")',
          orElse: () => fail('no Text("the box") in the tree'),
        )
        .layout!;
    var rect = tester.getRect(find.byKey(const Key('box')));
    expect(rect.topLeft, const Offset(40, 100));
    expect(Rect.fromLTWH(box.x, box.y, box.width, box.height), rect);
  });
}
