import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../inspect/guest_errors.dart';
import '../inspect/guest_inspect.dart';
import '../inspect/guest_logs.dart';
import '../inspect/log.dart';
import '../offscreen_raster.dart';
import '../scenarios/target.dart';
import 'drive.dart';
import 'human_actions.dart';
import 'live_settle.dart';
import 'resolve.dart';

/// The guest half of the drive wire: one `ext.flutterware.act` extension,
/// every call a transaction — act, settle, observe — whose reply is the whole
/// bundle. There is deliberately no separate screenshot-then-tap pair to
/// correlate: two calls against a live app are two moments, and the gap
/// between them is where computer-use's bugs live.
///
/// Calls are serialized on a queue: two drivers interleave as transactions,
/// never as overlapping gestures.
class GuestDrive {
  GuestDrive({Drive? drive, this.inspector, this.humanActions})
    : drive = drive ?? Drive();

  /// Starts photographing human bursts — called on the first contact from
  /// anything that reads beats, never at startup.
  ///
  /// The gesture *list* is always recorded: a pointer route costs nothing and
  /// it is what fills the first reply's `human` field. The *capture* is a
  /// settle plus a `toImage` after every burst of taps — real frames forced
  /// in the user's app — and with no agent driving and no host polling,
  /// every picture it took would age out of the ring unseen. So the recorder
  /// runs cold until a consumer announces itself through `act` or `beats`,
  /// and arms for the rest of the app's life on the first call.
  void _armBeats() {
    humanActions?.capture ??= _captureBeat;
  }

  /// One beat's worth of observation, queued like any other transaction.
  ///
  /// Settles first, for the same reason every verb does: the picture wanted is
  /// the one the tap *produced*, not the frame that happened to be up when the
  /// finger left. No tree — see [HumanCapture].
  Future<HumanCapture?> _captureBeat() {
    var completer = Completer<HumanCapture?>();
    _queue = _queue.then((_) async {
      HumanCapture? result;
      try {
        if (_hasTree) {
          // The act-less transaction, exactly as an agent's `observe` is: it
          // settles and nothing else.
          await drive.observe();
          result = HumanCapture(
            picture: await _screenshot(maxSide: beatMaxSide),
            texts: drive.visibleTexts(),
          );
        }
      } catch (_) {
        // Nothing may escape this callback, exactly as in the extension: an
        // error left in [_queue] wedges every later call, and for a long-lived
        // app that is forever. A beat losing its picture is the cheap failure.
      }
      completer.complete(result);
    });
    return completer.future;
  }

  final Drive drive;

  /// Wired when the tree rides the bundle; without it `tree` is absent and
  /// everything else still works.
  final GuestInspector? inspector;

  /// Wired when the human's taps between tool steps should ride the bundle
  /// as `human` entries; without it the journal stays tool-steps-only.
  final HumanActions? humanActions;

  /// The `navigate` verb's registration point. A routing system — the app's
  /// own, or a package like router_outlet — sets this to jump straight to a
  /// screen; unset, `navigate` refuses loudly rather than tap-hunting.
  static void Function(String route)? navigator;

  /// What a beat's picture is capped at, against an agent step's 900. A beat
  /// is scanned in a timeline rather than read for fine print, and the cap
  /// scales the render, so it bounds the encode and the bytes together.
  static const beatMaxSide = 640;

  var _queue = Future<void>.value();
  var _logCursor = 0;
  var _errorCounts = <String, int>{};

