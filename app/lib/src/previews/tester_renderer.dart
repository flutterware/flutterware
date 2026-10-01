// The report types, not the umbrella `ui_catalog.dart`: that one exports the
// demo annotations, which reach `package:flutter/widgets.dart`.
// ignore: implementation_imports
import 'package:flutterware/src/inspect/error.dart';
// ignore: implementation_imports
import 'package:flutterware/src/inspect/node.dart';
// ignore: implementation_imports
import 'package:flutterware/src/devices.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/axis.dart';
// ignore: implementation_imports
import 'package:flutterware/src/ui_catalog/knob.dart';

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'catalog_picture.dart';
import 'catalog_render.dart';
import 'catalog_values.dart';
import 'test_runner.dart';

/// The `flutter_tester` backend of [CatalogRenderer].
///
/// One warm harness for a whole package against one embedder guest per call:
/// measured 2026-08-27 on this repo's catalog, a guest render is ~12.7s of
/// daemon-connect, whole-kernel compile, spawn and teardown, and a warm
/// harness answers in tens of milliseconds. It is also reproducible — the same
/// entry renders byte-identically under FakeAsync — which is what the audit,
/// the comparison and the thumbnails all moved here for.
///
/// **What it cannot answer is refused, never approximated.** The logs are the
/// one thing left: a demo's `print` inside a widget test rides the runner's
/// own message stream rather than the zone `GuestLogs` wraps, so there is
/// nothing here to collect — and it is refused by name rather than answered
/// empty, because a caller told "no logs" when it means "not on this engine"
/// goes looking in the demo.
class TesterRenderer extends CatalogRenderer {
  TesterRenderer({required this.runner, this.sync = true});

  final PreviewTestRunner runner;

  /// Bring the harness up to date with what is on disk first — a sweep of
  /// every source and the asset bundle, ~1.5–1.9s even when nothing moved.
  ///
  /// Right for a caller answering a question about the code as it is now,
  /// which is every caller here; the hover thumbnails are the ones that turn
  /// it off, because they have their own idea of when a picture went stale.
  final bool sync;

  @override
  Future<CatalogObservation> render(CatalogRender request) async {
    // **Two calls, and the first one is what makes the refusals right.** Which
    // kind a knob is, and which label an axis option answers to, are facts
    // about the build that declared them — so the values are resolved against
    // a real declaration rather than guessed at from the characters, and a
    // name nobody declared is refused in the same words the guest refuses it
    // in. The extra call is a pump of one entry against a warm harness: tens
    // of milliseconds, against a wrong picture that looks right.
    var wantsValues = request.knobs.isNotEmpty || request.axes.isNotEmpty;
    var declared = wantsValues
        ? await _ask(request, wantKnobs: true, wantAxes: true)
        : null;

    var reply = await _ask(
      request,
      knobs: declared == null
          ? null
          : knobPayloadFor(
              declared.knobs,
              request.knobs,
              entryId: request.entryId,
            ),
      axes: declared == null
          ? null
          : axisPayloadFor(declared.axes, request.axes),
      wantKnobs: request.wantKnobs,
      wantAxes: request.wantAxes,
      // The *first* call syncs and the second must not: a sweep of every
      // source between reading what an entry declares and turning it would be
      // a second chance to pick up an edit, and the values would then be
      // applied against declarations from before it.
      sync: declared == null && sync,
      kept: true,
    );
    if (reply.stepRefused case var refused?) {
      throw ArgumentError.value(
        request.steps,
        'steps',
        _stepRefusal(request.steps, refused),
      );
    }
    if (reply.refused case var refused?) {
      throw ArgumentError.value(request.cropNode, 'node', refused);
    }
    // A harness that rendered and said nothing about the growing never grew
    // anything: the checkout resolves a `package:flutterware` from before
    // `full`, which renders the entry at rest and ignores the argument.
    if (request.full && reply.grown == null && reply.stagedOn != null) {
      throw ArgumentError.value(
        request.full,
        'full',
        "this checkout's package:flutterware predates `full`: the harness "
            'rendered the entry at its own height',
      );
    }
    var picture = switch ((request.screenshot, reply.frame)) {
      (var output?, var frame?) => _file(
        request,
        output,
        frame,
        reply.tree,
        cropTo: reply.revealed?.id ?? request.cropNode,
      ),
      _ => null,
    };

    return CatalogObservation(
      errors: reply.errors,
      knobs: request.wantKnobs ? reply.knobs : null,
      axes: request.wantAxes ? reply.axes : null,
      stagedOn: reply.stagedOn,
      tree: request.wantTree ? reply.tree : null,
      hits: reply.hits,
      revealed: reply.revealed,
      grown: reply.grown,
      drawnAt: reply.frame?.pixelRatio,
      screenshot: picture?.file,
      pages: picture?.pages ?? const [],
    );
  }

