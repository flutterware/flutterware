import 'dart:convert';
import 'dart:developer' as developer;

import '../guest_extensions.dart';

import 'package:flutter/widgets.dart';

import 'guest_inspect.dart';
import 'guest_scrolls.dart';
import 'watch.dart';

/// Tells the host when what it is looking at has moved, without being asked.
///
/// The problem this exists for. A tree is of one build. Entry switch,
/// reload, knob and axis change all notify; nothing notifies when the *demo's
/// own* state moves. That was invisible while a stale tree only showed slightly
/// wrong numbers — but once hovering a row draws a rectangle on screen, a stale
/// tree visibly lies: you hover `Padding` and a box appears over nothing.
///
/// Why not push the tree every frame. An animation almost never changes
/// tree structure. It changes geometry. Re-sending fifty identical nodes with
/// different rects sixty times a second, to move one rectangle, spends the most
/// in exactly the case the feature was turned on for. So two things are watched
/// separately, and only the one that changed is reported:
///
/// | tier | what moves | what is pushed |
/// |---|---|---|
/// | geometry | the watched node's box | the box |
/// | structure | the shape of the element tree | a flag — the host re-reads |
/// | resize | the demo's own box | a flag — every rect is stale at once |
/// | scroll | the offsets under a scrollable | a flag — the host waits, then re-reads |
///
/// The structure tier pushes a **flag, not a tree**. The host already knows how
/// to read `ext.flutterware.tree`; what it cannot do is know when to. Shipping
/// the tree inside the event would put the expensive walk on the frame that
/// detected the change, which is the frame that can least afford it.
///
/// Off unless something is watching, so an uninspected guest costs nothing —
/// which is why this is a switch and not an install.
class GuestWatch {
  GuestWatch({
    required this.inspector,
    required this.rootOf,
    required this.entryIdOf,
    void Function(WatchPush)? emit,
    int Function()? scrollsOf,
  }) : _emit = emit ?? _post,
       _scrollsOf = scrollsOf ?? _scrollTicks;

  static int _scrollTicks() => GuestScrolls.instance.ticks;

  static void _post(WatchPush push) =>
      GuestExtensions.post(eventKind, push.toJson());

  /// Where a push goes. Injectable for one reason: [developer.postEvent] is a
  /// no-op with no VM service attached, so a test that could not substitute
  /// this could only ever assert that *something* was pushed — never which
  /// tier fired, which is the whole distinction this class exists to draw.
  final void Function(WatchPush) _emit;

  /// Where the scroll tier's number comes from. Injectable for the reason
  /// [_emit] is: the counter is a singleton the demo writes to, and a test that
  /// could not substitute it would have to build a scrollable and fling it to
  /// assert anything about when this class speaks.
  final int Function() _scrollsOf;

  final GuestInspector inspector;

  /// The demo's root element — the same subtree [GuestInspector] reports, so a
  /// shape change here means a change to the tree the host is showing rather
  /// than to the catalog chrome around it.
  final Element? Function() rootOf;

  final String? Function() entryIdOf;

  /// The event the host listens for. One kind for both tiers: which tier fired
  /// is in the payload, and a host that has to subscribe twice to learn about
  /// one frame is a host that can see half of it.
  static const eventKind = 'flutterware.watch';

  var _watching = false;
  bool get watching => _watching;

  /// The node whose box is reported, or null to watch structure only.
  String? _nodeId;

  /// Resolved once and held, because resolving is the expensive half: an id is
  /// a position in the summary tree, so turning one back into a render object
  /// means walking the summary tree, and doing that per frame would be the very
  /// cost this design exists to avoid. Dropped whenever the shape changes or
  /// the entry does, which is when a held one could start describing something
  /// else.
  RenderObject? _node;

  /// Whether resolving has been *attempted* for the current [_nodeId].
  ///
  /// Separate from `_node != null`, and it has to be: a null [_node] otherwise
  /// means both "not looked up yet" and "looked up, names nothing", so an id
  /// that resolves to nothing is retried on **every frame** — and resolving is a
  /// whole summary-tree walk, measured at 4–8ms. On an animating demo that is
  /// half a core spent re-deciding that a stale id is still stale, which is
  /// precisely the cost holding [_node] exists to avoid.
  var _resolved = false;

  /// At most one push per interval, per tier. Zero means every frame.
  ///
  /// The host's call rather than the guest's: only the host knows whether it is
  /// driving an overlay that has to track an animation or a tree view that is
  /// happy a second late.
  var _minInterval = Duration.zero;

  int? _shape;
  Size? _size;

  /// The scroll count as of the last frame that was *reported*, which is not
  /// the same as the last frame that was read — see [_onFrame].
  int? _scrolls;
  Rect? _box;
  String? _watchedEntry;

