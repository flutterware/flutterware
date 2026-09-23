import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';
import 'package:flutterware/src/inspect/guest_inspect.dart';
import 'package:flutterware/src/scenarios/run_args.dart';
import 'package:flutterware/src/scenarios/run_listener.dart';

/// A translation export photographs the screens that show a key, and no
/// others.
///
/// It files a shot against a *string id*, so a screen showing no key can
/// contribute no shot: rasterizing it, encoding it and writing it produces a
/// file nothing will ever link to. Measured on the example suite, 23 of 62
/// steps were that file — and the picture is the one part of a step whose cost
/// grows with the screen.
const catalog = <String, String>{'title': 'Brewline', 'cart': 'Your order'};

String t(String key) => indexTranslations('shop')(key, catalog[key]!);

void main() {
  var captures = <ScenarioStepCapture>[];
  setUp(() {
    captures = [];
    scenarioRunListener = captures.add;
    var inspector = GuestInspector(
      rootOf: () => WidgetsBinding.instance.rootElement,
      entryIdOf: () => null,
    );
    scenarioScreenReader = () => ScenarioScreenRead(tree: inspector.read());
    TranslationIndex.reset();
    TranslationIndex.recording = true;
  });
  tearDown(() {
    scenarioRunListener = null;
    scenarioScreenReader = null;
    scenarioRunArgs = null;
    TranslationIndex.reset();
    TranslationIndex.recording = false;
  });

  /// What each step's picture came out as — `'none'` for the ones skipped.
  List<String> formats() => [for (var capture in captures) '${capture.format}'];

  group('asking for keyed pixels', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.keyed),
    );
    scenario('photographs the screens showing a key and skips the rest', (
      s,
    ) async {
      await s.pumpWidget(const _Shop());
      await s.tap('Nothing to translate');
      await s.tap('Back');
    });
    tearDown(() {
      expect(formats(), ['png', 'none', 'png']);
      // The skipped step is a step like any other — it reports its size, its
      // words and its tree, and only the bytes are missing. The survey reads
      // screen share off those dimensions.
      var skipped = captures[1];
      expect(skipped.bytes, isEmpty);
      expect(skipped.width, greaterThan(0));
      expect(skipped.texts, contains('Nothing to translate here'));
      expect(skipped.screen, isNotNull);
    });
  });

  group('a step that failed', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.keyed),
    );
    scenario('is photographed even with no key on it', (s) async {
      await s.pumpWidget(const _Shop());
      await s.tap('Nothing to translate');
      await expectLater(() => s.tap('Nothing by this name'), throwsA(anything));

      expect(formats(), ['png', 'none', 'png']);
      expect(captures.last.failure, isNotNull);
      expect(captures.last.bytes, isNotEmpty);
    });
  });

  group('asking for nothing', () {
    setUp(
      () =>
          scenarioRunArgs = const ScenarioRunArgs(pixels: ScenarioPixels.none),
    );
    scenario('skips the keyed screens too', (s) async {
      await s.pumpWidget(const _Shop());
      await s.tap('Nothing to translate');
    });
    tearDown(() => expect(formats(), ['none', 'none']));
  });

  group('saying nothing', () {
    scenario('photographs everything, as every other run does', (s) async {
      await s.pumpWidget(const _Shop());
      await s.tap('Nothing to translate');
    });
    tearDown(() => expect(formats(), ['png', 'png']));
  });
}

/// Two screens: one carrying catalog strings, one carrying only words that
/// belong to no catalog — which is the distinction the mode turns on, and not
/// the same as "has no text".
class _Shop extends StatefulWidget {
  const _Shop();

  @override
  State<_Shop> createState() => _ShopState();
}

class _ShopState extends State<_Shop> {
  var _away = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: _away
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Nothing to translate here'),
                  TextButton(
                    onPressed: () => setState(() => _away = false),
                    child: const Text('Back'),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('title')),
                  Text(t('cart')),
                  TextButton(
                    onPressed: () => setState(() => _away = true),
                    child: const Text('Nothing to translate'),
                  ),
                ],
              ),
      ),
    ),
  );
}
