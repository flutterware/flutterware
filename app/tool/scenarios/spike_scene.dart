import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/group.dart';
import 'package:test_api/src/backend/live_test.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';

// ignore_for_file: implementation_imports, depend_on_referenced_packages

/// S4 spike guest: runs a FakeAsync scenario under
/// `AutomatedTestWidgetsFlutterBinding` inside a directly-spawned
/// `flutter_tester`, capturing a PNG + the visible texts per step.
///
/// Driven by the host (`run_spike.dart`) over the VM service: `ext.spike.run`
/// runs the whole scenario and returns the step list, so a hot reload
/// followed by another call is the edit-to-rerun loop the design needs.
///
/// The strings below are edited by the host's hot cycle — keep them as
/// recognisable constants.
const _counterPrefix = 'Taps';
const _expectedAfterTwoTaps = 'Taps: 2';
const _initialLabel = 'initial';

late final String _outDir;

Future<void> main() async {
  _outDir = Platform.environment['FW_SPIKE_OUT']!;
  var binding = _SpikeBinding();

  var fonts = await _loadBundleFonts();

  developer.registerExtension('ext.spike.run', (method, params) async {
    var result = await _runScenario(binding, params['run'] ?? 'run');
    return developer.ServiceExtensionResponse.result(jsonEncode(result));
  });

  // The engine keeps the process alive, but give the isolate a port of its own
  // so it can never be considered idle between host calls.
  Timer.periodic(const Duration(days: 1), (_) {});
  print('S4 guest ready — fonts loaded: ${fonts.join(', ')}');
}

class _SpikeBinding extends AutomatedTestWidgetsFlutterBinding {
  // A hot reload schedules a warm-up frame; outside a test that frame asserts.
  // Same guard the 2026-05 port's binding used.
  @override
  void scheduleWarmUpFrame() {
    if (inTest) super.scheduleWarmUpFrame();
  }
}

/// Loads every font the asset bundle's `FontManifest.json` declares —
/// the app's own fonts plus `MaterialIcons`. This is the step `flutter test`
/// makes users do by hand (the golden_toolkit dance); here it is the harness's
/// job.
Future<List<String>> _loadBundleFonts() async {
  var manifest = jsonDecode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;
  var families = <String>[];
  for (var entry in manifest.cast<Map<String, dynamic>>()) {
    var family = entry['family']! as String;
    var loader = FontLoader(family);
    for (var font in (entry['fonts']! as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
    families.add(family);
  }
  return families;
}

Future<Map<String, Object?>> _runScenario(
  TestWidgetsFlutterBinding binding,
  String runId,
) async {
  var watch = Stopwatch()..start();
  var steps = <Map<String, Object?>>[];

  var declarer = Declarer();
  declarer.declare(() {
    testWidgets('spike scenario', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const _SpikeApp());
      await _capture(tester, steps, runId, _initialLabel);

      await tester.tap(find.text('Tap me'));
      await tester.pump();
      await tester.tap(find.text('Tap me'));
      await tester.pump();
      await _capture(tester, steps, runId, 'after two taps');

      // `enterText` was the "largest API gap" of the LiveWidgetController
      // route (S1). Here it is just flutter_test working.
      await tester.enterText(find.byType(TextField), 'typed in a scenario');
      await tester.pump();
      await _capture(tester, steps, runId, 'after enterText');

      expect(find.text(_expectedAfterTwoTaps), findsOneWidget);
      expect(find.text('typed in a scenario'), findsOneWidget);
    });
  });

  var lives = await _runGroup(declarer.build());
  var failures = [
    for (var live in lives)
      if (!live.state.result.isPassing)
        for (var error in live.errors) '${error.error}\n${error.stackTrace}',
  ];
  return {
    'ok': failures.isEmpty,
    'ms': watch.elapsedMilliseconds,
    'steps': steps,
    'errors': failures,
  };
}

Future<void> _capture(
  WidgetTester tester,
  List<Map<String, Object?>> steps,
  String runId,
  String label,
) async {
  var texts = [
    for (var text in tester.widgetList<Text>(find.byType(Text)))
      text.data ?? text.textSpan?.toPlainText() ?? '',
  ];
  await tester.runAsync(() async {
    var view = tester.binding.renderViews.single;
    var layer = view.debugLayer! as OffsetLayer;
    var image = await layer.toImage(Offset.zero & view.size);
    var data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    var file = File(
      p.join(
        _outDir,
        '$runId-${steps.length}-${label.replaceAll(' ', '_')}.png',
      ),
    );
    file.writeAsBytesSync(data.buffer.asUint8List());
    steps.add({
      'label': label,
      'texts': texts,
      'png': file.path,
      'bytes': data.lengthInBytes,
    });
  });
}

// Minimal copy of the 2026-05 port's `run_group.dart` — drives the declared
// tests without `flutter test`'s runner.
Future<List<LiveTest>> _runGroup(Group group) async {
  var suite = Suite(group, SuitePlatform(Runtime.vm));
  var results = <LiveTest>[];
  for (var entry in group.entries) {
    if (entry is Test) {
      var live = entry.load(suite, groups: [group]);
      await live.run();
      results.add(live);
    }
  }
  return results;
}

/// The app under test. Every text is a font hammer:
/// bundle Roboto (regular + bold), MaterialIcons glyphs, CJK fallback, emoji
/// fallback — none of which may render as Ahem boxes or tofu.
class _SpikeApp extends StatelessWidget {
  const _SpikeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: _CounterPage());
  }
}

class _CounterPage extends StatefulWidget {
  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  var _taps = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scenario spike S4')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_counterPrefix: $_taps', style: const TextStyle(fontSize: 24)),
          const Text(
            'Bold Roboto 700',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
          ),
          const Text('こんにちは世界 — CJK fallback', style: TextStyle(fontSize: 20)),
          const Text('Emoji: 🎉 🚀 ❤️', style: TextStyle(fontSize: 20)),
          const Row(
            children: [
              Icon(Icons.favorite, size: 32),
              Icon(Icons.add_a_photo, size: 32),
              Icon(Icons.wifi, size: 32),
            ],
          ),
          ElevatedButton(
            onPressed: () => setState(() => _taps++),
            child: const Text('Tap me'),
          ),
          const SizedBox(
            width: 300,
            child: TextField(
              decoration: InputDecoration(hintText: 'Type here'),
            ),
          ),
        ],
      ),
    );
  }
}
