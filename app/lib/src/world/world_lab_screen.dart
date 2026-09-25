import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../embedder/embedded_engine.dart';
import '../embedder/flutter_cache.dart';
import '../embedder/guest_texture.dart';
import '../embedder/input_region.dart';
import '../run/handle.dart';
import '../ui/action_button.dart';
import '../ui/theme.dart';
import 'app_guest.dart';
import 'guest_launcher.dart';
import 'guest_log.dart';
import 'guest_process.dart';
import 'platform/studio_platform.dart';

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
/// agent observes and drives inside it with the same tools as any app — and
/// the pane stands in for its `flutter run` ([GuestLauncher]), so Run's
/// reload and restart reach it too.
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
    this.studioAnswers = false,
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

  /// Candidate 2: the plugins' own Dart halves, their platform answered here
  /// — which is also what lets the pane show what each app posts and opens,
  /// open a link in it, and give it the cursor it asks for. Otherwise the
  /// app's [fakes].
  final bool studioAnswers;

  @override
  State<WorldLabScreen> createState() => _WorldLabScreenState();
}

class _Person {
  _Person(this.name, this.engine, this.platform, this.log, this.knobs);

  final String name;

  /// What their app was last started with.
  Map<String, Object?> knobs;
  final EmbeddedEngine engine;
  final StudioPlatform? platform;
  final GuestLog log;
  final focus = FocusNode();
  RunHandle? handle;
  GuestLauncher? launcher;
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
      studioAnswers: widget.studioAnswers,
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
        var platform = widget.studioAnswers
            ? StudioPlatform(person: name, home: home, package: build.package)
            : null;
        var log = GuestLog(p.join(build.buildDir, 'logs', '$name.log'));
        var engine = EmbeddedEngine(
          appPackageRoot: widget.appRoot,
          flutterSdkRoot: widget.flutterSdkRoot,
          buildGuest: () async => (
            hostPath: hostPath,
            assetsDir: build.assetsDir,
            icuData: cache.icuData,
          ),
          workingDirectory: build.package,
          environment: guestEnvironment(
            home: home.path,
            knobsFile: build.writeKnobs(name, knobs),
            forward: platform != null,
          ),
          platform: platform == null
              ? null
              : (channel, bytes) {
                  // Each channel said once, as the host says the ones it
                  // leaves unanswered: what the app reached for.
                  if (!platform.platform.asked.contains(channel)) {
                    debugPrint('[$name] asks the platform on $channel');
                  }
                  return platform.platform.answer(channel, bytes);
                },
          onOutput: log.line,
          name: 'world-$name',
        );
        platform?.platform.send = engine.sendPlatform;
        _people.add(_Person(name, engine, platform, log, knobs));
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
      log: person.log,
    );
    var launcher = person.launcher = await GuestLauncher.connect(
      await engine.vmServiceUri,
    );
    await launcher.serve(reload: _reloadAll, restart: () => _restart(person));
  }

  /// Recompiles what changed and reloads every person's app from the one
  /// delta — Run's reload, asked of any of them.
  Future<void> _reloadAll() => _serial(_reloadEveryone);

  Future<void> _reloadEveryone() async {
    var watch = Stopwatch()..start();
    var (changed, delta) = await _build!.recompile();
    if (!delta.ok) throw StateError(delta.output.join('\n'));
    await Future.wait([
      for (var person in _people)
        if (person.launcher case var launcher?)
          launcher.reloadFrom(delta.dillOutput!),
    ]);
    _say(
      'Reloaded ${_people.length} in ${watch.elapsedMilliseconds} ms, '
      '$changed changed',
    );
  }

  /// Starts [person]'s app again from scratch, with [knobs] when given, the
  /// others untouched — but brought to the same code first, since the whole
  /// program this compiles is what every later delta builds on.
  Future<void> _restart(_Person person, {Map<String, Object?>? knobs}) =>
      _serial(() async {
        var watch = Stopwatch()..start();
        if (knobs != null) {
          _build!.writeKnobs(person.name, knobs);
          person.knobs = knobs;
        }
        await _reloadEveryone();
        var (_, whole) = await _build!.recompileWhole();
        if (!whole.ok) throw StateError(whole.output.join('\n'));
        await person.launcher!.restartFrom(
          whole.dillOutput!,
          assets: _build!.assetsDir,
        );
        _say('Restarted ${person.name} in ${watch.elapsedMilliseconds} ms');
      });

  /// One compile at a time: the compiler is shared, and a delta is only
  /// right for guests that took every delta before it.
  Future<void> _serial(Future<void> Function() edit) {
    var next = _edits.then((_) => edit());
    _edits = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  var _edits = Future<void>.value();

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
      unawaited(person.launcher?.dispose());
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
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _PhonePane(person: person, size: widget.phone),
                          if (person.platform case var platform?) ...[
                            const SizedBox(width: FwSpacing.lg),
                            Padding(
                              padding: const EdgeInsets.only(top: 25),
                              child: _PlatformPanel(
                                person: person.name,
                                platform: platform,
                                knobs: person.knobs,
                                onRestart: (knobs) =>
                                    _restart(person, knobs: knobs),
                                width: 220,
                              ),
                            ),
                          ],
                        ],
                      ),
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
              ),
              // In front, not around: a border in `decoration` pads the child
              // by its width, and the guest — sized to the phone — would be
              // drawn 4px smaller than it is and clicked 2px off.
              foregroundDecoration: BoxDecoration(
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
                (_, var textureId?) => _Cursor(
                  system: person.platform?.system,
                  child: EmbedderInputRegion(
                    engine: engine,
                    focusNode: person.focus,
                    child: GuestTexture(textureId: textureId),
                  ),
                ),
              },
            );
          },
        ),
      ],
    );
  }
}

