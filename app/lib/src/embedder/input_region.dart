import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'embedded_engine.dart';
import 'protocol.dart';

/// Everything a guest needs to be driven: keys, hover, pointers, scrolling and
/// trackpad gestures.
///
/// Coordinates and deltas are scaled because the wire speaks physical pixels:
/// the guest divides by its own ratio, so a wheel tick scrolls the same logical
/// distance whether the guest fills the panel or is staged as a phone.
///
/// The ratio is read from the engine at event time, not passed in at build.
/// It is the engine that was told what to render at, so it is the only value
/// that cannot disagree with what the guest is actually doing — and it moves
/// without this widget rebuilding, because magnifying the stage changes the
/// ratio and nothing else. Passed in, it goes stale the moment a zoom settles,
/// and a stale ratio does not fail loudly: every click simply lands somewhere
/// other than where it was aimed.
class EmbedderInputRegion extends StatelessWidget {
  const EmbedderInputRegion({
    super.key,
    required this.engine,
    required this.focusNode,
    this.touch = false,
    this.shouldIgnoreKey,
    this.shouldIgnorePointer,
    required this.child,
  });

  final EmbeddedEngine engine;
  final FocusNode focusNode;

  /// Whether the guest is being touched rather than clicked — a phone or a
  /// tablet, where the mouse driving it is standing in for a finger.
  ///
  /// The mouse then stops existing, deliberately rather than as a side
  /// effect: no add, no hover, no exit, so a demo staged as a phone shows no
  /// hover states, because a phone has none. What survives is the wheel, sent
  /// as it always was — a phone has no wheel, but the human driving one has no
  /// finger to drag with either, and a preview you cannot scroll is worse than
  /// a preview scrolled by a device that is not there.
  ///
  /// A trackpad's two-finger pan is untouched for the same reason and arrives
  /// as itself; the guest's scrollables read it on every platform.
  final bool touch;

  /// Keys the host keeps for itself — chords a surrounding
  /// `CallbackShortcuts` should claim. Returning true answers `ignored`, not
  /// `handled`, so the event carries on up to whichever binding wants it.
  final bool Function(KeyEvent event)? shouldIgnoreKey;

  /// Pointer events the host keeps for itself — a scroll or a pinch that means
  /// the stage, or a drag that is moving it.
  ///
  /// Only the *forwarding* stops. A `Listener` above this one is in the same
  /// hit-test path and receives the event whatever this answers — and, being a
  /// listener rather than a recognizer, it never loses a gesture arena either.
  /// So the host does not need a way to claim anything; it needs a way to stop
  /// the demo acting on a gesture aimed over its head. Everything not claimed
  /// still arrives, which is what keeps a magnified preview a preview you can
  /// still click, type into and scroll.
  final bool Function(PointerEvent event)? shouldIgnorePointer;

  final Widget child;

  bool _ignores(PointerEvent event) =>
      shouldIgnorePointer?.call(event) ?? false;

  /// The trackpad swipes each guest was sent the start of, and is owed the
  /// end of. Kept beside the engine rather than in this widget, which is
  /// rebuilt — and can be replaced — while a swipe is under way.
  static final _panZooms = Expando<Set<int>>('pan-zooms open in the guest');

  /// [PointerPanZoomUpdateEvent.pan] in this region's space, as a distance.
  ///
  /// Not the event's own `localPan`, which transforms the pan as though it
  /// were a point — the region's offset in the window included — and turns a
  /// 40px swipe into a jump of thousands.
  static Offset _localPan(PointerPanZoomUpdateEvent event) {
    var transform = event.transform;
    if (transform == null) return event.pan;
    return PointerEvent.transformPosition(
          transform,
          event.position + event.pan,
        ) -
        event.localPosition;
  }

  /// One contact event, as whichever kind of pointer is driving the guest.
  void _contact(PointerPhase phase, PointerEvent event, {int buttons = 0}) =>
      engine.sendPointer(
        phaseKind: phase,
        x: event.localPosition.dx * engine.pixelRatio,
        y: event.localPosition.dy * engine.pixelRatio,
        buttons: buttons,
        touch: touch,
      );

