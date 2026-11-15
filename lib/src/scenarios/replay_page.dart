import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
// The pieces `flutter test` itself runs a file with. A replay runs one test
// of one file, so it builds the same objects rather than a whole runner.
// ignore: implementation_imports
import 'package:test_api/src/backend/declarer.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/group.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/live_test.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/runtime.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/suite.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/suite_platform.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/test.dart';
import 'package:web/web.dart' as web;

import '../translations/index.dart';
import 'default_fonts.dart';
import 'replay_hooks.dart';
import 'replay_index.dart' show assetKeyOfMessage, locateKeys;
import 'replay_protocol.dart';

/// One test file the replay page can run, as the generated entry point
/// declares it.
class ReplayFile {
  const ReplayFile(this.path, this.main, {this.testExecutable});

  /// Relative to the package, with `/`: what the index names it.
  final String path;

  final void Function() main;

  /// The `flutter_test_config.dart` that `flutter test` would wrap the file
  /// in: the nearest one above it.
  final FutureOr<void> Function(FutureOr<void> Function() testMain)?
  testExecutable;
}

/// Runs the scenario replay page: the project's scenarios, on the fake
/// clock, in a browser, stopped at the step a request names.
///
/// The page answers requests from three places, all with the same shape (see
/// [ReplayRequest]): a `postMessage` from the page that embeds it, a call to
/// `flutterwareReplay.run(request)` from its own console, and its address
/// (`?file=…&scenario=…&position=…`).
Future<void> runScenarioReplay(List<ReplayFile> files) async {
  AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  var page = _ReplayPage(files);
  await page.start();
}

class _ReplayPage {
  _ReplayPage(this.files);

  final List<ReplayFile> files;

  late final ReplayManifest manifest;

  /// The index beside the page, for where each key was found at each step.
  /// Read in the background; until it lands keys are found by their words.
  ReplayIndex? _index;

  final _bytes = <String, ByteData>{};

  /// What the files declare, found by declaring each once at start.
  final _scenarios = <ReplayScenario>[];

  /// Why a file declared nothing, by path.
  final _unusable = <String, String>{};

  /// Requests run one at a time, in order.
  Future<void> _queue = Future.value();

  /// Completes to let the step on screen go, so its scenario can end.
  Completer<void>? _release;

  /// The run holding the step on screen.
  Future<void>? _held;

  /// Whether the running test was stopped on purpose, so what it reports
  /// from here on is not a failure. A split wraps the stop in its own error,
  /// so the error alone cannot say.
  var _stopping = false;

  /// Where the running request keeps its failures.
  void Function(Object error)? _onFailure;

  Future<void> start() async {
    // A replay ends its test by throwing once the step is on screen. That is
    // not a failure, and the console should not say it is.
    //
    // And every failure the binding reports is kept here too: in a page,
    // test_api's own record of a test's errors stays empty, so a failing run
    // would otherwise read as a pass.
    var report = reportTestException;
    reportTestException = (details, description) {
      if (_stopping) return;
      _onFailure?.call(details.exception);
      report(details, description);
    };
    manifest = await _readManifest();
    unawaited(_readIndex());
    await _loadDefaultFonts();
    for (var file in files) {
      _scenarios.addAll(await _declared(file));
    }
    _installApi();
    var ready = {
      'type': ReplayMessages.ready,
      'scenarios': [for (var scenario in _scenarios) scenario.toJson()],
    };
    _post(ready);
    var request = ReplayRequest.fromQuery(Uri.base.queryParametersAll);
    if (request != null) {
      var result = await submit(request);
      print('[flutterware] ${jsonEncode(result.toJson())}');
    }
  }

