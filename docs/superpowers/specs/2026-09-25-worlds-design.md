# Worlds — several people, one real server, one canvas

**Date:** 2026-09-25
**Question:** flutterware can run one app against a real server (Run), script
one app against faked outside services or real ones (scenarios, both lanes),
and render one widget (Previews). Nothing shows a *system* in use: several
people on their own apps, the server they share, and everything that server
sends to the services outside it. What would, and what would it look like?
**Answer:** a **world**. A Dart script, written in the project, brings up or
attaches to the real server, creates fresh users through the server's own
API, and declares the **people** who use it — each with an app running somewhere:
an embedded guest, a macOS window, a simulator, a phone, a browser. The studio
launches their apps, redirects the server's edges (email, SMS, push, jobs)
into view, delivers links and pushes into the right app, and draws all of it
on one zoomable canvas.
**Decision:** the shape below was agreed with the owner in a brainstorm. The
device experiment then settled where a person's app runs by default: **in the
studio's embedded guest, the studio answering its plugins' platform calls**
(*go*, `2026-09-25-worlds-guest-phase5-decision.md`) — narrowed since to the
platform and the plugins a world acts through, the project faking the rest
(*Plugins are the project's*). A person whose app needs
what a guest cannot carry — a camera, a view the OS draws, Bluetooth — runs on
a simulator, a phone or a macOS window, and external devices stay
first-class. Built so far: slice 0 — `package:flutterware/world.dart`, the
`worlds` plugin (`fw`, the MCP server, and a *Worlds* panel in the studio)
and the lab's first world, *Pickup order*
(`2026-09-25-worlds-slice0-findings.md`) — then hardened on the consumer's
first round with it (same findings, *Round 1*), whose team also drafted the
system beside the people, now folded in below.
**Method:** one brainstorm (2026-09-24/25) with three rounds of clickable
mockups; a read of a consumer's monorepo — a Dart server, a staff dashboard,
a client phone app, a local stack in docker compose — through its code and its
git history; a read of this repo's Run, server inspection, devbar, embedder
and scenario code. Every figure about the consumer comes from its repository,
not from running it. Then six invented worlds written on paper against this
design (`2026-09-25-worlds-paper-cases.md`); their findings are folded in
below — two words, eight places the API grew, and a section on the device.

## Where it sits

| | used freely | driven by a script |
|---|---|---|
| **the outside services faked** | — | Scenarios (fake time) |
| **the real system** | Run — *one* app | Scenarios (live lane) |
| **the real system, several people, its edges in view** | **Worlds** | a world as a live scenario's setup (later) |

Previews stays beside the grid: it shows a piece of an app, not an app.

The idea is older than this document. The cockpit brainstorm's *journeys*
(`2026-07-31-app-launcher-cockpit-brainstorm.md` §D10) were named,
parameterised, started from a cold app, took knobs, composed, and ended by
handing the app over — *"a journey is a scenario prefix that nobody asserted
on"*. They were parked on purpose until a real app had been driven. A world
is a journey for several people at once, with the server inside it.

## Three ideas this replaces

**A sandbox over a mocked API.** The consumer ran exactly that for two years
and deleted it on 2026-08-25: 2,470 lines in the app package, 137 commits to
its main file — 133 of which also touched the scenario harness's own API fake,
because every endpoint had to be stubbed twice — and by the end it misled: a
settings screen spun forever on an `UnimplementedError` while the scenarios
covering it passed. The fake sat at the widest boundary the system has,
between the app and the server, where every feature adds a method. A world
keeps both sides real and fakes only the server's *outside* edges, each of
which, in that consumer, was already one small interface.

**Reset to a snapshot.** The consumer's local seed runs only on a fresh
database, and re-seeding is `down --volumes` then `up`: minutes. A snapshot
would have to move three stores in lockstep — the app database, the auth
server's database, the sync service's storage — or sync breaks. Creating fresh
users per world needs no reset at all.

**Entering a scenario at step N.** A fake-time scenario's timers and streams
belong to the FakeAsync zone and cannot be handed to a real clock — the same
zone trap as the TLS timers in `2026-08-27-scenario-http-findings.md`. A world
starts from a script, never from a step.

## Vocabulary

- **World** — a named, restartable setup of the whole system. One Dart file.
- **World script** — that file. A process that lives as long as the world is
  open.
- **Person** — someone using the system: a name, an identity on the server
  (email, phone, user id) and, usually, an app running somewhere. A person
  with no app is **headless**; the script acts for them through the API. The
  plural is *people*. A person can exist before their account does.
- **Newcomer** — a person nobody declared, who turns up because someone typed
  their address into a form. Newcomers get the world's default app and device.
- **Edge** — where the server talks to outside services: email, SMS, push,
  background jobs, payments, outbound webhooks. Most edges tell; some ask.
- **Outbox** — everything the edges sent, as one feed.
- **Question** — an outbox item from an edge that waits for an answer: a
  charge, a 3-D Secure challenge, a consent screen.
- **Peripheral** — *later*: a simulated physical device a person's app talks
  to.
- **Canvas** — the studio's view of a world. Every person, the server and every
  peripheral is a **node** on it.

**Why not *actor*.** The word is taken, and publicly: `run act` and
`run observe` take an `actor` argument — *who this step is journaled as*,
`agent` unless told otherwise — the run journal stores it (`agent`, `human`,
`device`), and review notes use the same idea for who answered. It means *who
pulled the trigger*, and it keeps that meaning. A world's participant is a
**person**, so the two compose instead of colliding: a step on Leo's app that
the agent took is `person: Leo, actor: agent`, and the Steps tab reads
*Leo · by agent*. The owner first said *actor*; the collision decided it.

**Why not *sandbox* or *playground*.** Checked before slice 0, and *world*
kept. *Sandbox* is taken at both ends of a world: the app sandbox is how
this design isolates people (*two windows share one sandbox container*), and
the edges a world redirects each have a sandbox mode of their own — the push
sandbox, a payment provider's, the SMS provider's. It also promises that
nothing is real, which is the idea this design replaced. *Playground* reads
as "try code here", which in the studio is Previews. *World* says a
populated place with a server in it, which you open, restart and close; its
one weakness is that alone it says little, so wherever a stranger first
meets it, it carries a subtitle: *several people on your real server*. For
the same reason the prose says *outside services*, never *the outside
world*, for what the edges talk to.

## The world script

### Where it lives, how it runs

One file per world, in the package that owns seeding and the server's typed
client — for a Dart server, the server package, which already depends on
flutterware for inspection. Each is declared, the way Run's entry points are:

```dart
fw.use(Worlds(packages: [
  .new(server, worlds: [
    WorldScript('tool/worlds/pickup_order.dart', name: 'Pickup order'),
  ]),
]));
```

Declared rather than scanned for, because a project has a few worlds, each
named on purpose — scanning pays for many small things, like scenarios and
previews. The first build listed a `worlds/` folder and kept the files that
mentioned `World.run(`: a folder Dart does not know and a guess at what a
file is. `tool/worlds/` is where the files go, since they are scripts the
project runs rather than code it ships; the declaration is what makes them
worlds. `worlds open` takes a world by its file's name, so two of one name
are refused in the config.

The studio runs the file in that package when a world opens, keeps the
process alive while it is open and stops it on close.

**As built in slice 0,** the owner — the studio, `fw` or the MCP server —
binds a unix socket before it starts the script, and names it in the
script's environment; the two speak JSON lines over it
(`lib/src/world/protocol.dart`). The script runs with `dart run --resident`:
a resident compiler per opening, shut down when the world closes, whose
kernels outlive it on disk — so a script that imports a whole server compiles
once, and every later opening and restart starts it in a fraction of a
second (round 1). Other processes find the world through a handle, one file
per worktree in the run directory, naming the owner's pid and a second
socket on which the owner answers `status`, `invoke`, `restart` and `close`
for them (`app/lib/src/world/world_owner.dart`): whoever opened a world
owns it, and everyone else can still ask it. A script run with no owner
prints what it declares instead, which is how its setup is debugged.

### A sketch

Sketched on a coffee shop with a staff dashboard and a customer phone app —
the consumer's shape, none of its names:

```dart
// server/tool/worlds/join_the_loyalty_card.dart
import 'package:flutterware/world.dart';

import 'src/local.dart';

/// A barista, and a regular who has never installed the app. The invite is
/// not sent: that is the first thing you do.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);

  var shop = await server.shop('Canal Street ${w.id}');
  var ana = await shop.staff('ana.${w.id}@example.com', 'Ana', role: Role.barista);
  var leo = await shop.customer('Leo', phone: testPhone(w.id));

  w.person(
    'Ana',
    email: ana.email,
    userId: ana.id,
    app: Launch('Dashboard · Local', knobs: {...server.knobs, 'session': ana.token}),
    on: Studio(Devices.macbookPro),
  );
  var customer = w.person(
    'Leo',
    phone: leo.phone,
    userId: leo.id,
    app: Launch('Shop · Local', knobs: server.knobs), // signed out on purpose
    on: Studio(Devices.iphone16),
  );
});
```

A person takes any subset of email, phone, user id and password: a person who
signs up during the world is declared by a phone number alone, and gains a
user id when the server makes one.

The helper every world of the project shares. For a Dart server that runs on
the host, the world can **host the server in its own process**, and wiring an
edge becomes a constructor argument:

```dart
// server/tool/worlds/src/local.dart
Future<LocalServer> startLocalServer(World w) async {
  await w.stack('Local stack').up(); // the declared DevStack: probe, start if down
  var app = await startServer(       // the local entry point's main, as a function
    port: await w.freePort(),
    email: SmtpEmail(w.outbox.smtp), // the catcher, not the real relay
    sms: WorldSms(w),                // one small adapter per edge interface
    push: WorldPush(w),
    clock: w.clock,
  );
  w.onClose(app.close);
  return LocalServer(app, w);
}

class WorldSms implements SmsService {
  WorldSms(this.w);
  final World w;

  @override
  Future<void> send(String phone, String body) async =>
      w.outbox.sms(to: phone, body: body);
}
```

And what a world may do beyond setting up — all optional:

```dart
  await w.ready;                                    // every person's app launched
  await w.act('Ana', tap('Invite to the loyalty card')); // play the first moves

  w.action('Leo orders a flat white', () => leo.api.order(Drink.flatWhite));
  w.action('Job: fail the next one', () => server.worker.failNext());
  var language = w.knob('language', options: ['en', 'fr'], initial: 'en');

  var ben = await shop.staff('ben.${w.id}@example.com', 'Ben', role: Role.manager);
  w.person('Ben', email: ben.email, userId: ben.id); // headless
  w.action('Ben approves the refund', () => ben.api.approveRefund(leo));

  // Whoever turns up from outside gets this app, on this device.
  w.newcomers(app: Launch('Shop · Local', knobs: server.knobs), on: Studio(Devices.pixel8));

  // The device is part of the world; an action may take a while.
  w.action('Leo walks to the shop', () => customer.device.moveAlong(route));
  var network = w.knob('Leo’s network', options: ['online', 'offline']);
  customer.device.offline = network == 'offline'; // a knob change restarts the world
```

### Who writes what

| `package:flutterware/world.dart` | the project |
|---|---|
| the lifecycle: run, progress, `ready`, `onClose`, restart | the server's local entry point as a function with injectable edges |
| unique emails, phones and names; everything tagged with the world id | seeding helpers over its own typed clients |
| `w.person`, `w.newcomers` and `Launch`, mapped onto Run entry points and their knobs | one adapter per edge interface, reporting who each message reached |
| `person.device`: location, network, background — driven per kind of device | one file per world |
| `w.outbox` (with `ask`), `w.clock`, `w.action`, `w.knob`, `w.act`, `w.stack`, `w.attach` | |
| allocating one device per person, and announcing people, messages and panels to the studio | |

### Semantics

**Restart is close, then run again.** `onClose` runs, the script runs anew,
new users come out, and each person's app starts afresh — a new guest over
the program already compiled, in an emptied home — with the new knob values,
not a rebuild. The people are new, so nothing of the last ones may open as
them: a first build restarted each app in place, and at a consumer a
newcomer left signed out by the script opened signed in as the person
before, from the token and the database left in the same folder (round 2). A fresh guest costs about a
second, and the kernel is rewritten first only when the code changed since
it was written — a reload applies edits to running guests, not to disk. On a
Run device, knobs arrive by regenerating the run wrapper, measured at 262 ms
on macOS against 29.6 s for the same change as a define
(`2026-08-12-run-knobs-spike-findings.md`). A world restart costs the seed
plus one fresh start per person, in parallel.

**Identities are fresh every time.** `w.id` is new each opening, and the
script folds it into the emails, names and numbers it makes. It writes them
itself, because what a valid address or phone number looks like is its
server's rule: flutterware's own helpers were removed after a consumer's
server refused their fictional numbers (round 2). Worlds never collide, so two worktrees or two agents can each run one against
the same server, and an app that keeps one local database per signed-in user
starts clean without a wipe.

**A person can precede their account.** A world about signing up declares
the person by the phone number or email the script chose; messages route by
that before the server has a user id for them. Whatever the person needs to
type — email, phone, password — is shown on their node (see the canvas).

**Newcomers are the one hole in freshness.** An address a human types into a
form is theirs, not the world's, so the server may know it from an earlier
run. The SMTP catcher still keeps every email on the machine.

**Sign-in values come from the script.** A launch knob's `options` list fixed
seeded accounts today; a world's users are new each time, so the script passes
the values. Two ways to be signed in: register the user with the real auth
server (exercises the login path, slower), or hand the app a debug session
knob (fast, skips the login screen). A world *about* signing in uses the
first.

**Reload reaches the process; restart runs the setup.** Making people is
the script's `main`, and running it again means new people — a restart, by
definition, as Flutter's hot restart runs `main` again. But the process
outlives its setup: it hosts the server, when the world does, and holds the
actions' bodies and the cards' readers. An edit there should reach the
running world without new people, the way a hot reload reaches an app: the
script run under a VM service and reloaded from the resident compiler that
already compiles it (slice 3). A world attached to someone else's server
reloads that server by that server's own means.

**Cleanup is by tag.** Everything the helpers create carries the world id.
`onClose` removes what the script chooses; a *clean up old worlds* command
sweeps the rest.

**Actions can take time.** Riding a route or ramping a heart rate lasts a
minute: an action reports progress, can be cancelled, and shows as running in
the World tab until it ends.

**Actions are how anyone acts as a person the drive layer cannot reach** — a
person in a browser, a headless person, a shared account. That holds for the
agent too: where `flutterware_act` cannot go, `worlds invoke` can.

**A world acts; it never asserts.** It may play the first moves and hand
over. *Mia mentions Noah; Noah is notified; Zoe is not* is a check, and a
world with checks is a scenario that starts from a world — the live lane's
job, later.

**In-process or attached.** Hosting a Dart server in the world's process gives
full control: edges are arguments, the clock is `w.clock`, the world can stand
in for a background worker. Any other server is attached —
`w.attach(Server.running('orders'))` — and then edges arrive as
`FlutterwareServer.event`s and email over SMTP, with no clock.

**The world clock reaches Dart code only.** The database's `now()`, the auth
server and the sync service keep their own. A seed that writes
`now() - interval '240 days'` is not moved by `w.clock`. And advancing it
moves a scheduler only if the scheduler reads the injected clock: one that
sleeps on real timers, or asks the database what time it is, never notices.
For those the world offers *run due jobs now* as a server panel action. Time
is the least generic part of this design — only as movable as the server
lets it be.

**Some states the public API cannot reach.** *Subscription expired three days
ago*, *the job failed*: those need debug endpoints or server panels. Rich data
that goes through upload and processing needs a shortcut that attaches results
directly.

## The server in the world

### Monitored — already

The Server panel shows `http`, `sql` and `log` events a server sends through
`FlutterwareServer.event`, correlated by request id. The canvas adds a server
node that summarises them; nothing new is required of the server.

### Edges redirected

| edge | how it reaches the studio | why that way |
|---|---|---|
| email | an SMTP catcher run by flutterware, which the server *and* every third party that mails point at | an auth server sends its own verification and reset emails — a wrapper around the server's email service never sees them |
| SMS, push | the server's adapter emits `event('sms' \| 'push', …)` with a typed payload | there is no local protocol to catch them at |
| background jobs | events, plus controls: finish now, fail, delay | a job is an edge the world can *play* when no worker runs locally |
| payments | an edge that asks (below) | a charge waits for an answer |
| outbound webhooks | later, same pattern as SMS | |

**An adapter reports who a message reached.** A push to a topic or a group
has no recipient to route by, so the adapter reports the users the server
resolved it to — routing needs a person, not a topic.

In the consumer, all six edges were already one interface each, with local
implementations: SMTP to a mail catcher, an in-memory SMS logger whose
messages nothing read, real FCM with a committed service account, payments
off, webhooks through a gateway. Redirecting them is one adapter per
interface in the local entry point.

The Server panel renders a channel it does not know as a generic row, so each
message kind needs a viewer (below).

### Edges that ask

A charge, a 3-D Secure challenge, an OAuth consent screen: the server waits
for an answer from outside. The adapter asks the world, and the outbox shows a
**question** — a pending item with its choices — answered by a human, by the
agent, or by a knob set in advance:

```dart
class WorldPayments implements PaymentService {
  WorldPayments(this.w);
  final World w;

  @override
  Future<ChargeResult> charge(Customer c, Money amount) async {
    var answer = await w.outbox.ask(
      'Charge $amount to ${c.name}',
      choices: ['Approve', 'Decline', 'Ask for 3-D Secure'],
      unless: w.knobValue('Next charge'), // answered by the knob when it is set
    );
    return ChargeResult.from(answer);
  }
}
```

A third party's hosted page — the provider's checkout, its card form — is
served by the world as a stand-in and drawn as the edge's own viewer, not as
a node: the vocabulary holds without a new kind of thing.

### Server panels

A server exposes views and controls of its internals through the **devbar
panel vocabulary** — states, knobs, feeds, actions, item actions — rather than
a second protocol. The contract is already Flutter-free
(`lib/src/channels/panels.dart` imports none), and the door already exists:
`FlutterwareServer.handle(channel, method, handler)` (`inspector.dart:134`),
which the Server panel never calls. The outbox is then a feed, *open in app*
an item action, jobs a feed with finish/fail/retry, the clock a knob.

Generic rendering is for knobs, actions and short feeds only. The generic
panel renderer failed on the first data-heavy panel it met (2026-08-12:
*"the panes are mostly empty"*), so every message type gets a bespoke viewer
chosen by its type.

## Delivering into apps

**Routing.** By recipient first: an email address or phone number names a
person. If that person has several apps, by the link's shape — the app or the
script declares which paths it takes. If nobody matches, the recipient is a
**newcomer**: the viewer offers *Add <recipient> to the world*, on the app and
device the world's `w.newcomers` names, or *Open in a browser*. Without that
default, adding someone asks three questions at the worst moment.

**Three kinds of delivery.** A link is *opened*, a push is *tapped*, a code
is *typed* — into the person's focused field. In a guest it arrives through
the guest's own text input, which the studio stands in for, the way an
autofill offers a code: the field that has focus takes it, and with nothing
focused the delivery refuses and says to tap the field first. Not the drive
layer's `enterText`, which needs a target naming the field. iOS's
one-time-code autofill is an OS feature a simulator cannot show; typing is
honest about that.

**Mechanism, per kind of device:**

- **Guest** — through the plugin's own channel, answered by the studio: a
  link arrives on the link plugin's event channel, a notification's tap on
  the notification plugin's own callback — both measured
  (`2026-09-25-worlds-guest-phase3-findings.md`).
- **macOS window, simulator, phone** — through the app: a devbar panel that
  calls the app's own link and notification handling. The consumer already
  exposes an `open(url)` action straight into its deep-link pipe; brewline's
  push panel does the same for notifications. The OS paths were measured and
  are poor: a warm `simctl openurl` delivers nothing to Flutter on iOS, and
  `simctl push` takes a flat 30 s and cannot fail
  (`2026-08-24-run-device-tab-capability-findings.md`); Android's `am start`
  works. Delivering through the app tests the app's handling, not the OS's
  link association — a trade worth stating, and one that also sidesteps links
  a local server builds with the wrong host.
- **Browser** — navigate the tab. A link is already a URL.

**Viewers.** Email in a webview — the studio is a real app, so a native view
works there, unlike inside a guest — with every click intercepted and routed,
never followed. A rendered picture of each message as well, for history and
for comparing branches: built, both (*The outbox, begun*). PDF pages through pdfium, including a PDF attached to
an email. SMS as a bubble; push as the banner scenario beats already draw. A
question as a card with its choices.

## Where a person's app runs

Every person's app is **a Run app**, whatever runs it, so logs, network,
inspection, panels and drive come from Run unchanged and the world adds none
of its own. On a simulator, a phone or a macOS window it is a Run launch. A
guest is not launched by Run: the world builds one kernel for all its guests,
starts one process per person, and announces each to Run as the device
`studio-<person>` — and as that app's launcher, registering the reload and
restart services `flutter run` registers, so Run's reload and restart reach
it too. Measured: every Run tab and verb works on a guest, and drive round
trips are no slower than a macOS window's
(`2026-09-25-worlds-guest-phase4-findings.md`).

| runs on | on the canvas | plugins | cost to start | known traps |
|---|---|---|---|---|
| embedded guest — **the default** | live, sharp at any zoom | the app's own Dart halves; the studio answers the platform and the plugins a world acts through, 18–60 lines each, and the project fakes the rest behind a knob | no native build: a two-person world in 8.6–11.3 s from a cold worktree, 2 s warm; a person ~240 MB, plus one compiler per world | a plugin nothing answers fails in the app, and the world names it; the Mac's fonts, not the phone's; background is only a lifecycle message; a guest off screen is hidden, and stops rendering; macOS only for now |
| macOS window | a picture after each step; a strip drawn inside the app names the person | real, where the plugin supports macOS | a native build once, cached; hot restart after | two people on the same app share one sandbox container — prefs, keychain; a phone UI needs a platform override; placing the window beside the studio probably needs accessibility access |
| simulator or emulator | a picture after each step | real | a native build | iOS suspends apps in the background; with Simulator.app closed a booted app sits inactive |
| physical device | a picture; there is no window on the Mac | real | build and install | a live mirror is its own feature |
| browser — `Launch.web(name, path:, session:)` on `Browser()` | live if the studio embeds or screencasts it | web | a web build | Run does not drive web today (DWDS): script actions stand in for the agent |

Two findings changed what the guest costs. **A sync library and sqlite3 3.x
load their native libraries through build hooks** — the sync library's old
Flutter plugin package is marked end-of-life and "no longer does anything" —
and the guest's asset bundle already runs build hooks, so real sync in a
guest is plausible.
And **most plugins a real app carries are the kind scenarios already fake**
(paths, preferences, permissions, links, package info, notifications), thin
and stable, unlike the API fake that drifted. What a guest cannot carry is
the camera, a native capture SDK, the photo library and file dialogs: a
person who captures runs on a device. The experiment confirmed the first
finding on a real app — its sync library's native core loaded through its
build hook in a guest and synced against the local server — and measured the
second: six plugins answered in 35 lines each on average, and a real app
carrying 21 plugins with a native half needs about 14 more, sqflite the
largest. Its first screen needed three of them, and reached it signed in and
synced (slice 0).

**Plugins are the project's** (decided 2026-09-29). Answering every plugin a
real app carries is a job with no end, and not flutterware's: counting the 14
the consumer's app still lacked put a database plugin at the top of the
roadmap with no screen that needed it. The studio answers two kinds of
channel — what makes it a platform (the lifecycle, the address, the
keyboard, text input, the cursor, the title) and the plugins a world acts
through or keeps apart per person (links, notifications, the URLs an app
opens, permissions, preferences and secure storage, the person's device).
Three answers built before this line — package info, time zone, Firebase's
start — stay, and no more are added. Everything else is the project's: a
fake in the entry point the world starts, behind a knob, as a scenario fakes
it; the guest registers the plugins' Dart halves before it calls `main`, so a
fake set there wins. A call nothing answers fails in the app, as on a
platform the plugin does not support, and the world says so once a plugin:
in its log, on the person, and as `unanswered` in `worlds status`. Two doors
wait for a case that needs them: a channel the app answers itself in a
guest, for a plugin with no Dart seam to fake — the guest's counterpart of a
scenario's mock handler — and an answer from the world script, for state
people share or the script's actions steer, which is what a peripheral is.

**Where a person's app runs is chosen for what the case needs.** A map drawn
by a native view cannot render in a guest; one drawn in Flutter from tiles
can. Bluetooth that keeps streaming with the phone locked is honest only on a
physical phone — a guest has no background, and the iOS simulator has no
Bluetooth. So worlds mix kinds of device as a matter of course, which the
canvas already assumes.

## The device as an input

The device is not only where an app runs. Every invented world past the
first wanted to *do* something to one: move the courier, cut a network, lock
a phone mid-ride. `person.device` is that API — location (set, or moved along
a route over time), network (online, offline), foreground and background;
battery and permissions later.

The mechanism depends on the kind of device, and the coverage is uneven:

| | location | network | background |
|---|---|---|---|
| guest | a plugin answer in the studio — not built yet | only for the app's `dart:io` traffic, through a proxy the run wrapper installs — not built | a lifecycle message — built: frames and CPU stop, memory is given back; no OS limits behind it |
| iOS simulator | `simctl location` — a point or a route | — the network conditioner is machine-wide | Home, as the native `foreground` verb already presses |
| Android emulator | `adb emu geo fix` | `svc wifi` / `svc data`, `emu network` | the Home key over adb |
| physical Android | a mock-location app | `svc wifi` / `svc data` | the Home key over adb |
| physical iPhone | little that is scriptable | — | — |
| macOS window | — the Mac's own location | — | hiding the window, which is not iOS background |

Two things fall out. A world must say which controls a person's device
*cannot* honour rather than silently ignore them — the same rule as Run's
device strip, where a toggle nothing reads is worse than no toggle. And the
guest whose platform calls the studio answers is the only kind that controls
location and permissions uniformly — one of the reasons it became the
default.

### One device per person

Three people on *iPhone 16* cannot share a simulator: one app, one instance.
The script names a **kind** of device; flutterware **allocates** one per
person — a `simctl clone` named after the person, an emulator instance —
boots it on first use, and removes or keeps it warm on close. A physical
device is one person's by definition.

### Isolation is the world's guarantee

Two people on one app must not share storage. Per kind:

- **guest** — each guest is its own process with a home of its own: the
  studio keeps its answers there, and `CFFIXED_USER_HOME` points Foundation
  at it, so even a plugin that calls Foundation directly — `path_provider` —
  finds the person's folders. Measured: no shared state, nothing asked of
  the app;
- **simulators and phones** — one per person, by allocation;
- **macOS windows** — two windows of one app share one sandbox container
  (preferences, keychain, files), so it takes a data-directory knob the app
  honours, or a bundle id per person. The weakest of the kinds, and an open
  question.

## The canvas

```
 ┌ Worlds · Join the loyalty card ────────────── − 72% + Fit ┐┌ Timeline ─────────┐
 │  [Ana]  Dashboard · Studio         [Leo]  Shop · Studio   ││ ● Ana  tap Invite │
 │  ┌─────────────────────────┐       ┌─────────┐            ││ ● SMS to Leo      │
 │  │  live dashboard         │       │  live   │            ││  Open in Leo’s app│
 │  │                         │       │  phone  │            ││ ● POST /invite 201│
 │  └─────────────────────────┘       └─────────┘            ││ ● job queued      │
 │  ┌ Server · up · 1 job ────┐       ┌ Mia ────┐            ││   Finish · Fail   │
 │  │ requests · jobs         │       │ Pixel 8 │ not live   ││                   │
 │  └─────────────────────────┘       └─────────┘ step 4     ││                   │
 └───────────────────────────────────────────────────────────┘└───────────────────┘
```

**Everything in the world is a node,** not only the people: the server, the
services it uses (*The system beside the people*) and any peripheral sit
beside the apps. A relationship between nodes is a line —
a Bluetooth pairing, dashed while disconnected; later, messages travelling.

**Zoom changes what a node is, not only its size.** Below 70 % every node is
a card: who, where it runs, one status line. From 70 %, live screens with a
label above them, so text is never drawn too small to read. The same
threshold saves work: a guest drawn as a card, or off screen, stops producing
frames, so a ten-person world costs little until you look at it. The canvas
has to make that true: a guest does not know it is not drawn — one scrolled
out of view kept rendering at 12.5 % CPU and ~430 MB while it animated — so
the canvas tells it. **Built** (2026-09-29): an app out of view for two
seconds — another person in focus, or zoomed off the stage — is told it is
`hidden`, the state a desktop gives a minimised window, and `resumed` the
moment it is back. Not `paused`: that is a phone put away, and an app that
disconnects or stops syncing there would behave differently depending on
where the studio was looking. Hidden, the framework asks for no frames and
the app runs on; the lab's spinning app went from 20–28 % CPU and 684 MB to
0 % and 268 MB. A drive still reaches a hidden app, forcing the frames it
needs as it does for a hidden window, and *Send to the background* under
`⋯` is still `paused`, whatever is drawn.

**A guest stays sharp at any zoom.** Its logical size must stay the device's —
layout depends on it — but it can render at zoom × pixel ratio without laying
out again, since a pixel-ratio change leaves the logical size alone. The scene
canvas already renders its guest through the studio's view
(`lib/src/scene/host.dart`). A picture of an external device blurs when zoomed
in.

**Focus is a zoom and a drawer.** Double-clicking a node, or its name in the
toolbar, fits it, dims the rest, filters the timeline to it and opens the
drawer that suits it: Run's tabs for an app, state and a Bluetooth log for a
peripheral, requests and jobs for the server. Esc returns to everyone.

**The timeline is the spine.** Rows are coloured by person so cause and effect
read across people. A message carries its delivery (*Open in Leo's app*); the
outbox is the same list filtered to messages; the World tab holds the
script's actions and knobs.

**A node flashes when something lands on it,** so a zoomed-out world shows
where things happen without reading anything.

**External nodes say what they are:** *Not live · step N*, with *Show* to
bring a simulator's or macOS window forward, and *Mirror* reserved for later.

**A person's node carries their credentials** — email, phone, password, the
last code sent to them — shown, copyable, and fillable into their app.
Without it, a human re-reads the script to find the number it made
up.

**Questions wait where they are seen:** a pending question sits on the server
node and at the top of the outbox until someone answers it.

**Mixed worlds are the normal case** — a staff member in the studio, a
customer capturing on a real phone. The canvas draws guests live and
everything else as pictures, so *every app in a macOS window* is the same
canvas with every node a picture. The layout does not depend on the
experiment's outcome.

**Layout is arranged, then yours.** By kind — desktops on the left, phones to
the right, a peripheral under what it is paired with, the server along the
bottom — then dragged by hand and remembered per world. A script may name
groups; it never gives coordinates.

**In the studio:** a *Worlds* entry in the rail with a row per world. Each
person's app is also a row in Run, because it is a Run launch. The address is
`fw:///worktrees/<worktree>/flutterware.worlds/<world>[/<person>]`.

## The system beside the people

The consumer's first round with worlds asked for more than people: the
system they use, drawn beside them. Its team prototyped it as a page the
world serves, over its own stack, before asking for an API — so what follows
was designed against real traffic, and its numbers are that world's.

**A service is a node,** like a person: a card with what it holds — the mails
sent, the files in a bucket, the rows the world made — links to its own
console, and a status. Work passing from one node to another is a **flow**: a
dot travelling along the line between them, and a row on the timeline in its
person's colour.

**Movement has three sources,** and they reach different places:

| source | how | the world hosts the server | the world attaches to one |
|---|---|---|---|
| the server | its adapter, reporting through `FlutterwareServer`: request middleware, a query observer, the mail, SMS and job services | requests, reads and writes, messages, jobs | the same: the world attaches to every server announcing itself under the worktree, whichever process it is in |
| the script | `w.flow` from an action | works | works |
| each person's app | Run already records its HTTP and its logs; a service declares the origins it answers on, and a person's traffic to one is a flow | works | works — it needs nothing from the server |

The third is the one to build first. The prototype got *the change reached
Leo* by decoding a sync service's binary stream on the server's proxy —
protocol-specific and fragile — while the app already logs each checkpoint it
applies, and the studio already sees every app's traffic.

**Layers.** Watching a world, the question is rarely *what did the sync
service do*; it is *did Leo get it*, or *is the photo still processing*.
Every node, flow and span carries a layer, and the viewer picks one, seeing it
and every layer above it:

| layer | what |
|---|---|
| **Product** | what a person does, what reaches someone else, work people wait on |
| **System** | the parts, and the work passed between them: calls, messages, jobs, files |
| **Wire** | the plumbing: SQL, sync streams opening, sync operations |

On one world, from opening to a record one person shared with another, the
prototype recorded 60 events: 4 on Product, 14 more on System, 42 more on
Wire. With every phone syncing every 30 s, Wire keeps growing while nothing
happens; Product does not. The canvas opens on Product.

What building it taught, each an ask of the canvas:

- **Product is named by the project, never derived.** A route means nothing
  until someone says *places an order*; a domain event the server reports —
  *the photo is ready* — is the other way in. A **moment**
  (`w.moment('Ana', 'places an order')`) is its own kind of event, beside
  flows.
- **A coarser layer folds the hops it hides,** not only hides them. On
  Product, Ana → API → database → sync → Leo is one arrow, Ana → Leo. Within
  a request the chain is the request's; across to the sync that follows it,
  the prototype could only bind by timing. That wants a trace id that
  survives what the server hands off, and chains folded by the canvas rather
  than by each project.
- **Flows are about people, and a person comes before their account.** A
  flow names its person by any identity the world knows — email, phone, user
  id — and identities are added as the world learns them: an invitation
  leaves before its recipient has an account.
- **Receiving is not everything that arrives.** A person's first sync carries
  everything written before they connected; only what was written after
  reaches them. And a message sent while someone acts is that person reaching
  its recipient.
- **The world's own reads are not traffic.** Opening a card reads its
  service; those reads are tagged as the world's and never drawn.
- **History matters more than live.** Most flows happen while the world
  opens — sign-ups, invitations, a first sync — before anyone looks. Flows are
  kept with the world, and the timeline starts at its opening.
- **Coalesce.** One request runs several queries; one checkpoint completes
  several times. Same from, to and label within a short window is one dot,
  with a count.
- **Contents are pulled, and slow.** Read when a card opens or a flow touches
  it; the last contents shown at once and refreshed behind them.
- **Degraded, and saying so.** A card whose source is silent in this world —
  attached, or not wired — is marked *unreported*, with the reason: never an
  empty card that looks quiet. Run's device strip keeps the same rule.
- **Long work needs a start.** `FlutterwareServer.span` reports once, when
  the work ends, so a job that takes minutes shows nothing until then. A span
  reports its start, and how far it is.
- **Lines are architecture, not traffic.** Straight lines between every pair
  crossed every card by the fourth service: lines are routed, or drawn faint
  and lit while something moves along them.

**The outbox is part of it.** The mail and SMS cards are the outbox's
viewers, and their items carry the deliveries (*Open in Leo's app*), so the
outbox is built as the first cards rather than as a list of its own.

A draft API, from the prototype's stand-in:

```dart
w.service(
  'photos',
  label: 'Storage · photos',
  kind: ServiceKind.storage, // the icon
  group: 'Stack', // the lane
  links: {'Console': consoleUrl},
  origins: [storageUrl], // a person's traffic here is a flow
  contents: () async => [
    for (var object in await bucket.list())
      WorldItem(object.key, detail: '${object.size} B', opens: object.url),
  ],
  layer: Layer.system,
);
w.line('api', 'photos');

w.flow('Ana', 'api', 'places an order');
w.moment('Ana', 'places an order'); // Product
var job = w.span('menu', 'photo 42', person: 'Ana');
job.progress(0.4);
job.end();
```

From a server — the world's own, or one it attaches to — over the channel
servers already report on:
`FlutterwareServer.event('world.flow', {'from': 'api', 'to': 'mail', 'label': subject, 'email': recipient})`.

The readers and reporters stay in the project's `tool/`: nothing in its
`lib/` knows about worlds, and labels carry steps, statuses, ids and
durations only.

### Traces, as built

A spike, then the world itself (`app/lib/src/world/world_trace.dart`), made
the three sources above one thing: every **step** a person or an agent takes
on an app, with what it caused. Dart servers only, and nothing a project
imports beyond `package:flutterware/server.dart`.

- **A step is born on the device.** The guest's binding dispatches each
  gesture inside a zone naming it — `ben.3`, the person's own counter — and
  publishes it on the app's channels with what it landed on, spelled as the
  drive targets are (`tap "Order"`). Typing is not a step: a character never
  arrives as a pointer.
- **A request carries it.** An `HttpOverrides` stamps `x-fw-step` on every
  request the app opens: the zone's step, or — for work a tap started outside
  its callbacks, a sync engine's upload loop — the step that ended under
  1.5 s ago, and each request says which way it joined.
- **A server reads it in one line.** Its adapter puts the header in the zone
  as `FlutterwareServer.stepKey`; every event reported under it — the
  request, its writes, what it broadcast, the SMS it sent — then carries
  `step`. Two primitives say what only the server knows: `identify(user)` —
  who a request is, so a person who signed up themselves is learnt — and
  `reach(user, what)`, for what arrives on a connection nobody asked on.
- **A synced record joins by its key.** A tap writes locally and the engine
  uploads later, from its own isolate; the service fans the change out. The
  database panel reads the engine's own tables (`sync: DatabaseSync.powersync`)
  into a `records` feed: each local write, each record a checkpoint brought
  in. An arrival joins the step whose server write of that key came last.

`worlds trace` answers with the newest steps, each with its consequences as
lines — `+32 ms  Cleo  orders/08468cae arrived (op 24)` — and each person's
`sync` line is in `worlds status` and beside their phone. What the canvas
draws is this, and nothing invented: the rounds' boards were redrawn from
real traces before anything was built.

**What a part holds is the same record read the other way.** Open a part of
the system and it lists what the world heard it do since the opening,
whoever caused it, each with its step: a route's calls and who asked, a
table's records, the messages sent outside and whom they reached, the
records the sync engine carried. A record carries its life, joined by its
key — `+0 ms written on Ben's phone`, `+9 ms lab wrote it insert · status
placed`, `+21 ms arrived on Cleo's phone` — across every step that touched
it. `worlds contents {part}` answers the same. Contents are heard, not
pulled, which is less than *Contents are pulled* above asks: a table shows
the records this world wrote, never the ones seeded before it, and a record
a first sync brings that no server here wrote is only counted. A server
answering what it holds now is a server panel's job (slice 3).

Measured on the lab (`2026-09-26-worlds-trace-spike-findings.md`): 8 of 8
requests after a tap joined through the zone; a synced order reached the
other phone 23–40 ms after the tap and was confirmed back after ~255 ms.

**The world's own actions step too.** Each run of an action is a step the
owner names — `world.3` — and the script runs the action under it, stamping
every request it sends the way a guest does. *Mia orders a flat white* is
then traced like a tap: her sign-up, her order, the write, the record
arriving on Cleo's phone 44 ms later. `worlds invoke` answers with the step.

**A consumer's third round** (2026-09-27, three worlds on a real app) moved
five things:

- **A hand-off keeps its step when the project carries it.** A job queued by
  a request, or a storage notification after an upload, ran on no step: the
  consumer's richest flow — an upload, its callback, jobs writing for 16 s —
  had no cause after the upload. `FlutterwareServer.step` reads the current
  step and `FlutterwareServer.inStep(step, body)` re-enters it; the project
  keeps the step with the job's row or the object's metadata. No timing
  fallback: the consumer's round-2 prototype joined a write to the next sync
  by time and drew an arrival that never happened.
- **A delivery is a step.** A typed code joined the tap on the field before
  it, by time, and an opened link joined nothing. Each is now the person's
  next step (`leo.3 typed the code from the SMS`): the code's field callbacks
  run in it, and a link, which arrives on the plugin's own stream, is joined
  by the guest's window from the delivery rather than from the tap.
- **Statements fold into their request.** 8 to 23 bare `server  sql` lines a
  request buried the write, the push and the arrival. A request's line counts
  them (`12 statements, 9 ms`), its writes stay lines, and the statements open
  on demand. An event of a channel the trace has no words for still shows a
  gist of its fields.
- **A table can sit in a layer** (`'layer': 'jobs'` on `write`), beneath the
  records people act on: job-queue tables were 3 of 12 parts.
- **A record's bucket travels with its arrival.** Two seeded records arrived
  33 s after later ones; the feed reads arrivals at the first database change
  after the app applied them, so a record listed late was applied late, most
  likely in a bucket that reached the phone later. The feed now says which.

**A fourth round** (2026-09-27, four worlds) carried a step across every
hand-off the consumer's richest flow has — a storage notification, four
background jobs, a worker job — and the step grew from 3 requests to 74
lines over 39.7 s, with 37 writes and 17 arrivals on both phones. That made
the trace's shape the problem, and moved it:

- **A step is a tree.** Each request and each job heads what it did, by its
  request id — an app's request, an action's, a storage callback's, a
  worker's job alike. Its statements, and its writes to a table in a layer,
  are counted on its line; its other writes, messages and reaches sit
  beneath it. A write says what changed, and a record updated in a row is
  one line (`updated … ×16 · status queued → … → ready`). Work under no
  request folds by bursts, not into one line per server over the step.
- **`FlutterwareServer.job(name, body, step:, id:)`** does what the consumer
  wired by hand in three places: re-enter the step, run as a request of its
  own, say when the job started and ended.
- **A record is its table and its key.** Joining by key alone put a side
  table's parent in its life; a phone table no server has still joins by
  key, as a renamed table must.
- **A record arriving in a bucket new to the phone says so.** Their two
  seeded records arrived 80 s late on both phones at once: the app had just
  subscribed to a stream keyed by one person's id. An arrival is when the
  phone applied the op; the subscription is the cause.
- **Mail pictures are read as UTF-8**, as their mails and ours carry the
  charset in the MIME header only; `w.smtp(address:)` for a service in a
  container; a message another service sent is named by it,
  `identity/server-27`.

Link path prefixes a project could declare were left: an adapter naming its
`link` already hands over the right one.

**An app's start is its first step**, `ana.0`: what it sends before anyone
touches it — nine calls a phone in the consumer's app, config to sync
streams — joins it by window, for 10 s or until the first gesture.

What it does not do yet, each a known next step: the world's opening takes
no step, because what its body starts — the server it hosts, a timer —
would step under it for ever after, so the sign-ups a script seeds are
still nobody's; a gesture's name is its nearest label, so one of several
identical buttons is named by position; a request that is not `dart:io`
HTTP — gRPC, a platform HTTP client — carries no step.

### The outbox, begun

Built from what the servers already report, as the traces are: every `sms`,
`push` and `mail` event an adapter sends with its recipient is a message, the
person it reached found by phone number, user id or address, and the step
that sent it kept. A message carries a code — four to eight digits, in a
message that speaks of a code — and a link: the one the adapter names, else
the first the recipient's app declares it opens (URL schemes and associated
domains, Android `VIEW` filters, read from the project), else the first on a
scheme of an app's own, else the first. The consumer's invitation mail listed
two store badges before its invitation, and the first URL was a badge. A push
shows its body under its title: theirs are titled with the sender's name.

Each person's drawer opens on their messages, and the SMS and push cards'
contents carry the same deliveries: *Type it* puts the code into the field
that has focus in their app, *Open* or *Tap it* opens the link where the OS
would deliver it. Either lands in the person's Run journal as the step of
whoever asked. `worlds outbox` and `worlds deliver` are the same for an agent.
Measured on the lab: Leo's sign-up code typed into his code field, and the
push his order sent opened on that order.

**Mail is read two ways** (`2026-09-27-worlds-web-display-spike-findings.md`).
A mail event carries its HTML, and the column opens it as a **picture**
WebKit draws — a Swift helper compiled on first use, half a second a mail,
each link drawn clickable where it sits — or as the **page**, live in a
WKWebView. A link goes where a phone would send it: an app's link into the
person's app, a web link to a browser, here the page view; every link is
also listed with *Open in Leo's app*, for a web link the app claims.
`worlds show` hands an agent the picture and each link's box.

**How mail gets in is the project's, in several ways.** flutterware maintains
no client for a third-party catcher's API — every catcher's API is a moving
target, and its bugs would land in the wrong place. A project reports each
mail from its own mail adapter, as it does SMS and push, and a watcher the
project keeps over its own catcher is as good a reporter. A message says
which service sent it (`'from': 'identity'`) and is drawn as that service's
node; a service that is not Dart carries no step, so its message joins the
newest step heard in the 3 s before it, and says so. The real case came in
round 3: an identity provider sends the sign-up code itself, over SMTP, and
the world's own SMTP inbox is the answer flutterware owns (*The outbox*,
below).

No questions or newcomers yet.

**A web page in the panel, now possible.** The consumer asked for
`w.view(name, url)`, to draw its prototype's page beside the people until the
canvas exists. This was turned down because a web view meant a native plugin
in every user's build; the studio already built four, and now carries the
web view mail needed, so the objection is gone. The view itself is not
built: the page opens from a world action meanwhile.

## The agent's surface

- `worlds list`; `worlds open {world, knobs}` returns the people and their
  apps' run keys; `worlds restart`; `worlds close`. Any process can ask a
  world another one owns: `status`, `trace`, `contents`, `invoke`, `restart`
  and `close` are forwarded to the owner (round 1).
- `worlds trace {person?, step?, limit?}`: the newest steps on the people's
  apps and the world's own actions (`person: world`), each with what it
  caused (*Traces, as built*). The agent reads an SMS code there as readily
  as the log, and `worlds invoke` answers with the step its action ran as.
- `worlds contents {part?, limit?}`: what one part of the system holds —
  a route's calls, a table's records and their lives, what was sent — or,
  with no part, the parts there are.
- `flutterware_act` gains a `person` selector beside `device`, `entrypoint`
  and `run` (`_selectApp`, `run_core.dart:5201`). Its existing `actor`
  argument keeps saying who is driving.
- `worlds outbox {person?}` reads messages; `worlds deliver {message, how?}`
  types a message's code or opens its link, whichever it carries (built:
  *The outbox, begun*); `worlds answer {question, choice}`;
  `worlds invoke {action}` runs one of the script's actions.
- `worlds device {person, location | network | background}`, refusing — with
  the reason — what that kind of device cannot do.

One call hands an agent a setup with several people in it. Flows that cross
from one user to another are the ones no tool lets an agent exercise today.

## Peripherals — the door, not the room

A peripheral is a node with a model and a panel, both declared by the world
script (`w.peripheral(...)` with its own actions and knobs: press the button,
battery low, disconnect, stream a recorded trace). Two ways into the app:

- a fake at the Bluetooth plugin's interface that talks to the world — works
  in a guest and in a macOS window; the iOS simulator has no Bluetooth;
- the Mac advertising itself as the peripheral, so a physical phone connects
  over real radio with no change to the app.

Spike both before choosing. The script never says which: it says what the
peripheral *is*, and the kind of the paired person's device decides how it is
reached. Standard profiles — heart rate, battery — are generic enough for
flutterware to ship their models; a custom device needs one the project
writes, and that model is where drift moves: keep it at the protocol level,
and share it with firmware tests where there are any. Nothing in this design
depends on peripherals beyond node kinds staying open.

## The device experiment

**The question:** should a person's app default to the embedded guest?

| # | candidate | native build | plugins |
|---|---|---|---|
| 1 | guest, plugins faked in Dart — scenario fakes reused | none | fakes |
| 2 | guest, **the studio answers the platform calls** | none | the app's real plugin Dart code; the studio emulates the native half |
| 3 | a macOS app rendering off screen, its pixels shown in the studio | yes, cached | real |
| 4 | a macOS window with a flutterware strip drawn inside it | yes, cached | real, where supported |
| 5 | simulator or emulator | yes | real — the reference for truth |

Candidate 2 deserves the hardest test. The app runs its own code; only the
native half of a plugin is answered, by a studio that therefore sees and
controls every call. A local notification lands on the canvas as that person's
banner and a tap goes back through the plugin's real callback; a link arrives
on the link plugin's own event channel; permissions become a switch. Plugins
that moved to calling Apple frameworks directly may simply work, since a guest
is a macOS process. The cost is one emulation per plugin, which can drift at
the plugin's protocol.

Candidate 2 also carries two arguments the paper cases found: it is the only
kind that gives each person their own storage without the app's help, and
the only one that controls location and permissions the same way everywhere.

**Restart does not discriminate.** Every candidate restarts a world by hot
restart with new knob values, so an earlier draft's rule — *restarts a world
3× faster* — measured nothing. What does: opening a world from a cold
worktree until every screen is showing, whether a human can type in it, and
what each plugin costs to answer.

**The plan that settled it** — the lab fixture, five phases with kill points
after the second and fourth day or so, a scorecard per candidate, and a
go / narrow go / no-go rule fixed before measuring — is
`2026-09-25-worlds-guest-experiment-plan.md`.

**The result: go** (`2026-09-25-worlds-guest-phase5-decision.md`). Every phase
passed, and a two-person world opened from a cold worktree in 11.3 s against
31.6 s for macOS windows and 43.2 s for simulators. Candidate 2 is the
default: its answers are flutterware's, written once per plugin, where
candidate 1's fakes are every project's to write. Candidate 3 was never
triggered. *Narrowed 2026-09-29:* flutterware's answers stop at the platform
and the plugins a world acts through; for the rest, candidate 1's fakes are
the project's after all (*Plugins are the project's*).

