import 'package:material_ui/material_ui.dart';

import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import 'src/address/address_scope.dart';
import 'src/previews/catalog_session.dart';
import 'src/previews/catalog_view.dart';

/// IDE dev entrypoint for the Previews loop, without the shell.
///
/// The same [CatalogView] the `flutterware.previews` plugin mounts as its
/// panel — this just skips the shell, for working on the loop itself.
///
/// A macOS app launched by `flutter run` has a stripped environment and a
/// working directory of `/`, so the package and SDK roots are passed in:
///
/// ```sh
/// cd app && flutter run -t lib/main_catalog_dev.dart -d macos \
///   --dart-define=FLUTTERWARE_APP_ROOT="$(pwd)" \
///   --dart-define=FLUTTER_SDK_ROOT="$(cd "$(dirname "$(which flutter)")/.." && pwd)"
/// ```
const _appRootDefine = String.fromEnvironment('FLUTTERWARE_APP_ROOT');
const _sdkRootDefine = String.fromEnvironment('FLUTTER_SDK_ROOT');

/// Scan root, so this can be pointed at a project other than the app package —
/// which is the shape the CLI-installed GUI has and the one every headless
/// harness here lacked.
const _rootsDefine = String.fromEnvironment(
  'FLUTTERWARE_ROOTS',
  defaultValue: 'tool/catalog',
);

/// Where the previews are, when that is not the app package.
const _projectDefine = String.fromEnvironment('FLUTTERWARE_PROJECT');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // No fallback to discovery: a `flutter run` GUI has a stripped environment
  // and a working directory of `/`, so nothing here could answer anyway.
  var flutterSdkRoot = _sdkRootDefine;

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xff3366ff)),
      home: (_appRootDefine.isEmpty || flutterSdkRoot.isEmpty)
          ? const _MissingDefines()
          : _Harness(flutterSdkRoot: flutterSdkRoot),
    ),
  );
}

/// Stands in for the plugin: owns the session the view renders.
class _Harness extends StatefulWidget {
  const _Harness({required this.flutterSdkRoot});

  final String flutterSdkRoot;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  /// The standalone entry's own address, so the view runs the same path here as
  /// it does under the shell.
  ///
  /// Without one, `?device=` would have nowhere to live and the picker would
  /// need a second code path — which is how the two-sources-of-truth bug got in
  /// the first place.
  final _address = ValueNotifier(
    Address(worktree: 'dev', plugin: 'flutterware.previews'),
  );

  late final CatalogSession _session = CatalogSession(
    appPackageRoot: _appRootDefine,
    // Defaults to the app package, where flutterware's own demos live;
    // override to drive a different project through the same widget.
    projectRoot: _projectDefine.isEmpty ? _appRootDefine : _projectDefine,
    // The app package sits one level inside the repo, which is what the shell
    // would call the worktree — so a path shown here matches what `fw` prints
    // from the same checkout.
    worktreeRoot: p.dirname(_appRootDefine),
    flutterSdkRoot: widget.flutterSdkRoot,
    roots: _rootsDefine.split(','),
  );

  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  void dispose() {
    _address.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AddressRoot(
    address: _address,
    onChanged: (next) => _address.value = next,
    child: Scaffold(body: CatalogView(session: _session)),
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
            'The catalog harness needs the app and SDK paths.\n\n'
            'Run it with --dart-define FLUTTERWARE_APP_ROOT and '
            'FLUTTER_SDK_ROOT set — see the doc comment in '
            'app/lib/main_catalog_dev.dart.',
            style: TextStyle(color: Colors.red),
          ),
        ),
      ),
    );
  }
}
