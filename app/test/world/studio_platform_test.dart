import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/devices.dart';
import 'package:flutterware_app/src/world/guest_platform.dart';
import 'package:flutterware_app/src/world/platform/studio_platform.dart';

/// The studio's answers, asked the way each plugin's Dart half asks — through
/// the framework's own codecs, so a wire mistake here is one a real app would
/// hit.
void main() {
  late Directory home;
  late GuestPlatform platform;

  setUp(() {
    home = Directory.systemTemp.createTempSync('studio_platform');
    platform = StudioPlatform(
      person: 'Ana',
      home: home,
      package: Directory.current.path,
      device: Devices.iphone16,
    ).platform;
  });

  tearDown(() => home.deleteSync(recursive: true));

  Future<Object?> call(
    String channel,
    String method, [
    Object? arguments,
  ]) async {
    const codec = StandardMethodCodec();
    var reply = await platform.answer(
      channel,
      _bytes(codec.encodeMethodCall(MethodCall(method, arguments))),
    );
    return codec.decodeEnvelope(ByteData.sublistView(reply!));
  }

  const firebase = 'dev.flutter.pigeon.firebase_core_platform_interface';

  test('a Pigeon method with no parameters is answered', () async {
    // Such a method sends no message at all: no bytes, not an encoded null.
    var reply = await platform.answer(
      '$firebase.FirebaseCoreHostApi.initializeCore',
      Uint8List(0),
    );
    expect(const PigeonCodec().decodeMessage(ByteData.sublistView(reply!)), [
      <Object?>[],
    ]);
  });

  test('Firebase starts with the options the app passed', () async {
    const codec = PigeonCodec();
    var options = const PigeonValue(129, ['key', 'app', 'sender', 'project']);
    var reply = await platform.answer(
      '$firebase.FirebaseCoreHostApi.initializeApp',
      _bytes(codec.encodeMessage(['[DEFAULT]', options])!),
    );
    var [response as PigeonValue] =
        codec.decodeMessage(ByteData.sublistView(reply!))! as List;
    expect(response.type, 130);
    var [name, echoed, _, _] = response.value! as List;
    expect(name, '[DEFAULT]');
    expect((echoed! as PigeonValue).value, options.value);

    var core = await platform.answer(
      '$firebase.FirebaseCoreHostApi.initializeCore',
      Uint8List(0),
    );
    expect(
      (codec.decodeMessage(ByteData.sublistView(core!))! as List).single,
      hasLength(1),
    );
  });

  test(
    'device info describes the device, for an iOS or a macOS parser',
    () async {
      var info = await call(
        'dev.fluttercommunity.plus/device_info',
        'getDeviceInfo',
      );
      if (info is! Map) fail('no map: $info');
      // What each of device_info_plus's parsers requires.
      for (var key in [
        'name', 'systemName', 'systemVersion', 'model', 'modelName', //
        'localizedModel', 'isPhysicalDevice', 'utsname', 'freeDiskSize',
        'computerName', 'hostName', 'arch', 'kernelVersion', 'osRelease',
        'majorVersion', 'activeCPUs', 'memorySize', 'systemGUID',
      ]) {
        expect(info[key], isNotNull, reason: key);
      }
      expect(info['modelName'], 'iPhone 16');
      expect(info['isPhysicalDevice'], isFalse);
    },
  );

  test('the time zone is a zone name', () async {
    expect(
      await call('flutter_timezone', 'getLocalTimezone'),
      matches(RegExp(r'^[A-Za-z_]+(/[A-Za-z_+\-0-9]+)*$')),
    );
  });
}

Uint8List _bytes(ByteData data) =>
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
