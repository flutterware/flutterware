import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/render_bundle/bundle_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('render_bundle_');
    File(p.join(project.path, 'lib', 'renders.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
@RenderRegistry()
void registerRenders(RenderHost host) {}
''');
  });

  tearDown(() => project.deleteSync(recursive: true));

  void resolve(List<String> packages) {
    File(p.join(project.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (var name in packages)
              {'name': name, 'rootUri': 'file:///$name', 'packageUri': 'lib/'},
          ],
        }),
      );
  }

  test('a project without flutterware_render is told how to add it', () async {
    resolve(['flutter', 'flutterware']);
    await expectLater(
      buildRenderBundle(
        packageRoot: project.path,
        target: 'lib/renders.dart',
        output: p.join(project.path, 'bundle'),
        cache: FlutterCache(p.join(project.path, 'no_sdk')),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains(renderDependency),
        ),
      ),
    );
    expect(Directory(p.join(project.path, 'bundle')).existsSync(), isFalse);
  });
}
