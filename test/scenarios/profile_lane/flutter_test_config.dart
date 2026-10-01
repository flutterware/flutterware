import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// What this folder's scenarios are for. `flutter test` finds this by walking
/// up from each test file, so a folder is the unit that has a profile.
const phones = ScenarioProfile(
  'phones',
  devices: [Devices.iphone16, Devices.iphoneSe],
  languages: ['fr', 'en'],
  axes: {
    'brand': ['coffee', 'tea'],
  },
);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: phones);
