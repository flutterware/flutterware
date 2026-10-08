# Worlds

Several people on your real server at once, each with their own app, set up
by a script: a barista and a customer, or an admin and the colleague they
invite. When you open a world, the script creates the users and every
person's app starts signed in as one of them, side by side in the studio.

> **Experimental, and macOS only.** `package:flutterware/world.dart` can
> change in any release, and a world opens only on a Mac for now.

## Turn it on

A world is a Dart file in a package that can start your server and create
users on it. For a Dart server, that is the server's own package, which then
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

A world is opened by its file name, here `pickup_order`, so each world needs
a file name of its own. The people's apps are [Run](run.md) entry points,
named the way `Run` declares them.

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
script starts your server (or points at one already running) and creates its
users through your server's API.

- `w.id` is new every time the world opens or restarts. Put it in the emails,
  names and numbers the script makes (`'ana.${w.id}@example.com'`,
  `'Canal Street ${w.id}'`) so a world never collides with the users it made
  last time. The script writes each address and phone number itself, one line
  each, in a form your server accepts. Pass them to
  `w.person(email:, phone:)` and the studio shows them next to the person.
- `Launch` names an entry point and the [knobs](run.md#knobs) its `main` is
  called with. That is how a person starts signed in: a session token, a
  server URL or a starting page are all knobs.
- `on:` picks the device: `on: Studio(Devices.iPad)` for a tablet, or
  `on: Studio(Devices.window)` for someone at a desktop, which runs the same
  app in a 1280 × 800 window inside a browser the studio draws. The default
  is an iPhone 16.
- A person with no `app:` is someone the script acts for.
- `w.knob('Leo', options: ['signed out', 'signed in'], initial: 'signed out')`
  adds a choice to the world and returns the value the world was opened
  with, or `initial`. Changing it restarts the world.
- `w.action(...)` adds a button to the open world, for something that happens
  while you watch, such as a customer with no app placing an order.
- `w.onClose(...)` runs when the world closes or restarts, the last one
  registered first.
- `w.progress('Seeding the menu')` shows what the script is doing while the
  world opens.

Whatever the script prints shows in the world's log. To debug its setup
without launching any app, run the file on its own: it prints what it
declares, and `name=value` arguments set its knobs.

```shell
cd server && dart run tool/worlds/pickup_order.dart 'Leo=signed in'
```

## Open it

In the studio, **Worlds** lists the worlds you declared.

- **Open** runs the script and starts every person's app side by side, with
  the world's knobs as pickers and its actions as buttons.
- **Reload** updates the world to the code on disk and keeps the same people.
  The script's process is hot-reloaded, including the server it hosts and
  what its actions call, and every app is hot-reloaded the way Run reloads
  one. It takes well under a second.
- **Restart** runs the script again for new people and starts each app
  afresh with its storage emptied, so no app opens as the previous person.
  It takes about a second and rebuilds nothing.
- **Close** stops everything.

A reload keeps everything the world holds: the people, their sessions and the
server's data. It has the Dart VM's limits:

- The script's body does not run again, so a person, action or knob you add
  appears after a restart.
- A closure made before the reload keeps its old body. An edit inside the
  closure you pass to `w.action` waits for a restart, while an edit to
  anything it calls is reloaded. Keep an action you are working on to one
  line that calls a function:

```dart
w.action('Mia orders a flat white', (run) => miaOrders(server, run));
```

A server the world hosts needs the same care. Its route handlers are closures
made when its router was built, so after a reload they keep their old bodies
and a route you add does not exist. Rebuild the router in
`FlutterwareServer.onReassemble`, which the world calls after every reload
once the new code is in (see [the shelf adapter](server_inspection.md)):

```dart
FlutterwareServer.onReassemble(() {
  unawaited(app.dispose());
  app = App(database);
});
```

If the handler is all your server needs to rebuild,
`FlutterwareServer.reloadable(() => routes(store))` does the same in one
line.

If the source does not compile, the reload is refused with the compiler's
message and the world keeps running as it was. Reloads run one at a time: a
reload asked for while another is running (for example **Reload** pressed
while `fw run worlds reload` is still answering) waits for it. If the script
has its own hot reloader that reloads on save, the world waits for that too,
for up to ten seconds; if the VM still will not reload, the refusal gives the
VM's own message. Don't put such a reloader in a world script anyway: two
reloads compiling at once can crash the compiler the script reloads through,
or the script itself. If the script exits during a reload, the answer says
so, with its exit code and the last thing it printed, and **Restart** starts
it again.

The script reloads through a compiler of its own, which stops after 30
minutes without a reload. The next reload starts a new one, whether the old
one stopped or crashed, and says so in the log and in its answer's `note`.
The answer and the world's log split the time between the script's code, its
`onReassemble` callbacks and the apps:

```text
Reloaded in 0.86 s (reload.2): the script in 0.38 s, its onReassemble in 0.03 s, Shop in 0.45 s
```

Each reload is also a step in the trace, such as `reload.2`, which the answer
names. It shows as a pill in the timeline's **World** column. Everything after
it runs the new code, except a job or a request already in progress, which
finishes on the old code. A step still in progress at the reload shows it as
a line where it happened,
`+13148 ms  reload.2  the code reloaded`, and a job or request that ran across
it says so: `done in 30.1 s, across reload.2`.

From the command line, `open` opens the world in the studio when the studio
has this checkout open. Otherwise the world lives as long as the command
does, so pass `--hold=true` to keep it open in your terminal until Ctrl-C.

```shell
fw run worlds list
fw run worlds open --world=pickup_order               # in the studio, when it is open
fw run worlds open --world=pickup_order --hold=true   # here; Ctrl-C closes it
fw run worlds reload
```

An open world shows its people's apps live and side by side, each in its
device. A phone app is drawn in the phone's body. A desktop app is drawn in a
browser whose address bar shows the route the app reports; type a route there
and the app goes to it. Back and forward step through the routes it has been
on, as a browser does for a Flutter web app, and reload starts that person's
app again on the same address. Every device is drawn at the same scale, so a
window looks as large next to a phone as it really is. Above each device are
the person's name and the messages the servers sent them, by kind (mail,
push, SMS). A person with no app is a small card listing the actions that act
for them. Zoom with the buttons in the corner, a pinch or ⌘-scroll. A scroll
over a phone scrolls its app; anywhere else it pans the view. Use the apps as
you would the phones: an order placed on one shows up on another.