/// The cursor the guest's app asked for, over the guest — what its
/// `flutter/mousecursor` calls reach when the studio is its platform.
class _Cursor extends StatelessWidget {
  const _Cursor({required this.system, required this.child});

  final GuestSystem? system;
  final Widget child;

  static final _byKind = {
    for (var cursor in [
      SystemMouseCursors.basic,
      SystemMouseCursors.click,
      SystemMouseCursors.text,
      SystemMouseCursors.forbidden,
      SystemMouseCursors.grab,
      SystemMouseCursors.grabbing,
      SystemMouseCursors.precise,
      SystemMouseCursors.move,
      SystemMouseCursors.resizeLeftRight,
      SystemMouseCursors.resizeUpDown,
      SystemMouseCursors.wait,
    ])
      cursor.kind: cursor,
  };

  @override
  Widget build(BuildContext context) {
    var system = this.system;
    if (system == null) return child;
    return StreamBuilder<String>(
      stream: system.cursors,
      initialData: system.cursor,
      builder: (context, kind) => MouseRegion(
        cursor: _byKind[kind.data] ?? SystemMouseCursors.basic,
        child: child,
      ),
    );
  }
}

/// What one person's app did through the platform the studio stands in for —
/// the notifications it posted, the URLs it opened — and a link to open in
/// it, delivered where the OS would deliver one.
class _PlatformPanel extends StatefulWidget {
  const _PlatformPanel({
    required this.person,
    required this.platform,
    required this.knobs,
    required this.onRestart,
    required this.width,
  });

  final String person;
  final StudioPlatform platform;

  /// What the app was started with, and a restart with other values — what a
  /// world restart does to every person.
  final Map<String, Object?> knobs;
  final Future<void> Function(Map<String, Object?> knobs) onRestart;
  final double width;

  @override
  State<_PlatformPanel> createState() => _PlatformPanelState();
}

class _PlatformPanelState extends State<_PlatformPanel> {
  final _link = TextEditingController();
  late final _knobs = TextEditingController(
    text: [
      for (var MapEntry(:key, :value) in widget.knobs.entries)
        '$key=${value is String ? value : jsonEncode(value)}',
    ].join(';'),
  );
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _said;
  var _background = false;

  @override
  void initState() {
    super.initState();
    var platform = widget.platform;
    _subscriptions
      ..add(platform.notifications.shows.listen((_) => setState(() {})))
      ..add(platform.urls.opens.listen((_) => setState(() {})));
  }

  @override
  void dispose() {
    for (var subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _link.dispose();
    _knobs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var platform = widget.platform;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: FwSpacing.md),
          Text('Notifications', style: context.type.sectionLabel),
          if (platform.notifications.shown.isEmpty)
            Text('None posted', style: context.type.bodyMuted),
          for (var notification in platform.notifications.shown)
            Row(
              children: [
                Expanded(
                  child: Text('$notification', style: context.type.body),
                ),
                FwActionButton(
                  label: 'Tap',
                  onPressed: () async =>
                      platform.notifications.tap(notification),
                ),
              ],
            ),
          const SizedBox(height: FwSpacing.md),
          Text('Opened', style: context.type.sectionLabel),
          Text(
            platform.urls.opened.isEmpty
                ? 'Nothing'
                : platform.urls.opened.join('\n'),
            style: platform.urls.opened.isEmpty
                ? context.type.bodyMuted
                : context.type.body,
          ),
          const SizedBox(height: FwSpacing.md),
          Text('Open a link', style: context.type.sectionLabel),
          const SizedBox(height: FwSpacing.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: _link),
              const SizedBox(height: FwSpacing.sm),
              FwActionButton(
                label: "Open in ${widget.person}'s app",
                onPressed: () async {
                  var opened = platform.links.open(_link.text);
                  setState(
                    () => _said = opened ? null : 'The app is not listening',
                  );
                },
              ),
            ],
          ),
          if (_said case var said?) Text(said, style: context.type.bodyMuted),
          const SizedBox(height: FwSpacing.md),
          Text('App', style: context.type.sectionLabel),
          const SizedBox(height: FwSpacing.xs),
          // What a phone does to an app it no longer shows, and what the
          // canvas will do to a person drawn as a card: the framework stops
          // asking for frames.
          FwActionButton(
            label: _background
                ? 'Bring to the front'
                : 'Send to the background',
            onPressed: () async {
              setState(() => _background = !_background);
              platform.system.lifecycle(_background ? 'paused' : 'resumed');
            },
          ),
          const SizedBox(height: FwSpacing.sm),
          TextField(controller: _knobs, style: context.type.mono),
          const SizedBox(height: FwSpacing.sm),
          FwActionButton(
            label: 'Restart with these knobs',
            onPressed: () => widget.onRestart(parseKnobs(_knobs.text)),
          ),
        ],
      ),
    );
  }
}
