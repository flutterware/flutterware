import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/plugins.dart';
import 'package:path/path.dart' as p;

import '../../address/address_scope.dart';
import '../../embedder/embedded_engine.dart';
import '../../previews/authoring.dart';
import '../../previews/catalog_devices.dart';
import '../../previews/catalog_session.dart';
import '../../previews/catalog_view.dart';
import '../../previews/compiler_daemon_client.dart';
import '../../previews/discovery.dart';
import '../../previews/new_preview_dialog.dart';
import '../../previews/web_build_dialog.dart';
import '../../previews/web_server.dart';
import '../native_plugin.dart';
import 'previews_address.dart';
import '../../comparison/shot_cache.dart';
import '../../previews/thumbnail_keys.dart';
import '../../previews/thumbnails.dart';
import '../../utils/run_dir.dart';
import 'previews_core.dart';
import '../../ui/design/design.dart';
import '../../ui/loading_state.dart';
import '../../ui/startup_progress.dart';
import '../../embedder/tester_phase.dart';
import 'no_packages.dart';

export 'previews_core.dart' show PreviewsCore, uiCatalogPluginId;

/// The GUI half of Previews: the live compile loop, and a panel.
///
/// Everything else — the scan, the entry list, the report, `rescan` and
/// `screenshot` — lives in [PreviewsCore], which is pure Dart, so `fw` and an
/// agent reach exactly the same behaviour. What stays here is
/// [CatalogSession]: it drives a guest engine into a texture, which is
/// Flutter-bound by nature.
///
/// The session is owned by the plugin rather than the panel so that leaving the
/// panel does not throw away a running daemon — and so the sidebar can say what
/// the compiler is doing while you are looking elsewhere. That progress reaches
/// the report through [PreviewsCore.busyStatusFor].
class PreviewsPlugin extends NativePlugin<PreviewsCore> {
  PreviewsPlugin(
    super.core, {
    this.connectToDaemon = CompilerDaemonClient.connector,
    this.launchGuest = launchEmbeddedGuest,
    this.thumbnails = true,
  }) {
    core
      ..busyStatusFor = _busyStatusFor
      ..onRescanned = ((path) => _thumbnails[path]?.invalidate())
      ..onRunnerPhase = ((path, reading) =>
          startupFor(path).report('harness', _harnessTask(reading)));
  }

  /// How the sessions this builds reach a compiler — see
  /// [CatalogSession.connectToDaemon], which already exists for the same
  /// reason and is simply threaded through here.
  ///
  /// Nothing in production passes it. It exists so a test can mount
  /// this panel: the real connect compiles a snapshot and spawns a process, so
  /// without a seam the only way to exercise the panel's own wiring is not to
  /// exercise it.
  final DaemonConnector connectToDaemon;

  /// How each session's guest is brought up — see
  /// [CatalogSession.launchGuest]. The embedder process by default; a guest
  /// drawn inline where none can be spawned.
  final GuestLauncher launchGuest;

  /// Whether the landing page gets pictures. They are rendered by
  /// `flutter_tester`, which a host with no processes cannot run; off, the
  /// landing shows the guest itself.
  final bool thumbnails;

  final _sessions = <String, CatalogSession>{};

  /// Each package's photographed previews, for the list's hover popover.
  ///
  /// Here rather than on the core, which is pure Dart because `fw` and the
  /// MCP server link it — a cache of `dart:ui` images is exactly what the
  /// purity guardrail exists to keep out. Here rather than on the *session*
  /// too: a session is built fresh every time the panel is mounted, and a
  /// picture is worth keeping past that, because the harness behind it costs a
  /// compile of the whole catalog to bring up.
  final _thumbnails = <String, PreviewThumbnails>{};

  /// What each package's start is doing, merged across its two lanes.
  ///
  /// Here rather than on the session, and for the same reason the pictures are:
  /// a session is rebuilt every time the panel is mounted, and one of the two
  /// lanes reporting into this — the harness — is neither started nor stopped
  /// by the panel being open.
  final _startups = <String, StartupProgress>{};