  /// Registers the extension. Call once, before `runApp`.
  void registerExtensions() {
    developer.registerExtension('ext.flutterware.act', (method, params) {
      _armBeats();
      var completer = Completer<developer.ServiceExtensionResponse>();
      _queue = _queue.then((_) async {
        Object? result;
        try {
          result = await _dispatch(params);
        } catch (e, stack) {
          result = {'error': '$e', 'stack': '$stack'};
        }
        // Nothing may escape this callback: an error left in [_queue] would
        // wedge every later call, which for a long-lived app is forever.
        developer.ServiceExtensionResponse response;
        try {
          response = developer.ServiceExtensionResponse.result(
            jsonEncode(result),
          );
        } catch (e) {
          response = developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'observation was not encodable: $e'}),
          );
        }
        completer.complete(response);
      });
      return completer.future;
    });
    // Deliberately *not* on [_queue], and deliberately not an observation:
    // this hands over records the recorder already made and clears them. It
    // settles nothing, walks nothing and photographs nothing, so a host may
    // poll it on a timer without competing with a driver for the app.
    //
    // The pictures were taken when their bursts closed; this is the collection.
    developer.registerExtension('ext.flutterware.beats', (
      method,
      params,
    ) async {
      _armBeats();
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'human': humanActions?.take() ?? const []}),
      );
    });
  }

  /// Whether anything has been built yet.
  ///
  /// Null from the moment the binding exists until `runApp` mounts something —
  /// which is a window this extension is fully alive inside, because the
  /// generated wrapper installs the guest *around* the app's `main` rather
  /// than after it. An app whose `main` throws never leaves that window: the
  /// isolate lives, the VM service answers, `ext.flutterware.act` is
  /// registered, and every verb behind it walks a tree that is not there.
  static bool get _hasTree => WidgetsBinding.instance.rootElement != null;

  /// What to say instead of crashing in that window.
  ///
  /// It used to crash, and the crash was the worst possible one to read: the
  /// finder behind `observe` dereferences the root element, so the reply was
  /// `Null check operator used on a null value` — a sentence that names
  /// flutterware and sends whoever read it to debug the wrong program. Every
  /// surface said something wrong or internal about the one failure an agent
  /// is least able to diagnose. Reported by a consumer, who lost the time.
  static const _notStarted =
      'the app has not called runApp, so there is no widget tree to act on or '
      'observe. This is the app failing to start rather than flutterware '
      'failing to reach it — its `main` most likely threw before `runApp`, and '
      'the engine writes that reason to the launcher log where no daemon event '
      'carries it. `inspect {errors: true}` prints those lines.';

  /// One transaction, without the extension around it.
  ///
  /// [registerExtensions] is `dart:developer` and a VM service away from a
  /// widget test; the transaction is where the behaviour lives.
  @visibleForTesting
  Future<Map<String, Object?>> debugDispatch(Map<String, String> params) =>
      _dispatch(params);

  Future<Map<String, Object?>> _dispatch(Map<String, String> params) async {
    var settle = _durationOf(params, 'settleMs');
    var before = _beforeAct();
    // Refused before the verb, not inside it: with nothing mounted there is
    // no target to resolve and no screen to describe, so every verb fails the
    // same way and only one of them needs to say so. The observation still
    // rides along — the logs and the errors in it are the whole of what this
    // app has to say about itself.
    if (!_hasTree) {
      return {
        'error': _notStarted,
        'failure': 'notStarted',
        ...await _observe(params, before),
      };
    }
    // Taken before the verb runs: what is in the buffer now happened on the
    // way here, which is the step these entries precede in the journal.
    var human = humanActions?.take();
    DriveStep? step;
    String? refusal;
    TargetFailure? failure;
    // The verb's own pointer events arrive on the same global route as the
    // human's; without the suppression every agent tap would journal twice.
    humanActions?.suppress = true;
    try {
      step = await _verb(params, settle);
    } on TargetError catch (error) {
      // A refusal still observes: the agent needs to see the screen the
      // refusal happened on, not guess at it.
      refusal = error.message;
      failure = error.failure;
      await settleLive(budget: settle ?? drive.settleBudget);
    } finally {
      humanActions?.suppress = false;
    }
    return {
      if (step != null) 'step': step.toJson(),
      'error': ?refusal,
      if (failure != null) 'failure': failure.name,
      if (human != null && human.isNotEmpty) 'human': human,
      ...await _observe(params, before),
    };
  }

  Future<DriveStep> _verb(Map<String, String> params, Duration? settle) async {
    var timeout = _durationOf(params, 'actTimeoutMs');
    if (timeout == null) return _run(params, settle);
    // Per-call, not a setting: one caller's short deadline must not become
    // every later caller's.
    var previous = drive.actTimeout;
    drive.actTimeout = timeout;
    try {
      return await _run(params, settle);
    } finally {
      drive.actTimeout = previous;
    }
  }

  Future<DriveStep> _run(Map<String, String> params, Duration? settle) =>
      runWireVerb(drive, params, settle: settle, navigator: navigator);

  ({int logCursor, Map<String, int> errorCounts}) _beforeAct() =>
      (logCursor: _logCursor, errorCounts: _errorCounts);

  Future<Map<String, Object?>> _observe(
    Map<String, String> params,
    ({int logCursor, Map<String, int> errorCounts}) before,
  ) async {
    var binding = WidgetsBinding.instance;

    var logs = GuestLogs.instance.describe();
    var newLines = capStepLogs([
      for (var line in logs.lines)
        if (line.sequence > before.logCursor) line,
    ]);
    if (logs.lines.isNotEmpty) _logCursor = logs.lines.last.sequence;

    var errors = GuestErrors.instance.describe();
    var changed = [
      for (var error in errors.errors)
        if ((before.errorCounts[error.key] ?? 0) < error.count) error,
    ];
    _errorCounts = {for (var error in errors.errors) error.key: error.count};

    // The **whole** tree, every step, unfiltered.
    //
    // Not gated on the caller wanting one, and not narrowed here: the host
    // projects the screen out of it, answers `find`/`at`/`styles` from it and
    // archives it, and every one of those needs the nodes the noise filter
    // drops. Narrowing is the host's decision because the host is where the
    // reply is shaped — see `2026-08-13-screen-handback-design.md` § M1.
    //
    // It costs what it costs either way: the guest built this tree on every
    // observe already, including calls that asked for no tree at all, and the
    // difference between the filtered and unfiltered spellings is 78KB against
    // 121KB over a local socket. Compact, because the host expands the
    // spelling before anything that consumes nodes sees it.
    //
    // **Every one of these three needs a mounted app**, and this method is
    // also what answers for one that has none — see [_notStarted]. Walking the
    // tree, projecting the texts and reading the semantics all end at a null
    // root, so they are skipped rather than guarded individually. What is left
    // is the half that does not need a tree, and in that window it is the only
    // half worth having: the logs and the errors.
    var hasTree = _hasTree;
    var tree = hasTree ? inspector?.read().toJson(compact: true) : null;

    return {
      'lifecycle': binding.lifecycleState?.name,
      'texts': hasTree ? drive.visibleTexts() : const <String>[],
      'tree': ?tree,
      // The semantics tree, as the app publishes it — the same leg a scenario
      // step has kept for two milestones, so the run journal and a scenario
      // step archive the same four things. The nodes already carry the label
      // and the selected state read out of it; this is the rest, for a
      // reviewer asking what a screen reader would have said.
      'semantics': ?(hasTree ? inspector?.readSemantics().root : null),
      // Always taken, never conditional. Whether the caller wants to *see* a
      // picture is the host's business; whether the step is photographed is
      // not, because a journal missing the frame cannot answer a question
      // asked one step later. The host picks the cap, and picks a small one
      // when nobody asked to look — measured at ~46ms against ~234ms.
      'screenshot': await _screenshot(
        maxSide: int.tryParse(params['maxSide'] ?? ''),
      ),
      if (newLines.isNotEmpty)
        'logs': [for (var line in newLines) line.toJson()],
      if (changed.isNotEmpty)
        'errors': [for (var error in changed) error.toJson()],
    };
  }

  /// The root render view, rastered the way a scenario step is — and unlike
  /// `ext.flutter.inspector.screenshot`, alive in profile mode and correct on
  /// a hidden window (the settle already forced the frame this photographs).
  Future<Map<String, Object?>?> _screenshot({int? maxSide}) async {
    var view = WidgetsBinding.instance.renderViews.firstOrNull;
    var layer = view?.debugLayer;
    if (view == null || layer is! OffsetLayer) return null;
    var pixelRatio = view.flutterView.devicePixelRatio;
    var physical = view.size * pixelRatio;
    // The cap scales the render, not a re-encode: base64 over the wire is the
    // cost being bounded, and an agent reads a 1200px screen as well as a
    // 3200px one.
    var scale = 1.0;
    if (maxSide != null && maxSide > 0) {
      var longest = math.max(physical.width, physical.height);
      if (longest > maxSide) scale = maxSide / longest;
    }
    // Under [OffscreenRaster] because this is the raster that cannot hold an
    // external texture — on Linux it takes the whole application down. The
    // notice is what lets the app take one out of the tree first.
    var image = await OffscreenRaster.around(
      () => layer.toImage(Offset.zero & physical, pixelRatio: scale),
    );
    try {
      var bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      return {
        'width': image.width,
        'height': image.height,
        // Scaled with the render, so `imagePx / pixelRatio` stays the mapping
        // to logical coordinates whether or not the cap kicked in.
        'pixelRatio': pixelRatio * scale,
        'base64': base64Encode(bytes.buffer.asUint8List()),
      };
    } finally {
      image.dispose();
    }
  }
}

