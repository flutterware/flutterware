import 'dart:async';
import 'dart:io';

import 'package:flutterware/plugins.dart';
import 'package:flutterware/scenarios_report.dart';
import 'package:flutterware/store_report.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../scenarios/axes.dart';
import '../../scenarios/opaque_png.dart';
import '../../scenarios/runner.dart';
import '../../session/job.dart';
import '../../store/frame_runner.dart';
import '../../store/tree.dart';
import '../plugin_core.dart';
import '../plugin_host.dart';
import 'store_results.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const storePluginId = 'flutterware.store';

const _pluginDescription =
    'The screenshots a store listing is uploaded from: the named shots of a '
    "package's scenarios, at the sizes each store publishes.";

/// Store screenshots.
///
/// The plugin has no validator and must not grow one. A [Listing] declares
/// which store it is and the store's sizes arrive with it, so a set a store
/// would refuse cannot be declared — see `lib/src/plugins/store.dart` and
/// `docs/superpowers/specs/2026-08-26-store-screenshots-design.md`.
///
/// Holds to the two rules every core holds to: the constructor allocates
/// nothing, and [report] only formats what a previous call caused to load.
class StoreCore extends PluginCore {
  StoreCore(super.host, {StoreSource? source})
    : source = source ?? const LiveStoreSource();

  /// Where the pubspec, the export root and the manifest are read from — the
  /// package's directory unless a recording is standing in for one.
  final StoreSource source;

  /// Declared apps, filtered to those whose package the workspace knows
  /// about, so a typo cannot make the plugin run in a directory that is not
  /// there.
  late final List<StoreShotsApp> apps = [
    for (var entry in host.config['apps'] as List? ?? const [])
      if (entry is Map) StoreShotsApp.fromJson(entry.cast<String, Object?>()),
  ].where((app) => host.workspace.exists(app.path)).toList();

  /// What an app is called — in the rail, in `--app`, and as the directory its
  /// tree lands in.
  ///
  /// The declaration when it says, and otherwise the package's own pubspec
  /// name, which is right for the ordinary project shipping one app and is a
  /// real name rather than an invented one. `Pkg.name` is the last resort: for
  /// a single-package project it is `.`, which is not a directory anybody
  /// wants to see.
  String nameOf(StoreShotsApp app) =>
      app.name ??
      _names.putIfAbsent(app.path, () {
        var raw = _pubspecOf(app)?['name'];
        var name = raw == null ? '' : '$raw';
        return name.isEmpty ? _fallbackName(app) : name;
      });

  static String _fallbackName(StoreShotsApp app) =>
      app.pkg.name == '.' ? 'app' : app.pkg.name;

  final _names = <String, String>{};

  Map? _pubspecOf(StoreShotsApp app) => source.pubspecOf(_rootOf(app));

  /// One runner per package, and **on a build directory of its own**.
  ///
  /// Not the scenarios panel's warm runner, and not its build directory: two
  /// `TesterHost`s sharing one tear each other's dill, which is the bug the
  /// comparison lane already paid for. A store export is deliberate and
  /// occasional, so a compile of its own is the right side of that trade.
  final _runners = <String, ScenarioRunner>{};

  static const _buildDirectory = 'build/flutterware/store_harness';

  /// One runner per **app**, and a build directory each.
  ///
  /// Two apps on one package are two scenario files and therefore two dills,
  /// so sharing a directory between them is the tear the comparison lane
  /// already paid for once. They are cached and long-lived, so it would not
  /// even take two exports at once.
  ScenarioRunner _runnerFor(StoreShotsApp app) => _runners.putIfAbsent(
    nameOf(app),
    () => ScenarioRunner(
      packageRoot: _rootOf(app),
      directory: p.dirname(app.file ?? 'test'),
      flutterSdkRoot: host.workspace.flutterSdk.root,
      buildDirectory: p.join(_buildDirectory, nameOf(app)),
      projectClock: host.projectClock,
      projectNetwork: host.projectNetwork,
    ),
  );

  String _rootOf(StoreShotsApp app) =>
      host.workspace.packageFor(app.path).directory.path;

  /// Where an app's tree goes. Package-relative unless the declaration made it
  /// absolute.
  ///
  /// **The app's name is always the last segment**, including for a project
  /// that declares one app. A tree whose depth depends on how many things are
  /// in it is a tree every consumer has to branch on, and the replace rule
  /// would need two spellings of itself. It is why `--output` is a *root* and
  /// not a destination: two apps redirected to one directory would otherwise
  /// overwrite each other, which two packages already could.
  String outputOf(StoreShotsApp app) => p.join(rootOf(app), nameOf(app));

  /// The root an app's tree sits under — what `output:` names, and what
  /// `--output` replaces.
  String rootOf(StoreShotsApp app) => switch (app.output) {
    var given? when given.isNotEmpty =>
      p.isAbsolute(given) ? given : p.join(_rootOf(app), given),
    _ => source.defaultRootIn(_rootOf(app)),
  };

