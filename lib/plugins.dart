/// The flutterware plugin contract.
///
/// Pure Dart on purpose — **nothing here may import `package:flutter`**. A
/// project's `tool/flutterware.dart` runs under a plain `dart run`, and every
/// type below has to survive the trip to a CLI, a file projection or an agent,
/// not just to the GUI.
library;

export 'src/canvases.dart';
export 'src/devices.dart';
export 'src/plugins/action.dart';
export 'src/plugins/address.dart';
export 'src/plugins/artifact.dart';
export 'src/plugins/changes_config.dart';
export 'src/plugins/child.dart';
export 'src/plugins/status_badge.dart';
export 'src/scenarios/time_mode.dart' show ScenarioTime;
export 'src/plugins/first_party.dart';
export 'src/plugins/fuzzy.dart';
export 'src/plugins/guard.dart';
export 'src/plugins/manifest.dart';
export 'src/plugins/package.dart';
export 'src/plugins/project_identity.dart';
export 'src/plugins/plugin.dart';
export 'src/plugins/plugin_result.dart';
export 'src/plugins/report.dart';
export 'src/plugins/result_shape.dart';
export 'src/plugins/search.dart';
export 'src/plugins/status.dart';
export 'src/plugins/store.dart';
export 'src/plugins/teardown.dart';
export 'src/plugins/tone.dart';
export 'src/plugins/view.dart';
