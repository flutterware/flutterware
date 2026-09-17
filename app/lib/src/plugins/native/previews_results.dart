import 'package:flutterware/plugins.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart' show InspectStyle;
// ignore: implementation_imports
import 'package:flutterware/src/inspect/screen.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../delta/branch_delta.dart';

part 'previews_results.g.dart';

/// What the Previews actions hand back.
///
/// Classes rather than hand-built maps, for three reasons that all showed up in
/// this plugin: the compiler checks a field name and does not check `'entires'`;
/// `toJson` is generated from the fields, so the wire form cannot drift from
/// the type; and the *shape* of each class is extracted statically into
/// `docs/capabilities.md`, so a field added here is documented without anyone
/// remembering to.
///
/// Nullability is load-bearing. A shape derived from sample output can only say
/// which fields happened to be present; these say which are optional, which is
/// the difference between "this package has no error" and "this package cannot
/// have one".

/// `entries` — every catalog entry, per declared package.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogEntriesResult implements PluginResult {
  CatalogEntriesResult({required this.packages});

  final List<CatalogPackageEntries> packages;

  @override
  Map<String, Object?> toJson() => _$CatalogEntriesResultToJson(this);
}

/// One package's entries, or why they could not be read.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogPackageEntries {
  CatalogPackageEntries({
    required this.path,
    required this.directory,
    this.entries = const [],
    this.tree = const [],
    this.diagnostics = const [],
    this.error,
    this.authoring,
    this.branch,
  });

  /// Package path as declared in `tool/flutterware.dart`.
  final String path;

  /// What this branch changed among [entries], against which base. Absent
  /// when no base resolved, nothing changed, or the delta has not been read.
  final BranchChangeSummary? branch;

  /// Where this package's demos were looked for, relative to the package.
  ///
  /// Reported on every answer, not only the empty one: an entry list that does
  /// not say where it came from cannot be told apart from one that came from
  /// the wrong place, and "there are no demos" and "we looked in the wrong
  /// directory" are the same sentence until this is present.
  final String directory;

  final List<CatalogEntrySummary> entries;

  /// [entries] arranged the way the catalog is meant to be read: folders, then
  /// a level per file that holds several entries, then the entries.
  ///
  /// Reported rather than left to be rebuilt, because a rebuilt one is wrong
  /// quietly. Everything needed to derive this was already in [entries] and
  /// the arrangement rules were not — the shared leading directories are
  /// dropped, folders sort before entries, both alphabetically, and a folder's
  /// label is the directory segment as written while a derived group's is
  /// humanised. A consumer who reconstructed it from ids got a plausible tree
  /// in an order the panel never shows, twice, having read the source both
  /// times. This is the same `buildCatalogTree` the panel and the web export
  /// draw, so there is one arrangement and not three.
  final List<CatalogEntryNode> tree;

  /// Discovery's complaints — a duplicate id, an uncallable target.
  final List<String> diagnostics;

  /// Set when the scan failed, in which case [entries] is empty and means
  /// nothing.
  final String? error;

  /// How to write the first demo. Set **only** when there are none, which is
  /// the one moment the reader is certainly asking.
  final String? authoring;

  Map<String, Object?> toJson() => _$CatalogPackageEntriesToJson(this);
}

/// One row of the entry tree: a folder, a file's group of variants, or an
/// entry.
///
/// A branch has [children] and a leaf has an [entry]; never both, and the
/// distinction is what the field's presence means rather than a `kind` string
/// to compare against. The leaf carries only the id, because the entry itself is
/// already in the flat list under that id — a tree that repeated the payload
/// would be a second answer to keep in agreement with the first.
///
/// Not `CatalogTreeNode`, which this plugin already uses for a node of the
/// *widget* tree an entry renders. Two trees, and the shape names are published
/// in `docs/capabilities.md`, where one of them would have quietly become the
/// other.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogEntryNode {
  CatalogEntryNode({required this.label, this.entry, this.children = const []});

  /// What the panel shows on this row: a directory segment as it is written on
  /// disk, a group as it was declared or humanised from the file name, or an
  /// entry's name.
  final String label;

  /// The entry this leaf renders, as `screenshot --entry` takes it. Absent on a
  /// branch.
  final String? entry;

  /// What is under this branch, in the order it is shown. Empty on a leaf.
  final List<CatalogEntryNode> children;

  Map<String, Object?> toJson() => _$CatalogEntryNodeToJson(this);
}