/// One verb, as the wire spells it: `act`'s parameters, every value a string
/// — `verb`, `target` (bare text, or JSON for the rest of the grammar), and
/// whichever of `text`, `keys`, `dx`, `dy`, `holdMs`, `gapMs`, `waitMs`,
/// `within`, `step`, `maxScrolls` and `route` the verb reads.
///
/// Its own function rather than a method of [GuestDrive] because it is not
/// the live app's alone: a preview that is tapped before it is photographed
/// parses its steps here too, so a step there and an `act` here mean the same
/// thing and are refused in the same words.
Future<DriveStep> runWireVerb(
  Drive drive,
  Map<String, String> params, {
  Duration? settle,
  void Function(String route)? navigator,
}) async {
  switch (params['verb']) {
    case 'tap':
      return drive.tap(_target(params), settle: settle);
    case 'longPress':
      return drive.longPress(_target(params), settle: settle);
    case 'doubleTap':
      return drive.doubleTap(
        _target(params),
        gap: _durationOf(params, 'gapMs'),
        settle: settle,
      );
    case 'secondaryTap':
      return drive.secondaryTap(_target(params), settle: settle);
    case 'hover':
      return drive.hover(
        _target(params),
        hold: _durationOf(params, 'holdMs'),
        settle: settle,
      );
    case 'unhover':
      return drive.unhover(hold: _durationOf(params, 'holdMs'), settle: settle);
    case 'drag':
      return drive.drag(
        _target(params),
        Offset(
          double.parse(params['dx'] ?? '0'),
          double.parse(params['dy'] ?? '0'),
        ),
        settle: settle,
      );
    case 'scroll':
      return drive.scroll(
        _target(params),
        Offset(
          double.parse(params['dx'] ?? '0'),
          double.parse(params['dy'] ?? '0'),
        ),
        settle: settle,
      );
    case 'key':
      return drive.key(params['keys'] ?? '', settle: settle);
    case 'scrollTo':
      return drive.scrollTo(
        _target(params),
        within: params['within'] == null ? null : wireTarget(params['within']!),
        step: double.parse(params['step'] ?? '200'),
        maxScrolls: int.parse(params['maxScrolls'] ?? '50'),
        settle: settle,
      );
    case 'enterText':
      return drive.enterText(
        _target(params),
        params['text'] ?? '',
        settle: settle,
      );
    case 'back':
      return drive.back(settle: settle);
    case 'wait':
      return drive.wait(
        _durationOf(params, 'waitMs') ?? const Duration(seconds: 1),
        settle: settle,
      );
    case 'observe':
      return drive.observe(settle: settle);
    case 'navigate':
      var handler = navigator;
      if (handler == null) {
        throw TargetError(
          TargetFailure.notFound,
          'this app declares no navigation handler — `navigate` needs one. '
          'A routing system registers it with `GuestDrive.navigator = …`; '
          'until then, `tap` walks the UI.',
        );
      }
      var watch = Stopwatch()..start();
      handler(params['route'] ?? '');
      var result = await drive.lane.settle(settle ?? drive.settleBudget);
      return DriveStep(
        verb: 'navigate',
        target: params['route'],
        settle: result,
        elapsed: watch.elapsed,
      );
    default:
      throw ArgumentError(
        'unknown verb ${params['verb']} — one of tap, doubleTap, '
        'longPress, secondaryTap, hover, unhover, drag, scroll, scrollTo, '
        'enterText, key, back, wait, observe, navigate',
      );
  }
}

