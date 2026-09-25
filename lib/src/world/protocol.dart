/// The wire between a world script and whoever opened it — the studio, `fw`
/// or the MCP server, all through the same owner in `flutterware_app`.
///
/// JSON, one object a line, over a unix socket the owner binds before it
/// starts the script and names in the script's environment
/// ([worldSocketVariable]). Not stdout: a world usually hosts its server, and
/// a server prints.
///
/// **The owner asks, the script declares.** The owner sends `open` with the
/// world's knob values; the script runs its body and declares what it makes as
/// it makes it — people, actions, knobs, progress — then says it is `set-up`
/// or has `failed`. Everything after is the owner's: `ready` once every
/// person's app is up, `invoke` and `cancel` for actions, `close` at the end,
/// answered by `closed` once the script's `onClose` callbacks have run.
///
/// Flutter-free and `dart:io`-free, so both halves read it from here.
library;

import 'dart:convert';

import '../devices.dart';
import 'world.dart';

/// Where the owner's socket is, in the script's environment. A script run
/// without it runs on its own, and says what it would have asked for.
const worldSocketVariable = 'FW_WORLD_SOCKET';

/// Bumped when a message changes shape; the owner refuses a script that
/// speaks another.
const worldProtocolVersion = 1;

/// Every message type, both directions.
abstract final class WorldMessage {
  // The script's.
  static const hello = 'hello';
  static const progress = 'progress';
  static const person = 'person';
  static const action = 'action';
  static const knob = 'knob';
  static const setUp = 'set-up';
  static const failed = 'failed';
  static const actionProgress = 'action-progress';
  static const actionEnded = 'action-ended';
  static const closed = 'closed';

  // The owner's.
  static const open = 'open';
  static const ready = 'ready';
  static const invoke = 'invoke';
  static const cancel = 'cancel';
  static const close = 'close';
}

/// One message, as the line it travels as.
String encodeWorldMessage(
  String type, [
  Map<String, Object?> fields = const {},
]) => jsonEncode({'type': type, ...fields});

/// One line back into its fields; `type` is always there.
Map<String, Object?> decodeWorldMessage(String line) {
  var json = jsonDecode(line);
  if (json is! Map || json['type'] is! String) {
    throw FormatException('Not a world message', line);
  }
  return json.cast<String, Object?>();
}

/// [person] as the `person` message carries it.
Map<String, Object?> personToJson(Person person) => {
  'name': person.name,
  'email': ?person.email,
  'phone': ?person.phone,
  'userId': ?person.userId,
  'password': ?person.password,
  if (person.app case var app?)
    'app': {'entrypoint': app.entrypoint, 'knobs': app.knobs},
  'on': switch (person.on) {
    Studio(:var device) => {'kind': 'studio', 'device': deviceToJson(device)},
  },
};

/// The `person` message's fields back into a [Person].
Person personFromJson(Map<String, Object?> json) {
  var app = json['app'] as Map?;
  var on = (json['on'] as Map?)?.cast<String, Object?>() ?? const {};
  return Person(
    json['name']! as String,
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    userId: json['userId'] as String?,
    password: json['password'] as String?,
    app: app == null
        ? null
        : Launch(
            app['entrypoint']! as String,
            knobs: (app['knobs'] as Map? ?? const {}).cast<String, Object?>(),
          ),
    on: switch (on['kind']) {
      'studio' || null => Studio(
        deviceFromJson(
          (on['device'] as Map? ?? const {}).cast<String, Object?>(),
        ),
      ),
      var kind => throw FormatException('No device of the kind $kind'),
    },
  );
}

/// A device by its id when the table has it, and its geometry besides — a
/// `Device(...)` the script made up is not in anybody's table.
Map<String, Object?> deviceToJson(Device device) => {
  'id': device.id,
  'label': device.label,
  'kind': device.kind.name,
  'platform': device.platform.name,
  'width': device.width,
  'height': device.height,
  'pixelRatio': device.pixelRatio,
  'insets': [
    device.insetTop,
    device.insetRight,
    device.insetBottom,
    device.insetLeft,
  ],
};

Device deviceFromJson(Map<String, Object?> json) {
  var id = json['id'] as String? ?? Devices.iphone16.id;
  if (deviceById(id) case var known?) return known;
  var insets = [
    for (var inset in json['insets'] as List? ?? const [0, 0, 0, 0])
      (inset as num).toDouble(),
  ];
  return Device(
    id,
    json['label'] as String? ?? id,
    kind: DeviceKind.values.byName(json['kind'] as String? ?? 'phone'),
    platform: DevicePlatform.values.byName(
      json['platform'] as String? ?? 'ios',
    ),
    group: 'Custom',
    width: (json['width']! as num).toDouble(),
    height: (json['height']! as num).toDouble(),
    pixelRatio: (json['pixelRatio']! as num).toDouble(),
    insetTop: insets[0],
    insetRight: insets[1],
    insetBottom: insets[2],
    insetLeft: insets[3],
  );
}
