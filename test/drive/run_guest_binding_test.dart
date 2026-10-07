import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/run_guest.dart';

/// The guest makes the binding before the app's `main` runs, so an app that
/// calls `runApp` from a zone of its own calls it from inside the guest's.
///
/// Reported by a consumer whose dev entry point wraps `main` in
/// `runZonedGuarded`, as crash reporting is set up: every launch printed
/// Flutter's "Zone mismatch" from `runApp`, and every drive step carried it.
///
/// `test` rather than `testWidgets`, which would make a test binding first: the
/// point is the binding a run guest makes, and a process holds one binding.
void main() {
  late Zone guest;
  var reported = <FlutterErrorDetails>[];

  setUpAll(() {
    FlutterError.onError = reported.add;
    runZoned(() {
      guest = Zone.current;
      RunGuestBinding.ensureInitialized();
    });
  });
  setUp(reported.clear);

  test('runApp from a zone the app made inside the guest’s is quiet', () {
    guest.run(
      () => runZonedGuarded(
        () => runApp(const SizedBox()),
        (error, stack) => fail('$error'),
      ),
    );
    expect(reported, isEmpty);
  });

  test('a zone outside the guest’s still gets Flutter’s own error', () {
    runZoned(() => WidgetsBinding.instance.debugCheckZone('runApp'));
    expect('${reported.single.exception}', contains('Zone mismatch'));
  });

  test('a second guest finds the binding rather than making another', () {
    expect(RunGuestBinding.ensureInitialized(), same(WidgetsBinding.instance));
  });
}
