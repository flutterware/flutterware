import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutterware/previews_guest.dart';
import 'package:path/path.dart' as p;

import '../embedder/embedded_engine.dart';
import '../embedder/guest_channel.dart';
import '../embedder/guest_surface.dart';
import '../ui/tree_collapse.dart';
import '../embedder/guest_vm_service.dart';
import 'authoring.dart';
import 'catalog_params.dart';
import 'devices.dart';
import 'catalog_entry.dart';
import '../ui/startup_progress.dart';
import 'catalog_source.dart';
import 'compiler_daemon_client.dart';
import 'daemon_phase.dart';
import 'inspect_client.dart';
import 'live_session.dart';
import 'protocol.dart';
import 'shader_reload.dart';

enum CatalogSessionPhase { starting, ready, error }

/// Which pane of the inspection panel is showing.
///
/// Lives here rather than beside the widget because the session outlives the
/// panel — the shell rebuilds it from scratch whenever you come back to it, and
/// returning to the tab you had open is the same courtesy as returning to the
/// entry you had selected.
///
/// Deliberately not on the address, unlike the node selection beside it.
/// `inspect.*` is dropped when the entry segment changes — it must be, since a
/// node id names a position in one particular tree and would otherwise name
/// some unrelated widget of the next demo with complete confidence. A tab
/// dropped with it would flip back to Elements on every click through the entry
/// list, which is exactly when you least want it to.
///
/// Controls is first and is the default. It is the everyday loop — turn a
/// knob, watch the demo — where the tree is what you go to when something is
/// wrong. Opening straight onto a wall of widget rows reads as the panel having
/// an opinion about what you came here to do.
enum InspectTab {
  controls('Controls'),
  elements('Elements'),
  semantics('Semantics'),
  problems('Problems'),
  console('Console');

  const InspectTab(this.label);

  final String label;
}

/// What the guest is being rendered *as*, which the top bar owns.
///
/// A device here is not decoration around the picture. The guest's window is
/// resized to the device's screen at the device's own pixel ratio, so a demo
/// reads the phone's size from `MediaQuery` rather than the panel's — which is
/// the difference between looking at a layout and testing one.
class CatalogStaging extends ChangeNotifier {
  /// Whether the device's chrome is drawn around the screen. Off leaves a
  /// plain rectangle of the right size, which is what you want once you are
  /// looking at the layout rather than at the phone.
  ///
  /// The only thing left here. The **device** used to live beside it, with a
  /// flag saying whether a person or an entry had last set it, and the panel
  /// copied it into the address a frame after every change. That copy loop was
  /// the bug: a pick was read back from an address that had not caught up yet
  /// and erased. A device is now a function of the address and the entry —
  /// see [resolveDevice] — held nowhere, so there is nothing to fall out of
  /// step.
  bool get frameVisible => _frameVisible;
  var _frameVisible = true;
  set frameVisible(bool value) {
    if (value == _frameVisible) return;
    _frameVisible = value;
    notifyListeners();
  }
}

/// The entry browser's own state, which is about looking rather than compiling.
///
/// Folders are tracked by what has been *closed*, not by what has been opened:
/// a folder that appears after a rescan is then open like everything around it,
/// where an expanded-set would have hidden it until someone thought to look.
class CatalogBrowsing extends ChangeNotifier {
  final _closed = <String>{};

  bool isOpen(String branchId) => !_closed.contains(branchId);

  void toggle(String branchId) {
    if (!_closed.remove(branchId)) _closed.add(branchId);
    notifyListeners();
  }

  /// Opens [branchIds], for a selection that has arrived somewhere folded away.
  ///
  /// An action taken once, not a rule applied on every build. The panel
  /// used to OR the path to the selected entry into "open" as it laid the rows
  /// out, which meant the folder holding your selection could not be closed at
  /// all: the click landed in [_closed], the row did not move, and the only
  /// visible effect anywhere was the collapse-all button quietly changing its
  /// mind. Opened when the selection lands and left alone afterwards, a folder
  /// is yours again — and a selection you can no longer see is exactly what any
  /// other file tree does with the file you have open.
  void reveal(Iterable<String> branchIds) {
    var opened = false;
    for (var id in branchIds) {
      if (_closed.remove(id)) opened = true;
    }
    if (opened) notifyListeners();
  }

  /// Whether [entryId] is a selection the tree has not been opened for yet.
  bool needsReveal(String? entryId) => entryId != _revealedFor;

  /// Opens [branchIds] for a selection that has just arrived, once.
  ///
  /// The mark is here rather than in the panel because the panel is rebuilt
  /// from scratch every time you come back to it: kept there, every return
  /// would re-open the folder you closed after arriving, which is the same bug
  /// as the render-time override in a slower form.
  void revealSelection(String? entryId, Iterable<String> branchIds) {
    if (entryId == _revealedFor) return;
    _revealedFor = entryId;
    reveal(branchIds);
  }

  String? _revealedFor;

  /// Whether anything is folded away at all, which is what makes one button
  /// enough for both directions.
  bool get anyClosed => _closed.isNotEmpty;

  void closeAll(Iterable<String> branchIds) {
    _closed.addAll(branchIds);
    notifyListeners();
  }

  void openAll() {
    if (_closed.isEmpty) return;
    _closed.clear();
    notifyListeners();
  }

  /// Whether [foldIfCrowded] has anything left to decide — the cheap guard
  /// for a caller that would otherwise walk its whole tree twice on every
  /// build to ask a question already answered.
  bool get needsFoldDecision => !_decidedFold;

  /// Folds a catalog that would not fit, once, the first time one is laid out.
  ///
  /// [rowCount] is what the tree would lay out open and [branchIds] is every
  /// branch in it. Over [treeRowBudget] rows, a catalog opens as a table of
  /// contents rather than as a list you arrive already scrolling; under it,
  /// everything stays visible, which is what a handful of demos wants.
  ///
  /// Decided once, not re-applied. After this, the fold is whatever the
  /// person browsing made it, including all the way open. A branch that turns
  /// up later — a file written while the panel is open — is open in a folded
  /// tree, since the closed set names what existed when the decision was
  /// taken. Which is the right accident: the newest thing is the visible one.
  ///
  /// Deliberately without a notification. The caller is the build that
  /// lays the rows out and reads [isOpen] a few lines further down, so the
  /// answer is already used by the frame that asked for it. Notifying from
  /// inside a build is a `markNeedsBuild` during build, and deferring the
  /// decision to a post-frame callback instead would paint the crowded tree
  /// open for one frame before folding it.
  void foldIfCrowded(int rowCount, Iterable<String> branchIds) {
    // An empty tree is not a decision: entries arrive from the daemon after
    // the panel mounts, and deciding on the tree that has none yet would mean
    // never deciding at all.
    if (rowCount == 0 || _decidedFold) return;
    _decidedFold = true;
    if (!foldsOnArrival(rowCount)) return;
    _closed.addAll(branchIds);
  }

  var _decidedFold = false;

  /// What was typed in the filter box. Empty shows everything.
  String get filter => _filter;
  var _filter = '';
  set filter(String value) {
    if (value == _filter) return;
    _filter = value;
    notifyListeners();
  }

  /// Whether the tree shows only what this branch changed. Off shows
  /// everything, with the changed rows tinted.
  bool get changedOnly => _changedOnly;
  var _changedOnly = false;
  set changedOnly(bool value) {
    if (value == _changedOnly) return;
    _changedOnly = value;
    notifyListeners();
  }

  /// What part of the catalog the sheet is showing — a directory, or one file
  /// — or null for the whole index. See `CatalogPlace.directory`.
  ///
  /// **Picked in the tree, and the tree marks it.** That is what was missing
  /// the first time this existed: narrowing was a hover-chevron on a heading
  /// and announced itself with a filter icon, so it read as a filter having
  /// been applied rather than as somewhere you had gone, and the tree beside it
  /// said nothing at all. A selected row is unambiguous about both.
  ///
  /// Kept while an entry is open, so that leaving a demo returns to the part of
  /// the catalog it was picked from rather than to all of it.
  String? get scope => _scope;
  String? _scope;
  set scope(String? value) {
    if (value == _scope) return;
    _scope = value;
    notifyListeners();
  }

  /// Whether resting the pointer on a row shows that entry's picture.
  ///
  /// On by default and switchable from the list's own header, because whether
  /// it reads as helpful or as the panel twitching under your hand is a matter
  /// of taste and of how big a catalog is.
  bool get previewOnHover => _previewOnHover;
  var _previewOnHover = true;
  set previewOnHover(bool value) {
    if (value == _previewOnHover) return;
    _previewOnHover = value;
    if (!value) hover(null);
    notifyListeners();
  }

  /// How long the pointer has to rest on a row before its picture is asked
  /// for.
  ///
  /// Long enough that sweeping the list past forty rows asks for none of them,
  /// short enough that stopping on one does not feel like waiting.
  static const hoverDelay = Duration(milliseconds: 180);

  /// And how long before the picture goes once the pointer has left. Shorter,
  /// because moving between two rows crosses no gap — the next row's [hover]
  /// cancels this before it fires — so it only ever runs when the pointer has
  /// genuinely gone.
  static const hoverLeaveDelay = Duration(milliseconds: 90);

  /// The entry the pointer is resting on, or null.
  ///
  /// Debounced: [hover] is free to call on every enter and exit, and this only
  /// moves where the pointer stopped.
  CatalogEntry? get hovering => _hovering;
  CatalogEntry? _hovering;

  /// Where that row is on screen, so the popover can point at it.
  Rect? get hoveringAt => _hoveringAt;
  Rect? _hoveringAt;

  Timer? _hoverDelay;
  var _disposed = false;

  /// The pointer is resting on [entry], whose row occupies [at] in global
  /// coordinates, or has left the list.
  void hover(CatalogEntry? entry, {Rect? at}) {
    if (_disposed) return;
    if (entry != null && !previewOnHover) return;
    if (entry?.id == _wantedHover?.id) return;
    _wantedHover = entry;
    _wantedHoverAt = at;
    _hoverDelay?.cancel();
    _hoverDelay = Timer(entry == null ? hoverLeaveDelay : hoverDelay, () {
      if (_disposed || _hovering?.id == _wantedHover?.id) return;
      _hovering = _wantedHover;
      _hoveringAt = _wantedHoverAt;
      notifyListeners();
    });
  }

  /// Ends what is showing at once, with no delay to wait out.
  ///
  /// What a click calls. A click is an answer, and a picture of the thing you
  /// just chose, hanging beside the canvas that is about to show it, is one
  /// picture too many — waiting out [hoverLeaveDelay] for it would be a card
  /// that lingers over the click that dismissed it.
  void endHover() {
    _hoverDelay?.cancel();
    _wantedHover = null;
    _wantedHoverAt = null;
    if (_hovering == null) return;
    _hovering = null;
    notifyListeners();
  }

  CatalogEntry? _wantedHover;
  Rect? _wantedHoverAt;

  @override
  void dispose() {
    _disposed = true;
    _hoverDelay?.cancel();
    super.dispose();
  }
}

/// How the last switch went, for the UI to show.
class SwitchReport {
  SwitchReport({
    required this.entry,
    required this.compile,
    required this.reload,
    required this.newSourceCount,
    required this.editedCount,
    this.reloaded = false,
    this.error,
  }) : direct = false;

  /// A switch the guest made by itself — see [InspectClient.showEntry]. Nothing
  /// was compiled and nothing was reloaded, so the compiler's numbers would all
  /// be zero and reporting them as such would read as a compile that did
  /// nothing rather than as one that never happened.
  SwitchReport.shown({required this.entry, required Duration elapsed})
    : compile = Duration.zero,
      reload = elapsed,
      newSourceCount = 0,
      editedCount = 0,
      reloaded = false,
      error = null,
      direct = true;

