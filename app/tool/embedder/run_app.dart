import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/embedder/embedder_build.dart';
import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/guest_vm_service.dart';
import 'package:flutterware_app/src/embedder/protocol.dart';
import 'package:flutterware_app/src/embedder/raw_frame.dart';
import 'package:flutterware_app/src/embedder/resident_compiler.dart';
import 'package:flutterware_app/src/embedder/seed_kernel.dart';
import 'package:flutterware_app/src/embedder/source_invalidator.dart';
import 'package:flutterware_app/src/previews/asset_bundle.dart';
import 'package:flutterware_app/src/utils/run_dir.dart';
import 'package:image/image.dart' as img;
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

/// Runs an app's own `main` in embedded guests, one per person, and times each
/// step — phase 1 of the worlds guest experiment
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`).
///
/// ```sh
/// cd app && fvm dart run tool/embedder/run_app.dart \
///   --package ../fixtures/world_lab/app \
///   --fakes ../fixtures/world_lab/app/guest/fakes.dart \
///   --person Ana --person Leo --shots build/world_shots --hold
/// ```
///
/// **One kernel, every person.** The generated entry reads its knobs from the
/// environment at run time and hands them to `main` by name, so a second
/// person is a second process over the same kernel rather than a second
/// build — the thing Run's wrapper, which writes knob values into the source,
/// cannot do (phase 0, finding 4).
///
/// The entry wraps `main` in Run's own `runGuest`, so a guest carries the same
/// drive, inspection and log extensions as an app Run launched; and it installs
/// the guest keyboard and text input Previews uses, since a guest has no
/// platform to deliver keys. `--fakes` names a file with
/// `installGuestFakes({required Directory home, required answerChannel})`, the
/// project's replacements for its plugins: `home` is that person's own
/// directory, and `answerChannel(name, (call) async => …)` answers a channel a
/// plugin with no platform interface calls directly.
///
/// The engine and the C host are the machine's, not the worktree's — built
/// once per flutterware checkout — so a cold worktree pays for neither, and the
/// report names them apart.
Future<void> main(List<String> args) async {
  var options = _Options.parse(args);
  _clock.start();

  var appRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var package = p.normalize(p.absolute(options.package));
  var cache = FlutterCache.fromRunningSdk();
  var buildDir = options.buildDir ?? p.join(package, 'build', 'world_guest');
  var packageConfig = _packageConfigFor(package);
  var assetsDir = p.join(buildDir, 'assets');

  var engineDir = await _step(
    "engine (the machine's, cached)",
    () => ensureEmbedderEngine(cache),
  );
  var hostPath = await _step(
    "host (the machine's, cached)",
    () => buildHost(
      nativeSourceDir: p.join(appRoot, 'native'),
      nativeBuildDir: p.join(appRoot, 'build', 'embedder', 'native'),
      engineDir: engineDir,
    ),
  );

  _clock.reset();
  stdout.writeln("[world] --- the worktree's work starts here ---");
  await _step(
    'assets, build hooks included',
    () => AssetBundleBuilder(
      cache: cache,
      rootPackageRoot: package,
      packageConfigPath: packageConfig,
    ).build(assetsDir),
  );
  var entry = _writeEntry(buildDir, package, options);
  // `--seeds`: the studio's own machine-level seed of the half of the program
  // no checkout owns — the SDK and the pub cache — found before the compile
  // and left behind after it, exactly as the catalog and the tester do.
  var seeds = SeedStore(
    engineRevision: cache.engineRevision,
    flavor: seedFlavor(
      ResidentCompiler.argumentsFor(trackWidgetCreation: true),
    ),
  );
  var resolution = await loadPackageConfigUri(Uri.file(packageConfig));
  var seed = options.seeds ? seeds.find(resolution) : null;
  if (options.seeds) {
    stdout.writeln(
      '[world] seed: ${seed == null ? 'none on this machine yet' : '${seed.packages.length} packages'}',
    );
  }
  var compiler = await ResidentCompiler.start(
    entrypoint: entry,
    outputDill: p.join(buildDir, 'app.dill'),
    packageConfig: packageConfig,
    cache: cache,
    workingDirectory: package,
    seedDill: options.seed ?? seed?.kernelPath,
  );
  var outcome = await _step('compile', () => compiler.compile());
  if (!outcome.ok) {
    stderr.writeln(outcome.output.join('\n'));
    exit(1);
  }
  File(outcome.dillOutput!).copySync(p.join(assetsDir, 'kernel_blob.bin'));

  var guests = await _step(
    'start ${options.people.length} guest(s), until each has drawn',
    () => Future.wait([
      for (var (person, own) in options.people)
        _Guest.start(
          hostPath: hostPath,
          assetsDir: assetsDir,
          icuData: cache.icuData,
          person: person,
          home: p.join(buildDir, 'people', person),
          // Only knobs somebody named: `main` is called by name, and a name
          // it does not declare fails the call.
          knobs: {...options.knobs, ...own},
          size: options.size,
          insets: options.insets,
          locales: options.locales,
        ),
    ]),
  );
  for (var guest in guests) {
    stdout.writeln(
      '[world] ${guest.person}: drew at ${_seconds(guest.drewAt)}, '
      'pid ${guest.process.pid}, VM service ${await guest.vmService.future}',
    );
  }

  if (options.shots case var shots?) {
    // Long enough for the app's boot work — its plugin check — to land.
    await Future<void>.delayed(const Duration(seconds: 2));
    Directory(shots).createSync(recursive: true);
    for (var guest in guests) {
      var png = p.join(shots, '${guest.person}.png');
      await guest.capturePng(png);
      stdout.writeln('[world] ${guest.person}: $png');
    }
  }
  for (var guest in guests) {
    stdout.writeln('[world] ${guest.person}: ${await guest.memory()}');
  }
  if (options.seeds) {
    // After the world is open, as a studio would do it in the background.
    var wrote = await compiler.writeSeed(
      store: seeds,
      resolution: resolution,
      immutableRoots: [cache.flutterRoot, ...pubCacheRoots()],
      improving: seed,
      log: (line) => stdout.writeln('[world] seed: $line'),
    );
    if (wrote != null) stdout.writeln('[world] seed: wrote $wrote');
  }

  if (options.hold) {
    stdout.writeln(
      '[world] holding; `kill -USR1 $pid` photographs every guest again, '
      '`kill -USR2 $pid` reloads them after an edit, Ctrl-C ends',
    );
    var shot = 0;
    var photographs = ProcessSignal.sigusr1.watch().listen((_) async {
      shot++;
      var dir = options.shots ?? p.join(buildDir, 'shots');
      Directory(dir).createSync(recursive: true);
      for (var guest in guests) {
        var png = p.join(dir, '${guest.person}-$shot.png');
        await guest.capturePng(png);
        stdout.writeln('[world] ${guest.person}: $png');
      }
    });
    // SIGUSR2: an edit. Recompile what changed since the last compile, then
    // reload every guest from the one delta — which is what makes a reload of
    // N people cost one compile.
    var compiledAt = DateTime.now();
    var invalidator = SourceInvalidator();
    var services = <String, GuestVmService>{};
    var reloads = ProcessSignal.sigusr2.watch().listen((_) async {
      var watch = Stopwatch()..start();
      var changed = invalidator.sweep(compiler.sources, compiledAt: compiledAt);
      compiledAt = DateTime.now();
      var delta = await compiler.compile(changed);
      var compiled = watch.elapsed;
      if (!delta.ok) {
        stderr.writeln(delta.output.join('\n'));
        return;
      }
      await Future.wait([
        for (var guest in guests)
          () async {
            var service = services[guest.person] ??=
                await GuestVmService.connect(await guest.vmService.future);
            await service.reload(delta.dillOutput!);
          }(),
      ]);
      stdout.writeln(
        '[world] reload: ${changed.length} changed, compile '
        '${compiled.inMilliseconds} ms, ${guests.length} guest(s) reloaded at '
        '${watch.elapsedMilliseconds} ms',
      );
    });
    await ProcessSignal.sigint.watch().first;
    await photographs.cancel();
    await reloads.cancel();
  }
  for (var guest in guests) {
    await guest.shutdown();
  }
  await compiler.shutdown();
  exit(0);
}

