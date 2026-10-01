import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../devices.dart';

/// Whether a scenario staged on [device] points with a mouse rather than a
/// finger — a desktop does, and everything else, a run staged on nothing
/// included, is touched.
///
/// The one rule for both halves of a run: which pointer a verb presses with,
/// and whether the film draws an arrow or a fingertip. Kept in one place
/// because the two disagreeing is what a film looked like before it — a
/// cursor that hovered as a mouse and then pressed as a finger.
bool pointsWithMouse(Device? device) => device?.kind == DeviceKind.desktop;

/// The one mouse a scenario has.
///
/// One, because a mouse is a *device* and the framework keeps a state per
/// device: `MouseTracker` answers what is hovered device by device, and
/// asserts that a device is only ever added after it was removed. A verb that
/// made a mouse of its own would either be a second one — two controls hovered
/// at once, and a picture lying about where the pointer is — or would add a
/// device the tracker already holds and trip that assert. So the film's
/// travel, `hover`, `secondaryTap`, `scroll` and — on a desktop — every press
/// and drag move this one.
///
/// Its device id is not one `flutter_test` hands out. `createGesture(kind:
/// mouse)` numbers its mouse 1, so a scenario that drives `s.tester` with a
/// mouse of its own moves that one and never finds this one in its way.
class ScenarioMouse {
  ScenarioMouse._(this._tester, this._tracker);

  /// The mouse of the test [tester] is running, made on first use.
  ///
  /// Keyed to the binding's `MouseTracker`, which the test binding replaces
  /// between tests: a mouse never outlives the test that moved it, and every
  /// scenario starts with none on the screen.
  static ScenarioMouse of(WidgetTester tester) {
    var tracker = tester.binding.mouseTracker;
    if (_current case var mouse? when identical(mouse._tracker, tracker)) {
      return mouse;
    }
    return _current = ScenarioMouse._(tester, tracker);
  }

  static ScenarioMouse? _current;

  final WidgetTester _tester;
  final MouseTracker _tracker;

  static const _device = 1000;

  /// Where the mouse is, or null while it is off the screen.
  Offset? get at => _present ? _pointer.location : null;

  /// What the mouse is parked over, as the verb that put it there named it —
  /// null when it is off the screen, or when the last thing to move it named
  /// nothing: the film's travel between two verbs, say.
  String? get hovering => _hovering;
  String? _hovering;

  var _pointer = TestPointer(_nextPointer(), PointerDeviceKind.mouse, _device);
  var _present = false;

  /// Moves the mouse to [to], bringing it onto the screen first if it is not
  /// there — a hover while no button is down, and a drag while one is.
  ///
  /// [over] names what it has arrived over, for whoever asks [hovering].
  Future<void> moveTo(
    Offset to, {
    String? over,
    Duration timeStamp = Duration.zero,
  }) async {
    _hovering = over;
    if (!_present) {
      _present = true;
      await _send(_pointer.addPointer(location: to));
      return;
    }
    // Sent even where the mouse already is: a hand resting on a button down
    // keeps reporting, and those samples are what bring a velocity estimate
    // down before it lets go.
    await _send(
      _pointer.isDown
          ? _pointer.move(to, timeStamp: timeStamp)
          : _pointer.hover(to, timeStamp: timeStamp),
    );
  }

  /// Moves to [at] and presses [buttons] there — the primary button unless it
  /// says otherwise — and holds them until [up].
  ///
  /// **A fresh pointer id for every press**, as an engine numbers them. A
  /// double-tap recognizer holds the gesture arena of the first press open
  /// until the second one arrives, and a second press on the *same* id would
  /// join that held arena rather than open its own — which asserts. The
  /// device stays the same, and the device is what hover follows.
  Future<void> down(
    Offset at, {
    int buttons = kPrimaryButton,
    String? over,
  }) async {
    await moveTo(at, over: over);
    _pointer = TestPointer(_nextPointer(), PointerDeviceKind.mouse, _device);
    await _send(_pointer.down(at, buttons: buttons));
  }

  /// Lets go of what [down] pressed, where the mouse now is.
  Future<void> up({Duration timeStamp = Duration.zero}) =>
      _send(_pointer.up(timeStamp: timeStamp));

  /// Moves to [at] and clicks there with [buttons].
  Future<void> click(
    Offset at, {
    int buttons = kPrimaryButton,
    String? over,
  }) async {
    await down(at, buttons: buttons, over: over);
    await up();
  }

  /// Presses at [at] for as long as a long press takes, and lets go —
  /// `flutter_test`'s `longPressAt`, with this mouse.
  Future<void> longPress(Offset at, {String? over}) async {
    await down(at, over: over);
    await _tester.pump(kLongPressTimeout + kPressTimeout);
    await up();
  }

  /// Presses at [from], moves by [by] and lets go — `flutter_test`'s
  /// `dragFrom`, with this mouse.
  ///
  /// The move is cut where it leaves the drag slop, as `dragFrom` cuts it:
  /// a recognizer that starts its drag where the slop was crossed consumes
  /// the move that crossed it, and one move of the whole distance would
  /// leave it no update at all.
  Future<void> drag(Offset from, Offset by, {String? over}) async {
    await down(from, over: over);
    var cuts = {
      if (by.dx.abs() > kDragSlopDefault) kDragSlopDefault / by.dx.abs(),
      if (by.dy.abs() > kDragSlopDefault) kDragSlopDefault / by.dy.abs(),
      1.0,
    }.toList()..sort();
    for (var t in cuts) {
      await moveTo(from + by * t);
    }
    await up();
  }

  /// [drag] spread over [duration], moving at [frequency] — `flutter_test`'s
  /// `timedDragFrom`, with this mouse. The clock moves between the moves and
  /// every move carries its time, which is what a velocity is read from.
  Future<void> timedDrag(
    Offset from,
    Offset by,
    Duration duration, {
    double frequency = 60,
    String? over,
  }) async {
    var intervals = math.max(1, duration.inMicroseconds * frequency ~/ 1e6);
    await down(from, over: over);
    var elapsed = Duration.zero;
    for (var i = 0; i <= intervals; i++) {
      var at = duration * i ~/ intervals;
      await _tester.binding.delayed(at - elapsed);
      elapsed = at;
      await moveTo(from + by * (i / intervals), timeStamp: at);
    }
    await up(timeStamp: duration);
  }

  /// Moves to [at] and turns the wheel by [by] — a pointer *signal*, which the
  /// framework hit-tests to whatever is under the mouse.
  Future<void> scroll(Offset at, Offset by, {String? over}) async {
    await moveTo(at, over: over);
    await _send(_pointer.scroll(by));
  }

  /// Takes the mouse off the screen, so everything it was over gets its exit.
  /// Nothing at all when it is not there.
  Future<void> leave() async {
    if (!_present) return;
    _present = false;
    _hovering = null;
    await _send(_pointer.removePointer());
  }

  Future<void> _send(PointerEvent event) => _tester.sendEventToBinding(event);

  /// Pointer ids from a range `flutter_test`'s own counter, which starts at 1
  /// and counts one per gesture, does not reach in any suite.
  static int _nextPointer() => _pointerIds++;
  static var _pointerIds = 1 << 20;
}