  /// [child] with the mouse's own events forwarded, or [child] alone when the
  /// guest is being touched.
  Widget _hovered(Widget child) => touch
      ? child
      : MouseRegion(
          onEnter: (e) => _contact(PointerPhase.add, e),
          onHover: (e) => _contact(PointerPhase.hover, e),
          // Paired with the add: the guest is tracking a device that has left
          // the window, and a hover state left behind never lifts.
          onExit: (e) => _contact(PointerPhase.remove, e),
          child: child,
        );

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (shouldIgnoreKey?.call(event) ?? false) {
          return KeyEventResult.ignored;
        }
        engine.sendKey(
          kind: event is KeyDownEvent
              ? KeyEventKind.down
              : event is KeyRepeatEvent
              ? KeyEventKind.repeat
              : KeyEventKind.up,
          physicalKey: event.physicalKey.usbHidUsage,
          logicalKey: event.logicalKey.keyId,
          // The host's layout resolved this keystroke to text; the guest's
          // text input builds editing state from it and can get it nowhere
          // else. Null on ups and non-printing keys.
          character: event.character,
        );
        return KeyEventResult.handled;
      },
      // Hover is not a [Listener]'s business: with no button held the engine
      // sends `PointerHoverEvent`, which `onPointerMove` never sees. Without
      // this the demo is blind to the mouse unless you are dragging — no ink
      // highlight, no `MouseRegion`, no hover tooltip, every demo frozen in
      // its resting state.
      //
      // And on a phone that is exactly right: there is no mouse to be blind
      // to. See [touch].
      child: _hovered(
        Listener(
          onPointerDown: (e) {
            if (_ignores(e)) return;
            focusNode.requestFocus();
            // A finger comes into existence when it lands and stops existing
            // when it lifts, which is what a real touchscreen embedder sends
            // and what keeps the engine's own pointer bookkeeping honest — a
            // mouse, by contrast, was added when it entered the window.
            if (touch) _contact(PointerPhase.add, e);
            _contact(PointerPhase.down, e, buttons: 1);
          },
          onPointerMove: (e) =>
              _ignores(e) ? null : _contact(PointerPhase.move, e, buttons: 1),
          // Withheld like the moves, and for a reason that is easy to miss:
          // the demo has already had a `cancel` by the time the host is
          // claiming this gesture, and an `up` arriving after it is an up with
          // no down behind it.
          onPointerUp: (e) {
            if (_ignores(e)) return;
            _contact(PointerPhase.up, e);
            if (touch) _contact(PointerPhase.remove, e);
          },
          // A discrete wheel only — a trackpad's two-finger scroll has not
          // arrived here since Flutter 3.3; it is the pan-zoom sequence below.
          onPointerSignal: (e) {
            if (e is! PointerScrollEvent || _ignores(e)) return;
            engine.sendPointer(
              phaseKind: PointerPhase.hover,
              x: e.localPosition.dx * engine.pixelRatio,
              y: e.localPosition.dy * engine.pixelRatio,
              scrollDeltaX: e.scrollDelta.dx * engine.pixelRatio,
              scrollDeltaY: e.scrollDelta.dy * engine.pixelRatio,
            );
          },
          // A swipe the host keeps is not the guest's at all — not its start
          // and end with nothing between, which reads in the guest as a
          // gesture that began and gave up. So the start goes only when the
          // host leaves the swipe alone, and the end follows the start: one
          // taken over halfway, a pan turned into a pinch the stage zooms,
          // still gets its end, or the guest waits for it forever.
          onPointerPanZoomStart: (e) {
            if (_ignores(e)) return;
            (_panZooms[engine] ??= {}).add(e.pointer);
            engine.sendPointer(
              phaseKind: PointerPhase.panZoomStart,
              x: e.localPosition.dx * engine.pixelRatio,
              y: e.localPosition.dy * engine.pixelRatio,
            );
          },
          // Cumulative since the start event, not per-update deltas — the
          // embedder API's convention, and the framework's own events already
          // carry it that way.
          //
          // In the guest's own space, like the position: a phone drawn at a
          // third of its size under two fingers moves its content as far as
          // the fingers went on screen. The window's pan moved it a third as
          // far — a swipe too short to turn a page, and a fling too slow to
          // carry it.
          onPointerPanZoomUpdate: (e) {
            if (_ignores(e)) return;
            var pan = _localPan(e);
            engine.sendPointer(
              phaseKind: PointerPhase.panZoomUpdate,
              x: e.localPosition.dx * engine.pixelRatio,
              y: e.localPosition.dy * engine.pixelRatio,
              panX: pan.dx * engine.pixelRatio,
              panY: pan.dy * engine.pixelRatio,
              scale: e.scale,
              rotation: e.rotation,
            );
          },
          onPointerPanZoomEnd: (e) {
            if (!(_panZooms[engine]?.remove(e.pointer) ?? false)) return;
            engine.sendPointer(
              phaseKind: PointerPhase.panZoomEnd,
              x: e.localPosition.dx * engine.pixelRatio,
              y: e.localPosition.dy * engine.pixelRatio,
            );
          },
          child: child,
        ),
      ),
    );
  }
}