  final CatalogEntry entry;
  final Duration compile;
  final Duration reload;
  final int newSourceCount;

  /// How many edited files the daemon picked up. The interesting number when
  /// [reloaded] — it is the difference between "your save is on screen" and
  /// "nothing was saved".
  final int editedCount;

  /// This was a reload of the entry already showing, not a switch to another.
  final bool reloaded;

  /// The guest switched itself, with no compile and no reload behind it.
  final bool direct;

  /// Compiler diagnostics when the entry did not build. The guest keeps
  /// rendering whatever it had.
  final String? error;

  bool get ok => error == null;
}

/// Owns the warm catalog loop from the GUI's side: the compiler daemon, one
/// embedder guest, and the VM-service connection that pushes entries into it.
///
/// Switching an entry is a hot reload, not a restart — the engine, the isolate
/// and the compiler all stay warm.
///
/// Nothing here compiles in-process. All building and compiling happens in
/// the daemon, a separate plain-Dart process; see [CompilerDaemonClient] for
/// why that is not a style preference.
class CatalogSession extends ChangeNotifier {
  CatalogSession({
    required this.appPackageRoot,
    required this.flutterSdkRoot,
    required this.projectRoot,
    this.worktreeRoot,
    this.roots = const [defaultCatalogRoot],
    this.previewAnnotations = defaultPreviewAnnotations,
    this.canvases = const [],
    this.scannedEntries = const [],
    this.clock,
    this.setup,
    this.connectToDaemon = CompilerDaemonClient.connector,
    this.launchGuest = launchEmbeddedGuest,
    StartupProgress? startup,
  }) : startup = startup ?? StartupProgress() {
    // Forwarded, so a renderer has one thing to listen to.
    browsing.addListener(notifyListeners);
    staging.addListener(notifyListeners);
  }

  /// Where the browser was left: what is folded away, what was typed, whether
  /// the list is showing.
  ///
  /// On the session because the session outlives the panel — the shell builds
  /// the panel from scratch each time you come back to it, and returning to a
  /// tree you had arranged and a filter you had typed is the same courtesy as
  /// returning to the entry you had selected.
  final browsing = CatalogBrowsing();

  /// What `clock.now()` reads in every preview, or null for
  /// `pinnedClockOrigin` — the project's own `fw.clock(...)`.
  final DateTime? clock;

  /// What the guest is rendered as: a device, or the panel.
  final staging = CatalogStaging();

  /// What this start is doing, merged with whatever else is working on the same
  /// wait — see [StartupProgress].
  ///
  /// Injected rather than owned, because the session is not the only lane. The
  /// panel's other one is the `flutter_tester` harness photographing the
  /// catalog page, which comes up beside this one, knows nothing about it, and
  /// is waited for by the same person. The plugin holds one of these per
  /// package and hands it to both.
  final StartupProgress startup;

  /// Everything discovery found, populated when the daemon reports ready.
  ///
  /// Assigning it is what retires [scannedEntries]: the daemon has spoken, so
  /// the listing is its answer from here on. Said in the setter rather than at
  /// the call sites so that nothing can report entries without also meaning it.
  List<CatalogEntry> get entries => _entries;
  List<CatalogEntry> _entries = const [];

  set entries(List<CatalogEntry> value) {
    _entries = value;
    _daemonReported = true;
    _allEntries = null;
  }

  /// The listing to show until the daemon has reported: what the plugin's own
  /// scan already found.
  ///
  /// The panel is only built once that scan has entries — it is the gate on
  /// starting a session at all — so this is known before the first frame, while
  /// [entries] is a daemon handshake away. Measured on this repo's example
  /// package, that gap is **8 seconds**, and the list spent all of it saying
  /// "No entries", which was not merely slow but false.
  ///
  /// The two lists are the same set: both sides run the same scanner over the
  /// same roots, and the daemon serves everything it discovered with the
  /// unbuildable ones quarantined rather than dropped. So the daemon's arrival
  /// adds error marks to rows that are already there rather than replacing one
  /// list with another. Empty for a session nobody scanned for — the standalone
  /// entry point and the motion panel — which then behaves as it always did.
  final List<CatalogEntry> scannedEntries;

  /// Whether the daemon's answer is in, which is when [allEntries] stops
  /// answering from [scannedEntries]. Either half of that answer sets it.
  ///
  /// Not `phase == ready`: that waits for the guest as well, several seconds
  /// past the point the entry list is known.
  var _daemonReported = false;

  /// Entries discovery found but the compiler cannot build, with the error to
  /// show for each. Kept out of [entries] rather than hidden: a demo you are
  /// midway through editing should say why it is unavailable.
  ///
  /// The other half of the daemon's answer, so assigning it retires the scan
  /// too — a catalog whose every entry is quarantined reports an empty
  /// [entries] and would otherwise go on showing the seed.
  List<QuarantinedEntry> get quarantined => _quarantined;
  List<QuarantinedEntry> _quarantined = const [];

  set quarantined(List<QuarantinedEntry> value) {
    _quarantined = value;
    _daemonReported = true;
    _allEntries = null;
  }

  /// Warnings the scan produced; the daemon refuses to start on errors.
  List<String> diagnostics = const [];

  /// Called when the daemon's catalog stops being the one [scannedEntries]
  /// describes — a preview written, deleted, renamed, or its annotation edited
  /// while the panel was open.
  ///
  /// The daemon watches the files and this session simply believes it, so the
  /// *listing* is right the moment the demo is saved. Nothing else in the tool
  /// is watching: the plugin's own scan is what the previews harness generates
  /// its program from, and it was read once, before this session existed. This
  /// is how it hears that it is behind.
  ///
  /// A callback rather than a listener because it is not a rebuild: it costs a
  /// scan, so it must fire when the catalog genuinely moved and not on every
  /// notification.
  void Function()? onEntriesChanged;

  /// The catalog the last report agreed with, seeded from the scan the session
  /// was built on — so a daemon whose first answer already differs from it is
  /// change enough to say so.
  late Map<String, String> _reported = _shapeOf(scannedEntries);

  /// What has to still be true for a scan to describe the catalog, per entry.
  ///
  /// **Not the ids.** The generated wrapper is written from the annotation and
  /// resolves the demo from the path, so an edit that changes either without
  /// renaming the symbol leaves the ids identical and the wrapper wrong — and
  /// the harness regenerates only when `PreviewProgram.sources()` moves, which
  /// is a list of ids. The symptom is a thumbnail that goes on rendering under
  /// the wrapper you have just replaced while the panel, which reads the
  /// daemon, shows the new one.
  ///
  /// The same fields the daemon's own `_differs` names as *everything the
  /// wrapper or the entrypoint reads* (`app/tool/catalog/compiler_daemon.dart`),
  /// plus [CatalogEntry.path], which a declared `id:` otherwise hides.
  ///
  /// Joined on NUL rather than on punctuation: an annotation is source text and
  /// a name is a string literal out of it, so every printable separator is one
  /// an entry can contain and shift a field across. It stays in this map —
  /// nothing writes it, and the only thing it is ever compared against is
  /// another one built here.
  static Map<String, String> _shapeOf(Iterable<CatalogEntry> entries) => {
    for (var entry in entries)
      entry.id: [
        entry.path,
        entry.symbol,
        entry.annotation,
        entry.name,
        entry.group ?? '',
      ].join('\u0000'),
  };

  /// The daemon's answer, taken whole.
  ///
  /// One door rather than the two setters called in sequence, because a report
  /// is one fact: between the assignments the catalog is half this answer and
  /// half the last one, and what reads it reads across both. The setters stay
  /// public for a test staging a session by hand, which is stating a state
  /// rather than hearing one.
  ///
  /// Both halves merged for the comparison: an entry moving from buildable to
  /// quarantined stays in the catalog, and treating that as a change would
  /// throw away every picture of a package because one demo has a typo in it.
  void reportCatalog(
    List<CatalogEntry> reported,
    List<QuarantinedEntry> refused,
  ) {
    entries = reported;
    quarantined = refused;
    var shape = _shapeOf(allEntries);
    if (mapEquals(_reported, shape)) return;
    _reported = shape;
    onEntriesChanged?.call();
  }

  /// The `flutterware_app` package root, which owns `native/` and the build dir.
  final String appPackageRoot;
  final String flutterSdkRoot;

  /// Root the entries' paths are relative to.
  final String projectRoot;

  /// The worktree the project sits in, for shortening what is shown.
  ///
  /// An absolute URI is the truth and a relative path is what anybody reading
  /// it wants — and worktree-relative rather than package-relative so a source
  /// location read off the panel is byte-identical to the one `fw run
  /// ui_catalog inspect --tree` prints, which is what lets you paste one where
  /// the other was expected. Falls back to [projectRoot] when nothing said.
  final String? worktreeRoot;

  /// How [start] reaches a daemon. [CompilerDaemonClient.connect] outside of
  /// tests, which cannot afford the snapshot compile and process it spawns —
  /// and the dispose-during-connect window can only be held open by a connect
  /// a test controls.
  final DaemonConnector connectToDaemon;

  /// How the guest is brought up once the catalog has compiled: an embedder
  /// process by default, or — for a browser, or a test over a real entry —
  /// one drawn inline. See [GuestLauncher].
  final GuestLauncher launchGuest;

  /// What a path shown in the panel is measured against.
  String get displayRoot => worktreeRoot ?? projectRoot;

  /// Directories to scan, relative to [projectRoot].
  final List<String> roots;

  /// The annotation names that mark an entry. Part of the daemon address, so
  /// this has to be the plugin's answer rather than a second one.
  final List<String> previewAnnotations;

  /// The package's declared setup file, package-relative — part of the daemon
  /// address too, and the plugin's answer for the same reason. See
  /// `PreviewsPackage.setup`.
  final String? setup;

  /// What the canvas frames as when the address names no device — what the
  /// package declared for the subtree the entry lives in, or null for the plain
  /// rectangle.
  ///
  /// The core's answer rather than a second one, for the same reason [roots] is:
  /// the panel and `previews screenshot` have to open on the same picture, and a
  /// default resolved twice is a default that eventually differs. The setting
  /// exists so they agree — a project says "we are a phone" once and both
  /// surfaces stop rendering it as a small desktop.
  ///
  /// The list rather than one device, because a package is allowed to hold
  /// more than one form factor and the answer is then a function of the entry
  /// rather than of the package. A session that had been handed a single device
  /// would have to ask the plugin again on every selection, which is the two
  /// copies this field exists to prevent.
  final List<PreviewCanvas> canvases;

  /// The canvas that applies to [entry], or the package's own when nothing is
  /// selected yet.
  PreviewCanvas? canvasOf(CatalogEntry? entry) =>
      canvasFor(canvases, entry?.path ?? '');

  CatalogSessionPhase phase = CatalogSessionPhase.starting;
  String? errorMessage;

  /// What the guest is currently rendering.
  CatalogEntry? active;

  /// What the user last asked for, which is not the same thing: an entry that
  /// does not compile stays selected — and stays the one a reload retries —
  /// while the guest goes on rendering whatever it last managed to load.
  CatalogEntry? selected;

  /// Puts the stage back to nothing selected — which is the catalog, drawn as
  /// pictures.
  ///
  /// The **deliberate** counterpart of a null [wantedEntryId], which means "no
  /// request" and leaves whatever is selected alone. The two look identical at
  /// this level and are opposite intentions: one is the panel being remounted
  /// at an address that happens not to name an entry, the other is somebody
  /// asking to go back to the catalog. Only the caller can tell them apart, so
  /// only the caller may say this.
  ///
  /// The guest keeps whatever it is holding. Nothing about deciding not to look
  /// at a demo makes the next click worth twelve seconds again.
  void deselect() {
    if (selected == null && _wantedEntryId == null) return;
    selected = null;
    _wantedEntryId = null;
    notifyListeners();
  }

