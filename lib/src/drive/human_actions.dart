import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart' show Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'resolve.dart' show visibleTextCap;

/// What a burst-end capture produced: the picture of the settled screen and
/// the texts on it.
///
/// Deliberately not a tree. A beat that carried one would pay the inspect
/// walk — measured at 47ms on the UI thread for a 34k-element screen, fired
/// in the instant after the user's finger lifts, which is exactly when they
/// are watching for the app to respond. `texts` is the same question answered
/// 15x cheaper, because a predicate walk filters where the tree builds an
/// object per node. See `2026-08-24-human-beats-design.md` § Measured.
class HumanCapture {
  HumanCapture({required this.picture, required this.texts});

  /// The wire shape `_screenshot` already returns — `width`, `height`,
  /// `pixelRatio`, `base64`. Null when the capture could not be taken.
  final Map<String, Object?>? picture;

  final List<String> texts;

  /// What this costs the ring. The base64 is the whole of it in practice —
  /// measured at ~107KB for a real screen, against the ~12KB a flat list of
  /// rows encodes to, so the budget is counted rather than assumed.
  late final int bytes = switch (picture?['base64']) {
    String base64 => base64.length,
    _ => 0,
  };
}

/// One human gesture the guest saw between two tool steps.
class HumanAction {
  HumanAction({required this.at, required this.verb, required this.target});

  final DateTime at;

  /// `tap` or `longPress` — the two gestures a down-up pair within slop can
  /// be. Scrolls and drags are deliberately not recorded: a fling is a dozen
  /// pointer sequences and none of them is a decision worth journaling.
  final String verb;

  /// The nearest nameable widget under the finger, in the same spelling the
  /// drive targets use — `"Pay"`, `key 'shop.next'` — or the bare position
  /// when nothing named was hit.
  final String target;

  /// The picture and texts of the screen this gesture produced, once the
  /// burst it belongs to has closed and the capture has landed.
  ///
  /// Mutable, and the only mutable thing here, because a beat is written in
  /// two moments: the gesture is known the instant the finger lifts, and what
  /// it did to the screen is not known until the screen has settled. Null
  /// forever for every gesture that is not the last of its burst, and for one
  /// that is if the capture was abandoned — which is not a failure, it is the
  /// designed fallback to the entry this class already wrote.
  HumanCapture? capture;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'verb': verb,
    'target': target,
    if (capture case var capture?) ...{
      'screenshot': ?capture.picture,
      'texts': capture.texts,
    },
  };
}

/// Records the human's taps in the driven app, so the journal can carry
/// `actor: human` entries between the tool steps.
///
/// The co-driving premise made the journal one-eyed: every agent step lands
/// with its picture, but what the human did between them was invisible — the
/// agent only saw that the screen had moved. This is the mechanism the design
/// noted as known and cheap: a global pointer route, a hit test on pointer-up,
/// the nearest nameable widget as the target.
///
/// Pull, like everything else on this wire: actions buffer here and ride the
/// next act/observe reply as a since-last-step delta. Nothing pushes.
class HumanActions {
  HumanActions({
    this.cap = 100,
    this.pictureBytes = 8 * 1024 * 1024,
    this.burstWindow = kDoubleTapTimeout,
    this.capture,
  });

  /// Buffered actions past this are counted but not kept — the take reports
  /// how many were dropped rather than discarding them silently.
  final int cap;

  /// How many bytes of pictures the ring may hold before the oldest are let
  /// go. The gestures themselves are never dropped for this — a beat over
  /// budget degrades to the entry it would have been without a picture, which
  /// is the same fallback an abandoned capture takes.
  ///
  /// Pictures are the only thing here with a size worth counting: an action is
  /// three short strings, a picture is ~107KB.
  final int pictureBytes;

  /// How long after a tap the recorder waits for another before it decides the
  /// burst is over and takes one picture.
  ///
  /// [kDoubleTapTimeout] because the framework has already decided that is how
  /// long two taps may be apart and still belong together, and a beat wants
  /// exactly that grouping: one picture per burst, attached to its last
  /// gesture, rather than five near-identical mid-flight frames.
  final Duration burstWindow;

  /// Takes the picture and texts of the settled screen. Supplied by the guest,
  /// which is what owns the render view and the act queue; null in a test that
  /// only cares about the gestures.
  ///
  /// Runs on the guest's own queue, so it never overlaps an agent's gesture —
  /// two calls against a live app are two moments, and the gap between them is
  /// where the wrong screen gets attached to the right tap.
  ///
  /// Settable as well as constructable because the guest wiring is a cycle:
  /// `GuestDrive` takes the recorder and the recorder needs the guest's queue
  /// and render view. The guest sets it on itself at construction.
  Future<HumanCapture?> Function()? capture;

  final _records = <HumanAction>[];
  var _dropped = 0;
  var _installed = false;
  final _downs = <int, PointerDownEvent>{};
  Timer? _burst;

  /// Bumped by every recorded gesture. A capture reads it when its burst
  /// closes and again when it lands: a change between the two means a newer
  /// gesture arrived while the picture was being taken, so the picture is of a
  /// screen that gesture has already moved on from.
  var _sequence = 0;

  /// True while a drive verb is injecting pointer events, which arrive on the
  /// same global route as real ones. Without this, every agent tap would be
  /// journaled twice — once as its step, once as a phantom human.
  var suppress = false;

