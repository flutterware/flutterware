import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutterware/plugins.dart';
import 'package:meta/meta.dart';
// The tree types, not the umbrella: same rule as `headless_catalog.dart`, and
// for the same reason — `node.dart` is plain Dart and `ui_catalog.dart` is not.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/log.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axis.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';
import 'package:path/path.dart' as p;

import '../../embedder/tester_phase.dart';
import '../../previews/authoring.dart';
import '../../previews/catalog_entry.dart';
import '../../previews/catalog_tree.dart';
import '../../previews/debug_flags.dart';
import '../../previews/devices.dart';
import '../../previews/discovery.dart';
import '../../previews/inspect_client.dart';
import '../../previews/live_session.dart';
import '../../previews/protocol.dart';
import '../../previews/catalog_render.dart';
import '../../previews/tester_renderer.dart';
import '../../previews/headless_catalog.dart';
import '../../previews/test_runner.dart';
import '../../previews/web_build.dart';
import '../../delta/branch_delta.dart';
import '../../delta/branch_delta_controller.dart';
import '../../delta/delta_painting.dart';
import '../../inspect/lens.dart';
import '../../inspect/screen_read.dart';
import '../../session/job.dart';
import '../../utils/base_href.dart';
import '../plugin_core.dart';
import 'previews_address.dart';
import 'previews_results.dart';
import '../plugin_host.dart';

/// The registered id — also what `tool/flutterware.dart` declares.
const uiCatalogPluginId = 'flutterware.previews';

/// What this plugin is, for a reader who has only the id — see
/// `PluginReport.description`.
const _pluginDescription =
    'Your `@Preview` entries, rendered with the real fonts and the real theme '
    '— listed, screenshotted, inspected, and compared against the base branch.';

/// The action that compiles a browsable page.
///
/// Named once because two places spell it: the declaration below, and the
/// command the GUI's build dialog shows so the same thing can be run from a
/// terminal. A rename that reached only one of them would put a command that
/// fails in front of a user.
const webBuildActionId = 'build-web';

/// A package's busy line while the tester host works, or null when the host
/// has nothing left to wait on.
///
/// The rail's register, not the log's: lower case and trailing, so it sits in
/// the column beside `scanning…` and `rendering the catalog…` rather than
/// arriving as a sentence from somewhere else.
///
/// [TesterPhase.ready] is the one that returns null, and it is the reason this
/// exists at all: the warm tester is started for *thumbnails* as often as for
/// an audit, and only the audit clears the line afterwards. A row that said
/// "starting the harness" on the way up kept saying it for the rest of the
/// session.
@visibleForTesting
Status? previewsRunnerStatus(TesterPhaseReading reading) =>
    switch (reading.phase) {
      TesterPhase.compiling => const Status.info('compiling the catalog…'),
      TesterPhase.bundling => const Status.info('rebuilding the assets…'),
      TesterPhase.starting => const Status.info('starting the harness…'),
      TesterPhase.restarting => const Status.info('restarting the harness…'),
      TesterPhase.reloading => Status.info(
        'reloading ${reading.files} file${reading.files == 1 ? '' : 's'}…',
      ),
      TesterPhase.ready => null,
    };

/// What the scan knows about a package before anything is compiled.
enum CatalogSetup {
  /// Nothing has scanned this package yet.
  unknown,

  /// The declared directory is not on disk — usually a misspelt `directory:`.
  missing,

  /// The directory is there and holds no entries — every project, before its
  /// first demo. Not an error, and the state the tool should be best at.
  empty,

  /// There is at least one entry.
  ready,
}

/// Entries the text projection lists before it starts counting. A projection is
/// read, not scrolled.
const _projectedEntries = 20;

/// Entry ids spelled out inline as action options. Beyond this the caller reads
/// them from the view, which is what `optionsFrom` says.
const _inlinedOptions = 50;

/// What `--knobs` is, written once because five actions take it.
///
/// `optionsFrom` cannot help here the way it does for `entry`: a knob's names
/// depend on the entry, so there is no one list to point at. What an agent can
/// be given instead is where the names come from and how to ask.
const _orientationDoc = orientationParameterDoc;

const _knobsDoc =
    'Values to turn before this runs: `name=value,name=value`, or a JSON '
    'object. A knob is whatever the preview asked for while it built — a '
    'preview calling `context.knobs.string("label", "Hello")` '
    'declares one named `label` — so the names come from the preview itself '
    'and differ per '
    'entry. Read them with `describe --entry=<id> --with-knobs=true`. Each '
    'value is coerced to the kind the preview declared, and a picker takes one '
    'of its '
    'option labels; a name the entry does not declare is an error listing the '
    'ones it does.';

/// What `--debug` is. Third of a family, and the distinction is who owns it.
const _debugDoc =
    'The debug switches the framework itself registers, as '
    '`name=value,name=value`. These '
    'belong to neither the preview nor its shell but to the guest process, and '
    'the framework registers them whether anything asks or not — so unlike '
    'knobs and axes the set is fixed and listed in `--help`. '
    '`paint=true` draws the layout guides, `brightness=dark` moves '
    '`MediaQuery.platformBrightness` (dark mode without a shell axis for it), '
    '`banner=false` drops the DEBUG ribbon, `platform=iOS` changes what '
    '`defaultTargetPlatform` reports, `timeDilation=5` slows animations enough '
    'to photograph. Only what you name is set; the rest are left as they are.';

/// What `--keyboard` is, on every action that renders.
///
/// One string for the same reason [_orientationDoc] is one: a reader meeting it
/// on `screenshot` and again on `inspect` should not have to work out whether
/// the two differ.
const _keyboardDoc =
    'Whether the software keyboard is up — `auto` (the default), `up` or '
    '`down`. **`auto` is not off**: the preview raises a keyboard exactly when '
    'the widget asks for one, the way a phone does, so an entry that '
    'autofocuses a field is already rendered with 336 points less screen. '
    '`up` holds one up with nothing focused, which is how to ask *what does '
    'this layout do with a third of the screen gone* without hunting for a '
    'field to tap. The height is measured per device and per orientation — a '
    "phone's landscape keyboard is shorter than its portrait one, an iPad's is "
    'taller — and it is reported in the `MediaQuery` the way a real embedder '
    'reports it: the insets rise, the bottom safe area is eaten, `viewPadding` '
    'still remembers the device. Ignored by anything with no measured '
    'keyboard, which is every desktop size and `fit`.';

/// What `--width` and `--height` are, on both actions that take them.
const _sizeOverrideDoc =
    'Override the viewport, whatever it would otherwise have been — the '
    "package's declared `device:`, the one this call named, or the plain "
    'rectangle. This is how to ask for a size no device has; on a device it '
    'stretches the screen rather than dropping its ratio, its notch and its '
    'safe areas.';

/// What `--axes` is. The distinction from a knob is the whole content.
const _axesDoc =
    'Values for the shell *around* the preview — theme, locale, flavour. Same '
    'syntax as knobs: `name=value,name=value` or a JSON object. The difference '
    'is who declares it and how long it lasts: a knob is asked for by the preview '
    'and travels with the entry, an axis is declared by the `PreviewShell` '
    'wrapping it and stays put as you move between entries. Read them with '
    '`describe --entry=<id> --with-axes=true`, which also names the shell; an '
    'entry whose wrapper is not a shell offers none.';

/// What `--live` is, on every read that can be answered by a window somebody
/// already has open.
const _liveDoc =
    'Read the entry from a GUI session that is already showing it, instead of '
    'building a fresh guest. **Off unless you ask.** What it buys is real: '
    'attached, the answer describes the preview *as the person left it* — the '
    'dropdown they opened, the tab they switched to, the row they scrolled to, '
    'and anything their clicking made it print or throw. No fresh render can '
    'reach that, because no fresh render performs the clicks. What it costs is '
    'determinism: the same command answers differently depending on whether a '
    'window happens to be open, which is a poor default for CI and for an agent '
    'that did not know to look. So it is opt-in, and `readFrom` says which one '
    'you got either way — and which engine drew it when it was not this.  Even switched on it declines unless a session is open '
    'on this exact entry and nothing here would change what is drawn, and it '
    'never switches what that window is showing.';

/// Previews' entries, per declared package — everything but the panel.
///
/// Two tiers, and the split matters. The **scan** parses a package's demos
/// in ~38ms and touches no compiler, so `fw` and an agent read the entry list
/// without building anything. **Screenshots** run the real pipeline headlessly
/// — `HeadlessCatalog` needs no Flutter, which is what lets the button, `fw`
/// and an agent reach the same artifact by the same route.
///
/// What is *not* here is the live compile loop (`CatalogSession`): it drives a
/// guest engine into a texture, so it is Flutter-bound and belongs to the
/// panel. Its progress reaches [report] through [busyStatusFor], which the GUI
/// supplies and a CLI leaves null — correctly, since there is no session in a
/// CLI to be busy.
class PreviewsCore extends PluginCore {
  /// [scan] answers a package's syntactic scan — a parse of the disk
  /// off-isolate by default, and the door a catalog compiled into the host
  /// comes in through: the same core over a table of entries. See
  /// `lib/src/previews/inline_guest.dart`.
  PreviewsCore(super.host, {CatalogScan? scan}) : _scanner = scan ?? _liveScan;

  final CatalogScan _scanner;

  static Future<ScanResult> _liveScan({
    required String projectRoot,
    required List<String> roots,
    required List<String> previewAnnotations,
  }) => Isolate.run(
    () => CatalogScanner(
      projectRoot: projectRoot,
      roots: roots,
      previewAnnotations: previewAnnotations,
    ).scan(),
  );

  /// Declared packages, filtered to those the workspace knows about, so a typo
  /// cannot make the plugin scan a directory that is not there.
  late final List<String> packages = [
    for (var path in host.packagePaths)
      if (host.workspace.exists(path)) path,
  ];

  /// The web build in flight per package, so it can be refused a second time
  /// and killed when the worktree goes — see [dispose]. A `flutter build web`
  /// child is not reaped when the Dart process exits.
  final _builds = <String, WebCatalogBuilder>{};

  final _scans = <String, ScanResult>{};
  final _failures = <String, String>{};
  final _scanning = <String>{};

  /// How many looks a package has had, so an overlapping pair can be ordered —
  /// see [_scan].
  final _scanTokens = <String, int>{};

  /// The look in flight per package, for a look that gets overtaken to wait on
  /// rather than answer over — see [_scan].
  final _scanRuns = <String, Future<void>>{};

  /// The tester the audit renders in, kept per package and kept **warm**.
  ///
  /// That warmth is why it is held here rather than built once per call: the
  /// first audit pays a compile and a tester launch, and every
  /// one after it pays an incremental compile of what was edited. Disposed with
  /// the plugin — see [dispose] — because a `flutter_tester` is a child process
  /// and nothing else reaps it.
  final _testRunners = <String, PreviewTestRunner>{};

  /// What the GUI's compile loop is doing for a package, when there is one.
  ///
  /// A hook rather than a dependency: the core cannot import the session
  /// without importing Flutter, and the sidebar would otherwise lose the only
  /// status here that takes seconds.
  Status? Function(String path)? busyStatusFor;

  /// Called whenever a package has been scanned *again*.
  ///
  /// A hook for [busyStatusFor]'s reason, and the wall is the same one: the
  /// only thing that cares is the panel's picture cache, which holds
  /// `dart:ui` images and therefore cannot be named from here. What it means
  /// is "the catalog moved" — every picture taken of the previous scan is of
  /// code that may no longer be there.
  void Function(String path)? onRescanned;

  /// Called whenever a package's harness says what it is doing.
  ///
  /// A hook for the same reason as the two above — the phase is read here, and
  /// what wants it is a progress surface that cannot be named from a core with
  /// no Flutter in it. The *whole* vocabulary, not just the lines that make a
  /// status: [previewsRunnerStatus] drops [TesterPhase.ready] because a rail
  /// row shows nothing when nothing is happening, and a surface that has to
  /// take itself down needs to be told the wait ended.
  void Function(String path, TesterPhaseReading reading)? onRunnerPhase;

  /// Runs the `compare` action.
  ///
  /// A hook for the same reason as [busyStatusFor], though the wall is a
  /// different one: a comparison spans the previews *and* scenarios plugins,
  /// and a core cannot see its siblings. The session installs this on
  /// construction, closing over itself.
  Future<Object?> Function(Map<String, Object?> arguments)? compareRunner;

  /// What a headless action of this core is doing, while one runs.
  ///
  /// The counterpart of [busyStatusFor] for the work that needs no GUI: an
  /// audit compiles and renders every entry, which is the longest thing here,
  /// and it used to say `scanning…` once and then nothing for two minutes.
  /// Every renderer reads this — the sidebar shows it, and MCP forwards each
  /// change as a progress notification to a client that asked for one.
  final _busy = <String, Status>{};

  void _setBusy(String path, Status? status) {
    if (status == null) {
      _busy.remove(path);
    } else {
      _busy[path] = status;
    }
    notifyChanged();
  }

  /// Moves [path]'s busy line for a host line that means something, and leaves
  /// it exactly where it is for one that does not.
  ///
  /// The distinction is the whole of it: `onLog` carries the guest's console
  /// too, so a preview that prints while it builds would otherwise become the
  /// status. An unrecognised line is not "nothing is happening" either — it
  /// arrives *during* the compile it says nothing about — so it clears
  /// nothing.
  void _noteRunnerLine(String path, String line) {
    if (readTesterPhase(line) case var reading?) {
      _setBusy(path, previewsRunnerStatus(reading));
      onRunnerPhase?.call(path, reading);
    }
  }

  /// The scan failure for [path], for a panel that wants to show it directly.
  String? failureFor(String path) => _failures[path];

  /// What the scan noticed about [path] but did not act on — a duplicate id, an
  /// annotation on something that cannot be an entry.
  ///
  /// Public for the panel's empty state, which is the one place these matter
  /// most: with no entries to show, a diagnostic is the only explanation of
  /// why, and without it the screen claims none were written when some
  /// were.
  List<ScanDiagnostic> diagnosticsFor(String path) =>
      _scans[path]?.diagnostics ?? const [];

  /// Ends anything still running, which for this plugin means a web build.
  ///
  /// Called by the [Session] when the worktree closes. Without it a compile
  /// started from the dialog outlives the window it belongs to and keeps writing
  /// into the user's project.
  @override
  void dispose() {
    _delta.dispose();
    for (var builder in _builds.values) {
      unawaited(builder.cancel());
    }
    _builds.clear();
    for (var runner in _testRunners.values) {
      unawaited(runner.dispose());
    }
    _testRunners.clear();
    super.dispose();
  }

