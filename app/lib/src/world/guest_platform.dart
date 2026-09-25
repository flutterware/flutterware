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

  /// Channels the app used that nothing here answers.
  final unanswered = <String>{};

  /// Answers one message from the app. Null is "no implementation".
  Future<Uint8List?> answer(String channel, Uint8List bytes) async {
    _asked.add(channel);
    var handler = _channels[channel];
    if (handler == null) {
      unanswered.add(channel);
      return null;
    }
    return handler(bytes);
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