/// `new` — the first demo, written for somebody who has none.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogNewResult implements PluginResult {
  CatalogNewResult({
    required this.package,
    required this.file,
    required this.name,
    required this.id,
    required this.next,
  });

  final String package;

  /// The written file, package-relative.
  final String file;

  final String name;

  /// What `screenshot --entry` and `describe --entry` take for it, so the next
  /// call needs no translation.
  final String id;

  /// The command that renders what was just written. A scaffold that does not
  /// say how to look at itself sends the reader back to `actions`.
  final String next;

  @override
  Map<String, Object?> toJson() => _$CatalogNewResultToJson(this);
}

/// One entry, as every surface identifies it.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogEntrySummary {
  CatalogEntrySummary({
    required this.id,
    required this.name,
    required this.address,
    this.group,
    this.device,
    this.devices = const [],
    this.change,
  });

  /// What `screenshot --entry` and `describe --entry` take.
  final String id;

  /// How this branch touched the entry — `added`, `edited` or `reached`, with
  /// a sentence — or absent when it did not. See `EntryChangeKind`.
  final EntryChange? change;

  final String name;

  /// The `Address`, rendered — hand it back to `screenshot`, or later `show`.
  final String address;

  /// One tree level between the directory and the leaf, when the entry
  /// declares or derives one.
  final String? group;

  /// What a `screenshot` of this entry that names no device will be framed as
  /// — the head of [devices], absent when it is the plain rectangle.
  ///
  /// Reported because the canvas is otherwise invisible, and an invisible
  /// default is how a picture ends up wrong without looking wrong. A caller
  /// reading this list can see that one entry is a phone and its neighbour a
  /// desktop, which is the fact the declaration exists to carry — and hand the
  /// id straight back as `--device` to ask for the same framing on purpose.
  final String? device;

  /// Every device the entry's canvas offers, [device] first. Empty when the
  /// package declared none for this subtree.
  final List<String> devices;

  Map<String, Object?> toJson() => _$CatalogEntrySummaryToJson(this);
}

/// `check` — what the compiler can and cannot build.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogCheckResult implements PluginResult, ReportsFailure {
  CatalogCheckResult({required this.packages});

  final List<CatalogPackageCheck> packages;

  /// False when any package has a quarantined entry or could not be compiled
  /// at all — the same rule [CatalogAuditResult.ok] follows, one lane cheaper.
  ///
  /// A package that failed outright reports `ok: false` already: the error
  /// path leaves the flag at its default, so nothing here has to test for it
  /// twice.
  @override
  bool get ok => packages.every((package) => package.ok);

  @override
  Map<String, Object?> toJson() => _$CatalogCheckResultToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogPackageCheck {
  CatalogPackageCheck({
    required this.path,
    this.ok = false,
    this.servable = const [],
    this.broken = const [],
    this.error,
  });

  final String path;

  /// True when nothing is quarantined.
  final bool ok;

  /// Entry ids the compiler built.
  final List<String> servable;

  final List<CatalogBrokenEntry> broken;

  /// Set when the daemon could not be reached at all, which is not the same as
  /// "everything failed to compile".
  final String? error;

  Map<String, Object?> toJson() => _$CatalogPackageCheckToJson(this);
}

