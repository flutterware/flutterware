import 'dart:io';

// The pure-Dart file, not `previews_guest.dart`. This is on the compiler
// daemon's import closure, and the daemon must never reach Flutter — going
// through the barrel took `package:flutter` with it and made the daemon
// unloadable in a plain VM, which `entry_point_purity_test.dart` exists to
// catch and duly did. `src/clock.dart` imports nothing at all.
// ignore: implementation_imports
import 'package:flutterware/src/clock.dart' show pinnedClockOrigin;
import 'package:path/path.dart' as p;

import '../utils/source_code/escape_dart_string.dart';
import 'catalog_entry.dart';
import 'catalog_wrapper.dart';
import 'preview_setup.dart';

/// Writes the guest's entrypoint: one wrapper file per entry ever visited, plus
/// an accumulating `main.dart` that selects the active one.
///
/// Two rules from the spikes are structural here rather than enforced:
///
/// - **A fresh prefix per switch.** Each entry gets its own wrapper file
///   imported under its own prefix, so a prefix is never rebound to a different
///   library — which S3 measured as silently ignored.
/// - **Getters, never top-level finals.** A top-level `final` is initialised
///   once and hot reload does not re-run the initialiser, so the active entry
///   would freeze for the life of the session.
class EntrypointGenerator {
  EntrypointGenerator({
    required this.outputDir,
    required this.projectRoot,
    this.emitProbe = false,
    this.clock,
    this.setup,
  });

  /// Where generated sources are written. Must not be a directory anything
  /// else owns — regenerating clears the stale wrappers in it.
  final String outputDir;

  /// Resolves each entry's [CatalogEntry.path].
  final String projectRoot;

  /// Emits a periodic `FW-PROBE:` line naming the live entry and the text it is
  /// rendering, so a headless harness can assert what the guest actually shows
  /// rather than only that a reload reported success.
  final bool emitProbe;

  /// What `clock.now()` reads inside the guest, or null for
  /// [pinnedClockOrigin] — the project's own `fw.clock(...)`, so a preview and
  /// a scenario of the same project show the same date.
  final DateTime? clock;

  /// The package's declared setup, awaited in `main` once everything the host
  /// talks to is registered and before `runApp`. See `PreviewsPackage.setup`.
  ///
  /// Checked by whoever builds this — the daemon, before its first compile —
  /// so the import below is never of a file that is not there.
  final PreviewSetup? setup;

  /// The wrapper files themselves, written the same way the web build writes
  /// them — see [CatalogWrapperWriter] for why that sharing is structural.
  late final _wrappers = CatalogWrapperWriter(
    outputDir: outputDir,
    projectRoot: projectRoot,
  );

  final _wrapperIndex = <String, int>{};

  /// Never reused, even after a [drop]. A recycled index would point a live
  /// prefix at a wrapper written for a different entry, which S3 measured as
  /// silently ignored rather than an error.
  var _nextIndex = 0;

  String get entrypointPath => p.join(outputDir, 'main.dart');

  /// The entries whose wrappers are currently imported, in import order.
  Iterable<CatalogEntry> get visited => _visited;
  final _visited = <CatalogEntry>[];

  /// What the entrypoint on disk currently renders. Null when the last [drop]
  /// removed it and no [select] has chosen a replacement.
  CatalogEntry? get active => _active;
  CatalogEntry? _active;

  /// Imports every entry up front, so that from here on the only file a
  /// [select] changes is `main.dart`.
  ///
  /// This is what makes one compiler safe to share. Deltas are relative to the
  /// compiler's baseline, not to any particular guest: if a wrapper were added
  /// on one client's first visit, a second client selecting that same entry
  /// later would get a delta with the wrapper *missing* — unchanged since the
  /// baseline — and its guest, which never had that library, would reload
  /// nothing. Registering everything at once removes the divergence rather than
  /// tracking it.
  ///
  /// The cost is that a demo that does not compile breaks the catalog's cold
  /// start rather than only its own entry.
  List<Uri> registerAll(List<CatalogEntry> entries) => [
    for (var entry in entries) ..._register(entry),
  ];

  /// Makes [active] the rendered entry, adding it to the entrypoint if this is
  /// the first visit. Returns the files a caller should invalidate.
  List<Uri> select(CatalogEntry active) {
    Directory(outputDir).createSync(recursive: true);

    _active = active;
    var invalidated = _register(active);
    var entrypoint = File(entrypointPath);
    entrypoint.writeAsStringSync(_entrypoint(active));
    invalidated.add(entrypoint.uri);
    return invalidated;
  }

