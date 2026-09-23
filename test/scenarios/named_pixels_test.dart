import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// A store run photographs the shots somebody named, and no others.
///
/// `scenarios shots` keeps the named shots and deletes everything else — and it
/// captures at the device's own ratio, so an automatic step on a 6.9" iPhone
/// was being rasterized and encoded at eleven times the pixels of a 1× run,
/// written out, and thrown away with the scratch directory.
///
/// The half worth testing hardest is the last group. Every other mode decides
/// from the *screen*, and adoption only happens where the screen has not
/// moved — so a held capture and the shot adopting it agree by construction.
/// This one decides from the *step*, which breaks that, and the symptom is
/// silent: a named shot lands on a frame that was never rendered and the export
/// writes an empty file.
void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
  });
  tearDown(() {
    scenarioRunListener = null;
    scenarioRunArgs = null;
  });

  /// What each step's picture came out as — `'none'` for the ones skipped.
  List<String> formats() => [for (var capture in captures) '${capture.format}'];

  List<String?> names() => [for (var capture in captures) capture.name];

  group('asking for named pixels', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.named),
    );
    scenario('skips every step nobody named', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Go');
      await s.screen('Arrived');
    });
    tearDown(() {
      expect(formats(), ['none', 'none', 'png']);
      expect(names(), [null, null, 'Arrived']);
      // A skipped step is a step like any other — its size, its words and its
      // tree are all still there, and only the bytes are missing.
      var skipped = captures.first;
      expect(skipped.bytes, isEmpty);
      expect(skipped.width, greaterThan(0));
      expect(skipped.texts, contains('Go'));
    });
  });

  group('a step that failed', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.named),
    );
    scenario('is photographed though nobody named it', (s) async {
      await s.pumpWidget(const _App());
      await expectLater(() => s.tap('Nothing by this name'), throwsA(anything));

      expect(formats(), ['none', 'png']);
      expect(captures.last.name, isNull);
      expect(captures.last.failure, isNotNull);
      expect(captures.last.bytes, isNotEmpty);
    });
  });

  group('a name that would otherwise adopt the frame before it', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.named),
    );
    scenario('renders its own instead of landing on an empty one', (s) async {
      await s.pumpWidget(const _App());
      await s.tap('Go');
      await s.screen('Arrived');
    });
    tearDown(() {
      // Three captures, not two: the name did not fold onto the tap's frame.
      expect(captures, hasLength(3));
      var adopted = captures[1];
      expect(adopted.name, isNull, reason: 'the tap kept its own anonymity');
      expect(captures.last.name, 'Arrived');
      expect(
        captures.last.bytes,
        isNotEmpty,
        reason: 'a named shot with no bytes exports an empty file',
      );
    });
  });

  group('the same script with pixels unasked for', () {
    scenario('folds the name onto the frame before it, as it always has', (
      s,
    ) async {
      await s.pumpWidget(const _App());
      await s.tap('Go');
      await s.screen('Arrived');
    });
    tearDown(() {
      // The control. Two captures, because adoption is what `screen` does when
      // nothing has moved — and it is only refused above because the frame it
      // would have landed on was never taken.
      expect(formats(), ['png', 'png']);
      expect(names(), [null, 'Arrived']);
    });
  });
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  var _away = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: _away
            ? const Text('Arrived somewhere')
            : TextButton(
                onPressed: () => setState(() => _away = true),
                child: const Text('Go'),
              ),
      ),
    ),
  );
}
