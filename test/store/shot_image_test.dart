/// The provider a compose job hands its frame has to survive being resolved
/// twice: once by the `Image` the frame placed, under fake time, and again by
/// the harness's `precacheImage` inside `runAsync`. A provider whose load
/// awaits `dart:io` does not — the first resolve parks it in `FakeAsync`'s
/// microtask queue, which `runAsync` never drains, and the precache waits on
/// that parked completer forever.
///
/// So this is a test about a hang, and it is written the only way a test about
/// a hang can be: on real time, with a bound, asserting the future arrived.
/// `FileImage` in place of the provider under test fails it in three seconds
/// rather than running until somebody kills the process.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// A copy of the harness's `_ShotImage`, which is private to it.
///
/// Copied rather than exported because what is being tested is the *shape* of
/// the load — a synchronous read, no `dart:io` await — and a copy states that
/// shape where a reader can see it. If the two drift, this stops guarding the
/// harness; the harness's own doc comment says so.
class _ShotImage extends ImageProvider<_ShotImage> {
  _ShotImage(this.path) : _stamp = _stampOf(path);

  final String path;
  final String _stamp;

  static String _stampOf(String path) {
    var stat = File(path).statSync();
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  }

  @override
  Future<_ShotImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ShotImage>(this);

  @override
  ImageStreamCompleter loadImage(_ShotImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: path,
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(File(path).readAsBytesSync()),
  );

  @override
  bool operator ==(Object other) =>
      other is _ShotImage && other.path == path && other._stamp == _stamp;

  @override
  int get hashCode => Object.hash(path, _stamp);
}

/// Whether [future] completed within [bound] of *real* time.
///
/// Polling rather than `timeout`, because a `Timer` inside `runAsync` is real
/// but a future that never completes cannot be raced against one that a parked
/// zone would also swallow.
Future<bool> _arrives(
  Future<void> future, {
  Duration bound = const Duration(seconds: 3),
}) async {
  var done = false;
  unawaited(future.then((_) => done = true, onError: (_) => done = true));
  var step = const Duration(milliseconds: 50);
  for (var waited = Duration.zero; waited < bound; waited += step) {
    await Future<void>.delayed(step);
    if (done) return true;
  }
  return false;
}

/// An 8×8 PNG, so the test carries its own picture rather than borrowing one
/// from the docs — what is being measured is when a file is read, not what is
/// in it.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAbUlEQVR4nA3JQQEAMAgDMZzU'
    'CU7qpE5wgoKzgJst31QVKrpwkWKKLa6oEhItLCJGrDj9aNR04ybNNNtc/zAybWxixqw5/wgK'
    'HRwSJmy4/Bg09OAhwww73PxYtPTiJcssu9z+OHT04SPHHHvc8QAxxGhBeBRmJwAAAABJRU5E'
    'rkJggg==';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('flutterware_shot_image');
    path = '${dir.path}/shot.png';
    File(path).writeAsBytesSync(base64Decode(_png));
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('precaches inside runAsync after the tree resolved it', (
    tester,
  ) async {
    // The harness's own order: the frame places an `Image`, which resolves the
    // provider under fake time, and only then does the precache run.
    var provider = _ShotImage(path);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: provider),
      ),
    );

    var arrived = false;
    await tester.runAsync(() async {
      var element = find.byType(Image).evaluate().single;
      arrived = await _arrives(precacheImage(provider, element));
    });

    expect(
      arrived,
      isTrue,
      reason:
          "the precache never returned — the load parked in FakeAsync's "
          'microtask queue, which runAsync does not drain. A provider whose '
          'load awaits dart:io does this; read the file synchronously.',
    );
  });

  testWidgets('reads nothing until something resolves it', (tester) async {
    // The whole point of the laziness: `StoreShot.set` is the entire set, so a
    // provider built for a neighbour no frame paints must not touch the disk.
    var reads = 0;
    var counted = _CountingShotImage(path, () => reads++);
    expect(reads, 0, reason: 'constructing a provider is not a read');

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: counted),
      ),
    );
    await tester.runAsync(
      () => _arrives(
        precacheImage(counted, find.byType(Image).evaluate().single),
      ),
    );
    expect(reads, 1, reason: 'painted once, so read once');
  });
}

class _CountingShotImage extends _ShotImage {
  _CountingShotImage(super.path, this.onRead);

  final VoidCallback onRead;

  @override
  ImageStreamCompleter loadImage(_ShotImage key, ImageDecoderCallback decode) {
    onRead();
    return super.loadImage(key, decode);
  }
}