  /// Stops importing [entries], so nothing they pull in is compiled.
  ///
  /// How a demo that does not compile is kept from breaking the whole catalog:
  /// the wrapper file stays on disk, but an entrypoint that does not import it
  /// makes it unreachable, and the compiler only compiles what it can reach.
  /// Returns what to invalidate.
  List<Uri> drop(Iterable<CatalogEntry> entries) {
    var removed = false;
    for (var entry in entries) {
      if (_wrapperIndex.remove(entry.id) == null) continue;
      _visited.removeWhere((e) => e.id == entry.id);
      removed = true;
    }
    if (!removed) return [];

    var active = _active;
    if (active == null || _wrapperIndex.containsKey(active.id)) {
      // Rewritten, not merely invalidated: the file on disk is what the
      // compiler reads, so leaving the import in place would keep compiling
      // exactly what was just dropped.
      return select(active ?? _visited.first);
    }
    // The active entry was itself dropped; the caller has to choose another and
    // call [select]. Until then the entrypoint on disk is stale, so say so by
    // returning nothing to invalidate.
    _active = null;
    return [];
  }

  List<Uri> _register(CatalogEntry entry) {
    if (_wrapperIndex.containsKey(entry.id)) return [];
    Directory(outputDir).createSync(recursive: true);
    var index = _nextIndex++;
    _wrapperIndex[entry.id] = index;
    _visited.add(entry);
    var wrapper = File(p.join(outputDir, 'entry_$index.dart'));
    wrapper.writeAsStringSync(_wrappers.source(entry, index));
    return [wrapper.uri];
  }