@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogBrokenEntry {
  CatalogBrokenEntry({required this.id, required this.error});

  final String id;

  /// The compiler's diagnostics, verbatim.
  final String error;

  Map<String, Object?> toJson() => _$CatalogBrokenEntryToJson(this);
}

/// `describe` — one entry, and optionally the knobs it declares.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogEntryDescription implements PluginResult {
  CatalogEntryDescription({
    required this.id,
    required this.name,
    required this.package,
    required this.file,
    required this.symbol,
    required this.annotation,
    required this.address,
    this.group,
    this.knobs,
    this.axes,
    this.shell,
  });

  final String id;
  final String name;

  /// Which declared package holds it.
  final String package;

  /// Project-relative path of the declaring file.
  final String file;

  /// The annotated top-level function.
  final String symbol;

  /// The annotation's source text, verbatim — `Preview(name: 'Counter')`.
  final String annotation;

  final String address;
  final String? group;

  /// Present only when `--knobs` asked for them: reading a knob costs a
  /// compile and a frame, so absent means "not looked at" while an empty list
  /// means "this entry declares none".
  final List<CatalogKnob>? knobs;

  /// What the shell around the entry offers — theme, locale. Same nullability
  /// rule as [knobs], and the same cost.
  ///
  /// An axis is a knob with a different lifetime: a knob belongs to the entry
  /// and goes with it, an axis belongs to the shell and does not.
  final List<CatalogKnob>? axes;

  /// Which shell declared [axes]. Null when the entry's wrapper is not a shell,
  /// which is an answer rather than a failure.
  final String? shell;

  @override
  Map<String, Object?> toJson() => _$CatalogEntryDescriptionToJson(this);
}

/// One control an entry offers, flattened for the wire.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogKnob {
  CatalogKnob({
    required this.name,
    required this.kind,
    this.value,
    this.defaultValue,
    this.min,
    this.max,
    this.options = const [],
  });

  final String name;

  /// `string`, `boolean`, `integer`, `number`, `picker`.
  final String kind;

  /// What it is currently set to.
  final Object? value;

  /// What the demo renders with when nothing is set — also what it shows
  /// outside the catalog.
  @JsonKey(name: 'default')
  final Object? defaultValue;

  /// Bounds, when the demo gave any. Both present is a slider.
  final num? min;
  final num? max;

  /// A picker's labels, in declaration order.
  final List<String> options;

  Map<String, Object?> toJson() => _$CatalogKnobToJson(this);
}

/// One widget in the tree.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogTreeNode {
  CatalogTreeNode({
    required this.id,
    required this.type,
    required this.depth,
    this.description,
    this.source,
    this.local = false,
    this.offstage,
    this.rect,
    this.constraints,
    this.flex,
    this.flexChild,
  });

  /// The child-index path from the demo's root — `''`, `0`, `0/1`.
  ///
  /// Derived from the tree's shape and never assigned, because every `fw`
  /// invocation and every MCP call is a fresh process: an id minted by one of
  /// them means nothing to the next. Pass it back to `screenshot --node` or
  /// `tree --node`.
  final String id;

  /// The widget's runtime type.
  final String type;

  /// How deep below the demo's root, so a flat list still reads as a tree.
  final int depth;

  /// The framework's one-line description when it says more than [type] does
  /// — `Text("Save")` rather than `Text`.
  final String? description;

  /// `path/to/file.dart:12:5`, project-relative.
  ///
  /// Absent for a widget the compiler did not stamp. That is the whole of what
  /// `DaemonConfig.trackWidgetCreation` buys, and why it is on.
  final String? source;

  /// Whether the framework counts this as the user's code rather than
  /// `package:flutter`'s.
  final bool local;

  /// Present and true when this widget is in the tree but not on the screen —
  /// a route kept alive under the current one, `Offstage`, a hidden
  /// `IndexedStack` child.
  ///
  /// In `tree` it is the top of a subtree that was folded away (pass its id
  /// to `--node` to read inside); in `matches` it is a warning that the found
  /// widget is not on any screenshot, and its [rect] is where it *was*.
  final bool? offstage;

  /// Where it ended up: `x,y w×h`.
  ///
  /// Absent for a widget with no box of its own — a provider, a builder —
  /// which is most of a summary tree. Absent and "zero-sized" are different
  /// answers and only one of them is a bug, which is why this is nullable
  /// rather than zero-filled.
  final String? rect;

  /// What the parent allowed: `w 0.0..900.0, h 0.0..∞`.
  ///
  /// The other half of every layout question. A box that is 0 wide because it
  /// was handed `maxWidth: 0` is a different bug from one that chose to be,
  /// and the size alone cannot tell them apart.
  final String? constraints;

  /// For a `Row`, `Column` or `Flex`: `horizontal, start, center, max`.
  final String? flex;

  /// For a *child* of one: `flex 2 (tight)`, read off the parent data.
  final String? flexChild;

  Map<String, Object?> toJson() => _$CatalogTreeNodeToJson(this);
}

