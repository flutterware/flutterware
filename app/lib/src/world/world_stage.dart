import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../previews/stage_zoom.dart' show isStageModifier;
import '../ui/stage.dart' show stageGroundColor;
import '../ui/theme.dart';

/// Who a gesture belongs to: the stage, or one person's app. Never both.
final class GestureOwner {
  const GestureOwner._(this.person);

  static const stage = GestureOwner._(null);

  factory GestureOwner.app(String person) => GestureOwner._(person);

  /// Null for the stage.
  final String? person;

  bool get isStage => person == null;
}

/// Decides, once per gesture, whether the stage or an app has it — and keeps
/// to that until the gesture ends.
///
/// A phone takes its pointer through a `Listener`, outside the gesture arena,
/// so nothing in Flutter stops a scroll over it from also scrolling whatever
/// is around it. Both sides ask this instead: the phone forwards only what
/// its app owns, the stage acts only on what it owns, and the answer is fixed
/// when the gesture starts so a phone passing under the pointer mid-scroll
/// does not take the rest of it.
///
/// A scroll goes to what is under the pointer — the app over a phone, the
/// stage over the ground — unless ⌘ is held, which always means the stage.
/// Two fingers converging always mean the stage: a pinch zooms it.
class StageReferee {
  StageReferee({required this.hit});

  /// The person whose phone is under [global], or null over the ground.
  final String? Function(Offset global) hit;

  /// Wheel notches closer than this are one scroll: a wheel has no start or
  /// end, so this is what a browser calls latching.
  static const _wheelLatch = Duration(milliseconds: 300);

  final _clock = Stopwatch()..start();
  final _gestures = <int, GestureOwner>{};
  PointerEvent? _last;
  GestureOwner _lastOwner = GestureOwner.stage;
  Duration? _wheelAt;
  GestureOwner _wheelOwner = GestureOwner.stage;

  /// Asked by the phone and by the stage about the same event: the first to
  /// ask decides, the second hears the same answer.
  GestureOwner ownerOf(PointerEvent event) {
    // Each side is handed its own copy, transformed into its own space; the
    // original is what they share.
    var original = event.original ?? event;
    if (identical(original, _last)) return _lastOwner;
    _last = original;
    return _lastOwner = _decide(event);
  }

  GestureOwner _decide(PointerEvent event) {
    switch (event) {
      case PointerScrollEvent():
        // The clock rather than the event's stamp: a synthesized event —
        // the drive's, a test's — carries none, and every one of them would
        // latch to the first.
        var at = _clock.elapsed;
        var last = _wheelAt;
        _wheelAt = at;
        if (last != null && at - last < _wheelLatch) return _wheelOwner;
        return _wheelOwner = _fresh(event, scroll: true);
      case PointerPanZoomStartEvent():
        return _gestures[event.pointer] = _fresh(event, scroll: true);
      case PointerPanZoomUpdateEvent():
        var owner = _gestures[event.pointer] ?? GestureOwner.stage;
        // Two fingers converging mean zoom wherever they are.
        if (!owner.isStage && event.scale != 1.0) {
          owner = _gestures[event.pointer] = GestureOwner.stage;
        }
        return owner;
      case PointerPanZoomEndEvent():
        return _gestures.remove(event.pointer) ?? GestureOwner.stage;
      case PointerDownEvent():
        return _gestures[event.pointer] = _fresh(event, scroll: false);
      case PointerUpEvent() || PointerCancelEvent():
        return _gestures.remove(event.pointer) ?? GestureOwner.stage;
      default:
        return _gestures[event.pointer] ?? _under(event);
    }
  }

  GestureOwner _fresh(PointerEvent event, {required bool scroll}) {
    if (scroll && isStageModifier()) return GestureOwner.stage;
    return _under(event);
  }

  GestureOwner _under(PointerEvent event) => switch (hit(event.position)) {
    var person? => GestureOwner.app(person),
    null => GestureOwner.stage,
  };
}

/// How far the stage is zoomed and panned, shared with the zoom buttons.
class StageView extends ChangeNotifier {
  /// Times the scale at which everyone fits: 1 is everyone in view, and the
  /// stage never draws them smaller than that.
  double zoom = 1;

  /// How far the people are moved from centred, in the stage's pixels. The
  /// stage keeps it within what the zoom lets it move.
  Offset pan = Offset.zero;

  static const maxZoom = 8.0;

  /// Zooms about [focal], a point measured from the stage's centre, so what
  /// is under it stays there; about the centre when there is none.
  void zoomBy(double factor, [Offset focal = Offset.zero]) {
    var next = (zoom * factor).clamp(1.0, maxZoom);
    if (next == zoom) return;
    pan = focal - (focal - pan) * (next / zoom);
    zoom = next;
    notifyListeners();
  }

  void reset() {
    zoom = 1;
    pan = Offset.zero;
    notifyListeners();
  }

