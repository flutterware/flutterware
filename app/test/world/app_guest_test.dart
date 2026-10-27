import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/run/entrypoint_knobs.dart';
import 'package:flutterware_app/src/run/wrapper_import.dart';
import 'package:flutterware_app/src/world/app_guest.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory package;
  setUp(() {
    package = Directory.systemTemp.createTempSync('world_enum_knobs');
    addTearDown(() => package.deleteSync(recursive: true));
  });

  void write(String path, String source) => File(p.join(package.path, path))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);

  test("turns an enum knob's name back into the constant main takes, "
      'wherever the enum is declared', () async {
    write('pubspec.yaml', 'name: shop\nenvironment:\n  sdk: ^3.0.0\n');
    write('demo/src/env.dart', 'enum Env { local, stage }');
    write('demo/main_dev.dart', '''
import 'src/env.dart' as config;

enum Look { plain, loud }

void main({
  config.Env env = config.Env.stage,
  Look look = Look.plain,
  String server = '',
}) {}
''');
    var scan = scanEntrypointKnobs(
      packageRoot: package.path,
      entrypoint: 'demo/main_dev.dart',
    );
    // Where the guest build writes it, beside Run's wrapper.
    write(
      p.posix.join(wrapperDirectory, 'knobs.dart'),
      enumKnobsSource(
        scan,
        entryImport: wrapperImportOf('demo/main_dev.dart', package: 'shop'),
      ),
    );
    write('check.dart', '''
import '$wrapperDirectory/knobs.dart';

void main() {
  print([
    enumKnobs['env']!('local'),
    enumKnobs['look']!('loud'),
    enumKnobs.containsKey('server'),
  ]);
}
''');
    var dart = p.join(Platform.environment['FLUTTER_ROOT']!, 'bin', 'dart');
    var run = await Process.run(dart, [
      'check.dart',
    ], workingDirectory: package.path);
    expect(run.stderr, '');
    expect('${run.stdout}'.trim(), '[Env.local, Look.loud, false]');
  });

  test("an entry point with no enum knobs gets none of main's imports", () {
    var source = enumKnobsSource(
      const EntrypointKnobs(imports: ["import 'package:shop/config.dart';"]),
      entryImport: 'package:shop/main.dart',
    );
    expect(source, isNot(contains('import')));
    expect(source, contains('final enumKnobs'));
  });
}