/// One thing the framework reported.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogRenderError {
  CatalogRenderError({
    required this.exception,
    this.library,
    this.context,
    this.count = 1,
  });

  final String exception;

  /// `widgets library`, `rendering library` — which tells a layout overflow
  /// from a failed image load without reading the message.
  final String? library;

  /// What the framework was doing: `during layout`, `while painting`.
  final String? context;

  /// How many times this exact error was reported. An error thrown from
  /// `paint` fires once per frame.
  final int count;

  Map<String, Object?> toJson() => _$CatalogRenderErrorToJson(this);
}

/// `inspect` — one rendered build, and every projection of it that was asked
/// for.
///
/// The one result shape that replaced four. `tree`, `find`, `at` and
/// `errors` were not four capabilities; they were four questions about the same
/// frame, each paying its own compile, guest launch and render to answer one of
/// them. Three questions was three renders, and for an agent in a UI edit loop
/// that was the dominant per-iteration cost.
///
/// Every section is **absent unless it was asked for**, which is what keeps the
/// default answer small. `includeIfNull: false` does that in the JSON;
/// [nodeCount] and friends are nullable for the same reason. Zero nodes and no
/// tree requested are different answers.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogInspectResult implements PluginResult, ProducesArtifacts {
  CatalogInspectResult({
    required this.entry,
    required this.address,
    required this.readFrom,
    required this.ok,
    required this.errors,
    required this.lens,
    this.screen,
    this.styles,
    this.nodes,
    this.tree,
    this.find,
    this.at,
    this.atOuterElided,
    this.logs,
    this.logsDropped,
    this.screenshot,
    this.note,
    this.next,
  });

  final String entry;
  final String address;

  /// Where this reading came from: `live` when it was taken from a session
  /// somebody has open — the demo in whatever state they left it, including
  /// anything they reached by clicking — and, when this call built and drew
  /// its own copy, **which engine drew it**: `harness` for the
  /// `flutter_tester` lane, `guest` for the embedder.
  ///
  /// Always present, not only on the interesting case. A caller that gets
  /// two different answers to the same invocation has to be able to see why,
  /// and an absent field is not an answer.
  ///
  /// It never reads `live` unless `live: true` was asked for *and* a session
  /// happened to be open on this entry; attaching is opt-in precisely because
  /// it makes the same command answer differently depending on what window is
  /// open. Between the other two it reads `harness` unless something sent the
  /// call to the guest — `engine=guest`, or `logs`, which only the guest can
  /// collect. The two agree about the layout and that is pinned by a test;
  /// where they differ is the clock, so a `guest` picture is of whatever real
  /// instant the render landed on and a `harness` one is reproducible.
  ///
  /// It matters most for the errors and the logs: `live` means these are what
  /// the demo has reported **since somebody opened it**, so a throw reached by
  /// clicking is in the list. No fresh render can produce that one, because no
  /// fresh render ever performs the click.
  final String readFrom;

  /// Whether it rendered without the framework reporting anything.
  ///
  /// Present on every answer, whatever else was asked, because it is the
  /// question behind asking at all — and because with no flags at all it *is*
  /// the answer. Stated rather than left to be inferred from an empty list: the
  /// question people ask is "is this one broken", and a caller should not have
  /// to know that zero errors means fine.
  final bool ok;

  final List<CatalogRenderError> errors;

  /// The lens the unset flags came from — `act`, `look`, `design` or `raw`.
  /// Said on every reply, because a caller who does not know a picture was
  /// available cannot ask for one.
  final String lens;

  /// What rendered: the things that carry words or respond to touch, nested
  /// under the layout's branch points, with their boxes and their state.
  ///
  /// The default answer now. `inspect` used to report only whether the
  /// framework complained, which says a build happened and nothing about what
  /// it drew; this is a rough picture of the screen in a few hundred tokens,
  /// and the handle for deciding what to ask next.
  final Screen? screen;

  /// Every distinct text size, weight and colour, most-used first with a
  /// sample. ~185 tokens for the whole type ramp.
  final List<InspectStyle>? styles;

  /// How many nodes the preview drew, whether or not the tree rode back — the
  /// number that says whether asking for `tree` is affordable.
  final int? nodes;

  /// The tree, when `--tree` asked for it. Depth-first, root first.
  final List<CatalogTreeNode>? tree;

  /// The nodes matching `--find`.
  ///
  /// Its own section rather than sharing [tree], because they answer different
  /// questions and a caller that asked both should get both labelled. Merging
  /// them into one list would make "the tree" and "the three nodes I searched
  /// for" indistinguishable in the reply.
  ///
  /// Named `find` after the flag that asks for it, the same word the run
  /// plugin answers under — the point of a shared grammar is that a query
  /// against a preview and one against a live app differ in which frame was
  /// read and in nothing anyone has to learn twice.
  final List<CatalogTreeNode>? find;

  /// The chain under `--at`, outermost first — the thing under a cursor is
  /// usually a `Text` and the thing meant is the button around it.
  ///
  /// Filtered and capped, like every other query here. The raw chain is
  /// measured at 35 nodes and 1258 tokens, of which the outer twenty are the
  /// wrapper run that sits under every point of every screen; the innermost
  /// eight carry the answer.
  ///
  /// An empty list is an answer: nothing of the demo's is at that point.
  final List<CatalogTreeNode>? at;

  /// How many outer nodes of the chain were left out, when the cap bit.
  final int? atOuterElided;

  /// What the demo printed, when `--logs` asked.
  final List<String>? logs;

  /// How many earlier lines fell off the guest's buffer, when any did.
  ///
  /// Said rather than silently begun in the middle: a scrollback that quietly
  /// starts partway reads as one that has everything.
  final int? logsDropped;

  /// The picture, when `--screenshot` asked for one.
  ///
  /// An [Artifact] rather than a path, because a PNG produced here is the same
  /// kind of thing `screenshot` produces: it has an identity — the address
  /// records the device, the size, the knobs, the axes, the debug flags, the
  /// crop and whether it was annotated — so asking twice with the same flags
  /// overwrites one file and asking with different flags does not. A bare path
  /// would have made this the one place in the surface where a picture is less
  /// than an artifact.
  final Artifact? screenshot;

  /// Something this reading could not answer, said in a way a caller can act
  /// on — the render happened, so it is not an error.
  ///
  /// The same field the run and scenario surfaces carry, for the same reason:
  /// a projection is a decoration on an observation, and a decoration that
  /// fails may cost its own field and nothing else.
  final String? note;

  /// One line naming what else can be asked of this frame.
  ///
  /// The same rule the refusals follow. A schema read once at connection time
  /// is not where anyone looks on step forty, so the reply that could have
  /// answered more says what it could have answered — about twenty tokens,
  /// and the difference between a drill-down that exists and one that is used.
  final String? next;

  /// [screenshot], where a surface that can render a picture will look for it.
  ///
  /// Without this the flag quietly did half its job. `screenshot` returns an
  /// `Artifact` as its whole value, so MCP turns it into an image and the agent
  /// sees the widget; `inspect --screenshot` carries one in a *field*, which
  /// reaches `JobResult.artifacts` only through this interface — so it came back
  /// as a path and nothing else. The caller most likely to hit that is the one
  /// that took the action's own advice and folded the picture into the render it
  /// was already paying for.
  ///
  /// `includeToJson: false` because the artifact is already on the wire under
  /// `screenshot`; this is the same value by the route a renderer looks down.
  @override
  @JsonKey(includeToJson: false)
  List<Artifact> get artifacts => [?screenshot];

  @override
  Map<String, Object?> toJson() => _$CatalogInspectResultToJson(this);
}