  /// The warm tester for [packagePath], started on first use.
  ///
  /// Public because the Flutter side builds its picture cache over the same
  /// one — see `PreviewsPlugin.thumbnailsFor`. Two testers for one package
  /// would be two `flutter_tester` processes and two cold compiles of the same
  /// catalog.
  ///
  /// [PreviewProgram.read] is a callback rather than a snapshot so that the
  /// harness is regenerated from whatever the scan says *now* — a preview
  /// written since the last audit is picked up by the next one, without the
  /// caller having to know a tester is being reused.
  PreviewTestRunner testRunnerFor(String packagePath) =>
      _testRunners.putIfAbsent(
        packagePath,
        () => PreviewTestRunner(
          packageRoot: p.join(host.worktree.path, packagePath),
          flutterSdkRoot: host.workspace.flutterSdk.root,
          read: () => (
            entries: _scans[packagePath]?.entries ?? const [],
            canvases: canvasesFor(packagePath),
          ),
          // The cold compile is the long pole and the only thing worth
          // reading during one — but a *log line* is not what a row can say,
          // so the host's narration is read back as a phase and everything
          // else is dropped. See [previewsRunnerStatus].
          onLog: (line) => _noteRunnerLine(packagePath, line),
        ),
      );

  /// Scans [path], unless it already has been. Idempotent.
  ///
  /// Deliberately does **not** start the compile loop: a scan reads files, a
  /// session spawns a daemon, and only mounting the panel justifies the second.
  void track(String path) {
    if (_scans.containsKey(path) ||
        _failures.containsKey(path) ||
        _scanning.contains(path)) {
      return;
    }
    _scanning.add(path);
    notifyChanged();
    unawaited(_scan(path));
  }

  /// Releases [path]. The scan stays — demand decides what work is justified,
  /// not what has to be discarded.
  void untrack(String path) {}

  /// Reads [path] again, for a caller that has learned the files moved.
  ///
  /// **The panel's list and the harness's list are not the same list.** What
  /// the tree draws comes from the compiler daemon, which watches the files and
  /// reports entries as they appear; what the `flutter_tester` harness behind
  /// every thumbnail generates its program from is the scan kept here, and
  /// until this existed that scan was taken once — when [track] first looked —
  /// and never again for the life of the process.
  ///
  /// A preview written while the panel was open was therefore listed and could
  /// not be photographed: its id was in no generated table, and the row came
  /// back *the harness returned nothing for this entry*. A **renamed** one was
  /// worse. The wrapper is generated from this scan, so it went on naming a
  /// symbol that no longer existed, the harness stopped compiling, and nothing
  /// short of reopening the studio brought it back.
  Future<void> rescan(String path) => _scan(path);

  /// Scans every declared package and waits — what `fw` does for the duration
  /// of one request, where there is no panel to subscribe on its behalf.
  @override
  Future<void> computeAll() async {
    await Future.wait([
      for (var path in packages)
        if (!_scans.containsKey(path) && !_failures.containsKey(path))
          _scan(path),
    ]);
  }

  /// Reads [path] and records what it found, resolving once the answer a
  /// caller may act on is in.
  ///
  /// **Awaiting this means an answer is in the maps** — for the awaiter's
  /// purposes, the freshest one. Two looks can be in flight at once: an action
  /// scans unconditionally, and [rescan] fires whenever the daemon says the
  /// catalog moved. They read the disk at different moments, so the one that
  /// *started* last is the one whose answer is about now, and the other's is
  /// dropped rather than written — otherwise the slower of the two lands last
  /// and puts the entry list back to before the edit that asked for the
  /// rescan, which is the staleness this is all for.
  ///
  /// A dropped look still owes its caller a fresh read, so it waits for the
  /// one that overtook it rather than returning with nothing written. Without
  /// that, `_entries` — which documents that it always re-scans rather than
  /// answering from the cache — could hand back the catalog from before the
  /// edit that started the overtaking look.
  Future<void> _scan(String path) {
    var token = _scanTokens[path] = (_scanTokens[path] ?? 0) + 1;
    // Registered after the run is created and cleared only by the run that is
    // still the registered one, so a look that finished long ago cannot sweep
    // its successor's entry — the trap `ScanCache` documents at `load`.
    late Future<void> run;
    run = _look(path, token).whenComplete(() {
      if (identical(_scanRuns[path], run)) _scanRuns.remove(path);
    });
    return _scanRuns[path] = run;
  }

  Future<void> _look(String path, int token) async {
    var root = p.join(host.worktree.path, path);
    var entryRoot = rootFor(path);
    var annotations = previewAnnotationsFor(path);
    // The look that overtook this one, when one did — awaited at the end, so
    // that a caller of a dropped look still comes back to an answer.
    Future<void>? overtaking;
    _scanning.add(path);
    try {
      // Off the calling isolate: a large catalog is tens of milliseconds of
      // file reads and parsing, which is a dropped frame if it runs on the UI
      // isolate.
      var result = await _scanner(
        projectRoot: root,
        roots: [entryRoot],
        previewAnnotations: annotations,
      );
      if (_scanTokens[path] != token) {
        overtaking = _scanRuns[path];
      } else {
        var previous = _scans[path];
        _scans[path] = result;
        _delta.scanLanded(path, result);
        // Anything holding a picture of the previous scan is holding one of
        // code that may have moved. An entry whose own file changed is caught
        // by that side's stamp; one whose *neighbour* changed is not, and a
        // rescan is exactly the moment we learn something did.
        if (previous != null) onRescanned?.call(path);
        // A scan that worked supersedes one that did not. Without this the
        // failure outlives its cause for the life of the process: the sidebar
        // keeps the error badge after the demo is fixed, `track` keeps
        // declining to look again because it treats a recorded failure as
        // "already scanned", and `build-web` keeps refusing with the stale
        // message while holding a perfectly good entry list.
        _failures.remove(path);
      }
    } catch (e) {
      if (_scanTokens[path] != token) {
        overtaking = _scanRuns[path];
      } else {
        _failures[path] = '$e';
      }
    } finally {
      // Only the newest look clears the mark: a superseded one finishing first
      // would report the package settled while the look everybody is waiting
      // for is still reading.
      if (_scanTokens[path] == token) _scanning.remove(path);
      notifyChanged();
    }
    // Outside the `finally`, so what is awaited is the successor's whole run
    // rather than a value the return statement raced. Null when it had already
    // finished — in which case the answer this look was overtaken by is
    // already in the maps.
    await overtaking;
  }

  /// What the branch changed, installed by the session — see
  /// `Session.branchDelta` and [DeltaPainting].
  BranchDeltaController? get branchDelta => _delta.controller;
  set branchDelta(BranchDeltaController? value) => _delta.controller = value;

  late final _delta = DeltaPainting<ScanResult>(
    owner: id,
    filesOf: (path, scan) => {
      for (var entry in scan.entries) worktreeRelative(path, entry.path),
    },
    spansOf: (path, scan) => [
      for (var entry in scan.entries)
        EntrySpan(
          id: entry.id,
          file: worktreeRelative(path, entry.path),
          line: entry.line,
          endLine: entry.endLine,
        ),
    ],
    onChanged: notifyChanged,
  );

  /// How the branch touched each entry of [path], or null before the delta
  /// has landed.
  EntryChanges? entryChangesFor(String path) => _delta.changesFor(path);

  /// What the package is scanned for: `directory` when declared, else the whole
  /// package.
  ///
  /// Public because it is part of the daemon address — `roots` is one of the
  /// fields [DaemonConfig] hashes — so the panel has to reach *this* answer
  /// rather than compute its own. It had a byte-identical copy in
  /// `PreviewsPlugin` until that copy became the next `appPackageRoot`.
  /// Where this package's entries are discovered.
  ///
  /// Reads the project-wide resolution rather than this plugin's own config,
  /// so that "where the catalog looks" has exactly one answer and every plugin
  /// that renders through it arrives at the same daemon. See
  /// [PluginHost.catalogRootsFor].
  String rootFor(String path) => host.catalogRootsFor(path).first;

  /// Where a *new* preview file goes — `demo/` unless the package narrowed the
  /// scan, in which case it goes where the scan is looking.
  ///
  /// Apart from [rootFor] because the two stopped being the same question when
  /// the scan widened to the package: everything is found, so nothing has to
  /// live anywhere, and the tool still has to put a scaffold *somewhere*.
  String authoringDirectoryFor(String path) {
    var root = rootFor(path);
    return root.isEmpty ? defaultAuthoringDirectory : root;
  }

  /// What [path]'s previews are framed as when no device is named, or null
  /// for the plain rectangle.
  ///
  /// One answer for every surface, which is the fix: the panel
  /// canvas, `screenshot`, `inspect` and `compare` each took `device`
  /// separately, so a project that is all phones had to repeat itself into
  /// every call site and CI invocation — and the one that forgot rendered at
  /// 900 × 700 and looked fine, because a phone layout laid out as a tablet
  /// does not overflow. A default that is wrong *and* looks right is the kind
  /// worth spending a config field on.
  ///
  /// An unknown id is ignored rather than refused. This is read on the way to
  /// drawing something, not while validating a command line, and a typo that
  /// blanked the panel would be a worse report than one that renders the
  /// rectangle it always used to.
  ///
  /// [entry] is the entry's package-relative path, and naming it is what makes
  /// the answer the *entry's* rather than the package's — a package holding a
  /// phone app and a desktop dashboard has two answers, and which one applies
  /// is a question only a path can settle. Omitting it asks what the package
  /// says with no subtree in mind, which is what `new` and an empty catalog
  /// want.
  ({Device? device, ScreenOrientation? orientation, KeyboardMode? keyboard})
  defaultFramingFor(String path, {String? entry}) {
    var canvas = canvasFor(canvasesFor(path), entry ?? '');
    return (
      device: canvas?.defaultDevice,
      orientation: canvas?.defaultOrientation,
      keyboard: canvas?.defaultKeyboard,
    );
  }

