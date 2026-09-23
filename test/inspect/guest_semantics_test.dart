import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/inspect/semantics.dart';

/// The guest half of the live Semantics tab: what `ext.flutterware.semantics`
/// serves. The enable-from-off path needs a real app (a `testWidgets` guest
/// already holds a semantics handle), so what is pinned here is the contract
/// the host settles on: the entry id arrives with the tree, and the wire
/// round-trips.
void main() {
  testWidgets('names the entry once a tree exists, and round-trips', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextButton(onPressed: () {}, child: const Text('Buy')),
        ),
      ),
    );
    var inspector = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => 'demo/a.dart#x',
    );

    var read = inspector.readSemantics();
    expect(read.entryId, 'demo/a.dart#x');
    expect(read.root, isNotNull);

    var decoded = InspectSemantics.fromJson(
      (jsonDecode(jsonEncode(read.toJson())) as Map).cast<String, Object?>(),
    );
    expect(decoded.entryId, 'demo/a.dart#x');
    expect(decoded.root, isNotNull);
  });

  testWidgets('enabling is idempotent both ways', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('still here')));
    var inspector = GuestInspector(
      rootOf: () => tester.binding.rootElement,
      entryIdOf: () => 'demo/a.dart#x',
    );

    // The test binding holds its own handle, so semantics stays on however
    // this toggles — what is asserted is that the bookkeeping cannot crash
    // or double-dispose.
    inspector.enableSemantics(true);
    inspector.enableSemantics(true);
    inspector.enableSemantics(false);
    inspector.enableSemantics(false);
    expect(inspector.readSemantics().root, isNotNull);
  });
}