  /// What the last export left, per package — the panel's whole data source.
  ///
  /// Cached against the file's **mtime**, not against this process's own
  /// writes. The panel is not the only thing that exports: `fw run store
  /// export` in a terminal beside the open studio is the ordinary case, and a
  /// cache keyed on our own actions would leave that panel showing yesterday's
  /// listing with no way to tell. A `stat` per rebuild is microseconds; a
  /// silently stale panel is the bug class this repo has paid for more than
  /// once.
  StoreShotsReport manifestOf(StoreShotsApp app) {
    var output = outputOf(app);
    if (source.manifestOf(output) case var manifest?) return manifest;
    // A source that has yet to read it — a recording fetched from a server —
    // answers null: start the read once, and say so when it lands. The
    // package's own directory never answers null.
    _reads.putIfAbsent(
      output,
      () => source.readManifest(output).then((_) => notifyChanged()),
    );
    return const StoreShotsReport();
  }

  final _reads = <String, Future<void>>{};

  /// The name and one line the stage puts beside a shot.
  ///
  /// The package's own pubspec, not a new declaration. A listing's real name
  /// and subtitle live in a store console and are not ours to hold — what the
  /// stage needs is something true and roughly the right length, so a
  /// screenshot is judged beside a name rather than beside a placeholder.
  ///
  /// Read here rather than in the panel because a `build` may not touch the
  /// filesystem, and cached because a name does not change under a running
  /// studio in any way worth a read per frame.
  ({String name, String subtitle}) identityOf(StoreShotsApp app) {
    if (_identities[nameOf(app)] case var known?) return known;
    var yaml = _pubspecOf(app);
    // Not cached: a source that has yet to read the pubspec answers null now
    // and the real thing once the manifest read beside it lands.
    if (yaml == null) return (name: nameOf(app), subtitle: '');
    var raw = '${yaml['name'] ?? nameOf(app)}'.replaceAll('_', ' ');
    return _identities[nameOf(app)] = (
      name: raw.isEmpty ? nameOf(app) : raw[0].toUpperCase() + raw.substring(1),
      subtitle: '${yaml['description'] ?? ''}',
    );
  }

  final _identities = <String, ({String name, String subtitle})>{};

  /// What the export running right now is doing, or null when none is.
  ///
  /// Read by the panel for its bar, and by [report] — which is what makes the
  /// same narration reach `fw run` and an MCP client, since both follow a
  /// plugin's status line. One field, three audiences.
  StoreProgress? get progress => _progress;
  StoreProgress? _progress;

  void _narrate(StoreProgress? progress) {
    _progress = progress;
    notifyChanged();
  }

  @override
  PluginReport get report => PluginReport(
    id: id,
    label: label,
    description: _pluginDescription,
    actions: _actions,
    status: _progress == null ? Status.none : Status.info(_progress!.line),
    view: PluginView([
      for (var app in apps)
        ViewSection(nameOf(app), [
          for (var listing in app.listings)
            ViewItems([
              for (var target in listing.targets)
                for (var locale in listing.locales.values)
                  ViewItem(
                    '${listing.storeLabel} · ${target.label}',
                    detail:
                        '$locale · ${target.canvas.label}'
                        '${target.needsComposition ? ' · needs a frame' : ''}',
                    tone: target.needsComposition ? Tone.info : Tone.neutral,
                  ),
            ]),
        ]),
    ]),
  );

  List<PluginAction> get _actions => [
    PluginAction(
      'export',
      'Export',
      returns: StoreExportResult,
      description:
          'Writes the screenshots every declared listing needs, at the size '
          'each store publishes, into a tree an upload tool reads. **Takes no '
          'arguments**: everything it needs is declared in '
          '`tool/flutterware.dart`. Always runs the app — there is no way to '
          'reuse what is on disk, because an export is a release artifact. '
          "Where a frame composed a set, the app's own pixels are kept "
          'beside the listing under `unframed/`.',
      parameters: _narrowing,
    ),
    PluginAction(
      'open',
      'Reveal',
      returns: StoreOpenResult,
      description:
          'Opens the exported tree in the desktop file manager. Refuses when '
          'nothing has been exported yet, rather than opening an empty '
          'directory that looks like a failed export.',
      parameters: [
        _app,
        const ActionParameter(
          'output',
          'Output',
          kind: ActionParameterKind.string,
          required: false,
          description: 'Open this directory instead of the declared output',
        ),
      ],
    ),
  ];

