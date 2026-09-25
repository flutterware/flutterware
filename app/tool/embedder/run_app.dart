import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware_app/src/embedder/flutter_cache.dart';
import 'package:flutterware_app/src/embedder/guest_vm_service.dart';
import 'package:flutterware_app/src/world/app_guest.dart';
import 'package:flutterware_app/src/world/guest_process.dart';
import 'package:path/path.dart' as p;

/// Runs an app's own `main` in embedded guests, one per person, and times each
/// step — the worlds guest experiment's harness
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`).
///
/// ```sh
/// cd app && fvm dart run tool/embedder/run_app.dart \
///   --package ../fixtures/world_lab/app \
///   --fakes ../fixtures/world_lab/app/guest/fakes.dart \
///   --person 'Ana;person=Ana' --person 'Leo;person=Leo' \
///   --platform iOS --insets 59,0,34,0 --shots build/world_shots --hold
/// ```
///
/// The build is [AppGuestBuild] and each guest a [GuestProcess]; this file is
/// the command line around them. `--hold` keeps the guests up and announces
/// each to Run as the device `studio-<person>`, so `act` and `observe` reach
/// inside it; `kill -USR1` photographs every guest, `kill -USR2` recompiles
/// what changed and hot-reloads every guest from the one delta.
///
/// The engine and the C host are the machine's, not the worktree's — built
/// once per flutterware checkout — so a cold worktree pays for neither, and the
/// report names them apart.
Future<void> main(List<String> args) async {
  var options = _Options.parse(args);
  _clock.start();

  var appRoot = p.dirname(p.dirname(p.dirname(p.fromUri(Platform.script))));
  var cache = FlutterCache.fromRunningSdk();
  var build = AppGuestBuild(
    package: options.package,
    cache: cache,
    entrypoint: options.entrypoint,
    fakes: options.fakes,
    platform: options.platform,
    buildDir: options.buildDir,
    seeds: options.seeds,
    seedDill: options.seed,
  );

  var hostPath = await _step(
    "engine and host (the machine's, cached)",
    () => ensureGuestHost(cache, appRoot),
  );

  _clock.reset();
  stdout.writeln("[world] --- the worktree's work starts here ---");
  await _step('assets, build hooks included', build.assets);
  var outcome = await _step('compile', build.compile);
  if (options.seeds) {
    var seed = build.seed;
    stdout.writeln(
      '[world] seed: ${seed == null ? 'none on this machine yet' : '${seed.packages.length} packages'}',
    );
  }
  if (!outcome.ok) {
    stderr.writeln(outcome.output.join('\n'));
    exit(1);
  }

  var guests = await _step(
    'start ${options.people.length} guest(s), until each has drawn',
    () => Future.wait([
      for (var (person, own) in options.people)
        GuestProcess.start(
          build: build,
          hostPath: hostPath,
          person: person,
          knobs: {...options.knobs, ...own},
          size: options.size,
          insets: options.insets,
          locales: options.locales,
        ).then((guest) {
          guest.output.listen((line) => stdout.writeln('[$person] $line'));
          return guest;
        }),
    ]),
  );
  var opened = DateTime.now().subtract(_clock.elapsed);
  for (var guest in guests) {
    stdout.writeln(
      '[world] ${guest.person}: drew at '
      '${_seconds(guest.drewAt.difference(opened))}, '
      'pid ${guest.process.pid}, VM service ${await guest.vmService.future}',
    );
  }

  if (options.shots case var shots?) {
    // Long enough for the app's boot work to land.
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
    var wrote = await build.writeSeed(
      log: (line) => stdout.writeln('[world] seed: $line'),
    );
    if (wrote != null) stdout.writeln('[world] seed: wrote $wrote');
  }

  if (options.hold) {
    for (var guest in guests) {
      var handle = await guest.announce(
        packageRoot: build.package,
        entrypoint: options.entrypoint,
      );
      stdout.writeln(
        '[world] ${guest.person}: announced to Run as device '
        '`${handle.device}`',
      );
    }
    stdout.writeln(
      '[world] holding; `kill -USR1 $pid` photographs every guest again, '
      '`kill -USR2 $pid` reloads them after an edit, Ctrl-C ends',
    );
    var shot = 0;
    var photographs = ProcessSignal.sigusr1.watch().listen((_) async {
      shot++;
      var dir = options.shots ?? p.join(build.buildDir, 'shots');
      Directory(dir).createSync(recursive: true);
      for (var guest in guests) {
        var png = p.join(dir, '${guest.person}-$shot.png');
        await guest.capturePng(png);
        stdout.writeln('[world] ${guest.person}: $png');
      }
    });
    // An edit: recompile what changed since the last compile, then reload
    // every guest from the one delta — which is what makes a reload of N
    // people cost one compile.
    var services = <String, GuestVmService>{};
    var reloads = ProcessSignal.sigusr2.watch().listen((_) async {
      var watch = Stopwatch()..start();
      var (changed, delta) = await build.recompile();
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
        '[world] reload: $changed changed, compile '
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
  await build.dispose();
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