## Slices

0. **World script v0: guests only, no canvas.**
   - `package:flutterware/world.dart`: `World.run`, `w.person` (any subset
     of identity), unique identities, progress, actions that take time,
     knobs and `onClose`.
   - `worlds list`, `open`, `restart`, `close` and `invoke` from the CLI and
     the MCP.
   - Every person's app in a guest: the lab's build, processes, launcher and
     Run announcement, promoted out of the lab. `Studio(device)` is the one
     kind of device the script can name until slice 4.
   - **Whoever opens a world owns it,** as with a Run launch. Opened in the
     studio, its guests are live in a plain *Worlds* panel, the lab's row of
     phones. Opened by the CLI or the MCP, they run headless in that
     process, and the studio sees them as Run apps, in pictures.
   - Restart with new knobs per person, as measured. Run's `setKnobs` keeps
     refusing a guest, and its refusal names the world's restart.
   - Proved on the lab's *Pickup order*, then on the consumer's first world,
     with the plugin answers its first screen turns out to need — three.
     **Done** (`2026-09-25-worlds-slice0-findings.md`).
   - **Round 1**, from the consumer's first day: any process reaches a world
     another owns; the script compiled once by a resident compiler; a log
     stamped with the time since the opening; each guest in its person's own
     folder; `permission_handler`; and an older studio or
     MCP server saying it is older rather than that a plugin has no actions.
   - **Round 2**, from the consumer's second day: every restart starts fresh
     guests in emptied homes; a script that dies on the resident compiler's
     socket is started once more with a fresh one; a failed restart stops
     the last opening's people; guest builds start as the script does, from
     the apps the world used last time; `w.email`, `w.phone` and `w.unique`
     are gone — the script writes its identities, with its server's rules.
