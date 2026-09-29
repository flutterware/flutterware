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
- **`on:` picks the device**: `Studio(Devices.iPad)` for a tablet,
  `Studio(Devices.window)` for someone at a desktop — the same app, run at a
  1280 × 800 window in a browser the studio draws. The default is an iPhone
  16. A person with no `app:` is someone the script acts for.
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
as pickers and its actions as buttons. **Reload** brings the world to the
code on disk with the same people: the script's process is hot-reloaded —
the server it hosts, what its actions call — and every app is reloaded as
Run reloads one, in well under a second. **Restart** runs the script again
for new people and starts each app afresh, in an emptied home, so nothing of
the last people opens as the new ones; it takes about a second and rebuilds
nothing. **Close** stops everything.

A reload keeps everything the world holds: the people, their sessions, the
server's data. Its limits are the Dart VM's. The script's body does not run
again, so a person, an action or a knob you add waits for a restart. And a
closure made before the reload keeps its old body, so an edit *inside* the
closure you hand `w.action` waits too, while an edit to anything it calls
does not. Keep an action you are working on a line that calls a function:

```dart
w.action('Mia orders a flat white', (run) => miaOrders(server, run));
```

A server the world hosts takes the same care. Its route handlers are
closures made when its router was built, so they would keep their old
bodies, and a route you add would never exist. Rebuild it in
`FlutterwareServer.onReassemble`, which the world calls after every reload,
once the new code is in (see [the shelf adapter](server_inspection.md)):

```dart
FlutterwareServer.onReassemble(() {
  unawaited(app.dispose());
  app = App(database);
});
```

For a server whose handler is all it rebuilds,
`FlutterwareServer.reloadable(() => routes(store))` does the same in one
line.

Source that does not compile is refused with the compiler's message, and
the world runs on as it was.

From the command line, the world lives as long as the command does:

```shell
fw run worlds list
fw run worlds open --world=pickup_order --hold=true   # Ctrl-C closes it
fw run worlds reload
```

An open world is its people's apps, live, side by side and all in view on
the stage, each in its device: a phone in its body, a desktop app in a
browser whose address bar shows the route the app reports — type one there
and the app goes to it. Back and forward walk the routes it has been on, as
a browser's do for a Flutter web app, and reload starts that person's app
again on the same address. Every device is drawn at one scale, so a window
looks as large beside a phone as it is. Above each is the person's name and
what the servers sent them, by kind (mail, push, SMS); someone with no app
is a small card naming the actions that act for them. Zoom in with the
buttons in the corner, a pinch or ⌘-scroll, and the stage pans; a scroll
over a phone scrolls its app. Use them as phones: an order placed on one
shows up on another.

The toolbar holds the world's knobs and actions, and on the right who is in
view: **Everyone**, or one person — their name on the stage does the same.
One person is in focus with their device as large as the room allows, and
beside it their panel: who they are and what their app runs on, and

- **Messages** — the texts, pushes and mails the servers sent that person,
  each saying what caused it, in the words of its step (`action "Rush
  hour"`, `Leo: tap "Order a flat white"`), and with the button that hands
  it to their app: **Type it** for a code, **Open** or **Tap it** for a
  link, **Read it** for a mail. A push the app showed a notification for is
  marked *shown*.
- **Network**, **App** and **Logs** — Run's own views of that app: every
  request it made, its devbar panels (its database, when it exposes one —
  `doc/database_watch.md`), and its log.

**⋯** on the person is what the studio can do as their app's platform: open
a link in it, show the notifications it posted and the pages it opened, and
send it to the background. **Everyone** or Esc goes back. The dock along the
bottom has the world's own log — its script, its server, each app's build —
as its first tab.

An app nobody can see — someone else in focus, or zoomed out of view — is
told it is *hidden*, as a minimised desktop window is, a couple of seconds
after it goes: it stops drawing and gives back the memory drawing took, and
keeps running — its timers, its connections, its sync. It draws again the
moment it is back in view. It is not sent to the background, so an app's
own code for that runs only when you ask for it, from **⋯**.

