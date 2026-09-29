import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:standard_message_codec/standard_message_codec.dart';

/// One person's platform, as the studio answers it for their guest — phase 3
/// of the worlds guest experiment: can the studio stand in for the platform a
/// plugin's native half would have run on
/// (`docs/superpowers/specs/2026-09-25-worlds-guest-experiment-plan.md`).
///
/// A guest started with `FW_FORWARD_PLATFORM=1` hands every platform message
/// to its studio, and this answers them by channel. The plugins' own Dart code
/// runs unchanged in the guest — registered as `flutter run` would register it
/// — and speaks to this as it would to its Swift half. What each plugin needs
/// is in `platform/`, a file each, so what one costs can be counted.
///
/// Flutter-free on purpose: a world `fw` opens answers with the same code
/// the studio does. The codecs are the standard ones, written against
/// `package:standard_message_codec`.
class GuestPlatform {
  GuestPlatform({required this.person, required this.home});

  final String person;

  /// This person's own directory, which keeps two people's state apart
  /// without the app knowing there are two.
  final Directory home;

  /// Sends a message into the app; wired by whoever owns the guest.
  void Function(String channel, Uint8List bytes)? send;

  final _channels = <String, Future<Uint8List?> Function(Uint8List)>{};
  final _asked = <String>{};

  /// Every channel the app has used, answered or not — what a run says the
  /// app reached for.
  Set<String> get asked => _asked;

  /// The plugins' channels the app used that nothing here answers, each with
  /// the method it asked first: a call that failed in the app, as it would on
  /// a platform the plugin has no implementation for.
  ///
  /// Answering them is the project's, not the studio's — a fake in the entry
  /// point the world starts. A channel under `flutter/` is left out: it is
  /// the framework's own, and nothing a project could fake.
  final unanswered = <String, String?>{};

  /// Called the first time the app uses a channel [unanswered] then holds.
  void Function(String channel, String? method)? onUnanswered;

  /// Answers one message from the app. Null is "no implementation".
  Future<Uint8List?> answer(String channel, Uint8List bytes) async {
    _asked.add(channel);
    var handler = _channels[channel];
    if (handler == null) {
      if (!channel.startsWith('flutter/') && !unanswered.containsKey(channel)) {
        var method = unanswered[channel] = _methodOf(channel, bytes);
        onUnanswered?.call(channel, method);
      }
      return null;
    }
    return handler(bytes);
  }

  /// The method a message on [channel] calls, when it is a method call: a
  /// Pigeon channel names its method itself, and a message that is not a
  /// method call — a basic message channel's — has none.
  static String? _methodOf(String channel, Uint8List bytes) {
    if (channel.startsWith(_pigeon)) return null;
    try {
      return standardMethods.decodeCall(bytes).$1;
    } on Object {
      return null;
    }
  }

  static const _pigeon = 'dev.flutter.pigeon.';

  /// A channel [unanswered] holds, as a person reads it: a Pigeon channel's
  /// package and method — `camera_avfoundation: CameraApi.create` — or the
  /// channel and the method it was asked.
  static String describe(String channel, String? method) {
    if (channel.startsWith(_pigeon)) {
      var name = channel.substring(_pigeon.length);
      var dot = name.indexOf('.');
      if (dot > 0) {
        return '${name.substring(0, dot)}: ${name.substring(dot + 1)}';
      }
    }
    return method == null ? channel : '$channel ($method)';
  }

  /// A method channel with the standard method codec — how most plugins that
  /// predate Pigeon talk to their native half.
  void methods(
    String channel,
    Map<String, FutureOr<Object?> Function(Object? arguments)> methods,
  ) {
    _channels[channel] = (bytes) async {
      var (method, arguments) = standardMethods.decodeCall(bytes);
      var handle = methods[method];
      if (handle == null) return null;
      try {
        return standardMethods.success(await handle(arguments));
      } on GuestPlatformError catch (e) {
        return standardMethods.error(e.code, e.message);
      }
    };
  }