  /// Adds the global route. Call once, with the binding initialized.
  void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(handlePointerEvent);
  }

  /// The route itself — public so a test can feed events without a binding
  /// route registration of its own.
  void handlePointerEvent(PointerEvent event) {
    if (suppress) return;
    switch (event) {
      case PointerDownEvent():
        _downs[event.pointer] = event;
      case PointerUpEvent():
        var down = _downs.remove(event.pointer);
        if (down == null) return;
        if ((event.position - down.position).distance > kTouchSlop) return;
        var held = event.timeStamp - down.timeStamp;
        _add(
          HumanAction(
            at: DateTime.now(),
            verb: held >= kLongPressTimeout ? 'longPress' : 'tap',
            target: describeHit(down.position, viewId: down.viewId),
          ),
        );
      case PointerCancelEvent():
        _downs.remove(event.pointer);
    }
  }

  void _add(HumanAction action) {
    if (_records.length >= cap) {
      _dropped++;
      return;
    }
    _records.add(action);
    _sequence++;
    if (capture == null) return;
    _burst?.cancel();
    _burst = Timer(burstWindow, () => unawaited(_closeBurst(action)));
  }

  /// One picture, once the taps have stopped, attached to the gesture that
  /// ended the burst.
  Future<void> _closeBurst(HumanAction last) async {
    var seq = _sequence;
    HumanCapture? taken;
    try {
      taken = await capture!();
    } catch (_) {
      // Housekeeping: a capture that throws costs this beat its picture and
      // nothing else. The gesture is already recorded.
      return;
    }
    if (taken == null) return;
    // Abandoned rather than misattributed: another gesture landed while the
    // picture was being taken, so this frame is not what [last] produced, and
    // a newer burst is already pending to photograph what is.
    if (_sequence != seq) return;
    // Taken by the host while the picture was in flight — there is nothing
    // left here to attach it to.
    if (!_records.contains(last)) return;
    last.capture = taken;
    _evictPictures();
  }

  /// Lets go of the oldest pictures until the ring is inside [pictureBytes].
  /// The gestures stay; only what they are carrying is dropped.
  void _evictPictures() {
    var total = 0;
    for (var record in _records) {
      total += record.capture?.bytes ?? 0;
    }
    for (var record in _records) {
      if (total <= pictureBytes) return;
      if (record.capture case var capture?) {
        total -= capture.bytes;
        record.capture = null;
      }
    }
  }

  /// Stops the pending burst. A guest that is going away calls this; a test
  /// calls it so a timer does not outlive the binding it fires against.
  void dispose() {
    _burst?.cancel();
    _burst = null;
  }

  /// Everything recorded since the last take, oldest first, cleared on the
  /// way out. A drop past [cap] becomes a visible final entry, per the
  /// stated-caps rule.
  List<Map<String, Object?>> take() {
    var out = [for (var record in _records) record.toJson()];
    // The burst's capture has nothing to attach to once the records are gone,
    // and a picture taken for a gesture the host already has is a picture
    // nobody will ever see.
    _burst?.cancel();
    _burst = null;
    if (_dropped > 0) {
      out.add(
        HumanAction(
          at: DateTime.now(),
          verb: 'dropped',
          target: '$_dropped more past the $cap-action cap',
        ).toJson(),
      );
    }
    _records.clear();
    _dropped = 0;
    return out;
  }
}

/// Names what a pointer at [position] would land on: hit test, then walk from
/// the leaf element upward for the first widget a drive target could spell —
/// visible text, a string key, a tooltip, a semantics label.
String describeHit(Offset position, {int? viewId}) =>
    nameHit(position, viewId: viewId) ?? _at(position);

/// [describeHit] when the walk found a name, null when it did not — for a
/// caller with a better fallback sentence than the bare position.
String? nameHit(Offset position, {int? viewId}) {
  var binding = WidgetsBinding.instance;
  var view = viewId != null
      ? binding.renderViews
            .where((v) => v.flutterView.viewId == viewId)
            .firstOrNull
      : binding.renderViews.firstOrNull;
  if (view == null) return null;
  var result = HitTestResult();
  binding.hitTestInView(result, position, view.flutterView.viewId);
  for (var entry in result.path) {
    var target = entry.target;
    if (target is! RenderObject) continue;
    if (target.debugCreator case DebugCreator(:var element)) {
      var name = _nameFrom(element);
      if (name != null) return name;
    }
    // Only the leaf-most render object's element is walked: it already
    // visits every ancestor, and later path entries are those ancestors.
    break;
  }
  return null;
}

String _at(Offset position) =>
    'at (${position.dx.round()}, ${position.dy.round()})';

String? _nameFrom(Element leaf) {
  String? name;
  var hops = 0;
  bool visit(Element element) {
    // Deep enough for a Material control's internals (an IconButton is ~40
    // elements of ripple and style between its RenderParagraph and its key),
    // shallow enough not to name the page for a tap on its background.
    if (++hops > 100) return false;
    switch (element.widget) {
      case Text(:var data, :var textSpan):
        name = '"${_cap(data ?? textSpan?.toPlainText() ?? '')}"';
        return false;
      case Tooltip(:var message?):
        name = "tooltip '$message'";
        return false;
      case Semantics(properties: SemanticsProperties(:var label?))
          when label.isNotEmpty:
        name = "label '${_cap(label)}'";
        return false;
      case Widget(key: ValueKey<String>(:var value)):
        name = "key '$value'";
        return false;
    }
    return true;
  }

  if (visit(leaf)) leaf.visitAncestorElements(visit);
  return name;
}

String _cap(String text) => text.length <= visibleTextCap
    ? text
    : '${text.substring(0, visibleTextCap)}…';
