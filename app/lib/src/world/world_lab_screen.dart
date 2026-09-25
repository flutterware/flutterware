import 'dart:async';
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
  _Person(this.name, this.engine, this.platform);

  final String name;
  final EmbeddedEngine engine;
  final StudioPlatform? platform;
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
            knobs: knobs,
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
          name: 'world-$name',
        );
        platform?.platform.send = engine.sendPlatform;
        _people.add(_Person(name, engine, platform));
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
    required this.width,
  });

  final String person;
  final StudioPlatform platform;
  final double width;

  @override
  State<_PlatformPanel> createState() => _PlatformPanelState();
}

class _PlatformPanelState extends State<_PlatformPanel> {
  final _link = TextEditingController();
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _said;

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
        ],
      ),
    );
  }
}
