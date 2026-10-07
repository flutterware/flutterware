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
the world runs on as it was. One reload runs at a time: one asked for while
another runs — **Reload** pressed as `fw run worlds reload` answers — goes
after it. A hot reloader of your own inside the script, reloading it on a
save, is waited for too, for up to ten seconds; if the VM still will not
reload, the refusal says so in its words rather than as a compile error.
Keep such a reloader out of a world all the same: two reloads compiling at
once can take down the compiler the script reloads through, or the script
itself. A script that exits during a reload is said to have, with its exit
code and the last thing it said, and **Restart** starts it again.

The script reloads through a compiler of its own, which stops itself after
30 minutes without a reload; one left open longer, or one a collision took
down, is started afresh by the next reload, which says so in the log and in
its answer's `note`. The answer, and the world's log, split the time between
the script's code, its `onReassemble` callbacks and the apps:
`Reloaded in 0.86 s (reload.2): the script in 0.38 s, its onReassemble in 0.03 s, Shop in 0.45 s`.

Each reload is also a moment in the trace, a step of the world's own —
`reload.2`, a pill on the timeline's World column — which the answer names.
What happened after it ran the new code, but for work already running when
it came: a job, a request, finishing on the old code as it lets go. A step
still going when it came has it as a line in its place,
`+13148 ms  reload.2  the code reloaded`, and a job or request that ran
across it says so — `done in 30.1 s, across reload.2` — since it began on
the old code.

From the command line, with the studio open on the checkout, the world opens
in the studio; without it, the world lives as long as the command does:

```shell
fw run worlds list
fw run worlds open --world=pickup_order               # in the studio, when it is open
fw run worlds open --world=pickup_order --hold=true   # here; Ctrl-C closes it
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

The toolbar holds the world's knobs and an **Actions** menu with every action
its script declares, and on the right who is in view: **Everyone**, or one
person — their name on the stage does the same.
One person is in focus with their device as large as the room allows, and
beside it their panel: who they are and what their app runs on, and

- **Messages** — the texts, pushes and emails the servers sent that
  person, each saying what caused it (`Rush hour`, `Leo tapped "Order a flat
  white"`), with buttons that hand it to their app: **Enter code**, **Open
  link**, **Open notification**, and **View email** for an email. A push the
  app showed a notification for is marked *shown by the app*.
- **Network**, **App** and **Logs** — Run's own views of that app: every
  request it made, its devbar panels (its database, when it exposes one —
  `doc/database_watch.md`), and its log.

**⋯** on the person is what the studio can do as their app's platform: open
a link in it, show the notifications it posted and the pages it opened, and
send it to the background. **Everyone** or Esc goes back. The dock along the
bottom has the world's own log — its script, its server, each app's build —
as its first tab.

**Timeline**, beside **Phones** in the toolbar, shows what happened in the
world rather than who is in it: a column for each person and each part of
the system — a server, the SMS, mail and push it sent, a service that mailed
on its own — and time running down. A pill is something someone did; an
arrow is something that reached someone, in the colour of whoever caused
it. **Product** shows what people did and what reached someone else,
**System** adds the calls and the jobs, and **Wire** the writes, the
statements and the sync; each says how many rows it has. A column's name —
or a person in the toolbar — shows only what touches it. Three rows or more
alike on one step, differing only in their numbers, fold into one (`×4`),
and a pause is marked where it was (`12.7 s later`). A row opens in place
onto what it was, its step lit and the rest faded: a call's request and
response — headers and bodies, read from the app that sent it, secrets cut —
the fields a write set and the statements its request ran, a message with
its code and links, a mail as its recipient sees it. `worlds trace` takes
the same `level`.

An app nobody can see — someone else in focus, zoomed out of view, or the
timeline shown — is told it is *hidden*, as a minimised desktop window is, a couple of seconds
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