  /// The entry the address names, which is **a request rather than a call**.
  ///
  /// Nothing here can be selected until the daemon reports what exists, and on
  /// a cold start the address arrives long before that — clicking a search hit
  /// is what *starts* the compile it would be waiting for. So this is written
  /// whenever it is known and applied whenever it becomes possible: at [start],
  /// and again whenever the entry list moves. Setting it while ready switches
  /// immediately.
  ///
  /// Null is **no request**, not a request for nothing: whatever is selected
  /// stays selected. That is what makes leaving the plugin and coming back
  /// return you to the demo you were on — the panel unmounts, the session does
  /// not, and the address it is remounted at names no entry. On a session that
  /// has never selected anything it means the stage stays empty, which is the
  /// other half of the same rule.
  String? get wantedEntryId => _wantedEntryId;
  String? _wantedEntryId;

  set wantedEntryId(String? id) {
    if (_wantedEntryId == id) return;
    _wantedEntryId = id;
    if (phase == CatalogSessionPhase.ready) {
      _applyWanted();
    } else if (wantedEntry case var entry?) {
      // Nothing to switch yet — but the ask is still the ask, and [selected] is
      // what the user last asked for rather than what the guest holds. Saying
      // so here is what makes a click during the boot visible: the row lights,
      // and the stage says what it is compiling instead of going on inviting
      // you to pick something.
      //
      // Resolvable this early because the listing is too, off the plugin's own
      // scan — see [scannedEntries].
      selected = entry;
      notifyListeners();
    }
  }

  /// The entry [wantedEntryId] names, if the catalog has one.
  ///
  /// Looks in [allEntries] rather than [entries]: an address naming a demo that
  /// currently does not compile should land on it and show the error, which is
  /// the useful answer. Being sent somewhere else instead is how a broken
  /// build turns into "the link is wrong".
  CatalogEntry? get wantedEntry {
    var id = _wantedEntryId;
    return id == null ? null : allEntries.where((e) => e.id == id).firstOrNull;
  }

  /// Set when the address names an entry this catalog does not have at all.
  ///
  /// Deliberately not repaired by moving somewhere that does exist. A pasted
  /// address that quietly becomes a different one is indistinguishable from a
  /// broken app; saying "there is no such entry" is information, and silently
  /// showing the first demo is not.
  ///
  /// Only once the session is ready. Before that *nothing* exists yet, and
  /// "there is no such entry" would be the first thing every cold start said
  /// about a perfectly good address.
  String? get missingEntryId =>
      phase == CatalogSessionPhase.ready &&
          _wantedEntryId != null &&
          wantedEntry == null
      ? _wantedEntryId
      : null;

  void _applyWanted() {
    var entry = wantedEntry;
    if (entry == null || entry.id == selected?.id) return;
    unawaited(switchTo(entry));
  }

  SwitchReport? lastSwitch;
  Duration? coldCompile;

  /// What the daemon's one-time work cost, by phase, and what it began from.
  ///
  /// The post-mortem the strip is the live half of. It answers the question a
  /// slow start actually raises — *where did it go* — which neither a total nor
  /// a bar can: the same forty seconds is a fetched engine framework, a
  /// compile with no head start, or a compile whose head start held a fraction
  /// of what this program reaches, and only these tell those apart.
  Map<String, int> timings = const {};
  SeedReport? seed;
  var warmStart = false;

  /// Whether this session attached to a daemon that was already up, and so paid
  /// for none of the above.
  var reusedDaemon = false;

  /// The controls the entry on screen declared while it built, or an empty
  /// report for one that declares none.
  KnobReport knobs = KnobReport.empty;

  /// The axes the shell on screen declared, with what each is set to.
  ///
  /// The only place shells are known at all. Nothing discovers them: a shell is
  /// whatever the entry's wrapper builds, and it declares its axes while it
  /// builds — so the host learns which shell an entry uses from this report and
  /// from nowhere else.
  AxisReport axes = AxisReport.empty;

  /// The widget tree the guest last reported, whichever entry it was of.
  ///
  /// Read from the **live** guest rather than through a `PluginAction`, which
  /// is the point: an action renders its own headless copy, and a copy has
  /// none of the state a person put this one into. Prefer [treeForSelection]
  /// for anything that draws.
  InspectTree? tree;

  /// The tree, but only when it describes what is selected.
  ///
  /// A tree naming another entry is a read from before the switch, not an
  /// empty one — the same rule `KnobReport.entryId` follows. Drawing it under
  /// a selection it does not belong to is how you end up wondering why your
  /// edit did nothing, which is the mistake `_CompileError` exists to avoid
  /// one pane over.
  InspectTree? get treeForSelection =>
      tree?.entryId == (selected ?? active)?.id ? tree : null;

  /// The semantics tree the guest last reported — what a screen reader gets.
  ///
  /// Same live-guest rule as [tree], and one more reason it cannot be an
  /// action's re-render: semantics is **off** in a live app until the guest is
  /// asked to hold a handle, which [inspectingSemantics] does only while the
  /// tab is open.
  InspectSemantics? semantics;

  /// The semantics, but only when they describe what is selected — the rule
  /// [treeForSelection] follows, and for the same reason.
  InspectSemantics? get semanticsForSelection =>
      semantics?.entryId == (selected ?? active)?.id ? semantics : null;

  /// What the entry on screen reported while building and painting.
  ///
  /// Read after every build regardless of which tab is open, unlike the
  /// tree. A badge exists to tell you about something you did not ask about,
  /// and one that only appears once you open the tab it is on would be telling
  /// you what you had just gone and looked up. It is also a much smaller answer
  /// than a tree: a handful of distinct errors, counted rather than repeated.
  InspectErrors? renderErrors;

  /// The errors, but only when they describe what is selected — the same rule
  /// [treeForSelection] follows, and for the same reason.
  InspectErrors? get errorsForSelection =>
      renderErrors?.entryId == (selected ?? active)?.id ? renderErrors : null;

  /// Which pane of the panel is showing. See [InspectTab] for why it is here
  /// and not on the address.
  InspectTab inspectTab = InspectTab.controls;

  /// Whether the panel is folded away.
  ///
  /// Closed to start with. Most entries declare no knobs, so opening on
  /// Controls spent 260px of every catalog on a sentence explaining what a knob
  /// is. What says there is something to open is the count on the tab, the way
  /// Problems already says it — see [InspectPanel].
  ///
  /// Here rather than in the panel's own state, for the reason [inspectTab] is:
  /// the shell rebuilds the panel from scratch every time you come back to it,
  /// so a collapse kept there was forgotten on every trip to another plugin and
  /// the panel came back open however you had left it.
  var panelCollapsed = true;

  /// Whether the tree is **on screen** — the Elements tab showing, and the
  /// panel not collapsed.
  ///
  /// Deliberately narrower than "the panel is mounted". An unwatched tree is a
  /// round trip on every entry switch, paid even by sessions that never open
  /// that tab; and since the panel now opens on Controls, tying it to the mount
  /// would have meant every session reading trees for a pane that was never
  /// opened.
  /// Does not notify. Nothing draws this flag, and the panel turns it off
  /// from `dispose` — where notifying would rebuild listeners around a widget
  /// on its way out. Turning it on notifies soon enough, when the tree lands.
  bool get inspecting => _inspecting;
  var _inspecting = false;
  set inspecting(bool value) {
    if (value == _inspecting) return;
    _inspecting = value;
    // Opening the panel is itself a request — the entry on screen arrived
    // before anybody asked for its tree.
    if (value) unawaited(readTree());
  }

  /// Whether the semantics tree is **on screen** — the Semantics tab showing,
  /// and the panel not collapsed.
  ///
  /// The same shape as [inspecting] with one extra duty: the flag drives the
  /// *guest's* semantics on and off. A live app builds no semantics until
  /// something holds a handle, and building it costs every frame — so the
  /// guest pays only between opening the tab and leaving it.
  /// Does not notify, for the reason [inspecting] does not.
  bool get inspectingSemantics => _inspectingSemantics;
  var _inspectingSemantics = false;
  set inspectingSemantics(bool value) {
    if (value == _inspectingSemantics) return;
    _inspectingSemantics = value;
    var inspect = _inspect;
    // Null when the panel opened before the guest was up — the connect path
    // catches up, exactly as it does for the watch and the logs.
    if (inspect == null) return;
    if (value) {
      _enableSemantics(inspect);
    } else {
      // Tolerant, like unwatch: this runs from disposes, where the guest may
      // already be gone.
      unawaited(inspect.setSemantics(false));
    }
  }

  /// Turns the guest's semantics on, then reads — the read settles through
  /// the frame that builds the first tree.
  void _enableSemantics(InspectClient inspect) => _fireAndForget(
    inspect.setSemantics(true).then((_) => readSemantics()),
    'enabling semantics',
  );

  /// What the entry on screen has printed, oldest first.
  ///
  /// Its own notifier, for the reason [watchedBox] is: a demo printing from
  /// `build` prints on every frame, and rebuilding the entry list and the top
  /// bar to append a line would be absurd. Only the console listens.
  final guestLogs = ValueNotifier<List<InspectLogLine>>(const []);

  /// How many lines the guest dropped off the front of its buffer, so the
  /// console can say the scrollback is not the beginning.
  int get logsDropped => _logsDropped;
  var _logsDropped = 0;

  /// The highest sequence already held, which is what makes taking the buffer
  /// and subscribing at the same moment safe. The two overlap by however long
  /// the round trip took; the overlap is dropped by number.
  var _lastLogSequence = 0;

  StreamSubscription<InspectLogLine>? _logStream;

  /// Bounded here as well as in the guest. The guest keeps 500; this keeps the
  /// same, so a session left open for a day holds a screenful of scrollback
  /// rather than a day of it.
  static const _logLimit = 500;

  /// Empties both ends — the console's clear button.
  ///
  /// The guest's buffer too, and not only this one: clearing the host alone
  /// would put every line straight back on the next read.
  Future<void> clearLogs() async {
    var inspect = _inspect;
    guestLogs.value = const [];
    _logsDropped = 0;
    if (inspect == null) return;
    await inspect.clearLogs();
    // Not reset to zero: the guest goes on counting from where it was, and a
    // host that started again from nothing would discard every line until the
    // guest's counter caught back up.
  }

  /// Reads the guest's buffer, then keeps up with it.
  void _startLogs() {
    var inspect = _inspect;
    if (inspect == null || _logStream != null) return;
    // Subscribed before the read, so nothing printed while the read is in
    // flight falls between the two.
    _logStream = inspect.logLines.listen(_onLogLine);
    unawaited(readLogs());
  }

  void _stopLogs() {
    unawaited(_logStream?.cancel());
    _logStream = null;
  }

  void _onLogLine(InspectLogLine line) {
    if (_disposed || line.sequence <= _lastLogSequence) return;
    _hold([...guestLogs.value, line]);
  }

  /// Keeps the last [_logLimit] of [lines], in order, and remembers how far it
  /// has got.
  ///
  /// One place, because the cap and the high-water mark were written twice —
  /// once for a pushed line and once for a pulled buffer — and a cap enforced
  /// in two places is a cap that will eventually be two different caps.
  void _hold(List<InspectLogLine> lines) {
    lines.sort((a, b) => a.sequence.compareTo(b.sequence));
    if (lines.length > _logLimit) {
      lines = lines.sublist(lines.length - _logLimit);
    }
    _lastLogSequence = lines.isEmpty ? _lastLogSequence : lines.last.sequence;
    guestLogs.value = lines;
  }