  /// What [path] declares its subtrees are framed as, longest prefix last to
  /// matter and `canvasFor` deciding between them.
  ///
  /// `device:` is desugared here, into the canvas with no prefix — so there
  /// is one mechanism underneath rather than a per-package default *and* a set
  /// of per-subtree ones with a precedence rule between them. A package that
  /// declares both gets the explicit whole-package canvas: it is the more
  /// specific spelling of the same thing, and silently merging the two would be
  /// inventing a third rule.
  List<PreviewCanvas> canvasesFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] != path) continue;
      var declared = [
        for (var raw in (config['canvases'] as List? ?? const []))
          ?PreviewCanvas.fromJson(raw),
      ];
      if (declared.any((canvas) => canvas.root.isEmpty)) return declared;
      var device = switch (config['device']) {
        String id => deviceById(id),
        _ => null,
      };
      var orientation = switch (config['orientation']) {
        String name => orientationById(name),
        _ => null,
      };
      if (device == null && orientation == null) return declared;
      return [
        ...declared,
        PreviewCanvas('', devices: [?device], orientations: [?orientation]),
      ];
    }
    return const [];
  }

  /// The annotation names that mark an entry in [path], without their `@`.
  ///
  /// Part of the daemon address, like [rootFor] and for the same reason: the
  /// panel and `fw run previews` must arrive at one daemon, and two sides
  /// deciding this independently would be two daemons scanning for different
  /// things.
  List<String> previewAnnotationsFor(String path) {
    for (var config in host.packageConfigs) {
      if (config['path'] != path) continue;
      if (config['previewAnnotations'] case List<Object?> names) {
        var registered = names.whereType<String>().toList();
        if (registered.isNotEmpty) return registered;
      }
    }
    return defaultPreviewAnnotations;
  }

  /// What the scan says about [path], before anything is compiled.
  ///
  /// The gate on the compile loop. A package with no entries used to reach
  /// the daemon anyway: it bound a socket, scanned the same directory in 1ms,
  /// refused, and exited before the client's first poll — which then ran to its
  /// 30-second deadline and reported that the daemon "never started listening".
  /// Half a minute of waiting for a fact this answers instantly, off a scan the
  /// panel has already paid for.
  ///
  /// [CatalogSetup.missing] is kept apart from [CatalogSetup.empty] because a
  /// misspelt `directory:` is otherwise indistinguishable from a directory
  /// nobody has written a demo in yet — the scanner skips a directory that is
  /// not there without a word ([CatalogScanner] takes the roots on trust).
  CatalogSetup setupFor(String path) {
    var scan = _scans[path];
    if (scan == null) return CatalogSetup.unknown;
    if (scan.entries.isNotEmpty) return CatalogSetup.ready;
    return Directory(p.join(host.worktree.path, path, rootFor(path)))
            .existsSync()
        ? CatalogSetup.empty
        : CatalogSetup.missing;
  }

  /// True while any declared package is being scanned.
  bool get isScanning => _scanning.isNotEmpty;

  /// Every entry found so far, across packages, in scan order.
  List<CatalogEntry> get entries => [
    for (var path in packages) ...?_scans[path]?.entries,
  ];

  /// What the scan found in [path] alone, before any daemon has run.
  ///
  /// The panel's listing is drawn from this until the daemon reports. It is
  /// the same set the daemon will send — both sides run [CatalogScanner] over
  /// the same roots, and the daemon serves everything it discovered, quarantine
  /// included. What the daemon adds is which of them *build*, and that is a
  /// mark on a row rather than a reason to withhold every row for the length of
  /// a cold compile.
  List<CatalogEntry> entriesFor(String path) =>
      _scans[path]?.entries ?? const [];

  /// Where an entry *is*, as the one identifier every surface carries.
  ///
  /// ```
  /// fw:///worktrees/<worktree>/flutterware.previews/<package>/<file…>/<file.dart%23symbol>
  /// ```
  ///
  /// The package comes first because two packages may legitimately declare the
  /// same entry id, and an address that cannot tell them apart is not an
  /// identity.
  ///
  /// The segments come from [catalogSegments], which the panel reads back
  /// through its inverse. Both halves live in one file so that this — the way
  /// in — and the way out cannot drift apart.
  ///
  /// [axes] are *applied*, not identity — the same entry rendered differently —
  /// which is what makes an address with its axes resolved a complete capture
  /// spec rather than an under-specified one.
  Address addressFor(
    String packagePath,
    String entryId, {
    Map<String, String> axes = const {},
  }) => Address(
    worktree: host.worktree.name,
    plugin: host.id,
    segments: catalogSegments(packagePath, entryId),
    axes: axes,
  );

  @override
  PluginReport get report => PluginReport(
    id: host.id,
    label: host.label,
    description: _pluginDescription,
    status: _status,
    badge: _failures.isNotEmpty || _scans.values.any((scan) => !scan.ok)
        ? const StatusBadge.dot(Tone.error)
        : StatusBadge.none,
    children: [
      for (var path in packages)
        PluginChild(
          id: path,
          label: path == '.' ? 'root' : path,
          status: _packageStatus(path),
        ),
    ],
    actions: [
      PluginAction(
        'entries',
        'Entries',
        returns: CatalogEntriesResult,
        description:
            'Every catalog entry, with its id and address — the whole list, '
            'not the projection the report carries — and `tree`, the same '
            'entries arranged into the folders and groups the panel shows, so '
            'nobody has to work the arrangement out from the ids',
        parameters: [
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description: 'Which declared package; all of them when omitted',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
        ],
      ),
      PluginAction(
        'new',
        'New preview',
        returns: CatalogNewResult,
        description:
            'Writes a preview file where the package keeps them, creating the '
            'directory if it is not there, and reports the id that renders it. '
            'The scaffold renders as written, so start here when you have '
            'never written one: it is the API, in a file that already works.',
        parameters: [
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Which declared package; the only one when there is one',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
          const ActionParameter(
            'name',
            'Name',
            required: true,
            description:
                "The preview's name — what the panel lists and what `@Preview(name:)` "
                'carries',
          ),
          const ActionParameter(
            'file',
            'File',
            required: false,
            description:
                'Package-relative path to write. Defaults to a snake_cased '
                "`.dart` file under the package's preview directory. Never "
                'overwrites.',
          ),
        ],
      ),
      PluginAction(
        'check',
        'Check',
        returns: CatalogCheckResult,
        description:
            'Which entries the compiler can build, and the diagnostics for '
            'those it cannot',
        parameters: [
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description: 'Which declared package; all of them when omitted',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
        ],
      ),
      const PluginAction(
        'describe',
        'Describe',
        returns: CatalogEntryDescription,
        description:
            'One entry: what it is, where it is, and the knobs it declares',
        parameters: [
          ActionParameter(
            'entry',
            'Entry',
            kind: ActionParameterKind.choice,
            description: 'The id of the entry to describe',
            optionsFrom: 'entries',
          ),
          // `with-` rather than the bare name, and that prefix is the whole
          // point of it. These four actions are listed side by side in
          // `fw run previews --help` and in the action index, so `--knobs`
          // meaning "include them in the answer" here and "set them on the
          // render" three lines down is a name that has to be learned
          // positionally — reported by a consumer who typed
          // `inspect --axes=true` by analogy and got a refusal. `--knobs=` and
          // `--axes=` now mean a selection everywhere, which is what they
          // already mean on an address (`axis.Language=nl`).
          ActionParameter(
            'with-knobs',
            'Read the knobs',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Compile the entry and run it to read the knobs it declares — '
                'the names and kinds every other action takes as `--knobs`. '
                'Off by default because it costs a build; without it the '
                'answer is what the scan knows.',
          ),
          ActionParameter(
            'with-axes',
            'Read the axes',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Run it and read what the shell around it offers — the names '
                'and kinds every other action takes as `--axes`, plus which '
                'shell declared them. Costs a build for the same reason knobs '
                'do: an axis is declared by a shell asking for it while it '
                'builds.',
          ),
        ],
      ),
      PluginAction(
        'screenshot',
        'Screenshot',
        returns: Artifact,
        description:
            'Render one entry to a PNG. **This is how you look at a Flutter '
            'widget.** Whenever the question is how something *looks* — a '
            'corner, a glyph, a border, two candidate designs side by side, a '
            'state that is three clicks deep in the running app — this answers '
            'it in one call: the real widget, the real fonts, the real theme, '
            'at any device in the table and at that device pixel ratio, so a '
            'detail worth a pixel comes back worth several. The alternatives '
            'people reach for instead are worse and quietly so: a widget test '
            'rendering to an image has no font loaded and draws every glyph as '
            'a filled box, and a screenshot of the whole app shrinks the thing '
            'you are asking about to a smudge. A widget that is not an entry '
            'yet becomes one in a few lines — a top-level function returning '
            'it, marked `@Preview` — and then it is here for good.',
        parameters: [
          ActionParameter(
            'entry',
            'Entry',
            kind: ActionParameterKind.choice,
            description: 'The id of the entry to render',
            // Points at the `entries` action, not at the report's view: the
            // view stops at 20 and this list does not, so the old pointer sent
            // a caller to a shorter list than the one it was truncating.
            optionsFrom: 'entries',
            options: [
              for (var entry in entries.take(_inlinedOptions))
                ActionOption(entry.id, label: entry.name),
            ],
          ),
          const ActionParameter(
            'output',
            'Output file',
            required: false,
            description: 'Where to write the PNG; a build path when omitted',
          ),
          const ActionParameter(
            'knobs',
            'Knobs',
            required: false,
            description:
                '$_knobsDoc Recorded on the address, so two settings are two '
                'artifacts rather than one file written twice.',
          ),
          ActionParameter(
            'device',
            'Device',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Render as a device: its screen, its pixel ratio and its safe '
                'areas, so the preview reads the phone from `MediaQuery` rather '
                "than a rectangle. Omitted takes the package's declared `device:`, "
                'and a plain rectangle when it declares none. The same value the '
                'GUI writes as `?device=`, so an address captured here reopens '
                'framed the way it was shot.',
            options: [
              for (var id in deviceIds)
                ActionOption(
                  id,
                  label: id == fitDeviceId
                      ? 'Fit'
                      : Devices.all.firstWhere((d) => d.id == id).label,
                ),
            ],
          ),
          ActionParameter(
            'orientation',
            'Orientation',
            kind: ActionParameterKind.choice,
            required: false,
            description: _orientationDoc,
            options: [for (var id in orientationIds) ActionOption(id)],
          ),
          ActionParameter(
            'keyboard',
            'Keyboard',
            kind: ActionParameterKind.choice,
            required: false,
            description: _keyboardDoc,
            options: [for (var id in keyboardModeIds) ActionOption(id)],
          ),
          // Declared because they change the pixels, and anything that changes
          // the pixels is recorded on the artifact's address.
          //
          // No `defaultValue`. They used to say 900 and 700, which stopped
          // being true the moment a package could declare a device — and a
          // stated default that the tool then ignores is worse than none,
          // because it is the number somebody reasons about without checking.
          // What they actually do is override whatever the framing resolved to,
          // which is what the descriptions now say.
          const ActionParameter(
            'width',
            'Width',
            kind: ActionParameterKind.integer,
            required: false,
            description: _sizeOverrideDoc,
          ),
          const ActionParameter(
            'height',
            'Height',
            kind: ActionParameterKind.integer,
            required: false,
            description: _sizeOverrideDoc,
          ),
          const ActionParameter(
            'axes',
            'Axes',
            required: false,
            description: _axesDoc,
          ),
          ActionParameter(
            'debug',
            'Debug switches',
            required: false,
            description: _debugDoc,
            options: [
              for (var flag in debugFlags)
                ActionOption(flag.name, label: flag.description),
            ],
          ),
          const ActionParameter(
            'node',
            'Crop to',
            required: false,
            description:
                'Photograph **one widget** instead of the whole viewport — '
                'name it: `node=SplitButton`, `node=Save`. Matched against '
                'every type, description and label on screen, the same way '
                '`find` matches, so no tree read is needed first and nothing '
                'has to be looked up. This is what to pass when the question '
                'is about a control rather than a screen: an entry laid out on '
                'a 900×700 canvas answers it with the thing you asked about in '
                'one corner and dead space everywhere else, which is a picture '
                'you then have to squint at. A tree id works too, for the case '
                'where the name is ambiguous — several matches are refused '
                'with their ids rather than guessed at, because cropping to '
                'the wrong one gives a picture that looks right. Cut out of '
                'the real frame rather than re-rendered alone, so the widget '
                'is still surrounded by what surrounds it.',
          ),
          const ActionParameter(
            'annotate',
            'Draw the ids',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Draw a box and its node id over every widget, so a tree read '
                'and a picture of it can be laid side by side',
          ),
          const ActionParameter(
            'engine',
            'Engine',
            kind: ActionParameterKind.choice,
            required: false,
            options: [
              ActionOption(
                'harness',
                label:
                    'The default. Renders under `flutter_tester` on a warm '
                    "harness: tens of milliseconds against the guest's ~12.7s "
                    'of daemon-connect, compile, spawn and teardown, and '
                    'reproducible — under a fake clock the same entry renders '
                    'byte-identically.',
              ),
              ActionOption(
                'guest',
                label:
                    'The embedder — a real engine drawing a real frame, which '
                    'is what the panel shows. Slower and not reproducible: it '
                    'photographs whatever real instant the render landed on. '
                    'Ask for it to settle an argument about which lane is '
                    'wrong, or for `--logs`, which only it can collect. The '
                    'two agree about the layout, and a test pins that.',
              ),
            ],
            description:
                'Which engine renders this. Both mount the same widgets on the '
                'same screen and a parity test holds them to it; what differs '
                'is the clock and the rasterizer. Omitted picks the harness, '
                'except where the call needs the guest — `--logs` does. The '
                'answer says which one drew it.',
          ),
        ],
      ),
      PluginAction(
        'inspect',
        'Inspect',
        returns: CatalogInspectResult,
        description:
            'One rendered build, and whatever you ask about it. With no flags '
            'it answers the two questions worth asking first: did it render '
            'without the framework complaining, and **what is on it** — the '
            'things that carry words or respond to touch, nested under the '
            'layout, with their boxes and their state. Everything heavier is '
            'one more flag on the same frame: `find` for where something is, '
            '`at` for what is under a point, `styles` for the type ramp, '
            '`tree` for all of it, `screenshot` for pixels. The same grammar '
            'the run plugin answers with on a live app and the scenarios '
            'plugin on a captured step, so a query is learned once.',
        parameters: [
          ActionParameter(
            'entry',
            'Entry',
            kind: ActionParameterKind.choice,
            description: 'The id of the entry to inspect',
            optionsFrom: 'entries',
          ),
          ActionParameter(
            'lens',
            'Lens',
            kind: ActionParameterKind.choice,
            required: false,
            defaultValue: 'act',
            description:
                'How much to hand back, as one word, instead of setting the '
                'flags one at a time. `act` is the screen alone; `look` adds '
                'a picture; `design` adds every distinct text style; `raw` '
                'adds the whole tree and costs about 20,000 tokens. The same '
                'four words run and scenarios take. A flag you set explicitly '
                'always beats the lens.',
            options: [
              for (var lens in ObserveLens.values) ActionOption(lens.name),
            ],
          ),
          const ActionParameter(
            'screen',
            'Screen',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'true',
            description:
                'What rendered, as a nested list of the things that carry '
                'words or respond to touch — a few hundred tokens, and the '
                'handle for deciding what to dig into. On by default; '
                '`false` when you only want `ok` or a query.',
          ),
          const ActionParameter(
            'styles',
            'Text styles',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Every distinct text size, weight and colour, most-used '
                'first with a sample of each. ~185 tokens for the whole type '
                'ramp, which settles most typography arguments — two greys '
                'that should be one, a scale with both 11.5 and 12.5 in it.',
          ),
          ActionParameter(
            'tree',
            'Widget tree',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Report the widget tree, scoped to the preview rather than the '
                'catalog around it. Off by default because a real preview is '
                'thousands of tokens of tree — try `find` first. Offstage '
                'content (a route kept alive under the current one, an '
                '`Offstage`) is folded to one node marked `offstage: true`; '
                'pass its id to `node` to read inside it.',
          ),
          ActionParameter(
            'find',
            'Find',
            required: false,
            description:
                'Report only the nodes matching this, case-insensitively '
                "against each node's type and against the words it puts on "
                'screen — `ElevatedButton`, `Save`, `SizedBox`. What you want '
                'instead of `tree` when the question is "where is the submit '
                'button".',
          ),
          ActionParameter(
            'at',
            'At a point',
            required: false,
            description:
                'Report the widgets under this point as `x,y`, outermost '
                'first — the chain, because the thing under a cursor is '
                'usually a Text and the thing you meant is the button around '
                'it. In the same coordinates a screenshot is taken in, so a '
                'point read off one lands here without a transform. The '
                'framework wrappers are dropped and the chain is capped at '
                'its innermost eight, which is where the answer always is.',
          ),
          ActionParameter(
            'errors',
            'What it reported',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'true',
            description:
                'Report build failures and layout overflows. On by default, '
                'and with no other flag it is the whole answer. `check` says '
                'whether an entry *compiles*, which is a different question.',
          ),
          ActionParameter(
            'logs',
            'What it printed',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Report what the preview printed while it built and painted. '
                'Attached to an open session this is everything it has printed '
                'since the person opened it, including whatever their clicking '
                'caused — output no fresh render can produce.',
          ),
          ActionParameter(
            'node',
            'Subtree',
            required: false,
            description:
                'Narrow `tree` to one widget and below, and crop `screenshot` '
                'to it — **name it**: `node=SplitButton`, `node=Save`, matched '
                'the way `find` matches, so nothing has to be looked up first. '
                'An id from an earlier read works too and is exact; ids come '
                'from tree shape, so one taken in another process still names '
                'this node. A name matching several widgets narrows to the '
                'outermost of them here, and is refused by `screenshot`, '
                'because too much tree is visible and the wrong crop is not.',
          ),
          ActionParameter(
            'depth',
            'Depth',
            kind: ActionParameterKind.integer,
            required: false,
            description: 'Stop `tree` this many levels below its root',
          ),
          ActionParameter(
            'screenshot',
            'Screenshot',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Write a PNG of the same frame everything else is reported '
                'from, and hand back an artifact for it — the path, and the '
                'address recording everything that changed the pixels, so two '
                'settings are two artifacts rather than one file written '
                'twice. Give `output` to choose where. **Forces a fresh '
                'render**: a picture has to come from a frame this call '
                'composited, and an attached session only offers a VM service.',
          ),
          ActionParameter(
            'output',
            'Output file',
            required: false,
            description:
                'Where to write the PNG; a build path derived from the address '
                'when omitted, the same as `screenshot` uses',
          ),
          ActionParameter(
            'annotate',
            'Annotate',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description:
                'Draw a box and its node id over every widget of the '
                'screenshot. Now genuinely the same tree as the one reported '
                'rather than a second reading that happened to agree, which '
                'was the point of having it.',
          ),
          const ActionParameter(
            'engine',
            'Engine',
            kind: ActionParameterKind.choice,
            required: false,
            options: [
              ActionOption(
                'harness',
                label:
                    'The default. Renders under `flutter_tester` on a warm '
                    "harness: tens of milliseconds against the guest's ~12.7s "
                    'of daemon-connect, compile, spawn and teardown, and '
                    'reproducible — under a fake clock the same entry renders '
                    'byte-identically.',
              ),
              ActionOption(
                'guest',
                label:
                    'The embedder — a real engine drawing a real frame, which '
                    'is what the panel shows. Slower and not reproducible: it '
                    'photographs whatever real instant the render landed on. '
                    'Ask for it to settle an argument about which lane is '
                    'wrong, or for `--logs`, which only it can collect. The '
                    'two agree about the layout, and a test pins that.',
              ),
            ],
            description:
                'Which engine renders this. Both mount the same widgets on the '
                'same screen and a parity test holds them to it; what differs '
                'is the clock and the rasterizer. Omitted picks the harness, '
                'except where the call needs the guest — `--logs` does. The '
                'answer says which one drew it.',
          ),
          ActionParameter(
            'device',
            'Device',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Render as a device: its screen, its pixel ratio and its safe '
                'areas, so the preview reads the phone from `MediaQuery` rather '
                "than a rectangle. Omitted takes the package's declared `device:`, "
                'and a plain rectangle when it declares none. **This is what '
                'makes "why does it look wrong on a phone" one render**: the '
                'tree, the constraints and the picture all describe the same '
                'framed build. Forces a render, like any other change to what '
                'is drawn.',
            options: [
              for (var id in deviceIds)
                ActionOption(
                  id,
                  label: id == fitDeviceId
                      ? 'Fit'
                      : Devices.all.firstWhere((d) => d.id == id).label,
                ),
            ],
          ),
          ActionParameter(
            'orientation',
            'Orientation',
            kind: ActionParameterKind.choice,
            required: false,
            description: _orientationDoc,
            options: [for (var id in orientationIds) ActionOption(id)],
          ),
          ActionParameter(
            'keyboard',
            'Keyboard',
            kind: ActionParameterKind.choice,
            required: false,
            description: _keyboardDoc,
            options: [for (var id in keyboardModeIds) ActionOption(id)],
          ),
          const ActionParameter(
            'width',
            'Width',
            kind: ActionParameterKind.integer,
            required: false,
            description:
                'Override the viewport width — how to ask for a size no device '
                'has, and on a device it stretches the screen rather than '
                'dropping its ratio and its notch',
          ),
          ActionParameter(
            'height',
            'Height',
            kind: ActionParameterKind.integer,
            required: false,
            description: 'See width',
          ),
          ActionParameter(
            'knobs',
            'Knobs',
            required: false,
            description:
                '$_knobsDoc A tree is of one build, and a knob can change '
                'which widgets there are.',
          ),
          ActionParameter(
            'axes',
            'Axes',
            required: false,
            description: _axesDoc,
          ),
          ActionParameter(
            'debug',
            'Debug switches',
            required: false,
            description: _debugDoc,
          ),
          ActionParameter(
            'live',
            'Read what is open',
            kind: ActionParameterKind.boolean,
            required: false,
            defaultValue: 'false',
            description: _liveDoc,
          ),
        ],
      ),
      PluginAction(
        'audit',
        'Audit every entry',
        returns: CatalogAuditResult,
        description:
            'Render the whole catalog and report everything that does not '
            'compile or does not render — one warm guest, one answer for the '
            'repo',
        parameters: [
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description: 'Which declared package; all of them when omitted',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
          const ActionParameter(
            'path',
            'Narrow to',
            required: false,
            description:
                'A directory or one file — `demo/settings`, '
                '`demo/settings/tile.dart`. Either package-relative or '
                'worktree-relative; both are accepted because an entry id is '
                'the first and a shell tab-completes the second.',
          ),
          ActionParameter(
            'device',
            'Device',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Render every entry as this device instead of the canvas each '
                'one declares — how to ask whether the whole catalog survives a '
                'small phone. Omitted is the right answer for CI: each entry is '
                'framed as its own subtree declared, and an entry under no '
                'canvas gets the plain rectangle.',
            options: [
              for (var id in deviceIds)
                ActionOption(id, label: deviceById(id)?.label ?? id),
            ],
          ),
          ActionParameter(
            'orientation',
            'Orientation',
            kind: ActionParameterKind.choice,
            required: false,
            description: orientationParameterDoc,
            options: [for (var id in orientationIds) ActionOption(id)],
          ),
        ],
      ),
      PluginAction(
        webBuildActionId,
        'Build a web page',
        returns: CatalogWebBuildResult,
        description:
            'Compile the whole catalog into a browsable page — the previews '
            'themselves running in a browser, with their knobs, not pictures '
            'of them. Needs the package to have web enabled; says so, with the '
            'command, when it does not.',
        parameters: [
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Which declared package; the only one when there is one',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
          const ActionParameter(
            'output',
            'Write to',
            required: false,
            description:
                'Where the page goes. Package-relative unless absolute; '
                'defaults to `build/catalog/web`.',
          ),
          const ActionParameter(
            'base-href',
            'Base href',
            required: false,
            description:
                'Where the page is mounted. Defaults to `./`, which resolves '
                "against the page's own URL and so works at a host root and "
                'under a subdirectory alike. Give an absolute `/catalog/` '
                'only for a host that serves a directory without redirecting '
                'to a trailing slash.',
          ),
        ],
      ),
      PluginAction(
        'compare',
        'Compare against the base',
        returns: ComparisonCompareResult,
        description:
            'What this worktree did to the pictures: renders previews and '
            'replays scenarios on both sides of the branch and diffs them — '
            'pixels, widget tree, visible texts. Every package either half '
            'declares, unless `package` narrows it; a row from a repository '
            'with more than one carries the package in its id and in its '
            '`package` field. Nothing is blessed: both sides are computed '
            'from git on demand, and the skip rule answers entries whose '
            'closure nothing touched without rendering anything. Returns the '
            'verdict; the artifact at `index` has every row and channel.',
        parameters: [
          const ActionParameter(
            'base',
            'Against',
            required: false,
            description:
                'Any ref git can name — `origin/main`, a sha. Defaults to '
                "the project's base, then the default branch, taken at the "
                'merge base either way.',
          ),
          ActionParameter(
            'package',
            'Package',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Narrow to one package. Omitting this compares **every** '
                'package either half declares, which is the default: a '
                'repository with previews in two packages and scenarios in '
                'two others gets one verdict covering all four.',
            options: [
              for (var path in packages)
                ActionOption(path, label: path == '.' ? 'root' : path),
            ],
          ),
          const ActionParameter(
            'entry',
            'Entry',
            required: false,
            description:
                'Narrow to one entry or scenario id — as `entries` and the '
                'scenarios `list` action report them',
          ),
          const ActionParameter(
            'export',
            'Export a page',
            kind: ActionParameterKind.boolean,
            required: false,
            description:
                'Write the comparison as a browsable page under '
                '`build/comparison/web` — the viewer, the index and a PNG '
                'per frame. Serve it over HTTP.',
          ),
          const ActionParameter(
            'frames',
            'Frames',
            kind: ActionParameterKind.choice,
            required: false,
            description:
                'Which pictures the exported page carries. `changed` writes '
                "the findings' frames only — the verdict is untouched, but an "
                'unchanged entry has no picture beside it and says so. On a '
                'run where the skip rule did not earn its keep that is most of '
                'the page.',
            options: [
              ActionOption('all', label: 'all'),
              ActionOption('changed', label: 'findings only'),
            ],
          ),
          const ActionParameter(
            'base-href',
            'Base href',
            required: false,
            description:
                'Where the exported page is mounted. Defaults to `./`, which '
                "resolves against the page's own URL and so works at a "
                'bucket root and under a per-pull-request prefix alike. Give '
                'an absolute `/comparisons/42/` only for a host that serves '
                'a directory without redirecting to a trailing slash.',
          ),
          const ActionParameter(
            'report',
            'PR report into',
            required: false,
            description:
                'Write what a pull-request comment needs into this '
                'directory: `comment.md`, `mosaic.png`, and the page under '
                '`web/`. The comment references images by `__MOSAIC_URL__` '
                'and `__VIEWER_URL__` placeholders for the workflow to '
                'substitute after it hosts the files.',
          ),
          const ActionParameter(
            'jobs',
            'Jobs',
            kind: ActionParameterKind.integer,
            required: false,
            description:
                'How many previews render and scenarios replay at once on '
                'each side — up to twice this many `flutter_tester`s. '
                'Defaults to 1, one guest per side.',
          ),
        ],
      ),
    ],
    view: _view,
  );

  /// Deliberately silent at rest. An entry count is not news — it cannot even
  /// be known until something asks for a scan — and a row that fills in a
  /// number the moment you look at it is worse than an empty one.
  Status get _status {
    if (packages.isEmpty) return Status.none;
    if (_failures.isNotEmpty) {
      return Status.error('${_failures.length} failed to scan');
    }
    for (var path in packages) {
      if (_busy[path] case var busy?) return busy;
      if (busyStatusFor?.call(path) case var busy?) return busy;
    }
    if (isScanning) return const Status.info('scanning…');
    if (_scans.isEmpty) return Status.none;

    // Discovery refuses on a duplicate id or an uncallable target, so the
    // catalog is not usable; staying quiet would be a lie.
    var broken = _scans.values.where((scan) => !scan.ok).length;
    if (broken > 0) {
      return Status.error(
        '$broken ${broken == 1 ? 'package' : 'packages'} failed discovery',
      );
    }
    // Names the directory rather than the fact. "no entries" sent a reader
    // looking for a setting; "no entries in demo/" *is* the setting.
    if (entries.isEmpty) {
      var only = packages.length == 1 ? packages.single : null;
      return Status.warn(
        only == null ? 'no entries' : 'no entries in ${rootFor(only)}/',
      );
    }
    var warnings = _scans.values.fold(
      0,
      (sum, scan) => sum + scan.diagnostics.length,
    );
    return warnings == 0
        ? Status.none
        : Status.warn('$warnings ${warnings == 1 ? 'warning' : 'warnings'}');
  }

  Status _packageStatus(String path) {
    // The fact, not the exception: `_failures` holds a whole `'$e'`, which on
    // a scan is a multi-line analyzer message. The text is in the panel's own
    // projection, where there is room to read it.
    if (_failures.containsKey(path)) {
      return const Status.error('failed to scan');
    }
    if (_busy[path] case var busy?) return busy;
    if (busyStatusFor?.call(path) case var busy?) return busy;
    if (_scanning.contains(path)) return const Status.info('scanning…');
    var scan = _scans[path];
    if (scan == null) return Status.none;
    if (!scan.ok) return const Status.error('discovery failed');
    return switch (setupFor(path)) {
      // A directory that is not there is a typo in `directory:` far more often
      // than it is an intention, so it is worth a different word from "empty".
      CatalogSetup.missing => Status.warn('no ${rootFor(path)}/ directory'),
      CatalogSetup.empty => Status.warn('no entries in ${rootFor(path)}/'),
      _ => Status.none,
    };
  }

  PluginView get _view {
    var nodes = <ViewNode>[];
    for (var path in packages) {
      if (_failures[path] case var failure?) {
        nodes.add(ViewSection(path, [ViewText(failure, tone: Tone.error)]));
        continue;
      }
      var scan = _scans[path];
      if (scan == null) {
        // Honest: nothing has asked for this package, so nothing was scanned.
        // That is not the same as "no entries".
        nodes.add(
          ViewSection(path == '.' ? 'root' : path, const [
            ViewText('not computed'),
          ]),
        );
        continue;
      }

      // The one moment the reader is certainly asking "so how do I write one" —
      // the same rule the scenarios list follows, and the same hint text.
      //
      // **The diagnostics come first, and skipping them was a real hole.** Zero
      // entries does not mean nobody wrote one: an annotation on a function with
      // a required parameter, or on a non-static member, is rejected *with a
      // diagnostic* and produces no entry. Dropping them told somebody who had
      // just written a demo that they had none, and offered to teach them how —
      // while the sidebar said "failed discovery" from the same scan.
      if (scan.entries.isEmpty) {
        nodes.add(
          ViewSection(path == '.' ? 'root' : path, [
            ViewText(
              catalogEmptyReason(
                directory: rootFor(path),
                directoryExists: setupFor(path) != CatalogSetup.missing,
                package: packages.length == 1 ? null : path,
              ),
              tone: Tone.warn,
            ),
            if (scan.diagnostics.isNotEmpty)
              ViewSection('Diagnostics', [
                for (var diagnostic in scan.diagnostics)
                  ViewText(
                    '$diagnostic',
                    tone: diagnostic.isError ? Tone.error : Tone.warn,
                  ),
              ]),
            ViewText(catalogAuthoringHint(rootFor(path))),
          ]),
        );
        continue;
      }

      var children = <ViewNode>[
        ViewItems([
          for (var entry in scan.entries.take(_projectedEntries))
            ViewItem(
              entry.group == null
                  ? entry.name
                  : '${entry.group} / ${entry.name}',
              detail: entry.id,
              // The same address the screenshot action and an artifact carry —
              // built here rather than left to a reader to reassemble from the
              // package and the id, which is how two surfaces come to disagree
              // about what an entry is called.
              address: addressFor(path, entry.id),
            ),
        ], truncated: scan.entries.length - _projectedEntries),
        if (scan.diagnostics.isNotEmpty)
          ViewSection('Diagnostics', [
            for (var diagnostic in scan.diagnostics)
              ViewText(
                '$diagnostic',
                tone: diagnostic.isError ? Tone.error : Tone.warn,
              ),
          ]),
      ];
      nodes.add(ViewSection(path == '.' ? 'root' : path, children));
    }
    return PluginView(nodes);
  }

  /// Every entry, not just the projected ones.
  ///
  /// The default walks [report], which lists only the first
  /// [_projectedEntries] of each package — and since entries are sorted by id,
  /// that is the alphabetical head of the catalog. A 160-entry package offered
  /// twenty, all of them from files beginning `a`–`c`, and the palette looked
  /// like it worked. The same hole `AssetsCore.search` closes, for the same
  /// reason: the scan is already in memory, so walking all of it costs a fuzzy
  /// match per entry and stays the pure read the contract requires.
  ///
  /// The title is the one the projection shows, so a row found here and a row
  /// read there are the same row.
  @override
  List<SearchHit> search(String query) {
    var trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    var hits = <SearchHit>[];
    var seen = <String>{};
    for (var path in packages) {
      var scan = _scans[path];
      if (scan == null) continue;
      for (var entry in scan.entries) {
        var title = entry.group == null
            ? entry.name
            : '${entry.group} / ${entry.name}';
        var match = fuzzyMatch(trimmed, title);
        var score = match?.score;
        if (score == null) {
          // The subtitle fallback the default walk applies to a `detail`, kept
          // so the entries that were findable before behave identically now:
          // substring, not subsequence, because an id is a long path and a long
          // string contains almost any short subsequence.
          var index = entry.id.toLowerCase().indexOf(trimmed.toLowerCase());
          if (index < 0) continue;
          score = 10 + (20 - index).clamp(0, 20);
        }
        var address = addressFor(path, entry.id);
        if (!seen.add('$address')) continue;
        hits.add(
          SearchHit(
            address: address,
            title: title,
            subtitle: entry.id,
            group: host.label,
            reason: SearchReason.item,
            score: score,
            matched: match?.matched ?? const [],
          ),
        );
      }
    }

    // The plugin row and the package children still come from the projection —
    // there is no reason to reimplement those, and keying the dedupe on the
    // address alone keeps the projected entries from arriving a second time.
    for (var hit in searchReport(
      report,
      trimmed,
      worktree: host.worktree.name,
    )) {
      if (seen.add('${hit.address}')) hits.add(hit);
    }

    hits.sort((a, b) => b.score - a.score);
    return hits;
  }

  @override
  Future<Object?> invoke(
    String actionId, {
    Map<String, Object?> arguments = const {},
  }) async {
    switch (actionId) {
      case 'entries':
        return _entries(arguments);
      case 'new':
        return newPreview(
          package: arguments['package'] as String?,
          name: arguments['name'],
          file: arguments['file'],
        );
      case 'check':
        return _check(arguments);
      case 'describe':
        return _describe(arguments);
      case 'screenshot':
        return _screenshot(arguments);
      case 'inspect':
        return _inspect(arguments);
      case 'audit':
        return _audit(arguments);
      case webBuildActionId:
        return _buildWeb(arguments);
      case 'compare':
        var runner = compareRunner;
        if (runner == null) {
          // A core driven without a session around it — a test, usually.
          // Naming the wiring beats a null error three calls deep.
          throw StateError(
            'compare needs the session to install its runner, and this core '
            'was built without one.',
          );
        }
        return runner(arguments);
      default:
        return super.invoke(actionId, arguments: arguments);
    }
  }

  /// Every entry, in scan order, with the address that identifies each one.
  ///
  /// Scans if nothing has. A report may never start work; an action asked
  /// for by name may, and here must — `fw` and MCP open a session per request
  /// and hold nothing between them, so a query that only read the cache would
  /// answer "no entries" every time.
  ///
  /// The whole list, deliberately: the report's view stops at 20 entries and
  /// the screenshot action inlines at most 50 options, both of which are right
  /// for a projection meant to be read and wrong for the question "what can I
  /// screenshot".
  Future<CatalogEntriesResult> _entries(Map<String, Object?> arguments) async {
    var paths = _requestedPackages(arguments);

    // Always re-scans rather than answering from the cache. A scan is ~38ms
    // against a ~700ms process start, and the alternative is a `--refresh`
    // flag whose unset behaviour would be "possibly stale, no way to tell" —
    // which is not a useful thing to offer someone asking what exists.
    await Future.wait([for (var path in paths) _scan(path)]);
    // The scans registered their files, each starting or queueing a load. A
    // load already running when they landed was asked before them, so this
    // waits for the chain to settle rather than for the first to finish.
    await branchDelta?.whenSettled();

    return CatalogEntriesResult(
      packages: [for (var path in paths) _packageEntries(path)],
    );
  }

  /// Writes the first demo — the file, and the directory if it is not there.
  ///
  /// Public because the panel's empty state offers it as a button: somebody who
  /// is already looking at the GUI should not be sent to a terminal to get
  /// their first file. Both routes land here, so the file they get is the same
  /// file.
  Future<CatalogNewResult> newPreview({
    String? package,
    Object? name,
    Object? file,
  }) async {
    var path = _requireOnePackage(package);

    if (name is! String || name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', "required — the demo's name");
    }
    name = name.trim();

    if (file != null && file is! String) {
      throw ArgumentError.value(
        file,
        'file',
        'must be a package-relative path',
      );
    }
    var relative =
        (file as String?) ??
        '${authoringDirectoryFor(path)}/${catalogFileName(name)}';
    // Inside the package, always: the scan only looks under the declared
    // directory, so a file written outside it is a file nothing will ever find.
    if (p.isAbsolute(relative) || p.split(relative).contains('..')) {
      throw ArgumentError.value(
        relative,
        'file',
        'must be relative to the package and stay inside it',
      );
    }
    if (!relative.endsWith('.dart')) {
      throw ArgumentError.value(relative, 'file', 'must end in `.dart`');
    }
    // Under the scanned directory, which is the check the two above only looked
    // like. Discovery walks `rootFor(path)` and nothing else, so a file written
    // beside it compiles, is never found, and leaves this call handing back an
    // id and a `next` command for an entry that does not exist.
    var root = rootFor(path);
    if (!_isAtOrUnder(relative, root)) {
      throw ArgumentError.value(
        relative,
        'file',
        'must be under $root/, the only directory this package is scanned for '
            'demos. A file outside it would never be found. Change the '
            r'directory itself with `Previews(packages: [.new(app, '
            r"directory: '...')])` in tool/flutterware.dart.",
      );
    }

    var target = File(p.join(host.worktree.path, path, relative));
    if (target.existsSync()) {
      throw ArgumentError.value(
        relative,
        'file',
        'already exists. Add the preview to it, or name another file.',
      );
    }
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(catalogScaffold(name));

    // The scan is now stale by exactly this file — and, when this was the first
    // demo, by the whole question of whether the package has any.
    _scans.remove(path);
    _failures.remove(path);
    await _scan(path);

    var id = '$relative#${catalogSymbolName(name)}';
    return CatalogNewResult(
      package: path,
      file: relative,
      name: name,
      id: id,
      next: "fw run previews screenshot --entry='$id'",
    );
  }

  /// Compiles one package's catalog into a browsable page.
  ///
  /// Unlike every other action here this runs no daemon and no guest: a page is
  /// the previews themselves, compiled for a browser, not pictures of them. What
  /// it needs from this class is only the scan — which entries there are — and
  /// which package they belong to.
  ///
  /// [onOutput] is how a caller follows a build that takes tens of seconds; the
  /// CLI hands it straight to its own printer and the GUI to a dialog.
  Future<CatalogWebBuildResult> buildWeb({
    String? package,
    String? output,
    String baseHref = defaultBaseHref,
    void Function(String line)? onOutput,
  }) async {
    var packagePath = _requireOnePackage(package);
    await _scan(packagePath);
    if (_failures[packagePath] case var failure?) {
      throw ActionRefusal('$packagePath could not be scanned: $failure');
    }

    // One at a time per package. Two builds share a generated source directory,
    // and `WebAppGenerator.generate` deletes it recursively before writing — so
    // a second build started while the first is compiling pulls the first's
    // sources out from under it, and the first fails pointing at files that no
    // longer exist.
    if (_builds.containsKey(packagePath)) {
      throw ActionRefusal(
        'A web build is already running for $packagePath. Wait for it, or '
        'close the worktree to stop it.',
      );
    }

    var packageRoot = p.join(host.worktree.path, packagePath);
    var builder = _builds[packagePath] = WebCatalogBuilder(
      flutterExecutable: host.workspace.flutterSdk.flutter,
      packageRoot: packageRoot,
      // The package rather than the plugin: a page says what it is a catalog
      // *of*, and "Previews" on a repo with three of them says nothing.
      title: packagePath == '.' ? host.worktree.name : packagePath,
      clock: host.projectClock,
    );
    WebCatalogBuild built;
    try {
      built = await builder.build(
        entries: _scans[packagePath]?.entries ?? const [],
        output: output,
        baseHref: baseHref,
        onOutput: onOutput,
      );
    } finally {
      _builds.remove(packagePath);
    }

    return CatalogWebBuildResult(
      package: packagePath,
      output: _shortened(built.output),
      indexHtml: _shortened(built.indexHtml),
      entries: built.entryCount,
      durationMs: built.duration.inMilliseconds,
    );
  }

  Future<CatalogWebBuildResult> _buildWeb(Map<String, Object?> arguments) {
    String? text(String name) {
      var value = arguments[name];
      if (value == null) return null;
      if (value is! String) {
        throw ArgumentError.value(value, name, 'must be a string');
      }
      return value.isEmpty ? null : value;
    }

    var baseHref = text('base-href') ?? defaultBaseHref;
    // Checked here rather than left to the tool, which fails after the whole
    // compile with a message about a value this action accepted.
    if (baseHrefProblem(baseHref) case var problem?) {
      throw ArgumentError.value(baseHref, 'base-href', problem);
    }

    return buildWeb(
      package: text('package'),
      output: text('output'),
      baseHref: baseHref,
    );
  }

  /// The one package an action can act on, which is not the same question
  /// [_requestedPackages] answers.
  ///
  /// A build writes one page from one package's demos. Defaulting to "all of
  /// them" would either concatenate catalogs that are deliberately separate
  /// or silently build the first — so a repo with several is asked, once,
  /// rather than guessed at.
  String _requireOnePackage(String? requested) {
    if (requested != null) {
      if (!packages.contains(requested)) {
        throw ArgumentError.value(
          requested,
          'package',
          'not declared for this plugin. Declared: ${packages.join(', ')}',
        );
      }
      return requested;
    }
    if (packages.length == 1) return packages.single;
    if (packages.isEmpty) {
      throw ActionRefusal('No packages are declared for Previews.');
    }
    throw ArgumentError.value(
      null,
      'package',
      'this plugin has more than one package, so a build has to say which: '
          '${packages.join(', ')}',
    );
  }

  /// Worktree-relative where it is inside the worktree, so the value survives
  /// being read on another machine — the same rule [Artifact.path] follows.
  String _shortened(String path) => p.isWithin(host.worktree.path, path)
      ? p.relative(path, from: host.worktree.path)
      : path;

  /// Which packages an action was pointed at: the named one, or all declared.
  List<String> _requestedPackages(Map<String, Object?> arguments) {
    var requested = arguments['package'];
    if (requested != null && requested is! String) {
      throw ArgumentError.value(requested, 'package', 'must be a package path');
    }
    var paths = requested == null ? packages : [requested as String];
    for (var path in paths) {
      if (!packages.contains(path)) {
        throw ArgumentError.value(
          path,
          'package',
          'not declared for this plugin. Declared: ${packages.join(', ')}',
        );
      }
    }
    return paths;
  }

  CatalogPackageEntries _packageEntries(String path) {
    if (_failures[path] case var failure?) {
      return CatalogPackageEntries(
        path: path,
        directory: rootFor(path),
        error: failure,
      );
    }
    var scan = _scans[path];
    // Resolved once for the package rather than per entry: `canvasesFor` walks
    // the package configs, and a list is short where an entry list is not.
    var canvases = canvasesFor(path);
    var changes = entryChangesFor(path);
    return CatalogPackageEntries(
      path: path,
      directory: rootFor(path),
      branch: _delta.summaryFor(path),
      authoring: scan == null || scan.entries.isNotEmpty
          ? null
          : '${catalogEmptyReason(directory: rootFor(path), directoryExists: setupFor(path) != CatalogSetup.missing, package: path)}\n\n'
                '${catalogAuthoringHint(rootFor(path))}',
      entries: [
        for (var entry in scan?.entries ?? const <CatalogEntry>[])
          _summarise(path, entry, canvases, changes?[entry.id]),
      ],
      tree: _treeNodes(
        buildCatalogTree(scan?.entries ?? const <CatalogEntry>[]),
      ),
      diagnostics: [
        for (var diagnostic in scan?.diagnostics ?? const []) '$diagnostic',
      ],
    );
  }

  /// The panel's own tree, on the wire.
  ///
  /// A translation and nothing more: [buildCatalogTree] decides the shape, and
  /// this turns its nodes into the serialisable ones. Arranging entries a
  /// second time here — even correctly, today — is how the answer and the panel
  /// come to disagree about a catalog neither of them changed.
  static List<CatalogEntryNode> _treeNodes(List<CatalogNode> nodes) => [
    for (var node in nodes)
      switch (node) {
        CatalogLeaf(:var entry) => CatalogEntryNode(
          label: node.label,
          entry: entry.id,
        ),
        CatalogBranch(:var children) => CatalogEntryNode(
          label: node.label,
          children: _treeNodes(children),
        ),
      },
  ];

  /// One entry, as the `entries` action reports it.
  ///
  /// The canvas is resolved here rather than left out because an unreported
  /// default is an invisible one: two entries in one package can be a phone and
  /// a desktop now, and a caller that cannot see which is which takes the wrong
  /// picture without anything looking wrong. [canvases] is passed in because
  /// the list is the package's and this runs once per entry.
  CatalogEntrySummary _summarise(
    String path,
    CatalogEntry entry,
    List<PreviewCanvas> canvases,
    EntryChange? change,
  ) {
    var canvas = canvasFor(canvases, entry.path);
    return CatalogEntrySummary(
      id: entry.id,
      name: entry.name,
      group: entry.group,
      change: change,
      // What every other surface identifies this by — hand it straight back to
      // `screenshot`, or later to `show`.
      address: '${addressFor(path, entry.id)}',
      device: canvas?.defaultDevice?.id,
      devices: [
        for (var device in canvas?.devices ?? const <Device>[]) device.id,
      ],
    );
  }

  /// Which entries the compiler can build, per package.
  ///
  /// The one question the scan cannot answer: it parses a file and finds an
  /// entry, but whether that entry *compiles* is a fact only the compiler
  /// holds. Until now only the panel could ask, because only the panel ran a
  /// daemon.
  ///
  /// One daemon at a time rather than all at once: each package's daemon may
  /// have to build a host binary, and two cold builds racing helps neither. A
  /// package that cannot be checked reports why in its own row instead of
  /// sinking the others.
  Future<CatalogCheckResult> _check(Map<String, Object?> arguments) async {
    var results = <CatalogPackageCheck>[];
    for (var path in _requestedPackages(arguments)) {
      try {
        var checked = await _headlessFor(path).check();
        results.add(
          CatalogPackageCheck(
            path: path,
            ok: checked.ok,
            servable: [for (var entry in checked.servable) entry.id],
            broken: [
              for (var broken in checked.quarantined)
                CatalogBrokenEntry(id: broken.entry.id, error: broken.error),
            ],
          ),
        );
      } catch (e) {
        results.add(CatalogPackageCheck(path: path, error: '$e'));
      }
    }
    return CatalogCheckResult(packages: results);
  }

  /// Everything known about one entry.
  ///
  /// The scan half is free. The knobs are not: a demo declares them by *asking*
  /// for them while it builds, so the only way to know is to compile it and run
  /// it — which is why `knobs` is opt-in and off by default. An agent deciding
  /// what to vary before a screenshot wants it; an agent listing entries does
  /// not.
  Future<CatalogEntryDescription> _describe(
    Map<String, Object?> arguments,
  ) async {
    var entryId = arguments['entry'];
    if (entryId is! String || entryId.isEmpty) {
      throw ArgumentError.value(entryId, 'entry', 'required');
    }
    if (_scans.isEmpty && _failures.isEmpty) await computeAll();

    var packagePath = _packageHolding(entryId);
    var entry = _scans[packagePath]!.entries.firstWhere((e) => e.id == entryId);

    CatalogEntryDescription describe({
      List<CatalogKnob>? knobs,
      List<CatalogKnob>? axes,
      String? shell,
    }) => CatalogEntryDescription(
      id: entry.id,
      name: entry.name,
      group: entry.group,
      package: packagePath,
      file: entry.path,
      symbol: entry.symbol,
      annotation: entry.annotation,
      address: '${addressFor(packagePath, entryId)}',
      knobs: knobs,
      axes: axes,
      shell: shell,
    );

    var wantsKnobs = arguments['with-knobs'] == true;
    var wantsAxes = arguments['with-axes'] == true;
    if (!wantsKnobs && !wantsAxes) return describe();

    // **One render for both**, which the comment here used to claim and the
    // code did not do: `axes` and `knobs` were a `_withGuest` each, so asking
    // for both compiled, launched and tore down two guests to read two
    // projections of the same build.
    //
    // And on the harness rather than the guest, because neither answer is a
    // picture: what a demo declares it declares by *building*, which is what
    // this lane does in tens of milliseconds against the guest's ~12.7s.
    var observed = await TesterRenderer(runner: testRunnerFor(packagePath))
        .render(
          CatalogRender(
            entryId: entryId,
            wantKnobs: wantsKnobs,
            wantAxes: wantsAxes,
          ),
        );
    var axisReport = observed.axes ?? AxisReport.empty;
    // An entry that declares none answers with an empty list: "it has no
    // knobs" and "we did not look" are different questions, and only one of
    // them was asked. Which is why the field is nullable and this is a list.
    return describe(
      knobs: wantsKnobs
          ? [
              for (var knob
                  in observed.knobs?.knobs ?? const <KnobDescriptor>[])
                _asKnob(knob),
            ]
          : null,
      axes: wantsAxes
          ? [for (var axis in axisReport.axes) _asKnob(axis)]
          : null,
      shell: axisReport.shellId,
    );
  }

  /// How one entry of [path] is framed during a whole-catalog run.
  ///
  /// Through the same funnel `screenshot` and `inspect` go through, and per
  /// entry rather than per run: a `device` in [arguments] wins for the whole
  /// catalog — that is how you ask whether everything survives a small phone —
  /// and where it is absent each entry falls back to the canvas its own subtree
  /// declared. An entry under none gets the plain rectangle, which is what
  /// every entry used to get unconditionally.
  @visibleForTesting
  (String?, String?, CaptureViewport) auditFramingFor(
    String path,
    String entryPath,
    Map<String, Object?> arguments,
  ) => framingFor(
    arguments,
    fallback: defaultFramingFor(path, entry: entryPath),
  );

  /// Every entry in every requested package, compiled and rendered.
  Future<CatalogAuditResult> _audit(Map<String, Object?> arguments) async {
    var paths = _requestedPackages(arguments);
    await Future.wait([for (var path in paths) _scan(path)]);

    var narrowTo = arguments['path'];
    if (narrowTo != null && narrowTo is! String) {
      throw ArgumentError.value(narrowTo, 'path', 'must be a path');
    }

    // Checked here and discarded, before anything is compiled — a misspelt
    // device is the same class of typo as a misspelt path below, and an audit
    // is the longest thing in this plugin to discover one halfway through.
    framingFor(arguments);

    // Resolved before anything is compiled, so a typo costs no build. An empty
    // match is refused rather than audited: `checked: 0, broken: 0` is what a
    // clean run looks like, and a flag that silently matched nothing would
    // report a repo green on the strength of a misspelling.
    Map<String, List<String>>? selected;
    if (narrowTo is String) {
      selected = {for (var path in paths) path: _entryIdsUnder(path, narrowTo)};
      if (selected.values.every((ids) => ids.isEmpty)) {
        throw ArgumentError.value(
          narrowTo,
          'path',
          'matches no entry in ${paths.join(', ')}. Ask `entries` what there '
              'is; a path names a directory or a file, not an entry id.',
        );
      }
    }

    var checked = 0;
    var network = 0;
    var rows = <CatalogAuditEntry>[];
    var unreachable = <CatalogAuditFailure>[];
    // One package at a time: each brings up a tester of its own, and two cold
    // compiles racing helps nobody. The same reason `check` gives.
    for (var path in paths) {
      var only = selected?[path];
      // Nothing under this package matched, and another package's did — so
      // there is nothing to do here rather than everything.
      if (only != null && only.isEmpty) continue;
      List<PreviewAuditRow> audited;
      try {
        _setBusy(path, const Status.info('rendering the catalog…'));
        audited = await testRunnerFor(path).audit(
          entryIds: only,
          // Validated above; passed on by id, because the harness resolves it
          // against the device table the *project* pins rather than this one.
          device: arguments['device'] as String?,
          orientation: arguments['orientation'] as String?,
          clock: host.projectClock,
        );
      } catch (e) {
        // Per package, exactly as `check` does it: one package that cannot host
        // a tester must not decide the answer for the others.
        unreachable.add(CatalogAuditFailure(package: path, error: '$e'));
        continue;
      } finally {
        _setBusy(path, null);
      }
      checked += audited.length;

      var byId = {
        for (var entry in _scans[path]?.entries ?? const <CatalogEntry>[])
          entry.id: entry,
      };
      for (var row in audited) {
        // Counted even on a green row: an audit that quietly set failures
        // aside would read as "covered everything" when the network half of
        // those entries was never checkable in this lane at all.
        if (row.errors.length != row.indicting.length) network++;
        if (row.ok) continue;
        var indicting = row.indicting;
        rows.add(
          CatalogAuditEntry(
            id: row.id,
            address: '${addressFor(path, row.id)}',
            compiles: row.compileError == null,
            compileError: row.compileError,
            // Which screen the overflow was on. An audit row that does not say
            // is unactionable twice over: a reader cannot tell whether the
            // entry was framed as its declaration intended, and cannot
            // reproduce the failure without guessing the device back.
            device: row.compileError != null
                ? null
                : auditFramingFor(path, byId[row.id]?.path ?? '', arguments).$1,
            errors: [
              // Only when the build reported nothing of its own. A failing
              // entry usually has both — the framework's error, and the test
              // runner's restatement of it — and listing the pair reports one
              // overflow twice under two spellings.
              if (indicting.isEmpty)
                if (row.failure case var failure?)
                  CatalogRenderError(exception: failure, count: 1),
              for (var error in indicting)
                _asRenderError(InspectError.fromJson(error)),
            ],
            stillWaitingOn: row.pending.isEmpty
                ? null
                : pendingWorkOf(row.pending),
          ),
        );
      }
    }

    return CatalogAuditResult(
      checked: checked,
      broken: rows.length,
      network: network,
      entries: rows,
      unreachable: unreachable,
    );
  }

  /// The ids in [packagePath] whose file sits at or under [narrowTo].
  ///
  /// An entry id is `<package-relative file>#<symbol>`, so narrowing to a
  /// directory or a file is a prefix test on the part before the `#`. Matched
  /// on whole segments — `demo/set` must not select `demo/settings/` — and
  /// tolerant of a worktree-relative path, since `app/demo/x.dart` is what a
  /// shell completes and `demo/x.dart` is what the id says.
  List<String> _entryIdsUnder(String packagePath, String narrowTo) {
    var wanted = p.normalize(narrowTo);
    var prefix = packagePath == '.' ? '' : '$packagePath/';
    if (prefix.isNotEmpty && wanted.startsWith(prefix)) {
      wanted = wanted.substring(prefix.length);
    }
    return [
      for (var entry in _scans[packagePath]?.entries ?? const <CatalogEntry>[])
        if (_isAtOrUnder(entry.path, wanted)) entry.id,
    ];
  }

  static bool _isAtOrUnder(String file, String directoryOrFile) {
    var target = p.normalize(directoryOrFile);
    if (target == '.' || target.isEmpty) return true;
    var normalized = p.normalize(file);
    return normalized == target || p.isWithin(target, normalized);
  }

  static CatalogRenderError _asRenderError(InspectError error) =>
      CatalogRenderError(
        exception: error.exception,
        library: error.library,
        context: error.context,
        count: error.count,
      );

  /// A declared control, flattened for the wire. Axes are [KnobDescriptor]s
  /// too — the same kind of thing with a different lifetime — so they flatten
  /// through here as well.
  static CatalogKnob _asKnob(KnobDescriptor knob) => CatalogKnob(
    name: knob.name,
    kind: knob.kind.name,
    value: knob.value,
    defaultValue: knob.defaultValue,
    min: knob.min,
    max: knob.max,
    options: knob.options,
  );

  /// Where [entryId]'s file is, relative to its package — what a canvas prefix
  /// is matched against. Null when the scan does not know it, which leaves
  /// [defaultFramingFor] asking what the package says with no subtree in mind.
  String? _entryPathOf(String packagePath, String entryId) {
    for (var entry in _scans[packagePath]?.entries ?? const <CatalogEntry>[]) {
      if (entry.id == entryId) return entry.path;
    }
    return null;
  }

  /// Which declared package holds [entryId].
  String _packageHolding(String entryId) => packages.firstWhere(
    (path) => _scans[path]?.entries.any((e) => e.id == entryId) ?? false,
    orElse: () => throw ArgumentError.value(
      entryId,
      'entry',
      'no entry with that id. Known: '
          '${entries.map((e) => e.id).take(10).join(', ')}'
          '${entries.length > 10 ? ', …' : ''}',
    ),
  );

  /// One rendered build, and every projection of it that was asked for.
  ///
  /// This replaced `tree`, `find`, `at` and `errors`, and the argument was
  /// never mainly about tidiness. They had the same inputs, the same
  /// precondition — the entry must be rendered first — and each paid a full
  /// compile, guest launch and render to answer one question about a frame the
  /// others also had to produce. Three questions was three renders. For an
  /// agent in a UI edit loop that is the dominant per-iteration cost, and a
  /// sixth (`logs`) and a seventh (`semantics`) were queued up to be added to
  /// the list by reflex.
  ///
  /// The second argument is consistency, and it is the deciding one.
  /// `screenshot --annotate` read its **own** tree, so a caller that ran `tree`
  /// and then `screenshot --annotate` got two trees out of two processes: the
  /// ids on the picture matched the ids in the tree because the build is
  /// deterministic, not because they were the same object. Closing that loop
  /// was the entire point of `--annotate`. Now one render produces one tree and
  /// every projection comes off it, and the assumption is gone rather than
  /// merely reliable.
  ///
  /// No flags is the "is it OK" answer — render, report what the framework
  /// said, nothing else. Everything heavier is opt-in, which is what the token
  /// measurements in the prior design already concluded: summary always,
  /// details on request, `find` before `tree`.
  Future<CatalogInspectResult> _inspect(Map<String, Object?> arguments) async {
    // Read and checked before anything is scanned or compiled. A typo in a flag
    // should cost nothing, and a compile-and-render is the most expensive thing
    // here.
    var want = _InspectRequest.of(arguments);
    if (_scans.isEmpty && _failures.isEmpty) await computeAll();
    var packagePath = _packageHolding(want.entryId);
    // Read again, now that the package the entry belongs to is known and its
    // declared framing can be applied. The first pass is what makes a typo in a
    // flag cost nothing — it runs before the scan — and the package default
    // cannot be looked up until the scan says which package this is. Parsing
    // twice is a few string splits against a compile and a render.
    want = _InspectRequest.of(
      arguments,
      fallback: defaultFramingFor(
        packagePath,
        entry: _entryPathOf(packagePath, want.entryId),
      ),
    );

    var address = _pixelAddress(
      packagePath: packagePath,
      entryId: want.entryId,
      deviceId: want.deviceId,
      orientationId: want.orientationId,
      viewport: want.viewport,
      knobs: want.knobs,
      axes: want.axes,
      debug: want.debug,
      node: want.node,
      annotate: want.annotate,
    );

    var observed = await _observe(want, packagePath, address);
    return _project(want, observed.$1, live: observed.$2, address: address);
  }

  /// Reads the entry, from the session a person is driving when they asked for
  /// that and it is showing this entry, and from a guest of its own otherwise.
  Future<(CatalogObservation, bool)> _observe(
    _InspectRequest want,
    String packagePath,
    Address address,
  ) async {
    var open = await _withLiveGuest(
      packagePath,
      want.entryId,
      live: want.mayAttach,
      body: (inspect, tree) async => CatalogObservation(
        // Handed over rather than read again: `_withLiveGuest` reads it to
        // decide the session is showing this entry at all, and a second read
        // would be a second build's worth of truth.
        tree: tree,
        errors: await inspect.errors(want.entryId) ?? InspectErrors.empty,
        logs: want.logs ? await inspect.logs(want.entryId) : null,
        hits: want.at == null
            ? null
            : await inspect.hitTest(
                want.at!.$1.toDouble(),
                want.at!.$2.toDouble(),
              ),
      ),
    );
    if (open != null) return (open, true);

    return (
      await _rendererFor(
        packagePath,
        engine: want.engine,
        wantsLogs: want.logs,
      ).render(
        CatalogRender(
          entryId: want.entryId,
          viewport: want.viewport,
          knobs: want.knobs,
          axes: want.axes,
          debug: want.debug,
          // Only what the *caller* asked about. A tree needed to resolve a hit,
          // a crop or an annotation is `CatalogRender.needsTree`'s business,
          // which is why that is on the request rather than worked out here:
          // every backend has to make the same decision, and one that made it
          // differently would answer a question nobody could see it had been
          // asked.
          wantTree:
              want.tree || want.query != null || want.screen || want.styles,
          wantLogs: want.logs,
          at: want.at == null
              ? null
              : (want.at!.$1.toDouble(), want.at!.$2.toDouble()),
          screenshot: want.picture
              ? _outputFor(want, packagePath, address)
              : null,
          annotate: want.annotate,
          cropNode: want.node,
        ),
      ),
      false,
    );
  }

  /// Where the PNG goes: what was asked for, or a path derived from the address.
  ///
  /// Derived exactly as `screenshot` derives it, so asking twice with the same
  /// flags overwrites one file and asking with different flags does not.
  String _outputFor(
    _InspectRequest want,
    String packagePath,
    Address address,
  ) => switch (want.output) {
    var given? when given.isNotEmpty =>
      p.isAbsolute(given) ? given : p.join(host.worktree.path, given),
    _ => p.join(
      host.worktree.path,
      packagePath,
      'build',
      'catalog',
      'screenshots',
      _defaultFileName(address),
    ),
  };

  /// One observation, projected into whatever was asked about it.
  CatalogInspectResult _project(
    _InspectRequest want,
    CatalogObservation observed, {
    required bool live,
    required Address address,
  }) {
    var tree = observed.tree;
    // `find`, `at` and `styles` run over the *filtered* tree, exactly as the
    // run plugin runs them: the framework wrappers are never the answer to
    // any of the three, and an unfiltered chain under a point is twenty nodes
    // of root scaffolding before it reaches anything the preview drew.
    var narrowed = tree?.filtered(const InspectFilter());
    var hits = observed.hits == null
        ? null
        : [for (var id in observed.hits!) ?narrowed?.nodeAt(id)];
    var elided = hits == null || hits.length <= ScreenRead.chainDepth
        ? 0
        : hits.length - ScreenRead.chainDepth;
    var projected = want.screen && tree != null
        ? Screen.tryOf(tree)
        : (screen: null, note: null);
    return CatalogInspectResult(
      entry: want.entryId,
      address: '$address',
      readFrom: switch (live) {
        true => 'live',
        false when _onGuest(engine: want.engine, wantsLogs: want.logs) =>
          'guest',
        false => 'harness',
      },
      lens: want.lens.name,
      ok: observed.errors.isEmpty,
      // `ok` is answered whatever else was asked, so the list that explains it
      // is too — a caller told `ok: false` with no list has been told nothing it
      // can act on. Suppressed only when explicitly switched off.
      errors: want.errors
          ? [for (var error in observed.errors.errors) _asRenderError(error)]
          : const [],
      tree: want.tree && tree != null
          ? _asNodes(_scoped(tree, want.node, want.depth, want.entryId))
          : null,
      // The screen, which with no other flag is now the answer: what
      // rendered, as a nested list of the things carrying words or responding
      // to touch, rather than only the news that something did.
      screen: projected.screen,
      note: projected.note,
      styles: want.styles ? narrowed?.styles() : null,
      nodes: narrowed?.length,
      next: ScreenRead.offer,
      find: want.query == null || narrowed == null
          ? null
          : _asNodes(
              narrowed
                  .matching(want.query!)
                  .take(ScreenRead.findLimit)
                  .toList(),
            ),
      // Present-and-empty when the point missed, which is an answer: there is
      // nothing of the demo's there. A caller that probed outside the viewport
      // wants to see that it missed rather than that it did not ask.
      at: hits == null ? null : _asNodes(hits.sublist(elided)),
      atOuterElided: elided == 0 ? null : elided,
      logs: switch (observed.logs) {
        var report? => [for (var line in report.lines) line.text],
        null => null,
      },
      logsDropped: switch (observed.logs) {
        InspectLogs(dropped: var n) when n > 0 => n,
        _ => null,
      },
      // **An artifact, not a path.** `screenshot` has always handed back one,
      // and a picture produced here is the same kind of thing: it has an
      // identity, and something downstream will want to file it. Handing back a
      // bare string would have made this the one place in the surface where a
      // PNG is less than an artifact.
      screenshot: switch (observed.screenshot) {
        var file? => Artifact(
          kind: Artifact.png,
          address: address,
          // Worktree-relative, so the value survives being read on another
          // machine and an agent whose tools are scoped to the repo can open it.
          path: p.relative(file.path, from: host.worktree.path),
        ),
        null => null,
      },
    );
  }

  /// `tree` narrowed by `--node` and `--depth`.
  ///
  /// The depth is counted from the *reported* root rather than from the demo's,
  /// so `--node=0/1 --depth=1` means one level below that node — which is what
  /// anybody asking for both would mean by it.
  ///
  /// Offstage subtrees are folded to their top node, which is reported with
  /// `offstage: true` and nothing under it — a covered route is most of a
  /// tree's tokens and none of its picture. Naming that node with `--node` is
  /// the way in: a caller pointing *at* hidden content has asked for it.
  List<InspectNode> _scoped(
    InspectTree tree,
    String? node,
    Object? depth,
    String entryId,
  ) {
    var root = tree.root;
    var offset = 0;
    if (node != null) {
      // The same grammar `screenshot` crops with — a name or an id — so one
      // value means one thing wherever it is passed. Several matches narrow to
      // the outermost rather than refusing: unlike a crop, a tree read that
      // included too much is something the reader can see and step past, and
      // the alternative is a refusal for the ordinary case of a widget that
      // appears twice on a page.
      var found = tree.resolve(node);
      if (found.isEmpty) {
        throw ArgumentError.value(
          node,
          'node',
          'nothing in $entryId is called that, and it is not the id of a node '
              'either. `node` takes a widget name — `SplitButton`, `Save` — or '
              'an id from an earlier read. Ids are positions in the tree, so '
              'one taken before an edit may name nothing now.',
        );
      }
      var subtree = found.reduce(
        (a, b) => _depthOf(a.id) <= _depthOf(b.id) ? a : b,
      );
      root = subtree;
      offset = _depthOf(subtree.id);
    }
    if (root == null) return const [];
    return [
      for (var found in root.nodesFoldingOffstage)
        if (switch (depth) {
          int max => _depthOf(found.id) - offset <= max,
          _ => true,
        })
          found,
    ];
  }

  /// `--at=120,300`.
  ///
  /// One parameter rather than the `--x`/`--y` pair it replaced: a point is one
  /// thing, and two required integers that are only meaningful together are two
  /// ways to get it half-wrong.
  static (int, int)? _parsePoint(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw ArgumentError.value(value, 'at', 'a point, written `x,y`');
    }
    var parts = value.split(',');
    var x = parts.length == 2 ? int.tryParse(parts[0].trim()) : null;
    var y = parts.length == 2 ? int.tryParse(parts[1].trim()) : null;
    if (x == null || y == null) {
      throw ArgumentError.value(
        value,
        'at',
        'a point, written `x,y` — two whole numbers in the coordinates a '
            'screenshot is taken in, as `120,300`',
      );
    }
    return (x, y);
  }

  /// Every node in the reply's shape, layout formatted for a reader.
  List<CatalogTreeNode> _asNodes(List<InspectNode> nodes) {
    // Project-relative, because an absolute URI in a terminal is mostly the
    // same forty characters over and over — and the consumer's file tools are
    // scoped to the worktree anyway.
    var worktree = host.worktree.path;
    return [
      for (var node in nodes)
        CatalogTreeNode(
          id: node.id,
          type: node.type,
          depth: _depthOf(node.id),
          description: node.description,
          source: node.source?.describe(relativeTo: worktree),
          local: node.createdByLocalProject,
          // Sparse: nearly every node is on stage. In `tree` this is the top
          // of a folded subtree; in `matches` it warns that the found widget
          // is not on the picture.
          offstage: node.offstage ? true : null,
          // Formatted here rather than carried as four numbers: the consumer
          // is a terminal or a model, and `12.0,40.0 200.0×48.0` is one
          // glance where four fields are four.
          rect: switch (node.layout) {
            var l? => '${_n(l.x)},${_n(l.y)} ${_n(l.width)}×${_n(l.height)}',
            null => null,
          },
          constraints: node.layout?.constraints?.describe(),
          flex: switch (node.layout?.flex) {
            var f? => [
              f.direction,
              ?f.mainAxisAlignment,
              ?f.crossAxisAlignment,
              ?f.mainAxisSize,
            ].join(', '),
            null => null,
          },
          flexChild: switch (node.layout) {
            InspectLayout(flexFactor: var factor?, :var flexFit) =>
              flexFit == null ? 'flex $factor' : 'flex $factor ($flexFit)',
            _ => null,
          },
        ),
    ];
  }

  /// A node's depth, read off its id — `0/1/2` is three below the root.
  static int _depthOf(String id) => id.isEmpty ? 0 : id.split('/').length;

  /// Layout arrives as doubles and is nearly always whole pixels, so `48` beats
  /// `48.0` and `47.5` still says so.
  static String _n(double value) => value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);

  /// Whether this call may read the session a person is driving, rather than
  /// rendering its own copy.
  static bool _mayAttach({
    required Object? live,
    required Map<String, String> knobs,
    required Map<String, String> axes,
    required Map<String, String> debug,
    required bool wantsPicture,
    required bool reframed,
  }) =>
      // Opt-in. Reading a window somebody is using answers questions nothing
      // else can, and it makes the same command answer differently depending on
      // whether that window is open — which is the wrong default for CI and for
      // a caller that did not know to look.
      live == true &&
      // Everything below is a refusal even when asked, because each of these
      // would reach past this call's business and change what the person is
      // looking at: knobs and axes are pushed into whichever guest answers, a
      // debug flag changes the guest process, and a different device or size
      // reframes the window. A picture is refused for the opposite reason —
      // there is nothing to take one from, since an attached session offers a VM
      // service and no frames.
      knobs.isEmpty &&
      axes.isEmpty &&
      debug.isEmpty &&
      !wantsPicture &&
      !reframed;

  /// Runs [body] against the guest a person has open, when there is one and it
  /// is **already showing** [entryId].
  ///
  /// Null means "render your own", and every path to it is a deliberate
  /// refusal rather than a failure: [live] is off; nothing is published for
  /// this package; the published handle will not connect, in which case it is
  /// deleted on the way past; or the session is showing a different entry.
  ///
  /// It never switches the guest, which is the whole safety property. This
  /// reads what is on screen or it declines — it does not put something on
  /// screen. A person watching their own window sees nothing happen.
  ///
  /// The tree that decided all this is handed to [body] rather than read
  /// again: it is both the liveness check and the answer, and a second read
  /// would be a second build's worth of truth.
  Future<T?> _withLiveGuest<T>(
    String packagePath,
    String entryId, {
    required bool live,
    required Future<T> Function(InspectClient inspect, InspectTree tree) body,
  }) async {
    if (!live) return null;
    var vmService = await attachToLiveSession(
      p.join(host.worktree.path, packagePath),
    );
    if (vmService == null) return null;
    try {
      var inspect = InspectClient(vmService, patience: InspectPatience.glance);
      var tree = await inspect.tree(entryId);
      if (tree == null || tree.root == null) return null;
      return await body(inspect, tree);
    } finally {
      await vmService.close();
    }
  }

  /// Which engine renders a call, and why.
  ///
  /// **The harness by default, the guest when the call needs it.** Measured
  /// 2026-08-27 on this repo's catalog, a guest render is ~12.7s of
  /// daemon-connect, whole-kernel compile, spawn and teardown against a warm
  /// harness's tens of milliseconds — and the harness is reproducible, which
  /// the guest is not: under FakeAsync the same entry renders byte-identically
  /// where the guest photographs whatever real instant its socket round trip
  /// lands on. That the two agree about the *layout* is not assumed, it is
  /// pinned (`app/test/previews/lane_parity_test.dart`).
  ///
  /// Two things send a call to the guest anyway, and both are named in the
  /// answer rather than guessed at by the caller:
  ///
  /// - **`logs`.** A demo's `print` inside a widget test rides the runner's
  ///   own message stream, not the zone `GuestLogs` wraps, so the harness has
  ///   nothing to collect. Refusing would be the other option and is worse: a
  ///   flag that worked yesterday would stop, to save a caller from a slower
  ///   answer it did not ask about.
  /// - **`engine=guest`**, said out loud. The escape hatch is not decoration:
  ///   with everything else on the harness, this is what still exercises the
  ///   embedder outside the panel, and what settles an argument about which
  ///   lane is wrong when the parity check is not enough.
  CatalogRenderer _rendererFor(
    String packagePath, {
    Object? engine,
    bool wantsLogs = false,
  }) {
    if (engine != null && engine != 'guest' && engine != 'harness') {
      throw ArgumentError.value(
        engine,
        'engine',
        'no such engine. Accepted: harness, guest',
      );
    }
    if (engine == 'guest' || wantsLogs) return _headlessFor(packagePath);
    return TesterRenderer(runner: testRunnerFor(packagePath));
  }

  /// Whether [engine] and the request between them put this call on the guest.
  bool _onGuest({Object? engine, bool wantsLogs = false}) =>
      engine == 'guest' || wantsLogs;

  /// The headless pipeline for one declared package.
  ///
  /// The config comes from [DaemonConfig.forPackage] so that this and the GUI's
  /// [CatalogSession] derive the same [DaemonAddress] — which is what makes
  /// `fw` and a panel two drivers of one daemon rather than two daemons.
  HeadlessCatalog _headlessFor(String packagePath) => HeadlessCatalog(
    dartExecutable: p.join(host.workspace.flutterSdk.root, 'bin', 'dart'),
    config: DaemonConfig.forPackage(
      appToolDirectory: host.workspace.appContext.appToolDirectory.path,
      packageRoot: p.join(host.worktree.path, packagePath),
      flutterSdkRoot: host.workspace.flutterSdk.root,
      roots: [rootFor(packagePath)],
      previewAnnotations: previewAnnotationsFor(packagePath),
      clock: host.projectClock,
    ),
  );

  /// Renders one entry to a PNG.
  ///
  /// Runs the whole pipeline headlessly, so the button, `fw` and an agent all
  /// reach the same artifact by the same route.
  ///
  /// Returns an [Artifact] rather than a path: a PNG that cannot say which
  /// entry it is of, at which size, is not reproducible — you cannot ask for
  /// the same picture again from the file alone. The [Address] it carries is
  /// exactly that question's answer.
  ///
  /// Scans on demand when nothing has yet: an agent naming an entry it read
  /// from a previous call should not have to know that the process it is
  /// talking to is a fresh one.
  Future<Artifact> _screenshot(Map<String, Object?> arguments) async {
    var entryId = arguments['entry'];
    if (entryId is! String || entryId.isEmpty) {
      throw ArgumentError.value(entryId, 'entry', 'required');
    }

    if (_scans.isEmpty && _failures.isEmpty) await computeAll();

    var packagePath = _packageHolding(entryId);
    var packageRoot = p.join(host.worktree.path, packagePath);
    var entry = _scans[packagePath]!.entries.firstWhere((e) => e.id == entryId);

    var (deviceId, orientationId, viewport) = framingFor(
      arguments,
      fallback: defaultFramingFor(packagePath, entry: entry.path),
    );

    var knobs = parsePairs(arguments['knobs']);
    var axes = parsePairs(arguments['axes']);
    var debug = parsePairs(arguments['debug']);
    var node = arguments['node'];
    if (node != null && node is! String) {
      throw ArgumentError.value(
        node,
        'node',
        'must be text — a widget name or a node id',
      );
    }
    var annotate = arguments['annotate'] == true;

    var address = _pixelAddress(
      packagePath: packagePath,
      entryId: entryId,
      deviceId: deviceId,
      orientationId: orientationId,
      viewport: viewport,
      knobs: knobs,
      axes: axes,
      debug: debug,
      node: node as String?,
      annotate: annotate,
    );

    var output =
        arguments['output'] as String? ??
        p.join(
          packageRoot,
          'build',
          'catalog',
          'screenshots',
          _defaultFileName(address),
        );

    var captured = await _rendererFor(packagePath, engine: arguments['engine'])
        .capture(
          CatalogRender(
            entryId: entryId,
            screenshot: output,
            viewport: viewport,
            knobs: knobs,
            axes: axes,
            debug: debug,
            cropNode: node,
            annotate: annotate,
          ),
        );

    return Artifact(
      kind: Artifact.png,
      address: address,
      // Relative to the worktree root, so the value survives being read on
      // another machine — and so an agent whose tools are scoped to the repo
      // can open it.
      path: p.relative(captured.file.path, from: host.worktree.path),
      meta: {
        'name': entry.name,
        'group': ?entry.group,
        'package': packagePath,
        'bytes': captured.file.lengthSync(),
        // What the entry reported after the values landed. A demo may clamp
        // one, and a caller comparing this with what it asked for is the only
        // way to notice.
        if (captured.knobs.isNotEmpty)
          'knobs': {for (var knob in captured.knobs) knob.name: knob.value},
      },
    );
  }

  /// Knob values, however they arrived.
  ///
  /// A map when an agent sent JSON, a string when a shell did — `fw` has no
  /// types to pass and no repeatable flags, so `name=value,name=value` is the
  /// form that survives a command line. A JSON object in that string works
  /// too, since an agent writing one is not wrong to expect it to.
  ///
  /// Values stay strings here: only the guest knows what kind each knob is,
  /// and guessing at this end would make `count=5` an int for one demo and a
  /// string for another.
  static Map<String, String> parsePairs(Object? value) {
    if (value == null) return const {};
    if (value is Map) {
      return {
        for (var entry in value.entries) '${entry.key}': '${entry.value}',
      };
    }
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError.value(value, 'knobs', 'expected name=value pairs');
    }

    if (value.trimLeft().startsWith('{')) {
      var decoded = jsonDecode(value.trim());
      if (decoded is! Map) {
        throw ArgumentError.value(value, 'knobs', 'expected a JSON object');
      }
      return parsePairs(decoded);
    }

    // Names are trimmed, values never: `label= x ` sets a string knob to a
    // value with spaces in it, which is a legitimate thing to want to look at.
    // So the argument as a whole is not trimmed either — the trailing space of
    // the last pair belongs to it.
    var knobs = <String, String>{};
    for (var pair in value.split(',')) {
      var equals = pair.indexOf('=');
      if (equals <= 0 || pair.substring(0, equals).trim().isEmpty) {
        throw ArgumentError.value(
          pair,
          'knobs',
          'expected name=value, separated by commas',
        );
      }
      knobs[pair.substring(0, equals).trim()] = pair.substring(equals + 1);
    }
    return knobs;
  }

  /// A file name that differs whenever the address does.
  ///
  /// The axes are in it because they are part of the address: capturing the
  /// same entry at two sizes used to write both to one path, so the second
  /// silently overwrote the first and two different addresses pointed at one
  /// file. An artifact that cannot be told apart from another artifact is not
  /// reproducible, which is the whole reason it carries an address.
  static String _defaultFileName(Address address) {
    var slug = _slug(address.segments.join('_'));
    var axes = address.axes.entries
        .map((axis) => '${_slug(axis.key)}-${_slug(axis.value)}')
        .join('_');
    return axes.isEmpty ? '$slug.png' : '${slug}__$axes.png';
  }

  static String _slug(String value) =>
      value.replaceAll(RegExp('[^A-Za-z0-9]+'), '_');

  /// Accepts an `int` or the string a CLI flag arrives as.
  /// The identity of one **picture**: everything that changed the pixels.
  ///
  /// Shared by `screenshot` and `inspect`, and it has to be. They can now
  /// produce the same PNG from the same flags, and the default output path is
  /// derived from this address — so two builders means the same picture lands in
  /// two filenames. Which is not hypothetical: `inspect` was written with its
  /// own copy and it omitted one of the framing keys, so the two disagreed the
  /// moment both could take a `--device`.
  ///
  /// Recording the size the capture actually *ran* at — rather than only a size
  /// someone asked for — is what lets the same frame be requested again.
  ///
  /// Every family is prefixed. A demo may declare a knob called `width`, and a
  /// shell an axis called `width`; an address where either quietly overwrote the
  /// viewport would name a picture nobody took.
  Address _pixelAddress({
    required String packagePath,
    required String entryId,
    required String? deviceId,
    required String? orientationId,
    required CaptureViewport viewport,
    required Map<String, String> knobs,
    required Map<String, String> axes,
    required Map<String, String> debug,
    required String? node,
    required bool annotate,
  }) => addressFor(
    packagePath,
    entryId,
    axes: {
      // The word the GUI reads, so an address that came out of a capture reopens
      // framed the way it was shot. Without it the two surfaces describe the
      // same picture in different vocabularies and the round-trip silently
      // loses the framing.
      'device': ?deviceId,
      // Absent for portrait, so an address written before orientation existed
      // and one written now are the same string for the same picture.
      'orientation': ?orientationId,
      // And absent for `auto`, which is what an address that says nothing has
      // always meant. Read off the viewport rather than passed in beside it:
      // the mode is part of what the guest was staged with, so there is one
      // copy of it and the picture and the address cannot disagree.
      if (viewport.keyboardMode != KeyboardMode.auto)
        'keyboard': viewport.keyboardMode.name,
      'width': '${viewport.width}',
      'height': '${viewport.height}',
      for (var knob in knobs.entries) 'knob.${knob.key}': knob.value,
      for (var axis in axes.entries) 'axis.${axis.key}': axis.value,
      // On the address for the same reason as the rest: a picture taken with the
      // layout guides drawn is not the same picture.
      for (var flag in debug.entries) 'debug.${flag.key}': flag.value,
      // Both change the pixels, so both belong on the identity — a crop of one
      // node and a crop of another are two artifacts, not one file written
      // twice.
      'node': ?node,
      if (annotate) 'annotate': 'true',
    },
  );

  /// How `--device`, `--width` and `--height` become a viewport.
  ///
  /// Shared by `screenshot` and `inspect` so the two cannot disagree about what
  /// `iphone15` means — which they would eventually, being two copies of a table
  /// lookup and a pair of overrides.
  ///
  /// Named rather than defaulted, and refused rather than approximated. A device
  /// this build does not know is the one failure that has to be loud: quietly
  /// framing as the panel produces a PNG that is wrong without looking wrong,
  /// and something downstream files it as evidence.
  ///
  /// [fallback] is what the package declared — see [defaultFramingFor]. It is
  /// applied here rather than at each caller so that the argument checking, the
  /// rotation and the address all see one device: a default resolved later
  /// would frame the picture and leave the address saying nothing, and two
  /// different framings would share one file name.
  @visibleForTesting
  static (String?, String?, CaptureViewport) framingFor(
    Map<String, Object?> arguments, {
    ({Device? device, ScreenOrientation? orientation, KeyboardMode? keyboard})
    fallback = (
      device: null,
      orientation: null,
      keyboard: null,
    ),
  }) {
    var deviceId = arguments['device'] ?? fallback.device?.id;
    if (deviceId != null && (deviceId is! String || !isDeviceId(deviceId))) {
      throw ArgumentError.value(
        deviceId,
        'device',
        'no such device. Accepted: ${deviceIds.join(', ')}',
      );
    }
    // Only when the device is the declared one too: an orientation belongs to
    // the device it turns, so a caller naming a phone should not inherit the
    // landscape the project declared for its tablet.
    var orientationId =
        arguments['orientation'] ??
        (arguments['device'] == null ? fallback.orientation?.name : null);
    if (orientationId != null &&
        (orientationId is! String || !isOrientationId(orientationId))) {
      throw ArgumentError.value(
        orientationId,
        'orientation',
        'no such orientation. Accepted: ${orientationIds.join(', ')}',
      );
    }
    // Only with the device, like the orientation: a keyboard belongs to the
    // subtree that declared it, and it is the same declaration.
    var keyboardId =
        arguments['keyboard'] ??
        (arguments['device'] == null ? fallback.keyboard?.name : null);
    if (keyboardId != null &&
        (keyboardId is! String || !isKeyboardModeId(keyboardId))) {
      throw ArgumentError.value(
        keyboardId,
        'keyboard',
        'no such keyboard mode. Accepted: ${keyboardModeIds.join(', ')}',
      );
    }
    // Width and height still win where they are given: they are how you ask for
    // a size no device has, and on a device they stretch its screen rather than
    // dropping its ratio and its notch.
    // `fit` names the panel and resolves to no device, which is the same
    // viewport by a different route.
    // Rotated before it becomes a viewport, which is the one place this has to
    // happen: everything past here is four numbers and a ratio.
    var device = (deviceId is String ? deviceById(deviceId) : null)?.oriented(
      orientationId is String ? orientationById(orientationId) : null,
    );
    var viewport = device == null
        ? CaptureViewport.panel
        : CaptureViewport.of(device);
    return (
      deviceId as String?,
      // Only a departure travels: portrait is what an address that says nothing
      // already means, and writing it would churn every link saved so far.
      orientationId == ScreenOrientation.landscape.name &&
              (device?.canRotate ?? false)
          ? orientationId as String?
          : null,
      viewport
          .withKeyboard(
            keyboardId is String
                ? keyboardModeById(keyboardId)!
                : KeyboardMode.auto,
          )
          .resized(
            width: _intArgument(arguments, 'width'),
            height: _intArgument(arguments, 'height'),
          ),
    );
  }

  static int? _intArgument(Map<String, Object?> arguments, String key) {
    var value = arguments[key];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}

