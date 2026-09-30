@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutterware_app/src/embedder/build_directory.dart';
import 'package:flutterware_app/src/embedder/tester_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A source deleted between the scan and the end of the compile — a scenario
/// file removed or renamed while a run was compiling — is scanned again and
/// built around, on each of the three lanes that compile: the cold start, a
/// restart, and a sync's incremental compile.
///
/// End-to-end, a real compiler and a real `flutter_tester`, because what is
/// under test is the compiler's answer to an import of a file that is not
/// there. The race is not left to timing: the program deletes the file on
/// cue, the instant its scan has listed it.
void main() {
  test('each lane that compiles scans again when the sources moved', () async {
    var repoRoot = Directory.current.parent.path; // `flutter test` runs in app/
    var sources = Directory.systemTemp.createTempSync('tester_host_rescan');
    var lines = <String>[];
    var program = _Program(
      sources,
      BuildLane(
        repoRoot,
        preferred: 'build/flutterware/rescan_test',
        program: 'rescan',
      ),
    );
    var host = TesterHost(
      packageRoot: repoRoot,
      flutterSdkRoot: Platform.environment['FLUTTER_ROOT']!,
      program: program,
      lane: program.lane,
      onLog: lines.add,
    );
    addTearDown(() async {
      await host.dispose();
      sources.deleteSync(recursive: true);
    });
    void write(String name, [String body = '']) =>
        File(p.join(sources.path, name)).writeAsStringSync(
          "const name = '${p.basenameWithoutExtension(name)}';\n$body",
        );
    String ready() => lines.lastWhere((line) => line.contains(_ready));

    // The cold start.
    write('a.dart');
    write('b.dart');
    program.vanishAfterScan = 'b.dart';
    await host.exclusive(host.ensureGuest);
    expect(program.written, [
      ['a.dart', 'b.dart'],
      ['a.dart'],
    ]);
    expect(ready(), endsWith('$_ready a'));

    // A restart, which scans for itself.
    write('b.dart');
    write('c.dart');
    program.vanishAfterScan = 'c.dart';
    await host.exclusive(host.restartGuest);
    expect(program.written.skip(2), [
      ['a.dart', 'b.dart', 'c.dart'],
      ['a.dart', 'b.dart'],
    ]);
    expect(ready(), endsWith('$_ready a b'));

    // A sync whose scan still saw the file, and whose compile did not.
    program.vanishAfterScan = 'b.dart';
    await host.refresh();
    expect(program.written.last, ['a.dart']);
    expect(ready(), endsWith('$_ready a'));
    expect(
      lines.where((line) => line.contains('changed while compiling')),
      hasLength(3),
    );

    // And a real error, over a source set that did not move, is still the
    // real error — raised once, not retried into a second compile.
    var writes = program.written.length;
    write('a.dart', 'const broken = ;');
    await expectLater(host.refresh(), throwsA(isA<TesterCompileException>()));
    expect(program.written, hasLength(writes));
  });
}

const _ready = 'rescan harness ready';

/// A program made of every `.dart` file in [directory], whose `main` prints
/// the name each one declares.
class _Program extends TesterProgram {
  _Program(this.directory, this.lane);

  final Directory directory;
  final BuildLane lane;

  /// Deleted the moment the next scan has listed it.
  String? vanishAfterScan;

  /// Every source set an entrypoint was written for, in order.
  final written = <List<String>>[];

  @override
  String get name => 'rescan';

  @override
  String get readyLine => _ready;

  @override
  List<String> sources() {
    var files = [
      for (var file in directory.listSync().whereType<File>())
        if (file.path.endsWith('.dart')) p.basename(file.path),
    ]..sort();
    if (vanishAfterScan case var name?) {
      vanishAfterScan = null;
      File(p.join(directory.path, name)).deleteSync();
    }
    return files;
  }

  @override
  String writeEntrypoint(List<String> sources) {
    written.add(sources);
    var names = [for (var i = 0; i < sources.length; i++) '\${s$i.name}'];
    var content = [
      "import 'package:flutter/widgets.dart';",
      for (var (i, source) in sources.indexed)
        "import '${p.toUri(p.join(directory.path, source))}' as s$i;",
      '',
      'void main() {',
      '  WidgetsFlutterBinding.ensureInitialized();',
      "  print('$_ready ${names.join(' ')}');",
      '}',
      '',
    ].join('\n');
    var file = File(p.join(lane.packageRoot, lane.path, 'rescan_main.dart'))
      ..parent.createSync(recursive: true);
    if (!file.existsSync() || file.readAsStringSync() != content) {
      file.writeAsStringSync(content);
    }
    return file.path;
  }
}
