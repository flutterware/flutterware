import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutterware/scene.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/context_menu.dart';
import '../../ui/design/design.dart';
import '../../ui/menu.dart';
import '../../ui/tappable.dart';
import '../editor.dart';
import '../model_assets.dart';
import '../playback.dart';
import '../type_axes.dart';
import 'inline_name.dart';
import 'modifiers.dart';
import 'pointer.dart';
import 'shortcuts.dart';
import 'transport.dart';

/// The keyframe editor: one lane per animated track, keys as diamonds, the
/// playhead across all of them.
///
/// Rows are scene nodes — a group targets a node by name, so the gutter is
/// the node tree filtered to what moves — and every key drawn is a
/// [MotionKeyRef] the editor can select, nudge and delete as a set. A drag
/// goes through `nudgeKeys` with a merge key, so it is one undo entry
/// however far it went, and the sort door keeps the track ordered while it
/// moves.
/// How much time the strip shows for a motion [durationMs] long: never less
/// than a second, and always room past the end, rounded up to the ruler's
/// step — a new motion has no length yet, and a key has to go somewhere.
int spanFor(int durationMs) {
  var wanted = math.max(1000, (durationMs * 1.25).ceil());
  var step = _Ruler.step(wanted);
  return ((wanted + step - 1) ~/ step) * step;
}

/// How the strip maps time to pixels: so many pixels per millisecond, from
/// an offset. Fit is the span over the width; ⌘-scroll zooms about the
/// pointer and a horizontal scroll moves along.
class TimeScale {
  const TimeScale({required this.pxPerMs, required this.offsetMs});

  final double pxPerMs;
  final double offsetMs;

  double xOf(num ms) => (ms - offsetMs) * pxPerMs;
  double msAt(double x) => x / pxPerMs + offsetMs;
}

class SceneTimeline extends StatefulWidget {
  const SceneTimeline(
    this.editor,
    this.playback, {
    super.key,
    this.gutterWidth = 240,
    this.transport = true,
    this.axesFor,
    this.packageRoot,
  });

  final SceneEditor editor;
  final ScenePlayback playback;
  final double gutterWidth;

  /// The package the file belongs to — where a clip block reads the length
  /// of the clip it runs, to be born the right size.
  final String? packageRoot;

  /// Whether the transport sits in the ruler's gutter. Off where the
  /// arrangement puts it on a toolbar instead.
  final bool transport;

  /// What a family's variable axes are. Without it the menus offer the
  /// table's rows and nothing else, which is what a static family has.
  final AxesLookup? axesFor;

  @override
  State<SceneTimeline> createState() => _SceneTimelineState();
}

class _SceneTimelineState extends State<SceneTimeline> {
  final _focus = FocusNode(debugLabel: 'scene timeline');

  /// Pixels per millisecond, or null while the strip fits the whole span.
  double? _pxPerMs;
  double _offsetMs = 0;

  /// The strip's width as last laid out, and the span it would fit.
  double _stripWidth = 1;
  int _span = 1000;

  TimeScale get _scale =>
      TimeScale(pxPerMs: _pxPerMs ?? _stripWidth / _span, offsetMs: _offsetMs);

  /// Zooms by [factor] about [x] on the strip, clamped between fit and ten
  /// pixels a millisecond, and keeps the whole span reachable.
  void _zoom(double factor, double x) {
    var fit = _stripWidth / _span;
    var current = _pxPerMs ?? fit;
    var next = (current * factor).clamp(fit, 10.0);
    if (next == current) return;
    var msUnder = _scale.msAt(x);
    setState(() {
      _pxPerMs = next == fit ? null : next;
      _offsetMs = _clampOffset(msUnder - x / next, next);
    });
  }

  void _scroll(double dx) {
    var next = _clampOffset(_offsetMs - dx / _scale.pxPerMs, _scale.pxPerMs);
    if (next != _offsetMs) setState(() => _offsetMs = next);
  }

  double _clampOffset(double ms, double pxPerMs) {
    var visible = _stripWidth / pxPerMs;
    return ms.clamp(0.0, math.max(0.0, _span - visible)).toDouble();
  }

  /// Where a trackpad gesture last was, so its cumulative pan reads as a
  /// delta.
  Offset _panSeen = Offset.zero;

  bool get _zoomKey =>
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;

