import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';

import 'async_watchdog.dart';

/// The real-time lane's binding: `LiveTestWidgetsFlutterBinding` with three
/// things changed, each measured to be necessary on a consumer's suite
/// (`2026-09-16-live-scenarios-findings-and-design.md`).
///
/// - HTTP is left alone. The base class installs `flutter_test`'s 400 mock
///   whatever the binding, and only the integration_test binding flips it.
/// - Animation time is scaled **around the body**: the base class asserts
///   `timeDilation == 1.0` the moment the body returns, before any
///   `addTearDown` runs, so a test that sets it fails at its own end.
/// - Platform messages go through the harness's spy messenger, so a channel
///   call lands on the step like it does under fake time.
class LiveHarnessBinding extends LiveTestWidgetsFlutterBinding {
  LiveHarnessBinding({required this.animations, required this.wrapMessenger});

  /// The ticker scale while a body runs.
  final double animations;

  /// The harness's spy around the binding's own messenger; identity for the
  /// bare `flutter test` lane, which records nothing.
  final TestDefaultBinaryMessenger Function(TestDefaultBinaryMessenger)
  wrapMessenger;

  @override
  bool get overrideHttpClient => false;

  @override
  TestDefaultBinaryMessenger createBinaryMessenger() =>
      wrapMessenger(super.createBinaryMessenger());

  /// The view is the surface, as it is under the automated binding.
  ///
  /// `LiveTestWidgetsFlutterBinding` lays the tree out on an 800×600 test
  /// surface whatever the view's size, and paints that surface into the view
  /// through a fit-and-centre matrix — it was written for a test watched on
  /// a device's screen. The harness stages a device the other way round: it
  /// sets the view's physical size, exactly as a widget test does, and every
  /// capture and every hit test reads the view. Under the matrix a phone-sized
  /// step came back as an 800×600 picture with the app shrunk into its lower
  /// half, and a tap at a widget's centre landed on whatever the matrix put
  /// there instead. Measured on a consumer's welcome screen, 2026-09-16.
  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) =>
      ViewConfiguration.fromView(renderView.flutterView);

  // A hot reload schedules a warm-up frame; outside a test that frame
  // asserts. The same guard the fake-time binding carries.
  @override
  void scheduleWarmUpFrame() {
    if (inTest) super.scheduleWarmUpFrame();
  }

  // Watched here for the reason the fake-time binding watches it: a
  // `tester.runAsync` that wedges takes the run down just as quietly.
  @override
  Future<T?> runAsync<T>(Future<T> Function() callback) =>
      watchRunAsync(() => super.runAsync(callback));

  @override
  Future<void> runTest(
    Future<void> Function() testBody,
    VoidCallback invariantTester, {
    String description = '',
  }) => super.runTest(
    () async {
      timeDilation = animations;
      try {
        await testBody();
      } finally {
        timeDilation = 1.0;
      }
    },
    invariantTester,
    description: description,
  );
}
