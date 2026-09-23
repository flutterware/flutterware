import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/target.dart';

/// What a step is labelled with, and compared by.
///
/// A comparison aligns two runs' steps by this string, so it has to mean the
/// same thing in two processes. A `Finder` interpolated does not: its
/// `toString` evaluates and dumps the widgets it matched, identity hashes and
/// all — which is how one real suite came back with 38 steps "retargeted" and
/// nothing retargeted about any of them.
void main() {
  final hash = RegExp(r'#[0-9a-f]{5}(?![0-9a-f])');

  testWidgets('a Finder says what it looks for, not what it found', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: TextEditingController())),
      ),
    );

    var described = describeTarget(find.byType(TextField));

    expect(described, 'widget with type "TextField"');
    expect(described, isNot(contains('TextEditingController')));
  });

  // The three shapes from the report, and the property that matters for all
  // of them: two processes must produce the same string.
  testWidgets('no target carries an address', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              const BackButton(),
              TextField(controller: TextEditingController()),
              const Placeholder(key: ValueKey('thumb_5')),
            ],
          ),
        ),
      ),
    );

    for (var target in [
      find.byType(TextField),
      find.byType(BackButton).hitTestable(),
      find
          .ancestor(
            of: find.byKey(const ValueKey('thumb_5')),
            matching: find.byType(Scrollable),
          )
          .first,
    ]) {
      var described = describeTarget(target);
      expect(described, isNot(matches(hash)), reason: described);
      expect(described.length, lessThan(200), reason: described);
    }
  });

  test('the shapes that already read well are untouched', () {
    expect(describeTarget('Pay'), '"Pay"');
    expect(describeTarget(const ValueKey('save')), "key 'save'");
  });

  // The author's own words are content, not an address.
  test("a target's own text keeps a hash-shaped tail", () {
    expect(describeTarget('Order#12345'), '"Order#12345"');
  });
}
