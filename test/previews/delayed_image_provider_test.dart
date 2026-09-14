import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/flutter_test.dart';

/// An image provider that sleeps before it decodes is drawn loaded.
///
/// The image cache counts it as pending from the moment it starts sleeping,
/// and the sleep is on the fake clock. The settle used to wait for that count
/// in real time between its frames: the clock stood still for the whole
/// allowance, the timer could not fire, and by the time the frames had moved
/// the clock the allowance was gone and nothing turned the real loop for the
/// decode. The entry was photographed on its placeholder, and — once a still
/// said what it was still waiting on — refused by every comparison.
///
/// Measured on a consumer's catalog: a blur-hash demo whose images load after
/// a simulated second, refused on every run.
void main() {
  var drawn = false;

  runPreviewHarness([
    PreviewEntry(
      id: 'demo/delayed_image.dart#delayedImage',
      path: 'demo/delayed_image.dart',
      name: 'Delayed image',
      build: () => Directionality(
        textDirection: TextDirection.ltr,
        child: Image(
          image: _SleepsBeforeDecoding(_onePixel),
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame != null) drawn = true;
            return child;
          },
        ),
      ),
    ),
  ]);

  // Declared after the entry, so it runs after it.
  test('an image whose provider sleeps before it decodes is drawn', () {
    expect(drawn, isTrue);
  });
}

/// A 1×1 BMP.
final _onePixel = Uint8List.fromList([
  0x42, 0x4D, 0x3A, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, //
  0x28, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0x18, 0, //
  0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0x80, 0, 0,
]);

class _SleepsBeforeDecoding extends ImageProvider<_SleepsBeforeDecoding> {
  _SleepsBeforeDecoding(this.bytes);

  final Uint8List bytes;

  @override
  Future<_SleepsBeforeDecoding> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _SleepsBeforeDecoding key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
}
