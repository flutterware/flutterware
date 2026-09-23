/// The second pass: an app's captures, composed onto the canvas a store takes.
///
/// A program in its own right, run in a `flutter_tester` the tool spawned, with
/// the project's own frame compiled into it. It renders nothing of the app —
/// pass one already did that — so what happens here is a `pumpWidget` over a
/// decoded PNG and a capture of the result.
///
/// Kept apart from the capture pass on purpose, and the reason is a loop rather
/// than a layer: **changing a headline or a background must not re-run the
/// app.** The captures are on disk, this reads them, and a recompose is
/// seconds where a re-run is a minute. See the design's §3.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart' show Runtime, SuitePlatform;
// ignore: implementation_imports
import 'package:test_api/src/backend/declarer.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/suite.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/test.dart' as backend;

import '../devices.dart';
import '../plugins/store.dart';
import '../scenarios/fonts.dart';
import '../scenarios/run_args.dart';
import '../scenarios/staging.dart';
import 'frame.dart';

/// Serves compose requests until the host stops asking.
///
/// The generated entrypoint calls this with the project's frame — one function,
/// because a frame is handed [StoreShot.canvas] and [StoreShot.device] and a
/// widget branching on its input is what a widget is.
void runStoreFrameHarness(StoreFrame Function(StoreShot shot) build) {
  // Guarded for the reason the other two harnesses are: an async error leaking
  // after a compose completes reaches `tester_main.cc`'s unhandled handler,
  // which kills the process — and a shared harness dying because one frame
  // threw is the one outcome this may never have.
  unawaited(
    runZonedGuarded(() => _serve(build), (error, stack) {
      stderr.writeln('[store] uncaught: $error\n$stack');
    }),
  );
}

Future<void> _serve(StoreFrame Function(StoreShot shot) build) async {
  // The binding first: loading a font goes through the messenger `rootBundle`
  // reaches for, and that is the binding's.
  TestWidgetsFlutterBinding.ensureInitialized();
  var fonts = await loadScenarioFonts();

  developer.registerExtension('ext.flutterware.store.compose', (_, args) async {
    try {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(
          await composeStoreFrames(build, manifest: args['manifest']!),
        ),
      );
    } catch (error, stack) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'error': '$error', 'stack': '$stack'}),
      );
    }
  });

  // The engine keeps the process alive; the timer keeps the isolate from ever
  // reading as idle between host calls.
  Timer.periodic(const Duration(days: 1), (_) {});
  print('flutterware store frames harness ready — fonts: ${fonts.join(', ')}');
}

/// One compose job, as the host writes it into the manifest.
///
/// A file rather than flat arguments because a set is tens of jobs each
/// carrying nine fields, and a service-extension call takes a map of strings.
class _Job {
  _Job(Map<String, Object?> json)
    : image = json['image']! as String,
      set = [for (var it in json['set'] as List? ?? const []) '$it'],
      out = json['out']! as String,
      slug = json['slug']! as String,
      index = json['index']! as int,
      total = json['total']! as int,
      locale = json['locale'] as String? ?? 'en',
      device = json['device']! as String,
      canvasWidth = json['canvasWidth']! as int,
      canvasHeight = json['canvasHeight']! as int,
      canvasRatio = (json['canvasRatio']! as num).toDouble(),
      statusBrightness = _brightness(json['statusBrightness']),
      navBrightness = _brightness(json['navBrightness']);

  /// The names `SystemUiOverlayStyle` uses, as a scenario recorded them.
  /// Absent — an app that declared no style — is dark icons, for a light app.
  static Brightness _brightness(Object? name) =>
      name == 'light' ? Brightness.light : Brightness.dark;

  final String image;

  /// Every image of the set, in order — see [StoreShot.set].
  final List<String> set;

  final String out;
  final String slug;
  final int index;
  final int total;
  final String locale;
  final String device;
  final int canvasWidth;
  final int canvasHeight;
  final double canvasRatio;
  final Brightness statusBrightness;
  final Brightness navBrightness;
}

