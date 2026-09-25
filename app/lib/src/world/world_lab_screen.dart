import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../embedder/embedded_engine.dart';
import '../embedder/flutter_cache.dart';
import '../embedder/guest_texture.dart';
import '../embedder/input_region.dart';
import '../run/handle.dart';
import '../ui/theme.dart';
import 'app_guest.dart';
import 'guest_process.dart';

/// A world's people side by side, each an app in an embedded guest the studio
/// shows live and hands its mouse and keyboard to — phase 2 of the guest
/// experiment, "can a human use it"
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`).
///
/// A lab rather than the canvas the design draws: one row of phones, no
/// zoom, no server panels. What it has to answer is whether typing, pasting,
/// selecting, scrolling and shortcuts reach the right app, and each phone
/// takes the keyboard when it is clicked, as a window would.
///
/// Every guest is announced to Run as the device `studio-<person>`, so the
/// agent observes and drives inside it with the same tools as any app.
class WorldLabScreen extends StatefulWidget {
  const WorldLabScreen({
    super.key,
    required this.appRoot,
    required this.flutterSdkRoot,
    required this.package,
    required this.people,
    this.entrypoint = 'lib/main.dart',
    this.fakes,
    this.platform,
    this.phone = const Size(393, 852),
    this.safeArea = const EdgeInsets.only(top: 59, bottom: 34),
  });

  /// The `flutterware_app` package root — where the guest's C host is built.
  final String appRoot;
  final String flutterSdkRoot;

  /// The app's package, its entry point, and its guest fakes.
  final String package;
  final String entrypoint;
  final String? fakes;

  /// Each person's name and the knobs their app is started with.
  final List<(String, Map<String, Object?>)> people;

  /// A `TargetPlatform` name for the phones' look, `iOS`.
  final String? platform;

  /// The phone, in logical pixels, and its safe areas.
  final Size phone;
  final EdgeInsets safeArea;

  @override
  State<WorldLabScreen> createState() => _WorldLabScreenState();
}

class _Person {
  _Person(this.name, this.engine);

  final String name;
  final EmbeddedEngine engine;
  final focus = FocusNode();
  RunHandle? handle;
}

class _WorldLabScreenState extends State<WorldLabScreen> {
  final _people = <_Person>[];
  AppGuestBuild? _build;
  String _status = 'Building';
  String? _error;
  final _clock = Stopwatch();

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    _clock.start();
    var cache = FlutterCache(p.join(widget.flutterSdkRoot, 'bin', 'cache'));
    var build = _build = AppGuestBuild(
      package: widget.package,
      cache: cache,
      entrypoint: widget.entrypoint,
      fakes: widget.fakes,
      platform: widget.platform,
    );
    try {
      _say('Preparing the guest host');
      var hostPath = await ensureGuestHost(cache, widget.appRoot);
      _say('Building assets');
      await build.assets();
      _say('Compiling');
      var outcome = await build.compile();
      if (!outcome.ok) throw StateError(outcome.output.join('\n'));
      for (var (name, knobs) in widget.people) {
        var home = Directory(build.homeOf(name));
        if (home.existsSync()) home.deleteSync(recursive: true);
        home.createSync(recursive: true);
        _people.add(
          _Person(
            name,
            EmbeddedEngine(
              appPackageRoot: widget.appRoot,
              flutterSdkRoot: widget.flutterSdkRoot,
              buildGuest: () async => (
                hostPath: hostPath,
                assetsDir: build.assetsDir,
                icuData: cache.icuData,
              ),
              workingDirectory: build.package,
              environment: guestEnvironment(home: home.path, knobs: knobs),
              name: 'world-$name',
            ),
          ),
        );
      }
      _say('Starting ${_people.length} guests');
      if (!mounted) return;
      var dpr = MediaQuery.devicePixelRatioOf(context);
      await Future.wait([for (var person in _people) _start(person, dpr)]);
      _say(
        'Open in ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _start(_Person person, double dpr) async {
    var engine = person.engine;
    var width = (widget.phone.width * dpr).round();
    var height = (widget.phone.height * dpr).round();
    await engine.start(width: width, height: height);
    // Not before the guest has announced its surfaces: until then the engine
    // drops what it is asked to send, and the guest would keep the ratio 1 it
    // started with — a phone twice its size, with no safe areas, that every
    // click lands on at double the coordinates.
    await _running(engine);
    engine.resize(width, height, dpr, insets: widget.safeArea * dpr);
    var pid = engine.guestPid;
    if (pid == null) return;
    person.handle = await announceGuest(
      person: person.name,
      pid: pid,
      vmService: await engine.vmServiceUri,
      packageRoot: _build!.package,
      entrypoint: widget.entrypoint,
    );
  }

  Future<void> _running(EmbeddedEngine engine) {
    if (engine.phase != EmbeddedEnginePhase.building) return Future.value();
    var done = Completer<void>();
    void check() {
      if (engine.phase == EmbeddedEnginePhase.building) return;
      engine.removeListener(check);
      done.complete();
    }

    engine.addListener(check);
    return done.future;
  }

  void _say(String status) {
    if (mounted) setState(() => _status = status);
  }

  @override
  void dispose() {
    for (var person in _people) {
      person.handle?.delete();
      person.engine.dispose();
      person.focus.dispose();
    }
    unawaited(_build?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(FwSpacing.lg),
            child: Text(
              _error ?? 'World lab · $_status',
              style: _error == null
                  ? context.type.heading
                  : context.type.body.copyWith(color: context.colors.red),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: FwSpacing.lg),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var person in _people)
                    Padding(
                      padding: const EdgeInsets.only(right: FwSpacing.xl),
                      child: _PhonePane(person: person, size: widget.phone),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhonePane extends StatelessWidget {
  const _PhonePane({required this.person, required this.size});

  final _Person person;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: person.focus,
          builder: (context, _) => Text(
            person.focus.hasFocus
                ? '${person.name} · has the keyboard'
                : person.name,
            style: person.focus.hasFocus
                ? context.type.bodyStrong.copyWith(color: context.colors.accent)
                : context.type.bodyStrong,
          ),
        ),
        const SizedBox(height: FwSpacing.sm),
        ListenableBuilder(
          listenable: Listenable.merge([person.focus, person.engine]),
          builder: (context, _) {
            var engine = person.engine;
            return Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: context.colors.panel,
                borderRadius: BorderRadius.circular(context.radii.radiusLarge),
                border: Border.all(
                  color: person.focus.hasFocus
                      ? context.colors.accent
                      : context.colors.line,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: switch ((engine.phase, engine.textureId)) {
                (EmbeddedEnginePhase.error, _) => Padding(
                  padding: const EdgeInsets.all(FwSpacing.lg),
                  child: Text(
                    '${engine.errorMessage}',
                    style: context.type.body.copyWith(
                      color: context.colors.red,
                    ),
                  ),
                ),
                (_, null) => Center(
                  child: Text('Starting', style: context.type.bodyMuted),
                ),
                (_, var textureId?) => EmbedderInputRegion(
                  engine: engine,
                  focusNode: person.focus,
                  child: GuestTexture(textureId: textureId),
                ),
              },
            );
          },
        ),
      ],
    );
  }
}