PluginCore uiCatalogCoreFactory(PluginHost host) => PreviewsCore(host);

/// What one `inspect` call asked for, read and checked once.
///
/// Its own type because the handler had fifteen locals, and a function that
/// parses arguments, chooses a source and projects a result in one breath is a
/// function nobody can review — which is how `--debug` came to be declared and
/// passed nowhere.
///
/// Everything here is validated in the constructor, before the caller's request
/// has cost a scan or a compile. A typo in a flag should cost nothing.
class _InspectRequest {
  _InspectRequest._({
    required this.entryId,
    required this.tree,
    required this.logs,
    required this.errors,
    required this.query,
    required this.at,
    required this.node,
    required this.depth,
    required this.picture,
    required this.screen,
    required this.styles,
    required this.lens,
    required this.annotate,
    required this.output,
    required this.deviceId,
    required this.orientationId,
    required this.viewport,
    required this.knobs,
    required this.axes,
    required this.debug,
    required this.mayAttach,
    required this.engine,
  });

  /// Which engine to render on when the live session is not the answer — null
  /// for the default, `guest` to say it out loud. See
  /// [PreviewsCore._rendererFor].
  final Object? engine;

  factory _InspectRequest.of(
    Map<String, Object?> arguments, {
    ({Device? device, ScreenOrientation? orientation, KeyboardMode? keyboard})
    fallback = (
      device: null,
      orientation: null,
      keyboard: null,
    ),
  }) {
    var entryId = arguments['entry'];
    if (entryId is! String || entryId.isEmpty) {
      throw ArgumentError.value(entryId, 'entry', 'required');
    }
    var knobs = PreviewsCore.parsePairs(arguments['knobs']);
    var axes = PreviewsCore.parsePairs(arguments['axes']);
    var debug = PreviewsCore.parsePairs(arguments['debug']);
    var (deviceId, orientationId, viewport) = PreviewsCore.framingFor(
      arguments,
      fallback: fallback,
    );
    var lens = switch (arguments['lens']) {
      String name when name.isNotEmpty =>
        ObserveLens.byName(name) ??
            (throw ArgumentError.value(
              name,
              'lens',
              ObserveLens.unknown(name),
            )),
      _ => ObserveLens.act,
    };
    // The lens sets what nobody said; an explicit flag always beats it. A
    // preset that overrode what the caller actually wrote would be a trap.
    var picture = arguments['screenshot'] == null
        ? lens.picture
        : arguments['screenshot'] == true;

    return _InspectRequest._(
      entryId: entryId,
      tree: arguments['tree'] == null ? lens.tree : arguments['tree'] == true,
      logs: arguments['logs'] == true,
      errors: arguments['errors'] != false,
      query: switch (arguments['find']) {
        String q when q.isNotEmpty => q,
        null || '' => null,
        var other => throw ArgumentError.value(other, 'find', 'must be text'),
      },
      at: PreviewsCore._parsePoint(arguments['at']),
      node: switch (arguments['node']) {
        String id when id.isNotEmpty => id,
        _ => null,
      },
      depth: arguments['depth'],
      picture: picture,
      screen: arguments['screen'] != false,
      styles: arguments['styles'] == null
          ? lens.styles
          : arguments['styles'] == true,
      lens: lens,
      annotate: arguments['annotate'] == true,
      output: arguments['output'] as String?,
      deviceId: deviceId,
      orientationId: orientationId,
      viewport: viewport,
      knobs: knobs,
      axes: axes,
      debug: debug,
      mayAttach: PreviewsCore._mayAttach(
        live: arguments['live'],
        knobs: knobs,
        axes: axes,
        debug: debug,
        wantsPicture: picture,
        reframed: deviceId != null || viewport != CaptureViewport.panel,
      ),
      engine: arguments['engine'],
    );
  }