/// `audit` — every entry, and whether it compiles and renders.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogAuditResult implements PluginResult, ReportsFailure {
  CatalogAuditResult({
    required this.checked,
    required this.broken,
    required this.entries,
    this.network = 0,
    this.unreachable = const [],
  });

  /// How many entries were looked at.
  final int checked;

  /// How many entries had a network fetch fail — which under `flutter_test`
  /// is every network fetch, the binding answering 400 to all of them. Those
  /// failures do not count an entry [broken], because they are the lane's and
  /// not the code's; the count is here so setting them aside is never silent.
  /// An entry that renders a remote image is checked for everything *except*
  /// that image, in this lane, forever.
  final int network;

  /// How many of them are broken — the number the whole thing exists to
  /// produce, so that a caller has an answer before it has read a list.
  final int broken;

  /// Only the ones with something to say.
  ///
  /// A passing entry contributes to [checked] and nothing else: an audit of a
  /// healthy repo should be a line rather than a page, or it will not be run
  /// twice.
  final List<CatalogAuditEntry> entries;

  /// Packages that could not be audited at all, which is not the same as a
  /// package whose entries are fine.
  ///
  /// Kept separate from [entries] and out of [checked] deliberately: an audit
  /// that quietly counted an unreachable package as clean would report a green
  /// repo on the strength of not having looked.
  final List<CatalogAuditFailure> unreachable;

  /// False when anything at all is wrong — what makes `fw run previews audit`
  /// exit 1, and what makes it a line a CI job can be gated on.
  ///
  /// [unreachable] counts, for the reason it is a separate list: a package the
  /// audit could not reach is a result nobody has checked, and exiting 0 on it
  /// would report a green repo on the strength of not having looked.
  @override
  bool get ok => entries.isEmpty && unreachable.isEmpty;

  @override
  Map<String, Object?> toJson() => _$CatalogAuditResultToJson(this);
}

