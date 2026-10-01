import 'package:flutterware/plugins.dart';
import 'package:test/test.dart';

/// `PreviewsPackage.setup` crosses to the tool as a path, because the config is
/// JSON and a function does not survive being printed.
void main() {
  const app = Pkg('app');

  Map<String, Object?> declared(PreviewsPackage package) {
    late String emitted;
    Flutterware.configure(
      (fw) => fw.use(Previews(packages: [package])),
      emit: (line) => emitted = line,
    );
    var packages =
        PluginManifest.parse(emitted).plugins.single.config['packages']!
            as List;
    return (packages.single as Map).cast<String, Object?>();
  }

  test('the setup rides the manifest as the path it was given', () {
    expect(
      declared(const PreviewsPackage(app, setup: 'lib/preview_setup.dart')),
      {'path': 'app', 'setup': 'lib/preview_setup.dart'},
    );
  });

  test('a package that declares none carries no key', () {
    expect(declared(const PreviewsPackage(app)), {'path': 'app'});
  });
}