  void panBy(Offset delta) {
    pan += delta;
    notifyListeners();
  }
}

/// The people on the stage, all in view in as many rows as draws them
/// largest; zoomed in, the stage pans. Every scroll, drag and pinch goes to
/// exactly one of the stage and an app — see [StageReferee].
class WorldStage extends StatefulWidget {
  const WorldStage({
    super.key,
    required this.people,
    required this.sizeOf,
    required this.scales,
    required this.labelHeight,
    required this.person,
    required this.view,
    required this.onScale,
    required this.onGround,
    this.onDrawn,
  });

  final List<String> people;

  /// A person's device as drawn — its body included — in logical pixels.
  final Size Function(String person) sizeOf;

  /// Whether a person is drawn at the stage's scale — a device — or at
  /// [sizeOf] on the screen whatever the zoom: a card, read rather than
  /// used. Only a device takes the pointer.
  final bool Function(String person) scales;

  /// How much of a person's view is above their device.
  final double labelHeight;

  /// A person drawn at [scale], their app told which events to leave alone.
  final Widget Function(
    String person,
    double scale,
    bool Function(PointerEvent event) ignores,
  )
  person;

  final StageView view;

  /// The scale the devices are drawn at.
  final void Function(double scale) onScale;

  /// A press on the ground, which takes the keyboard from any app.
  final VoidCallback onGround;

  /// The people whose device is at least partly in view, each time the
  /// stage is drawn: all of them until a zoom pans some out.
  final void Function(Set<String> people)? onDrawn;

  @override
  State<WorldStage> createState() => _WorldStageState();
}

class _WorldStageState extends State<WorldStage> {
  late final _referee = StageReferee(hit: _hit);

  /// Each person's device, in the stage's pixels, as last drawn.
  var _devices = <String, Rect>{};

  /// How far the people can be panned each way at the current zoom.
  var _slack = Size.zero;
  Offset? _dragFrom;
  Offset _panAt = Offset.zero;
  double _pinchFrom = 1;

  static const _pad = FwSpacing.xl;
  static const _gap = FwSpacing.xxl;

  String? _hit(Offset global) {
    var box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    var local = box.globalToLocal(global);
    for (var MapEntry(key: person, value: rect) in _devices.entries) {
      if (rect.contains(local)) return person;
    }
    return null;
  }

  double get _tallest => widget.people
      .where(widget.scales)
      .map((p) => widget.sizeOf(p).height)
      .fold(0.0, max);

  /// [person]'s size on the stage at [scale].
  Size _drawn(String person, double scale) => widget.scales(person)
      ? widget.sizeOf(person) * scale
      : widget.sizeOf(person);

  /// The scale at which [rows] all fit the stage, across and down.
  double _fitAll(Size viewport, List<List<String>> rows) {
    if (_tallest == 0) return 1;
    var down =
        (viewport.height -
            2 * _pad -
            rows.length * widget.labelHeight -
            (rows.length - 1) * _gap) /
        (rows.length * _tallest);
    var across = [
      for (var row in rows)
        (viewport.width -
                2 * _pad -
                (row.length - 1) * _gap -
                row
                    .whereNot(widget.scales)
                    .map((p) => widget.sizeOf(p).width)
                    .fold(0.0, (a, b) => a + b)) /
            row
                .where(widget.scales)
                .map((p) => widget.sizeOf(p).width)
                .fold(0.0, (a, b) => a + b),
    ].fold(double.infinity, min);
    // Never nothing: cards wider than the stage leave the devices a sliver.
    return max(0.05, [1.0, down, across].reduce(min));
  }

  /// The people in the number of rows that draws everyone largest.
  List<List<String>> _rows(Size viewport) {
    var people = widget.people;
    var best = [people];
    var bestScale = 0.0;
    for (var count = 1; count <= people.length; count++) {
      var perRow = (people.length / count).ceil();
      var rows = [
        for (var i = 0; i < people.length; i += perRow)
          people.sublist(i, min(i + perRow, people.length)),
      ];
      var scale = _fitAll(viewport, rows);
      if (scale > bestScale) (best, bestScale) = (rows, scale);
    }
    return best;
  }