/// Every job in [manifest], composed and captured.
///
/// Answers `{'written': [paths], 'failures': {slug: why}}` — the two halves a
/// host needs, and a job is in exactly one of them. Visible so a test can put a
/// job in front of it directly: the alternative is reaching the harness through
/// a spawned `flutter_tester` and a service extension, which tests the
/// transport rather than the rule.
@visibleForTesting
Future<Map<String, Object?>> composeStoreFrames(
  StoreFrame Function(StoreShot shot) build, {
  required String manifest,
}) async {
  var jobs = [
    for (var entry in (jsonDecode(
      File(manifest).readAsStringSync(),
    ) as List).cast<Map<String, Object?>>())
      _Job(entry),
  ];

  var written = <String>[];
  var failures = <String, String>{};

  // Declared and run the way the previews harness runs its audit: a `tester` is
  // the only thing that can pump and capture, and a `Declarer` of our own is
  // how a program with no test runner gets one.
  var declarer = Declarer();
  declarer.declare(() {
    for (var job in jobs) {
      testWidgets(job.slug, (tester) async {
        var device = deviceById(job.device);
        if (device == null) {
          throw StateError(
            'no device "${job.device}" — the host resolved it, so this is a '
            'version disagreement between the harness and the tool.',
          );
        }
        var canvas = StoreCanvas(
          width: job.canvasWidth,
          height: job.canvasHeight,
          pixelRatio: job.canvasRatio,
        );
        // The canvas is the whole viewport, at its own ratio, so what
        // `toImage` produces below is already the store's exact pixel size
        // and nothing is resampled afterwards.
        var reset = applyScenarioRunArgs(
          tester,
          ScenarioRunArgs(
            size: Size(canvas.logicalWidth, canvas.logicalHeight),
            pixelRatio: canvas.pixelRatio,
          ),
        );
        try {
          var shot = StoreShot(
            image: _ShotImage(job.image),
            set: [for (var path in job.set) _ShotImage(path)],
            imageSize: Size(device.width, device.height),
            slug: job.slug,
            index: job.index,
            total: job.total,
            locale: _localeOf(job.locale),
            device: device,
            canvas: canvas,
            statusBrightness: job.statusBrightness,
            navBrightness: job.navBrightness,
          );
          await tester.pumpWidget(
            StoreFrameStage(shot: shot, child: build(shot)),
          );
          // A decode happens on the real event loop, which fake time never
          // runs — so without this turn the frame is captured with the app's
          // own pixels still missing from it, and the picture is a composition
          // around a hole.
          //
          // **Every `Image` the frame placed**, not just the shot's own. It
          // was `precacheImage(shot.image, …find.byType(Image))` — singular,
          // and correct only while a frame could paint exactly one picture. A
          // panorama paints its neighbours, and each of those would have been
          // that hole. Asked of the tree rather than of the job, so what gets
          // decoded is what was actually placed: a frame that ignores
          // [StoreShot.set] pays nothing.
          //
          // The `onError` is what makes this a check rather than only a wait.
          // [precacheImage] completes its future either way — a decode that
          // failed is indistinguishable from one that worked, from the
          // `await` — so without a handler the job walked on and captured the
          // hole the precache exists to prevent, and the export reported it as
          // a screenshot. Handled here, the failure is also kept off
          // `FlutterError`, whose only account of two of these is "Multiple
          // exceptions (2) were detected", naming neither file.
          var unreadable = <String, Object>{};
          await tester.runAsync(() async {
            for (var element in find.byType(Image).evaluate()) {
              var provider = (element.widget as Image).image;
              await precacheImage(
                provider,
                element,
                onError: (error, _) => unreadable['$provider'] ??= error,
              );
            }
          });
          if (unreadable.isNotEmpty) {
            // Reported and **not written**: a store screenshot with a hole in
            // it is worse than a set that is visibly one short, because only
            // one of the two is noticed before upload.
            failures[job.slug] = [
              for (var MapEntry(key: provider, value: error)
                  in unreadable.entries)
                'unreadable capture $provider: $error',
            ].join('\n');
            return;
          }
          await tester.pump();
          await _capture(tester, job.out);
          written.add(job.out);
        } finally {
          reset();
        }
      });
    }
  });

  var suite = Suite(declarer.build(), SuitePlatform(Runtime.vm));
  for (var (index, test) in suite.group.entries.cast<backend.Test>().indexed) {
    var live = test.load(suite);
    var priorReporter = reportTestException;
    reportTestException = (details, _) =>
        failures[jobs[index].slug] ??= details.exceptionAsString();
    try {
      await live.run();
    } finally {
      reportTestException = priorReporter;
    }
  }

  return {'written': written, if (failures.isNotEmpty) 'failures': failures};
}

