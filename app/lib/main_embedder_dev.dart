import 'package:material_ui/material_ui.dart';

import 'src/embedder/embedder_harness_screen.dart';

/// IDE dev entrypoint: runs only the embedder harness screen.
///
/// A macOS app launched by `flutter run` has a stripped environment (no PATH,
/// no `FLUTTER_HOME`) and a working directory of `/`, so neither the Flutter
/// SDK nor the `app/` package root can be discovered from inside the process.
/// Pass them in explicitly:
///
/// ```sh
/// cd app && flutter run -t lib/main_embedder_dev.dart -d macos \
///   --dart-define=FLUTTERWARE_APP_ROOT="$(pwd)" \
///   --dart-define=FLUTTER_SDK_ROOT="$(cd "$(dirname "$(which flutter)")/.." && pwd)"
/// ```
const _appRootDefine = String.fromEnvironment('FLUTTERWARE_APP_ROOT');
const _sdkRootDefine = String.fromEnvironment('FLUTTER_SDK_ROOT');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // No fallback to discovery: the environment described above cannot answer,
  // so a fallback here only delays [_MissingDefines] by a process launch.
  var flutterSdkRoot = _sdkRootDefine;

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: (_appRootDefine.isEmpty || flutterSdkRoot.isEmpty)
          ? const _MissingDefines()
          : EmbedderHarnessScreen(
              appPackageRoot: _appRootDefine,
              flutterSdkRoot: flutterSdkRoot,
            ),
    ),
  );
}

class _MissingDefines extends StatelessWidget {
  const _MissingDefines();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'The embedder harness needs the app and SDK paths.\n\n'
            'Run it with the --dart-define flags FLUTTERWARE_APP_ROOT and '
            'FLUTTER_SDK_ROOT set — see the run command in '
            'app/lib/src/embedder/README.md.',
            style: TextStyle(color: Colors.red),
          ),
        ),
      ),
    );
  }
}