  /// [path]'s merged progress, created on first use.
  StartupProgress startupFor(String path) =>
      _startups.putIfAbsent(path, StartupProgress.new);

  /// [path]'s photographed previews, started on first use.
  ///
  /// Given the **machine's** shot store rather than one of its own, which is
  /// the same store a comparison files under and for the same reason: a key
  /// says everything about a picture, so five worktrees off one commit render
  /// the catalog once between them and a restart re-renders nothing at all.
  PreviewThumbnails? thumbnailsFor(String path) => !thumbnails
      ? null
      : _thumbnails.putIfAbsent(
          path,
          () => PreviewThumbnails.of(
            core.testRunnerFor(path),
            cache: _shots,
            keys: ThumbnailKeys(
              packageRoot: p.join(core.host.worktree.path, path),
              // Two SDKs lay text out differently, so a picture is only ever this
              // one's — the same thing `ComparisonRunner` puts in its own keys.
              sdkKey: core.host.workspace.flutterSdk.root,
              // What this caller does to a frame that its source does not say. The
              // capture is whole-size PNG and the decode is bounded by
              // [PreviewThumbnails.longestSide]; a caller that changed either would
              // want its own pictures, not these.
              extra: {
                'format': 'png',
                'longest': '${PreviewThumbnails.longestSide}',
              },
            ),
          ),
        );

  late final _shots = ShotCache(p.join(flutterwareDir(), 'shots'));

  /// The harness lane, in the harness's own words.
  ///
  /// [TesterPhase.ready] is the one that answers null, and it is what takes the
  /// lane back down: everything else here is a wait, and that one is the end of
  /// all of them.
  StartupTask? _harnessTask(TesterPhaseReading reading) =>
      switch (reading.phase) {
        TesterPhase.compiling => const StartupTask(
          'Compiling the previews harness',
        ),
        TesterPhase.bundling => const StartupTask(
          'Rebuilding the asset bundle',
        ),
        TesterPhase.starting => const StartupTask('Starting the harness'),
        TesterPhase.restarting => const StartupTask('Restarting the harness'),
        TesterPhase.reloading => StartupTask(
          'Reloading ${reading.files} '
          'edited file${reading.files == 1 ? '' : 's'}',
        ),
        TesterPhase.ready => null,
      };

  /// A server per served directory, so a rebuild of the same page reuses the
  /// port a browser tab already has open — the tab reloads onto the new build
  /// rather than pointing at a server that has gone.
  final _servers = <String, CatalogWebServer>{};

  List<String> get packages => core.packages;

  /// Serves a built page and answers with the URL, starting a server only if
  /// this directory has not got one.
  ///
  /// Owned here rather than by the dialog that asks for it: the dialog is
  /// closed the moment you have the URL, and a server that died with it would
  /// leave the tab it just opened showing a connection error. The worktree is
  /// the right lifetime — see [dispose].
  Future<Uri> serveBuild(String output, {String basePath = '/'}) async {
    var directory = p.isAbsolute(output)
        ? output
        : p.join(host.worktree.path, output);
    var existing = _servers[directory];
    // Rebound when the base href changed: the same directory built for a
    // different mount point is a different page as far as a browser is
    // concerned, and the old server would answer 404 for all of it.
    if (existing != null &&
        existing.basePath == CatalogWebServer.normaliseBasePath(basePath)) {
      return existing.url;
    }
    await existing?.close();
    var server = await CatalogWebServer.serve(directory, basePath: basePath);
    _servers[directory] = server;
    return server.url;
  }

