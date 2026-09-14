import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/comparison/previews_side.dart';

/// The note a row carries when a side's frame was refused for having work in
/// flight. It is the only place the reader learns why that side has no
/// picture, so it names the work the way the app labelled it.
void main() {
  test('names each tracked load by its label', () {
    expect(
      PreviewsSide.stillWaiting({
        'tracked': ['3D model', 'fonts'],
      }),
      'still waiting on `3D model`, `fonts` when it was captured',
    );
  });

  test('counts what the framework was still decoding and reading', () {
    expect(
      PreviewsSide.stillWaiting({'images': 1, 'assets': 2}),
      'still waiting on 1 image decode, 2 asset reads when it was captured',
    );
  });

  test('still says something for a field it does not know', () {
    expect(
      PreviewsSide.stillWaiting({'shaders': 1}),
      'still waiting on work it announced when it was captured',
    );
  });
}
