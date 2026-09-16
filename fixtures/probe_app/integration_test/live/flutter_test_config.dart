import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// A folder on the real clock: real timers, real sockets, one guest per
/// scenario under the runner.
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, time: ScenarioTime.real());