final _clock = Stopwatch();

Future<T> _step<T>(String name, Future<T> Function() body) async {
  var at = _clock.elapsed;
  var result = await body();
  stdout.writeln(
    '[world] ${_seconds(_clock.elapsed).padLeft(7)}  $name '
    '(${_seconds(_clock.elapsed - at)})',
  );
  return result;
}

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';

/// The package config that resolves [package]: its own, or its workspace's.
String _packageConfigFor(String package) {
  for (var dir = package; ; dir = p.dirname(dir)) {
    var candidate = p.join(dir, '.dart_tool', 'package_config.json');
    if (File(candidate).existsSync()) return candidate;
    if (p.dirname(dir) == dir) {
      throw StateError('$package is not resolved; run `flutter pub get`.');
    }
  }
}

String _writeEntry(String buildDir, String package, _Options options) {
  var name = RegExp(
    r'^name:\s*(\S+)',
    multiLine: true,
  ).firstMatch(File(p.join(package, 'pubspec.yaml')).readAsStringSync())!;
  // A `lib/` entry point by its package URI; anything else — a `demo/` or
  // `tool/` entry point, which no package URI reaches — by its file.
  var main = options.entrypoint.startsWith('lib/')
      ? 'package:${name.group(1)}/${options.entrypoint.substring(4)}'
      : '${Uri.file(p.join(package, options.entrypoint))}';
  var fakes = options.fakes == null
      ? null
      : Uri.file(p.normalize(p.absolute(options.fakes!)));
  var entry = File(p.join(buildDir, 'entry.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
// Generated by app/tool/embedder/run_app.dart. Do not edit.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/previews_guest.dart'
    show GuestKeyboard, GuestLogs, GuestTextInput;
import 'package:flutterware/run_guest.dart';
import '$main' as app;
${fakes == null ? '' : "import '$fakes' as fakes;"}

/// The guest's binding. Two things only a binding can do for an app whose
/// `runApp` is its own:
///
/// * **Answer a plugin that has no platform interface.** Such a plugin calls a
///   `MethodChannel` directly, so no Dart fake can take its place — except the
///   messenger every channel sends through. The project's fakes name the
///   channels they answer; every other message goes to the platform as before.
/// * **Give the app a device's safe areas.** They reach a guest as view
///   *insets* — `FlutterWindowMetricsEvent` has no padding field — so they are
///   turned back into padding under the root `View`.
class _GuestBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _AnsweringMessenger(super.createBinaryMessenger());

  @override
  Widget wrapWithDefaultView(Widget rootWidget) =>
      super.wrapWithDefaultView(Builder(builder: (context) {
        var media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.viewInsets,
            viewPadding: media.viewInsets,
            viewInsets: EdgeInsets.zero,
          ),
          child: rootWidget,
        );
      }));
}

