import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one mouse a scenario has.
///
/// One, because a mouse is a *device* and the framework keeps a state per
/// device: `MouseTracker` answers what is hovered device by device, and
/// asserts that a device is only ever added after it was removed. A verb that
/// made a mouse of its own would either be a second one — two controls hovered
/// at once, and a picture lying about where the pointer is — or would add a
/// device the tracker already holds and trip that assert. So the film's
/// travel, `hover`, `secondaryTap` and `scroll` all move this one.
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
  /// there — a hover, so the app under it knows it is under the mouse.
  ///
  /// [over] names what it has arrived over, for whoever asks [hovering].
  Future<void> moveTo(Offset to, {String? over}) async {
    _hovering = over;
    if (!_present) {
      _present = true;
      await _tester.sendEventToBinding(_pointer.addPointer(location: to));
      return;
    }
    if (_pointer.location == to) return;
    await _tester.sendEventToBinding(_pointer.hover(to));
  }

  /// Moves to [at] and clicks there with [buttons] — the primary button
  /// unless it says otherwise.
  ///
  /// **A fresh pointer id for every press**, as an engine numbers them. A
  /// double-tap recognizer holds the gesture arena of the first press open
  /// until the second one arrives, and a second press on the *same* id would
  /// join that held arena rather than open its own — which asserts. The
  /// device stays the same, and the device is what hover follows.
  Future<void> click(
    Offset at, {
    int buttons = kPrimaryButton,
    String? over,
  }) async {
    await moveTo(at, over: over);
    _pointer = TestPointer(_nextPointer(), PointerDeviceKind.mouse, _device);
    await _tester.sendEventToBinding(_pointer.down(at, buttons: buttons));
    await _tester.sendEventToBinding(_pointer.up());
  }

  /// Moves to [at] and turns the wheel by [by] — a pointer *signal*, which the
  /// framework hit-tests to whatever is under the mouse.
  Future<void> scroll(Offset at, Offset by, {String? over}) async {
    await moveTo(at, over: over);
    await _tester.sendEventToBinding(_pointer.scroll(by));
  }

  /// Takes the mouse off the screen, so everything it was over gets its exit.
  /// Nothing at all when it is not there.
  Future<void> leave() async {
    if (!_present) return;
    _present = false;
    _hovering = null;
    await _tester.sendEventToBinding(_pointer.removePointer());
  }

  /// Pointer ids from a range `flutter_test`'s own counter, which starts at 1
  /// and counts one per gesture, does not reach in any suite.
  static int _nextPointer() => _pointerIds++;
  static var _pointerIds = 1 << 20;
}