  /// Walks the playhead, yielding a frame per stop.
  ///
  /// The knob and axis resolution is [render]'s, deliberately: a walk turns
  /// the same values against the same declarations, and a second way of
  /// resolving them is a second chance to disagree about what a knob named
  /// `progress` is.
  ///
  /// Raw rather than PNG, and yielded rather than collected: a walk's consumer
  /// is an encoder, which wants pixels and wants them as they come. Sixty
  /// frames of a phone at 3x is a gigabyte if it is gathered first.
  @override
  Future<CatalogWalkResult> walk(CatalogWalk request) async {
    var probe = CatalogRender(
      entryId: request.entryId,
      viewport: request.viewport,
      knobs: request.knobs,
      axes: request.axes,
    );
    var wantsValues = request.knobs.isNotEmpty || request.axes.isNotEmpty;
    var declared = wantsValues
        ? await _ask(probe, wantKnobs: true, wantAxes: true)
        : null;

    var reply = await _ask(
      probe,
      knobs: declared == null
          ? null
          : knobPayloadFor(
              declared.knobs,
              request.knobs,
              entryId: request.entryId,
            ),
      axes: declared == null
          ? null
          : axisPayloadFor(declared.axes, request.axes),
      walk: request,
      sync: declared == null && sync,
    );

    var frames = reply.walk;
    if (request.stops case var asked? when frames.length != asked.length) {
      throw StateError(
        'the harness returned ${frames.length} frames for ${asked.length} '
        'stops',
      );
    }
    if (frames.isEmpty) {
      throw StateError(
        'the harness walked no stops of ${request.entryId} — it reports a '
        'motion ${reply.durationMs}ms long, and a motion of no duration has '
        'nothing to render',
      );
    }
    return CatalogWalkResult(
      durationMs: reply.durationMs,
      scope: reply.scope,
      scopes: reply.scopes,
      frames: _read(frames),
    );
  }

