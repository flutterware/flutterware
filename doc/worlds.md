# Worlds

Several people on your real server at once, each with their own app, set up
by a script: a barista and a customer, an admin and the colleague they
invite. Open the world, and every person's app starts signed in as a user the
script just made, side by side in the studio.

> **Experimental, and macOS only.** Worlds are new. `package:flutterware/world.dart`
> can change in any release, and a world opens only on a Mac for now.

## Turn it on

A world is a Dart file in the package that can start your server and create
users on it. For a Dart server, that's the server's own package, which then
depends on `flutterware`. Declare the file in `tool/flutterware.dart`:

```dart
// tool/flutterware.dart
const server = Pkg('server');

fw.use(
  Worlds(
    packages: [
      WorldsPackage(
        server,
        worlds: [
          WorldScript(
            'tool/worlds/pickup_order.dart',
            name: 'Pickup order',
            description: 'A barista and a regular',
          ),
        ],
      ),
    ],
  ),
);
```

A world is opened by its file name, `pickup_order`, so two worlds can't share
one. The people's apps are [Run](run.md) entry points, named the way `Run`
declares them.

## Write a world

```dart
// server/tool/worlds/pickup_order.dart
import 'package:flutterware/world.dart';

void main(List<String> args) => World.run(args, (w) async {
  var server = await startServer(port: await w.freePort());
  w.onClose(server.close);

  var ana = await server.createStaff(email: w.email('ana'));
  w.person(
    'Ana',
    email: ana.email,
    app: Launch('Shop', knobs: {'server': '${server.url}', 'session': ana.token}),
  );

  // Leo has never used the app: he signs up with this number himself.
  w.person(
    'Leo',
    phone: w.phone(),
    app: Launch('Shop', knobs: {'server': '${server.url}'}),
  );

  w.action('A walk-in orders a flat white', (run) async {
    await server.placeOrder('Flat white');
  });
});
```

`startServer`, `createStaff` and `placeOrder` stand for your own code: the
script starts your server (or points at one already running) and makes its
users through your server's API.

- **Everything is new each time.** `w.email('ana')` and
  `w.unique('Canal Street')` carry an id made every time the world opens, so
  a world never trips over the users it made the last time. `w.phone()` draws
  from a thousand numbers reserved for fiction, which a server that keeps its
  users may already know.
- **A person starts signed in through their app's knobs.** `Launch` names an
  entry point and the [knobs](run.md#knobs) its `main` is called with. A
  session token, a server URL or a starting page are all knobs.
- **`on:` picks the device**: `Studio(Devices.iPad)` for a tablet. The default
  is an iPhone 16.
- **`w.knob('Leo', options: ['signed out', 'signed in'], initial: 'signed out')`**
  is a choice the world opens with, and answers the one it was opened with.
  Changing it restarts the world.
- **`w.action(...)`** is a button on the open world, for something that
  happens to it while you watch: a customer with no app places an order.
- **`w.onClose(...)`** runs when the world closes or restarts, last one first.
  `w.progress('Seeding the menu')` says what the script is doing while the
  world opens.

Whatever the script prints shows in the world's log. Run the file on its own
to debug its setup without launching any app: it prints what it declares, and
`name=value` arguments set its knobs.

```shell
cd server && dart run tool/worlds/pickup_order.dart 'Leo=signed in'
```

## Open it

In the studio, **Worlds** lists the worlds you declared. **Open** runs the
script and starts every person's app, side by side, with the world's knobs
as pickers and its actions as buttons. **Restart** runs the script again for
new people and restarts each app in place, which takes a few seconds and
rebuilds nothing. **Close** stops everything.

From the command line, the world lives as long as the command does:

```shell
fw run worlds list
fw run worlds open --world=pickup_order --hold=true   # Ctrl-C closes it
```

Each person's app is a Run app on the device `studio-<name>`: an agent opens a
world with `flutterware_invoke` and drives Leo's app with `flutterware_act`
and `device: "studio-leo"`, with the same verbs as any other app.

A world belongs to the process that opened it (the studio, `fw` or the MCP
server), and a checkout has one world open at a time.

## What an app can use in a world

Each person's app runs in the studio's embedded guest, not on a simulator, so
opening a world builds nothing native. The app's plugins run their own Dart
code, and the studio answers what they ask of the platform:

- `shared_preferences`, `flutter_secure_storage` and `path_provider`, kept
  apart per person, so two people never share a session;
- `package_info_plus`, `device_info_plus` (the person's device), and
  `flutter_timezone`;
- `firebase_core`;
- `app_links`, `url_launcher` and `flutter_local_notifications`: beside each
  person, the studio lists the notifications their app showed and the URLs it
  opened, and can open a link in it.

HTTP, WebSockets and native libraries built by build hooks, such as
`sqlite3`, work as they do in the app. A plugin the studio doesn't answer
behaves as on a platform it has no implementation for: its calls throw.
Cameras, maps and web views aren't available.

In a guest, `dart:io`'s `Platform` says macOS whatever the person's device,
while `Theme.of(context).platform` follows the device. An app that picks a
code path with `Platform.isIOS` takes its macOS path in a world.

## Reference

[`flutterware.worlds` in the capabilities reference](../docs/capabilities.md#flutterwareworlds).
