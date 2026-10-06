import 'dart:io';

import 'package:flutterware_app/src/utils/flutter_sdk.dart';
import 'package:path/path.dart' as p;

/// Builds the studio's web demo: `web_demo/demo/main.dart` compiled for the
/// web, with the recording copied beside it.
///
/// ```sh
/// cd app && fvm dart run tool/demo/build_web.dart [--base-href /demo/]
/// ```
///
/// The page reads its recording from `demo/fixture/` relative to the
/// document, so the recording must sit next to `index.html` — and it is not
/// an asset of the app, on purpose: see `lib/src/demo/recording.dart`. This
/// is the one place that knows both halves, which is why CI and
/// `integration_test/web_demo_test.dart` call it rather than
/// `flutter build web` directly.
///
/// The SDK is the one running this script, the same way every command in the
/// repository names its SDK.
Future<void> main(List<String> args) async {
  var baseHref = '/';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base-href' && i + 1 < args.length) {
      baseHref = args[++i];
    } else {
      stderr.writeln(
        'usage: dart run tool/demo/build_web.dart [--base-href /path/]',
      );
      exit(64);
    }
  }
  var packageRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var demo = p.join(p.dirname(packageRoot), 'web_demo');
  var out = p.join(packageRoot, 'build', 'web');
  var sdk = await FlutterSdkPath.findSdk();
  if (sdk == null) {
    stderr.writeln(
      "Run this through a Flutter SDK's dart: fvm dart run tool/demo/build_web.dart",
    );
    exit(1);
  }
  // The demo app's previews, as a table the page compiles in — regenerated
  // on every build so the page never ships a stale one.
  var generated = await Process.start(
    sdk.dart,
    ['run', 'tool/demo/web_entries.dart'],
    workingDirectory: packageRoot,
    mode: ProcessStartMode.inheritStdio,
  );
  if (await generated.exitCode case var code when code != 0) exit(code);
  // Built from the web demo's own package, which imports both this one and
  // the demo app's previews. The output lands here, where the deploy and the
  // browser test expect it.
  var result = await Process.start(
    sdk.flutter,
    [
      'build',
      'web',
      '-t',
      'demo/main.dart',
      '--output',
      out,
      '--base-href',
      baseHref,
      // Leaves out the service worker Flutter is retiring, which only ever
      // showed up as a console error on this page.
      '--pwa-strategy=none',
    ],
    workingDirectory: demo,
    mode: ProcessStartMode.inheritStdio,
  );
  var code = await result.exitCode;
  if (code != 0) exit(code);

  var fixture = Directory(p.join(packageRoot, 'demo', 'fixture'));
  var target = Directory(p.join(out, 'demo', 'fixture'));
  if (target.existsSync()) target.deleteSync(recursive: true);
  var copied = 0;
  for (var entity in fixture.listSync(recursive: true)) {
    if (entity is! File) continue;
    var relative = p.relative(entity.path, from: fixture.path);
    File(p.join(target.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(entity.readAsBytesSync());
    copied++;
  }
  print(
    'Copied $copied recording files to ${p.relative(target.path, from: packageRoot)}',
  );
}
