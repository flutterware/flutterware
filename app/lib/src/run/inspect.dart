import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';

// The node types the catalog already carries between processes. Reused rather
// than re-invented so that a tree read off a phone and a tree read out of a
// headless guest are the same shape to whatever consumes them.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/semantics.dart';

import '../session/job.dart';
import 'connection.dart';

final _logger = Logger('run_inspect');

/// What the run guest registers its own tree walk as.
///
/// Named here rather than imported from the guest so that the host's copy of
/// the string is the host's: this file talks to whichever flutterware built
/// the app, which need not be this one.
const guestTreeExtension = 'ext.flutterware.tree';

/// The guest's semantics read. Same extension the previews panel asks over its
/// embedder wire, asked here over the VM service.
const guestSemanticsExtension = 'ext.flutterware.semantics';

/// JSON-RPC's "Method not found" — what the VM answers for an extension the
/// isolate in the request does not have.
const _methodNotFound = -32601;

/// The app answered, and has mounted nothing.
///
/// Not "still starting up", which is what this used to guess. The two
/// states are indistinguishable from here — a root element is absent during
/// the first frames and absent forever after a `main` that threw — so the
/// sentence says what is *known* and points at the one place that can tell
/// them apart. The launcher log is that place: an exception before `runApp`
/// reaches no `FlutterError` and no daemon event, and the engine writes it to
/// the process's stderr, which is the log this run already keeps.
///
/// A [ProjectFault], so the CLI prints it without a stack out of this package.
/// The stack was the actively harmful half of the old answer.
class AppNotStarted implements ProjectFault {
  AppNotStarted([this.detail]);

  /// What the launcher log had to say, when the caller could look it up.
  final String? detail;

  static const summary =
      'the app has not called runApp, so there is no widget tree yet. '
      'Either it is still starting, or its `main` threw before `runApp`. '
      'The launcher log says which, and `inspect {errors: true}` prints the '
      'relevant lines.';

  @override
  String toString() => [summary, ?detail].join('\n\n');
}

/// Reads a running app through the framework's own inspector.
///
/// Nothing here needs code in the user's app. `WidgetInspectorService` is
/// registered by `package:flutter` in debug mode, so this works against any
/// Flutter app the cockpit can reach a VM service for — including one that has
/// never depended on flutterware.
///
/// It is also app-side rather than tool-side: an app whose `flutter run` has
/// died keeps its tree and its screenshots and loses only hot reload.
class RunInspector {
  RunInspector(this.connection);

  final RunConnection connection;

  VmService get _service => connection.service;

  /// Object group names are per-connection and refcounted by the inspector, so
  /// two overlapping reads must not share one — disposing the first would
  /// invalidate the ids the second is still holding.
  static var _groups = 0;

  /// One reading of the app: the tree, a picture, or both.
  ///
  /// Both come off one object group and one `getRootWidgetTree` call, and
  /// that is the whole reason this exists rather than two methods a caller
  /// chains. The app is live: between two reads it animates, a timer fires,
  /// data arrives. Two calls produce a tree and a picture that *happen to
  /// agree*, which is not the same thing as one reading and is exactly what
  /// annotating a screenshot with node ids cannot be built on. The catalog
  /// learned this first — see `ui_catalog_core.dart`'s `inspect`.
  ///
  /// Asks for the tree even when only a picture is wanted, because the
  /// screenshot RPC takes an inspector id and ids only exist inside a group.
  /// Previews are skipped in that case, which is the only cost saved.
  ///
  /// [preferGuest] asks the app's own walk for the tree first and falls back
  /// to the service extension — see [_guestTree] for what that buys and why it
  /// is off by default.
  Future<InspectRead> read({
    bool tree = false,
    bool screenshot = false,
    bool semantics = false,
    bool summary = true,
    bool preferGuest = false,
    double maxPixelRatio = 2,
    int? maxSide,
  }) => _inGroup((group) async {
    // Only for a tree somebody asked for, and only for a summary one: the
    // guest walks the summary tree and nothing else, so `full` is a question
    // it cannot answer.
    var guest = tree && summary && preferGuest ? await _guestTree() : null;
    // **A picture still needs an inspector id**, because that is what the
    // screenshot RPC takes and the guest's ids are positions rather than
    // handles. It does not need a whole second tree for one, though — see
    // [_rootId].
    var (:read, :rootId) = guest == null
        ? await _readTree(group, summary: summary, withPreviews: tree)
        : (
            read: InspectTree.empty,
            rootId: screenshot ? await _rootId(group) : null,
          );
    return InspectRead(
      tree: tree ? guest ?? read : null,
      fromGuest: guest != null,
      // **After the tree, and only when the tree came from the guest.** Two
      // reasons, both load-bearing. The service extension has no semantics to
      // give, so a run with no guest in it has no question to ask — and
      // [_guestTree] is what repairs a connection pointing at the wrong
      // isolate, so asking second is asking the isolate that just answered.
      semantics: semantics && guest != null ? await _guestSemantics() : null,
      image: screenshot
          ? await _screenshot(
              group,
              rootId,
              maxPixelRatio: maxPixelRatio,
              maxSide: maxSide,
            )
          : null,
    );
  });