  /// Takes whatever the guest is holding that this has not seen.
  ///
  /// Called on open and after a reload, which is when the stream alone is not
  /// enough: a reload prints before anything here has subscribed.
  Future<void> readLogs() async {
    var inspect = _inspect;
    var entry = selected ?? active;
    if (inspect == null || entry == null) return;
    var report = await inspect.logs(entry.id);
    if (report == null || _disposed) return;
    _logsDropped = report.dropped;

    // **Merged and re-sorted, not appended.** The obvious version took
    // everything newer than the highest sequence held — and lost the entire
    // scrollback on open, because the stream is subscribed first and one line
    // arriving during the round trip would push the mark past every line the
    // buffer was about to deliver. What the buffer holds is history; history
    // does not go on the end.
    var known = {for (var line in guestLogs.value) line.sequence};
    var fresh = [
      for (var line in report.lines)
        if (!known.contains(line.sequence)) line,
    ];
    if (fresh.isEmpty) return;
    _hold([...guestLogs.value, ...fresh]);
  }

  /// Whether the panel is mounted at all — which is the watch's lifetime.
  ///
  /// Deliberately wider than [inspecting]. The watch costs the guest
  /// 0.3ms a frame on the largest tree in the repo, measured, and nothing at
  /// all on a frame that is not drawn; what is expensive is the *tree read* it
  /// can ask for, and that stays behind [inspecting]. Tying the watch to the
  /// Elements tab instead would have left the Problems tab — the one place
  /// where resizing the preview genuinely changes the answer, because that is
  /// what makes a `Row` overflow or stop overflowing — with no way to know the
  /// preview had been resized at all.
  ///
  /// Does not notify, for the reason [inspecting] does not: the panel
  /// clears it from `dispose`.
  bool get panelOpen => _panelOpen;
  var _panelOpen = false;
  set panelOpen(bool value) {
    if (value == _panelOpen) return;
    _panelOpen = value;
    if (value) {
      _startWatch();
      _startLogs();
    } else {
      _stopWatch();
      _stopLogs();
    }
  }

  /// The box the guest last reported for [watchedNode], live.
  ///
  /// A notifier of its own, not a field behind [notifyListeners]. This
  /// arrives sixty times a second on an animating demo, and rebuilding the
  /// whole catalog view at that rate — entry list, panel, tree and all — to
  /// move one rectangle would cost far more than the watch saves. Only the
  /// painter listens.
  final watchedBox = ValueNotifier<WatchBox?>(null);

  /// The node whose box the guest should report.
  ///
  /// Whatever the pointer is over, which is the only thing that draws a
  /// rectangle — see the overlay's own note on why a *selection* deliberately
  /// draws nothing.
  ///
  /// Debounced, and this is the whole reason it is a setter rather than a
  /// call. Resolving an id costs the guest a full summary-tree walk — 8ms on
  /// the largest tree in the repo, measured — so sweeping the pointer down
  /// fifty rows would spend half a second of guest time resolving forty-nine
  /// nodes nobody stopped on. Highlighting stays instant regardless: it is
  /// drawn from the tree already in hand. What waits is only the *tracking*,
  /// which matters exactly when you have come to rest.
  String? get watchedNode => _watchedNode;
  String? _watchedNode;
  Timer? _watchSettle;
  set watchedNode(String? id) {
    if (id == _watchedNode) return;
    _watchedNode = id;
    // The old box named the old node. Kept for the moment it takes to resolve
    // the new one, it would draw the previous row's rectangle around this one.
    watchedBox.value = null;
    _watchSettle?.cancel();
    _watchSettle = Timer(const Duration(milliseconds: 120), () {
      if (_disposed || !_panelOpen) return;
      if (_inspect case var inspect?) _armWatch(inspect, 'tracking a node');
    });
  }

  StreamSubscription<WatchPush>? _watch;

  /// Subscribes, then turns the guest's watch on.
  ///
  /// That order matters: the guest starts pushing the moment the extension
  /// returns, and a subscription taken afterwards misses whatever landed in
  /// between.
  void _startWatch() {
    var inspect = _inspect;
    if (inspect == null || _watch != null) return;
    _watch = inspect.watches.listen(_onWatch);
    _armWatch(inspect, 'starting the watch');
  }

  /// Turns the guest's watch on, and turns it straight back off if the panel
  /// went away while the call was in flight.
  ///
  /// Which it can be for a while at startup. `watch` is one of the *required*
  /// extensions, and [GuestVmService.requireExtension] waits for a guest that
  /// has not registered yet rather than calling it missing — so this can be
  /// mid-wait when the panel closes, and [_stopWatch]'s own `unwatch` has run
  /// and returned by the time the watch actually starts. A guest left watching
  /// with no reader pays for it every frame.
  void _armWatch(InspectClient inspect, String what) {
    _fireAndForget(
      inspect.watch(nodeId: _watchedNode).then((_) {
        if (_disposed || !_panelOpen) unawaited(inspect.unwatch());
      }),
      what,
    );
  }

  void _stopWatch() {
    _watchSettle?.cancel();
    _watchSettle = null;
    _resizeSettle?.cancel();
    _resizeSettle = null;
    _scrollSettle?.cancel();
    _scrollSettle = null;
    unawaited(_watch?.cancel());
    _watch = null;
    watchedBox.value = null;
    // Fire and forget: a guest going away is the common case here, and the
    // tolerant form is what makes that a non-event.
    unawaited(_inspect?.unwatch());
  }

  void _onWatch(WatchPush push) {
    if (_disposed) return;
    // A push from before a switch describes a demo that is no longer on
    // screen. Not dropped in the guest, so that this can tell the difference
    // between "nothing moved" and "you are a switch behind".
    if (push.entryId != (selected ?? active)?.id) return;
    if (push.geometry case var box?) watchedBox.value = box;
    // Promptly, because a shape change is rare by nature — an animation moves
    // geometry, not structure — so there is nothing here to smooth out.
    if (push.structureChanged && _inspecting) unawaited(_rereadTree());
    if (push.structureChanged && _inspectingSemantics) {
      unawaited(readSemantics());
    }
    if (push.resized) _settleResize();
    if (push.scrolled) _settleScroll();
  }

  Timer? _scrollSettle;

  /// Catches up after something in the demo has scrolled.
  ///
  /// The staleness nothing else here could see. A scroll changes no
  /// widget's type, no widget's depth and not the demo's box, so neither the
  /// structure tier nor the resize tier fires — and the tree went on reporting
  /// the rects from before it. That is invisible in the numbers and very
  /// visible in the picker: the overlay is drawn from those rects, so after a
  /// scroll it named whatever used to be under the pointer and put the box
  /// wherever that had gone. Pressing refresh was the only way back, which is
  /// how it was found.
  ///
  /// Waited out rather than acted on, like [_settleResize] and more so: a fling
  /// reports on every frame of itself, and each one would otherwise queue a
  /// 17ms walk for a layout that has already moved on. One read per gesture,
  /// once it stops. Shorter than the resize window because this one ends a
  /// gesture the hand has already finished, and the tree is what the next hover
  /// reads.
  void _settleScroll() {
    _scrollSettle?.cancel();
    _scrollSettle = Timer(const Duration(milliseconds: 120), () {
      if (_disposed || !_panelOpen) return;
      if (_inspecting) unawaited(_rereadTree());
      if (_inspectingSemantics) unawaited(readSemantics());
    });
  }

  Timer? _resizeSettle;