  /// Where each person goes at [scale], label and device together: rows
  /// centred across, the whole centred on the stage, then moved by [pan] as
  /// far as the zoom lets it go.
  Map<String, Rect> _place(
    List<List<String>> rows,
    double scale,
    Size viewport,
    Offset pan,
  ) {
    var rowSizes = [
      for (var row in rows)
        Size(
          row.map((p) => _drawn(p, scale).width).fold(0.0, (a, b) => a + b) +
              (row.length - 1) * _gap,
          widget.labelHeight +
              row.map((p) => _drawn(p, scale).height).fold(0.0, max),
        ),
    ];
    var content = Size(
      rowSizes.map((s) => s.width).fold(0.0, max) + 2 * _pad,
      rowSizes.fold(0.0, (sum, s) => sum + s.height) +
          (rows.length - 1) * _gap +
          2 * _pad,
    );
    _slack = Size(
      max(0, (content.width - viewport.width) / 2),
      max(0, (content.height - viewport.height) / 2),
    );
    var origin =
        Offset(
          (viewport.width - content.width) / 2,
          (viewport.height - content.height) / 2,
        ) +
        _clamp(pan);
    var placed = <String, Rect>{};
    var y = origin.dy + _pad;
    for (var (i, row) in rows.indexed) {
      var x = origin.dx + (content.width - rowSizes[i].width) / 2;
      for (var person in row) {
        var size = _drawn(person, scale);
        var height = widget.labelHeight + size.height;
        // Centred down the row, so someone shorter than its tallest — a
        // phone beside a browser, a card — stands level with them.
        placed[person] = Rect.fromLTWH(
          x,
          y + (rowSizes[i].height - height) / 2,
          size.width,
          height,
        );
        x += size.width + _gap;
      }
      y += rowSizes[i].height + _gap;
    }
    return placed;
  }

  /// [pan], kept within what the zoom lets the people move: nowhere at all
  /// while everyone is in view.
  Offset _clamp(Offset pan) => Offset(
    pan.dx.clamp(-_slack.width, _slack.width),
    pan.dy.clamp(-_slack.height, _slack.height),
  );

  void _pan(Offset delta) {
    var view = widget.view;
    var moved = _clamp(view.pan + delta);
    if (moved != view.pan) view.panBy(moved - view.pan);
  }

  /// [local], as the view measures a focal point: from the stage's centre.
  Offset _fromCentre(Offset local) {
    var box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Offset.zero;
    return local - box.size.center(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    var view = widget.view;
    return LayoutBuilder(
      builder: (context, constraints) {
        var viewport = constraints.biggest;
        var rows = _rows(viewport);
        var base = _fitAll(viewport, rows);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            if (!_referee.ownerOf(event).isStage) return;
            if (isStageModifier()) {
              view.zoomBy(
                exp(-event.scrollDelta.dy * 0.0016),
                _fromCentre(event.localPosition),
              );
            } else {
              _pan(-event.scrollDelta);
            }
          },
          onPointerPanZoomStart: (event) {
            _referee.ownerOf(event);
            _panAt = Offset.zero;
            _pinchFrom = 1;
          },
          onPointerPanZoomUpdate: (event) {
            if (!_referee.ownerOf(event).isStage) return;
            if (event.scale != 1.0) {
              view.zoomBy(
                event.scale / _pinchFrom,
                _fromCentre(event.localPosition),
              );
              _pinchFrom = event.scale;
              return;
            }
            var step = event.pan - _panAt;
            _panAt = event.pan;
            if (isStageModifier()) {
              view.zoomBy(
                exp(step.dy * 0.0016),
                _fromCentre(event.localPosition),
              );
            } else {
              _pan(step);
            }
          },
          onPointerPanZoomEnd: (event) {
            _referee.ownerOf(event);
            _pinchFrom = 1;
          },
          onPointerDown: (event) {
            if (!_referee.ownerOf(event).isStage) return;
            _dragFrom = event.localPosition;
            widget.onGround();
          },
          onPointerMove: (event) {
            var from = _dragFrom;
            if (from == null || !_referee.ownerOf(event).isStage) return;
            _pan(event.localPosition - from);
            _dragFrom = event.localPosition;
          },
          onPointerUp: (event) {
            _referee.ownerOf(event);
            _dragFrom = null;
          },
          onPointerCancel: (event) {
            _referee.ownerOf(event);
            _dragFrom = null;
          },
          child: ClipRect(
            child: ColoredBox(
              color: stageGroundColor(context.colors),
              child: ListenableBuilder(
                listenable: view,
                builder: (context, _) {
                  var scale = base * view.zoom;
                  widget.onScale(scale);
                  var placed = _place(rows, scale, viewport, view.pan);
                  // Where the zoom left it, not past it: a zoom out that
                  // shrank the room to pan in keeps the people in view.
                  view.pan = _clamp(view.pan);
                  _devices = {
                    for (var MapEntry(key: person, value: rect)
                        in placed.entries)
                      if (widget.scales(person))
                        person: Rect.fromLTRB(
                          rect.left,
                          rect.top + widget.labelHeight,
                          rect.right,
                          rect.bottom,
                        ),
                  };
                  var inView = Offset.zero & viewport;
                  widget.onDrawn?.call({
                    for (var MapEntry(key: person, value: rect)
                        in _devices.entries)
                      if (rect.overlaps(inView)) person,
                  });
                  return Stack(
                    children: [
                      for (var MapEntry(key: person, value: rect)
                          in placed.entries)
                        Positioned.fromRect(
                          rect: rect,
                          child: widget.person(
                            person,
                            scale,
                            (event) => _referee.ownerOf(event).person != person,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
