import 'dart:async';

import 'package:flutterware/flutter_test.dart';

/// The guides' pictures, and the window the README's hero is drawn around:
/// a laptop's window, wide enough that a panel shows its list, its content and
/// its dock at once.
const docsWindow = Device(
  'docs-window',
  'Docs window',
  kind: DeviceKind.desktop,
  platform: DevicePlatform.macos,
  group: 'Desktop',
  width: 1440,
  height: 900,
  pixelRatio: 2,
);

const docs = ScenarioProfile('docs', devices: [docsWindow]);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: docs);