  var _frames = 0;
  var _pushes = 0;
  var _hashMicrosLast = 0;
  var _hashMicrosTotal = 0;
  var _hashMicrosMax = 0;
  var _resolveMicrosLast = 0;
  var _nodeCount = 0;

  /// Reset rather than replaced. A new [Stopwatch] per push is sixty
  /// short-lived objects a second in a process whose frame budget is the very
  /// thing being measured.
  final _sinceLastPush = Stopwatch();

  /// Turns the watch on or off, and says what it is watching.
  ///
  /// Idempotent: asking for a watch that is already running with the same
  /// arguments changes nothing, because the panel restates its interest on
  /// every rebuild and a watch that restarted each time would never accumulate
  /// the frame it is supposed to be comparing against.
  void watch({String? nodeId, Duration minInterval = Duration.zero}) {
    _minInterval = minInterval;
    if (_nodeId != nodeId) {
      _nodeId = nodeId;
      _node = null;
      _resolved = false;
      _box = null;
    }
    if (_watching) return;
    _watching = true;
    _shape = null;
    _size = null;
    _scrolls = null;
    _frames = 0;
    _pushes = 0;
    _hashMicrosTotal = 0;
    _hashMicrosMax = 0;
    // The "last seen" figures too, which is not obvious and was got wrong: a
    // watch started on an entry that never draws a frame kept reporting the
    // *previous* entry's node count and resolve cost, so a run of static demos
    // all claimed the size of whichever animating one came before them.
    _hashMicrosLast = 0;
    _resolveMicrosLast = 0;
    _nodeCount = 0;
    _sinceLastPush.reset();
    _arm();
  }

  void unwatch() {
    _watching = false;
    _node = null;
    _resolved = false;
    _box = null;
    _shape = null;
    _size = null;
    _scrolls = null;
  }