The toolbar holds the world's knobs, an **Actions** menu with every action
the script declares, and, on the right, who is in view: **Everyone** or one
person. Clicking a person's name above their device does the same. With one
person in focus, their device is as large as the space allows, next to their
panel. The panel says who they are and what their app runs on, and has these
tabs:

- **Messages**: the texts, pushes and emails the servers sent that person,
  each with what caused it (`Rush hour`, `Leo tapped "Order a flat white"`).
  Buttons hand a message to their app: **Enter code**, **Open link**, **Open
  notification**, and **View email** for an email. A push the app showed a
  notification for is marked *shown by the app*.
- **Network**, **App** and **Logs**: Run's own views of that app, with every
  request it made, its devbar panels (including its database, when it exposes
  one; see [Database watch](database_watch.md)) and its log.

**⋯** on the person acts as the app's platform: it opens a link in the app,
shows the notifications the app posted and the pages it opened, and sends the
app to the background. **Everyone** or Esc goes back. The first tab along the
bottom is the world's own log, with its script, its server and each app's
build.

**Timeline**, next to **Phones** in the toolbar, shows what happened in the
world. It has a column for each person and for each part of the system (a
server; the SMS, mail and push it sent; a service that sent mail on its
own), with time running down. A pill is something someone did. An arrow is
something that reached someone, in the colour of whoever caused it. Three
levels set how much it shows, and each says how many rows it has:

- **Product**: what people did and what reached someone else.
- **System** adds the calls and the jobs.
- **Wire** adds the writes, the statements and the sync.

Click a column's name, or a person in the toolbar, to show only what touches
it. Three or more rows on one step that differ only in their numbers fold
into one (`×4`), and a pause is marked where it happened (`12.7 s later`).
Click a row to open it in place, with its step highlighted and the rest
faded. It shows a call's request and response (headers and bodies, read from
the app that sent it, with secrets removed), the fields a write set and the
statements its request ran, a message with its code and links, or a mail as
its recipient sees it. `worlds trace` takes the same levels:
`--level=product`, `system` or `wire` (the default).

When nobody can see an app (someone else is in focus, it is zoomed out of
view, or the timeline is showing), it is told it is *hidden* a couple of
seconds later, as a minimised desktop window is. It stops drawing and frees
the memory drawing used, and keeps running its timers, connections and sync.
It draws again as soon as it is back in view. It is not sent to the
background, so the app's own code for that runs only when you choose it from
**⋯**.