  /// The semantics tree as the app publishes it, or null.
  ///
  /// **No `on` argument, and that is not an omission.** The catalog turns
  /// semantics on and off around its tab, because there it is a tab nobody may
  /// have opened and the tree costs a frame to build. A run launched through
  /// flutterware holds a `SemanticsHandle` for its whole life already — see
  /// `run_guest.dart`, where it is load-bearing for the drive layer and
  /// measured free (431ms against 434ms over 24 timed taps). So this reads
  /// what is already there and changes nothing about the app.
  ///
  /// Null on every failure, like [_guestTree]: an app that will not answer has
  /// no semantics as far as the pane is concerned, and the pane says so in
  /// words rather than throwing a reading away that has a picture in it.
  Future<InspectSemantics?> _guestSemantics() async {
    try {
      var response = await _service.callServiceExtension(
        guestSemanticsExtension,
        isolateId: connection.isolateId,
      );
      var json = response.json;
      if (json == null) return null;
      return InspectSemantics.fromJson(json);
    } on Object catch (e) {
      _logger.fine('Could not read a guest semantics tree: $e');
      return null;
    }
  }

  /// The tree as the **app itself** walks it, or null when this run has no
  /// guest in it.
  ///
  /// One shape, two readers. `ext.flutterware.tree` answers with the same
  /// `GuestInspector.read()` that the drive loop, the previews panel and a
  /// scenario step are answered from, so a cockpit handed this one gets what
  /// the service extension has no way to part with: the boxes, the widget's
  /// own properties, the resolved text style and the ambient style underneath
  /// it. The last of those is not a matter of nobody having wired it —
  /// `RenderParagraph`'s resolved span never leaves the app on any RPC.
  ///
  /// It never throws, and the fallback is not a degraded mode. An app with
  /// no guest is the ordinary case here — this class exists to work against
  /// one that has never heard of flutterware — so every failure lands on
  /// [_readTree], which is what every run got before this existed. The cost of
  /// being wrong is one refused RPC, plus a census on top when the refusal
  /// could have been a wrong isolate.
  Future<InspectTree?> _guestTree() async {
    try {
      return await _askGuest();
    } on RPCError catch (error) {
      if (error.code != _methodNotFound) {
        _logger.fine('The guest would not answer with a tree: $error');
        return null;
      }
      // `Unknown method` is two facts — no guest at all, or a guest in an
      // isolate this connection did not pick — and only the VM tells them
      // apart. Repaired rather than concluded, exactly as `DriveSession` does
      // it: a guess left standing here would quietly downgrade the pane for
      // the life of the run, and quietly is the problem.
      var found = await connection.findIsolateWith(guestTreeExtension);
      if (found.id case var id? when id != connection.isolateId) {
        connection.useIsolate(id);
        try {
          return await _askGuest();
        } on Object catch (e) {
          _logger.fine('The guest in $id would not answer: $e');
        }
      }
      return null;
    } on Object catch (e) {
      _logger.fine('Could not read a guest tree: $e');
      return null;
    }
  }