  /// Waits for the next frame, once.
  ///
  /// A post-frame callback rather than a persistent one, for two reasons that
  /// point the same way. It can be stopped — there is no API to remove a
  /// persistent callback, so a watch built on one would keep running after the
  /// panel closed. And it costs nothing when nothing is happening: a re-arm
  /// does not schedule a frame, so an idle guest simply never calls back, which
  /// is exactly the behaviour wanted and would have had to be built otherwise.
  void _arm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_watching) return;
      _onFrame();
      _arm();
    });
  }

  void _onFrame() {
    var entryId = entryIdOf();
    // An entry switch invalidates both halves: the shape is a different demo's,
    // and the node id names a position in a tree that no longer exists.
    if (entryId != _watchedEntry) {
      _watchedEntry = entryId;
      _shape = null;
      _size = null;
      // The count is the guest's, not the entry's, so it does not restart with
      // the demo — but the frame it is compared against belongs to the previous
      // one, and a demo that scrolled on its way out would otherwise be
      // reported as this one scrolling on its way in.
      _scrolls = null;
      _node = null;
      _resolved = false;
      _box = null;
    }

    var root = rootOf();
    if (root == null) return;
    _frames++;

    var timer = Stopwatch()..start();
    var (:hash, :count) = _shapeOf(root);
    timer.stop();
    _hashMicrosLast = timer.elapsedMicroseconds;
    _hashMicrosTotal += _hashMicrosLast;
    if (_hashMicrosLast > _hashMicrosMax) _hashMicrosMax = _hashMicrosLast;
    _nodeCount = count;

    var structureMoved = _shape != null && _shape != hash;
    _shape = hash;
    // The resolved node is a position in the tree that just changed shape, so
    // whatever it points at is no longer necessarily what was asked for.
    if (structureMoved) {
      _node = null;
      _resolved = false;
    }

    // The demo's own box. One `hasSize` and a compare, so it rides along with
    // the walk for nothing — and it catches the staleness the shape hash
    // cannot see at all: dragging the panel divider resizes the preview, every
    // rect in the tree changes, and not one widget does. Until this, the tree
    // went on reporting the widths it had before the drag, including whether
    // anything overflowed at them.
    var size = switch (root.renderObject) {
      RenderBox(hasSize: true, :var size) => size,
      _ => null,
    };
    var resized = _size != null && size != _size;
    _size = size;

    // One integer compare, and it catches what neither of the two above can:
    // scrolling moves every rect under the scrollable while leaving the shape
    // and the demo's box exactly as they were. Assigned *after* the debounce
    // below rather than here, so a push dropped inside the window is caught
    // again on the next frame — the other tiers overwrite here and lose it,
    // which is survivable for a shape change nobody is drawing and is not
    // survivable for this, whose whole purpose is to say the rectangles on
    // screen are lies.
    var scrolls = _scrollsOf();
    var scrolled = _scrolls != null && scrolls != _scrolls;
    _scrolls ??= scrolls;

    var box = _boxOf();
    WatchBox? geometry;
    if (box != null && box != _box) {
      geometry = WatchBox(
        id: _nodeId,
        x: box.left,
        y: box.top,
        width: box.width,
        height: box.height,
      );
    }
    _box = box;

    if (!structureMoved && !resized && !scrolled && geometry == null) return;
    // Debounced *after* the comparison, never before: skipping the read would
    // mean comparing the next frame against a state two frames old, and a
    // change that reverted inside the window would go unreported for ever.
    if (_sinceLastPush.isRunning && _sinceLastPush.elapsed < _minInterval) {
      return;
    }
    _sinceLastPush
      ..reset()
      ..start();
    _pushes++;
    _scrolls = scrolls;

    _emit(
      WatchPush(
        entryId: entryId,
        frame: _frames,
        nodes: count,
        hashMicros: _hashMicrosLast,
        structureChanged: structureMoved,
        resized: resized,
        scrolled: scrolled,
        geometry: geometry,
      ),
    );
  }

  /// The watched node's box in the guest's own coordinates, or null when there
  /// is nothing to watch or it has gone away.
  Rect? _boxOf() {
    var id = _nodeId;
    if (id == null) return null;
    if (!_resolved) {
      _resolved = true;
      var timer = Stopwatch()..start();
      _node = inspector.renderObjectFor(id);
      _resolveMicrosLast = timer.elapsedMicroseconds;
    }
    var render = _node;
    // `attached` as well as `hasSize`: a render object held across a rebuild
    // can be detached rather than replaced, and asking a detached box where it
    // is on screen walks a parent chain that no longer reaches a view.
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    // Through the transform as one rect — see `_layoutOf` in guest_inspect.dart
    // for why an origin plus a raw size is two different spaces. Relative to
    // the demo's root, not the window: the two coincide in an embedder guest
    // and differ for a guest drawn inside its host.
    return boxWithin(render, rootOf()?.renderObject);
  }

  /// A hash of the element tree's shape, and how many elements it has.
  ///
  /// Elements rather than the summary tree, and this is the whole reason the
  /// structure tier is affordable. The summary tree comes out of
  /// `WidgetInspectorService` as a JSON *string* that has to be decoded and
  /// then resolved node by node back into elements; this walks the elements the
  /// framework already has, allocates nothing, and touches each once.
  ///
  /// Depth is folded in as well as type, so that moving a subtree without
  /// changing what is in it still counts as a change. Order comes free from the
  /// walk.
  ({int hash, int count}) _shapeOf(Element root) {
    var hash = 17;
    var count = 0;
    void visit(Element element, int depth) {
      count++;
      // 0x3fffffff keeps this in the small-integer range on every platform the
      // guest runs on, including the web's 32-bit ints. A hash that boxes is a
      // hash that allocates, per element, per frame.
      hash = 0x3fffffff & (hash * 31 + element.widget.runtimeType.hashCode);
      hash = 0x3fffffff & (hash * 31 + depth);
      element.visitChildren((child) => visit(child, depth + 1));
    }

    visit(root, 0);
    return (hash: hash, count: count);
  }

  /// What the watch has cost so far.
  ///
  /// Pull-based as well as pushed, so the cost can be read by something that is
  /// not subscribed — and so it survives the case that matters most, a watch
  /// whose events are arriving too slowly to trust.
  WatchStats describe() => WatchStats(
    watching: _watching,
    entryId: entryIdOf(),
    node: _nodeId,
    minIntervalMillis: _minInterval.inMilliseconds,
    frames: _frames,
    pushes: _pushes,
    nodes: _nodeCount,
    hashMicrosLast: _hashMicrosLast,
    hashMicrosMax: _hashMicrosMax,
    hashMicrosMean: _frames == 0 ? 0 : _hashMicrosTotal ~/ _frames,
    resolveMicrosLast: _resolveMicrosLast,
    resolved: _node != null,
  );

  /// Registers the extension. Call once, before `runApp`.
  void registerExtensions() {
    GuestExtensions.register('ext.flutterware.watch', (_, args) async {
      // Absent means "leave it alone", which is what lets a caller change the
      // node without restating the interval and the other way round.
      if (args['on'] case var on?) {
        if (on == 'false') {
          unwatch();
        } else {
          watch(
            nodeId: switch (args['node']) {
              // The empty string is how a caller says "structure only" over a
              // wire whose values are all strings.
              null || '' => _nodeId,
              '-' => null,
              var id => id,
            },
            minInterval: Duration(
              milliseconds:
                  int.tryParse(args['minIntervalMillis'] ?? '') ??
                  _minInterval.inMilliseconds,
            ),
          );
        }
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(describe().toJson()),
      );
    });
  }
}