  /// The arguments both actions take, and every one of them *narrows* what the
  /// declaration says. None of them adds to it: the listings, the locales and
  /// the source scenarios live in `tool/flutterware.dart`, and an invocation
  /// that restated them would be one more place for them to drift.
  ///
  /// [_output] is the exception that proves it: it redirects the deliverable
  /// without changing a single thing about what the deliverable *is*.
  List<ActionParameter> get _narrowing => [
    _app,
    const ActionParameter(
      'listing',
      'Listing',
      kind: ActionParameterKind.choice,
      required: false,
      description: 'Only this store',
      options: [ActionOption('app-store'), ActionOption('play')],
    ),
    const ActionParameter(
      'locale',
      'Locale',
      kind: ActionParameterKind.string,
      required: false,
      description:
          "Only this locale — the **app's** tag as the declaration spells "
          'it (`fr`), not the store slot it maps to (`fr-FR`)',
    ),
    ActionParameter(
      'class',
      'Display class',
      kind: ActionParameterKind.choice,
      required: false,
      description: 'Only this display class',
      options: [for (var id in _declaredClasses) ActionOption(id)],
    ),
    const ActionParameter(
      'shot',
      'Shot',
      kind: ActionParameterKind.string,
      required: false,
      description:
          'Only this shot, by position (`02`) or by name (`order-placed`). '
          'Narrows what is **written**, not what is run: a scenario produces '
          'its shots together or not at all.',
    ),
    _output,
    const ActionParameter(
      'open',
      'Reveal when done',
      kind: ActionParameterKind.boolean,
      required: false,
      description: 'Open the tree in the file manager afterwards',
    ),
  ];

  /// Every display class any declaration mentions, so the choice offers what
  /// this project actually has rather than the whole of both stores.
  List<String> get _declaredClasses => {
    for (var app in apps)
      for (var listing in app.listings)
        for (var target in listing.targets) target.id,
  }.toList()..sort();

  static const _output = ActionParameter(
    'output',
    'Output',
    kind: ActionParameterKind.string,
    required: false,
    description:
        'Write the tree here instead of where the declaration says. Only the '
        'tree an uploader reads moves: `unframed/` and the manifest stay under '
        'the declared output, since a redirect may point at a directory of '
        "somebody else's metadata.",
  );

  ActionParameter get _app => ActionParameter(
    'app',
    'App',
    kind: ActionParameterKind.choice,
    required: false,
    description: 'Which declared app; all of them when omitted',
    options: [for (var app in apps) ActionOption(nameOf(app))],
  );

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async => switch (actionId) {
    'export' => _export(arguments),
    'open' => _open(arguments),
    _ => super.invoke(actionId, arguments: arguments),
  };

