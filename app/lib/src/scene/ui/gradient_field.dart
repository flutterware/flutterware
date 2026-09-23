// A gradient's stops, as the bar every design tool draws: the gradient
// itself, a handle under each stop, a tap on the bar to add one, a drag to
// move one, and the selected stop's colour and position beneath.
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutterware/scene_authoring.dart';

import '../../ui/design/design.dart';
import '../../ui/tappable.dart';
import '../gradient_edit.dart';
import 'number_field.dart';
import 'number_shape.dart';
import 'pointer.dart';
import 'swatches.dart';

/// A change to the gradient, with the words for its undo entry. [mergeKey]
/// is set while a gesture runs, so one drag is one undo entry.
typedef GradientChanged = void Function(
  SceneGradient next, {
  required String label,
  String? mergeKey,
});

class SceneGradientField extends StatefulWidget {
  const SceneGradientField({
    super.key,
    required this.gradient,
    required this.onChanged,
  });

  final SceneGradient gradient;
  final GradientChanged onChanged;

  @override
  State<SceneGradientField> createState() => _SceneGradientFieldState();
}

class _SceneGradientFieldState extends State<SceneGradientField> {
  static const _barHeight = 18.0;
  static const _handle = 12.0;

  /// Which stop is selected, by position — a stop is a value with no
  /// identity, so an index is all there is, and every edit says where the
  /// stop went.
  var _selected = 0;

  /// The gradient as this field last wrote it, until the parent hands it
  /// back. A drag delivers updates faster than the editor rebuilds, and an
  /// update computed from the previous gradient moves the wrong stop the
  /// moment a sort has reordered them.
  SceneGradient? _pending;

  /// Where the dragged handle's centre is, in the track's pixels — kept here
  /// rather than read back from the stop, which is rounded to three places.
  double? _dragX;

  SceneGradient get _g => _pending ?? widget.gradient;

  int get _index => _selected.clamp(0, _g.colors.length - 1);

  @override
  void didUpdateWidget(SceneGradientField old) {
    super.didUpdateWidget(old);
    if (widget.gradient != old.gradient) _pending = null;
  }

  void _apply(StopEdit edit, String label, {String? mergeKey}) {
    setState(() {
      _pending = edit.gradient;
      _selected = edit.index;
    });
    widget.onChanged(edit.gradient, label: label, mergeKey: mergeKey);
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colors;
    var stops = _g.resolvedStops;
    var index = _index;
    var removable = _g.colors.length > 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // Handles ride a track inset by half a handle at each end, so the
            // first and last sit under the bar's ends without overhanging.
            var track = constraints.maxWidth - _handle;
            double at(double t) => _handle / 2 + t * track;
            double tOf(double x) => ((x - _handle / 2) / track).clamp(0.0, 1.0);
            return SizedBox(
              width: double.infinity,
              height: _barHeight + FwSpacing.xxs + _handle,
              child: Stack(
                children: [
                  Positioned(
                    left: _handle / 2,
                    right: _handle / 2,
                    top: 0,
                    height: _barHeight,
                    child: GestureDetector(
                      key: const ValueKey('gradient:bar'),
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => _apply(
                        addStop(_g, tOf(d.localPosition.dx + _handle / 2)),
                        'Add stop',
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            context.radii.micro,
                          ),
                          border: Border.all(color: colors.line),
                          gradient: LinearGradient(
                            colors: [for (var c in _g.colors) Color(c.argb)],
                            stops: stops,
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < stops.length; i++)
                    Positioned(
                      left: at(stops[i]) - _handle / 2,
                      top: _barHeight + FwSpacing.xxs,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: GestureDetector(
                          key: ValueKey('gradient:stop:$i'),
                          supportedDevices: editingDevices,
                          dragStartBehavior: DragStartBehavior.down,
                          onTap: () => setState(() => _selected = i),
                          onHorizontalDragStart: (_) {
                            setState(() => _selected = i);
                            _dragX = at(stops[i]);
                          },
                          onHorizontalDragUpdate: (d) {
                            _dragX = _dragX! + d.delta.dx;
                            _apply(
                              moveStop(_g, _index, tOf(_dragX!)),
                              'Move stop',
                              mergeKey: 'stop',
                            );
                          },
                          onHorizontalDragEnd: (_) => _dragX = null,
                          child: _StopHandle(
                            color: _g.colors[i],
                            selected: i == index,
                            size: _handle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        const Gap(FwSpacing.sm),
        Row(
          children: [
            Expanded(
              child: SceneColorField(
                current: _g.colors[index],
                allowNone: false,
                onPick: (c) =>
                    _apply(recolorStop(_g, index, c!), 'Stop colour'),
              ),
            ),
            const Gap(FwSpacing.sm),
            SizedBox(
              width: 64,
              child: SceneNumberField(
                value: stops[index] * 100,
                shape: const SceneNumberShape(
                  perPixel: 0.5,
                  decimals: 0,
                  unit: '%',
                  min: 0,
                  max: 100,
                ),
                onChanged: (v) => _apply(
                  moveStop(_g, index, v / 100),
                  'Move stop',
                  mergeKey: 'stop:at',
                ),
                onCommit: (v) => _apply(
                  moveStop(_g, index, v / 100),
                  'Move stop',
                  mergeKey: 'stop:at',
                ),
              ),
            ),
            Tappable(
              key: const ValueKey('gradient:remove'),
              onTap: removable
                  ? () => _apply(removeStop(_g, index), 'Remove stop')
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(FwSpacing.xxs),
                child: Icon(
                  Icons.close,
                  size: FwIconSize.xs,
                  color: removable ? colors.mut2 : colors.line,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One stop's handle: its colour in a small square, ringed in the accent
/// when it is the one the fields below are editing.
class _StopHandle extends StatelessWidget {
  const _StopHandle({
    required this.color,
    required this.selected,
    required this.size,
  });

  final SceneColor color;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Color(color.argb),
      borderRadius: BorderRadius.circular(context.radii.micro),
      border: Border.all(
        color: selected ? context.colors.accent : context.colors.line,
        width: selected ? 2 : 1,
      ),
    ),
  );
}
