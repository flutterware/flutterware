import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

// ignore: implementation_imports
import 'package:flutterware/scene_authoring.dart';
// ignore: implementation_imports
export 'package:flutterware/scene_authoring.dart' show videoStops;

import '../../previews/catalog_render.dart';
import '../../session/job.dart';

/// Encodes a sequence of rendered frames into a video file, through `ffmpeg`.
///
/// Frames arrive as decoded images and leave as raw RGBA on the encoder's
/// stdin, so nothing is ever a PNG. That is not a micro-optimisation: a second
/// of motion is 30 frames, and PNG encoding was measured at ~7.5ms a picture
/// on top of a write and a read back — a third of a minute per minute of video
/// spent turning pixels into a format the encoder immediately undoes.
///
/// `ffmpeg` rather than a Dart encoder because there is no Dart H.264 encoder
/// worth the name, and because the one thing an export has to be is a file
/// somebody else's player opens. It is a hard dependency and says so: an
/// export that silently produced an unplayable file would be worse than one
/// that refuses.
class VideoEncoder {
  VideoEncoder._(
    this._process,
    this._errors,
    this.file,
    this.fps,
    this._width,
    this._height,
  );

  /// Starts an encoder writing [output] at [fps], for frames of [width] by
  /// [height] physical pixels.
  ///
  /// The dimensions are fixed at start because raw video carries no header —
  /// the stream is nothing but pixels, and the encoder has to be told how to
  /// cut it into frames. A guest whose frame size changes mid-motion would
  /// therefore corrupt the stream rather than resize, which is why [add]
  /// checks rather than trusts.
  static Future<VideoEncoder> start({
    required String output,
    required int width,
    required int height,
    required int fps,

    /// The byte order the frames arrive in — what the guest wrote, not what
    /// the encoder would prefer. `ffmpeg` reads either at no cost, so telling
    /// it the truth is cheaper than converting: the guest's ring is BGRA on a
    /// Metal host and RGBA on a GL one, and swizzling in Dart to hide that
    /// costs more than the encode.
    String pixelFormat = 'rgba',

    /// What `libx264` trades encoding time against file size.
    ///
    /// **`medium`, and the fast presets are not worth taking.** The encode is
    /// four fifths of an export's clock, which makes this look like the lever
    /// it is not: measured on a 211-frame phone-resolution clip, the whole
    /// span from `medium` to `ultrafast` is 1568ms to 1334ms — 15% — while
    /// the file goes from 1.1MB to 3.0MB. The time is going into moving and
    /// converting 2.5GB of pixels, which no preset changes.
    ///
    /// Exposed anyway, because a caller who wants the trade should be able to
    /// take it; just not by default.
    String preset = 'medium',

    /// The quality `libx264` aims at, lower being better, or null for its own
    /// default of 23.
    ///
    /// The other half of the trade the preset does not buy: since the export
    /// is bound on moving pixels rather than on encoding them, a clip somebody
    /// is going to *watch* can afford 18 and the file it costs, where a clip
    /// in a pipeline should not pay for it.
    int? crf,
  }) async {
    var file = File(output);
    file.parent.createSync(recursive: true);
    if (file.existsSync()) file.deleteSync();

    Process process;
    try {
      process = await Process.start(executable, [
        '-hide_banner',
        '-loglevel', 'error',
        '-f', 'rawvideo',
        '-pix_fmt', pixelFormat,
        '-s', '${width}x$height',
        '-r', '$fps',
        '-i', '-',
        '-c:v', 'libx264',
        '-preset', preset,
        if (crf != null) ...['-crf', '$crf'],
        // Even dimensions: yuv420p subsamples chroma 2×2, so an odd width
        // fails the encoder outright. Motion renders at a device's pixel
        // ratio, which makes odd sizes ordinary rather than exotic.
        '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2',
        // The chroma format every player agrees on. libx264 defaults to
        // yuv444p for RGBA input, which QuickTime and most browsers refuse.
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        output,
      ]);
    } on ProcessException catch (error) {
      throw ActionRefusal(
        'video export needs `$executable` on PATH, and starting it failed: '
        '${error.message}',
      );
    }

    // Drained rather than ignored: a process whose stderr fills its pipe
    // blocks on the write and the export hangs with no output.
    var errors = StringBuffer();
    unawaited(
      process.stderr.forEach(
        (chunk) => errors.write(String.fromCharCodes(chunk)),
      ),
    );
    unawaited(process.stdout.drain<void>());

    return VideoEncoder._(process, errors, file, fps, width, height);
  }