  /// The export.
  ///
  /// **Always runs the app**, and there is no way to ask it not to. There was
  /// once — a `frame` action that recomposed from kept captures — and it is
  /// gone for two reasons. A frame is authored against `previews`, which
  /// renders one composition in about a second where this renders a whole
  /// listing in seventeen; and an export is a release artifact, where reusing
  /// what happens to be on disk risks shipping last week's screenshots to save
  /// nine seconds. See decision 13.
  Future<StoreExportResult> _export(Map<String, Object?> arguments) async {
    var onlyListing = arguments['listing'] as String?;
    var onlyLocale = arguments['locale'] as String?;
    var onlyClass = arguments['class'] as String?;
    var onlyShot = arguments['shot'] as String?;
    var redirect = _outputArgument(arguments);
    var chosen = _appsFor(arguments);

    // **An export replaces exactly what it produces**, and the scope of the
    // invocation is the scope of the deletion. Un-narrowed, the whole tree is
    // the statement and the whole tree is emptied — the reason `scenarios
    // shots` empties its own, that last release's screenshot of a screen that
    // no longer exists would ship beside this one. Narrowed to a listing, a
    // locale or a class, one set is the statement and the set's directory is
    // what gets emptied; wiping the root there would delete the App Store half
    // of a listing to rewrite the Play half. Narrowed to a shot, one file is,
    // and nothing is deleted at all.
    var replace = switch ((onlyShot, onlyListing ?? onlyLocale ?? onlyClass)) {
      (String _, _) => _Replace.file,
      (_, String _) => _Replace.set,
      // A redirect never wipes: `--output` can point at a directory of
      // somebody else's metadata, and emptying it to write a listing into it
      // is not the same statement at all.
      _ => redirect == null ? _Replace.tree : _Replace.set,
    };

    var results = <StoreExportApp>[];
    var total = 0;
    for (var app in chosen) {
      var declared = outputOf(app);
      // A redirect names a **root**, exactly as `output:` does, so the app's
      // own segment is still under it. Two apps sent to one directory would
      // otherwise write over each other — which two packages always could.
      var output = redirect == null ? declared : p.join(redirect, nameOf(app));
      // Both stay under the **declared** output even when the deliverable is
      // redirected: `--output` sends the tree an uploader reads somewhere
      // else, and that somewhere else can be a directory of somebody's
      // metadata, which is not ours to leave things in.
      var scratch = p.join(declared, internalDirectory, 'capture');
      var sets = <StoreExportSet>[];
      var manifestFile = File(
        p.join(declared, internalDirectory, StoreShotsReport.fileName),
      );
      try {
        if (replace == _Replace.tree) {
          var root = Directory(output);
          if (root.existsSync()) root.deleteSync(recursive: true);
          root.createSync(recursive: true);
        }
        // **One set at a time, all the way through.** Capturing everything
        // and then composing everything is the same work in the same time,
        // and it is what this did first — but it means nothing on disk is
        // finished until almost all of it is, so a panel watching an export
        // sits blank and then fills in one burst. Interleaved, a set is
        // captured, composed, recorded and visible before the next one
        // starts, which is also what makes an interrupted export leave a
        // truthful manifest rather than a stale one.
        var pending = _requestsFor(
          app,
          listing: onlyListing,
          locale: onlyLocale,
          deviceClass: onlyClass,
        );
        for (var (index, request) in pending.indexed) {
          _narrate(
            StoreProgress(
              done: index,
              total: pending.length,
              app: nameOf(app),
              key: request.key,
              set: request.label,
              phase: 'Running',
            ),
          );
          var captured = await _captureSet(
            app,
            request,
            scratch: p.join(scratch, request.slug),
          );
          if (captured == null) continue;
          _narrate(
            StoreProgress(
              done: index,
              total: pending.length,
              app: nameOf(app),
              key: request.key,
              set: request.label,
              phase: 'Composing',
            ),
          );
          var set = await _render(
            app,
            captured,
            output: output,
            unframedRoot: declared,
            shot: onlyShot,
            replace: replace,
          );
          sets.add(set);
          total += set.images.length;
          // Recorded from the **directory**, not from what this invocation
          // wrote. Under `--shot` those differ: one file is rewritten and the
          // set still holds fifteen, and a manifest saying otherwise would
          // have the panel draw a listing of one screenshot.
          //
          // Merged rather than replaced, and written **per set** — for the
          // reason the on-disk replace is scoped, and so the panel's next
          // rebuild shows this set finished while the rest are still ghosts.
          var merged =
              (StoreShotsReport.readFile(manifestFile) ??
                      const StoreShotsReport())
                  .merge([
                    StoreShotsSet(
                      app: nameOf(app),
                      store: set.store,
                      deviceClass: set.deviceClass,
                      appLocale: request.appLocale,
                      storeLocale: set.locale,
                      output: output,
                      directory: set.directory,
                      images: _imagesOn(
                        app,
                        request.target,
                        root: output,
                        into: set,
                      ),
                      failed: set.failed,
                      framesFailed: set.framesFailed,
                      exportedAt: DateTime.now(),
                    ),
                  ]);
          merged.writeTo(manifestFile);
          _narrate(
            StoreProgress(
              done: index + 1,
              total: pending.length,
              app: nameOf(app),
              key: request.key,
              set: request.label,
              phase: 'Composing',
            ),
          );
        }
        // A narrowing argument that matches nothing is a typo, and writing
        // empty sets for it would report a green export of no screenshots.
        if (onlyShot != null && sets.every((set) => set.images.isEmpty)) {
          throw ArgumentError.value(
            onlyShot,
            'shot',
            'matched nothing in ${sets.length} set(s). A shot is addressed by '
                'position (`02`) or by name (`order-placed`), and matching is '
                'exact.',
          );
        }
        results.add(
          StoreExportApp(app: nameOf(app), output: output, sets: sets),
        );
      } catch (error) {
        results.add(
          StoreExportApp(
            app: nameOf(app),
            output: output,
            sets: sets,
            error: '$error',
          ),
        );
      } finally {
        // The raw RGBA captures are working files: a frame composes over them
        // and the alpha comes off at the end. What survives an export is the
        // deliverable, and — where a frame applied — the flattened originals
        // under `unframed/`, which is an output rather than a cache.
        var dir = Directory(scratch);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    }
    // Cleared however the loop ended, including by throwing: a status line
    // left saying "Composing…" outlives the export that was doing it, and a
    // panel with a bar that never finishes is worse than one with none.
    _narrate(null);
    if (arguments['open'] == true) {
      for (var result in results) {
        if (result.error == null) await _reveal(result.output);
      }
    }
    return StoreExportResult(apps: results, count: total);
  }

  /// `open` — the tree, in the desktop's own file manager.
  Future<StoreOpenResult> _open(Map<String, Object?> arguments) async {
    var redirect = _outputArgument(arguments);
    var opened = <String>[];
    for (var app in _appsFor(arguments)) {
      var output = redirect == null
          ? outputOf(app)
          : p.join(redirect, nameOf(app));
      if (!Directory(output).existsSync()) {
        throw ActionRefusal(
          'nothing exported to "$output" yet. Run `store export` first — '
          'opening a directory that is not there would look like an export '
          'that produced nothing.',
        );
      }
      await _reveal(output);
      opened.add(output);
    }
    return StoreOpenResult(paths: opened);
  }

  /// The desktop's own opener, which is the only part of this that is not
  /// portable. Spawned rather than reached through `url_launcher`, because
  /// this runs under `fw` as well as in the GUI and the CLI has no Flutter.
  Future<void> _reveal(String path) async {
    var (executable, arguments) = switch (Platform.operatingSystem) {
      'macos' => ('open', [path]),
      'windows' => ('explorer', [path]),
      // Freedesktop's, which every Linux desktop implements.
      _ => ('xdg-open', [path]),
    };
    // Exit code deliberately ignored: `explorer` reports 1 on success, and a
    // desktop with no opener installed is not a failed export.
    await Process.run(executable, arguments);
  }

  List<StoreShotsApp> _appsFor(Map<String, Object?> arguments) {
    var requested = arguments['app'] as String?;
    var chosen = [
      for (var app in apps)
        if (requested == null || nameOf(app) == requested) app,
    ];
    if (requested != null && chosen.isEmpty) {
      throw ArgumentError.value(
        requested,
        'app',
        'not declared. Declared: ${apps.map(nameOf).join(', ')}',
      );
    }
    return chosen;
  }

  /// `--output`, resolved against the worktree rather than against the
  /// package: a path typed on a command line means what it means in the shell
  /// that typed it, not in whichever package the export happens to reach.
  String? _outputArgument(Map<String, Object?> arguments) {
    var given = arguments['output'] as String?;
    if (given == null || given.isEmpty) return null;
    return p.isAbsolute(given) ? given : p.join(host.worktree.path, given);
  }

  /// Every (target, locale) the declaration asks for, narrowed by arguments.
  List<_SetRequest> _requestsFor(
    StoreShotsApp app, {
    String? listing,
    String? locale,
    String? deviceClass,
  }) => [
    for (var declared in app.listings)
      if (listing == null || declared.store == listing)
        for (var target in declared.targets)
          if (deviceClass == null || target.id == deviceClass)
            for (var entry in declared.locales.entries)
              if (locale == null || entry.key == locale)
                _SetRequest(
                  target: target,
                  appLocale: entry.key,
                  storeLocale: entry.value,
                ),
  ];

  /// Run the app and keep the named shots, **raw**.
  ///
  /// Raw on purpose. These are *inputs* — a frame composes over them, and the
  /// alpha comes off at the end — so flattening here would apply a lossy step
  /// before the one that needs it.
  ///
  /// Into a scratch the export sweeps afterwards. There is nothing to read
  /// them back with any more, so nothing writes a manifest of them: the set
  /// this returns goes straight into the render that follows it.
  Future<_CapturedSet?> _captureSet(
    StoreShotsApp app,
    _SetRequest request, {
    required String scratch,
  }) async {
    var into = Directory(scratch)..createSync(recursive: true);
    var run = p.join(into.path, '.run');
    {
      var raw = await _runnerFor(app).run(
        outDir: run,
        file: app.file,
        axes: ScenarioAxes(
          device: request.target.device.id,
          language: request.appLocale,
        ),
        unspecifiedDevice: request.target.device.id,
        // The device's own ratio, which is what makes the capture the store's
        // exact pixel size rather than a picture that has to be resampled.
        captureNative: true,
        pixels: ScenarioPixels.named,
      );
      // Decoded with the *published* outcome types rather than the scenarios
      // core's private walk. That walk adds artifact addresses and writes a
      // `run.json`, neither of which a store export wants — but the raw report
      // a runner hands back is already the shape `ScenarioRunOutcome.fromJson`
      // reads, so there is nothing to reimplement and nothing to keep in sync.
      var names = <String>[];
      var overlay = <String, ({String? status, String? nav})>{};
      var failed = 0;
      for (var entry
          in (raw['scenarios']! as List).cast<Map<String, Object?>>()) {
        var outcome = ScenarioRunOutcome.fromJson(entry);
        if (!outcome.ok) failed++;
        for (var step in outcome.steps) {
          // A named step with no picture: a document or a notification beat,
          // which is a step in the flow and not a screenshot of anything.
          if (step.name == null || step.image == null) continue;
          if (app.tag != null && !step.tags.contains(app.tag)) continue;
          var number = (names.length + 1).toString().padLeft(2, '0');
          var name = '$number-${storeSlug(step.name!)}.png';
          // `step.image` is recorded relative to the worktree, which is what
          // keeps a report portable between machines.
          File(p.join(host.worktree.path, step.image!))
              .copySync(p.join(into.path, name));
          names.add(name);
          // Kept beside the name rather than folded into it: `images` is a
          // list of file names in half a dozen places, and the frame is the
          // only reader that wants what the app declared while it was on
          // screen.
          overlay[name] = (
            status: step.statusBrightness,
            nav: step.navBrightness,
          );
        }
      }
      if (Directory(run).existsSync()) {
        Directory(run).deleteSync(recursive: true);
      }
      return _CapturedSet(
        directory: into.path,
        request: request,
        images: names,
        overlay: overlay,
        failed: failed,
      );
    }
  }

  /// The deliverable, and — where a frame applied — the originals beside it.
  ///
  /// Composed where a frame applies, flattened straight through where none
  /// does; see `StoreShotsApp.frame` for which is which. Both ends produce
  /// an opaque PNG, because neither store accepts an alpha channel.
  ///
  /// **A composed set also writes its unframed originals**, under
  /// `unframed/<store>/<class>/<locale>/`. Not a flag and not a declaration:
  /// composing is precisely the case where the app's own pixels are *not* the
  /// deliverable, so it is the only case where keeping them says anything. An
  /// uncomposed set's originals are already the deliverable, and writing them
  /// twice would be two names for one file.
  ///
  /// It is a sibling of the store trees rather than inside them, because
  /// `deliver` and `supply` read `ios/` and `android/` and would happily
  /// upload anything they found there.
  Future<StoreExportSet> _render(
    StoreShotsApp app,
    _CapturedSet captured, {
    required String output,
    required String unframedRoot,
    required _Replace replace,
    String? shot,
  }) async {
    var request = captured.request;
    var directory = storeDirectoryFor(
      app.layout,
      request.target,
      request.storeLocale,
    );
    var into = Directory(p.join(output, directory));
    var unframedInto = Directory(
      p.join(
        unframedRoot,
        unframedDirectory,
        storeDirectoryFor(
          StoreLayout.plain,
          request.target,
          request.storeLocale,
        ),
      ),
    );
    // The set's own scope, emptied — see the rule in `_export`. **Both
    // directories**: `unframed/` is an output of this set like the deliverable
    // is, so a narrowed or redirected export that swept only the deliverable
    // left a renamed shot's original there forever. That is the same defect
    // this rule was written for, recurring in the newer directory.
    //
    // Only the images are swept, not the directory: fastlane's iOS tree shares
    // one directory between two classes, so deleting it would take the other
    // class's set with it.
    if (replace == _Replace.set) {
      for (var sweep in [into, unframedInto]) {
        if (!sweep.existsSync()) continue;
        for (var file in sweep.listSync().whereType<File>()) {
          if (storeOwnsFile(
            // `unframed/` is always the plain layout, whose directories belong
            // to one set — so every PNG in it is this set's.
            sweep == into ? app.layout : StoreLayout.plain,
            request.target,
            p.basename(file.path),
          )) {
            file.deleteSync();
          }
        }
      }
    }
    into.createSync(recursive: true);
    // Whether the deliverable is a *composition* — a ground and a device body
    // — and so whether the app's own pixels are worth keeping beside it. Not
    // whether the set is framed: every set is, because every set wants its
    // status bar. See `defaultStoreFrame`.
    var compose = storeShouldCompose(
      hasFrame: app.frame != null,
      target: request.target,
    );

    var written = <String>[];
    var jobs = <Map<String, Object?>>[];
    var flatten = <(String, String)>[];
    for (var (index, name) in captured.images.indexed) {
      var stem = p.basenameWithoutExtension(name);
      if (shot != null && !storeShotMatches(stem, shot)) continue;
      var out = p.join(
        into.path,
        storeFileNameFor(app.layout, request.target, stem),
      );
      var source = p.join(captured.directory, name);
      if (compose) {
        // The original, kept beside the listing. Named the readable way —
        // `unframed/play/phone/en-US/03-cart.png` — because a person is the
        // only reader it has.
        flatten.add((source, p.join(unframedInto.path, name)));
      }
      {
        jobs.add({
          'image': source,
          // Every image of the set, so a frame can reach a neighbour — see
          // `StoreShot.set`. Paths only: nothing is read until a frame paints
          // it.
          'set': [
            for (var sibling in captured.images)
              p.join(captured.directory, sibling),
          ],
          'out': out,
          'slug': stem.replaceFirst(RegExp(r'^\d+-'), ''),
          'index': index + 1,
          'total': captured.images.length,
          'locale': request.appLocale,
          'device': request.target.device.id,
          'canvasWidth': request.target.canvas.width,
          'canvasHeight': request.target.canvas.height,
          'canvasRatio': request.target.canvas.pixelRatio,
          'statusBrightness': ?captured.overlay[name]?.status,
          'navBrightness': ?captured.overlay[name]?.nav,
        });
      }
      written.add(p.basename(out));
    }
    var uncomposed = <String>{};
    if (jobs.isNotEmpty) {
      if (compose) unframedInto.createSync(recursive: true);
      var composed = await _composerFor(
        app,
      ).compose(jobs, manifestPath: p.join(captured.directory, 'frames.json'));
      // What the composer says it wrote, not what it was asked to write. A job
      // whose capture would not decode composes to nothing — see the harness's
      // precache — and this is the only place that learns it, because the
      // reply was previously discarded and every asked-for file was reported
      // as a screenshot.
      var landed = {
        for (var out in composed['written'] as List? ?? const []) '$out',
      };
      uncomposed = {
        for (var job in jobs)
          if (!landed.contains(job['out'])) p.basename(job['out']! as String),
      };
      // The composer writes what the framework encoded, which is RGBA like
      // every other capture. The alpha comes off here, at the last step, for
      // the same reason it does on the unframed path — in place, so the source
      // and the destination are the same file.
      flatten.addAll([
        for (var job in jobs)
          if (landed.contains(job['out']))
            (job['out']! as String, job['out']! as String),
      ]);
    }
    written.removeWhere(uncomposed.contains);
    await flattenPngFiles(flatten);
    return StoreExportSet(
      store: request.target.store,
      deviceClass: request.target.id,
      locale: request.storeLocale,
      directory: directory,
      width: request.target.canvas.width,
      height: request.target.canvas.height,
      images: written,
      failed: captured.failed,
      framesFailed: uncomposed.length,
    );
  }

  /// What a set holds on disk, right now, in the order a store will show it.
  ///
  /// Read back rather than reported, because the two differ exactly when it
  /// matters: `--shot` rewrites one file of fifteen, and the set is still a set
  /// of fifteen. Sorted by name, which is the numbering, which is the order.
  List<String> _imagesOn(
    StoreShotsApp app,
    StoreTarget target, {
    required String root,
    required StoreExportSet into,
  }) {
    var directory = Directory(p.join(root, into.directory));
    if (!directory.existsSync()) return into.images;
    return [
      for (var file in directory.listSync().whereType<File>())
        if (storeOwnsFile(app.layout, target, p.basename(file.path)))
          p.basename(file.path),
    ]..sort();
  }

  /// The frame composer for a package, warm across calls.
  ///
  /// A package that declares no frame still needs one — every set is framed,
  /// if only to wear its status bar — and it is *generated* rather than
  /// shipped as a file: the harness entrypoint imports a source, so the
  /// default has to be one. `defaultStoreFrame` is the function that decides
  /// per shot whether that means a composition or a pane of glass.
  StoreFrameRunner _composerFor(StoreShotsApp app) =>
      _composers.putIfAbsent(nameOf(app), () {
        var root = _rootOf(app);
        var frame = app.frame;
        if (frame == null) {
          frame = p.join(StoreFrameRunner.buildDirectory, 'default_frame.dart');
          var file = File(p.join(root, frame))
            ..parent.createSync(recursive: true);
          const content =
              '// GENERATED — flutterware default store frame.\n'
              "import 'package:flutterware/store.dart';\n"
              '\n'
              'final storeFrame = defaultStoreFrame;\n';
          // Left alone when already right: a touched mtime reads as an edit and
          // recompiles for nothing.
          if (!file.existsSync() || file.readAsStringSync() != content) {
            file.writeAsStringSync(content);
          }
        }
        return StoreFrameRunner(
          packageRoot: root,
          flutterSdkRoot: host.workspace.flutterSdk.root,
          frameFile: frame,
        );
      });

  final _composers = <String, StoreFrameRunner>{};

  /// Where a composed set leaves the app's own pixels, relative to the
  /// declared output. See [_render].
  ///
  /// Kept rather than deleted: recomposing a headline reads these and never
  /// runs the app, which is the entire reason the work is two passes.
  /// Dot-prefixed so an upload tool pointed at the output ignores it.
  static const unframedDirectory = 'unframed';

  /// Ours, and dot-prefixed so an upload tool pointed at the tree ignores it.
  /// Holds the manifest the panel reads — and which
  /// `package:flutterware/store_report.dart` reads too — plus the scratch an
  /// export captures into.
  static const internalDirectory = StoreShotsReport.directory;

  @override
  void dispose() {
    for (var runner in _runners.values) {
      unawaited(runner.dispose());
    }
    for (var composer in _composers.values) {
      unawaited(composer.dispose());
    }
    _runners.clear();
    _composers.clear();
    super.dispose();
  }
}

PluginCore storeCoreFactory(PluginHost host) => StoreCore(host);

/// Where an export has got to.
///
/// Counts **sets**, not images, because a set is the unit that takes time — a
/// tester run per set on the capture pass — and because it is the unit the
/// panel draws. Fractional progress over images would move smoothly and mean
/// less: eleven of fifteen images of one set is not eleven-fifteenths of the
/// work when the next set has to run the app again.
class StoreProgress {
  const StoreProgress({
    required this.done,
    required this.total,
    required this.app,
    required this.key,
    required this.set,
    required this.phase,
  });