  String _entrypoint(CatalogEntry active) {
    var imports = StringBuffer();
    var cases = StringBuffer();
    var ids = StringBuffer();
    for (var entry in _visited) {
      var index = _wrapperIndex[entry.id]!;
      imports.writeln("import 'entry_$index.dart' as fw$index;");
      // Escaped, never raw: an id is `path#symbol` unless the annotation pins
      // one with `id:`, and that one is free text a human typed.
      cases.writeln(
        '  ${escapeDartString(entry.id)} => (\n'
        '    preview: fw$index.fwPreview.transform(),\n'
        '    builder: fw$index.fwBuilder,\n'
        '  ),',
      );
      ids.writeln('  ${escapeDartString(entry.id)},');
    }
    // Round-tripped through ISO rather than spelled out as constructor
    // arguments: a project's own pin may carry seconds, or be UTC, and a
    // `DateTime(y, m, d, h, min)` literal silently drops both.
    var clockLiteral =
        'DateTime.parse(${escapeDartString((clock ?? pinnedClockOrigin).toIso8601String())})';
    var setup = this.setup;
    if (setup != null) {
      imports.writeln(
        'import ${escapeDartString(_wrappers.uriFor(p.join(projectRoot, setup.path)))} '
        'as fw_setup;',
      );
    }

    return '''
// GENERATED — do not edit.
${emitProbe ? "import 'dart:async';\n" : ''}import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutterware/previews_guest.dart';

$imports
// **Every entry, reachable by id.** The imports above already put the whole
// catalog in this program — that is what makes one compiler safe to share —
// and this is what lets the guest *use* it: the host switches demos with
// `ext.flutterware.showEntry` and a frame, instead of rewriting this file,
// recompiling it and hot-reloading a delta to move one integer.
//
// A switch expression rather than a map, so resolving an entry allocates one
// record instead of building the whole table on every build.
//
// Functions and getters, never top-level finals: a final is initialised once
// and hot reload does not re-run its initialiser, which would freeze the
// catalog at whatever it held when the guest started.
({Preview preview, Widget Function() builder})? _entry(String id) =>
    switch (id) {
$cases  _ => null,
};

List<String> get _entryIds => const [
$ids];

// Which entry *this* generation of the file means. A reload is how the panel
// says "show that one", so the file outranks a runtime switch whenever it
// moves — see [CatalogEntries].
const _fileEntryId = ${escapeDartString(active.id)};

// **The whole of main runs inside the log-capturing zone, binding and all.**
//
// Not a stylistic choice and not reversible: `PlatformDispatcher.onBeginFrame`
// captures `Zone.current` when it is *set*, and the binding sets it in
// `initInstances`. So a zone that started after `ensureInitialized` would have
// every build, layout and paint callback running in the zone that came before
// it — and a demo printing from `build`, which is the case this exists for,
// would print into the root zone and be captured by nothing at all.
//
// The clock is pinned outside all of it for the same reason, one layer up: a
// demo reads the clock from `build`, which runs in whatever zone the binding
// captured. A preview showing today's date would otherwise differ from
// yesterday's screenshot of itself.
void main() => withClock(Clock.fixed($clockLiteral), () => GuestLogs.instance.install(() ${setup == null ? '' : 'async '}{
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything can be typed, keys have to arrive at all: the framework
  // parks every one of them waiting for a legacy platform message this guest
  // cannot send. Both of these are replacements for platform plumbing the
  // guest does not have, and both must be up before the first frame.
  GuestKeyboard.instance.install();
  GuestTextInput.instance.install();
  // The fake keyboard, which is two facts meeting: what the app asks for
  // arrives from the control just installed, and how tall it is arrives from
  // the host. Installed before runApp because the app half is a framework
  // signal that can fire on the very first frame — an entry with an
  // autofocused field asks for a keyboard before anything has been drawn.
  CatalogKeyboard.instance.install();
  CatalogKeyboard.instance.registerExtensions();
  // Before runApp, and once, like every extension below: the host may ask for
  // another entry before the first frame, and switching must outlive the entry
  // it switches away from.
  CatalogEntries.instance.install(() => _entryIds);
  CatalogEntries.instance.registerExtensions();
  // Before runApp, and once: the panel may ask what knobs exist before the
  // first frame, and the extensions have to outlive every entry switch.
  CatalogKnobs.instance.registerExtensions();
  // The axes are pushed *in* rather than read out, and the push can land
  // before the shell that reads them has built — so this has to be up before
  // anything renders, not merely before the first question.
  CatalogAxes.instance.registerExtensions();
  // Reads the demo's own subtree rather than the whole app, which is what
  // CatalogGuest.demoRoot marks. Null until the first build, and that is an
  // answer: a headless host draws nothing until a frame is asked for.
  var inspector = GuestInspector(
    rootOf: () => CatalogGuest.demoRoot,
    entryIdOf: () => CatalogKnobs.instance.entryId,
  )..registerExtensions();
  // Off until something asks. The extension has to exist from the start for
  // the same reason the others do, but the per-frame work behind it costs
  // nothing until a panel turns it on.
  GuestWatch(
    inspector: inspector,
    rootOf: () => CatalogGuest.demoRoot,
    entryIdOf: () => CatalogKnobs.instance.entryId,
  ).registerExtensions();
  // Framework errors, on stdout *and* kept where they can be asked for.
  //
  // A demo that throws while building paints Flutter's red ErrorWidget in the
  // guest and nothing else changes: the compile succeeded, the reload
  // succeeded, and every check that asserts on those passes while the user
  // looks at an error. The stdout line makes that visible to a human watching
  // a terminal; the buffer makes it visible to `fw`, to MCP and to a panel,
  // which read stdout for nothing but the VM service URI.
  GuestErrors.instance.install();
  GuestErrors.instance.registerExtensions();
  // Whether every image the build asked for has arrived — what a capture
  // polls so it does not photograph a layout whose pixels are still decoding.
  GuestImages.instance.registerExtensions();
  // And what the demo prints, which reached the *host's* console and nowhere
  // else: the GUI could not show it, `fw` could not return it, and an agent
  // driving a demo could not read the first thing a developer reaches for.
  GuestLogs.instance.registerExtensions();
${setup?.statements ?? ''}  runApp(const CatalogHost(fileEntryId: _fileEntryId, entryOf: _entry));
${emitProbe ? _probe : ''}}));
''';
  }

  static const _probe = r'''
  Timer.periodic(const Duration(milliseconds: 200), (_) {
    var showing = CatalogEntries.instance.showing ?? _fileEntryId;
    var texts = <String>[];
    void visit(Element e) {
      var widget = e.widget;
      if (widget is Text && widget.data != null) texts.add(widget.data!);
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    // The view's own numbers, not a widget's: what the host's window metrics
    // actually became is the question a device frame drawn in another process
    // cannot answer any other way.
    var view = WidgetsBinding.instance.platformDispatcher.implicitView;
    var padding = view?.padding;
    var insets = view?.viewInsets;
    print(
      'FW-PROBE: $showing | ${_entry(showing)?.preview.name} '
      '| ${texts.join(' / ')} '
      '| padding ${padding?.top},${padding?.bottom} '
      'insets ${insets?.top},${insets?.bottom}',
    );
  });
''';
}