  double _stripX(Offset local) => local.dx - widget.gutterWidth - 1;

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_zoomKey) {
      _zoom(
        math.exp(-event.scrollDelta.dy * 0.0016),
        _stripX(event.localPosition),
      );
    } else if (event.scrollDelta.dx != 0) {
      _scroll(-event.scrollDelta.dx);
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) =>
      _panSeen = Offset.zero;

  void _onPanZoom(PointerPanZoomUpdateEvent event) {
    var delta = event.pan - _panSeen;
    _panSeen = event.pan;
    if (event.scale != 1.0) return; // a pinch: the canvas's, not the strip's
    if (_zoomKey) {
      _zoom(math.exp(delta.dy * 0.004), _stripX(event.localPosition));
    } else if (delta.dx.abs() > delta.dy.abs()) {
      _scroll(delta.dx);
    }
  }

  SceneEditor get editor => widget.editor;
  ScenePlayback get playback => widget.playback;
  MotionDocument get motion => playback.motion;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// The placed groups in document order, each with its lanes — one per
  /// track, with the group's start so a key draws at its absolute time.
  ///
  /// Document order, not start order: a row that sorted by start would move
  /// while its bar is being dragged past a neighbour, and a drag whose row
  /// walks away under the pointer is how one gesture came to move two groups.
  List<_GroupLanes> _groups() {
    var placements = motion.placements;
    var out = <_GroupLanes>[];
    for (var group in motion.groups) {
      // A group the timeline expression does not place — legal in a
      // hand-edited file — is shown at zero; dragging its bar places it.
      var at = placements[group.name] ?? Duration.zero;
      out.add(
        _GroupLanes(group, at, [
          for (var MapEntry(key: prop, value: track) in group.tracks.entries)
            _Lane(group, prop, track, at),
        ]),
      );
    }
    return out;
  }

  /// A key on [prop] of [group], at the playhead — the door every "animate
  /// this" gesture ends in. A group that is not placed cannot take the
  /// playhead's time; it gets a key at its own zero.
  void _keyAtPlayhead(AnimateGroup group, String prop) {
    var at = motion.placements[group.name];
    var t = at == null ? Duration.zero : playback.position - at;
    editor.addKey(
      playback.motionName,
      group.name,
      prop,
      t < Duration.zero ? Duration.zero : t,
      value: _seed(group.node, prop),
    );
  }

  /// Where a fresh track on an AXIS starts.
  ///
  /// Every other property answers for itself — the editor reads the node —
  /// but an axis the node has not set rests wherever the FONT puts it, and
  /// only the file knows that. Null everywhere else, which leaves the
  /// editor's own answer alone.
  Object? _seed(SceneNode node, String prop) {
    if (sceneAxisTag(prop) == null) return null;
    if (getSceneProperty(node, prop) case var v?) return v;
    for (var spec in sceneAnimatableProps(node, widget.axesFor)) {
      if (spec.name == prop) return spec.identity;
    }
    return null;
  }

  /// The selected node's first group — made and placed at zero when it has
  /// none — then a key on [prop] at the playhead.
  void _animateSelected(SceneNode node, String prop) {
    var group =
        editor.groupsTargeting(playback.motionName, node).firstOrNull ??
        editor.addGroup(playback.motionName, node);
    _keyAtPlayhead(group, prop);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return _TimelineShortcuts(
      editor: editor,
      playback: playback,
      focusNode: _focus,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          editor.listenable,
          editor.doc.listenable,
          playback,
        ]),
        builder: (context, _) {
          var groups = _groups();
          _span = spanFor(playback.duration.inMilliseconds);
          var selected = editor.primary;
          var selectedName = selected?.name;
          var selectedHasGroup = groups.any(
            (g) => g.group.node.name == selectedName,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              _stripWidth = math.max(
                1.0,
                constraints.maxWidth - widget.gutterWidth - 1,
              );
              var scale = _scale;
              return Listener(
                onPointerSignal: _onSignal,
                onPointerPanZoomStart: _onPanZoomStart,
                onPointerPanZoomUpdate: _onPanZoom,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 28,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: widget.gutterWidth,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: FwSpacing.xs,
                              ),
                              child: widget.transport
                                  ? Align(
                                      alignment: Alignment.centerLeft,
                                      child: SceneTransport(
                                        playback,
                                        compact: true,
                                      ),
                                    )
                                  : Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: FwSpacing.md,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          playback.motionName,
                                          style: context.type.bodyStrong,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          _gutterEdge(colors),
                          Expanded(
                            child: _Ruler(
                              scale: scale,
                              playheadMs: playback.position.inMilliseconds,
                              onSeek: (ms) => playback.seek(
                                Duration(milliseconds: ms.round()),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(height: 1, color: colors.line),
                    Expanded(
                      child: groups.isEmpty && selected == null
                          ? Center(
                              child: Text(
                                'Nothing animates yet — select a node to animate it',
                                style: context.type.bodyMuted,
                              ),
                            )
                          : ListView(
                              children: [
                                for (var g in groups) ...[
                                  _GroupRow(
                                    key: ValueKey('group:${g.group.name}'),
                                    lanes: g,
                                    showName:
                                        groups
                                            .where(
                                              (o) =>
                                                  o.group.node.name ==
                                                  g.group.node.name,
                                            )
                                            .length >
                                        1,
                                    editor: editor,
                                    playback: playback,
                                    scale: scale,
                                    gutterWidth: widget.gutterWidth,
                                    axesFor: widget.axesFor,
                                    onAddKey: (prop) =>
                                        _keyAtPlayhead(g.group, prop),
                                  ),
                                  for (var lane in g.lanes)
                                    _LaneRow(
                                      key: ValueKey(
                                        'lane:${g.group.name}/${lane.prop}',
                                      ),
                                      lane: lane,
                                      editor: editor,
                                      playback: playback,
                                      scale: scale,
                                      gutterWidth: widget.gutterWidth,
                                      packageRoot: widget.packageRoot,
                                    ),
                                ],
                                if (selected != null && !selectedHasGroup)
                                  _AnimateRow(
                                    node: selected,
                                    gutterWidth: widget.gutterWidth,
                                    axesFor: widget.axesFor,
                                    onPick: (prop) =>
                                        _animateSelected(selected, prop),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _gutterEdge(FwPalette colors) =>
      Container(width: 1, color: colors.line);
}

class _Lane {
  const _Lane(this.group, this.prop, this.track, this.at);

  final AnimateGroup group;
  final String prop;
  final MotionTrack track;

  /// Where the group starts on the timeline.
  final Duration at;

  String get label => sceneKeyLabel(prop);
}

/// A placed group and the lanes under it.
class _GroupLanes {
  const _GroupLanes(this.group, this.at, this.lanes);

  final AnimateGroup group;
  final Duration at;
  final List<_Lane> lanes;
}

/// The row a group gets above its lanes: its node and its name in the
/// gutter with the door to a new track, and in the strip a bar spanning its
/// length — dragging the bar moves the whole group on the timeline.
class _GroupRow extends StatefulWidget {
  const _GroupRow({
    super.key,
    this.axesFor,
    required this.lanes,
    required this.editor,
    required this.playback,
    required this.scale,
    required this.gutterWidth,
    required this.onAddKey,
    required this.showName,
  });

  final _GroupLanes lanes;
  final SceneEditor editor;
  final ScenePlayback playback;
  final TimeScale scale;
  final double gutterWidth;
  final ValueChanged<String> onAddKey;

  /// See [SceneTimeline.axesFor].
  final AxesLookup? axesFor;

  /// Whether the row says the group's name after the node's. The name is
  /// the group's field in the motion class — `headlineIn` — and reads as
  /// noise beside `headline` until the node has a second group in this
  /// motion, when it is what tells the two rows apart. The menu always says
  /// it.
  final bool showName;

  static const height = 26.0;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  var _carried = 0.0;
  var _dragging = false;
  var _renaming = false;

  String? _rename(String wanted) {
    if (!_renaming) return null;
    try {
      editor.renameGroup(widget.playback.motionName, group.name, wanted);
      setState(() => _renaming = false);
      return null;
    } on ArgumentError catch (e) {
      return e.message as String?;
    }
  }

  AnimateGroup get group => widget.lanes.group;
  SceneEditor get editor => widget.editor;

  void _down(Offset local, double width) {
    var start = widget.scale.xOf(widget.lanes.at.inMilliseconds);
    var end = widget.scale.xOf(
      (widget.lanes.at + group.duration).inMilliseconds,
    );
    if (local.dx < start - 4 || local.dx > end + 4) {
      widget.playback.seek(
        Duration(milliseconds: widget.scale.msAt(local.dx).round()),
      );
      return;
    }
    editor.select(editor.doc.nodeNamed(group.node.name));
    _dragging = true;
    _carried = 0;
  }

  void _update(double dx, double width) {
    if (!_dragging) return;
    _carried += dx / widget.scale.pxPerMs;
    var whole = _carried.truncate();
    if (whole == 0) return;
    _carried -= whole;
    var at = widget.playback.motion.placements[group.name] ?? Duration.zero;
    editor.moveGroup(
      widget.playback.motionName,
      group.name,
      at + Duration(milliseconds: whole),
      mergeKey: 'groupdrag',
    );
  }

  void _end() {
    if (!_dragging) return;
    _dragging = false;
    editor.endMerge();
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var node = editor.doc.nodeNamed(group.node.name);
    var tracked = group.tracks.keys.toSet();
    var offered = node == null
        ? const <ScenePropSpec>[]
        : sceneAnimatableProps(
            node,
            widget.axesFor,
          ).where((p) => !tracked.contains(p.name));
    var hovered = editor.hover == group.node.name;
    var selected = node != null && editor.isSelected(node);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => showContextMenu(context, d.globalPosition, [
        MenuItem(
          'Rename ${group.name}…',
          icon: Icons.edit_outlined,
          onSelected: () => setState(() => _renaming = true),
        ),
        MenuItem(
          'Delete ${group.name}',
          icon: Icons.close,
          danger: true,
          onSelected: () =>
              editor.deleteGroup(widget.playback.motionName, group.name),
        ),
      ]),
      child: SizedBox(
        height: _GroupRow.height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: widget.gutterWidth,
              child: MouseRegion(
                onEnter: (_) => editor.hover = group.node.name,
                onExit: (_) {
                  if (editor.hover == group.node.name) editor.hover = null;
                },
                child: Tappable(
                  onTap: () => editor.select(node, toggle: toggleModifier),
                  child: Container(
                    color: selected ? colors.accentSoft : null,
                    padding: const EdgeInsets.only(
                      left: FwSpacing.lg,
                      right: FwSpacing.xs,
                    ),
                    child: Row(
                      spacing: FwSpacing.sm,
                      children: [
                        if (_renaming)
                          Expanded(
                            child: InlineNameField(
                              initial: group.name,
                              dense: true,
                              onCommit: _rename,
                              onCancel: () => setState(() => _renaming = false),
                            ),
                          )
                        else
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                text: group.node.name,
                                style: context.type.body.copyWith(
                                  color: hovered || selected
                                      ? colors.accentDark
                                      : colors.ink,
                                ),
                                children: [
                                  if (widget.showName)
                                    TextSpan(
                                      text: '  ${group.name}',
                                      style: context.type.caption.copyWith(
                                        color: colors.mut3,
                                      ),
                                    ),
                                ],
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        if (offered.isNotEmpty)
                          _AddPropertyButton(
                            tooltip:
                                'Animate another property of ${group.node.name} — '
                                'a key at the playhead',
                            entries: [
                              for (var spec in offered)
                                MenuItem(
                                  sceneKeyLabel(spec.name),
                                  onSelected: () => widget.onAddKey(spec.name),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(width: 1, color: colors.line),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  var width = math.max(1.0, constraints.maxWidth);
                  return MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: GestureDetector(
                      supportedDevices: editingDevices,
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onHorizontalDragDown: (d) =>
                          _down(d.localPosition, width),
                      onHorizontalDragUpdate: (d) => _update(d.delta.dx, width),
                      onHorizontalDragEnd: (_) => _end(),
                      onHorizontalDragCancel: _end,
                      // Clipped: zoomed in, a bar that starts off to the left
                      // painted across the gutter and over the row's name.
                      child: ClipRect(
                        child: CustomPaint(
                          painter: _SpanPainter(
                            start: widget.scale.xOf(
                              widget.lanes.at.inMilliseconds,
                            ),
                            end: widget.scale.xOf(
                              (widget.lanes.at + group.duration).inMilliseconds,
                            ),
                            playhead: widget.scale.xOf(
                              widget.playback.position.inMilliseconds,
                            ),
                            fill: selected
                                ? colors.accentSoft2
                                : colors.accentSoft,
                            edge: colors.accent,
                            line: colors.line,
                            playheadColor: colors.red,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpanPainter extends CustomPainter {
  _SpanPainter({
    required this.start,
    required this.end,
    required this.playhead,
    required this.fill,
    required this.edge,
    required this.line,
    required this.playheadColor,
  });

  final double start;
  final double end;
  final double playhead;
  final Color fill;
  final Color edge;
  final Color line;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()..color = line,
    );
    var bar = RRect.fromRectAndRadius(
      Rect.fromLTRB(start, 6, math.max(end, start + 4), size.height - 6),
      const Radius.circular(4),
    );
    canvas.drawRRect(bar, Paint()..color = fill);
    canvas.drawRRect(
      bar,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge.withValues(alpha: 0.6),
    );
    canvas.drawLine(
      Offset(playhead, 0),
      Offset(playhead, size.height),
      Paint()
        ..color = playheadColor.withValues(alpha: 0.8)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SpanPainter old) => true;
}

/// The row a selected node gets when nothing animates it yet: pick a
/// property, and a group is made for it with a key at the playhead.
class _AnimateRow extends StatelessWidget {
  const _AnimateRow({
    required this.node,
    required this.gutterWidth,
    required this.onPick,
    this.axesFor,
  });

  final SceneNode node;
  final double gutterWidth;
  final ValueChanged<String> onPick;

  /// See [SceneTimeline.axesFor].
  final AxesLookup? axesFor;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return SizedBox(
      height: _GroupRow.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: gutterWidth,
            child: Padding(
              padding: const EdgeInsets.only(
                left: FwSpacing.lg,
                right: FwSpacing.xs,
              ),
              child: Row(
                spacing: FwSpacing.sm,
                children: [
                  Expanded(
                    child: Text(
                      node.name,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.body.copyWith(color: colors.mut),
                    ),
                  ),
                  _AddPropertyButton(
                    tooltip: 'Animate ${node.name} — a key at the playhead',
                    entries: [
                      for (var spec in sceneAnimatableProps(node, axesFor))
                        MenuItem(
                          sceneKeyLabel(spec.name),
                          onSelected: () => onPick(spec.name),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Container(width: 1, color: colors.line),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.line)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LaneRow extends StatelessWidget {
  const _LaneRow({
    super.key,
    required this.lane,
    required this.editor,
    required this.playback,
    required this.scale,
    required this.gutterWidth,
    this.packageRoot,
  });

  final _Lane lane;
  final SceneEditor editor;
  final ScenePlayback playback;
  final TimeScale scale;
  final double gutterWidth;
  final String? packageRoot;

  static const height = 26.0;

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var node = editor.doc.nodeNamed(lane.group.node.name);
    var hovered = node != null && editor.hover == node.name;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: gutterWidth,
            child: MouseRegion(
              onEnter: (_) => editor.hover = lane.group.node.name,
              onExit: (_) {
                if (editor.hover == lane.group.node.name) editor.hover = null;
              },
              child: Tappable(
                onTap: () => editor.select(node, toggle: toggleModifier),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: FwSpacing.xxl + FwSpacing.md,
                    right: FwSpacing.md,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      lane.label,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.caption.copyWith(
                        color: hovered ? colors.accentDark : colors.mut,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, color: colors.line),
          Expanded(
            child: _KeyStrip(
              lane: lane,
              editor: editor,
              playback: playback,
              scale: scale,
              packageRoot: packageRoot,
            ),
          ),
        ],
      ),
    );
  }
}

/// One lane's keys — or its clip blocks — hit and dragged in milliseconds.
class _KeyStrip extends StatefulWidget {
  const _KeyStrip({
    required this.lane,
    required this.editor,
    required this.playback,
    required this.scale,
    this.packageRoot,
  });

  final _Lane lane;
  final SceneEditor editor;
  final ScenePlayback playback;
  final TimeScale scale;
  final String? packageRoot;

  @override
  State<_KeyStrip> createState() => _KeyStripState();
}

class _KeyStripState extends State<_KeyStrip> {
  /// Sub-millisecond drag carried to the next update, so a slow drag still
  /// moves the key.
  var _carried = 0.0;
  var _dragging = false;

  /// The block a drag holds, and what it does to it: `move`, or
  /// `start`/`end` for a trim.
  int? _clipIndex;
  String? _clipEdge;

  _Lane get lane => widget.lane;
  SceneEditor get editor => widget.editor;
  List<MotionClip> get _clips => lane.track.clips;
  String get _motion => widget.playback.motionName;

  /// The block's ends on the strip.
  (double, double) _clipSpan(MotionClip c) => (
    widget.scale.xOf((lane.at + c.at).inMilliseconds),
    widget.scale.xOf((lane.at + c.end).inMilliseconds),
  );

  /// The placement this lane belongs to, when the lane is its time.
  KindNode? _placement() {
    if (lane.prop != 'animationTime') return null;
    var node = editor.doc.nodeNamed(lane.group.node.name);
    return node is KindNode ? node : null;
  }

  /// The clips the placement's asset carries, with their lengths — what a
  /// block is born from. Empty where nothing is known.
  List<ModelClip> _assetClips() {
    var node = _placement();
    var root = widget.packageRoot;
    if (node == null || root == null) return const [];
    var asset = '${scenePropNamed(node, 'asset')?.read(node) ?? ''}';
    if (asset.isEmpty) return const [];
    return ModelAssets.shared.info(root, asset)?.clips ?? const [];
  }

  /// What the placement's own `animation` row names.
  String _rowClip() {
    var node = _placement();
    if (node == null) return '';
    return '${scenePropNamed(node, 'animation')?.read(node) ?? ''}';
  }

  String _clipLabel(MotionClip c) {
    var name = c.clip.isNotEmpty ? c.clip : _rowClip();
    var parts = [
      if (name.isNotEmpty) name else 'clip',
      '${(c.length.inMilliseconds / 1000).toStringAsFixed(2)}s',
      if (c.speed != 1) '×${c.speed.toStringAsFixed(c.speed % 1 == 0 ? 0 : 2)}',
      if (c.offset != Duration.zero)
        'from ${(c.offset.inMilliseconds / 1000).toStringAsFixed(2)}s',
      if (c.reverse) '⟵',
    ];
    return parts.join(' · ');
  }

  MotionKeyRef _ref(MotionKey key) =>
      MotionKeyRef(_motion, lane.group.name, lane.prop, key.id);

  MotionClipRef _clipRef(MotionClip c) =>
      MotionClipRef(_motion, lane.group.name, lane.prop, c.id);

  double _x(MotionKey key, double width) =>
      widget.scale.xOf((lane.at + key.at).inMilliseconds);

  MotionKey? _hit(Offset local, double width) {
    MotionKey? best;
    var bestDistance = 7.0;
    for (var key in lane.track.keys) {
      var d = (local.dx - _x(key, width)).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = key;
      }
    }
    return best;
  }

  /// The block under [local] and which part of it: an edge within six
  /// pixels first, then a body — the later block where two overlap, since
  /// it is drawn on top.
  (int, String)? _hitClip(Offset local) {
    for (var i = _clips.length - 1; i >= 0; i--) {
      var (start, end) = _clipSpan(_clips[i]);
      if ((local.dx - start).abs() <= 6) return (i, 'start');
      if ((local.dx - end).abs() <= 6) return (i, 'end');
    }
    for (var i = _clips.length - 1; i >= 0; i--) {
      var (start, end) = _clipSpan(_clips[i]);
      if (local.dx > start && local.dx < end) return (i, 'move');
    }
    return null;
  }

  void _down(Offset local, double width) {
    if (_clips.isNotEmpty) {
      editor.clearKeySelection();
      var hit = _hitClip(local);
      if (hit == null) {
        widget.playback.seek(
          Duration(milliseconds: widget.scale.msAt(local.dx).round()),
        );
        return;
      }
      var (index, edge) = hit;
      var ref = _clipRef(_clips[index]);
      if (!editor.isClipSelected(ref)) editor.selectClip(ref);
      _clipIndex = index;
      _clipEdge = edge;
      _dragging = true;
      _carried = 0;
      return;
    }
    var key = _hit(local, width);
    if (key == null) {
      editor.clearKeySelection();
      widget.playback.seek(
        Duration(milliseconds: widget.scale.msAt(local.dx).round()),
      );
      return;
    }
    var ref = _ref(key);
    if (toggleModifier) {
      editor.selectKey(ref, toggle: true);
    } else if (!editor.isKeySelected(ref)) {
      editor.selectKey(ref);
    }
    _dragging = true;
    _carried = 0;
  }

  void _update(double dx, double width) {
    if (!_dragging) return;
    _carried += dx / widget.scale.pxPerMs;
    var whole = _carried.truncate();
    if (whole == 0) return;
    _carried -= whole;
    if (_clipIndex case var index?) {
      var block = _clips[index];
      editor.nudgeClip(
        _motion,
        lane.group.name,
        lane.prop,
        index,
        Duration(milliseconds: whole),
        edge: _clipEdge ?? 'move',
        mergeKey: 'clipdrag',
      );
      // A move may re-sort the blocks; the drag keeps holding the same one.
      _clipIndex = _clips.indexOf(block);
      return;
    }
    editor.nudgeKeys(Duration(milliseconds: whole), mergeKey: 'keydrag');
  }

  void _end() {
    if (!_dragging) return;
    _dragging = false;
    _clipIndex = null;
    _clipEdge = null;
    editor.endMerge();
  }

  /// A block on this lane for [clip], born at [at] within the group and
  /// as long as the clip — or a second, when the asset does not say.
  void _addClipAt(Duration at, String clip) {
    var seconds = _assetClips()
        .where((c) => c.name == (clip.isEmpty ? _rowClip() : clip))
        .firstOrNull
        ?.seconds;
    editor.addClip(
      _motion,
      lane.group.name,
      lane.prop,
      at: at < Duration.zero ? Duration.zero : at,
      length: seconds == null || seconds <= 0
          ? const Duration(seconds: 1)
          : Duration(milliseconds: (seconds * 1000).round()),
      clip: clip,
    );
  }

  /// Where the second tap of a double-tap landed: the recognizer reports the
  /// position on its down and the gesture on its up.
  Offset? _doubleTapAt;

  void _addKeyAt(double width) {
    var local = _doubleTapAt;
    if (local == null) return;
    // A block lane takes no keys by double-click: the blocks are the track.
    if (_clips.isNotEmpty) return;
    var t =
        Duration(milliseconds: widget.scale.msAt(local.dx).round()) - lane.at;
    editor.addKey(
      _motion,
      lane.group.name,
      lane.prop,
      t < Duration.zero ? Duration.zero : t,
    );
  }

  /// Right-click: on a key, the key's verbs; on a block, the block's;
  /// anywhere on the lane, the track's and the group's.
  void _contextMenu(BuildContext context, TapUpDetails d, double width) {
    var motion = _motion;
    var group = lane.group.name;
    var prop = lane.prop;
    var here =
        Duration(milliseconds: widget.scale.msAt(d.localPosition.dx).round()) -
        lane.at;
    var assetClips = _assetClips();
    var rowClip = _rowClip();
    // What a new block may run: the asset's clips, or the row's one when
    // the asset is not readable here.
    var births = [
      for (var c in assetClips) c.name,
      if (assetClips.isEmpty && rowClip.isNotEmpty) '',
    ];
    var hit = _clips.isEmpty ? null : _hitClip(d.localPosition);
    // A block's facts — clip, start, length, speed, offset — are fields in
    // the inspector, where a right-click selects it. The menu keeps the
    // verbs that are one click: the direction, a new block, delete.
    if (hit case (var index, _)) {
      var c = _clips[index];
      editor.selectClip(_clipRef(c));
      showContextMenu(context, d.globalPosition, [
        MenuItem(
          c.reverse ? 'Play forwards' : 'Play backwards',
          icon: c.reverse ? Icons.arrow_forward : Icons.arrow_back,
          onSelected: () =>
              editor.setClip(motion, group, prop, index, reverse: !c.reverse),
        ),
        const MenuDivider(),
        for (var name in births)
          MenuItem(
            'Add ${name.isEmpty ? rowClip : name} block here',
            icon: Icons.view_timeline_outlined,
            onSelected: () => _addClipAt(here, name),
          ),
        const MenuDivider(),
        MenuItem(
          'Delete this block',
          shortcut: '⌫',
          danger: true,
          onSelected: () => editor.deleteClip(motion, group, prop, index),
        ),
        MenuItem(
          'Delete ${lane.group.name}',
          danger: true,
          onSelected: () => editor.deleteGroup(motion, group),
        ),
      ]);
      return;
    }
    var key = _hit(d.localPosition, width);
    if (key != null) {
      var ref = _ref(key);
      if (!editor.isKeySelected(ref)) editor.selectKey(ref);
    }
    var selected = editor.selectedKeys.length;
    showContextMenu(context, d.globalPosition, [
      // A placement's time can be blocks instead of keys: a clip the asset
      // carries, as one bar to move, trim and reverse.
      for (var name in births)
        MenuItem(
          'Add ${name.isEmpty ? rowClip : name} block here',
          icon: Icons.view_timeline_outlined,
          onSelected: () => _addClipAt(here, name),
        ),
      if (key != null) ...[
        MenuItem(
          selected > 1 ? 'Delete $selected keys' : 'Delete key',
          icon: Icons.close,
          shortcut: '⌫',
          danger: true,
          onSelected: editor.deleteKeys,
        ),
        const MenuDivider(),
      ],
      if (_clips.isEmpty)
        MenuItem(
          'Add key here',
          icon: Icons.add,
          onSelected: () {
            _doubleTapAt = d.localPosition;
            _addKeyAt(width);
          },
        ),
      MenuItem(
        'Delete ${lane.label} track',
        danger: true,
        onSelected: () =>
            editor.deleteTrack(motion, lane.group.name, lane.prop),
      ),
      MenuItem(
        'Delete ${lane.group.name}',
        danger: true,
        onSelected: () => editor.deleteGroup(motion, lane.group.name),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = math.max(1.0, constraints.maxWidth);
        // The drag's own down, and no tap recognizer beside it: a tap is a
        // drag that never moved, and two recognizers both answering the
        // press toggled a shift-click twice.
        return GestureDetector(
          supportedDevices: editingDevices,
          behavior: HitTestBehavior.opaque,
          // From the down point: the double-tap recognizer beside this one
          // holds the arena for its slop, and a drag that started counting
          // only after would lose that distance.
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragDown: (d) => _down(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _update(d.delta.dx, width),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          // A double-click on the lane is a new key there.
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () => _addKeyAt(width),
          onSecondaryTapUp: (d) => _contextMenu(context, d, width),
          child: ClipRect(
            child: CustomPaint(
              painter: _KeyPainter(
                xs: [for (var k in lane.track.keys) _x(k, width)],
                selected: [
                  for (var k in lane.track.keys) editor.isKeySelected(_ref(k)),
                ],
                clips: [
                  for (var c in _clips)
                    (
                      _clipSpan(c).$1,
                      _clipSpan(c).$2,
                      _clipLabel(c),
                      editor.isClipSelected(_clipRef(c)),
                    ),
                ],
                labelStyle: context.type.caption.copyWith(
                  color: colors.accentDark,
                ),
                spanStart: widget.scale.xOf(lane.at.inMilliseconds),
                spanEnd: widget.scale.xOf(
                  (lane.at + lane.track.duration).inMilliseconds,
                ),
                playhead: widget.scale.xOf(
                  widget.playback.position.inMilliseconds,
                ),
                line: colors.line,
                key: colors.ink2,
                accent: colors.accent,
                playheadColor: colors.red,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _KeyPainter extends CustomPainter {
  _KeyPainter({
    required this.xs,
    required this.selected,
    required this.spanStart,
    required this.spanEnd,
    required this.playhead,
    required this.line,
    required this.key,
    required this.accent,
    required this.playheadColor,
    this.clips = const [],
    this.labelStyle,
  });

  final List<double> xs;
  final List<bool> selected;

  /// Each block's ends, label and whether it is selected, drawn instead
  /// of keys. Where two overlap, the overlap is shaded again: that is the
  /// crossfade.
  final List<(double, double, String, bool)> clips;
  final TextStyle? labelStyle;
  final double spanStart;
  final double spanEnd;
  final double playhead;
  final Color line;
  final Color key;
  final Color accent;
  final Color playheadColor;

  @override
  void paint(Canvas canvas, Size size) {
    var mid = size.height / 2;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()..color = line,
    );
    for (var (start, end, label, on) in clips) {
      var rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(start, 4, math.max(end, start + 2), size.height - 5),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()..color = accent.withValues(alpha: on ? 0.32 : 0.18),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = on ? 2 : 1
          ..color = accent.withValues(alpha: on ? 1 : 0.7),
      );
      var text = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(0, end - start - 12));
      if (end - start > 24) {
        text.paint(canvas, Offset(start + 6, mid - text.height / 2));
      }
    }
    // Between the first and the last key, where the value moves. Before the
    // first key the track holds that key's value — drawn from the group's
    // start, that read as a track that "starts without a key".
    if (xs.length > 1) {
      canvas.drawLine(
        Offset(xs.reduce(math.min), mid),
        Offset(xs.reduce(math.max), mid),
        Paint()
          ..color = key.withValues(alpha: 0.35)
          ..strokeWidth = 2,
      );
    }
    for (var (i, x) in xs.indexed) {
      var on = selected[i];
      var r = on ? 5.5 : 4.5;
      var path = Path()
        ..moveTo(x, mid - r)
        ..lineTo(x + r, mid)
        ..lineTo(x, mid + r)
        ..lineTo(x - r, mid)
        ..close();
      canvas.drawPath(path, Paint()..color = on ? accent : key);
      if (on) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = accent.withValues(alpha: 0.4),
        );
      }
    }
    canvas.drawLine(
      Offset(playhead, 0),
      Offset(playhead, size.height),
      Paint()
        ..color = playheadColor.withValues(alpha: 0.8)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_KeyPainter old) => true;
}

/// Ticks at a step that keeps about eight labels on screen whatever the
/// zoom, and the playhead's head. Drag anywhere to scrub — past the end
/// too, which is where the next key goes.
class _Ruler extends StatelessWidget {
  const _Ruler({
    required this.scale,
    required this.playheadMs,
    required this.onSeek,
  });

  final TimeScale scale;
  final int playheadMs;
  final ValueChanged<double> onSeek;

  static int step(int duration) {
    for (var candidate in const [
      10,
      20,
      25,
      50,
      100,
      200,
      250,
      500,
      1000,
      2000,
      5000,
    ]) {
      if (duration / candidate <= 8) return candidate;
    }
    return duration <= 0 ? 1 : duration;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = math.max(1.0, constraints.maxWidth);
        var visibleMs = (width / scale.pxPerMs).round();
        var every = step(visibleMs);
        var first = (scale.offsetMs / every).ceil() * every;
        // A tick keeps its line at any width; the words go when two of them
        // would touch — a docked strip can be 60px wide.
        var labelled = every * scale.pxPerMs >= 44;
        void seek(Offset local) => onSeek(math.max(0, scale.msAt(local.dx)));
        return MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            supportedDevices: editingDevices,
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seek(d.localPosition),
            onHorizontalDragDown: (d) => seek(d.localPosition),
            onHorizontalDragUpdate: (d) => seek(d.localPosition),
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var ms = first; scale.xOf(ms) <= width; ms += every)
                    Positioned(
                      left: scale.xOf(ms),
                      top: 0,
                      bottom: 0,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 1,
                            child: ColoredBox(color: context.colors.line),
                          ),
                          if (labelled && scale.xOf(ms) < width - 40)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: FwSpacing.xs,
                                top: FwSpacing.sm,
                              ),
                              child: Text(
                                _label(ms),
                                style: context.type.caption.copyWith(
                                  color: context.colors.mut2,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: scale.xOf(playheadMs) - 4.5,
                    top: 0,
                    child: CustomPaint(
                      size: const Size(9, 6),
                      painter: _PlayheadHead(context.colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _label(int ms) => ms % 1000 == 0 ? '${ms ~/ 1000}s' : '${ms}ms';
}

class _PlayheadHead extends CustomPainter {
  _PlayheadHead(this.tone);

  final Color tone;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close(),
      Paint()..color = tone,
    );
  }

  @override
  bool shouldRepaint(_PlayheadHead old) => old.tone != tone;
}

/// The timeline's focus scope: arrows step the selected keys, Backspace
/// deletes them, space plays. Its own scope rather than the canvas's, because
/// an arrow means a different thing to a key than to a node.
class _TimelineShortcuts extends StatelessWidget {
  const _TimelineShortcuts({
    required this.editor,
    required this.playback,
    required this.focusNode,
    required this.child,
  });

  final SceneEditor editor;
  final ScenePlayback playback;
  final FocusNode focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) => SceneShortcutScope(
    focusNode: focusNode,
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): editor.undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
          editor.redo,
      const SingleActivator(LogicalKeyboardKey.backspace):
          editor.deleteSelected,
      const SingleActivator(LogicalKeyboardKey.delete): editor.deleteSelected,
      const SingleActivator(LogicalKeyboardKey.escape):
          editor.clearKeySelection,
      const SingleActivator(LogicalKeyboardKey.space): playback.toggle,
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => editor
          .nudgeKeys(const Duration(milliseconds: -10), mergeKey: 'keynudge'),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => editor
          .nudgeKeys(const Duration(milliseconds: 10), mergeKey: 'keynudge'),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          editor.nudgeKeys(
            const Duration(milliseconds: -100),
            mergeKey: 'keynudge',
          ),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          editor.nudgeKeys(
            const Duration(milliseconds: 100),
            mergeKey: 'keynudge',
          ),
    },
    child: child,
  );
}

/// The `+` on a row: one button, and its menu is the properties that can
/// take a key. Was a split button whose primary half had nothing to do and
/// sat disabled beside a working chevron — the half people clicked.
class _AddPropertyButton extends StatelessWidget {
  const _AddPropertyButton({required this.tooltip, required this.entries});

  final String tooltip;
  final List<MenuEntry> entries;

  @override
  Widget build(BuildContext context) => Menu(
    entries: entries,
    builder: (context, controller) => Tooltip(
      message: tooltip,
      child: Tappable(
        onTap: controller.toggle,
        borderRadius: BorderRadius.circular(context.radii.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.all(FwSpacing.xxs),
          child: Icon(
            Icons.add,
            size: FwIconSize.md,
            color: controller.isOpen
                ? context.colors.accent
                : context.colors.mut,
          ),
        ),
      ),
    ),
  );
}