  final int done;
  final int total;

  /// Which declared app is being exported.
  ///
  /// Beside [key] rather than folded into it, because a key is the manifest's
  /// and a manifest belongs to one app already. The panel draws every app, so
  /// without this a second app declaring the same listing shape spins its card
  /// whenever the first one exports.
  final String app;

  /// Which set, as `store/class/appLocale` — the same key the manifest uses.
  ///
  /// A key rather than the label, because the panel has to ask *is this card
  /// the one*, and asking it of the label was wrong the first time it ran:
  /// `App Store · iPhone 6.9" · en` contains the string `Phone`, so Play's
  /// phone card span its spinner every time the iPhone set was exported.
  final String key;

  /// The set being worked on, as [_SetRequest.label] spells it — for the line
  /// a person reads, and nothing else.
  final String set;

  /// `Running` or `Composing` — the two passes, named as the reader sees them.
  final String phase;

  double get fraction => total == 0 ? 0 : done / total;

  /// The one line that reaches the panel, `fw run` and an MCP client alike.
  String get line => '$phase $set — ${done + 1} of $total';
}

/// How much of what is already there an export is entitled to remove.
///
/// One rule with three consequences, not three rules: an export replaces
/// exactly what it produces, so the scope of the invocation is the scope of
/// the deletion.
enum _Replace {
  /// Un-narrowed and writing where the declaration says: the whole tree is the
  /// statement, so the whole tree goes.
  tree,

