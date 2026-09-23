import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
// The only flutter_test imports the guest needs: a controller that drives a
// live binding, and the finder vocabulary. No binding, no package:test.
//
// Note: mixing in `TestDefaultBinaryMessengerBinding` to get
// `setMockMethodCallHandler` was tried and **deadlocks the guest during
// binding init** — it never reaches runApp. Plugins are faked at the platform
// interface instead (`XxxPlatform.instance = Fake()`), which is plain Dart and
// never reaches a channel at all.
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController, find;

/// S1 spike guest: a normal Flutter app that drives itself with
/// [LiveWidgetController] and reports each step (text projection + a real
/// rendered frame) back over a Unix socket named by `FW_SCENARIO_SOCKET`.
Future<void> main() async {
  var binding = WidgetsFlutterBinding.ensureInitialized();
  runApp(const _DemoApp());
  unawaited(_Driver(binding).run());
}

class _Driver {
  _Driver(this.binding);

  final WidgetsBinding binding;
  late final LiveWidgetController controller = LiveWidgetController(binding);

  // ignore: close_sinks — closed at the end of run(), past the analyzer's reach.
  Socket? _socket;
  int _stepIndex = 0;
  int _generation = 0;

  Future<void> run() async {
    await _connect();
    // Probe 1: does dart:io work at all inside the embedder guest?
    _send({
      'type': 'hello',
      'pid': pid,
      'envCount': Platform.environment.length,
      'dartVersion': Platform.version,
    });
    _send({'type': 'plugins', ...await _pluginProbe()});

    var socket = _socket;
    if (socket == null) {
      await _runOnce();
      return;
    }
    // Command loop. Hot reload replaces method bodies in place and never
    // re-runs main(), so this driver survives a reload and the next `run`
    // executes the *new* _scenario() body.
    await for (var line
        in socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      var command = jsonDecode(line) as Map<String, Object?>;
      if (command['type'] == 'quit') break;
      if (command['type'] == 'run') await _runOnce();
    }
    await socket.flush();
    await socket.close();
  }

  Future<void> _runOnce() async {
    _stepIndex = 0;
    // Hot reload deliberately *preserves* State, so a re-run would otherwise
    // start from wherever the previous run left the app. Remounting the root
    // under a fresh key gives every run a clean tree without restarting the
    // process — the guest, the engine and the compiler all stay warm.
    runApp(_DemoApp(key: ValueKey(_generation++)));
    await controller.pumpAndSettle();
    try {
      await _scenario().timeout(const Duration(seconds: 30));
      _send({'type': 'done', 'ok': true});
    } catch (e, st) {
      _send({'type': 'done', 'ok': false, 'error': '$e', 'stack': '$st'});
    }
  }

  /// The scenario itself. This is the shape the whole spike is testing: plain
  /// `await controller.<verb>` with `find.<matcher>`, no WidgetTester.
  Future<void> _scenario() async {
    await controller.pumpAndSettle();
    await _capture('initial');

    await controller.tap(find.text('Tap me'));
    await controller.pumpAndSettle();
    await _capture('after first tap');

    await controller.tap(find.text('Tap me'));
    await controller.pumpAndSettle();
    await _capture('after second tap');

    const expected = 'Taps: 2';
    if (find.text(expected).evaluate().isEmpty) {
      throw StateError(
        'expected "$expected" after two taps; texts=${_texts()}',
      );
    }

    await controller.tap(find.byIcon(Icons.palette));
    await controller.pumpAndSettle();
    await _capture('after theme toggle');
  }

  /// Plugins are faked at the platform-interface layer, which never reaches a
  /// channel. This probe covers the case where one slips through unfaked.
  ///
  /// Today it reports `TimeoutException`: `host.c` has no platform task runner,
  /// so nothing ever replies and the call hangs. Once the host grows one this
  /// should flip to `MissingPluginException`, matching `flutter_tester`.
  Future<Map<String, Object?>> _pluginProbe() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    var watch = Stopwatch()..start();
    try {
      var value = await channel
          .invokeMethod<String>('getApplicationDocumentsDirectory')
          .timeout(const Duration(seconds: 1));
      return {'outcome': 'returned: $value', 'ms': watch.elapsedMilliseconds};
    } catch (e) {
      return {'outcome': '${e.runtimeType}', 'ms': watch.elapsedMilliseconds};
    }
  }

  Future<void> _connect() async {
    var path = Platform.environment['FW_SCENARIO_SOCKET'];
    if (path == null) return;
    _socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
  }

  /// The "what is shown in the app" projection — structure, for an agent.
  List<String> _texts() => controller
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>()
      .toList();

  /// The pixels projection — a real rasterised frame from the live tree.
  Future<Uint8List> _png() async {
    var renderView = RendererBinding.instance.renderViews.first;
    var layer = renderView.debugLayer! as OffsetLayer;
    var image = await layer.toImage(renderView.paintBounds);
    try {
      var data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _capture(String label) async {
    var png = await _png();
    _send({
      'type': 'step',
      'index': _stepIndex++,
      'label': label,
      'texts': _texts(),
      'png': base64Encode(png),
    });
  }

  void _send(Map<String, Object?> message) {
    var line = jsonEncode(message);
    var socket = _socket;
    if (socket != null) {
      socket.add(utf8.encode('$line\n'));
    } else {
      // Truncate: without a socket this goes to the guest's stdout.
      stdout.writeln(line.length > 400 ? '${line.substring(0, 400)}…' : line);
    }
  }
}

class _DemoApp extends StatefulWidget {
  const _DemoApp({super.key});

  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  int _taps = 0;
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        brightness: _dark ? Brightness.dark : Brightness.light,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Scenario spike'),
          actions: [
            IconButton(
              icon: const Icon(Icons.palette),
              onPressed: () => setState(() => _dark = !_dark),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Taps: $_taps', style: const TextStyle(fontSize: 40)),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => setState(() => _taps++),
                child: const Text('Tap me'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