  /// A channel answered in its own terms, for a codec neither of the others
  /// speaks — `flutter/navigation` is JSON. [handler] is given the message's
  /// bytes and returns the reply's.
  void bytes(
    String channel,
    Future<Uint8List?> Function(Uint8List message) handler,
  ) => _channels[channel] = handler;

  /// A Pigeon API: one channel per method, `<api>.<method>`, arguments as a
  /// list, the result in a one-element list. [codec] is the API's own, for
  /// the classes and enums it declares.
  void pigeon(
    String api,
    Map<String, FutureOr<Object?> Function(List<Object?> arguments)> methods, {
    PigeonCodec codec = const PigeonCodec(),
  }) {
    for (var MapEntry(key: name, value: handle) in methods.entries) {
      _channels['$api.$name'] = (bytes) async {
        // A method with no parameters sends no message at all, which reaches
        // here as no bytes — not an encoded null.
        var arguments = bytes.isEmpty
            ? const <Object?>[]
            : codec.decodeMessage(ByteData.sublistView(bytes)) as List? ?? [];
        try {
          return _bytes(codec.encodeMessage([await handle(arguments)]));
        } on GuestPlatformError catch (e) {
          return _bytes(codec.encodeMessage([e.code, e.message, null]));
        }
      };
    }
  }

  /// Sends [event] on an event channel the app is listening to, as the
  /// platform side of an `EventChannel` does.
  void emit(String channel, Object? event) =>
      send?.call(channel, standardMethods.success(event));

  /// Calls [method] on a channel the app handles calls on — a notification
  /// tapped, answered by nobody.
  void call(String channel, String method, [Object? arguments]) =>
      send?.call(channel, standardMethods.encodeCall(method, arguments));

  /// A raw message on [channel] — `flutter/lifecycle` takes a string.
  void raw(String channel, Uint8List bytes) => send?.call(channel, bytes);
}

/// A failure to report to the app as a `PlatformException`.
class GuestPlatformError implements Exception {
  GuestPlatformError(this.code, [this.message]);

  final String code;
  final String? message;
}

/// `StandardMethodCodec`'s wire format, over `StandardMessageCodec`.
const standardMethods = _StandardMethods();

class _StandardMethods {
  const _StandardMethods();

  static const _codec = StandardMessageCodec();

  (String, Object?) decodeCall(Uint8List bytes) {
    var buffer = ReadBuffer(ByteData.sublistView(bytes));
    var method = _codec.readValue(buffer)! as String;
    var arguments = _codec.readValue(buffer);
    return (method, arguments);
  }

  Uint8List encodeCall(String method, Object? arguments) {
    var buffer = WriteBuffer();
    _codec.writeValue(buffer, method);
    _codec.writeValue(buffer, arguments);
    return _bytes(buffer.done())!;
  }

  Uint8List success(Object? result) {
    var buffer = WriteBuffer()..putUint8(0);
    _codec.writeValue(buffer, result);
    return _bytes(buffer.done())!;
  }

  Uint8List error(String code, String? message) {
    var buffer = WriteBuffer()..putUint8(1);
    _codec.writeValue(buffer, code);
    _codec.writeValue(buffer, message);
    _codec.writeValue(buffer, null);
    return _bytes(buffer.done())!;
  }
}

/// A value of a type a Pigeon API declares: its tag, and the list — or, for
/// an enum, the index — it is written as.
class PigeonValue {
  const PigeonValue(this.type, this.value);

  final int type;
  final Object? value;

  @override
  String toString() => 'PigeonValue($type, $value)';
}

/// A Pigeon API's codec without the API: every declared type — tag 129 and
/// up — reads as a [PigeonValue], and a [PigeonValue] writes back as one.
/// Enough for the studio to answer an API it never imported.
class PigeonCodec extends StandardMessageCodec {
  const PigeonCodec();

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is PigeonValue) {
      buffer.putUint8(value.type);
      writeValue(buffer, value.value);
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) => type >= 129
      ? PigeonValue(type, readValue(buffer))
      : super.readValueOfType(type, buffer);
}

Uint8List? _bytes(ByteData? data) =>
    data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
