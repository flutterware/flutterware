import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// A folder on the real clock — said once, here, and nowhere per scenario.
Future<void> testExecutable(FutureOr<void> Function() testMain) => runScenarios(
  testMain,
  time: ScenarioTime.real(),
  // A phone, so a capture here is taken at a device size rather than the
  // tester's 800×600 — the case the blank-picture question was about.
  profile: ScenarioProfile('live', devices: [Devices.iphone13Mini]),
);
