import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';

import '../drive/human_actions.dart' show describeHit;
import '../server/vm_transport.dart' show GuestChannels;
import 'step_http.dart';
import 'step_names.dart';

export 'step_names.dart' show worldStepKey;

/// A world guest's steps. Each gesture on the app — a person's or an agent's,
/// both arrive through the binding — is one step with an id of its own,
/// `ben.3`, and what its callbacks start runs in a zone naming it. Every HTTP
/// request the app opens carries the id in [worldStepHeader], so a server
/// whose adapter reads it can say which tap each of its events came from,
/// and the world can join the two.
///
/// A request started outside the tap's callbacks — a fetch a rebuild began, a
/// sync engine's upload loop — is given the last step instead, while that
/// ended under [window] ago. Each request says which way it joined.
///
/// The one thing an app can undo: setting `HttpOverrides.global` itself
/// replaces this, and its requests go unstamped.
class WorldSteps {
  WorldSteps({
    required String person,
    this.window = const Duration(milliseconds: 1500),
    this.startWindow = worldStartWindow,
    void Function(String channel, Map<String, Object?> payload)? report,
  }) : _prefix = worldStepPrefix(person),
       _report = report ?? _toChannels;

  /// How long after a step ends a request with no step of its own still
  /// belongs to it.
  final Duration window;

  /// How long after [install] a request with no step belongs to the app's
  /// start, `ana.0`, while nobody has touched the app yet.
  final Duration startWindow;

  final String _prefix;
  final void Function(String channel, Map<String, Object?> payload) _report;
  var _count = 0;
  _Gesture? _gesture;
  String? _last;
  DateTime? _lastAt;
  DateTime? _started;

  /// Stamps every request the app opens from now on, and opens the app's
  /// start as its first step, `ana.0`: what it sends before anyone touches
  /// it — its config, the user it resumes, its sync streams — belongs to
  /// that step, for [startWindow] or until the first gesture.
  void install() {
    HttpOverrides.global = StepStamping(stepFor, onStamped: _stamped);
    _started = DateTime.now();
    _report(worldStepsChannel, {
      'step': '$_prefix.0',
      'verb': 'start',
      'target': 'the app',
    });
  }

  /// Dispatches [event] through [next] — the binding's own
  /// `handlePointerEvent` — inside its gesture's step.
  ///
  /// A gesture is every pointer from the first down to the last up, so a
  /// second finger belongs to the step the first began.
  void dispatch(PointerEvent event, void Function(PointerEvent event) next) {
    if (event is PointerDownEvent) {
      (_gesture ??= _Gesture(
        '$_prefix.${++_count}',
        event,
      )).down.add(event.pointer);
    }
    var gesture = _gesture;
    if (gesture == null) return next(event);
    runZoned(() => next(event), zoneValues: {worldStepKey: gesture.id});
    if (event is PointerMoveEvent &&
        (event.position - gesture.first.position).distance > kTouchSlop) {
      gesture.moved = true;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      gesture.down.remove(event.pointer);
      if (gesture.down.isNotEmpty) return;
      _gesture = null;
      _last = gesture.id;
      _lastAt = DateTime.now();
      var held = event.timeStamp - gesture.first.timeStamp;
      _report(worldStepsChannel, {
        'step': gesture.id,
        'verb': gesture.moved
            ? 'drag'
            : held >= kLongPressTimeout
            ? 'longPress'
            : 'tap',
        'target': describeHit(
          gesture.first.position,
          viewId: gesture.first.viewId,
        ),
      });
    }
  }

  /// A step the world takes on this person's behalf — a code typed from an
  /// SMS, a link opened from a mail — named as a tap's is, `ana.4`. [body]
  /// runs inside it, and what the app starts after it, within [window],
  /// joins it: a link reaches the app through the plugin's own stream, on
  /// no step of ours.
  ///
  /// [verb] is what it did, `type` or `open`; [target] what to, as the
  /// trace says it: `the code from SMS`. [body] is given the step's id.
  T deliver<T>(String verb, String target, T Function(String step) body) {
    var id = '$_prefix.${++_count}';
    _report(worldStepsChannel, {'step': id, 'verb': verb, 'target': target});
    _last = id;
    _lastAt = DateTime.now();
    try {
      return runZoned(() => body(id), zoneValues: {worldStepKey: id});
    } finally {
      _lastAt = DateTime.now();
    }
  }

  /// The step a request opened now belongs to, and how it was found.
  (String step, String how)? stepFor() {
    if (Zone.current[worldStepKey] case String step) return (step, 'zone');
    var at = _lastAt;
    if (_last case var step? when at != null) {
      if (DateTime.now().difference(at) < window) return (step, 'window');
      return null;
    }
    if (_started case var started?
        when DateTime.now().difference(started) < startWindow) {
      return ('$_prefix.0', 'window');
    }
    return null;
  }

  void _stamped(String step, String how, String method, Uri url) =>
      _report(worldRequestsChannel, {
        'step': step,
        'method': method,
        'url': '${url.host}:${url.port}${url.path}',
        'how': how,
      });

  static void _toChannels(String channel, Map<String, Object?> payload) =>
      GuestChannels.core.addEvent(channel, payload);
}

class _Gesture {
  _Gesture(this.id, this.first);

  final String id;
  final PointerDownEvent first;
  final down = <int>{};
  var moved = false;
}
