import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// A folder on the real clock — said once, here, and nowhere per scenario.
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, time: ScenarioTime.real());