  /// An inspector id for the root, and nothing else.
  ///
  /// What [_screenshot] takes, and all of what it takes. `getRootWidget`
  /// serializes the root node alone where `getRootWidgetTree` serializes the
  /// whole summary tree — **2.7ms against 122ms**, measured against the studio
  /// inspecting itself (835 nodes) — so a read that already has its tree from
  /// the guest does not pay for a second one it is going to throw away. That
  /// one call is the difference between the guest path costing more than the
  /// service path and costing about the same.
  ///
  /// `objectGroup`, not `groupName`. The two spellings are not
  /// interchangeable and the wrong one does not say so: this extension is
  /// registered through `_registerObjectGroupServiceExtension`, which reads
  /// `objectGroup` behind a null check, so `groupName` comes back as
  /// `(-32000) Server error: Null check operator used on a null value` —
  /// which reads like a broken app rather than a misspelled argument.
  Future<String?> _rootId(String group) async {
    try {
      var response = await _service.callServiceExtension(
        'ext.flutter.inspector.getRootWidget',
        isolateId: connection.isolateId,
        args: {'objectGroup': group},
      );
      if ((response.json?['result'] as Map?)?['valueId'] case String id) {
        return id;
      }
    } on Object catch (e) {
      _logger.fine('Could not read a root id on its own: $e');
    }
    // The whole tree for the one field on it, rather than no picture: this is
    // what the service path pays anyway, so the fallback is the old cost and
    // not a new failure.
    return (await _readTree(group, summary: true, withPreviews: false)).rootId;
  }

  Future<InspectTree?> _askGuest() async {
    var response = await _service.callServiceExtension(
      guestTreeExtension,
      isolateId: connection.isolateId,
    );
    var json = response.json;
    if (json == null) return null;
    var read = InspectTree.fromJson(json.cast<String, Object?>());
    // A guest that has not built a frame yet has nothing to prefer: the
    // service tree says the same thing and comes with the id a picture needs.
    return read.root == null ? null : read;
  }

  /// The widget tree, as of the app's last build.
  ///
  /// Summary by default, and that default is not a nicety: the full tree
  /// measured 6.1 MB across 517 nodes at depth 224 for a one-screen demo, where
  /// the summary was 25 nodes and 25 KB. Summary means "the widgets the
  /// framework attributes to the user's code", which is what anyone reading a
  /// tree is asking about.
  Future<InspectTree> tree({bool summary = true}) async =>
      (await read(tree: true, summary: summary)).tree ?? InspectTree.empty;

  /// A PNG of the whole app, as it is on the screen right now.
  ///
  /// `ext.flutter.inspector.screenshot`, not `_flutter.screenshot`. The
  /// rasterizer screenshot fails under Impeller — measured on macOS and the iOS
  /// simulator alike, and `_flutter.screenshotSkp` says so in its error — which
  /// rules it out on every target, since macOS, iOS and Android are all
  /// Impeller. This one renders the render tree into an offscreen layer through
  /// `toImage`, which Impeller does support.
  ///
  /// Verified to be live rather than cached: flipping `debugPaint` from outside
  /// changes the next picture.
  ///
  /// Platform views — native maps, webviews, video — will not appear. They are
  /// composited by the OS, not by Flutter's layer tree, so nothing rendering
  /// that tree can photograph them.
  Future<Uint8List> screenshot({double maxPixelRatio = 2, int? maxSide}) async {
    var read = await this.read(
      screenshot: true,
      maxPixelRatio: maxPixelRatio,
      maxSide: maxSide,
    );
    return read.image!;
  }

