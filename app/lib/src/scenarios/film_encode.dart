import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// The encoder is lane-agnostic by design — it takes packed pixels and knows
// nothing about what drew them — so a film uses the one the scene export
// already has rather than a second copy of `ffmpeg`.
import '../scene/export/video.dart';
import '../session/job.dart';

/// Encodes a film **while the harness is still drawing it**.
///
/// The harness writes one raw frame per file, numbered without gaps and
/// renamed into place, and this reads them in order, feeds them to `ffmpeg`
/// and deletes each one behind it. That is the whole of the transport: no
/// protocol, no socket, and — the point — no moment at which the clip exists
/// on disk. A minute of film at 1080×2340 is 9GB of raw pixels, and the
/// consumer is roughly two orders of magnitude faster than the producer
/// (~3.5ms of `ffmpeg` against a build, a layout, a paint and two rasters),
/// so what is actually on disk at any moment is a handful of frames.
///
/// Three files agree on when it is over, and none of them is a message:
/// `film.head.json` appears with the first frame and says how big the frames
/// are, the frames appear in order, and `film.json` appears last and says how
/// many there were. A run that ends without the timeline ended badly, and this
/// aborts rather than handing back a clip that looks finished.
class ScenarioFilmEncode {
  ScenarioFilmEncode({
    required this.directory,
    required this.output,
    this.preset = 'slow',
    this.crf = 18,
    this.poll = const Duration(milliseconds: 20),
  });

  /// Where the harness is writing frames.
  final String directory;

  /// Where the mp4 goes.
  final String output;

  /// What `libx264` trades time against size for. `slow` rather than the
  /// scene export's `medium`, because a reel is watched: measured there, the
  /// whole preset span is 15% of a render's clock.
  final String preset;

  /// Quality, lower being better. 18 is visually lossless enough for UI text
  /// under the chroma subsampling `yuv420p` forces.
  final int crf;

  /// How often the directory is looked at while frames are still coming.
  final Duration poll;

  /// Drains until [running] is done and the timeline says every frame is in.
  ///
  /// [running] is the render — awaited only to know that no more frames are
  /// coming. Its own failure is the caller's business; what this does with it
  /// is stop waiting.
  Future<ScenarioFilm> drain(
    Future<void> running, {

    /// Told how far along the encode is, whenever that changes.
    ///
    /// A render is the only thing in this GUI that takes tens of seconds and
    /// has nothing to show for it until it ends, and the frame count is the
    /// one number that is honest the whole way through: it starts at nothing
    /// while the harness compiles, counts up while the film is drawn, and only
    /// gains a *total* when the timeline lands — which is why the total is
    /// nullable rather than guessed.
    void Function(ScenarioFilmProgress progress)? onProgress,
  }) async {
    var over = false;
    onProgress?.call(const ScenarioFilmProgress(frames: 0));
    // Watched rather than awaited: this loop has to keep feeding the encoder
    // while the render is in flight, and it must also notice a render that
    // died before it wrote anything.
    unawaited(running.then((_) => over = true, onError: (_) => over = true));

    var head = await _head(() => over);
    onProgress?.call(ScenarioFilmProgress(frames: 0, fps: head.fps));
    var encoder = await VideoEncoder.start(
      output: output,
      width: head.width,
      height: head.height,
      fps: head.fps,
      preset: preset,
      crf: crf,
    );
    var fed = 0;
    try {
      while (true) {
        // Read before the frames, so a timeline that lands mid-sweep is not
        // believed about a frame this pass has not seen yet.
        var timeline = _timeline();
        var before = fed;
        fed += _feed(
          encoder,
          from: fed,
          width: head.width,
          height: head.height,
        );
        if (fed != before || timeline != null) {
          onProgress?.call(
            ScenarioFilmProgress(
              frames: fed,
              total: timeline?.frames,
              fps: head.fps,
            ),
          );
        }
        if (timeline != null) {
          if (fed >= timeline.frames) break;
        } else if (over) {
          throw ActionRefusal(
            'the render ended without writing ${ScenarioFilmNames.timeline}: '
            'it wrote $fed frames and then stopped, so there is no film to '
            'encode. The scenario failed, and its own error says why.',
          );
        }
        await Future<void>.delayed(poll);
      }
      var timeline = _timeline()!;
      var file = await encoder.finish();
      return ScenarioFilm(
        file: file,
        frames: fed,
        fps: head.fps,
        width: head.width,
        height: head.height,
        dropped: timeline.dropped,
        beats: timeline.beats,
      );
    } catch (_) {
      // A truncated clip is worse than none: it plays, it looks finished, and
      // it stops in the middle of the flow it was meant to show.
      await encoder.abort();
      rethrow;
    }
  }

