import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutterware/flutter_test.dart';

/// A 1×1 red PNG, the smallest image `Image.network` decodes.
final _redPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, //
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

final _shots = Directory.systemTemp.createTempSync('live_capture');

void main() {
  ScenarioTester.screenshotsDestinationOverride = _shots.path;

  scenario('a network image lands inside the step that mounts it', (s) async {
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(_redPng)
        ..close();
    });
    addTearDown(() => server.close(force: true));

    var loaded = false;
    await s.pumpWidget(
      MaterialApp(
        home: Image.network(
          'http://127.0.0.1:${server.port}/red.png',
          frameBuilder: (context, child, frame, sync) {
            if (frame != null) loaded = true;
            return child;
          },
        ),
      ),
    );
    expect(loaded, isTrue, reason: 'the step waited for the real decode');
  });

  scenario('a capture at a phone size is not blank', (s) async {
    await s.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: Text('red')),
          body: ColoredBox(color: Colors.red),
        ),
      ),
    );
    await s.screen('red');
  });

  test('the phone-size capture has more than one colour', () async {
    var pngs = _shots
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('red.png'))
        .toList();
    expect(pngs, hasLength(1), reason: 'the screen was written once');
    var decoded = await decodeImageFromList(pngs.single.readAsBytesSync());
    var bytes = await decoded.toByteData();
    var colours = <int>{};
    for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
      colours.add(bytes.getUint32(i));
    }
    expect(
      colours.length,
      greaterThan(1),
      reason:
          'a red body under an app bar is at least two colours; one colour '
          'means the layer raster came back blank',
    );
  });
}
