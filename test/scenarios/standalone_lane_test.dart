import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The lane a bare `flutter test` runs in: no listener, no daemon, a
/// destination directory and the files that land in it.
///
/// This is what a consumer's CI produces without the GUI anywhere near it, and
/// the one place the step's *label* is load-bearing rather than cosmetic —
/// every artifact's file name is built from it.
void main() {
  late Directory destination;
  setUp(() {
    destination = Directory.systemTemp.createTempSync('scenario_standalone');
    ScenarioTester.screenshotsDestinationOverride = destination.path;
  });
  tearDown(() {
    ScenarioTester.screenshotsDestinationOverride = null;
    if (destination.existsSync()) destination.deleteSync(recursive: true);
  });

  /// The `<index>-<label>` stems written under [destination], by index.
  ///
  /// Everything before the first dot: the suffixes a step's other artifacts
  /// wear (`.after`, and the extension) are dotted onto the stem, so one step
  /// contributes several files and exactly one stem.
  List<String> stems() => {
    for (var file in destination.listSync(recursive: true).whereType<File>())
      p.basename(file.path).split('.').first,
  }.toList()..sort((a, b) => _index(a).compareTo(_index(b)));

  group('an adopted name reaches the file names', () {
    scenario('Adopting', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      await s.screen('Counted');
    });
    // The whole reason a capture is held one step. Written when the tap
    // captured, these files would be called `2-tap_Add` and the report would
    // say `Counted` — a directory that disagrees with the panel about what its
    // own steps are called.
    tearDown(() {
      // An anonymous step wears its verb, the way the harness spells one. What
      // matters here is the second: the adopted name, on the tap's own files.
      expect(stems(), ['1-pumpWidget', '2-Counted']);
      var png = File(p.join(_scenarioDir(destination), '2-Counted.png'));
      expect(png.existsSync(), isTrue);
      expect(png.lengthSync(), greaterThan(1000));
    });
  });

  group('a screen with a frame of its own', () {
    scenario('Capturing', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Add');
      await s.tester.tap(find.text('Add'));
      await s.tester.pump();
      await s.screen('Twice');
    });
    // Three stems: the raw pump between the tap and the screen drew, so the
    // screen has a frame of its own to photograph and the tap keeps its
    // anonymous name.
    tearDown(() => expect(stems(), ['1-pumpWidget', '2-tap', '3-Twice']));
  });

  group('a beat writes its own content', () {
    scenario('Producing', (s) async {
      await s.pumpWidget(const _App());
      await s.document('request', [1], fileName: 'request.json');
      await s.tap('Add');
      await s.screen('Done');
      await s.document('receipt', [2], fileName: 'receipt.json');
      await s.notification('Receipt ready', title: 'Receipts');
    });
    // Each beat is a step with a stem of its own, so the directory reads as
    // the flow did: a screen writes its picture, a document writes the thing
    // it produced, a notification writes the push. This lane writes only what
    // a person would look at — no trees, no events — and a beat is no
    // exception to that, it simply has something other than pixels to write.
    tearDown(() {
      var dir = _scenarioDir(destination);
      expect(Directory(dir).listSync().map((e) => p.basename(e.path)).toSet(), {
        '1-pumpWidget.png',
        '2-request.request.json',
        '3-Done.png',
        '4-receipt.receipt.json',
        '5-notification.notification.json',
      });
    });
  });
}

/// The `<index>-` a stem starts with.
int _index(String stem) => int.parse(stem.split('-').first);

/// The single scenario directory the lane created under [root] — the
/// destination nests by axis slug, declaring file and scenario name.
String _scenarioDir(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => p.dirname(file.path))
    .toSet()
    .single;

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Count: $_count'),
            TextButton(
              onPressed: () => setState(() => _count++),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    ),
  );
}