  /// Waits for the head — the first thing the harness writes that says how big
  /// a frame is, and so the first moment an encoder can be opened.
  Future<_Head> _head(bool Function() over) async {
    var file = File(p.join(directory, ScenarioFilmNames.head));
    while (!file.existsSync()) {
      if (over()) {
        throw ActionRefusal(
          'the render drew no frames at all, so there is nothing to encode. '
          'The scenario failed before its first screen, and its own error '
          'says why.',
        );
      }
      await Future<void>.delayed(poll);
    }
    var json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return _Head(
      width: json['width']! as int,
      height: json['height']! as int,
      fps: json['fps']! as int,
    );
  }

  /// Feeds every frame that has arrived since the last pass, and deletes each
  /// one as it goes. Returns how many.
  ///
  /// In order and without skipping: a numbered file that is not there yet is
  /// not a gap, it is the next frame still being drawn. Stopping at the first
  /// hole is what keeps the clip in playhead order.
  int _feed(
    VideoEncoder encoder, {
    required int from,
    required int width,
    required int height,
  }) {
    var fed = 0;
    while (true) {
      var file = File(p.join(directory, ScenarioFilmNames.frame(from + fed)));
      if (!file.existsSync()) return fed;
      encoder.addPacked(file.readAsBytesSync(), width: width, height: height);
      file.deleteSync();
      fed++;
    }
  }

  _Timeline? _timeline() {
    var file = File(p.join(directory, ScenarioFilmNames.timeline));
    if (!file.existsSync()) return null;
    var json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return _Timeline(
      frames: json['frames']! as int,
      dropped: json['dropped'] as int? ?? 0,
      beats: [
        for (var beat in json['beats']! as List)
          (beat as Map).cast<String, Object?>(),
      ],
    );
  }
}

/// The names the harness and the drain agree on, in one place, so the two ends
/// of a directory cannot drift apart.
abstract final class ScenarioFilmNames {
  static const head = 'film.head.json';
  static const timeline = 'film.json';

  static String frame(int index) => '${index.toString().padLeft(6, '0')}.raw';
}

/// How far along an encode is.
///
/// [total] is null until the harness writes its timeline, because until then
/// nobody knows how long the film is: a scenario's length is what it does, not
/// something declared up front.
class ScenarioFilmProgress {
  const ScenarioFilmProgress({required this.frames, this.total, this.fps = 30});

  /// Frames handed to the encoder so far.
  final int frames;

  /// Frames in the whole film, once the render has finished drawing it.
  final int? total;

  final int fps;

  /// A bar's value, or null while there is nothing to be a fraction of.
  double? get fraction => switch (total) {
    null || 0 => null,
    var total => (frames / total).clamp(0.0, 1.0),
  };

  /// How much film has been encoded — the number a viewer actually reads.
  Duration get filmed =>
      Duration(microseconds: (frames / fps * 1000000).round());
}

/// One rendered film, and what it says about itself.
class ScenarioFilm {
  ScenarioFilm({
    required this.file,
    required this.frames,
    required this.fps,
    required this.width,
    required this.height,
    required this.dropped,
    required this.beats,
  });

  final File file;
  final int frames;
  final int fps;
  final int width;
  final int height;

  /// Frames the film's own ceiling refused — the clip stops before the
  /// scenario did.
  final int dropped;

  /// What each stretch of the film is: the beat list from the timeline.
  final List<Map<String, Object?>> beats;

  Duration get duration =>
      Duration(microseconds: (frames / fps * 1000000).round());
}

class _Head {
  _Head({required this.width, required this.height, required this.fps});

  final int width;
  final int height;
  final int fps;
}

class _Timeline {
  _Timeline({required this.frames, required this.dropped, required this.beats});

  final int frames;
  final int dropped;
  final List<Map<String, Object?>> beats;
}