  /// The live compile loop for [path], started on first ask — which is the
  /// panel mounting.
  CatalogSession sessionFor(String path) => _sessions.putIfAbsent(path, () {
    var session = CatalogSession(
      appPackageRoot: host.workspace.appContext.appToolDirectory.path,
      flutterSdkRoot: host.workspace.flutterSdk.root,
      projectRoot: p.join(host.worktree.path, path),
      // So a `file:line` in the panel reads the same as one from `fw`, which
      // shortens against the worktree too.
      worktreeRoot: host.worktree.path,
      // The core's answer, not a second one: `roots` is part of the daemon
      // address, so a panel resolving it independently would open a different
      // daemon than `fw run previews` does for the same package.
      roots: [core.rootFor(path)],
      previewAnnotations: core.previewAnnotationsFor(path),
      clock: host.projectClock,
      // The whole list, not one resolved device: which of them applies is a
      // function of the entry on screen, and the panel is where that changes.
      canvases: core.canvasesFor(path),
      // What the listing draws until the daemon reports. Known already — the
      // scan finding entries is the gate this session is created behind — and
      // without it the panel shows an empty list for the whole cold compile.
      scannedEntries: core.entriesFor(path),
      connectToDaemon: connectToDaemon,
      launchGuest: launchGuest,
      startup: startupFor(path),
    )..addListener(core.notifyChanged);
    // The daemon is the only thing here watching the files, so its word is how
    // the core's scan learns it has been overtaken — and the harness behind
    // every thumbnail is generated from that scan. See [PreviewsCore.rescan]
    // for what a preview written or renamed while the panel was open did
    // before this line.
    session.onEntriesChanged = () => unawaited(core.rescan(path));
    unawaited(session.start());
    return session;
  });

  /// Not worth photographing while any open catalog is still working.
  ///
  /// Four conditions, and the two easy to miss are the last of them.
  ///
  /// A session can be `ready` with nothing in flight while the guest is still
  /// showing the *previous* entry, because [CatalogSession.selected] is what
  /// was asked for and `active` is what the guest managed to load. A capture
  /// taken in that window is a correct picture of the wrong demo, which is the
  /// single worst thing a screenshot tool can produce.
  ///
  /// And a session goes idle as soon as the guest's VM service answers, which
  /// is *before* the guest has drawn anything — the ring is mapped, the texture
  /// is in the widget tree, and it is empty. So the last condition is
  /// [EmbeddedEngine.hasPainted], and it is the one that produced a black
  /// phone: every capture in this repository happened to survive it because
  /// another plugin was wrongly claiming to be busy and held the shutter for
  /// minutes, while a project without that plugin photographed the empty ring
  /// and got the device frame's own black where the demo should be.
  ///
  /// A compile error settles rather than waits. The panel is showing the error,
  /// the error is the state, and hanging until the timeout would turn "this
  /// demo is broken" into "the tool is broken".
  @override
  String? get busyWith {
    for (var session in _sessions.values) {
      if (session.phase == CatalogSessionPhase.starting) {
        return session.busyWith ?? 'starting the catalog';
      }
      if (session.busyWith case var busy?) return busy;
      // Not while it is failing: an engine that died has an error on the stage
      // and will never paint, and waiting for a frame from it is waiting for
      // the timeout.
      if (session.engine case var engine?) {
        if (engine.phase == EmbeddedEnginePhase.running && !engine.hasPainted) {
          return 'rendering the guest';
        }
      }
      if (session.selectedError != null) continue;
      // Nothing selected is nothing to wait for: the guest holds the entry it
      // was warmed on, and the stage is not showing it. Without the pattern
      // this read `selected?.id != active?.id` as a mismatch and answered
      // `loading null` for as long as the panel sat unselected.
      if (session.selected case var entry?) {
        if (entry.id != session.active?.id) return 'loading ${entry.id}';
      }
    }
    return null;
  }

