import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/ui_catalog/knobs.dart';

/// A knob exists because a build read it, which makes a build the only thing
/// that can retire one — there is no list of knobs to delete from. Without a
/// pass around each build, a knob renamed or deleted in a demo's source has
/// nothing to remove it, and lingers in the panel as a control that reads
/// nothing.
void main() {
  late EditableKnobs parameters;
  var refreshes = 0;
  var additions = 0;

  setUp(() {
    refreshes = 0;
    additions = 0;
    parameters = EditableKnobs(
      onRefresh: () => refreshes++,
      onAdded: () => additions++,
    );
  });

  List<String> declare(List<String> names) {
    parameters.beginPass();
    for (var name in names) {
      parameters.string(name, 'default');
    }
    parameters.endPass();
    return parameters.knobs.keys.toList();
  }

  test('a knob the pass did not declare is retired', () {
    declare(['label', 'count']);
    expect(declare(['label']), ['label']);
  });

  test('a renamed knob replaces the old one rather than joining it', () {
    declare(['label', 'count']);
    expect(declare(['caption', 'count']), ['caption', 'count']);
  });

  test("the order is the build's, not the order things were first seen", () {
    declare(['a', 'c']);
    // Inserted in the middle, so it belongs in the middle — a knob added to a
    // demo halfway down its build should not appear at the bottom of the panel.
    expect(declare(['a', 'b', 'c']), ['a', 'b', 'c']);
  });

  test('endPass answers how many went, so a bump can be conditional', () {
    declare(['a', 'b', 'c']);
    parameters.beginPass();
    parameters.string('a', 'default');
    expect(parameters.endPass(), 2);
  });

  test('a knob keeps its value across a pass that still declares it', () {
    declare(['label']);
    parameters.knobs['label']!.value = 'set by hand';
    declare(['label', 'other']);
    expect(parameters.knobs['label']!.value, 'set by hand');
  });

  test('without a pass nothing is retired', () {
    // The other catalog reads these parameters without pass boundaries, and
    // must keep the old behaviour: no build to bound the set, no sweep.
    parameters.string('label', 'default');
    parameters.string('count', 'default');
    expect(parameters.endPass(), 0);
    expect(parameters.knobs.keys, ['label', 'count']);
  });

  test('a retired knob stops reporting to its owner', () {
    declare(['label']);
    var retired = parameters.knobs['label']!;
    declare(['other']);
    expect(
      () => retired.value = 'ignored',
      // A FlutterError up to Flutter 3.50. From 3.51 ChangeNotifier comes from
      // package:listen, which throws a StateError.
      throwsA(anyOf(isFlutterError, isStateError)),
      reason: 'it was disposed, not merely dropped',
    );
    expect(refreshes, 0);
    expect(
      additions,
      2,
      reason: 'label, then other — declaring is what counts',
    );
  });
}