Each person's app is a Run app on the device `studio-<name>`: an agent opens a
world with `flutterware_invoke` and drives Leo's app with `flutterware_act`
and `device: "studio-leo"`, with the same verbs as any other app.

A world belongs to the process that opened it (the studio, `fw` or the MCP
server), and a checkout has one world open at a time. Every other process can
still reach it: `fw run worlds status`, `trace`, `invoke`, `reload`,
`restart` and `close` are answered by the process that owns it, so an agent can run an
action on the world you opened in the studio, or close one it left held in a
terminal.

## See what a tap caused

Every tap on a person's app, yours or an agent's, is a **step**, named after
its person: `leo.2`. So is the app starting, `leo.0`, which takes what the
app sends before anyone touches it — its config, the user it resumes, its
sync streams. The world follows each step through the system:

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

**Work handed off keeps its step when you carry it.** A zone ends where its
request does, so a job queued for later, or an upload whose storage calls
the server back, starts on no step. Keep `FlutterwareServer.step` with the
work — a column on the job's row, the object's metadata, or a map in memory
by the row's key when the queue and its worker share a process — and run
the work through `FlutterwareServer.job`:

```dart
// Where the request queues it:
await jobs.insert(kind: 'thumbnail', file: id, step: FlutterwareServer.step);

// Where a worker runs it, later:
await FlutterwareServer.job('thumbnail', () => makeThumbnail(job.file),
    step: job.step, id: job.id, queue: 'jobs');
```

The job runs under the step that queued it and as a request of its own, and
says when it started and ended, so the trace heads what it did with one
line, however long after: `job thumbnail on jobs, done in 1.2 s`. For work
that is not a job — a storage notification — `FlutterwareServer.inStep(step,
body)` re-enters the step alone.

**A step reads as a tree.** Each request and each job is a line, and what it
did sits beneath it: the records it wrote, with what changed
(`wrote orders/o7 (update · status ready)`), the messages it sent and whom
it reached. A record updated several times in a row is one line,
`updated uploads/u1 ×16 · status queued → … → ready`. What a line only
counts folds into it: the SQL statements it ran and how long they took
together, `POST /orders  201 in 9 ms, 12 statements, 6.1 ms`, and its
writes to a table in a layer. `fw run worlds trace --statements=true` lists
them beneath the line. Statements run
under no request fold into one line for each burst of them.

**A table can sit in a layer of its own.** A `write` event with a `layer`,
`FlutterwareServer.event('write', {'table': 'jobs', 'key': id, 'layer': 'jobs'})`,
files the table under that name, apart from the records people act on,
and counts its writes on the line of the request or job that made
them rather than listing each. Job queues and outboxes belong there.

**A server the script hosts is named after the script**, because it reports
from the script's own process. Call `FlutterwareServer.configure(name: 'api')`
before its first event to give it its own name.

The world's own actions are steps too, named `world.1`, `world.2`: every
request an action sends carries its step, so what *Mia orders a flat white*
caused is traced the same way, and `fw run worlds invoke` answers with the
step it ran as. `--person=world` lists only those.

An app that keeps its data in a synced database follows its records instead:
with `sync: DatabaseSync.powersync` on its [Database watch](database_watch.md)
adapter, a record written on one phone is traced to the others as it
arrives, and each person's sync state shows in their focus and in
`worlds status`.

## Hand a message to a person

What a server sends outside — an SMS, a push, a mail — reaches its person
through the world. Each message is listed under its person — open their
phone in focus — and **Type it** puts a code into the field that has
focus in their app, as an autofill would, and **Open** or **Tap it** opens a
message's link in their app. Tap the field the code goes in first.

```shell
fw run worlds outbox --person=Leo
fw run worlds deliver --message=lab/10
```

A server takes part by reporting each message with its recipient, in its
adapter for that edge:

```dart
FlutterwareServer.event('sms', {'to': phone, 'body': body});
FlutterwareServer.event('push', {'to': userId, 'title': title, 'body': body, 'link': ?link});
FlutterwareServer.event('mail', {'to': address, 'subject': subject, 'text': text, 'html': html, 'link': ?link});
```

