/// Worlds: several people on your real server, set up by a script.
///
/// **Experimental.** This library can change in any release while worlds are
/// being built, and a world opens only on macOS for now. The guide is
/// `doc/worlds.md` in flutterware's repository.
///
/// A world is one Dart file in the package that can start your server and
/// seed it — for a Dart server, the server's own — declared in
/// `tool/flutterware.dart` with `WorldScript(...)`. Opening it runs the file
/// there: it brings the server up, makes fresh users through the
/// server's own API, and declares the [Person]s who use it, each with an app.
/// flutterware launches their apps — in the studio's embedded guest by
/// default — signed in as whoever the script made.
///
/// ```dart
/// // server/tool/worlds/pickup_order.dart
/// import 'package:flutterware/world.dart';
///
/// /// A barista and a regular who has never used the app.
/// void main(List<String> args) => World.run(args, (w) async {
///   var server = await startServer(port: await w.freePort());
///   w.onClose(server.close);
///
///   // New every opening: the world's id, in the names the server gets.
///   var ana = await server.admin.createStaff('ana.${w.id}@example.com');
///   w.person(
///     'Ana',
///     email: ana.email,
///     app: Launch('Shop', knobs: {'server': '${server.url}', 'session': ana.token}),
///     on: Studio(Devices.iPad),
///   );
///   // A number your server accepts: its rule, so your helper.
///   w.person('Leo', phone: testPhone(w.id), app: Launch('Shop', knobs: {'server': '${server.url}'}));
/// });
/// ```
///
/// Pure Dart: a server package can depend on it without Flutter in its
/// build, the bargain `package:flutterware/server.dart` already makes. The
/// design is `docs/superpowers/specs/2026-09-25-worlds-design.md` in
/// flutterware's repository.
library;

export 'src/devices.dart' show Device, DeviceKind, DevicePlatform, Devices;
export 'src/world/world.dart'
    show ActionRun, Launch, Person, Studio, World, WorldDevice;