  /// Catches up after the preview has been given a different box.
  ///
  /// Waited out rather than acted on, because a resize is a **drag**: the size
  /// changes on every frame of it, and each one would otherwise queue a tree
  /// read and a round of error clearing for a layout the pointer has already
  /// left behind.
  ///
  /// The errors go with it, and that is the half worth explaining. The record
  /// is of what the framework *said*, and nothing ever arrives to say an
  /// overflow stopped — so a `Row` that overflowed at one width went on being
  /// listed under Problems at every width after it, including the ones where it
  /// fits. Dragging the panel divider is precisely how you make that happen,
  /// and was how it was found.
  void _settleResize() {
    _resizeSettle?.cancel();
    _resizeSettle = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || !_panelOpen) return;
      if (_inspecting) unawaited(_rereadTree());
      if (_inspectingSemantics) unawaited(readSemantics());
      unawaited(forgetErrors());
    });
  }

  var _treeReading = false;
  var _treeReadPending = false;

  /// Re-reads the tree, at most one read at a time.
  ///
  /// The guest's structure push is a flag and costs it nothing; the read it
  /// asks for costs **17ms on the largest tree in the repo**, measured. So a
  /// demo whose shape moves on every frame — a list ticking, a menu animating
  /// open — would queue reads faster than they complete and never catch up.
  /// Coalescing here rather than debouncing in the guest keeps the decision
  /// where the cost is: the guest cannot know this reader is still busy.
  Future<void> _rereadTree() async {
    if (_treeReading) {
      _treeReadPending = true;
      return;
    }
    _treeReading = true;
    try {
      do {
        _treeReadPending = false;
        await readTree();
      } while (_treeReadPending && !_disposed && _inspecting);
    } finally {
      _treeReading = false;
    }
  }

  /// What the guest says is under a point, innermost last.
  ///
  /// The authoritative half of the picker. [InspectTree.nodeAtPoint] answers
  /// the same question from rectangles alone and answers it every frame, which
  /// is what the highlight follows; this runs the framework's own `hitTest`
  /// over the real render tree and is what a *click* commits to. Optimistic
  /// while you move, correct when you choose.
  ///
  /// Null when there is no guest or nothing of the demo is under the point —
  /// which is an answer, not a failure.
  Future<String?> nodeUnder(double x, double y) async {
    var inspect = _inspect;
    if (inspect == null) return null;
    var ids = await inspect.hitTest(x, y);
    return ids.isEmpty ? null : ids.last;
  }

  /// Tells the guest it is being rendered as [platform] — null for the panel's
  /// own rectangle, which renders as this machine.
  ///
  /// Deduped against the guest that was told, not only against the value.
  /// A fresh guest starts as itself and has to be told again even when nothing
  /// about the device moved — which is every restart, and would otherwise be a
  /// phone quietly rendering as a Mac for the rest of the session.
  void stageAs(DevicePlatform? platform) {
    var inspect = _inspect;
    if (inspect == null) return;
    if (_staged case (var told, var was)
        when identical(told, inspect) && was == platform) {
      return;
    }
    _staged = (inspect, platform);
    _fireAndForget(inspect.setStaging(platform), 'staging the guest');
  }

  /// Which guest was told what — see [stageAs].
  (InspectClient, DevicePlatform?)? _staged;

  /// What the guest's keyboard is doing, as the guest last said.
  ///
  /// Pushed rather than polled, because the transitions that matter are the
  /// *app's*: a field takes focus and the keyboard comes up on its own. A
  /// host that had to ask would find out a poll late, and the control drawn
  /// over the keyboard band would be drawn in the wrong place for that long.
  ///
  /// Null before the first push — a guest still starting, or one built before
  /// the extension existed.
  KeyboardState? get keyboard => _keyboard;
  KeyboardState? _keyboard;

  StreamSubscription<KeyboardState>? _keyboardStream;

  /// Tells the guest how tall its keyboard is and whether to raise it.
  ///
  /// Deduped against the guest that was told, exactly as [stageAs] is and for
  /// the same reason: a restart starts from the guest's own defaults, so a
  /// dedupe on the value alone would leave a fresh guest with no measurement
  /// and a mode nobody chose.
  void keyboardAs(KeyboardMode mode, double height, double? keypadHeight) {
    var inspect = _inspect;
    if (inspect == null) return;
    if (_keyboarded case (var told, var was)
        when identical(told, inspect) && was == (mode, height, keypadHeight)) {
      return;
    }
    _keyboarded = (inspect, (mode, height, keypadHeight));
    _fireAndForget(
      inspect.setKeyboard(
        mode: mode,
        height: height,
        keypadHeight: keypadHeight,
      ),
      'raising the keyboard',
    );
  }

  /// Closes the keyboard the way a platform does — what the dismiss key drawn
  /// over the band calls. The app is told, and lets go of the field itself.
  ///
  /// Clears the forced-up mode with it, so the key drawn on a manually raised
  /// keyboard actually takes it away rather than being undone by the next
  /// push. The guest does the same on its own side; both, because
  /// the mode lives here and the focus lives there.
  void dismissKeyboard() {
    var inspect = _inspect;
    if (inspect == null) return;
    if (_keyboarded case (var told, (KeyboardMode.up, var height, var keypad))
        when identical(told, inspect)) {
      _keyboarded = (inspect, (KeyboardMode.auto, height, keypad));
    }
    _fireAndForget(inspect.dismissKeyboard(), 'dismissing the keyboard');
  }

  /// Which guest was told what — see [keyboardAs].
  (InspectClient, (KeyboardMode, double, double?))? _keyboarded;

  void _onKeyboard(KeyboardState state) {
    if (_disposed || state == _keyboard) return;
    _keyboard = state;
    notifyListeners();
  }

  /// Forgets what the entry has reported, then reads it back.
  ///
  /// What the panel's refresh does, and what a reload does before it rebuilds.
  /// Nothing ever arrives to say a problem *stopped* — an overflow that a
  /// resize fixed goes on being reported, because the record is of what was
  /// said rather than of what is true now — so forgetting has to be a
  /// deliberate act, and it belongs to whatever asked for the rebuild.
  ///
  /// The read that follows will usually come back empty and fill again on the
  /// next poll, which is accurate: the frame that would re-report has not been
  /// painted yet.
  Future<void> forgetErrors() async {
    var inspect = _inspect;
    if (inspect == null) return;
    await inspect.clearErrors();
    if (_disposed) return;
    renderErrors = null;
    notifyListeners();
    await readErrors();
  }

  /// Asks the guest what the entry on screen reported.
  ///
  /// The guest forgets the previous entry's errors when it switches, so this
  /// describes this demo rather than the one before it.
  Future<void> readErrors() async {
    var inspect = _inspect;
    var entry = selected ?? active;
    if (inspect == null || entry == null) return;
    var report = await inspect.errors(entry.id);
    if (report == null || _disposed) return;
    renderErrors = report;
    notifyListeners();
  }

  /// Asks the guest for the tree of the entry on screen.
  ///
  /// Public because the panel offers a refresh: a demo's own state moves
  /// without anything here being told — you tapped, a menu opened — and until
  /// the watch lands (S5e) pressing the button is how the tree catches up.
  Future<void> readTree() async {
    var inspect = _inspect;
    var entry = selected ?? active;
    if (inspect == null || entry == null) return;
    var read = await inspect.tree(entry.id);
    if (read == null || _disposed) return;
    tree = read;
    notifyListeners();
  }

  /// Asks the guest what a screen reader would get for the entry on screen.
  ///
  /// Worth calling only while [inspectingSemantics] holds the guest's
  /// semantics on — reading a guest that builds none settles on nothing and
  /// leaves what is held here alone.
  Future<void> readSemantics() async {
    var inspect = _inspect;
    var entry = selected ?? active;
    if (inspect == null || entry == null) return;
    var read = await inspect.semantics(entry.id);
    if (read == null || _disposed) return;
    semantics = read;
    notifyListeners();
  }

  /// What the address asks each of the shell's axes to be, as slugs.
  ///
  /// A **request**, like [wantedEntryId], and for the same reason: which axes
  /// exist is something only the guest can say, and it cannot say it until the
  /// shell has built. So this is written whenever the address moves and
  /// resolved whenever resolving becomes possible.
  ///
  /// Slugs rather than the labels the guest wants — see [catalog_params.dart].
  /// Turning one into the other needs the declaration, which arrives later.
  Map<String, String> get axisSelections => _axisSelections;
  var _axisSelections = const <String, String>{};

  set axisSelections(Map<String, String> value) {
    if (mapEquals(value, _axisSelections)) return;
    _axisSelections = Map.unmodifiable(value);
    // Deliberately silent. This is written while the view is building — the
    // address is a dependency, so it arrives in `didChangeDependencies` — and
    // notifying there would mark the builder listening to this session dirty
    // mid-build. Nothing needs the notification anyway: the controls draw from
    // the address, not from here, and the guest is told below.
    //
    // Read back afterwards, like a knob: a shell's build decides what axes
    // exist, and setting one can reveal or retire another.
    _fireAndForget(_pushAxes().then((_) => _readAxes()), 'setting an axis');
  }

  /// What the address asks each of the entry's knobs to be, as slugs.
  ///
  /// The same shape as [axisSelections] and for the same reasons — a request
  /// resolved once the declaration arrives — differing only in lifetime. A knob
  /// belongs to the entry, so these go when the entry does; an axis belongs to
  /// the shell and does not.
  Map<String, String> get knobSelections => _knobSelections;
  var _knobSelections = const <String, String>{};

  set knobSelections(Map<String, String> value) {
    if (mapEquals(value, _knobSelections)) return;
    _knobSelections = Map.unmodifiable(value);
    // Silent, and read back afterwards — see [axisSelections].
    _fireAndForget(_pushKnobs(), 'turning a knob');
  }

  /// The last payload sent, encoded, so a switch that changes nothing costs no
  /// frame. Starts as the empty selection, which is what a guest begins with.
  var _pushed = '{}';

  /// Everything discovery found, broken or not, in discovery's own order.
  ///
  /// Sorted by id because that is how the scanner sorts, so merging the two
  /// lists puts a quarantined entry back exactly where it was rather than in a
  /// section of its own. A demo you are midway through editing should not move.
  ///
  /// [scannedEntries] until the daemon has spoken — the same set, in the same
  /// order, without the marks saying which of them build.
  ///
  /// **Held, not recomputed.** This is read from `build` by both panes, and it
  /// allocates and sorts the whole catalog — which for 145 entries is a
  /// measurable slice of every frame the panel draws, for an answer that only
  /// changes when the daemon reports. Both setters drop it; nothing else can
  /// change what it is made of.
  List<CatalogEntry> get allEntries => _allEntries ??= _daemonReported
      ? ([...entries, ...quarantined.map((q) => q.entry)]
          ..sort((a, b) => a.id.compareTo(b.id)))
      : scannedEntries;
  List<CatalogEntry>? _allEntries;

  /// The compiler's complaint about [entry], or null if it builds.
  String? compileErrorFor(CatalogEntry entry) {
    for (var broken in quarantined) {
      if (broken.entry.id == entry.id) return broken.error;
    }
    // Still broken as far as anybody knows. Asking for a quarantined entry
    // *is* the retry, so the daemon drops it from the quarantine and announces
    // that **before it has compiled anything** — which left the row looking
    // healthy for the several seconds the compile took, and then changing its
    // mind. Not a flicker: a claim, held long enough to read, that we had no
    // reason to make.
    //
    // So the last known error stands until the retry has actually decided. If
    // it compiles, nothing re-quarantines it and the marker goes for good; if
    // it does not, the announcement arrives before the switch returns and the
    // list above answers again.
    if (_retrying?.$1 == entry.id) return _retrying?.$2;
    return null;
  }

  /// The entry whose quarantine is being retried, and the error it had.
  (String, String)? _retrying;

  /// Why [selected] is not what the guest is showing, or null when it is.
  ///
  /// Covers both ways that happens: the entry does not compile, or it compiled
  /// and the reload was refused. Either way the guest keeps rendering the last
  /// thing that worked, and this is the text that explains the difference.
  String? get selectedError {
    var entry = selected;
    if (entry == null) return null;
    if (compileErrorFor(entry) case var error?) return error;
    var report = lastSwitch;
    if (report != null && report.entry.id == entry.id && !report.ok) {
      return report.error;
    }
    return null;
  }

  /// The guest's picture — see [GuestSurface]. Null until [start] has one.
  GuestSurface? get surface => _surface;
  GuestSurface? _surface;

  /// The embedder process behind [surface], for what only a process can do
  /// — the scene plugin's own guest rides on it. Null for a guest drawn
  /// inline.
  EmbeddedEngine? get engine => switch (_surface) {
    EmbeddedEngine engine => engine,
    _ => null,
  };

  /// Calls a service extension on this session's guest, or null when there is
  /// no guest to call.
  ///
  /// The one door another plugin reaches this guest through. The scene
  /// plugin shares the catalog's compiler and guest and has its own panel, so
  /// it needs to drive `ext.fw.scene.*` against whatever is running here. Deliberately not an `InspectClient`: that one is *this* plugin's
  /// vocabulary, and widening it every time somebody else needs a call is how
  /// one class ends up owning every plugin's protocol.
  Future<Map<String, dynamic>?> callGuestExtension(
    String method, {
    Map<String, String> args = const {},
  }) async => _channel?.callExtension(method, args: args);

  CatalogSource? _daemon;
  GuestChannel? _channel;

  /// The inspection reads and writes, shared with the headless path that `fw`
  /// and MCP go through — see [InspectClient]. Impatient compared with that
  /// one: this session drove the reload itself, so it is waiting only on the
  /// frame after it rather than on a whole cold build.
  InspectClient? _inspect;

  /// Whether this session announced itself — so a teardown that never got as
  /// far as a guest does not delete a handle belonging to another window.
  var _published = false;
  StreamSubscription<CatalogChanged>? _changes;
  StreamSubscription<AssetsChanged>? _assetsChanges;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// What the session is busy doing, or null when it is idle. A steady word,
  /// not a number: this is what a sidebar shows while the compiler works, and a
  /// figure that changes every second reads as movement rather than as news.
  String? get busyWith => _busyWith;
  String? _busyWith;

  /// What a *status surface* may say the session is doing.
  ///
  /// [busyWith] with a floor under it: null until the work has lasted
  /// [busyAppearsAfter], the same word afterwards. The two answer different
  /// questions and the difference is not cosmetic. [busyWith] is the truth, and
  /// the things that must not race the compiler read it the instant it changes
  /// — the capture path refuses to photograph a session that is working, and
  /// the reload button disables itself. A row in the rail is not one of those.
  ///
  /// Measured on this repo's catalog, which is where the floor comes from: a
  /// warm switch is 64ms, and a second click on the entry already on screen is
  /// `compile 17ms · reload 104ms · 0 edited` — 121ms of announcement for a
  /// frame that did not change. A word that arrives and leaves inside either is
  /// a flash rather than news, so neither says anything anywhere now, and the
  /// canvas arriving is the feedback.
  String? get visiblyBusyWith => _busyShown ? _busyWith : null;
  var _busyShown = false;

  /// Longer than a warm switch, shorter than a wait you would question.
  static const busyAppearsAfter = Duration(milliseconds: 250);

  /// How long the current [busyWith] has been running.
  ///
  /// Only counts up on screen where a counter is useful — the cold-start
  /// screen, which is a spinner and nothing else.
  Duration get busyFor => _busySince.elapsed;
  final _busySince = Stopwatch();
  Timer? _ticker;
  Timer? _busyFloor;

  /// [tick] rebuilds listeners each second so an elapsed readout advances. Off
  /// by default: everywhere but a dedicated loading screen, the label alone
  /// says what is happening and its disappearance says when it stopped.
  void _busy(String what, {bool tick = false}) {
    if (_disposed) return;
    // A word that changes without an [_idle] between — `compiling` becoming
    // `reloading` — is one stretch of work continuing, so the floor keeps
    // running rather than restarting. Otherwise a surface that had earned its
    // way on screen would blink off at the moment the work got longer.
    var continuing = _busyWith != null;
    _busyWith = what;
    if (!continuing) {
      _busyShown = false;
      _busyFloor?.cancel();
      _busyFloor = Timer(busyAppearsAfter, () {
        if (_disposed || _busyWith == null) return;
        _busyShown = true;
        notifyListeners();
      });
    }
    _busySince
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = !tick
        ? null
        : Timer.periodic(const Duration(seconds: 1), (_) {
            if (!_disposed && _busyWith != null) notifyListeners();
          });
    notifyListeners();
  }

  void _idle() {
    _busyWith = null;
    _busyShown = false;
    _busySince.stop();
    _ticker?.cancel();
    _ticker = null;
    _busyFloor?.cancel();
    _busyFloor = null;
    if (!_disposed) notifyListeners();
  }

  /// Brings up the daemon, the guest and the reload channel.
  Future<void> start({int width = 900, int height = 700}) async {
    // The one place a counter earns its keep: a cold compile is tens of seconds
    // behind a spinner, and the screen has nothing else on it.
    _busy('building', tick: true);
    try {
      var (daemon, ready) = await connectToDaemon(
        dartExecutable: p.join(flutterSdkRoot, 'bin', 'dart'),
        // Through the shared builder, so this panel and `fw run previews`
        // arrive at the same socket. See [DaemonConfig.forPackage] for what
        // happened when each side built its own.
        config: () => DaemonConfig.forPackage(
          appToolDirectory: appPackageRoot,
          packageRoot: projectRoot,
          flutterSdkRoot: flutterSdkRoot,
          roots: roots,
          previewAnnotations: previewAnnotations,
          clock: clock,
          setup: setup,
        ),
        onLog: (line) => debugPrint('[catalog] $line'),
        onProgress: _onDaemonProgress,
      );
      if (_disposed) {
        // Disposed while connecting — which spans the cold compile, i.e.
        // exactly when a config reload tears the plugin graph down. [dispose]
        // ran and closed a null; the client the await just produced is ours,
        // and leaked it holds the shared daemon's idle reaper open forever.
        unawaited(daemon.close());
        return;
      }
      _daemon = daemon;
      _clearDaemonLanes();
      timings = ready.timings;
      seed = ready.seed;
      warmStart = ready.warmStart;
      reusedDaemon = ready.reused;
      coldCompile = ready.coldCompile;
      // Already worth comparing: attaching to a daemon that has been up a while
      // means the handshake itself can be the first news that a demo was
      // written since the scan this session was built on.
      reportCatalog(ready.entries, ready.quarantined);
      diagnostics = ready.diagnostics;
      _changes = daemon.catalogChanges.listen(_onCatalogChanged);
      _assetsChanges = daemon.assetsChanges.listen(_onAssetsChanged);
      // Then whatever changed between the handshake and that subscription. The
      // ready message is a snapshot of the moment the daemon prepared, which for
      // a client attaching to a daemon that has been up a while is not the same
      // as now — another client's compile may have quarantined an entry since,
      // and the notice for it was addressed to a listener that did not exist yet.
      if (daemon.lastChange case var missed?) _onCatalogChanged(missed);
      if (_disposed) return;

      // The daemon refuses to start with an empty catalog, and the panel no
      // longer asks for a session until its own scan has found an entry, so
      // there are two gates in front of the line below. It is still stated
      // rather than assumed: `entries.first` on an empty list is `Bad state: No
      // element`, which names neither the catalog nor the directory it is empty
      // of.
      if (entries.isEmpty) {
        throw StateError(
          'the catalog daemon reported no entries, so there is nothing to '
          'show. Check the demo directory declared for this package in '
          'tool/flutterware.dart.',
        );
      }
      // **What to boot on, which is not the same as what to select.** The
      // guest has to come up rendering *something*, and which entry that is
      // costs nothing to change afterwards: measured on this repo, a cold start
      // is ~12.5s and a switch on the warm guest is ~49ms. So an address that
      // named no entry still warms the guest on the first one — it just does
      // not call that a selection.
      //
      // Which it used to, and the pick was arbitrary twice over: entries sort
      // by id while the tree sorts folders first and then by label, so the demo
      // that opened — rendered, its folder revealed, its id written into the
      // address — was routinely not even the row at the top of the list.
      //
      // The other half of the argument is one branch away, in [missingEntryId]:
      // an address naming an entry that does not exist is reported rather than
      // repaired, precisely because "silently showing the first demo" is not
      // information. Neither is showing it when the address named none.
      var warmUp = wantedEntry ?? entries.first;
      // Compiled before the guest exists, and whole.
      //
      // A session's bundle symlinks the kernel the daemon compiled when it
      // *started*, which lets a client that has just attached launch without
      // paying for a compile. What it costs is that the first frame is neither
      // necessarily this entry — the daemon prepared whichever one was first —
      // nor necessarily this source: every compile since has been a delta hot
      // reloaded into a guest that was already up, and nothing rewrites the
      // kernel a new guest boots from. So a panel opened against a daemon that
      // has been running a while names one entry and renders another, or renders
      // this one as it was written some edits ago, and then silently corrects
      // itself the first time anything reloads.
      //
      // Asking for a whole kernel first is what closes that: ~40ms on a warm
      // daemon, once per session, and it is what `HeadlessCatalog` has always
      // done before it launches a guest.
      var compiled = await daemon.select(warmUp.id, full: true);
      if (_disposed) return;

      var launched = await launchGuest(
        GuestLaunch(
          appPackageRoot: appPackageRoot,
          flutterSdkRoot: flutterSdkRoot,
          projectRoot: projectRoot,
          // Keyed by session, so a second panel — or an agent taking a
          // screenshot — does not bind over this guest's socket.
          sessionId: ready.sessionId,
          // Asked for here rather than read off the handshake: the build
          // happens on the first panel that opens, and this closure is
          // exactly that moment. A project that never opens one never builds
          // a host.
          buildGuest: () async => (
            hostPath: await daemon.hostPath(),
            assetsDir: ready.assetsDir,
            icuData: ready.icuData,
          ),
          width: width,
          height: height,
        ),
        attach: (surface) {
          _surface = surface;
          surface.addListener(_onEngineChanged);
        },
        abandoned: () => _disposed,
      );
      if (launched == null) return;
      var channel = _channel = launched.channel;
      // `dart:developer` logs from the guest, which its stdout never carries;
      // the studio's own output is where every other host line already goes.
      unawaited(
        channel
            .developerLog()
            .forEach((line) => debugPrint('[guest log] $line'))
            .catchError((Object _) {}),
      );
      _inspect = InspectClient(
        channel,
        patience: InspectPatience.live,
        abandoned: () => _disposed,
      );
      // The panel usually mounts *before* this — a cold start puts it on screen
      // with a spinner while the daemon compiles — and all of these need a
      // client to attach to. Asked for once at mount and once here, because
      // either can be the one that comes second; all are idempotent.
      if (_panelOpen) {
        _startWatch();
        _startLogs();
      }
      // Not gated on the panel being open, unlike the two above: this is one
      // small event per keyboard move rather than a per-frame push, and the
      // thing that draws on it — the dismiss key over the band — is part of
      // the picture rather than part of the inspector.
      _keyboardStream = _inspect!.keyboards.listen(_onKeyboard);
      if (_inspectingSemantics) _enableSemantics(_inspect!);
      // Announced only now: a URI published before the service answers is a
      // URI that fails to connect. From here on `fw` and an agent can read the
      // entry on screen rather than rendering their own copy of it. No await
      // between the disposed check above and this publish, so a session that
      // publishes is one whose [dispose] is still to come and will clear it.
      if (launched.vmServiceUri case var uri?) {
        LiveSession.publish(
          LiveSession(projectRoot: projectRoot, vmServiceUri: uri, pid: pid),
        );
        _published = true;
      }

      // Only when it was asked for. Nothing selected is a real state — the
      // stage says so and waits — and it is what a panel opened at the bare
      // plugin address lands in.
      selected = wantedEntry;
      // [active] is what the guest actually holds, asked for or not. A demo
      // that did not compile leaves it on the daemon's own kernel, so naming
      // this entry there would be a claim the status bar goes on repeating; the
      // report below is what puts the compiler's error where the widget would
      // have been.
      if (compiled.ok) {
        active = warmUp;
      } else if (selected != null) {
        // Reported only for an entry somebody asked for. A warm-up that failed
        // to compile is not a thing to complain about: nobody is looking at it,
        // and the complaint would occupy the stage that is meant to be saying
        // "pick a demo".
        lastSwitch = SwitchReport(
          entry: warmUp,
          compile: compiled.compile,
          reload: Duration.zero,
          newSourceCount: compiled.newSourceCount,
          editedCount: compiled.editedCount,
          error: compiled.error,
        );
      }
      phase = CatalogSessionPhase.ready;
      _idle();

      // **A request that arrived while the guest was booting.** Clicking a row
      // is live from the moment the list is — seconds before the guest — so
      // what was asked for can have moved since [warmUp] was chosen, and the
      // guest would otherwise sit on one entry while the panel named another.
      // Only when they differ: a warm-up that *is* the selection has already
      // been compiled, failure included, and re-asking for it would pay a
      // second compile to reach the same error.
      if (selected case var entry? when entry.id != warmUp.id) {
        unawaited(switchTo(entry));
      }
    } catch (e) {
      // Before the failure is recorded, because a strip still counting the
      // seconds of a start that died is the one reading worse than saying
      // nothing at all. The panel has the error and the error is the state.
      _clearDaemonLanes();
      _fail('$e');
    }
  }

  /// One lane per daemon phase, so the model's own rule — the longest-running
  /// lane is the one that speaks — resolves the daemon's three concurrent
  /// chains without this having to pick between them.
  void _onDaemonProgress(DaemonProgress progress) {
    if (_disposed) return;
    var lane = 'catalog:${progress.phase}';
    if (progress.done) {
      _daemonLanes.remove(lane);
      startup.report(lane, null);
      return;
    }
    _daemonLanes.add(lane);
    startup.report(lane, StartupTask(daemonPhaseLabel(progress.phase)));
  }

  /// The lanes this session opened, so they can be closed together.
  ///
  /// A phase that was announced started and never announced finished is what a
  /// connection dying mid-compile leaves behind, and nothing else would ever
  /// take it down.
  final _daemonLanes = <String>{};

  void _clearDaemonLanes() {
    for (var lane in _daemonLanes) {
      startup.report(lane, null);
    }
    _daemonLanes.clear();
  }

  /// Switches the guest to [entry] by hot reload.
  ///
  /// Switches are serialised: the daemon and the isolate each tolerate one
  /// in-flight operation, and a click-happy user must not interleave them.
  Future<void> switchTo(CatalogEntry entry, {bool ifChanged = false}) {
    // **Selected now, not when the compile finishes.** [selected] is what the
    // user last *asked for*, and asking happens here; assigning it at the far
    // end of the queue left a window where everything else read the previous
    // entry as the current intent.
    //
    // That window was a real bug, not a tidiness point. Opening the catalog at
    // an address queues a switch, and then `CatalogView` mounts and reloads
    // "whatever is selected" — which was still the entry before it. The reload
    // queued *behind* the address's switch and won, so arriving from search
    // landed on the last entry you had open, but only when the panel was not
    // already mounted.
    var previous = selected;
    // Remembered before anything moves: selecting a quarantined entry is how
    // you ask the daemon to try again, and the row must go on saying so until
    // it has. See [compileErrorFor].
    if (compileErrorFor(entry) case var error?) _retrying = (entry.id, error);
    selected = entry;
    // **And this is now what the address wants**, said here rather than waited
    // for. The panel writes the address back from a *post-frame callback*, so
    // between a click and the next frame boundary `_wantedEntryId` still names
    // the entry you came from — and anything that calls [_applyWanted] in that
    // window switches you back to it.
    //
    // Which is a race the daemon is unusually good at winning. Asking for a
    // **quarantined** entry *is* the retry, so the daemon drops it from the
    // quarantine and announces the change immediately, before it has compiled
    // anything (`compiler_daemon.dart:550`). That announcement arrives as a
    // `CatalogChanged`, `_onCatalogChanged` calls `_applyWanted`, and if the
    // frame has not turned over yet your click is undone. Whether it has is a
    // coin toss, which is exactly how it presented: clicking the entry that
    // does not compile takes somewhere between four and eight goes, at random.
    //
    // Selecting *is* wanting. Saying so closes the window without changing
    // what any of it means, and the address write that follows sets the same
    // value, which the setter already treats as nothing.
    _wantedEntryId = entry.id;
    // **And say so now.** Setting the field without this left the click
    // invisible until the queue reached [_switchTo] and `_busy` notified —
    // which for an entry the daemon has quarantined means waiting out a *fresh
    // compile attempt*, seconds of it. Nothing moved, so you clicked again,
    // which queued another compile behind the first. Five clicks, five
    // compiles, and the selection finally appearing looked like the fifth one
    // having worked.
    //
    // The comment above was already right that `selected` is what the user
    // asked for and that asking happens here. It just never told anybody.
    notifyListeners();
    _queue = _queue
        .then((_) => _switchTo(entry, previous: previous, ifChanged: ifChanged))
        .catchError((Object e) {
          _fail('$e');
        });
    return _queue;
  }

  /// Sends the entry's knobs what the address asks of them, and reads back
  /// what the demo made of it.
  ///
  /// Coalesced, not queued. A slider writes a value per frame of a drag,
  /// and each push is a round trip that waits for the guest's frame. Sent
  /// concurrently they land out of order — a slider that jumps backwards under
  /// the pointer; sent one at a time in a queue, the drag finishes seconds
  /// after your hand does. So one is in flight at a time and the rest is
  /// simply the latest state, which the address already holds: whatever the
  /// push catches up with is what gets sent.
  ///
  /// That works because a push is the *whole* set rather than a change. There
  /// is nothing to miss by skipping an intermediate value.
  Future<void> _pushKnobs() async {
    if (_pushingKnobs) return;
    _pushingKnobs = true;
    try {
      String? sent;
      while (true) {
        var inspect = _inspect;
        if (inspect == null) return;
        var payload = jsonEncode(paramPayloadFor(knobs.knobs, _knobSelections));
        if (payload == sent || payload == _pushedKnobs) break;
        sent = payload;
        _pushedKnobs = payload;
        await inspect.setKnobs(payload);
        if (_disposed) return;
      }
      // Once, after the last one: a demo's build decides what knobs exist, so
      // turning one can reveal or retire another — but only the settled state
      // is worth drawing.
      await _readKnobs();
      // And which *widgets* exist, which is the same fact one layer down —
      // and whether the build that produced them complained.
      await readErrors();
      if (_inspecting) await readTree();
      if (_inspectingSemantics) await readSemantics();
    } finally {
      _pushingKnobs = false;
    }
  }

  var _pushingKnobs = false;

  /// The last payload sent, so a push that would repeat itself costs nothing.
  var _pushedKnobs = '';

  /// Sends the shell on screen what the address asked for, in the labels it
  /// declared.
  ///
  /// Resolved here rather than held anywhere: [axisSelections] is slugs, the
  /// guest wants labels, and only the declaration joins the two. So this is
  /// recomputed on every push and nothing can fall out of step with the
  /// address.
  ///
  /// Only the shell on screen. This used to send every shell it had ever seen,
  /// so that one building for the first time had its values in hand rather than
  /// showing a frame of defaults first — but that needed a store of selections
  /// per shell, which is the thing the address replaced. A shell appearing for
  /// the first time now shows its defaults for one frame and is corrected as
  /// soon as it says what it declares.
  Future<void> _pushAxes() async {
    var inspect = _inspect;
    var shellId = axes.shellId;
    if (inspect == null || shellId == null) return;
    // Compared encoded rather than with [mapEquals], which is shallow: the
    // payload is a map of maps, and a fresh copy of an unchanged one is a
    // different object every time.
    var payload = jsonEncode({
      shellId: paramPayloadFor(axes.axes, _axisSelections),
    });
    if (payload == _pushed) return;
    _pushed = payload;
    await inspect.setAxes(payload);
  }

  /// Asks the guest what the shell on screen offers.
  ///
  /// Retried while the report names another *entry*, exactly as a knob read is,
  /// and for the same reason: the axes are recorded by the shell's build, so a
  /// read landing between the reload and the frame describes what was there
  /// before. Matching on the entry rather than the shell is what lets an entry
  /// whose wrapper is not a shell settle — it reports no shell and no axes, and
  /// that is an answer rather than something to keep waiting for.
  Future<void> _readAxes() async {
    var inspect = _inspect;
    var entryId = (selected ?? active)?.id;
    if (inspect == null || entryId == null) return;
    var report = await inspect.axes(entryId);
    // The guest never named this entry, or has no such extension. Either way
    // what is held describes a build nobody has replaced, so leave it.
    if (report == null || _disposed) return;
    axes = report;
    notifyListeners();
    // The shell may only just have said who it is. Nothing could be pushed
    // before that — [_pushAxes] needs a shell id — so a selection made while
    // the previous entry was on screen would otherwise never reach this one.
    // Self-dedupes when there is nothing new to send.
    await _pushAxes();
  }

  /// Asks the guest what the entry on screen offers.
  ///
  /// Retried while the report names another entry: the knobs are recorded by
  /// the demo's *build*, so a read that lands between the reload and the frame
  /// describes the entry that was there before. Giving up quietly after a few
  /// tries beats a panel that spins.
  Future<void> _readKnobs() async {
    var inspect = _inspect;
    var entry = selected;
    if (inspect == null || entry == null) return;
    var report = await inspect.knobs(entry.id);
    if (report == null || _disposed) return;
    knobs = report;
    notifyListeners();
  }

  /// Rebuilds what is on screen from the files as they are now.
  ///
  /// Literally a switch to the entry already selected: the daemon sweeps for
  /// edits on every request, so re-selecting is all a reload is — and
  /// because the daemon retries a quarantined entry on request, this is also
  /// how a demo that stopped compiling is asked again.
  ///
  /// Explicit rather than automatic on save: nothing watches the project yet,
  /// and a catalog that reloads itself mid-refactor is its own annoyance.
  ///
  /// **[selected], never [active].** The two differ exactly when the stage is
  /// showing the catalog rather than a demo: the guest goes on holding the last
  /// entry it loaded, because letting go of it would make the next click cost a
  /// cold start again. Reloading *that* re-selects it — so a page of pictures
  /// turned into a demo nobody had asked for. There is nothing on the stage for
  /// this to rebuild, and doing nothing is the honest answer.
  Future<void> reload() async {
    var entry = selected;
    if (entry == null) return;
    // Forgotten first, because the guest only resets its own record when the
    // *entry* changes — a reload of the one already on screen would otherwise
    // keep reporting the problem you have just been fixing. You edit, reload,
    // and the fixed overflow is still in the list.
    await forgetErrors();
    await switchTo(entry);
  }

  /// Asks the daemon whether entries have appeared or disappeared.
  ///
  /// Deliberately not a [reloadIfChanged]: this runs on a timer while you are
  /// looking at the panel, and a catalog that reloaded itself every few
  /// seconds — resetting the demo's state mid-refactor — is the thing we chose
  /// not to build. This notices new *entries* and nothing else.
  void refresh() => _daemon?.refresh();

  /// A [reload] that costs nothing when nothing was edited.
  ///
  /// For the triggers the user did not press — coming back to the window, or
  /// to the panel. The daemon answers `unchanged` rather than working, so the
  /// guest is not reassembled and the demo keeps whatever state it was holding;
  /// alt-tabbing must not be a way to lose your place.
  Future<void> reloadIfChanged() {
    var entry = selected;
    if (entry == null || phase != CatalogSessionPhase.ready) {
      return Future.value();
    }
    return switchTo(entry, ifChanged: true);
  }

  Future<void> _switchTo(
    CatalogEntry entry, {
    required CatalogEntry? previous,
    required bool ifChanged,
  }) async {
    var daemon = _daemon;
    var vmService = _channel;
    if (_disposed ||
        phase != CatalogSessionPhase.ready ||
        daemon == null ||
        vmService == null) {
      return;
    }

    // Told apart by where the user already was, so that asking again for the
    // entry on screen — or for the broken one they are fixing — reports what it
    // did rather than what a switch would have done.
    //
    // Against the selection as it stood when this was *asked for*, handed down
    // by [switchTo]: `selected` has already moved to `entry` by the time this
    // runs, so reading it here would call every switch a reload.
    var reloaded = entry.id == previous?.id || entry.id == active?.id;
    // Nothing to do about the device here any more. This used to push the
    // entry's `formFactor` into the staging, guarded so a reload would not undo
    // a pick — a mutation, an ordering rule, and a whole class of bug. The
    // entry's declaration is now a *default* read at build time behind whatever
    // the address says, so a switch changes what is on screen simply by
    // changing which entry is selected.
    _busy(reloaded ? 'reloading' : 'compiling');
    try {
      await _switchOnce(
        daemon,
        vmService,
        entry,
        reloaded: reloaded,
        ifChanged: ifChanged,
      );
    } finally {
      // Whatever it decided, the answer is in [quarantined] now — the daemon
      // re-files a failure before the request it came from returns.
      if (_retrying?.$1 == entry.id) _retrying = null;
      compilingSwitch = null;
      _idle();
    }
  }

  /// The entry a *switch* is compiling and reloading for, or null.
  ///
  /// What the canvas draws a loader over the stale picture for, and deliberately
  /// narrower than [busyWith]. Two things it is not:
  ///
  /// - **Not the fast path.** A switch the guest makes by itself is one frame,
  ///   and a loader that appeared and left inside it would be a flash on every
  ///   click. This is set at the moment the guest refuses, which is when the
  ///   slow path is known — no delay to tune, and nothing to flash.
  /// - **Not an edit reload.** Saving a file reloads the entry already on
  ///   screen, and what is on screen is still the answer to what you asked
  ///   for. Only a switch away from what the guest holds obscures its own
  ///   picture.
  CatalogEntry? compilingSwitch;

  Future<void> _switchOnce(
    CatalogSource daemon,
    GuestChannel vmService,
    CatalogEntry entry, {
    required bool reloaded,
    required bool ifChanged,
  }) async {
    // **The program the guest is running already holds every entry.** The
    // generated entrypoint imports them all, so moving between two of them is a
    // message and a frame — [InspectClient.showEntry] — rather than a compile,
    // a hot reload and a full reassemble to change which entry one getter
    // names. Measured on this repo's catalog: 347ms became 33ms. The headless
    // path has switched this way since the audit; the panel, which is where a
    // person actually feels it, had never been taught to.
    //
    // Only for a genuine switch. A [reloaded] call is ⌘R or the entry already
    // on screen, and an [ifChanged] one is the poll asking the compiler whether
    // a file moved — both want the compiler, and the guest would happily answer
    // "already showing it" and reload nothing.
    var inspect = _inspect;
    if (inspect != null &&
        !reloaded &&
        !ifChanged &&
        // A quarantined entry is not in the program at all, so the guest can
        // only refuse. Asking anyway would be a round trip to learn what the
        // daemon has already told us.
        compileErrorFor(entry) == null) {
      var watch = Stopwatch()..start();
      // Before the switch rather than after, for the reason the reload path
      // gives below: the shell reads its axes as it builds.
      await _pushAxes();
      if (await inspect.showEntry(entry.id)) {
        watch.stop();
        _afterSwitch(entry);
        lastSwitch = SwitchReport.shown(entry: entry, elapsed: watch.elapsed);
        notifyListeners();
        // **Said out loud, or the ask below is not cheap.** What the daemon
        // records per session is which entry this guest is rendering, and it
        // has no other way to learn that the guest moved on its own — so
        // without this the `ifChanged` below sees a mismatch, compiles, and
        // reassembles the guest to arrive where it already is. Measured
        // exactly that way: every fast switch was still followed by a 20ms
        // compile and a 98ms reload reporting `0 edited`.
        daemon.shown(entry.id);
        // **The click asked the compiler nothing, so ask it now.** Without this
        // an entry edited since the last look would show its previous build
        // until something else thought to check. Cheap by construction: the
        // daemon answers `unchanged` when nothing on disk moved, which is the
        // ordinary case, and when something did move this is the reload it
        // would have done anyway — behind a picture that is already right.
        await _switchOnce(
          daemon,
          vmService,
          entry,
          reloaded: true,
          ifChanged: true,
        );
        return;
      }
      // The guest refused: an entry it does not hold, or one from before the
      // extension. It says so with what it is actually showing rather than
      // raising, and the recovery is the compile and reload below.
    }

    // And now it is worth saying so on screen — see [compilingSwitch]. Said
    // here rather than at the top because everything above is a frame, and a
    // loader that came and went inside one is a flash on every click.
    if (!reloaded) {
      compilingSwitch = entry;
      notifyListeners();
    }

    var compiled = await daemon.select(entry.id, ifChanged: ifChanged);
    // Nothing on disk moved. Leave everything alone — including [lastSwitch],
    // which still describes the last thing that actually happened.
    if (compiled.unchanged) return;
    if (!compiled.ok) {
      // The guest keeps rendering the previous entry; a broken demo is a
      // reportable event, not the end of the session.
      lastSwitch = SwitchReport(
        entry: entry,
        compile: compiled.compile,
        reload: Duration.zero,
        newSourceCount: compiled.newSourceCount,
        editedCount: compiled.editedCount,
        reloaded: reloaded,
        error: compiled.error,
      );
      notifyListeners();
      return;
    }

    // Before the reload, not after: the shell reads its axes as it builds, so
    // a push that landed afterwards would mean one frame rendered with the
    // previous shell's selections and then a second correcting it.
    await _pushAxes();

    var watch = Stopwatch()..start();
    try {
      await vmService.reload(compiled.dill!);
    } catch (e) {
      // A refused reload leaves the guest exactly as it was, still rendering
      // the previous entry, so this is reportable rather than fatal — the same
      // rule a failed compile already follows. Ending the session would throw
      // away a working engine over one bad switch.
      lastSwitch = SwitchReport(
        entry: entry,
        compile: compiled.compile,
        reload: watch.elapsed,
        newSourceCount: compiled.newSourceCount,
        editedCount: compiled.editedCount,
        reloaded: reloaded,
        error: 'hot reload was refused: $e',
      );
      notifyListeners();
      return;
    }
    watch.stop();

    _afterSwitch(entry);
    lastSwitch = SwitchReport(
      entry: entry,
      compile: compiled.compile,
      reload: watch.elapsed,
      newSourceCount: compiled.newSourceCount,
      editedCount: compiled.editedCount,
      reloaded: reloaded,
    );
    notifyListeners();
  }

  /// What this side has to do once the guest is showing [entry], however it got
  /// there — a hot reload, or the guest switching itself.
  ///
  /// Everything here describes the *entry on screen*, so it belongs to the
  /// arrival rather than to the mechanism. Split out when the second mechanism
  /// arrived: a copy of it that forgot one of these reads would be a panel
  /// describing the previous demo, and only sometimes.
  void _afterSwitch(CatalogEntry entry) {
    active = entry;
    unawaited(_readKnobs());
    unawaited(_readAxes());
    // Not gated on the panel: this is what puts a badge on the Problems tab,
    // and a demo that throws should say so whether or not you were looking.
    unawaited(readErrors());
    if (_inspecting) unawaited(readTree());
    if (_inspectingSemantics) unawaited(readSemantics());
    // The guest cleared its own buffer on the switch, so this one has to go
    // too — otherwise the console reads as the new demo having printed what the
    // old one did. The sequence mark is deliberately *not* reset: the guest
    // goes on counting, and starting again from nothing here would discard
    // every line until its counter caught back up.
    guestLogs.value = const [];
    _logsDropped = 0;
    // A reload prints before anything has had a chance to hear it — the stream
    // is live, but the lines the demo wrote while starting are already in the
    // buffer and nowhere else.
    if (_panelOpen) unawaited(readLogs());
  }

  /// The daemon serves several clients, so the set of buildable entries can
  /// move without this session having asked for anything — a demo is edited and
  /// breaks, or is fixed and comes back.
  void _onCatalogChanged(CatalogChanged change) {
    reportCatalog(change.entries, change.quarantined);

    // An entry that stopped *compiling* keeps its place and stays selected —
    // the panel says why it is not rendering, and moving the user somewhere
    // else is what made a typo feel like losing your place.
    //
    // An entry that stopped *existing* is a different thing: it was deleted or
    // renamed, there is nothing to go back to, and staying on it would leave
    // the guest showing something the catalog no longer lists.
    var selectedId = selected?.id;
    if (selectedId != null &&
        !allEntries.any((e) => e.id == selectedId) &&
        entries.isNotEmpty) {
      unawaited(switchTo(entries.first));
    }

    // An entry the address asked for may have only just appeared — somebody
    // finished writing the demo the link points at. This is the second half of
    // "a request, not a call".
    if (phase == CatalogSessionPhase.ready) _applyWanted();
    notifyListeners();
  }

  /// The shared bundle moved under the guest — a file added to a declared
  /// directory, a pubspec edit — and the guest's caches still answer from the
  /// old one.
  ///
  /// `AssetManifest.bin` is the cache that matters: an added or removed key
  /// is a manifest change, and reassemble re-resolves every image against the
  /// fresh read (clearing the image cache with it, which also covers an
  /// edited file). Fonts are past helping here — the engine registered them
  /// at guest startup, and `asset_refresh_test.dart` measures that eviction
  /// does not move a glyph — so [AssetsChanged.fontsChanged] waits for the
  /// next guest launch. Relaunching this one automatically is a decision
  /// about losing the user's state, not a cache call, and is deliberately
  /// not taken here.
  void _onAssetsChanged(AssetsChanged change) {
    var vm = _channel;
    if (vm == null) return;
    _fireAndForget(
      reloadGuestAssets(
        change,
        (method, [args]) => vm.callExtension(method, args: args ?? const {}),
        onShaderError: (key, e) {
          if (!_disposed) debugPrint('[catalog] reloading $key: $e');
        },
      ),
      'refresh assets',
    );
  }

  void _onEngineChanged() {
    if (_surface?.phase == EmbeddedEnginePhase.error) {
      _fail(engine?.errorMessage ?? 'the embedder guest failed');
    } else {
      notifyListeners();
    }
  }

  /// Runs [work] with nothing waiting on it, and reports a failure.
  ///
  /// The panel drives the guest from setters and timers — an address changing,
  /// a pointer coming to rest — where there is no caller left to hand a failure
  /// to. `unawaited` alone hands it to the zone instead, which prints
  /// `Unhandled Exception` and a stack trace; and since these are the *required*
  /// writes rather than the tolerant reads (see [InspectClient.watch] for why
  /// they are required), throwing is something they genuinely do.
  ///
  /// Reported rather than swallowed, which is why those calls are strict: a
  /// watch that never started looks exactly like a demo that is not moving, and
  /// this is the line that tells the two apart.
  void _fireAndForget(Future<void> work, String what) {
    unawaited(
      work.then<void>(
        (_) {},
        onError: (Object e) {
          if (_disposed) return;
          debugPrint('[catalog] $what: $e');
        },
      ),
    );
  }

  void _fail(String message) {
    if (_disposed) return;
    // Also to stdout: a failure that only lands in the UI is invisible to
    // whoever is driving the harness through `flutter run`.
    debugPrint('[catalog] failed: $message');
    errorMessage = message;
    phase = CatalogSessionPhase.error;
    _idle();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _busyFloor?.cancel();
    _watchSettle?.cancel();
    _resizeSettle?.cancel();
    _scrollSettle?.cancel();
    unawaited(_watch?.cancel());
    unawaited(_logStream?.cancel());
    unawaited(_keyboardStream?.cancel());
    watchedBox.dispose();
    guestLogs.dispose();
    browsing
      ..removeListener(notifyListeners)
      ..dispose();
    staging
      ..removeListener(notifyListeners)
      ..dispose();
    _surface?.removeListener(_onEngineChanged);
    _surface?.dispose();
    // Withdraw the invitation before the guest goes. A handle left behind is
    // not fatal — the next reader fails to connect and deletes it — but it
    // costs that reader a timeout, and this session is the one thing that
    // knows for certain the guest is going away.
    if (_published) LiveSession.clear(projectRoot);
    unawaited(_channel?.close());
    unawaited(_changes?.cancel());
    unawaited(_assetsChanges?.cancel());
    unawaited(_daemon?.close());
    super.dispose();
  }
}

