/// A compose job whose capture will not decode must fail, not ship.
///
/// The precache the harness runs exists to stop a frame being captured with
/// the app's pixels missing from it. [precacheImage] completes its future
/// whether the decode worked or not, so for as long as nothing read its error
/// the check was only a wait: the job carried on, captured the hole, and the
/// export counted it as a screenshot. This drives the real
/// [composeStoreFrames] to hold the other behaviour in place.
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutterware/src/store/frame_harness.dart';
import 'package:flutterware/store.dart';

/// The smallest frame there is: the app's own pixels, nothing around them.
class _BareFrame extends StoreFrame {
  const _BareFrame(super.shot);

  @override
  Widget build(BuildContext context) => Image(image: shot.image);
}

/// An 8×8 PNG — a capture that decodes, to sit beside one that does not.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAbUlEQVR4nA3JQQEAMAgDMZzU'
    'CU7qpE5wgoKzgJst31QVKrpwkWKKLa6oEhItLCJGrDj9aNR04ybNNNtc/zAybWxixqw5/wgK'
    'HRwSJmy4/Bg09OAhwww73PxYtPTiJcssu9z+OHT04SPHHHvc8QAxxGhBeBRmJwAAAABJRU5E'
    'rkJggg==';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('flutterware_compose'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// One job per entry of [images], each named for its file.
  String manifestFor(List<String> images) {
    var path = '${dir.path}/frames.json';
    File(path).writeAsStringSync(
      jsonEncode([
        for (var (index, image) in images.indexed)
          {
            'image': '${dir.path}/$image',
            'set': [for (var it in images) '${dir.path}/$it'],
            'out': '${dir.path}/out/$image',
            'slug': image.split('.').first,
            'index': index + 1,
            'total': images.length,
            'locale': 'en',
            'device': 'iphone-13',
            'canvasWidth': 108,
            'canvasHeight': 216,
            'canvasRatio': 1.0,
          },
      ]),
    );
    return path;
  }

  void writeGood(String name) =>
      File('${dir.path}/$name').writeAsBytesSync(base64Decode(_png));

  void writeBad(String name) =>
      File('${dir.path}/$name').writeAsStringSync('this is not a PNG');

  test('a capture that will not decode is reported, not written', () async {
    writeBad('01-broken.png');

    var result = await composeStoreFrames(
      _BareFrame.new,
      manifest: manifestFor(['01-broken.png']),
    );

    expect(
      result['written'],
      isEmpty,
      reason: 'a frame composed around a hole must not reach the tree',
    );
    expect(File('${dir.path}/out/01-broken.png').existsSync(), isFalse);
    expect(
      result['failures'],
      containsPair('01-broken', contains('unreadable capture')),
    );
    // The path, so a person reading the failure knows which capture to look at
    // — the binding's own account of this is "Multiple exceptions (2) were
    // detected", which names no file at all.
    expect(result['failures'], containsPair('01-broken', contains('.png')));
  });

  test('a capture that is not there is reported the same way', () async {
    // Not a separate branch in the harness, and this is what says so: a read
    // that throws and a decode that throws leave by the same door.
    var result = await composeStoreFrames(
      _BareFrame.new,
      manifest: manifestFor(['01-absent.png']),
    );

    expect(result['written'], isEmpty);
    expect(
      result['failures'],
      containsPair('01-absent', contains('unreadable capture')),
    );
  });

  test('one bad capture does not take the good ones with it', () async {
    writeGood('01-fine.png');
    writeBad('02-broken.png');
    writeGood('03-fine.png');

    var result = await composeStoreFrames(
      _BareFrame.new,
      manifest: manifestFor(['01-fine.png', '02-broken.png', '03-fine.png']),
    );

    expect(result['written'], [
      '${dir.path}/out/01-fine.png',
      '${dir.path}/out/03-fine.png',
    ]);
    expect((result['failures']! as Map).keys, ['02-broken']);
  });

  test('a set that decodes reports no failures at all', () async {
    writeGood('01-fine.png');

    var result = await composeStoreFrames(
      _BareFrame.new,
      manifest: manifestFor(['01-fine.png']),
    );

    expect(result['written'], ['${dir.path}/out/01-fine.png']);
    expect(result.containsKey('failures'), isFalse);
  });
}