  static const executable = 'ffmpeg';

  /// Whether [executable] is on PATH and runs.
  ///
  /// Asked *before* a render rather than discovered by [start] after it:
  /// learning that ffmpeg is missing costs nothing here and costs a whole
  /// render there, and the two failures read very differently to whoever is
  /// waiting.
  static Future<bool> get available async {
    try {
      var probe = await Process.run(executable, ['-version']);
      return probe.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// What to say when it is not.
  static const missing =
      'video export needs `ffmpeg` on PATH, and it is not there. '
      '`brew install ffmpeg` on macOS, `apt install ffmpeg` on Debian and '
      'Ubuntu, `winget install ffmpeg` on Windows.';

  final Process _process;
  final StringBuffer _errors;

  final File file;
  final int fps;

  /// How many frames have been handed over.
  int get frames => _frames;
  var _frames = 0;

  final int _width;
  final int _height;

  /// Hands one frame to the encoder.
  ///
  /// Frames go in playhead order and each one is one frame of output — the
  /// caller decides what `t` a frame was rendered at, which is what keeps
  /// [VideoEncoder] ignorant of motion and reusable by anything that renders a
  /// sequence.
  void add(img.Image frame) {
    _require(frame.width, frame.height);
    _process.stdin.add(frame.getBytes(order: img.ChannelOrder.rgba));
    _frames++;
  }

  /// Hands over one frame of a walk, which is already packed RGBA.
  ///
  /// No stride to undo and no channels to swap: the harness rasterises the
  /// layer tree straight to `rawRgba`, which is the format the encoder was
  /// opened on.
  void addPacked(Uint8List pixels, {required int width, required int height}) {
    _require(width, height);
    _process.stdin.add(pixels);
    _frames++;
  }

  void _require(int width, int height) {
    if (width != _width || height != _height) {
      throw StateError(
        'frame ${_frames + 1} is ${width}x$height, but the stream was opened '
        'at ${_width}x$_height: raw video carries no size, so a frame that '
        'changes it corrupts everything after it',
      );
    }
  }

  /// Closes the stream and waits for the file to be written.
  ///
  /// The exit code is read here rather than watched from [start], because an
  /// encoder that is [abort]ed exits non-zero *by design* — a watcher would
  /// turn every deliberate teardown into an unhandled error thrown into
  /// whatever zone happened to be running.
  Future<File> finish() async {
    if (_frames == 0) {
      _process.kill();
      await _process.exitCode;
      throw StateError('nothing was added, so there is no video to write');
    }
    // An encoder that already died leaves a broken pipe here. Its own
    // complaint is the useful one, so the close is allowed to fail quietly and
    // the exit code below speaks.
    try {
      await _process.stdin.close();
    } on Object {
      // Reported by the exit code.
    }
    var code = await _process.exitCode;
    if (code != 0) throw StateError('ffmpeg exited $code:\n$_errors');
    return file;
  }

  /// Ends the encode without producing a file — for a render that failed
  /// partway, where a truncated video is worse than none.
  Future<void> abort() async {
    _process.kill();
    await _process.exitCode;
    if (file.existsSync()) file.deleteSync();
  }
}

/// One clip, and what the motion said about itself while it was rendered.
class MotionVideo {
  MotionVideo({
    required this.file,
    required this.frames,
    required this.fps,
    required this.durationMs,
    required this.renderTime,
    required this.encodeTime,
    this.parts = 1,
    this.scope,
    this.scopes = const [],
  });

  final File file;
  final int frames;
  final int fps;

  /// The motion's own duration, which is what set the frame count.
  final int durationMs;

  /// Rendering and handing frames over, which is the cost that scales.
  final Duration renderTime;

  /// Waiting for the encoder after the last frame went in. Small, because
  /// `ffmpeg` was encoding all along.
  final Duration encodeTime;

  /// How many encoders the clip was spread across.
  final int parts;

  final String? scope;

  /// Every playhead that was mounted, when there was more than one.
  final List<String> scopes;
}

/// Encodes a walk into a clip.
///
/// Lane-agnostic on purpose: it takes a [CatalogWalkResult] and knows nothing
/// about how the frames were drawn, which is what lets the renderer be chosen
/// per call rather than baked in here.
///
/// The encoder is opened on the *first* frame's size rather than on a device's,
/// because raw video carries no header and what matters is the size the frames
/// actually came out — a clip opened at the size we asked for and fed frames of
/// another shears rather than fails.
Future<MotionVideo> encodeWalk(
  CatalogWalkResult walk, {
  required String output,
  required int fps,
  String preset = 'medium',

  /// How many encoders to spread the clip across. One writes [output]
  /// directly; more write parts that are joined afterwards. Null picks from
  /// the machine and the clip's length.
  int? parts,
}) async {
  // Decided before the first frame, because it decides where the first frame
  // goes. The count comes from the same rule that produced the stops.
  var perPart = _framesPerPart(
    videoStops(durationMs: walk.durationMs, fps: fps).length,
    parts: parts,
  );
  var scratch = Directory.systemTemp.createTempSync('fw-clip');
  var encoders = <VideoEncoder>[];
  var render = Stopwatch()..start();
  var count = 0;

  try {
    await for (var frame in walk.frames) {
      var index = perPart == 0 ? 0 : count ~/ perPart;
      if (index >= encoders.length) {
        encoders.add(
          await VideoEncoder.start(
            output: perPart == 0
                ? output
                : p.join(scratch.path, 'part-$index.mp4'),
            width: frame.width,
            height: frame.height,
            fps: fps,
            preset: preset,
          ),
        );
      }
      encoders[index].addPacked(
        frame.pixels,
        width: frame.width,
        height: frame.height,
      );
      count++;
    }
  } catch (_) {
    for (var encoder in encoders) {
      await encoder.abort();
    }
    scratch.deleteSync(recursive: true);
    rethrow;
  }
  if (encoders.isEmpty) {
    scratch.deleteSync(recursive: true);
    throw StateError('the walk rendered nothing to encode');
  }
  render.stop();

  // **The concurrency is in never awaiting a part as it is fed.** Frames
  // arrive in playhead order, so part `k` is still encoding while part `k+1`
  // is being handed its pixels: the overlap costs no scheduling and no thread
  // of ours, and what is waited for here is the slowest tail rather than the
  // sum. Measured on this machine a single export used two of sixteen cores,
  // which is the headroom this spends.
  var flush = Stopwatch()..start();
  var files = await Future.wait([for (var e in encoders) e.finish()]);
  var file = files.length == 1
      ? files.single
      : await _joinParts(files, output: output);
  flush.stop();
  if (scratch.existsSync()) scratch.deleteSync(recursive: true);

  return MotionVideo(
    file: file,
    frames: count,
    fps: fps,
    durationMs: walk.durationMs,
    renderTime: render.elapsed,
    encodeTime: flush.elapsed,
    parts: files.length,
    scope: walk.scope,
    scopes: walk.scopes,
  );
}

/// How many frames each encoder takes, or zero for one encoder over the lot.
///
/// Splitting has to earn its join: a part wants to be long enough that its
/// encoder spends more time on pixels than on starting, and there is no use
/// having more parts than the machine has room for. A short clip therefore
/// gets one encoder writing the output directly, with nothing to join.
int _framesPerPart(int frames, {int? parts}) {
  var wanted =
      parts ??
      (frames < _minimumPartFrames * 2
          ? 1
          : math.min(Platform.numberOfProcessors ~/ 2, 8));
  if (wanted <= 1) return 0;
  return math.max(_minimumPartFrames, (frames / wanted).ceil());
}

/// The shortest part worth starting an encoder for.
const _minimumPartFrames = 60;

/// Joins encoded parts into one clip, copying the streams rather than
/// re-encoding them.
///
/// Sound because each part is its own encode and so opens on a keyframe; the
/// concat demuxer only has to rebase timestamps. Re-encoding here would hand
/// back everything the split bought.
Future<File> _joinParts(List<File> parts, {required String output}) async {
  var list = File(p.join(p.dirname(parts.first.path), 'parts.txt'))
    ..writeAsStringSync(
      [for (var part in parts) "file '${part.path}'"].join('\n'),
    );
  var out = File(output);
  if (out.existsSync()) out.deleteSync();
  var joined = await Process.run(VideoEncoder.executable, [
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    list.path,
    '-c',
    'copy',
    '-movflags',
    '+faststart',
    output,
  ]);
  if (joined.exitCode != 0) {
    throw StateError(
      'joining ${parts.length} encoded parts failed:\n${joined.stderr}',
    );
  }
  return out;
}