Each person's app is a Run app on the device `studio-<name>`. An agent opens
a world with `flutterware_invoke` and drives Leo's app with `flutterware_act`
and `device: "studio-leo"`, using the same verbs as for any other app.

A world belongs to the process that opened it (the studio, `fw` or the MCP
server), and a checkout has one world open at a time. Other processes can
still reach it: the process that owns the world answers
`fw run worlds status`, `trace`, `invoke`, `reload`, `restart` and `close`.
So an agent can run an action on a world you opened in the studio, and you
can close a world an agent left open in a terminal.

While the studio has the checkout open, a `worlds open` from `fw` or the MCP
server is sent to the studio, because neither of them can show a person's
app. The world opens in the studio with its people's apps on screen, so you
and the agent see the same world, and its log says who asked. The agent's
answer says where the world opened, and everything the agent does next
reaches it as usual. `--hold=true` keeps the world in the process that asked
instead. A world opened before the studio stays where it is; close it and
open it again to see it in the studio.

## See what a tap caused

Every tap on a person's app, yours or an agent's, is a **step** named after
the person: `leo.2`. The app starting is a step too, `leo.0`. It collects
what the app sends before anyone touches it (its config, the user it
resumes, its sync streams) for ten seconds or until the first tap. A request
the app sends from another isolate carries no step, because the world stamps
only the app's main isolate. `leo.0` still collects such a request if, in
that time, the server identified Leo as the one asking
(`FlutterwareServer.identify`), and its line ends `joined by who and when`.
The world follows each step through the system:

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

What a tap causes can keep arriving for seconds: the jobs it queued, the sync
to the other phones, a mail a service sends later. The trace answers at once
with what has arrived so far. With `--settle=2000` it waits first, until the
answer has not changed for two seconds and no job in it is still running.
The answer says whether it settled (`"settled": true`); if the timeout came
first, it lists the jobs still running. The timeout is 30 seconds by default,
and `--timeout` sets it in milliseconds, up to `120000`. Settling waits only
for quiet: if an app debounces for longer than the quiet you ask for, what it
sends lands after the answer. Ask for more than its debounce, or read the
trace again.

```shell
fw run worlds trace --person=Leo --settle=2000
```

Every request an app sends carries its step in an `x-fw-step` header. A Dart
server takes part with one line in its [inspection
adapter](server_inspection.md) that puts the header in the zone next to the
request id:

```dart
zoneValues: {
  FlutterwareServer.requestIdKey: id,
  FlutterwareServer.stepKey: ?request.headers['x-fw-step'],
},
```

Everything the server reports under that request then carries the step: its
writes, the messages it sent and who they reached. Two calls tell the world
what only the server knows:

- `FlutterwareServer.identify(user.id)`, once auth knows who made the
  request. The world can then tell which person a user is, even one who
  signed up themselves.
- `FlutterwareServer.reach(userId, what)`, when the server pushes something
  down a connection, such as a WebSocket frame.

When the server has the phone or address the account was made with, pass it
to `identify` too: `identify(user.id, phone: user.phone)`. A person the world
declared by phone or address is then also known by that id, so someone
invited by SMS, whose account a step creates and whose app then only syncs,
is still recognised as that person. An identity provider's token rarely
carries the phone or address, so the adapter may have to look them up from
the token's subject. One lookup per id is enough. Run it where your SQL
adapter does not report it, or it shows up among the statements of whichever
request it happens to run in.

A zone ends with its request, so a job queued for later, or an upload whose
storage calls the server back, starts with no step. To keep the step, store
`FlutterwareServer.step` with the work (a column on the job's row, the
object's metadata, or an in-memory map keyed by the row when the queue and
its worker share a process) and run the work through
`FlutterwareServer.job`:

```dart
// Where the request queues it:
await jobs.insert(kind: 'thumbnail', file: id, step: FlutterwareServer.step);

// Where a worker runs it, later:
await FlutterwareServer.job('thumbnail', () => makeThumbnail(job.file),
    step: job.step, id: job.id, queue: 'jobs');
```

The job runs under the step that queued it, as a request of its own, and
reports when it started and ended. In the trace, what it did sits under one
line, however much later it ran: `job thumbnail on jobs, done in 1.2 s`. For
work that is not a job, such as a storage notification,
`FlutterwareServer.inStep(step, body)` re-enters the step and does nothing
else.