The world finds the person by the phone number, user id or address it was
declared with, or learnt through `FlutterwareServer.identify`.

**Each delivery is a step** on the person's app, named like a tap:
`leo.3 typed the code from the SMS`, `leo.4 opened the link from the mail`.
A typed code runs the field's own callbacks inside it, so what they send
joins it directly; a link reaches the app through its link listener, so what
it starts joins by time, within a second and a half. `deliver` waits that
long and answers with what the step caused: nothing at all, for a link the
app ignored.

**The link handed over is the one the app takes.** When the adapter names a
`link`, that one. Otherwise the first link on a scheme or host the
recipient's app declares: its URL schemes and associated domains on iOS and
macOS, its `VIEW` intent filters on Android. Failing those, the first link
on a scheme of an app's own, then the first link. A mail that lists two
store badges before its invitation hands over the invitation.

**A service in your stack that sends its own mail**, and is not Dart, gets
an inbox from the world script: `var mail = await w.smtp('identity')`, then
point the service's SMTP settings at `mail.port`. Each mail is decoded and
reported as that service's, and `relay:` hands it on unchanged to the
stack's own catcher. A service on this machine sends to `localhost`; one in
a container reaches the machine as `host.docker.internal` with Docker
Desktop, and on Linux at the bridge's address, where the inbox must listen
beyond loopback: `w.smtp('identity', address: InternetAddress.anyIPv4)`.

**A message another service sent** is drawn as that service's, not the
reporting server's, when its event says so: `'from': 'identity'`. A service
that is not Dart carries no step, so what it sent joins the newest step
heard in the three seconds before it, and says it joined by time.

A mail with `html` is read as its recipient would see it: **Read it** opens
it in the person's panel, beside their app, as a picture WebKit draws, with
each link clickable where it sits. A link goes where a phone would send it:
into the app when the app opens it — a scheme of its own, a web host it
claims — and otherwise to the page, live, with **Mail** to come back. Under
the mail, each link opened from it in the app, and when. `fw run worlds show --message=<id>` draws the
picture for an agent to read, with each link's box, and
`fw run worlds deliver --message=<id> --link=<link>` opens a chosen link.
Drawing needs the Xcode command line tools, as the native layer does: the
helper is compiled on first use.

## See what the system holds

Each part of the system — a route, a table, the SMS a server sent, the sync
engine — answers with what the world heard it do since it opened,
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
code. The studio stands in for the platform, and answers a short list of
plugins, mostly ones a world acts through or keeps apart per person:

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
folder, so a file it writes relative to where it runs stays theirs. Cameras,
maps and web views aren't available.

**Every other plugin is yours to fake.** flutterware doesn't answer every
plugin there is, and won't. A call nothing answers fails in the app, as it
would on a platform the plugin doesn't support, and the world says so the
first time: a line in the world log, a warning on the person, and
`unanswered` in `worlds status`. Fake the plugin in the entry point the world
starts, behind a knob, as you would in a scenario. The guest
registers each plugin's Dart half before it calls `main`, so what `main` sets
wins: a plugin's platform interface, or a class of your own that wraps the
plugin.

```dart
void main({String server = '', bool fakeScale = false}) {
  if (fakeScale) ScalePlatform.instance = FakeScale();
  runApp(ShopApp(server: Uri.parse(server)));
}
```

```dart
app: Launch('Shop', knobs: {'server': '${server.url}', 'fakeScale': true}),
```

In a guest, `dart:io`'s `Platform` says macOS whatever the person's device,
while `Theme.of(context).platform` follows the device. An app that picks a
code path with `Platform.isIOS` takes its macOS path in a world.

**Push notifications need a stand-in.** A push plugin has no platform to
register with in a guest, so the app gets no token and the server pushes to
nobody. Give the app, in a world, a stand-in behind a knob: it asks for
permission through `permission_handler` and registers a token of its own
making. Have your push adapter report a push to such a token, with the link
tapping it opens, instead of sending it. The push then reaches its person
through your server's real push path, and **Tap it** opens it in their app.

## Reference

[`flutterware.worlds` in the capabilities reference](../docs/capabilities.md#flutterwareworlds).