  /// Reads the harness's frames one at a time, and sweeps them after.
  ///
  /// Lazily, because a clip is bigger than memory — sixty frames of a phone at
  /// 3x is about a gigabyte — and the encoder wants them one at a time anyway.
  Stream<WalkFrame> _read(List<_WalkFrame> frames) async* {
    try {
      for (var frame in frames) {
        var file = File(frame.path);
        var pixels = file.readAsBytesSync();
        // **Dropped as it is consumed, not at the end.** A frame is megabytes
        // — twelve of them at a phone's ratio — so a minute of video is tens
        // of gigabytes, and holding the whole clip on disk to delete it later
        // is a peak nothing needs. What the consumer has already encoded is
        // not coming back.
        if (file.existsSync()) file.deleteSync();
        yield WalkFrame(
          t: frame.t,
          width: frame.width,
          height: frame.height,
          pixels: pixels,
        );
      }
    } finally {
      // The frames were scaffolding on their way to a clip, and they are
      // megabytes each. One directory holds the walk, so one delete does it —
      // including when the consumer gave up half way.
      var directory = Directory(p.dirname(frames.first.path));
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }

  /// The frame the harness drew, framed and written where the caller asked.
  ///
  /// **The framing is host-side and shared**, which is the whole of §5.4: the
  /// same `PictureFraming` resolves `--node` against the same kind of tree,
  /// and the same `writePicture` encodes it, whichever engine drew the pixels.
  /// What differs is one decode — packed rgba here against the embedder's BGRA
  /// behind a header.
  ///
  /// A `--full` picture taller than the screen it started as is also written
  /// a screen at a time, cut between the rows [tree] places.
  ({File file, List<File> pages}) _file(
    CatalogRender request,
    String output,
    _Frame frame,
    InspectTree? tree, {
    required String? cropTo,
  }) {
    // Read and deleted here rather than inside the harness call, which is
    // where the numbering below earns itself: `TesterHost.exclusive`
    // serialises the *render*, and this runs after it returns. Two renders in
    // flight would otherwise both write `frame/0.png`, and the first would
    // decode the second's picture — a wrong picture that looks right, which
    // is the failure this whole lane is built to make impossible.
    var bytes = File(frame.path).readAsBytesSync();
    var image = frame.format == 'png'
        ? img.decodePng(bytes)!
        : decodeTesterFrame(bytes, width: frame.width, height: frame.height);
    try {
      var framing = request.framed
          ? PictureFraming.of(
              // `framed` is what put us here and the request's `needsTree`
              // covers it, so the tree was asked for and is in hand.
              tree!,
              node: cropTo,
              annotate: request.annotate,
              entryId: request.entryId,
            )
          : const PictureFraming();
      // The ratio the frame was *drawn* at, which is what turns the tree's
      // boxes into its pixels.
      var ratio = frame.pixelRatio ?? request.viewport.pixelRatio;
      var picture = framePicture(image, framing: framing, pixelRatio: ratio);
      var file = writePicture(picture, output);
      if (!request.full || tree == null) return (file: file, pages: const []);
      // The screen it started as, which is what a page is: a reader that
      // takes in one screenshot takes in one of these.
      var top = framing.crop?.y ?? 0;
      return (
        file: file,
        pages: writePages(
          picture,
          output,
          pageCuts(
            tree,
            page: request.viewport.height / request.viewport.pixelRatio,
            top: top,
            bottom: top + picture.height / ratio,
          ),
          pixelRatio: ratio,
        ),
      );
    } finally {
      // The frame was scaffolding: raw at a phone's ratio is megabytes, and
      // the artifact is the PNG.
      var directory = Directory(p.dirname(frame.path));
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }

  Future<_Reply> _ask(
    CatalogRender request, {
    Map<String, Object?>? knobs,
    Map<String, Map<String, Object?>>? axes,
    bool wantKnobs = false,
    bool wantAxes = false,
    bool? sync,
    CatalogWalk? walk,
    bool kept = false,
  }) async {
    var reply = await runner.render(
      entryId: request.entryId,
      sync: sync ?? this.sync,
      request: {
        'entry': request.entryId,
        // The whole screen as numbers, which is what the guest is sent over
        // its resize message too — so the two backends are staged from one
        // answer rather than each deriving its own from a device id.
        'viewport': request.viewport.staged.toJson(),
        // The staged screen's own ratio, so a picture from this lane comes out
        // the size the guest's would.
        if (request.viewport.pixelRatio != 1)
          'pixelRatio': request.viewport.pixelRatio,
        'knobs': ?knobs,
        'axes': ?axes,
        if (wantKnobs) 'wantKnobs': true,
        if (wantAxes) 'wantAxes': true,
        // A directory for the frame, not the final path: what the harness
        // draws is scaffolding, and the artifact is what `writePicture` makes
        // of it. PNG rather than raw, because a phone-sized frame is
        // megabytes of rgba to move across a disk for one picture — the
        // comparison keeps raw precisely because it diffs pixels and would
        // decode straight back out.
        if (walk != null) ...{
          'output': _scratch,
          // Raw: a walk's frames are pixels on their way to an encoder, and a
          // PNG each would be encoded here only to be decoded again there.
          'format': 'raw',
          'walk': {
            // Empty says "the whole motion at fps", which only the running
            // motion can turn into stops.
            'stops': walk.stops?.join(',') ?? '',
            'scope': ?walk.scope,
            'mode': walk.mode.name,
            'fps': walk.fps,
          },
        } else if (request.screenshot != null) ...{
          'output': _scratch,
          'format': 'png',
        },
        // The playhead for a single picture, which this lane used to drop on
        // the floor — a `--engine harness` screenshot at `t` rendered `t=0`
        // and reported success.
        if (walk == null) 'motionT': ?request.motionT,
        if (request.needsTree) 'tree': true,
        if (request.at != null) 'at': '${request.at!.$1},${request.at!.$2}',
        // Only on the call whose frame is kept: the probe that reads what an
        // entry declares would walk a long list, and tap its way through the
        // steps, for nothing.
        if (kept && (request.cropNode?.isNotEmpty ?? false))
          'reveal': request.cropNode,
        if (kept && request.steps.isNotEmpty) 'steps': request.steps,
        if (kept && request.full) 'full': true,
        // Named rather than omitted, so the harness refuses it by name — a
        // request that came back looking answered and was not is the failure
        // this lane has to be safe from.
        if (request.wantLogs) 'logs': true,
      },
    );
    var reported = InspectErrors.fromJson(reply);
    return _Reply(
      // The failure too, which the runner hands back rather than refusing
      // when a frame came with it: a picture and a complaint are two answers,
      // and a caller told `ok` about an entry whose test failed has been told
      // the one thing that is not true.
      errors: InspectErrors(
        entryId: reported.entryId,
        errors: withFailure(
          reported.errors,
          failure: reply['failure'] as String?,
          frames: [
            for (var frame in reply['failureFrames'] as List? ?? const [])
              '$frame',
          ],
        ),
      ),
      stagedOn: switch (reply['viewport']) {
        Map json => StagedViewport.fromJson(json.cast<String, Object?>()),
        _ => null,
      },
      knobs: switch (reply['knobs']) {
        Map json => KnobReport.fromJson(json.cast<String, Object?>()),
        _ => KnobReport.empty,
      },
      axes: switch (reply['axes']) {
        Map json => AxisReport.fromJson(json.cast<String, Object?>()),
        _ => AxisReport.empty,
      },
      tree: switch (reply['tree']) {
        Map json => InspectTree.fromJson(json.cast<String, Object?>()),
        _ => null,
      },
      hits: switch (reply['hits']) {
        List ids => [for (var id in ids) '$id'],
        _ => null,
      },
      revealed: switch (reply['reveal']) {
        Map json when json['refused'] == null => CatalogReveal(
          id: json['id'] as String?,
          scrolled: (json['scrolled'] as num? ?? 0).toDouble(),
        ),
        _ => null,
      },
      refused: switch (reply['reveal']) {
        {'refused': String refused} => refused,
        _ => null,
      },
      stepRefused: switch (reply['stepRefused']) {
        Map json => json.cast<String, Object?>(),
        _ => null,
      },
      grown: switch (reply['grown']) {
        Map json => CatalogGrown(
          from: (json['from'] as num).toDouble(),
          to: (json['to'] as num).toDouble(),
          truncated: json['truncated'] == true,
        ),
        _ => null,
      },
      durationMs: (reply['durationMs'] as num? ?? 0).toInt(),
      scope: reply['scope'] as String?,
      scopes: [for (var id in (reply['scopes'] as List? ?? const [])) '$id'],
      walk: [
        for (var frame in (reply['walk'] as List? ?? const []))
          if (frame is Map)
            _WalkFrame(
              path: '${frame['image']}',
              t: (frame['t'] as num).toDouble(),
              width: frame['width'] as int? ?? 0,
              height: frame['height'] as int? ?? 0,
            ),
      ],
      frame: switch (reply['image']) {
        String path => _Frame(
          path: path,
          format: reply['format'] as String? ?? 'raw',
          width: reply['width'] as int? ?? 0,
          height: reply['height'] as int? ?? 0,
          pixelRatio: (reply['pixelRatio'] as num?)?.toDouble(),
        ),
        _ => null,
      },
    );
  }

  /// A refused step, said the way `act` says it, with which step it was: the
  /// message alone is drive's, and does not know it was one of several.
  static String _stepRefusal(
    List<Map<String, String>> steps,
    Map<String, Object?> refused,
  ) {
    var index = refused['index'] as int? ?? 0;
    var step = index < steps.length ? steps[index] : const <String, String>{};
    var named = [step['verb'], ?step['target']].nonNulls.join(' ');
    return 'step ${index + 1} of ${steps.length} ($named) was refused, and '
        'the steps after it did not run: ${refused['error']}';
  }

  /// Where the next frame lands on its way to being a picture.
  ///
  /// Under the runner's own build directory rather than the system temp, so a
  /// crash leaves it where the rest of the lane's scaffolding is swept from —
  /// and numbered, because the read and the delete happen outside the
  /// harness's own lock. See [_file].
  String get _scratch =>
      p.join(runner.packageRoot, runner.buildDirectory, 'frame-${_frames++}');

  /// Process-wide, not per instance: `PreviewsCore` builds a renderer per
  /// call over the one shared runner, so a field here would start every
  /// concurrent call at `frame-0` and defeat the numbering.
  static var _frames = 0;
}

class _Frame {
  const _Frame({
    required this.path,
    required this.format,
    required this.width,
    required this.height,
    this.pixelRatio,
  });

  final String path;
  final String format;
  final int width;
  final int height;

  /// The ratio it was drawn at, when that is lower than the one asked for:
  /// a picture taller than the rasteriser's largest texture is drawn
  /// smaller rather than cut short.
  final double? pixelRatio;
}

class _Reply {
  const _Reply({
    required this.errors,
    required this.knobs,
    required this.axes,
    this.stagedOn,
    this.tree,
    this.hits,
    this.revealed,
    this.refused,
    this.stepRefused,
    this.grown,
    this.frame,
    this.walk = const [],
    this.durationMs = 0,
    this.scope,
    this.scopes = const [],
  });

  final StagedViewport? stagedOn;
  final InspectErrors errors;
  final KnobReport knobs;
  final AxisReport axes;
  final InspectTree? tree;
  final List<String>? hits;
  final CatalogReveal? revealed;

  /// Why the `--node` could not be brought on screen, when a walk found it
  /// ambiguous.
  final String? refused;

  /// The step that was refused — its index and drive's own words — when one
  /// was. The steps after it did not run.
  final Map<String, Object?>? stepRefused;

  /// How far the screen grew, answered whenever `full` was asked.
  final CatalogGrown? grown;
  final _Frame? frame;
  final List<_WalkFrame> walk;
  final int durationMs;
  final String? scope;
  final List<String> scopes;
}

/// One frame of a walk as the harness reported it: where it is, and which stop
/// it is of.
class _WalkFrame {
  const _WalkFrame({
    required this.path,
    required this.t,
    required this.width,
    required this.height,
  });

  final String path;
  final double t;
  final int width;
  final int height;
}
