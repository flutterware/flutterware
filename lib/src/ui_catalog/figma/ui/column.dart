import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../link.dart';
import '../service.dart';
import 'add_link_button.dart';
import 'colors.dart';
import 'floating.dart';
import 'image.dart';

final _radius = Radius.circular(10);
final _borderRadius = BorderRadius.only(topLeft: _radius, bottomLeft: _radius);

class FigmaPreviewer extends StatefulWidget {
  final FigmaService service;
  final Widget child;
  final void Function()? onOpenSettings;
  final void Function(String)? onAddLink;
  final void Function(FigmaLink) onLinkSettings;
  final List<FigmaLink> figmaLinks;
  final Widget clipboardButton;
  final double Function() floatDefaultWidth;

  const FigmaPreviewer(
    this.service, {
    super.key,
    required this.child,
    required this.onOpenSettings,
    required this.figmaLinks,
    required this.onAddLink,
    required this.onLinkSettings,
    required this.clipboardButton,
    required this.floatDefaultWidth,
  });

  @override
  State<FigmaPreviewer> createState() => _FigmaPreviewerState();
}

class _FigmaPreviewerState extends State<FigmaPreviewer> {
  late bool _isCollapsed = widget.figmaLinks.isEmpty;
  final _floatingLinks = <FigmaLink, FloatPosition>{};
  double _width = 200;

  @override
  Widget build(BuildContext context) {
    var child = DragTarget<FigmaLink>(
      builder:
          (
            context,
            List<FigmaLink?> candidateData,
            List<dynamic> rejectedData,
          ) {
            return FloatingStack(
              widget.service,
              floatingLinks: _floatingLinks,
              onRemove: (v) {
                setState(() {
                  _floatingLinks.remove(v);
                });
              },
              onMove: (link, position) {
                setState(() {
                  _floatingLinks[link] = position;
                });
              },
              child: widget.child,
            );
          },
      onAcceptWithDetails: (d) {
        var localOffset = (context.findRenderObject()! as RenderBox)
            .globalToLocal(d.offset);
        setState(() {
          _floatingLinks[d.data] = FloatPosition(
            offset: localOffset + Offset(10, -15),
            width: widget.floatDefaultWidth(),
            opacity: 0.5,
          );
        });
      },
    );

    var header = _Header(
      onToggle: () {
        setState(() {
          _isCollapsed = !_isCollapsed;
        });
      },
      isCollapsed: _isCollapsed,
      count: widget.figmaLinks.length,
    );

    if (_isCollapsed) {
      return Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            top: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Material(
                  borderRadius: _borderRadius,
                  color: figmaBackgroundColor,
                  elevation: 2,
                  clipBehavior: Clip.antiAliasWithSaveLayer,
                  child: header,
                ),
                widget.clipboardButton,
              ],
            ),
          ),
        ],
      );
    } else {
      var borderSide = BorderSide(color: figmaBorderColor, width: 1);

      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: child),
          _dragHandle(
            SizedBox(
              width: _width,
              child: Container(
                decoration: BoxDecoration(
                  color: figmaBackgroundColor,
                  border: Border(left: borderSide, bottom: borderSide),
                  borderRadius: _borderRadius,
                ),
                clipBehavior: Clip.antiAliasWithSaveLayer,
                child: Column(
                  children: [
                    header,
                    Expanded(
                      child: ListView(
                        children: [
                          for (var link in widget.figmaLinks)
                            _DockedPreview(
                              link,
                              this,
                              isFloating: _floatingLinks.containsKey(link),
                              onSettings: () => widget.onLinkSettings(link),
                              onToggleFloat: () {
                                setState(() {
                                  if (_floatingLinks.containsKey(link)) {
                                    _floatingLinks.remove(link);
                                  } else {
                                    _floatingLinks[link] = FloatPosition(
                                      offset: Offset.zero,
                                      width: widget.floatDefaultWidth(),
                                      opacity: 0.5,
                                    );
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                    widget.clipboardButton,
                    Row(
                      children: [
                        if (widget.onAddLink case var onAddLink?)
                          AddLinkButton(
                            onSubmit: onAddLink,
                            clipboardWatcher:
                                widget.service.clipboardWatcher.proposedLink,
                          ),
                        Expanded(child: const SizedBox()),
                        IconButton(
                          onPressed: widget.onOpenSettings,
                          icon: Icon(Icons.settings),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
  }

  Widget _dragHandle(Widget child) {
    return Stack(
      children: [
        child,
        Align(
          alignment: Alignment.centerLeft,
          child: Listener(
            onPointerMove: (v) {
              setState(() {
                _width -= v.delta.dx;
                _width = min(max(_width, 150), 600);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.black54),
                ),
                height: 30,
                width: 8,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final void Function() onToggle;
  final bool isCollapsed;
  final int count;

  const _Header({
    required this.onToggle,
    required this.isCollapsed,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: isCollapsed ? onToggle : null,
      child: Container(
        color: figmaBorderColor,
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: Row(
            children: [
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.all(4),
                child: Image.asset(
                  'assets/figma_logo.png',
                  height: 25,
                  package: 'flutterware',
                ),
              ),
              if (!isCollapsed)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text('Figma'),
                ),
              Container(
                decoration: BoxDecoration(
                  color: Colors.greenAccent,
                  shape: BoxShape.circle,
                ),
                width: 15,
                alignment: Alignment.center,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.black, fontSize: 11),
                ),
              ),
              if (!isCollapsed) Expanded(child: const SizedBox()),
              if (!isCollapsed)
                IconButton(
                  onPressed: onToggle,
                  icon: Transform.rotate(
                    angle: pi / 2,
                    child: Icon(
                      isCollapsed ? Icons.unfold_less : Icons.unfold_more,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockedPreview extends StatelessWidget {
  final FigmaLink link;
  final _FigmaPreviewerState parent;
  final void Function() onToggleFloat;
  final void Function() onSettings;
  final bool isFloating;

  const _DockedPreview(
    this.link,
    this.parent, {
    required this.onToggleFloat,
    required this.onSettings,
    required this.isFloating,
  });

  @override
  Widget build(BuildContext context) {
    var widget = Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black),
        color: Colors.white,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          FigmaImage(parent.widget.service, link),
          Wrap(
            children: [
              _IconButton(
                Icons.open_with,
                onPressed: onToggleFloat,
                color: isFloating ? Colors.greenAccent : null,
                tooltip: isFloating
                    ? 'Remove floating preview'
                    : 'Floating mode',
              ),
              _IconButton(
                Icons.settings,
                onPressed: onSettings,
                tooltip: 'More options',
              ),
            ],
          ),
        ],
      ),
    );
    return Draggable<FigmaLink>(
      data: link,
      feedback: SizedBox(
        width: 200,
        child: Opacity(opacity: 0.5, child: widget),
      ),
      childWhenDragging: Opacity(opacity: 0.5, child: widget),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: widget),
    );
  }
}

class _IconButton extends StatelessWidget {
  final void Function()? onPressed;
  final IconData icon;
  final String? tooltip;
  final Color? color;

  const _IconButton(
    this.icon, {
    required this.onPressed,
    this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: BoxConstraints(),
      padding: EdgeInsets.all(4),
      icon: Icon(icon, size: 14, color: color),
    );
  }
}