1. **A design round, then the system beside the people.** Clickable mockups
   of the canvas with people *and* services, flows on three layers, the
   timeline, focus and credentials, agreed before anything is built. Then
   the first cards: the outbox — the SMTP catcher; typed `mail`, `sms`,
   `push` and `job` events carrying who they reached; questions
   (`w.outbox.ask`); the viewers; newcomers; the three kinds of delivery,
   through a devbar panel convention flutterware publishes for links and
   notifications — and **traces**: each step on an app joined to what it
   caused, through Dart servers and synced records (*Traces, as built*),
   which replace flows guessed from traffic to the origins a service
   declares. Begun: `worlds trace` and each person's sync line; and the
   outbox, from what servers report, mail read as a picture or the live page
   (*The outbox, begun*). Not yet: questions, newcomers, flutterware's own
   SMTP server.
2. **Canvas v1.** Nodes — people and services — with their credentials and
   contents, the timeline, pending questions, focus, the drawer. Guests are
   live from the first version, as the lab already draws them, and hidden
   when off screen (built: *Zoom changes what a node is*); external devices
   are pictures.
   - **Begun, from traces only** (`app/lib/src/world/world_canvas.dart`):
     - the people's phones above a band of the system — each server with
       the parts of its API, the tables it wrote and what it sent outside,
       and the sync engine with each person's client;
     - a column of steps, newest first, that the stage follows until one is
       held open as a waterfall;
     - the shown step numbered on the parts it touched, and drawn as lines
       between each phone and its part, in the person's colour, with what
       crossed written in the gap between them — routed down the channels
       between the parts, so that no line crosses one;
     - the newest step that caused something followed until one is held;
     - the whole stage zoomable as previews' is — a pinch or ⌘-scroll, a
       drag once zoomed, fit to rest — with the phones still taking every
       gesture the stage does not, and each phone drawn again at the size
       it is shown once a zoom settles;
     - each person's platform — notifications, links, sync — moved into a
       drawer that opens from their name;
     - each part of the system opening on what it holds — calls, records
       with their lives, messages, synced records — each item linked to
       the step that caused it, and what the shown step touched marked.
   - **Laid out again after a design round** (canvas: *Worlds design
     round*, 2026-09-27; direction A2). The column had grown five modes
     behind one back link — steps, a step, a person, a part, a mail — and
     a choice could land under another and look like a dead click. Now:
     an outline on the left (people, every part of every server, messages),
     the stage in the middle — the band compact, each server's counts and
     only the parts the shown step touched, so the phones get the height —
     with a *Sequence* view beside the canvas (a lane per person and per
     server, arrows for what crossed), and the timeline on the right:
     steps and messages together, a step opening in place as its tree,
     messages carrying their delivery, the log folded into its foot. One
     sheet over the timeline shows whatever was chosen last, a mail at its
     own width. Open questions, to judge in use: how the band reads on a
     busy world, and whether the outline and the band read as the same
     thing twice.
   - **Stripped back to the phones** (2026-09-27, after judging A2 on the
     lab's busy *Rush hour*). Every layer meant to explain the system —
     outline, band, arrows, numbered trace, a timeline of steps summarised
     by kind — made the screen harder to read, and none started from a
     question somebody had. Now: the people's phones side by side, all in
     view, each with a count of the messages sent to them; a name opens that
     phone in focus beside its messages and Run's own Network, App and Logs
     panes (a panel reaches another plugin's through `NativePlugin.peer`).
     Nothing of the system is drawn. The trace still answers `worlds trace`
     for agents. What comes back on screen comes back one question at a
     time, when using a world raises it.
   - **Redrawn** (2026-09-29, the five frames of the 2026-09-28 UI pass;
     plan in `docs/superpowers/plans/2026-09-28-worlds-screen-pass.md`). One
     toolbar — knobs, actions, and a switch between everyone and one person,
     the rest of a crowd in a `+N` menu. Devices in their bodies on the stage
     grey, all at one scale: an iPhone's, or a browser the studio draws
     around a desktop person's app, whose address bar is the route the app
     reports over `flutter/navigation` and whose tab is the title it gives
     over `flutter/platform`. A crowd fits the stage in the rows that draw it
     largest and zooms from there (the experiment's *Fit*, with *Canvas*
     folded in); a scroll goes to the app under the pointer. A person with
     no app is a card. The focus's panel says who, what caused each message
     in its step's words, marks a push the app showed, reads a mail beside
     the app with what it opened, and keeps the platform's controls under
     `⋯`. The world log is the first tab of the dock Previews, Scenarios and
     Run share.
   - Not yet: focus, credentials, pending questions; contents pulled from a
     server rather than heard.
3. **Server panels** over `FlutterwareServer.handle`, and **reload of the
   world's process**: an edit to the server it hosts, or to an action,
   reaches the running world without new people.
   - **Reload built** (`2026-09-27-worlds-reload-spike-findings.md`): the
     script runs with its VM service on loopback, and `worlds reload` — a
     *Reload* beside *Restart* — hot-reloads it (34–46 ms on the lab) and
     reloads every app as Run does. The body does not run again, and a
     closure made before the reload keeps its body: the guide says to hand
     `w.action` a line that calls a function. A server's router is the same
     case, so `FlutterwareServer.onReassemble` runs after each reload
     (`ext.flutterware.reassemble`, as Flutter's reassemble) and the server
     rebuilds its app there; `reloadable` is the short form for a handler.
     A compile error is refused with the compiler's words and changes
     nothing. Re-running the body on reload, with kept resources, was
     weighed and left for when a consumer asks for new people mid-flow.
   - Not yet: server panels.
4. **Other devices, and the device as an input.** A simulator allocated per
   person, a macOS window when the script asks for one, and the controls
   where the mechanism already exists — `simctl location`, adb — refusing the
   rest by name.
5. **A canvas that shows live the guests a CLI or the MCP owns.** Answers
   for more plugins were to run beside every slice, a database plugin first;
   dropped 2026-09-29 — a plugin a world does not act through is the
   project's to fake, and the world names each one nothing answers
   (*Plugins are the project's*).
6. **Later:** peripherals, people in a browser, live mirrors of external
   devices, a world as a live scenario's setup.

The guest experiment ran beside these and is done; its fixture is the first
piece of the lab, `fixtures/world_lab/`, which now hosts the paper cases in
the order `2026-09-25-worlds-paper-cases.md` gives.

## Not in this design

Peripherals built; worlds in CI; recording a world and replaying it; a
sandbox over a mocked API.

## Open questions

1. **People in a browser or a webview.** A browser can be live on the canvas
   (embedded, or screencast) before Run can drive web at all. Worth having
   observed-only?
2. ~~**Discovery.**~~ Declared in the config, like Run's entry points —
   decided after slice 0 first built a folder scan (above).
3. **Seeding.** Through the public API, debug endpoints, or both — and who
   owns the helpers when the server team and the app team differ.
4. **Large worlds.** Cards scale; three baristas and five customers may still
   want groups that collapse.
5. **Live mirrors of external devices.** Window capture for a simulator, a
   screen stream for an Android phone — only once *a picture after each
   step* proves not enough.
6. **Several servers on one stack.** Whether a world-hosted server on its own
   port can share the stack's sync service and auth server, whose
   configuration may name a single address.
7. **Leftovers.** How long a world's tagged data lives before the sweep.
8. **Two people, one macOS app.** A data directory per person, or a bundle
   id per person.
9. **Live updates between people.** The Server panel shows HTTP; whether it
   shows socket frames decides whether the timeline can say *Zoe's app
   received it*.
10. **A guest's network.** Cutting it covers only the app's `dart:io`
    traffic, through a proxy; a plugin with its own HTTP stack escapes it.
11. **Allocated devices.** Simulator clones kept warm between worlds, or
    removed on close.
12. **A question nobody answers.** How long the server waits, and what the
    adapter answers when the world closes first.
13. ~~**Run changing a guest's knobs.**~~ Decided before slice 0: Run's
    `setKnobs` keeps refusing a guest — it rewrites a wrapper a guest does
    not have — and its refusal names the world's restart, which gives each
    person new knobs. A knobs door any launcher could answer waits until
    something outside a world needs it.
14. **A guest on Linux and Windows.** Linux renders guests today but has run
    no world: it needs a clipboard, and homes through the XDG variables.
    Windows waits for its embedder host.
15. **Services on the canvas.** Lanes by group, then dragged and remembered
    like people — or a fixed diagram the script draws?
16. **Traces.** Whether a flow carries the request id `FlutterwareServer`
    already puts on events, so one trace — Ana's tap to Leo's screen — replays
    as one.
17. **Busy worlds.** Every phone syncing every 30 s, a job queue: how many
    dots before the canvas aggregates.

## Evidence

**From the consumer (read, not run):**

- The mocked-API sandbox: 2,470 lines deleted from the app package on
  2026-08-25; 137 commits to its main file, 133 of them also touching the
  scenario harness's fake. The deletion's own reasons: the scenario fake did
  the job better, every endpoint was stubbed twice, and the mock had drifted
  far enough to mislead.
- The scenario harness's fake: 3,346 lines of Dart over an in-memory SQLite
  the app reads as its synced database; stateful; 47 methods still throw
  `UnimplementedError`; 130 scenarios across 74 files, all on fake time.
- Seeding: one state, applied only on a fresh database; re-seeding is
  `down --volumes` then `up`; the auth server's accounts come from a
  kickstart file read at its first boot only; the seeder signs in with a
  debug-only token and writes some rows as raw SQL.
- Edges: email, SMS, push, background jobs, payments and outbound webhooks,
  each a single interface in the server; the Dart server runs on the host,
  not in compose.
- The app already exposes a devbar action that pushes a URL into its
  deep-link pipe.

**From the consumer's first round (run, 2026-09-25):**

- Two worlds, opened from `fw` a few dozen times: two colleagues signed in
  and synced, one's new record reaching the other at the same sync
  checkpoint; two different apps in one world, two kernels built in parallel
  from one seed; an invitation by text delivered through the app's own devbar
  deep-link panel.
- From nothing — no stack, no database — one `fw` command opened a world in
  57.5 s, 33.0 s of it the stack; warm, ~21 s, of which `dart run` spent
  11.9 s before the script's first line (a 7.4 s, 92 MB kernel compile of the
  whole server) against 1.25 s from a precompiled kernel. Close: 0.4 s,
  nothing left behind.
- At rest: two guests 540 and 493 MB, the script and its server 139 MB.
- One plugin unanswered, `permission_handler`, caught by the app.
- The world could host its own server on a stack of its own, or attach to
  the developer's running server and only make its people there.

**From this repository:**

- `app/native/host.c` set no platform-message callback, so an unanswered
  platform call in a guest hung; the experiment's phase 1 gave it a platform
  task runner, and it now answers or forwards every message.
- `FlutterwareServer.handle` exists (`lib/src/server/inspector.dart:134`);
  the Server panel invokes no server handler.
- `lib/src/channels/panels.dart` and what it imports are Flutter-free.
- Run allows several launches at once, with no limit per device or entry
  point, and selects one by `device`, `entrypoint`, `worktree` or `run`
  (`app/lib/src/plugins/native/run_core.dart:5201`).
- Run's Screen tab is *"not a live mirror"*
  (`app/lib/src/plugins/native/run_plugin.dart:1017`).
- `simctl openurl` and `simctl push`:
  `2026-08-24-run-device-tab-capability-findings.md`.
- Knob changes by hot restart: `2026-08-12-run-knobs-spike-findings.md`.
- The guest and plugins, fake at the platform interface:
  `2026-07-26-s1-scenario-in-embedder-findings.md`.