  /// What the compiler is doing for [path], or null when it is idle.
  ///
  /// This is the status worth a sidebar row: a cold compile is the only thing
  /// here that takes seconds, and a word that stays put until it goes away is
  /// what lets you look elsewhere and notice when it lands. No elapsed count —
  /// a figure ticking in the corner of the eye is movement, not information.
  ///
  /// [CatalogSession.visiblyBusyWith] rather than `busyWith`, which is the
  /// difference between a rail that reports and a rail that flickers: a switch
  /// the guest makes by itself is 64ms, and a 64ms row is not worth reading.
  /// The unfloored [busyWith] is still what
  /// [PreviewsPlugin.busyWith] above answers with, because a capture must know
  /// the instant the session starts working, not a quarter-second later.
  Status? _busyStatusFor(String path) {
    if (_sessions[path]?.visiblyBusyWith case var busy?) {
      return Status.info(busy);
    }
    if (_sessions[path]?.phase == CatalogSessionPhase.error) {
      return const Status.error('failed to start');
    }
    return null;
  }

  @override
  Widget buildPanel(BuildContext context) => _CatalogPanel(this);

  /// One command, on the row for the package it would build.
  ///
  /// On the row rather than in the panel because that is what it is *of*: a
  /// page is one package's whole catalog, and the panel is always looking at
  /// one entry of it.
  @override
  List<PluginChildCommand> childCommands(
    BuildContext context,
    String childId,
  ) => [
    PluginChildCommand(
      label: 'Build a web page…',
      icon: Icons.language,
      onSelected: (context) => unawaited(
        showWebBuildDialog(
          context,
          core: core,
          package: childId,
          serve: serveBuild,
        ),
      ),
    ),
  ];

  /// Closing the worktree is what ends the compile loops and the servers —
  /// nothing shorter does, which is why the plugin owns them.
  @override
  void dispose() {
    for (var session in _sessions.values) {
      session
        ..removeListener(core.notifyChanged)
        ..dispose();
    }
    _sessions.clear();
    for (var thumbnails in _thumbnails.values) {
      thumbnails.dispose();
    }
    _thumbnails.clear();
    for (var startup in _startups.values) {
      startup.dispose();
    }
    _startups.clear();
    for (var server in _servers.values) {
      unawaited(server.close());
    }
    _servers.clear();
    super.dispose();
  }
}

/// Points the catalog at whatever the address names, and writes back where it
/// ends up.
///
/// Both directions run through [catalogSegments] and [catalogPlace], so the
/// address this writes for a given entry is byte-identical to the one it would
/// have read for it. That is what stops the two directions chasing each other:
/// the write-back for an entry the address already named produces the address
/// it already is, and the shell recognises that as no move at all.
class _CatalogPanel extends StatefulWidget {
  const _CatalogPanel(this.plugin);

  final PreviewsPlugin plugin;

  @override
  State<_CatalogPanel> createState() => _CatalogPanelState();
}

class _CatalogPanelState extends State<_CatalogPanel> {
  /// The preview stage's pan and zoom, kept across package switches — see
  /// [CatalogView.zoom].
  final _zoom = TransformationController();

  /// The plugin the binding below belongs to — **not** always the one
  /// [widget] holds.
  ///
  /// A config reload throws the whole plugin graph away and builds it again
  /// (`ShellController._apply` → `open.release()` → `_build`), so this plugin
  /// object is replaced. The shell keys the panel on the worktree and the
  /// plugin *id*, both of which survive that, so Flutter keeps this `State` —
  /// and it woke up holding a [CatalogSession] whose owner had already
  /// disposed it. The panel then went on rendering that session: the entry list
  /// and the top bar listen to it, and `addListener` on a disposed
  /// `ChangeNotifier` throws, which took the canvas out for the rest of the
  /// process. Saving `tool/flutterware.dart` was the whole of the repro.
  ///
  /// Compared by identity rather than asked about, because there is nothing to
  /// ask: a rebuilt graph is new objects all the way down, and *this is a
  /// different plugin* is the only fact that distinguishes it from the load
  /// that declared nothing new — which builds nothing and swaps nothing.
  PreviewsPlugin? _plugin;
  String? _package;
  CatalogSession? _session;
  var _writeScheduled = false;

