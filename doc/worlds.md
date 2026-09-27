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

  var ana = await server.createStaff(email: 'ana.${w.id}@example.com');
  w.person(
    'Ana',
    email: ana.email,
    app: Launch('Shop', knobs: {'server': '${server.url}', 'session': ana.token}),
  );

  // Leo has never used the app: he signs up with this number himself.
  w.person(
    'Leo',
    phone: newPhone(), // a number your server accepts; see below
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

- **Everything is new each time.** `w.id` is made every time the world opens
  or restarts. Fold it into the emails, names and numbers the script makes —
  `'ana.${w.id}@example.com'`, `'Canal Street ${w.id}'` — and a world never
  trips over the users it made the last time. What a valid address or phone
  number looks like is your server's rule, so the script writes them, a line
  each; flutterware makes none up. Hand them to `w.person(email:, phone:)` so
  the studio shows them beside the person.
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
new people and starts each app afresh, in an emptied home, so nothing of the
last people opens as the new ones; it takes about a second and rebuilds
nothing. **Close** stops everything.

From the command line, the world lives as long as the command does:

```shell
fw run worlds list
fw run worlds open --world=pickup_order --hold=true   # Ctrl-C closes it
```

Each person's app is a Run app on the device `studio-<name>`: an agent opens a
world with `flutterware_invoke` and drives Leo's app with `flutterware_act`
and `device: "studio-leo"`, with the same verbs as any other app.

A world belongs to the process that opened it (the studio, `fw` or the MCP
server), and a checkout has one world open at a time. Every other process can
still reach it: `fw run worlds status`, `trace`, `invoke`, `restart` and
`close` are answered by the process that owns it, so an agent can run an
action on the world you opened in the studio, or close one it left held in a
terminal.

## See what a tap caused

Every tap on a person's app, yours or an agent's, is a **step**, named after
its person: `leo.2`. The world follows each one through the system:

```shell
fw run worlds trace --person=Leo
```

```json
{
  "step": "leo.2",
  "person": "Leo",
  "at": "2026-09-26T22:46:13.594",
  "did": "tap \"Sign in\"",
  "then": [
    "+1 ms  Leo → lab  POST /auth/verify  200 in 0.4 ms",
    "+4 ms  Leo → lab  GET /me  200 in 0.3 ms",
    "+4 ms  lab  knows Leo as u2",
    "+6 ms  Leo → lab  GET /orders  200 in 0.5 ms"
  ]
}
```

Every request an app sends carries its step in an `x-fw-step` header. A Dart
server takes part with one line in its [inspection
adapter](server_inspection.md), putting the header in the zone beside the
request id:

```dart
zoneValues: {
  FlutterwareServer.requestIdKey: id,
  FlutterwareServer.stepKey: ?request.headers['x-fw-step'],
},
```

Everything the server reports under that request then carries the step: its
writes, the messages it sent and who they reached. Two calls say what only
the server knows: `FlutterwareServer.identify(user.id)` once auth knows who
the request is, so the world can tell whose a user is even when they signed
up themselves, and `FlutterwareServer.reach(userId, what)` when it pushes
something down a connection, such as a WebSocket frame.

The world's own actions are steps too, named `world.1`, `world.2`: every
request an action sends carries its step, so what *Mia orders a flat white*
caused is traced the same way, and `fw run worlds invoke` answers with the
step it ran as. `--person=world` lists only those.

An app that keeps its data in a synced database follows its records instead:
with `sync: DatabaseSync.powersync` on its [Database watch](database_watch.md)
adapter, a record written on one phone is traced to the others as it
arrives, and each person's sync state shows beside their phone and in
`worlds status`.

## Hand a message to a person

What a server sends outside — an SMS, a push, a mail — reaches its person
through the world. Each person's drawer opens on the messages sent to them:
**Type it** puts a code into the field that has focus in their app, as an
autofill would, and **Open** or **Tap it** opens a message's link in their
app. Tap the field the code goes in first.

```shell
fw run worlds outbox --person=Leo
fw run worlds deliver --message=lab/10
```

A server takes part by reporting each message with its recipient, in its
adapter for that edge:

```dart
FlutterwareServer.event('sms', {'to': phone, 'body': body});
FlutterwareServer.event('push', {'to': userId, 'title': title, 'link': ?link});
FlutterwareServer.event('mail', {'to': address, 'subject': subject, 'text': text, 'html': html});
```

The world finds the person by the phone number, user id or address it was
declared with, or learnt through `FlutterwareServer.identify`.

A mail with `html` is read as its recipient would see it: **Read it** opens
it as a picture WebKit draws, with each link clickable where it sits, and
**Page** shows the page itself, live. A link to the app opens in the
person's app; a web link opens in the page; every link is listed beneath
with **Open in Leo's app** too. `fw run worlds show --message=<id>` draws the
picture for an agent to read, with each link's box, and
`fw run worlds deliver --message=<id> --link=<link>` opens a chosen link.
Drawing needs the Xcode command line tools, as the native layer does: the
helper is compiled on first use.

## See what the system holds

Each part of the system the canvas draws — a route, a table, the SMS a server
sent, the sync engine — opens on what the world heard it do since it opened,
the script's own calls included, each with the step that caused it. A record
comes with its whole life, joined by its key:

```shell
fw run worlds contents --part=orders
```

```json
{
  "title": "80ef752c",
  "detail": "update · item Flat white · status preparing · customer Ben",
  "person": "Cleo",
  "step": "cleo.1",
  "life": [
    "+0 ms  written on Ben's phone  put  (ben.1)",
    "+9 ms  lab wrote it  insert · item Flat white · status placed · customer Ben  (ben.1)",
    "+21 ms  arrived on Cleo's phone  op 38  (ben.1)",
    "+251 ms  back on Ben's phone  op 37  (ben.1)",
    "+7602 ms  written on Cleo's phone  patch  (cleo.1)",
    "+7613 ms  lab wrote it  update · item Flat white · status preparing · customer Ben  (cleo.1)",
    "+7640 ms  arrived on Ben's phone  op 39  (cleo.1)"
  ]
}
```

With no `--part`, it lists the parts there are. What a record says is what
the server's `write` event carried beyond its table and key; a value that is
a person's user id reads as their name. A table shows the records this world
wrote, not the ones already there when it opened.

## What an app can use in a world

Each person's app runs in the studio's embedded guest, not on a simulator, so
opening a world builds nothing native. The app's plugins run their own Dart
code, and the studio answers what they ask of the platform:

- `shared_preferences`, `flutter_secure_storage` and `path_provider`, kept
  apart per person, so two people never share a session;
- `package_info_plus`, `device_info_plus` (the person's device), and
  `flutter_timezone`;
- `permission_handler`: nothing is granted until the app asks, and then the
  person allows it;
- `firebase_core`;
- `app_links`, `url_launcher` and `flutter_local_notifications`: beside each
  person, the studio lists the notifications their app showed and the URLs it
  opened, and can open a link in it.

HTTP, WebSockets and native libraries built by build hooks, such as
`sqlite3`, work as they do in the app. Each app runs in its person's own
folder, so a file it writes relative to where it runs stays theirs. A plugin the studio doesn't answer
behaves as on a platform it has no implementation for: its calls throw.
Cameras, maps and web views aren't available.

In a guest, `dart:io`'s `Platform` says macOS whatever the person's device,
while `Theme.of(context).platform` follows the device. An app that picks a
code path with `Platform.isIOS` takes its macOS path in a world.

## Reference

[`flutterware.worlds` in the capabilities reference](../docs/capabilities.md#flutterwareworlds).