/// One entry that did not come through clean.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogAuditEntry {
  CatalogAuditEntry({
    required this.id,
    required this.address,
    required this.compiles,
    this.compileError,
    this.device,
    this.errors = const [],
    this.stillWaitingOn,
  });

  final String id;
  final String address;

  /// False when the compiler quarantined it. A quarantined entry has no
  /// [errors] — it never ran, and inventing an empty list would read as
  /// "rendered fine".
  final bool compiles;

  /// The compiler's diagnostics, verbatim.
  final String? compileError;

  /// The screen it was rendered on — the entry's declared canvas, or whatever
  /// the call named for the whole run. Absent for the plain rectangle, and for
  /// an entry that never compiled and so was never framed at all.
  ///
  /// An overflow is a fact about a size. A row that does not say which one
  /// cannot be reproduced without guessing the device back, and cannot be told
  /// apart from a row that was framed wrong — which is the failure the canvas
  /// declaration exists to prevent and would be invisible here.
  final String? device;

  final List<CatalogRenderError> errors;

  /// What the entry had announced and not finished when the audit stopped
  /// waiting — a tracked load by its label, image decodes, asset reads — or
  /// absent when everything landed. The comparison refuses a frame like this,
  /// so it is broken here too: its picture is of a screen still loading.
  final String? stillWaitingOn;

  Map<String, Object?> toJson() => _$CatalogAuditEntryToJson(this);
}

