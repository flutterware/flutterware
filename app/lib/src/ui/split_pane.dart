import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../inspect/inspect_dock.dart';

/// A list beside its detail, with a draggable rule between them.
///
/// The shape three request-shaped lists now share — the server panel's
/// Requests and SQL tabs, and the run cockpit's Network tab. Each of them had
/// its own `SizedBox(width: 380)` and a `VerticalDivider`, which is fine for
/// `GET /users` and much too narrow for a `select … where … order by …`.
/// [InspectSplitGrip] is what three other panes already use to answer that.
///
/// The width is remembered by the widget, not by the host: it is a thing about
/// this window right now, like the dock's height, and a host that persisted it
/// would be persisting a preference nobody set.
class FwSplitPane extends StatefulWidget {
  const FwSplitPane({
    super.key,
    required this.list,
    required this.detail,
    this.initialWidth = 380,
    this.minWidth = 280,
  });

  final Widget list;
  final Widget detail;
  final double initialWidth;
  final double minWidth;

  @override
  State<FwSplitPane> createState() => _FwSplitPaneState();
}

class _FwSplitPaneState extends State<FwSplitPane> {
  late double _width = widget.initialWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Clamped on the way out as well as on the drag: the window can be
        // narrowed after the list was dragged wide, and that resize goes
        // nowhere near the grip.
        var ceiling = math.max(widget.minWidth, constraints.maxWidth * 0.6);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _width.clamp(widget.minWidth, ceiling),
              child: widget.list,
            ),
            InspectSplitGrip(
              axis: Axis.vertical,
              onDrag: (delta) => setState(() {
                _width = (_width + delta).clamp(widget.minWidth, ceiling);
              }),
            ),
            Expanded(child: widget.detail),
          ],
        );
      },
    );
  }
}
