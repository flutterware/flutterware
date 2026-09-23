import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// The picker's interaction grammar, in one place: sweep to preview, click to
/// commit, esc to leave, **one pick per arming** — staying armed would make
/// the next click anywhere also a pick, which is how you end up fighting the
/// tool to press a button in your own demo.
///
/// Extracted from the catalog's picker and the step page's, which had grown
/// the same ~40 lines apart. What differs between hosts is knowledge, not
/// grammar, so that is what the callbacks carry: how a point becomes a
/// highlight ([onSweep]) and how a click becomes a selection ([onPick]) — the
/// catalog commits through the guest's real hit test, a snapshot through its
/// rectangles. The run cockpit gets a picker for free the day it has rects.
///
/// Mount this only while armed; the host owns the mode and what the surface
/// does when it is off (the catalog hands input to the demo, a snapshot goes
/// inert).
class InspectPickRegion extends StatelessWidget {
  const InspectPickRegion({
    super.key,
    required this.onSweep,
    required this.onClear,
    required this.onPick,
    required this.onDisarm,
    required this.child,
  });

  /// The pointer is at this point, in the child's own coordinates — the
  /// host updates its highlight, usually via `InspectTree.nodeAtPoint`.
  final void Function(Offset point) onSweep;

  /// Put the light out: the pointer left, or the mode ended. A highlight that
  /// outlived the hover would be pointing at nothing.
  final VoidCallback onClear;

  /// A click, same coordinates: commit. Judging a miss is the host's — a
  /// click on the margin is a miss, not a selection to clear — and so is
  /// asynchrony, when the commit asks a live guest.
  final void Function(Offset point) onPick;

  /// Leave picking mode. Called on esc and after every pick; the host owns
  /// the flag this flips.
  final VoidCallback onDisarm;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Its own focus, so esc works without hunting for the button again — a
    // mode you can only leave by finding the button is a trap. (The demo's
    // focus is not mounted while picking, so there is nothing to steal.)
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        onDisarm();
        onClear();
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        onHover: (event) => onSweep(event.localPosition),
        onExit: (_) => onClear(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (event) {
            onPick(event.localPosition);
            // One pick per arming, as Chrome does — disarmed here rather
            // than by the host so an async commit cannot leave the mode
            // hanging armed while it waits.
            onDisarm();
            onClear();
          },
          child: child,
        ),
      ),
    );
  }
}
