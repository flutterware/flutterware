import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// A folder with an axis of the app's own: the same screens, built for two
/// brands. `run --axes=brand=coffee,tea`, `matrix=declared` and the panel's
/// Brand picker all read it from here; a run that names nothing builds the
/// first.
const brands = ScenarioProfile(
  'brands',
  devices: [Devices.iphone16, Devices.iphoneSe],
  languages: ['en'],
  axes: {
    'brand': ['coffee', 'tea'],
  },
);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: brands);