/// What a guest is launched with — everything an embedder process needs to
/// be built and started. A guest drawn inline reads none of it.
class GuestLaunch {
  const GuestLaunch({
    required this.appPackageRoot,
    required this.flutterSdkRoot,
    required this.projectRoot,
    required this.sessionId,
    required this.buildGuest,
    required this.width,
    required this.height,
  });

  final String appPackageRoot;
  final String flutterSdkRoot;
  final String projectRoot;
  final String sessionId;
  final Future<({String hostPath, String assetsDir, String icuData})> Function()
  buildGuest;
  final int width;
  final int height;
}

/// A launched guest: how to talk to it, and where its VM service is when it
/// is a process — null for a guest in this one.
typedef LaunchedGuest = ({GuestChannel channel, String? vmServiceUri});

/// Brings a guest up. [attach] receives the surface the moment it exists,
/// before it starts, so the session is listening while it boots; [abandoned]
/// says the session was disposed meanwhile, in which case the launcher cleans
/// up what it made and answers null.
typedef GuestLauncher = Future<LaunchedGuest?> Function(
  GuestLaunch launch, {
  required void Function(GuestSurface surface) attach,
  required bool Function() abandoned,
});

/// The default: an embedder process, painted into a texture and reached over
/// its VM service.
Future<LaunchedGuest?> launchEmbeddedGuest(
  GuestLaunch launch, {
  required void Function(GuestSurface surface) attach,
  required bool Function() abandoned,
}) async {
  var engine = EmbeddedEngine(
    appPackageRoot: launch.appPackageRoot,
    flutterSdkRoot: launch.flutterSdkRoot,
    workingDirectory: launch.projectRoot,
    name: launch.sessionId,
    buildGuest: launch.buildGuest,
  );
  attach(engine);
  await engine.start(width: launch.width, height: launch.height);
  if (abandoned()) return null;

  var uri = await engine.vmServiceUri;
  var vmService = await GuestVmService.connect(
    uri,
    describeGuest: () => engine.guestOutput,
  );
  if (abandoned()) {
    // Same shape as the connect above: [dispose] closed a null, so the
    // connection this await produced is ours to close.
    unawaited(vmService.close());
    return null;
  }
  return (channel: vmService, vmServiceUri: uri);
}