/// A capture on disk, read when something resolves it and not before.
///
/// The laziness is the point: [StoreShot.set] is the whole set, so an eager
/// provider makes every job read every file — 225 reads for a fifteen-shot set,
/// nearly all of them for pictures no frame paints.
///
/// **Why this is not a `FileImage`.** `FileImage` is lazy already and hangs
/// here, for a reason that is about the test binding rather than about files.
/// An `Image` in the pumped tree resolves its own provider during
/// `pumpWidget`, so the load starts inside `FakeAsync`'s zone — where
/// `scheduleMicrotask` is overridden to a queue that only `flushMicrotasks`
/// drains, and only `pump` calls that. `FileImage`'s load awaits
/// `File.length()`, whose completion arrives on the real event loop but whose
/// continuation is scheduled as one of those queued microtasks. `runAsync`
/// runs the real loop and never drains that queue, so the load parks mid-read
/// and the [precacheImage] below — which finds the very same parked completer
/// in the image cache — waits on it forever. Measured: the future advances one
/// step per alternating `pump`/`runAsync` pair, five pairs to finish one PNG.
///
/// Reading with `readAsBytesSync` removes every `dart:io` await, leaving only
/// the engine's own decode — which completes through a synchronous completer,
/// resuming in place rather than through the queue. That is the shape
/// `MemoryImage` has, and the reason it worked.
///
/// Keyed by path **and by what was at it**, so two jobs painting the same
/// neighbour share one decode through the image cache — where the eager
/// `MemoryImage`s, compared by byte identity, could only ever share within a
/// job — and a rerun over a rewritten capture does not.
///
/// The second half of that key is not optional, and the reason is the guest.
/// `StoreFrameRunner` keeps it warm on purpose, `flutter_test` never clears
/// `PaintingBinding.imageCache`, and the capture path an export composes from
/// is fully deterministic — same output, same store, same class, same locale,
/// same numbered name, run after run. A key of path alone therefore *hits* on
/// the previous export's decode: the app changes, the capture on disk changes,
/// and the composition ships the pixels from last time. Measured before this
/// stamp existed, driving two composes over one path whose bytes were replaced
/// in between: byte-identical output. The same key also cached the *failure* of
/// an unreadable capture, so fixing one and exporting again kept reporting it
/// broken until the studio was restarted.
///
/// A stat rather than a hash of the bytes, because the bytes are what this
/// exists not to read. Resolution is the filesystem's — measured here at
/// microseconds, and an export is tens of seconds of running an app, so two
/// captures at one path never share a stamp. A missing file stats to
/// `notFound`, size -1 and epoch, which is a stable key that fails at read time
/// like any other unreadable capture rather than throwing here.
///
/// Two tests hold this in place: `test/store/shot_image_test.dart` for the
/// load's shape, and `test/store/compose_freshness_test.dart` for the stamp —
/// which composes twice over one path and fails if the second one is the
/// first one again.
class _ShotImage extends ImageProvider<_ShotImage> {
  _ShotImage(this.path) : _stamp = _stampOf(path);

  final String path;

  /// What was at [path] when the job was built — mtime and length.
  final String _stamp;

  static String _stampOf(String path) {
    var stat = File(path).statSync();
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  }

  @override
  Future<_ShotImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ShotImage>(this);

  @override
  ImageStreamCompleter loadImage(_ShotImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: path,
        informationCollector: () => [ErrorDescription('Path: $path')],
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(File(path).readAsBytesSync()),
  );

  @override
  bool operator ==(Object other) =>
      other is _ShotImage && other.path == path && other._stamp == _stamp;

  @override
  int get hashCode => Object.hash(path, _stamp);

  @override
  String toString() => 'StoreShotImage("$path")';
}

/// `fr-CA` into a `Locale`, because that is the spelling a declaration uses and
/// `Locale` wants the halves apart.
Locale _localeOf(String tag) {
  var parts = tag.split(RegExp('[-_]'));
  return parts.length > 1 ? Locale(parts.first, parts[1]) : Locale(parts.first);
}

/// The composed frame, as a PNG at the canvas's exact pixel size.
Future<void> _capture(WidgetTester tester, String out) async {
  // A real-async turn, like every other capture in this codebase: `toImage`
  // completes on the real event loop, which fake time never runs.
  await tester.runAsync(() async {
    var view = tester.binding.renderViews.single;
    var layer = view.debugLayer! as OffsetLayer;
    var dpr = view.flutterView.devicePixelRatio;
    var image = await layer.toImage(Offset.zero & (view.size * dpr));
    var data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    File(out).parent.createSync(recursive: true);
    File(out).writeAsBytesSync(data.buffer.asUint8List());
  });
}

/// Where the generated entrypoint goes, relative to the package.
const storeFrameEntrypointPath =
    'build/flutterware/store_frames/store_frames.dart';