  Future<ReplayManifest> _readManifest() async {
    try {
      var response = await http.get(Uri.base.resolve(replayManifestFile));
      if (response.statusCode == 200) {
        return ReplayManifest.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        );
      }
    } catch (_) {}
    // Without one every read is a miss, which each result says.
    return ReplayManifest.empty;
  }

  Future<void> _readIndex() async {
    try {
      var response = await http.get(Uri.base.resolve(replayIndexFile));
      if (response.statusCode == 200) {
        _index = ReplayIndex.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        );
      }
    } catch (_) {}
  }

  /// Declares [file] and records what it declared. Nothing runs.
  Future<List<ReplayScenario>> _declared(ReplayFile file) async {
    var found = <String, List<ReplayPoint>>{};
    scenarioDeclarationHook = (name, description, point) {
      (found[description] ??= []).add(
        ReplayPoint(
          testName: name,
          label: point?.label ?? '',
          device: point?.device?.id,
          language: point?.language,
        ),
      );
    };
    try {
      await _declare(file);
    } catch (error) {
      _unusable[file.path] = describeReplayFailure(error);
      print('[flutterware] ${file.path} could not be declared: $error');
    } finally {
      scenarioDeclarationHook = null;
    }
    return [
      for (var MapEntry(key: description, value: points) in found.entries)
        ReplayScenario(file: file.path, scenario: description, points: points),
    ];
  }

  Future<Group> _declare(ReplayFile file, {String? only}) async {
    var declarer = Declarer(fullTestName: only);
    await declarer.declare(() async {
      var executable =
          file.testExecutable ?? (FutureOr<void> Function() main) => main();
      await executable(file.main);
    });
    return declarer.build();
  }

  void _installApi() {
    var api = JSObject();
    api['run'] = ((JSAny? request) {
      var json = _decode(request);
      return submit(ReplayRequest.fromJson(json))
          .then((result) => jsonEncode(result.toJson()).toJS)
          .toJS;
    }).toJS;
    api['scenarios'] = (() => jsonEncode([
      for (var scenario in _scenarios) scenario.toJson(),
    ]).toJS).toJS;
    globalContext['flutterwareReplay'] = api;

    web.window.addEventListener(
      'message',
      ((web.MessageEvent event) {
        var data = _decode(event.data);
        if (data['type'] != ReplayMessages.run) return;
        var id = data['id'];
        unawaited(
          submit(ReplayRequest.fromJson(data)).then((result) {
            _post({
              'type': ReplayMessages.result,
              'id': ?id,
              ...result.toJson(),
            });
          }),
        );
      }).toJS,
    );
  }

  static Map<String, Object?> _decode(JSAny? value) {
    if (value == null) return const {};
    if (value.isA<JSString>()) {
      return jsonDecode((value as JSString).toDart) as Map<String, Object?>;
    }
    var dart = value.dartify();
    return dart is Map ? dart.cast<String, Object?>() : const {};
  }

  void _post(Map<String, Object?> message) {
    var parent = web.window.parent;
    if (parent == null || parent == web.window) return;
    parent.postMessage(message.jsify(), '*'.toJS);
  }

  /// Runs [request] after every request before it.
  Future<ReplayResult> submit(ReplayRequest request) {
    var result = _queue.then((_) => _replay(request));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _letGo() async {
    if (_release case var release?) {
      _release = null;
      release.complete();
      await _held;
      _held = null;
    }
  }

  Future<ReplayResult> _replay(ReplayRequest request) async {
    await _letGo();
    var watch = Stopwatch()..start();
    var scenario = _scenarios
        .where((s) => s.file == request.file && s.scenario == request.scenario)
        .firstOrNull;
    if (scenario == null) {
      if (_unusable[request.file] case var why?) {
        return ReplayResult.refused(
          request,
          '${request.file} could not be declared: $why',
        );
      }
      return ReplayResult.refused(
        request,
        'No scenario "${request.scenario}" in ${request.file}. The page knows '
        '${_scenarios.length} scenarios; `flutterwareReplay.scenarios()` '
        'lists them.',
      );
    }
    var point = scenario.pointFor(
      language: request.language,
      device: request.device,
    );
    var aimed = branchesOfPosition(request.position);
    if (aimed == null) {
      return ReplayResult.refused(
        request,
        '"${request.position}" is not a step position. A position is the '
        'split branches taken, then # and the step: #3, or 1.0#2.',
      );
    }
    var file = files.firstWhere((f) => f.path == request.file);

    var missed = <String>{};
    await _fetchAssets(manifest.assetsOfFile(request.file));
    var fetched = watch.elapsedMilliseconds;

    TranslationIndex.drafts
      ..clear()
      ..addAll(request.drafts);
    scenarioAimedBranches = aimed;

    Group group;
    try {
      group = await _declare(file, only: point.testName);
    } catch (error) {
      scenarioAimedBranches = null;
      return ReplayResult.failed(request, point, describeReplayFailure(error));
    }
    var (test, parents) = _find(group, point.testName) ?? (null, <Group>[]);
    if (test == null) {
      scenarioAimedBranches = null;
      return ReplayResult.refused(
        request,
        '${point.testName} was not declared when ${file.path} was declared '
        'again.',
      );
    }

    _serveAssets(missed);
    var reached = Completer<ReplayResult>();
    var steps = 0;
    _stopping = false;
    var failures = <String>[];
    _onFailure = (error) {
      if (_stopping || error is _Stopped) return;
      var said = describeReplayFailure(error);
      if (!failures.contains(said)) failures.add(said);
    };
    scenarioStepHook = (step) async {
      if (step.scenario != request.scenario) return;
      steps++;
      if (step.position != request.position) return;
      var tester = step.tester;
      // An error the binding is holding back until the test ends belongs
      // to a step before this one, and the picture may show it.
      if (tester.takeException() case var pending?) {
        failures.add(describeReplayFailure(pending as Object));
      }
      var boxes = [
        for (var MapEntry(:key, value: rects) in locateKeys(
          tester,
          request.locate,
          addresses:
              _index?.addressesAt(
                request.file,
                request.scenario,
                request.position,
              ) ??
              const {},
        ).entries)
          for (var rect in rects)
            ReplayBox(
              key: key,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
            ),
      ];
      _stopping = true;
      // All of it in `runAsync`'s real zone. A completer made in the fake
      // one completes as a fake microtask that nothing flushes, and the page
      // would hold this step forever.
      await tester.runAsync(() async {
        var release = _release = Completer<void>();
        var shown = _paint(tester);
        reached.complete(
          ReplayResult(
            request: request,
            point: point,
            reached: true,
            ok: failures.isEmpty,
            steps: steps,
            ms: watch.elapsedMilliseconds,
            assetsMs: fetched,
            failures: List.of(failures),
            missedAssets: missed.toList()..sort(),
            width: shown.size.width,
            height: shown.size.height,
            boxes: boxes,
          ),
        );
        await release.future;
        shown.dispose();
      });
      throw const _Stopped();
    };

    var ended = Completer<void>();
    _held = ended.future;
    unawaited(() async {
      try {
        var suite = Suite(group, SuitePlatform(Runtime.chrome));
        for (var parent in parents) {
          if (parent.setUpAll case var setUp?) {
            await _runLive(setUp.load(suite, groups: parents));
          }
        }
        await _runLive(test.load(suite, groups: parents));
        for (var parent in parents.reversed) {
          if (parent.tearDownAll case var tearDown?) {
            await _runLive(tearDown.load(suite, groups: parents));
          }
        }
      } finally {
        scenarioStepHook = null;
        scenarioAimedBranches = null;
        _onFailure = null;
        if (!reached.isCompleted) {
          reached.complete(
            ReplayResult(
              request: request,
              point: point,
              reached: false,
              ok: false,
              steps: steps,
              ms: watch.elapsedMilliseconds,
              assetsMs: fetched,
              failures: failures.isEmpty
                  ? ['The scenario ended after $steps steps without reaching ${request.position}.']
                  : failures,
              missedAssets: missed.toList()..sort(),
            ),
          );
        }
        ended.complete();
      }
    }());
    var result = await reached.future;
    if (!result.reached) {
      // Nothing is held; the run is over.
      await ended.future;
      _held = null;
    }
    return result;
  }

  /// Runs one test to its end and reports every error it raised to
  /// [_onFailure], including those raised after its body returned: a failed
  /// tear-down, a timer left pending, an exception the binding held back.
  ///
  /// In its own error zone, because in a page those leave test_api's zones
  /// as uncaught errors, and its record of the test says it passed.
  Future<void> _runLive(LiveTest live) async {
    var errors = live.onError.listen((error) => _onFailure?.call(error.error));
    var done = Completer<void>();
    runZonedGuarded(() => unawaited(live.run().whenComplete(done.complete)), (
      error,
      stack,
    ) {
      // The binding's own summary of a failure it already reported.
      if ('$error'.startsWith('Test failed. See exception logs above.')) {
        return;
      }
      _onFailure?.call(error);
    });
    try {
      await done.future;
    } finally {
      await errors.cancel();
      await live.close();
    }
  }

  static (Test, List<Group>)? _find(Group group, String name) {
    (Test, List<Group>)? walk(Group group, List<Group> parents) {
      var path = [...parents, group];
      for (var entry in group.entries) {
        switch (entry) {
          case Group inner:
            if (walk(inner, path) case var found?) return found;
          case Test test when test.name == name:
            return (test, path);
        }
      }
      return null;
    }

    return walk(group, const []);
  }

  BinaryMessenger get _engine => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .delegate;

  /// Reads [keys] into memory, in real time and outside any test.
  ///
  /// A read started under the fake clock never completes in a browser: its
  /// answer is a real network event, and the fake clock waits for none.
  Future<void> _fetchAssets(Iterable<String> keys) async {
    await Future.wait([
      for (var key in {...manifest.commonAssets, ...keys})
        if (!_bytes.containsKey(key))
          Future(() async {
            var data = await _engine.send('flutter/assets', _encodeKey(key));
            if (data != null) _bytes[key] = data;
          }).catchError((_) {}),
    ]);
  }

  /// Answers the app's asset reads from memory. A key the index did not
  /// record goes to the network, which under the fake clock may never
  /// answer, and is reported in [missed].
  void _serveAssets(Set<String> missed) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) {
          if (message == null) return Future.value();
          var key = assetKeyOfMessage(message);
          if (_bytes[key] case var data?) return Future.value(data);
          missed.add(key);
          var data = _readNow(key);
          if (data != null) _bytes[key] = data;
          return Future.value(data);
        });
  }

  /// Reads an asset the index did not record, synchronously.
  ///
  /// A read the fake clock waits on has to answer before the next frame, and
  /// a network read only answers on the real event loop. A blocking request
  /// is the one kind that answers in time. It is the slow path: each one is
  /// reported, so the index can be fixed.
  static ByteData? _readNow(String key) {
    try {
      var request = web.XMLHttpRequest()
        ..open('GET', ui_web.assetManager.getAssetUrl(key), false)
        // Text, byte for byte: a blocking request cannot ask for binary.
        ..overrideMimeType('text/plain; charset=x-user-defined')
        ..send();
      if (request.status != 200) return null;
      var text = request.responseText;
      var bytes = Uint8List(text.length);
      for (var i = 0; i < text.length; i++) {
        bytes[i] = text.codeUnitAt(i) & 0xFF;
      }
      return ByteData.sublistView(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Loads the faces a `flutter test` run draws default text in, under the
  /// families Flutter's themes name, so the page lays text out as the run
  /// did. A family the app declares itself keeps its own.
  Future<void> _loadDefaultFonts() async {
    if (manifest.defaultFonts.isEmpty) return;
    var declared = <String>{};
    try {
      var response = await http.get(
        Uri.parse(ui_web.assetManager.getAssetUrl('FontManifest.json')),
      );
      for (var entry in jsonDecode(response.body) as List) {
        declared.add('${(entry as Map)['family']}');
      }
    } catch (_) {}
    var faces = <ByteData>[];
    for (var path in manifest.defaultFonts) {
      try {
        var response = await http.get(Uri.base.resolve(path));
        if (response.statusCode == 200) {
          faces.add(ByteData.sublistView(response.bodyBytes));
        }
      } catch (_) {}
    }
    if (faces.isEmpty) return;
    for (var family in scenarioDefaultFontFamilies) {
      if (declared.contains(family)) continue;
      var loader = FontLoader(family);
      for (var face in faces) {
        loader.addFont(Future.value(face));
      }
      await loader.load();
    }
  }

  static ByteData _encodeKey(String key) =>
      ByteData.sublistView(utf8.encode(Uri(path: Uri.encodeFull(key)).path));

  /// Shows the tester's last frame, scaled to fit the page, until the
  /// returned value is disposed. Called in the real zone.
  ///
  /// The engine takes a scene only from inside its own frame callback, and
  /// the fake-clock binding never runs one, so the frame is drawn from a real
  /// one here, and again whenever the page is resized. It is captured first,
  /// outside any frame: a hidden page gets no frames until it is shown, and
  /// the answer should not wait for that.
  ({ui.Size size, void Function() dispose}) _paint(WidgetTester tester) {
    var view = tester.binding.renderViews.first;
    var physical = tester.view.physicalSize;
    // `layer`, not `debugLayer`: the page is built with asserts off, and
    // `debugLayer` answers only through one.
    // ignore: invalid_use_of_protected_member
    var scene = view.layer!.buildScene(ui.SceneBuilder());
    var frame = scene.toImageSync(
      physical.width.ceil(),
      physical.height.ceil(),
    );
    scene.dispose();
    var dispatcher = ui.PlatformDispatcher.instance;
    var priorDraw = dispatcher.onDrawFrame;
    var priorBegin = dispatcher.onBeginFrame;
    var priorMetrics = dispatcher.onMetricsChanged;
    dispatcher.onBeginFrame = null;
    dispatcher.onDrawFrame = () => _present(frame);
    dispatcher.onMetricsChanged = () {
      priorMetrics?.call();
      dispatcher.scheduleFrame();
    };
    dispatcher.scheduleFrame();
    return (
      size: physical / tester.view.devicePixelRatio,
      dispose: () {
        dispatcher.onDrawFrame = priorDraw;
        dispatcher.onBeginFrame = priorBegin;
        dispatcher.onMetricsChanged = priorMetrics;
        frame.dispose();
      },
    );
  }

  /// Draws [frame] into the page's own view, as large as fits, centered.
  static void _present(ui.Image frame) {
    var real = ui.PlatformDispatcher.instance.implicitView;
    if (real == null) return;
    // The window's size, said out loud. The test binding renders each frame
    // at the device's size, and the page would otherwise keep that size.
    var limits = real.physicalConstraints;
    var biggest = Size(limits.maxWidth, limits.maxHeight);
    var size = biggest.isFinite ? biggest : real.physicalSize;
    if (size.isEmpty) return;
    var width = frame.width.toDouble();
    var height = frame.height.toDouble();
    var scale = math.min(size.width / width, size.height / height);
    var shown = Size(width * scale, height * scale);
    var at = Offset(
      (size.width - shown.width) / 2,
      (size.height - shown.height) / 2,
    );
    var recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      frame,
      Offset.zero & Size(width, height),
      at & shown,
      Paint()..filterQuality = FilterQuality.medium,
    );
    var builder = ui.SceneBuilder()
      ..addPicture(Offset.zero, recorder.endRecording());
    var scene = builder.build();
    real.render(scene, size: size);
    scene.dispose();
  }
}

class _Stopped implements Exception {
  const _Stopped();

  @override
  String toString() => 'The replay stopped at the step it was asked for.';
}