`job` starts its body immediately, in its caller's turn: like any `async`
function, it runs synchronously up to its first `await`. Work that must run
after its caller, such as a webhook delivered once the request that fired it
has answered, goes in a `Future`:
`unawaited(Future(() => FlutterwareServer.job('deliver', …)))`.

A step reads as a tree. Each request and each job is a line, with what it did
beneath it: the records it wrote and what changed
(`wrote orders/o7 (update · status ready)`), and the messages it sent and
whom they reached. Beneath a write is where the record arrived: each phone it
reached, and its writer's own copy confirmed, however long after. A record
updated several times in a row is one line:
`updated uploads/u1 ×16 · status queued → … → ready`. What a line only counts
is folded into it: the SQL statements it ran with their total time
(`POST /orders  201 in 9 ms, 12 statements, 6.1 ms`), and its writes to a
table in a layer. `fw run worlds trace --statements=true` lists them beneath
the line, along with each update of a record updated in a row. Statements run
outside any request fold into one line per burst.

To keep a table apart from the records people act on, give its `write`
events a `layer`:

```dart
FlutterwareServer.event('write', {'table': 'jobs', 'key': id, 'layer': 'jobs'});
```

The table is then filed under that name, and its writes are counted on the
line of the request or job that made them instead of listed one by one. Job
queues and outboxes belong in a layer.

A `write` event can also set the timeline level it shows at. Writes show at
**Wire**. `'level': 'system'` on a record's `write` events shows them at
**System**, among the jobs, which suits a record whose status is what a
pipeline decided at each hand-off. When a record arrives on a phone at a
level that hides the write it came with, the arrival line says what that
write brought: `Cleo  orders/o5 arrived (op 16) · update · status ready`.

A server the script hosts reports from the script's own process, so it is
named after the script. To give it its own name, call
`FlutterwareServer.configure(name: 'api')` before its first event.

The world's own actions are steps too, named `world.1`, `world.2`. Every
request an action sends carries its step, so what *Mia orders a flat white*
caused is traced the same way, and `fw run worlds invoke` answers with the
step it ran as. `--person=world` lists only those steps.

An app that keeps its data in a synced database is traced through its
records. With `sync: DatabaseSync.powersync` on its [Database
watch](database_watch.md) adapter, a record written on one phone is traced to
the others as it arrives, and each person's sync state shows in their panel
and in `worlds status`. A phone subscribing to a bucket is a line of its own,
`subscribed to note["n1"]`, under the write that brought the bucket its first
record, matched by that record's key. A bucket that can't be matched that
way, and one the phone lets go of, is a line in that person's step just
before it, marked `joined by time`. A phone receives what was written to a
bucket before it subscribed, so a record that arrives long after its write is
marked `new to this phone`. A bucket the phone held empty from the start
reads the same at its first record, because the phone lists a bucket only
once it holds something.

## Hand a message to a person

What a server sends outside the app (an SMS, a push, a mail) reaches its
person through the world. Each message is listed on the person's
**Messages** tab when they are in focus. **Enter code** types a message's
code into the field that has focus in their app, as autofill would, so tap
that field first. **Open link** or **Open notification** opens a message's
link in their app.

```shell
fw run worlds outbox --person=Leo
fw run worlds deliver --message=lab/10
```

`deliver` types the code when the message carries one and otherwise opens its
link; `--how=open` opens the link instead.

A server takes part by reporting each message with its recipient, in its
adapter for that channel:

```dart
FlutterwareServer.event('sms', {'to': phone, 'body': body});
FlutterwareServer.event('push', {'to': userId, 'title': title, 'body': body, 'link': ?link});
FlutterwareServer.event('mail', {'to': address, 'subject': subject, 'text': text, 'html': html, 'link': ?link});
```

The world finds the person by the phone number, user id or address they were
declared with, or that it learned through `FlutterwareServer.identify`.

Each delivery is a step on the person's app, named like a tap:
`leo.3 typed the code from the SMS`, `leo.4 opened the link from the mail`.
A typed code runs the field's own callbacks, so what they send belongs to the
step directly. A link reaches the app through its link listener, so what it
starts is joined to the step by time, within a second and a half. `deliver`
waits that long and answers with what the step caused, which is nothing for a
link the app ignored.

When a message has several links, the one handed to the app is:

1. the `link` the adapter reported, if any;
2. otherwise the first link on a scheme or host the recipient's app declares:
   its URL schemes and associated domains on iOS and macOS, its `VIEW` intent
   filters on Android;
3. otherwise the first link on a custom scheme;
4. otherwise the first link.