/// A package the audit could not reach.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogAuditFailure {
  CatalogAuditFailure({required this.package, required this.error});

  final String package;
  final String error;

  Map<String, Object?> toJson() => _$CatalogAuditFailureToJson(this);
}

/// `build-web` — where the browsable page was written.
///
/// A directory rather than an [Artifact]: an artifact carries one file and a
/// MIME type, and a Flutter web build is a tree whose entry point happens to be
/// `index.html`. Naming both is what lets a caller serve the first and open the
/// second without guessing the relationship.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class CatalogWebBuildResult implements PluginResult {
  CatalogWebBuildResult({
    required this.package,
    required this.output,
    required this.indexHtml,
    required this.entries,
    required this.durationMs,
  });

  final String package;

  /// The directory to serve, worktree-relative where it is inside the worktree
  /// — a path that survives being read on another machine.
  final String output;

  /// The page to open, relative to the same root as [output].
  final String indexHtml;

  /// How many entries the page can show.
  final int entries;

  final int durationMs;

  @override
  Map<String, Object?> toJson() => _$CatalogWebBuildResultToJson(this);
}

/// `compare` — the verdict of one comparison run, both halves.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ComparisonCompareResult implements PluginResult {
  ComparisonCompareResult({
    required this.against,
    required this.baseSha,
    required this.counts,
    required this.channels,
    required this.findings,
    required this.index,
    this.shapes = const [],
    this.eventChannels = const {},
    this.export,
    this.report,
    this.scenariosNote,
    this.verdictGap,
  });

  /// What the comparison was against — the ref's name, as a header shows it.
  final String against;

  /// The merge base it resolved to.
  final String baseSha;

  /// Every row by state, both halves merged: `{"changed": 2, "skipped": 9}`.
  /// One preview that broke and one scenario that broke is two broken things;
  /// which half they came from is the second question, and the findings below
  /// answer it.
  final Map<String, int> counts;

  /// How many findings each channel had something to say about:
  /// `{"pixels": 5, "tree": 3, "events": 2}`.
  ///
  /// A finding is counted once per channel that fired on it, so the numbers
  /// sum to more than [findings] and are meant to. The question they answer is
  /// *what kind of change was this branch* — which is the first thing a reader
  /// wants and the last thing a percentage can say.
  final Map<String, int> channels;

  /// Event deltas by the channel they travelled on: `{"system": 192, "db": 3}`.
  ///
  /// Counted separately from [channels] and kept even when a reader is hiding
  /// a channel, because a hidden channel that says nothing about itself is
  /// indistinguishable from an empty one. `system` is the case this exists
  /// for: on a real suite it was 192 of 293 event differences, which nobody
  /// wants by default and everybody wants when the bug is about focus.
  final Map<String, int> eventChannels;

  /// The distinct *shapes* of difference across the whole comparison, in
  /// channel order, each with how many findings wore it.
  ///
  /// The line that says what a branch did in one read. Measured on this
  /// repository, a comparison reporting eleven event deltas reported **one**
  /// shape eleven times — the same subchannel, subject and property, differing
  /// only in an identity hash. Eleven rows that are one fact, and no channel
  /// filter can tell them apart because they are all on the same channel.
  final List<ComparisonDelta> shapes;

  /// The rows worth attention, worst first. The `same` and `skipped` rows are
  /// in the artifact at [index], where a reader who needs proof of coverage
  /// finds them.
  final List<ComparisonFinding> findings;

  /// The whole verdict as a file — every row, every channel, the shot keys.
  final String index;

  /// The browsable page, when `export` asked for one. Serve it over HTTP.
  final String? export;

  /// The PR report directory, when `report` asked for one: `comment.md`,
  /// `mosaic.png`, the page under `web/`.
  final String? report;

  /// Why the scenario half has nothing to say, when it has nothing to say —
  /// a base harness that would not build reads differently from a project
  /// with no scenarios.
  final String? scenariosNote;

  /// Why the verdict is incomplete, when it is — the sentence `fw compare`
  /// exits 1 on, and the published reader's own `verdictGap`, so an agent and
  /// a script over `index.json` read the same answer. When present, the
  /// [findings] describe the gap rather than the branch: a half of nothing
  /// but `failed` rows is near-always one environmental cause, not that many
  /// regressions.
  final String? verdictGap;

  @override
  Map<String, Object?> toJson() => _$ComparisonCompareResultToJson(this);
}

