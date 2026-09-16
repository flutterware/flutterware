import 'dart:io';
import 'dart:typed_data';

import 'package:flutterware_app/src/comparison/shot_cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late ShotCache cache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fw_shot_adopt');
    cache = ShotCache(p.join(temp.path, 'shots'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  // A renderer's frame is megabytes, and nothing reads it after the cache has
  // it: moving it costs a rename where filing its bytes costs a read and a
  // write.
  test('a frame on disk is filed by moving it, and reads back whole', () {
    var bytes = Uint8List.fromList(List.generate(64, (i) => i));
    var frame = File(p.join(temp.path, 'frame.raw'))..writeAsBytesSync(bytes);

    cache.adoptFile(
      'abc123',
      frame.path,
      ShotRecord(format: 'raw', width: 4, height: 4, entryId: 'demo#card'),
    );

    expect(frame.existsSync(), isFalse);
    expect(cache.has('abc123'), isTrue);
    expect(cache.read('abc123'), bytes);
    expect(cache.meta('abc123')!.entryId, 'demo#card');
  });
}