So a mail that lists two store badges before its invitation hands over the
invitation.

A service in your stack that is not written in Dart and sends its own mail
can get an inbox from the world script. Point the service's SMTP settings at
the inbox's port; any username and password are accepted, and TLS is not
offered:

```dart
var mail = await w.smtp('identity');
// The service's SMTP port is mail.port.
```

Each mail is decoded and reported as sent by that service. With
`relay: (host: 'localhost', port: 1025)`, each mail also goes on unchanged to
your stack's own mail catcher. A service on this machine sends to
`localhost`. One in a container reaches the machine as
`host.docker.internal` with Docker Desktop. On Linux it uses the bridge's
address, and the inbox must listen beyond loopback:
`w.smtp('identity', address: InternetAddress.anyIPv4)`.

To show a message as sent by another service rather than the server
reporting it, add `'from': 'identity'` to its event. A service that is not
Dart carries no step, so what it sent joins the newest step heard in the
three seconds before it, and says it was joined by time.

A mail with `html` is shown as its recipient would see it. **View email**
opens it in the person's panel, next to their app, as a picture drawn by
WebKit, with each link clickable where it sits. A link goes where a phone
would send it: into the app if the app opens it (a scheme of its own, or a
web host it claims), and otherwise to the live web page, with **Email** and
**Page** to switch between the two. Under the mail are the links opened from
it in the app, and when. For an agent, `fw run worlds show --message=<id>`
draws the picture with each link's box, and
`fw run worlds deliver --message=<id> --link=<link>` opens a chosen link.
Drawing needs the Xcode command line tools, as Run's native layer does; the
helper is compiled on first use.

## See what the system holds

`worlds contents` shows what one part of the system (a route, a table, the
SMS a server sent, the sync engine) did since the world opened, including the
script's own calls, each with the step that caused it. A record comes with
its whole life, joined by its key:

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

With no `--part`, it lists the parts there are. A record's details are what
the server's `write` event carried besides its table and key, and a value
that is a person's user id shows as their name. A table shows only the
records written since the world opened.

## What an app can use in a world

Each person's app runs inside the studio itself, so opening a world builds
nothing native. The app's plugins run their own Dart code, and the studio
stands in for the platform side of a short list of plugins, mostly ones a
world acts through or keeps separate per person:

- `shared_preferences`, `flutter_secure_storage` and `path_provider`, kept
  separate per person, so two people never share a session;
- `package_info_plus`, `device_info_plus` (reporting the person's device) and
  `flutter_timezone`;
- `permission_handler`: nothing is granted until the app asks, and then every
  request is granted;
- `firebase_core`;
- `app_links`, `url_launcher` and `flutter_local_notifications`: next to each
  person, the studio lists the notifications their app showed and the URLs it
  opened, and can open a link in the app.

HTTP, WebSockets and native libraries built by build hooks, such as
`sqlite3`, work as they do in the app. Each app runs in its person's own
folder, so a file it writes relative to its working directory stays theirs.
Cameras, maps and web views aren't available.

Any other plugin needs a fake. A call that the studio does not answer fails
in the app, as it would on a platform the plugin doesn't support. The world
reports the first one: a line in the world log, a warning on the person, and
`unanswered` in `worlds status`. Fake the plugin in the entry point the world
starts, behind a knob, as you would in a scenario. The studio registers each
plugin's Dart half before it calls `main`, so whatever `main` sets wins: a
plugin's platform interface, or a class of your own that wraps the plugin.

```dart
void main({String server = '', bool fakeScale = false}) {
  if (fakeScale) ScalePlatform.instance = FakeScale();
  runApp(ShopApp(server: Uri.parse(server)));
}
```

```dart
app: Launch('Shop', knobs: {'server': '${server.url}', 'fakeScale': true}),
```

In a world, `dart:io`'s `Platform` reports macOS whatever the person's device
is, while `Theme.of(context).platform` follows the device. An app that picks
a code path with `Platform.isIOS` takes its macOS path in a world.

Push notifications need a stand-in. A push plugin has no platform to register
with in a world, so the app gets no token and the server pushes to nobody.
In a world, give the app a stand-in behind a knob that asks for permission
through `permission_handler` and registers a token it makes up. Have your
push adapter report a push to such a token, with the link that tapping it
opens, instead of sending it. The push then reaches its person through your
server's real push path, and **Open notification** opens it in their app.

## Reference

[`flutterware.worlds` in the capabilities reference](../docs/capabilities.md#flutterwareworlds).