/// One row that came out worth looking at.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ComparisonFinding {
  ComparisonFinding({
    required this.id,
    required this.half,
    required this.state,
    this.note,
    this.delta,
    this.deltas = const [],
    this.deltasDropped = 0,
  });

  /// The entry id, or the scenario id for a flow.
  final String id;

  /// `previews` or `scenarios`.
  final String half;

  /// `broke`, `failed`, `wasBroken`, `added`, `removed` or `changed` —
  /// declared worst-first, and the list is sorted by it.
  final String state;

  /// Why it is in the state it is, when the state alone does not say.
  final String? note;

  /// The size of the change: `0.38% · 2 regions` for pixels, the step that
  /// moved for a flow.
  final String? delta;

  /// What actually moved, on every channel — the facets a reader filters on.
  ///
  /// Capped, and [deltasDropped] says by how much: an agent asking what a
  /// branch did should not be handed four hundred lines of `system` chatter to
  /// get to the two that matter. The uncapped list of every row is in the
  /// artifact at `index`.
  final List<ComparisonDelta> deltas;

  final int deltasDropped;

  Map<String, Object?> toJson() => _$ComparisonFindingToJson(this);
}

/// One difference a finding is made of.
///
/// The wire form of `ChannelDelta`, and deliberately the same five facets:
/// `half` is the finding's, `channel` and the rest are here. See
/// `docs/superpowers/specs/2026-08-29-comparison-events-channel-design.md` §9.
@JsonSerializable(
  explicitToJson: true,
  includeIfNull: false,
  createFactory: false,
)
class ComparisonDelta {
  ComparisonDelta({
    required this.channel,
    this.subchannel,
    this.subject,
    this.property,
    this.base,
    this.head,
    this.origin,
    this.count,
    this.items,
  });

  /// `pixels`, `tree`, `texts` or `events`.
  final String channel;

  /// For an event, the channel it travelled on: `network`, `db`, `log`,
  /// `system`.
  final String? subchannel;

  /// A widget's path through the tree, or an event's one-line summary.
  final String? subject;

  /// Which field moved — `size`, `detail`, `data.cart.id` — or `added`,
  /// `removed`, `moved` where something arrived, left or changed places.
  final String? property;

  final String? base;
  final String? head;

  /// Where the app made the event, when it said: a file and a symbol. Never
  /// compared; it is there so a whole file's noise can be excluded at once.
  final String? origin;

  /// How many identical deltas this row stands for. Absent means one.
  ///
  /// [base] and [head] are then one example of [count], kept because a shape
  /// with no value attached to it cannot be judged.
  final int? count;

  /// How many findings wore this shape. Absent means one.
  ///
  /// The more useful of the two in a verdict: four text fields on one screen
  /// is one screen's problem, four screens with one each is the suite's.
  final int? items;

  Map<String, Object?> toJson() => _$ComparisonDeltaToJson(this);
}
