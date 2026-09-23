import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../toolbar.dart';
import '../link.dart';
import '../service.dart';
import 'colors.dart';
import 'image.dart';

class FloatingStack extends StatelessWidget {
  final FigmaService service;
  final Widget child;
  final Map<FigmaLink, FloatPosition> floatingLinks;
  final void Function(FigmaLink) onRemove;
  final void Function(FigmaLink, FloatPosition) onMove;

  const FloatingStack(
    this.service, {
    super.key,
    required this.child,
    required this.floatingLinks,
    required this.onRemove,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        for (var e in floatingLinks.entries)
          _FloatingPreview(
            service,
            e.key,
            e.value,
            key: ValueKey(e.key),
            onRemove: () {
              onRemove(e.key);
            },
            onMove: (p) => onMove(e.key, p),
          ),
      ],
    );
  }
}

class FloatPosition {
  final Offset offset;
  final double width;
  final double opacity;

  FloatPosition({
    required this.offset,
    required this.width,
    required this.opacity,
  });

  FloatPosition copyWith({Offset? offset, double? width, double? opacity}) {
    return FloatPosition(
      offset: offset ?? this.offset,
      width: width ?? this.width,
      opacity: opacity ?? this.opacity,
    );
  }
}

class _FloatingPreview extends StatelessWidget {
  final FigmaService service;
  final FigmaLink link;
  final void Function() onRemove;
  final FloatPosition position;
  final void Function(FloatPosition) onMove;

  const _FloatingPreview(
    this.service,
    this.link,
    this.position, {
    super.key,
    required this.onRemove,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: position.offset.dy,
      left: position.offset.dx,
      child: SizedBox(
        width: position.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.9),
                border: Border.all(color: figmaBorderColor, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  _IconButton(
                    Icon(Icons.clear),
                    onPressed: onRemove,
                    tooltip: 'Close floating mode',
                  ),
                  Expanded(
                    child: _dragHandle(
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          _OpacityButton(
                            value: position.opacity,
                            onChanged: (v) {
                              onMove(position.copyWith(opacity: v));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  _scaleHandle(),
                ],
              ),
            ),
            _dragHandle(
              Opacity(
                opacity: position.opacity,
                child: FigmaImage(service, link),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dragHandle(Widget child) {
    return Listener(
      onPointerMove: (v) {
        onMove(position.copyWith(offset: position.offset + v.delta));
      },
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }

  Widget _scaleHandle() {
    return Listener(
      onPointerMove: (v) {
        onMove(position.copyWith(width: max(position.width + v.delta.dx, 100)));
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRight,
        child: Icon(Icons.start),
      ),
    );
  }
}

class _OpacityButton extends StatelessWidget {
  final double value;
  final void Function(double) onChanged;

  const _OpacityButton({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ToolbarPanel(
      button: Icon(Icons.opacity),
      panelFollowerAnchor: Alignment.topCenter,
      buttonBuilder:
          ({required VoidCallback onPressed, required Widget button}) {
            return _IconButton(
              button,
              onPressed: onPressed,
              tooltip: 'Opacity',
            );
          },
      panel: SizedBox(
        width: 200,
        height: 40,
        child: Slider(value: value, onChanged: onChanged),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  final void Function()? onPressed;
  final Widget icon;
  final String? tooltip;

  const _IconButton(this.icon, {required this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconThemeData(size: 16),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: BoxConstraints(),
        padding: EdgeInsets.all(4),
        icon: icon,
      ),
    );
  }
}