  /// The entry this last handed to the session, so the same one is not handed
  /// over twice.
  ///
  /// [didChangeDependencies] fires for its own reasons, not only when the
  /// address moves, and the address lags a local selection by a frame — its
  /// write-back is a post-frame callback. Restating it unconditionally
  /// therefore pushes the *previous* entry back onto a session that has already
  /// moved on, and `_applyWanted` dutifully switches back to it. That is a
  /// click silently undone.
  ///
  /// This used to be harmless by accident: nothing else wrote `wantedEntryId`,
  /// so the setter's own no-op absorbed the repeat. The moment selecting also
  /// counted as wanting, the repeat became a real change and undid every click
  /// rather than merely some of them.
  String? _followed;
  var _hasFollowed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow(catalogPlace(AddressScope.segments(context)));
  }

  @override
  void didUpdateWidget(_CatalogPanel old) {
    super.didUpdateWidget(old);
    // The declared packages can change under a config reload without the
    // address moving, and the fallback below is computed from them.
    _follow(catalogPlace(AddressScope.segments(context)));
  }

  /// Mounting the panel is the demand: the scan, and the compile loop the scan
  /// deliberately leaves alone.
  void _follow(CatalogPlace? place) {
    var package = place?.package ?? widget.plugin.packages.firstOrNull;

    // A swapped plugin is as much a new session as a different package is, and
    // for a stronger reason: the old one is not merely stale, it is disposed.
    // See [_plugin].
    var sessionChanged = package != _package || widget.plugin != _plugin;
    if (sessionChanged) {
      _release();
      _plugin = widget.plugin;
      _package = package;
      if (package != null) {
        // The scan, always. The compile loop only once the scan has found
        // something to compile — see [_startSessionIfReady], which is also
        // called from `build` because the scan usually lands after this.
        widget.plugin.core.track(package);
        // The tint is read from the delta, which is re-read while a tree
        // that paints from it is on screen.
        widget.plugin.core.branchDelta?.attach();
        _startSessionIfReady(package);
      }
    }

    // A request rather than a call: on a cold start the daemon has not reported
    // anything yet, and clicking the link is what starts the compile it would
    // otherwise be waiting for.
    //
    // Applied only when the *address* has moved — see [_followed]. A fresh
    // session always gets it, since it has never been told anything.
    if (addressMoved(
      hasFollowed: _hasFollowed,
      sessionChanged: sessionChanged,
      followed: _followed,
      place: place?.path,
    )) {
      // **Going up to the package is a request to see the catalog**, where
      // arriving at it is not. Both are an address naming no entry, and the
      // difference is only whether this panel was already following one: a
      // remount — the rail link, a plugin switch — has followed nothing yet and
      // must leave the selection alone, which is what takes you back to the
      // demo you were on. A breadcrumb click inside a panel that *was* on an
      // entry is somebody asking to go back to the sheet, and without this
      // there is no way to.
      var wentUp = wentUpToCatalog(
        hasFollowed: _hasFollowed,
        sessionChanged: sessionChanged,
        namesEntry: place?.entryId != null,
      );
      _hasFollowed = true;
      _followed = place?.path;
      // **What the sheet is showing, when the address says.** A directory sets
      // it; going up to the bare package clears it, which is the All demos row;
      // an entry leaves it alone, so that leaving a demo returns to the folder
      // it was picked from. See [CatalogBrowsing.scope].
      //
      // The same distinction the selection makes, for the same reason: a
      // remount at the bare package is the rail link naming the only thing it
      // knows, not somebody asking to see everything. Clearing the scope there
      // sent you back to All demos every time you left the plugin and came
      // back, whatever folder you had been standing in.
      if (_session case var session?
          when place?.entryId == null && (wentUp || place?.directory != null)) {
        session.browsing.scope = place?.directory;
      }
      if (wentUp) {
        _session?.deselect();
      } else {
        _session?.wantedEntryId = place?.entryId;
      }
    }

    // **And say back where that left us.** Until now the address was only ever
    // restated from a session *notify*, which is fine while one is working and
    // wrong the moment it is not: coming back to a settled session — the rail
    // link, which names the package and stops there — restored the demo on
    // screen and left the address naming the package alone. Whether it caught
    // up was down to whether some timer happened to notify.
    //
    // Costs nothing when it is already right: the write resolves to the same
    // segments, which the shell reads as no move at all.
    _settled();
  }

  /// Starts the compile loop for [package], but only once the scan says there
  /// is something to compile.
  ///
  /// This is the thirty seconds. A package with no entries used to get a
  /// session like any other: the daemon bound its socket, scanned the same
  /// directory this one did, refused in about a millisecond, and exited before
  /// the client's first 25ms poll had connected — so the `DaemonFailed` it sent
  /// reached nobody, and the client polled a deleted socket until its
  /// 30-second deadline before reporting that the daemon "never started
  /// listening". The fastest failure in the system produced the slowest
  /// feedback, for a fact the scan already held.
  ///
  /// Idempotent, and called from both [_follow] and `build`: the scan is
  /// asynchronous, so on a cold open it is the rebuild that follows it — not
  /// the mount — that first knows the answer.
  void _startSessionIfReady(String package) {
    if (_session != null) return;
    if (widget.plugin.core.setupFor(package) != CatalogSetup.ready) return;
    _session = widget.plugin.sessionFor(package)..addListener(_settled);
    // A fresh session has never been told anything, so whatever the address
    // asked for has to be restated to it. [_follow] would otherwise only do
    // this when the address *moves*, and it has not moved since the mount.
    if (_hasFollowed) _session!.wantedEntryId = _followed;
    // The other direction, for the same reason [_follow] ends with it: this is
    // usually called from `build` — the scan lands after the mount — so the
    // binding that finds a session already on an entry happens here rather
    // than there.
    _settled();
  }

  /// Writes the first demo, then goes to it.
  ///
  /// The address move is what starts the compile loop: `newPreview` rescans, the
  /// package becomes [CatalogSetup.ready], and the rebuild that follows calls
  /// [_startSessionIfReady] — so the demo somebody just asked for is the entry
  /// their session opens on.
  Future<void> _newPreview(BuildContext context, String package) async {
    var result = await showNewPreviewDialog(
      context,
      core: widget.plugin.core,
      package: package,
    );
    if (result == null || !context.mounted) return;
    AddressScope.write(context)
        .setSegments(catalogSegments(package, result.id));
  }

  /// Lets go of whatever is bound, **through the plugin it was bound to**.
  ///
  /// [widget.plugin] is already the new one by the time a swap reaches here, so
  /// untracking through it would release a package on a core that has never
  /// been asked for it and leave the old one tracked — releasing the wrong half
  /// of a swap the whole point of which is that the two halves are different
  /// objects.
  void _release() {
    _hasFollowed = false;
    _followed = null;
    if (_package case var previous?) {
      _plugin?.core.untrack(previous);
      _plugin?.core.branchDelta?.detach();
    }
    _session?.removeListener(_settled);
    _session = null;
    _package = null;
    _plugin = null;
  }

  /// The other direction: the catalog moved on its own — a click in its tree, a
  /// device chosen from the picker, a deleted entry, or the first demo taken
  /// because the address named none — so the address has to catch up.
  ///
  /// Deferred a frame because the session notifies from wherever its work
  /// finished, which can be inside a build; writing the address marks the shell
  /// dirty, and doing that mid-build is the crash this defers around.
  ///
  /// One write for both halves. Two would put an address on screen naming a
  /// state that never existed — the new entry still framed as the old device —
  /// and anything reading it in that gap would act on it.
  void _settled() {
    if (_writeScheduled || !mounted || _package == null) return;

    _writeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _writeScheduled = false;
      var package = _package;
      var session = _session;
      if (!mounted || package == null || session == null) return;

      // **Never over a complaint.** An address naming an entry this catalog
      // does not have is reported, not repaired — but restating wherever the
      // session actually landed would repair it anyway, quietly. The banner
      // would vanish along with what you had asked for, and a pasted link would
      // look like it had worked.
      if (session.missingEntryId != null) return;

      // **Nor before it has landed anywhere.** A session notifies while it is
      // starting — `building`, and again for every step of it — and until the
      // daemon reports it has nothing to say about where it is. Writing anyway
      // states the package alone, which reads as *this catalog is on no entry*;
      // the shell then drops `knob` and `inspect` along with the segment,
      // because the write looks like the end of an entry. A config reload
      // builds a fresh session under a mounted panel, so that turned saving
      // `tool/flutterware.dart` into losing whatever the demo's knobs were set
      // to.
      //
      // The phase rather than the selection, which is the difference between
      // *not yet* and *deliberately nothing*. A ready session with nothing
      // selected has landed: it is the panel opened at the bare plugin address,
      // and the package alone is exactly what it should say. By the time the
      // phase turns, `start` has already applied whatever the address asked
      // for, so there is no window where this writes a bare package over an
      // entry somebody named.
      if (session.phase != CatalogSessionPhase.ready) return;

      // Nothing about the device or the axes here. Neither is state to write
      // back: their controls write the address directly, and what is on screen
      // is read from the address every time it is drawn.
      var handle = AddressScope.write(context);
      // The entry when there is one, else whichever folder the catalog is
      // narrowed to — an address names one place, and these are the two it can
      // name. Both are selections, which is what makes them worth writing:
      // where the page happens to be *scrolled* is not, and briefly writing
      // that produced an address restated on every scroll frame.
      var segments = catalogSegments(
        package,
        session.selected?.id ?? session.browsing.scope,
      );
      handle.update(
        segments: segments,
        // A knob belongs to the entry, so it cannot outlive one. Dropped here
        // because this is the write that ends the entry — a demo's knobs are
        // meaningless against the next one, and carrying them would leave an
        // address accumulating settings for demos it no longer names. Axes
        // belong to the shell and are deliberately untouched.
        //
        // `inspect` goes with it, and more sharply: a node id is a *position in
        // one tree*, so carried across a switch it would not merely be stale,
        // it would name some unrelated widget of the next demo with complete
        // confidence.
        drop: listEquals(segments, handle.segments)
            ? const {}
            : const {'knob', 'inspect'},
      );
    });
  }

  @override
  void dispose() {
    _zoom.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var path = _package;
    if (path == null) {
      return const NoPackagesConfigured(icon: Icons.widgets_outlined);
    }
    return AnimatedBuilder(
      animation: widget.plugin,
      builder: (context, _) {
        // The scan's own failure, which is the one that arrives first and
        // explains why the daemon would refuse to start.
        if (widget.plugin.core.failureFor(path) case var failure?) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                failure,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          );
        }

        // Before the compile loop, because the compile loop is what this
        // decides. `unknown` is the scan still running — a moment, and not the
        // same claim as "there are none".
        var setup = widget.plugin.core.setupFor(path);
        if (setup == CatalogSetup.unknown) {
          return const LoadingState(title: 'Looking for demos…');
        }
        if (setup != CatalogSetup.ready) {
          return _NoPreviews(
            directory: widget.plugin.core.rootFor(path),
            directoryExists: setup != CatalogSetup.missing,
            package: widget.plugin.packages.length == 1 ? null : path,
            diagnostics: widget.plugin.core.diagnosticsFor(path),
            onNew: () => unawaited(_newPreview(context, path)),
          );
        }

        _startSessionIfReady(path);
        var session = _session!;
        return Column(
          children: [
            // Said out loud rather than repaired. The address is left naming
            // what it named, so a link to a demo that has not been written yet
            // still reads as that demo rather than turning into a different one.
            if (session.missingEntryId case var missing?)
              _Complaint('No entry "$missing" in this package.'),
            // Derived from the address, like the framing itself. Nothing
            // remembers that a bad value was seen, so nothing has to remember
            // to forget it.
            if (unknownDeviceIn(AddressScope.param(context, 'device'))
                case var device?)
              _Complaint('No device "$device". Try: ${deviceIds.join(', ')}.'),
            // The live loop. The core's own scan stays — it is what `fw` and an
            // agent read without a daemon running — but what the panel shows is
            // the compiled catalog, because only the daemon knows which entries
            // actually build.
            //
            // **Keyed on the session, not on the package.** The package was
            // enough for as long as a new session only ever arrived with one,
            // and a config reload is the case where it does not: the package
            // is the same string and the session below it is a different
            // object. Everything under here binds to a session *at mount* —
            // `InspectPanel` turns the watch and the log stream on from
            // `initState`, `CatalogView` starts its poll there — so a swap the
            // key did not notice left the new session with nobody watching it
            // and no logs, silently, until you left the plugin and came back.
            // A package change still remounts, since one session is one
            // package.
            Expanded(
              child: CatalogView(
                key: ObjectKey(session),
                session: session,
                thumbnails: widget.plugin.thumbnailsFor(path),
                entryChanges: widget.plugin.core.entryChangesFor(path),
                onLookAgain: () =>
                    unawaited(widget.plugin.core.branchDelta?.refreshIfStale()),
                // Outlives the key above, and that is the whole reason it is
                // here: a package switch is a session switch, so everything
                // below remounts, and a magnification held down there would go
                // with it.
                zoom: _zoom,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The screen a project sees before it has written a demo.
///
/// Not an error screen. This is what every project looks like on the day it
/// first opens the catalog, and it used to be thirty seconds of spinner
/// followed by a stack trace. It says where we looked, why there is nothing,
/// how to write one, and offers to write it.
class _NoPreviews extends StatelessWidget {
  const _NoPreviews({
    required this.directory,
    required this.directoryExists,
    required this.package,
    required this.diagnostics,
    required this.onNew,
  });

  final String directory;
  final bool directoryExists;
  final String? package;

  /// What the scan rejected. Empty for a project that has genuinely written
  /// nothing — and decidedly not empty for one whose first attempt was turned
  /// away, which is the case this screen used to answer with "no previews yet".
  final List<ScanDiagnostic> diagnostics;

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            catalogEmptyReason(
              directory: directory,
              directoryExists: directoryExists,
              package: package,
            ),
            style: TextStyle(fontSize: 13, color: scheme.onSurface),
          ),
          // Above the button and the hint, because it outranks both: somebody
          // whose annotation was rejected does not need to be taught how to
          // write one, they need to be told what was wrong with theirs.
          if (diagnostics.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (var diagnostic in diagnostics)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SelectableText(
                  '$diagnostic',
                  style: TextStyle(
                    fontSize: 12,
                    color: diagnostic.isError
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: onNew,
              icon: const Icon(Icons.add, size: FwIconSize.md),
              label: const Text('New preview'),
            ),
          ),
          const SizedBox(height: 24),
          SelectableText(
            catalogAuthoringHint(directory),
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Something the address asked for that this catalog cannot give.
///
/// Shown rather than repaired, and the message names the accepted values where
/// there is a closed set of them — the reader is often an agent that guessed,
/// and the useful reply to a guess is the list it should have picked from.
class _Complaint extends StatelessWidget {
  const _Complaint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SelectableText(
        message,
        style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
      ),
    );
  }
}
