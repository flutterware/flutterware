import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/src/log_client.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'src/capture/capture_request.dart';
import 'src/constants.dart';
import 'src/context.dart';
import 'src/plugins/manifest_loader.dart';
import 'src/plugins/native/registry.dart';
import 'src/shell/shell_controller.dart';
import 'src/shell/shell_view.dart';
import 'src/utils/flutter_sdk.dart';
import 'src/identity/dock_icon.dart';
import 'src/utils/window_title.dart';

// ignore_for_file: implementation_imports

/// The production entry point: the plugin shell, against the project the CLI
/// was run from.
///
/// Requires the environment the compiled CLI sets; use `main_dev.dart` for
/// development, which is the same shell with the paths supplied by hand.
void main() async {
  var projectPath = Platform.environment[projectDefineKey];
  var appToolPath = Platform.environment[appToolPathKey];
  var flutterSdkPath = Platform.environment[flutterSdkDefineKey];

  if (projectPath == null || flutterSdkPath == null) {
    throw Exception(
      'This entry point need to be run with some Platform.environment parameters. Use main_dev.dart for development.',
    );
  }

  var appContext = AppContext(
    logger: LogClient.print(),
    // Where `native/`, `tool/catalog/` and the build directory live — the
    // copy under `~/.flutterware/`, not the user's project. The catalog needs
    // it, and only once its panel is opened.
    appToolDirectory: appToolPath != null ? Directory(appToolPath) : null,
  );
  var flutterSdk = FlutterSdkPath(flutterSdkPath);

  Logger.root
    ..level = Level.ALL
    ..onRecord.listen(appContext.logger.printLogRecord);

  var shell = ShellController(
    appContext: appContext,
    flutterSdk: flutterSdk,
    registry: buildNativeRegistry(),
    manifestLoader: ManifestLoader(
      dartExecutable: p.join(flutterSdk.root, 'bin', 'dart'),
      flutterRoot: flutterSdk.root,
    ),
  );
  // A capture run is the same window, driven and then closed. It is set up
  // before `runApp` only so the boundary exists in the first frame.
  var capture = CaptureRequest.fromEnvironment();
  var captureKey = capture == null ? null : GlobalKey();

  runApp(
    ShellApp(
      shell,
      captureKey: captureKey,
      framing: capture?.framing ?? const CaptureFraming(),
    ),
  );

  // Named here rather than before `runApp`, which is what initialises the
  // binding the channel goes through.
  await WindowTitle.setForProject(projectPath);

  // And the tile, which is what a user actually scans.
  DockIcon.follow(shell);

  // No welcome banner. It used to be printed here, and this process has no
  // terminal to print it to — `fw` owns the one it inherits, knows the plugin
  // list before the window exists, and says it there instead. What is left on
  // this stream is what belongs on it: the app's own logs.

  // After the first frame: discovery runs a subprocess, and the shell renders
  // its empty state until it resolves rather than holding up the window.
  await shell.start(projectPath);

  // Everything above is the ordinary launch, unchanged. A capture only ever
  // happens after it, against a window that came up exactly as a human's does
  // — which is the whole point of photographing this process rather than
  // rendering the panels somewhere headless.
  if (capture != null) {
    exit(await capture.run(shell, captureKey!, appContext.settle));
  }
}