  /// Narrowed to a listing, a locale or a class — or redirected somewhere that
  /// is not ours to empty, which may be a directory of somebody else's
  /// metadata.
  set,

  /// Narrowed to a shot. Its file is overwritten and its siblings are left
  /// alone.
  file,
}

/// One (target, locale) an export was asked for.
class _SetRequest {
  const _SetRequest({
    required this.target,
    required this.appLocale,
    required this.storeLocale,
  });

  final StoreTarget target;

  /// What the app is run as, and what the store files it under. Two
  /// vocabularies — see `Listing.locales`.
  final String appLocale;
  final String storeLocale;

  /// The same key [StoreShotsSet.key] uses, so the panel can match a card
  /// to the set being worked on without comparing rendered labels.
  String get key => '${target.store}/${target.id}/$appLocale';

  /// How a person would name this set out loud — `App Store · iPhone 6.9" ·
  /// en`. What a progress line says it is working on.
  String get label =>
      '${target.store == 'play' ? 'Google Play' : 'App Store'}'
      ' · ${target.label} · $appLocale';

  /// What this set's captures are filed under. Both locales are in it because
  /// two app locales can map to one store slot and vice versa, and a directory
  /// naming only one of them would collide.
  String get slug => '${target.store}-${target.id}-$appLocale-$storeLocale';