  Future<Uint8List> _screenshot(
    String group,
    String? rootId, {
    required double maxPixelRatio,
    required int? maxSide,
  }) async {
    if (rootId == null) throw AppNotStarted();
    // The RPC fits the render into this box, so the box decides how big the
    // picture comes back. Asking the root how big it actually is costs one
    // call and is the difference between a phone-shaped photograph and an
    // arbitrarily letterboxed one.
    var size =
        await _sizeOf(group, rootId) ?? const (width: 2000.0, height: 2000.0);
    var (:width, :height) = size;
    if (maxSide != null) {
      var longest = width > height ? width : height;
      if (longest > maxSide) {
        var scale = maxSide / longest;
        width *= scale;
        height *= scale;
      }
    }
    var response = await _service.callServiceExtension(
      'ext.flutter.inspector.screenshot',
      isolateId: connection.isolateId,
      args: {
        'id': rootId,
        'width': '$width',
        'height': '$height',
        'margin': '0',
        'maxPixelRatio': '$maxPixelRatio',
        'debugPaint': 'false',
      },
    );
    var encoded = response.json?['result'];
    if (encoded is! String) {
      throw StateError(
        'The app answered a screenshot request without a picture in it. '
        'It reported: ${response.json}',
      );
    }
    return base64Decode(encoded);
  }

  /// Runs [body] against a fresh inspector object group and always disposes it.
  ///
  /// A group that outlives its read pins every `Element` in it, and this runs
  /// against a live app rather than a stopped one.
  Future<T> _inGroup<T>(Future<T> Function(String group) body) async {
    var group = 'flutterware.run.${_groups++}';
    try {
      return await body(group);
    } finally {
      try {
        await _service.callServiceExtension(
          'ext.flutter.inspector.disposeGroup',
          isolateId: connection.isolateId,
          args: {'objectGroup': group},
        );
      } on Object catch (e) {
        // Best effort. An app that died mid-read cannot free anything, and
        // failing the read over its failure to tidy up would report the wrong
        // problem.
        _logger.fine('Could not dispose inspector group $group: $e');
      }
    }
  }

  /// The tree, and the inspector's own id for its root.
  ///
  /// Both from one call. The id is what the screenshot RPC takes and it is
  /// alive only while [group] is, so reading it separately would mean a second
  /// `getRootWidgetTree` against a tree that may already have moved.
  Future<({InspectTree read, String? rootId})> _readTree(
    String group, {
    required bool summary,
    required bool withPreviews,
  }) async {
    var response = await _service.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: connection.isolateId,
      args: {
        'groupName': group,
        'isSummaryTree': '$summary',
        'withPreviews': '$withPreviews',
        if (!summary) 'fullDetails': 'true',
      },
    );
    var result = response.json?['result'];
    if (result is! Map) return (read: InspectTree.empty, rootId: null);
    var json = result.cast<String, Object?>();
    return (
      read: InspectTree(entryId: null, root: convertNode(json, '')),
      rootId: json['valueId'] as String?,
    );
  }

  /// How big [id]'s box is, in logical pixels.
  ///
  /// The one piece of geometry the VM service will part with. There is no
  /// *position* anywhere in the inspector surface — `parentData` reads `<none>`
  /// and `getDetailsSubtree` errors — which is why [InspectNode.layout] is left
  /// null on this path and why cropping and annotating need the guest runtime.
  Future<({double width, double height})?> _sizeOf(
    String group,
    String id,
  ) async {
    try {
      var response = await _service.callServiceExtension(
        'ext.flutter.inspector.getLayoutExplorerNode',
        isolateId: connection.isolateId,
        args: {'groupName': group, 'id': id, 'subtreeDepth': '1'},
      );
      var result = response.json?['result'];
      if (result is! Map) return null;
      // The root is a `RenderView` rather than a `RenderBox` and need not
      // report one, so the first child that does is the app's own bounds.
      return _size(result) ??
          switch (result['children']) {
            [Map first, ...] => _size(first),
            _ => null,
          };
    } on Object catch (e) {
      _logger.fine('Could not read a size for $id: $e');
      return null;
    }
  }

  static ({double width, double height})? _size(Map<Object?, Object?> node) {
    // Reported as strings, both of them.
    if (node['size'] case Map size) {
      var width = double.tryParse('${size['width']}');
      var height = double.tryParse('${size['height']}');
      if (width != null && height != null && width > 0 && height > 0) {
        return (width: width, height: height);
      }
    }
    return null;
  }

  /// The inspector's JSON as an [InspectNode].
  ///
  /// The field rules here must stay in step with `GuestInspector._convert`
  /// (`lib/src/inspect/guest_inspect.dart`), because an agent can be handed a
  /// tree from either and must not have to tell which. They are separate rather
  /// than shared because only one of them can answer the two questions that
  /// need a live `Element`: what a node's box is, and which render object it
  /// belongs to.
  ///
  /// `InspectNode.widgetKey` is split off the description by
  /// [InspectNode.splitKey], which is shared with the guest precisely so that
  /// this field cannot drift between the two.
  ///
  /// `InspectNode.offstage` and `InspectNode.properties` are known,
  /// deliberate divergences: the first takes the render chain and the second
  /// the widget itself, neither of which this path can reach — so trees read
  /// here list a covered route's widgets unmarked and carry no properties.
  /// Same as `layout`: entries on the guest-runtime ledger.
  ///
  /// The id is the child-index path, exactly as [InspectNode.id] specifies —
  /// derived from shape, never the inspector's own `valueId`, which is minted
  /// per object group and dies with it. What this path *can* offer that the
  /// guest could not is [InspectNode.source] on every node: the creation
  /// location is unreachable in-process, because `_HasCreationLocation` is
  /// private and Dart mangles private names per library, but the service
  /// extension hands it out. So a node here is identified twice over — by
  /// position, and by `main.dart:66:11`.
  @visibleForTesting
  static InspectNode convertNode(Map<String, Object?> json, String path) {
    var described = json['description'] as String?;
    var type = json['widgetRuntimeType'] as String? ?? described ?? '';
    var preview = json['textPreview'] as String?;
    // Split off the widget's key before anything else looks at the string —
    // the same call the guest makes, on the same string, which is what keeps
    // the two spellings identical.
    var (:description, key: widgetKey) = InspectNode.splitKey(described, type);
    return InspectNode(
      id: path,
      type: type,
      // Only when it says more than the type does — `Text("Save")` earns its
      // place, a `Padding` described as "Padding" is the type twice.
      description: preview != null
          ? '$type("$preview")'
          : description == type
          ? null
          : description,
      widgetKey: widgetKey,
      createdByLocalProject: json['createdByLocalProject'] as bool? ?? false,
      source: switch (json['creationLocation']) {
        Map location => InspectSource.fromJson(
          location.cast<String, Object?>(),
        ),
        _ => null,
      },
      children: [
        for (var (index, child)
            in (json['children'] as List? ?? const []).indexed)
          if (child is Map)
            convertNode(
              child.cast<String, Object?>(),
              path.isEmpty ? '$index' : '$path/$index',
            ),
      ],
    );
  }
}

