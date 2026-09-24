import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// The README's cards: a 4:3 window, small enough that a panel still reads at
/// half a README column, and the rail folded away by each scenario's last
/// step — the card is the panel, not the chrome around it.
///
/// Not a device anybody owns, so it is declared here rather than in the
/// table: `scenarios shots` takes a profile's first device as it is.
const readmeCard = Device(
  'readme-card',
  'README card',
  kind: DeviceKind.desktop,
  platform: DevicePlatform.macos,
  group: 'Desktop',
  width: 960,
  height: 720,
  pixelRatio: 2,
);

const readme = ScenarioProfile('readme', devices: [readmeCard]);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: readme);