  Map<String, Object?> toJson({
    required List<String> images,
    required int failed,
  }) => {
    'store': target.store,
    'class': target.id,
    'appLocale': appLocale,
    'storeLocale': storeLocale,
    'images': images,
    'failed': failed,
  };
}

/// A set as it sits in `.captures/` — what pass two composes from.
class _CapturedSet {
  const _CapturedSet({
    required this.directory,
    required this.request,
    required this.images,
    required this.overlay,
    required this.failed,
  });

  final String directory;
  final _SetRequest request;
  final List<String> images;

  /// The `SystemUiOverlayStyle` each shot was captured under, by image name —
  /// what tells the frame whether to draw the status bar's icons dark or
  /// light. Null where the app declared no style.
  final Map<String, ({String? status, String? nav})> overlay;

  final int failed;
}

/// Where the store plugin reads from: the package's pubspec, where its export
/// tree sits by default, and the manifest that export left.
///
/// [LiveStoreSource] is the package's directory, which is the plugin as it
/// always was. The recorded project hands the core a source that answers from
/// a recording instead — see `demo/recorded_store.dart` — and the panel draws
/// the same cards over it. The pictures are the panel's business, not the
/// core's: `StorePlugin(image: …)` is the door for those.
abstract class StoreSource {
  const StoreSource();