  final String entryId;

  /// Which projections were asked for. `errors` is the one that defaults on:
  /// with no flags at all it is the whole answer.
  final bool tree;
  final bool logs;
  final bool errors;
  final bool picture;

  /// The screen — what is on it, what can be acted on, how it is laid out.
  /// On by default, and the reason a no-flag `inspect` now says what
  /// rendered rather than only that something did.
  final bool screen;

  /// Every distinct text style, most-used first.
  final bool styles;

  /// The preset the unset flags came from. Named on every reply, because a
  /// caller who does not know a picture was available cannot ask for one.
  final ObserveLens lens;

  final String? query;
  final (int, int)? at;
  final String? node;
  final Object? depth;
  final bool annotate;

  /// Where to write the picture, as the caller wrote it. Resolving it needs the
  /// worktree and the address, so that happens on the core.
  final String? output;

  final String? deviceId;

  /// `landscape`, or null for the portrait every other value means.
  final String? orientationId;

  final CaptureViewport viewport;
  final Map<String, String> knobs;
  final Map<String, String> axes;
  final Map<String, String> debug;

  /// Whether this call may read an already-open window — decided here so
  /// that the reasons sit beside the flags they are about.
  final bool mayAttach;
}

/// A package's syntactic scan — see [PreviewsCore.new].
typedef CatalogScan = Future<ScanResult> Function({
  required String projectRoot,
  required List<String> roots,
  required List<String> previewAnnotations,
});
