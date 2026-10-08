import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/scene/export/video.dart';
import 'package:flutterware_app/src/scenarios/film_encode.dart';
import 'package:flutterware_app/src/session/job.dart';
import 'package:path/path.dart' as p;

/// Encoding a film while the harness is still writing it. The producer here is
/// a fake — the point is the agreement between the two ends of a directory,
/// not the pixels — and `manual_film_dump.dart` is where the real one is
/// watched.
void main() {
  late Directory scratch;
  late String frames;
  late String output;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('fw-film-encode');
    frames = p.join(scratch.path, 'frames');
    Directory(frames).createSync(recursive: true);
    output = p.join(scratch.path, 'film.mp4');
  });
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  void head({int width = 32, int height = 24, int fps = 10}) =>
      File(p.join(frames, ScenarioFilmNames.head)).writeAsStringSync(
        jsonEncode({'width': width, 'height': height, 'fps': fps}),
      );

  void frame(int index, {int width = 32, int height = 24, int grey = 0}) {
    var path = p.join(frames, ScenarioFilmNames.frame(index));
    File('$path.part')
      ..writeAsBytesSync(
        Uint8List.fromList([
          for (var i = 0; i < width * height; i++) ...[grey, grey, grey, 255],
        ]),
      )
      ..renameSync(path);
  }

  void timeline(int count, {int dropped = 0}) =>
      File(p.join(frames, ScenarioFilmNames.timeline)).writeAsStringSync(
        jsonEncode({
          'frames': count,
          if (dropped > 0) 'dropped': dropped,
          'beats': [
            {'kind': 'open', 'frame': 0, 'frames': count},
          ],
        }),
      );

  test('encodes frames as they arrive, and deletes them behind it', () async {
    // The render, as the harness performs it: a head with the first frame,
    // frames in order, a timeline last. Deliberately slower than the encoder,
    // which is the real ratio — a frame costs a build, a layout, two rasters
    // and a write, against ~3.5ms of ffmpeg.
    var render = () async {
      head();
      for (var i = 0; i < 12; i++) {
        frame(i, grey: i * 20);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      timeline(12);
    }();

    var film = await ScenarioFilmEncode(
      directory: frames,
      output: output,
      // Fast: this test is about the agreement, not the compression.
      preset: 'ultrafast',
      poll: const Duration(milliseconds: 5),
    ).drain(render);

    expect(film.frames, 12);
    expect(film.fps, 10);
    expect(film.width, 32);
    expect(film.file.existsSync(), isTrue);
    // The container's own magic, so this asserts a real mp4 rather than
    // "ffmpeg exited 0" — which it also does for an empty file.
    expect(film.file.readAsBytesSync().sublist(4, 8), 'ftyp'.codeUnits);
    // Nothing is left behind: a minute of film is 9GB of raw pixels, and the
    // whole point of draining is that they are never all on disk at once.
    expect(
      Directory(frames).listSync().map((e) => p.basename(e.path)),
      unorderedEquals([ScenarioFilmNames.head, ScenarioFilmNames.timeline]),
    );
  }, skip: _skipWithoutFfmpeg);

  test('carries what the timeline says about itself', () async {
    var render = () async {
      head();
      for (var i = 0; i < 4; i++) {
        frame(i);
      }
      timeline(4, dropped: 7);
    }();

    var film = await ScenarioFilmEncode(
      directory: frames,
      output: output,
      preset: 'ultrafast',
      poll: const Duration(milliseconds: 5),
    ).drain(render);

    // A film that ran into its own ceiling stops before the scenario did, and
    // saying so is the difference between a short clip and a truncated one.
    expect(film.dropped, 7);
    expect(film.beats, hasLength(1));
    expect(film.duration, const Duration(milliseconds: 400));
  }, skip: _skipWithoutFfmpeg);

  test('a render that stops without a timeline leaves no file', () async {
    var render = () async {
      head();
      frame(0);
      frame(1);
      // And then the scenario throws: no timeline, so the film is unfinished.
    }();

    await expectLater(
      ScenarioFilmEncode(
        directory: frames,
        output: output,
        preset: 'ultrafast',
        poll: const Duration(milliseconds: 5),
      ).drain(render),
      throwsA(
        isA<ActionRefusal>().having(
          (e) => e.message,
          'message',
          contains('ended without writing'),
        ),
      ),
    );
    // A clip that plays and stops mid-flow reads as the app failing.
    expect(File(output).existsSync(), isFalse);
  }, skip: _skipWithoutFfmpeg);

  test('a render that drew nothing says that, rather than hanging', () async {
    await expectLater(
      ScenarioFilmEncode(
        directory: frames,
        output: output,
        poll: const Duration(milliseconds: 5),
      ).drain(Future<void>.value()),
      throwsA(
        isA<ActionRefusal>().having(
          (e) => e.message,
          'message',
          contains('drew no frames at all'),
        ),
      ),
    );
  }, skip: _skipWithoutFfmpeg);
}

/// `null` to run, a reason to skip — the encoder is a real process, and a
/// machine without `ffmpeg` should report that rather than fail.
final Object? _skipWithoutFfmpeg = _hasFfmpeg
    ? null
    : 'no `${VideoEncoder.executable}` on PATH';

bool get _hasFfmpeg {
  try {
    return Process.runSync(VideoEncoder.executable, ['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
