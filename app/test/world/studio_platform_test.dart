import 'dart:convert';
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
  late StudioPlatform studio;
  late GuestPlatform platform;

  setUp(() {
    home = Directory.systemTemp.createTempSync('studio_platform');
    studio = StudioPlatform(
      person: 'Ana',
      home: home,
      package: Directory.current.path,
      device: Devices.iphone16,
    );
    platform = studio.platform;
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

  test('a permission is granted once the app asks for it', () async {
    const channel = 'flutter.baseflow.com/permissions/methods';
    const camera = 1;
    expect(await call(channel, 'checkPermissionStatus', camera), 0);
    expect(await call(channel, 'requestPermissions', [camera]), {camera: 1});
    expect(await call(channel, 'checkPermissionStatus', camera), 1);
    expect(await call(channel, 'checkServiceStatus', camera), 1);
  });

  // `flutter/navigation` and `flutter/platform` speak JSON, as the
  // framework's own `SystemChannels` do.
  const json = JSONMethodCodec();

  test('the route an app reports is the address, and back and a typed '
      'address are sent back to it', () async {
    await platform.answer(
      'flutter/navigation',
      _bytes(
        json.encodeMethodCall(
          const MethodCall('routeInformationUpdated', {
            'uri': '/orders/o3',
            'state': null,
            'replace': false,
          }),
        ),
      ),
    );
    expect(studio.navigation.route, '/orders/o3');

    var sent = <MethodCall>[];
    platform.send = (channel, bytes) {
      if (channel == 'flutter/navigation') {
        sent.add(json.decodeMethodCall(ByteData.sublistView(bytes)));
      }
    };
    studio.navigation
      ..back()
      ..go('/orders');
    expect(
      [for (var call in sent) call.method],
      ['popRoute', 'pushRouteInformation'],
    );
    expect((sent.last.arguments as Map)['location'], '/orders');
  });

  test('the title an app gives its window is kept, and every other '
      'platform call is still answered as not implemented', () async {
    await platform.answer(
      'flutter/platform',
      _bytes(
        json.encodeMethodCall(
          const MethodCall('SystemChrome.setApplicationSwitcherDescription', {
            'label': 'Pickup · Counter',
            'primaryColor': 0xFF6F4E37,
          }),
        ),
      ),
    );
    expect(studio.system.title, 'Pickup · Counter');
    expect(studio.system.titleColor, 0xFF6F4E37);
    expect(
      await platform.answer(
        'flutter/platform',
        _bytes(
          json.encodeMethodCall(const MethodCall('HapticFeedback.vibrate')),
        ),
      ),
      isNull,
    );
  });

  test('an app out of sight is hidden, one sent to the background is '
      'paused whatever is drawn, and each state is told once', () {
    var told = <String>[];
    platform.send = (channel, bytes) {
      if (channel == 'flutter/lifecycle') told.add(utf8.decode(bytes));
    };
    var system = studio.system;
    system
      ..drawn = false
      ..drawn = false
      ..drawn = true
      ..inBackground = true
      ..drawn = false
      ..drawn = true
      ..drawn = false
      ..inBackground = false;
    expect(told, [
      'AppLifecycleState.hidden',
      'AppLifecycleState.resumed',
      'AppLifecycleState.paused',
      'AppLifecycleState.hidden',
    ]);
    expect(system.lifecycleState, 'hidden');
  });

  test('the time zone is a zone name', () async {
    expect(
      await call('flutter_timezone', 'getLocalTimezone'),
      matches(RegExp(r'^[A-Za-z_]+(/[A-Za-z_+\-0-9]+)*$')),
    );
  });
}

Uint8List _bytes(ByteData data) =>
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