final _answers = <String, Future<Object?> Function(MethodCall)>{};

class _AnsweringMessenger implements BinaryMessenger {
  _AnsweringMessenger(this._platform);

  final BinaryMessenger _platform;
  static const _codec = StandardMethodCodec();

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    var answer = _answers[channel];
    if (answer == null || message == null) {
      return _platform.send(channel, message);
    }
    return answer(_codec.decodeMethodCall(message))
        .then(_codec.encodeSuccessEnvelope);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _platform.setMessageHandler(channel, handler);

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) => _platform.handlePlatformMessage(channel, data, callback);
}

// The binding is created before `runGuest` makes its own, and inside the log
// zone `runGuest` would open: `install` does not nest, so `runGuest` runs in
// this same zone, finds the binding, and the zone the binding captured is the
// one `runApp` is called in. Any flutterware with the guest plumbing has this.
void main() => GuestLogs.instance.install<Object?>(() {
  _GuestBinding();
  return runGuest(() {
  ${options.platform == null ? '' : 'debugDefaultTargetPlatformOverride = TargetPlatform.${options.platform};'}
  GuestKeyboard.instance.install();
  GuestTextInput.instance.install();
  ${fakes == null ? '' : "fakes.installGuestFakes(home: Directory(Platform.environment['FW_PERSON_HOME']!), answerChannel: (channel, answer) => _answers[channel] = answer);"}
  var knobs = (jsonDecode(Platform.environment['FW_KNOBS'] ?? '{}') as Map)
      .cast<String, Object?>();
  return Function.apply(app.main, const [], {
    for (var knob in knobs.entries) Symbol(knob.key): knob.value,
  });
  });
});
''');
  return entry.path;
}

class _Guest {
  _Guest(this.person, this.process, this._socket);

  final String person;
  final Process process;
  final Socket _socket;
  final vmService = Completer<String>();
  late Duration drewAt;
  final _captured = <String, Completer<void>>{};

  static Future<_Guest> start({
    required String hostPath,
    required String assetsDir,
    required String icuData,
    required String person,
    required String home,
    required Map<String, Object?> knobs,
    required (int, int, double) size,
    required (double, double, double, double) insets,
    required String locales,
  }) async {
    var dir = Directory(home);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    var socketPath = checkSocketPath(
      p.join(flutterwareRunDir(), 'world-$pid-$person.sock'),
    );
    if (File(socketPath).existsSync()) File(socketPath).deleteSync();
    var server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    var (width, height, ratio) = size;
    var process = await Process.start(
      hostPath,
      [assetsDir, icuData, socketPath, '$width', '$height'],
      environment: {
        'FW_KNOBS': jsonEncode(knobs),
        'FW_PERSON_HOME': home,
        'FW_GUEST_LOCALES': locales,
      },
    );
    // Kept by the guest and closed by [shutdown].
    // ignore: close_sinks
    var socket = await server.first;
    await server.close();
    var guest = _Guest(person, process, socket);
    socket.add(
      encodeMessage(
        ResizeMessage(
          width: width,
          height: height,
          pixelRatio: ratio,
          insetTop: insets.$1 * ratio,
          insetRight: insets.$2 * ratio,
          insetBottom: insets.$3 * ratio,
          insetLeft: insets.$4 * ratio,
        ),
      ),
    );

    var drew = Completer<void>();
    var reader = FrameReader();
    socket.listen((chunk) {
      for (var message in reader.addBytes(chunk)) {
        switch (message) {
          case FrameReadyMessage() when !drew.isCompleted:
            guest.drewAt = _clock.elapsed;
            drew.complete();
          case CapturedMessage(:var path):
            guest._captured.remove(path)?.complete();
          case ErrorMessage(:var message):
            stderr.writeln('[$person] guest error: $message');
          default:
        }
      }
    });
    for (var stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        stdout.writeln('[$person] $line');
        var uri = RegExp(r'(http://127\.0\.0\.1:\S+/)').firstMatch(line);
        if (uri != null && !guest.vmService.isCompleted) {
          guest.vmService.complete(uri.group(1));
        }
      });
    }
    await drew.future.timeout(const Duration(minutes: 1));
    return guest;
  }

  Future<void> capturePng(String png) async {
    var raw = '$png.raw';
    var done = _captured[raw] = Completer<void>();
    _socket.add(encodeMessage(CaptureMessage(raw)));
    await done.future.timeout(const Duration(seconds: 10));
    File(png).writeAsBytesSync(
      img.encodePng(decodeRawFrame(File(raw).readAsBytesSync())),
    );
    File(raw).deleteSync();
  }

  Future<String> memory() async {
    var footprint = await Process.run('footprint', ['${process.pid}']);
    var line = LineSplitter.split('${footprint.stdout}')
        .firstWhere((l) => l.contains('Footprint:'), orElse: () => '?');
    var rss = await Process.run('ps', ['-o', 'rss=', '-p', '${process.pid}']);
    var mb = (int.tryParse('${rss.stdout}'.trim()) ?? 0) ~/ 1024;
    return '${line.trim()}, $mb MB resident';
  }

  Future<void> shutdown() async {
    _socket.add(encodeMessage(const ShutdownMessage()));
    await _socket.flush();
    await _socket.close();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
  }
}

/// A knob's value as `main` declares it: `8090` an int, `true` a bool,
/// anything that is not JSON a string.
Object? _knobValue(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

class _Options {
  _Options({
    required this.package,
    required this.entrypoint,
    required this.fakes,
    required this.people,
    required this.knobs,
    required this.size,
    required this.shots,
    required this.seed,
    required this.seeds,
    required this.hold,
    required this.platform,
    required this.insets,
    required this.buildDir,
    required this.locales,
  });

  factory _Options.parse(List<String> args) {
    String? value(String flag) {
      var at = args.indexOf(flag);
      return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
    }

    List<String> all(String flag) => [
      for (var i = 0; i < args.length - 1; i++)
        if (args[i] == flag) args[i + 1],
    ];
    var size = RegExp(r'^(\d+)x(\d+)@([\d.]+)$')
        .firstMatch(value('--size') ?? '393x852@3')!;
    var ratio = double.parse(size.group(3)!);
    return _Options(
      package: value('--package') ?? (throw ArgumentError('--package')),
      entrypoint: value('--entrypoint') ?? 'lib/main.dart',
      fakes: value('--fakes'),
      // `--person 'Ana;session=abc'`: a name, then that person's own knobs.
      people: [
        for (var spec in all('--person').isEmpty ? ['Guest'] : all('--person'))
          (
            spec.split(';').first,
            {
              for (var knob in spec.split(';').skip(1))
                knob.substring(0, knob.indexOf('=')): _knobValue(
                  knob.substring(knob.indexOf('=') + 1),
                ),
            },
          ),
      ],
      knobs: {
        for (var knob in all('--knob'))
          knob.substring(0, knob.indexOf('=')): _knobValue(
            knob.substring(knob.indexOf('=') + 1),
          ),
      },
      size: (
        (int.parse(size.group(1)!) * ratio).round(),
        (int.parse(size.group(2)!) * ratio).round(),
        ratio,
      ),
      shots: value('--shots'),
      seed: value('--seed'),
      seeds: args.contains('--seeds'),
      hold: args.contains('--hold'),
      platform: value('--platform'),
      locales: value('--locale') ?? 'en-US',
      buildDir: switch (value('--build-dir')) {
        var dir? => p.normalize(p.absolute(dir)),
        null => null,
      },
      insets: switch ((value('--insets') ?? '0,0,0,0')
          .split(',')
          .map(double.parse)
          .toList()) {
        [var top, var right, var bottom, var left] => (
          top,
          right,
          bottom,
          left,
        ),
        _ => throw ArgumentError('--insets top,right,bottom,left'),
      },
    );
  }

  final String package;
  final String entrypoint;
  final String? fakes;
  final List<(String, Map<String, Object?>)> people;
  final Map<String, Object?> knobs;
  final (int, int, double) size;
  final String? shots;
  final String? seed;
  final bool seeds;
  final bool hold;

  /// A `TargetPlatform` name — `iOS` — for the look of a phone the guest is
  /// not: it runs on the Mac, so without this it draws the Mac's.
  final String? platform;

  /// Safe areas in logical pixels, top, right, bottom, left — `59,0,34,0` for
  /// an iPhone 16's status bar and home indicator.
  final (double, double, double, double) insets;

  /// Where the kernel, the assets and each person's home go, when not under
  /// the package's own `build/` — for running a project this must not write
  /// into.
  final String? buildDir;

  /// The device's preferred locales, `en-US,fr-FR` — what the guest tells
  /// the engine at start, and all it will ever say.
  final String locales;
}