  /// The package's `pubspec.yaml`, parsed — or null when there is none, or
  /// when the source has yet to read it.
  Map? pubspecOf(String packageRoot);

  /// Where an app's tree goes when the declaration names no `output:`.
  String defaultRootIn(String packageRoot);

  /// The manifest under [output] as it stands: empty when nothing was ever
  /// exported, and **null only when the source has yet to read it** — then
  /// [readManifest] fetches it and this answers from then on.
  StoreShotsReport? manifestOf(String output);

  /// Reads the manifest under [output]. Idempotent.
  Future<StoreShotsReport> readManifest(String output);
}

/// The package's directory on disk.
class LiveStoreSource extends StoreSource {
  const LiveStoreSource();

  /// What the last export left, per output — the panel's whole data source.
  ///
  /// Cached against the file's **mtime**, not against this process's own
  /// writes. The panel is not the only thing that exports: `fw run store
  /// export` in a terminal beside the open studio is the ordinary case, and a
  /// cache keyed on our own actions would leave that panel showing yesterday's
  /// listing with no way to tell. A `stat` per rebuild is microseconds; a
  /// silently stale panel is the bug class this repo has paid for more than
  /// once.
  static final _manifests =
      <String, ({DateTime? stamp, StoreShotsReport manifest})>{};

  @override
  Map? pubspecOf(String packageRoot) {
    var file = File(p.join(packageRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return null;
    try {
      var yaml = loadYaml(file.readAsStringSync());
      return yaml is Map ? yaml : null;
    } on YamlException {
      return null;
    }
  }

  @override
  String defaultRootIn(String packageRoot) =>
      p.join(packageRoot, 'build', 'flutterware', 'store');

  @override
  StoreShotsReport manifestOf(String output) {
    var file = File(
      p.join(output, StoreShotsReport.directory, StoreShotsReport.fileName),
    );
    var stamp = file.existsSync() ? file.lastModifiedSync() : null;
    var cached = _manifests[output];
    if (cached != null && cached.stamp == stamp) return cached.manifest;
    var manifest = StoreShotsReport.readFile(file) ?? const StoreShotsReport();
    _manifests[output] = (stamp: stamp, manifest: manifest);
    return manifest;
  }

  @override
  Future<StoreShotsReport> readManifest(String output) async =>
      manifestOf(output);
}