dynamic _target(Map<String, String> params) {
  var spec = params['target'];
  if (spec == null) {
    throw ArgumentError('this verb needs a `target` parameter');
  }
  return wireTarget(spec);
}

Duration? _durationOf(Map<String, String> params, String key) {
  var ms = params[key];
  return ms == null ? null : Duration(milliseconds: int.parse(ms));
}

/// Parses the wire spelling of a target into the verb-facing value.
///
/// A bare JSON string is visible text; an object names one form:
///
/// ```json
/// "Pay"
/// {"text": "Pay"}
/// {"key": "shop.next"}
/// {"label": "Add to cart"}        // semantics label
/// {"tooltip": "Delete"}
/// {"containing": "Pay"}           // visible text containing
/// {"within": {"scope": {"key": "card"}, "child": "Buy"}}
/// {"nth": {"target": "Buy", "index": 1}}
/// ```
///
/// No node ids yet: acting on "the node I picked in this tree" arrives with
/// the picker integration, where the id has a tree read to be valid against.
dynamic wireTarget(String spec) {
  Object? json;
  try {
    json = jsonDecode(spec);
  } on FormatException {
    // Bare text that never was JSON — an agent typing `target=Pay` should
    // not need quoting rules to tap a button.
    return spec;
  }
  return _wireTarget(json);
}

dynamic _wireTarget(Object? json) {
  switch (json) {
    case String():
      return json;
    case {'text': String text}:
      return text;
    case {'key': String key}:
      return ValueKey<String>(key);
    case {'label': String label}:
      return Target.label(label);
    case {'tooltip': String message}:
      return Target.tooltip(message);
    case {'containing': String text}:
      return Target.containing(text);
    case {'within': {'scope': Object scope, 'child': Object child}}:
      return Target.within(
        _wireTarget(scope) as Object,
        _wireTarget(child) as Object,
      );
    case {'nth': {'target': Object target, 'index': int index}}:
      return Target.nth(_wireTarget(target) as Object, index);
    case {'at': {'x': num x, 'y': num y}}:
      return Target.at(x.toDouble(), y.toDouble());
    default:
      throw ArgumentError(
        'not a target: $json — a bare string is visible text, or one of '
        '{"text"}, {"key"}, {"label"}, {"tooltip"}, {"containing"}, '
        '{"within": {"scope", "child"}}, {"nth": {"target", "index"}}, '
        '{"at": {"x", "y"}}',
      );
  }
}