**With the studio open, you and an agent see the same world.** `fw` and the
MCP server draw a person's app nowhere, so while the studio has the checkout
open, a `worlds open` from either of them is sent to the studio: the world
opens there, its people's apps live on screen, and its log says who asked.
The agent's answer says so, and everything it does next reaches the world as
before. `--hold=true` keeps the world in the asking process instead. A world
opened before the studio was stays where it is: close it and open it again
to see it.

## See what a tap caused

Every tap on a person's app, yours or an agent's, is a **step**, named after
its person: `leo.2`. So is the app starting, `leo.0`, which takes what the
app sends before anyone touches it — its config, the user it resumes, its
sync streams — for ten seconds or until the first tap. A request the app
sends from another isolate carries no step, since the world stamps the
app's own; `leo.0` takes it all the same when the server identified Leo
asking (`FlutterwareServer.identify`) in that time, and its line says it
was joined by who and when. The world follows each step through the system:

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

**What a tap causes arrives over seconds**, and the trace answers at once
with what has arrived so far: the jobs it queued, the sync to the other
phones, a mail a service sends later. `--settle=2000` waits first, until the
answer has not changed for two seconds and no job in it is still running,
then answers. The answer says whether it settled (`"settled": true`); if the
timeout came first, it lists the jobs still running. The timeout is 30
seconds by default, `--timeout` up to 120. A wait settles on what is there,
not on what is coming: an app that debounces for longer than the quiet you
ask for still lands after the answer. So ask for more than its debounce, or
read again.

```shell
fw run worlds trace --person=Leo --settle=2000
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
something down a connection, such as a WebSocket frame. Give `identify` the
phone or address the account was made with when the server has them —
`identify(user.id, phone: user.phone)` — and a person the world declared by
those is known by the id too: someone invited by SMS, whose account a step
makes and whose app then only syncs, is theirs rather than nobody's. An
identity provider's token rarely carries either, so the adapter may have to
look them up by the token's subject: once an id is enough, and run the
lookup where your SQL adapter does not report it, or it shows among the
statements of whichever request it happens to run in.

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

`job` starts its body at once, in its caller's turn: like any `async`
function, it runs synchronously up to its first `await`. Work that must come
after its caller — a webhook delivered once the request that fired it has
answered, as a webhook service would — goes in a `Future`:
`unawaited(Future(() => FlutterwareServer.job('deliver', …)))`.

**A step reads as a tree.** Each request and each job is a line, and what it
did sits beneath it: the records it wrote, with what changed
(`wrote orders/o7 (update · status ready)`), the messages it sent and whom
it reached. Beneath a write, where the record arrived: each phone it
reached, and its writer's own copy confirmed, however long after. A record
updated several times in a row is one line,
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

**A write can say the level it is seen at.** Writes are the wire's; a
record whose status is what a pipeline decided at each hand-off is worth
seeing among the jobs, and `'level': 'system'` on its `write` events puts it
there. A record's arrival on a phone, at a level that hides the write it
came with, says what that write brought:
`Cleo  orders/o5 arrived (op 16) · update · status ready`.

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
`worlds status`. A phone subscribing to a bucket is a line of its own,
`subscribed to note["n1"]`, beneath the write that brought the bucket its
first record — the join that record's arrival makes, by its key. A bucket
nothing explains that way, and one the phone lets go of, is a line of that
person's step just before it, and says it was joined by time. What was
written to a bucket before, the phone receives after it — a record that
arrives long after its write says `new to this phone`. A bucket the phone
held empty from the start reads the same at its first record: the phone
lists a bucket only once it holds something.

## Hand a message to a person

What a server sends outside — an SMS, a push, a mail — reaches its person
through the world. Each message is listed under its person — open their
phone in focus — and **Enter code** puts a code into the field that has
focus in their app, as an autofill would, and **Open link** or **Open
notification** opens a message's link in their app. Tap the field the code
goes in first.

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

A mail with `html` is read as its recipient would see it: **View email** opens
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
through your server's real push path, and **Open notification** opens it in
their app.

## Reference

[`flutterware.worlds` in the capabilities reference](../docs/capabilities.md#flutterwareworlds).