/// What one [RunInspector.read] produced.
///
/// Both fields null is a legitimate answer — it is what asking for nothing
/// returns, and the caller that wanted only liveness got it from the
/// connection succeeding.
class InspectRead {
  const InspectRead({
    this.tree,
    this.image,
    this.semantics,
    this.fromGuest = false,
  });

  /// Null when the tree was not asked for. `InspectTree.empty` — non-null with
  /// a null root — when it was and the app has not built a frame yet. The
  /// difference matters: one is "did not ask", the other is "asked, nothing
  /// there".
  final InspectTree? tree;

  /// A PNG, when one was asked for.
  final Uint8List? image;

  /// The semantics tree, when one was asked for and the app had one.
  ///
  /// **Raw, on purpose.** `fw` and the MCP server link this class and neither
  /// can reach `dart:ui`, so the typed `SemanticsSnapshotNode` — whose every
  /// box is a `Rect` — cannot be named here. The GUI decodes it where `Rect`
  /// exists; `entry_point_purity_test` is what says so out loud.
  ///
  /// Three things are one null, and [fromGuest] tells them apart for the
  /// reader: not asked, asked of an app with no guest to ask, and asked of a
  /// guest that has not published a semantics tree. Only the last is worth a
  /// sentence about the app rather than about the reading.
  final InspectSemantics? semantics;

  /// [tree] came from the app's own walk rather than from the service
  /// extension.
  ///
  /// Which is what decides how to read a *missing* field. A guest tree with no
  /// box on a node means that node lays nothing out; a service tree with no
  /// box on a node means nothing looked. `ElementsView.readsWidgets` is this
  /// flag, and the sentence it draws is the difference between those two.
  final bool fromGuest;
}
