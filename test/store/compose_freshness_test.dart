/// A compose must see the capture that is on disk now, not the one that was
/// there last time.
///
/// The guest that composes is kept warm on purpose, `flutter_test` never
/// clears `PaintingBinding.imageCache`, and an export's capture paths are
/// fully deterministic — so a provider keyed on path alone hands the image
/// cache a key it has seen before and gets back the previous export's decode.
/// Two composes over one path, with the bytes replaced in between, is the
/// whole of the reproduction, and it is what these tests are.
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/store/frame_harness.dart';
import 'package:flutterware/store.dart';

/// The app's own pixels, nothing around them — so the output is the capture.
class _BareFrame extends StoreFrame {
  const _BareFrame(super.shot);

  @override
  Widget build(BuildContext context) => Image(image: shot.image);
}

/// Every shot of the set, side by side — a frame that reaches for its
/// neighbours, which is what makes one decode worth sharing between jobs.
class _PanoramaFrame extends StoreFrame {
  const _PanoramaFrame(super.shot);

  @override
  Widget build(BuildContext context) => Row(
    children: [for (var it in shot.set) Flexible(child: Image(image: it))],
  );
}

/// Two 8×8 PNGs of one flat colour each, and one file that is not a PNG at
/// all. Same size on disk for the two good ones is deliberate: it leaves the
/// mtime as the only thing telling them apart.
const _red =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQS'
    'ACj/P8Fu7N9hAAAAAElFTkSuQmCC';
const _blue =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEElEQVR4nGNgYPiPAw0pCQCp'
    'cD/BFMrqcwAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String capture;
  late String out;
  late String manifest;

  setUp(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    dir = Directory.systemTemp.createTempSync('flutterware_freshness');
    // Shaped like the real thing: an export's scratch is
    // `<output>/.store/capture/<store>-<class>-<locales>/NN-slug.png`, which
    // carries nothing that changes between runs.
    capture = '${dir.path}/01-welcome.png';
    out = '${dir.path}/out/01-welcome.png';
    manifest = '${dir.path}/frames.json';
    File(manifest).writeAsStringSync(
      jsonEncode([
        {
          'image': capture,
          'set': [capture],
          'out': out,
          'slug': 'welcome',
          'index': 1,
          'total': 1,
          'locale': 'en',
          'device': 'iphone-13',
          'canvasWidth': 40,
          'canvasHeight': 40,
          'canvasRatio': 1.0,
        },
      ]),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<Map<String, Object?>> compose() =>
      composeStoreFrames(_BareFrame.new, manifest: manifest);

  void write(String base64) =>
      File(capture).writeAsBytesSync(base64Decode(base64));

  test('a rewritten capture composes as itself, not as last time', () async {
    write(_red);
    await compose();
    var first = File(out).readAsBytesSync();

    // The developer changes the app and exports again: pass one overwrites the
    // same path, pass two composes from it.
    write(_blue);
    await compose();

    expect(
      File(out).readAsBytesSync(),
      isNot(first),
      reason:
          "the second compose shipped the first run's pixels — the image "
          'cache answered a key it had seen before',
    );
  });

  test('a capture that was fixed composes on the next run', () async {
    File(capture).writeAsStringSync('this is not a PNG');
    expect((await compose())['failures'], isNotEmpty);

    write(_red);
    var fixed = await compose();

    expect(
      fixed['written'],
      [out],
      reason:
          'the failed decode was cached under the same key, so the capture '
          'stayed broken however often it was fixed',
    );
    expect(fixed.containsKey('failures'), isFalse);
  });

  test('an unchanged capture is decoded once for the whole set', () async {
    // The other half of the trade. Two jobs, and a frame that paints both
    // shots in each of them — four resolutions of two files. The stamp must
    // not defeat the image cache for those, or the laziness has bought a
    // read per painting instead of a read per file.
    write(_red);
    var second = '${dir.path}/02-menu.png';
    File(second).writeAsBytesSync(base64Decode(_blue));
    File(manifest).writeAsStringSync(
      jsonEncode([
        for (var (index, image) in [capture, second].indexed)
          {
            'image': image,
            'set': [capture, second],
            'out': '${dir.path}/out/0${index + 1}.png',
            'slug': 'shot-${index + 1}',
            'index': index + 1,
            'total': 2,
            'locale': 'en',
            'device': 'iphone-13',
            'canvasWidth': 40,
            'canvasHeight': 40,
            'canvasRatio': 1.0,
          },
      ]),
    );

    var result = await composeStoreFrames(
      _PanoramaFrame.new,
      manifest: manifest,
    );
    expect(result['written'], hasLength(2));
    expect(result.containsKey('failures'), isFalse);
    expect(
      PaintingBinding.instance.imageCache.currentSize,
      2,
      reason: 'two files painted four times must be two entries, not four',
    );
  });
}
