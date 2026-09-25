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
(*go*, `2026-09-25-worlds-guest-phase5-decision.md`). A person whose app needs
what a guest cannot carry — a camera, a view the OS draws, Bluetooth — runs on
a simulator, a phone or a macOS window, and external devices stay
first-class. Built so far: slice 0 — `package:flutterware/world.dart`, the
`worlds` plugin (`fw`, the MCP server, and a *Worlds* panel in the studio)
and the lab's first world, *Pickup order*
(`2026-09-25-worlds-slice0-findings.md`).
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
flutterware for inspection. Declared by folder:

```dart
fw.use(Worlds(packages: [.new(server, directory: 'worlds')]));
```

The studio lists the folder, runs the file in that package when a world opens,
keeps the process alive while it is open and stops it on close. The name comes
from the file, the description from its doc comment.

**As built in slice 0,** the owner — the studio, `fw` or the MCP server —
binds a unix socket before it starts the script with `dart run`, and names it
in the script's environment; the two speak JSON lines over it
(`lib/src/world/protocol.dart`). No handle file: the owner started the
script, so it already knows where it is. What other processes need to know —
that a world is open, and whose — is on each person's Run handle, which
carries the world's name. A script run with no owner prints what it declares
instead, which is how its setup is debugged.

### A sketch

Sketched on a coffee shop with a staff dashboard and a customer phone app —
the consumer's shape, none of its names:

```dart
// server/worlds/join_the_loyalty_card.dart
import 'package:flutterware/world.dart';

import 'src/local.dart';

/// A barista, and a regular who has never installed the app. The invite is
/// not sent: that is the first thing you do.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);

  var shop = await server.shop(w.unique('Canal Street'));
  var ana = await shop.staff(w.email('ana'), 'Ana', role: Role.barista);
  var leo = await shop.customer('Leo', phone: w.phone());

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
// server/worlds/src/local.dart
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

  var ben = await shop.staff(w.email('ben'), 'Ben', role: Role.manager);
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
new users come out, and each person's app gets a hot restart with new knob
values — not a rebuild. On a Run device, knobs arrive by regenerating the run
wrapper, measured at 262 ms on macOS against 29.6 s for the same change as a
define (`2026-08-12-run-knobs-spike-findings.md`). A guest reads its knobs
from a file of that person's each time `main` runs, so the world writes the
new values and restarts the app in place: 347 ms, measured with a user the
server had just made (phase 5 of the experiment). A world restart costs the
seed plus one hot restart per person.

**Identities are fresh every time.** `w.email('ana')` is unique to the world
instance, `w.phone()` draws from a reserved range, `w.unique(name)` suffixes.
Worlds never collide, so two worktrees or two agents can each run one against
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
is *typed* — into the person's focused field, through the drive layer's
`enterText`. iOS's one-time-code autofill is an OS feature a simulator cannot
show; typing is honest about that.

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
for comparing branches. PDF pages through pdfium, including a PDF attached to
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
| embedded guest — **the default** | live, sharp at any zoom | the app's own Dart halves, their native half answered by the studio — 18–60 lines a plugin, written once in flutterware | no native build: a two-person world in 8.6–11.3 s from a cold worktree, 2 s warm; a person ~240 MB, plus one compiler per world | a plugin nobody has answered yet fails at once, by name; the Mac's fonts, not the phone's; background is only a lifecycle message; a guest off screen renders until it is paused; macOS only for now |
| macOS window | a picture after each step; a strip drawn inside the app names the person | real, where the plugin supports macOS | a native build once, cached; hot restart after | two people on the same app share one sandbox container — prefs, keychain; a phone UI needs a platform override; placing the window beside the studio probably needs accessibility access |
| simulator or emulator | a picture after each step | real | a native build | iOS suspends apps in the background; with Simulator.app closed a booted app sits inactive |
| physical device | a picture; there is no window on the Mac | real | build and install | a live mirror is its own feature |
| browser — `Launch.web(name, path:, session:)` on `Browser()` | live if the studio embeds or screencasts it | web | a web build | Run does not drive web today (DWDS): script actions stand in for the agent |

Two findings changed what the guest costs. **PowerSync 2.4 and sqlite3 3.x
load their native libraries through build hooks** — `powersync_flutter_libs`
is now a `+eol` package that "no longer does anything" — and the guest's
asset bundle already runs build hooks, so real sync in a guest is plausible.
And **most plugins a real app carries are the kind scenarios already fake**
(paths, preferences, permissions, links, package info, notifications), thin
and stable, unlike the API fake that drifted. What a guest cannot carry is
the camera, a native capture SDK, the photo library and file dialogs: a
person who captures runs on a device. The experiment confirmed the first
finding on a real app — its sync library's native core loaded through its
build hook in a guest and synced against the local server — and measured the
second: six plugins answered in 35 lines each on average, and a real app
carrying 21 plugins with a native half needs about 14 more, sqflite the
largest.

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

**Everything in the world is a node,** not only the people: the server and
any peripheral sit beside the apps. A relationship between nodes is a line —
a Bluetooth pairing, dashed while disconnected; later, messages travelling.

**Zoom changes what a node is, not only its size.** Below 70 % every node is
a card: who, where it runs, one status line. From 70 %, live screens with a
label above them, so text is never drawn too small to read. The same
threshold saves work: a guest drawn as a card, or off screen, stops producing
frames, so a ten-person world costs little until you look at it. The canvas
has to make that true: a guest does not know it is not drawn — one scrolled
out of view kept rendering at 12.5 % CPU and ~430 MB while it animated — so
the canvas sends it to the background, which stops its frames and gives the
memory back, and brings it forward on zoom.

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
Without it, a human re-reads the script to find the number `w.phone()` made
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

## The agent's surface

- `worlds list`; `worlds open {world, knobs}` returns the people and their
  apps' run keys; `worlds restart`; `worlds close`.
- `flutterware_act` gains a `person` selector beside `device`, `entrypoint`
  and `run` (`_selectApp`, `run_core.dart:5201`). Its existing `actor`
  argument keeps saying who is driving.
- `worlds outbox` reads messages; `worlds deliver {message, person?}` opens,
  taps or types, whichever the message calls for; `worlds answer {question,
  choice}`; `worlds invoke {action}` runs one of the script's actions.
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
triggered.

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
     with the plugin answers its first screen turns out to need.
1. **The outbox.** The SMTP catcher; typed `mail`, `sms`, `push` and `job`
   events carrying who they reached; questions (`w.outbox.ask`); the viewers;
   newcomers; the three kinds of delivery, through a devbar panel convention
   flutterware publishes for links and notifications.
2. **Canvas v1.** Nodes with their credentials, the timeline, pending
   questions, focus, the drawer. Guests are live from the first version, as
   the lab already draws them, and sent to the background when drawn as a
   card or off screen; external devices are pictures.
3. **Server panels** over `FlutterwareServer.handle`.
4. **Other devices, and the device as an input.** A simulator allocated per
   person, a macOS window when the script asks for one, and the controls
   where the mechanism already exists — `simctl location`, adb — refusing the
   rest by name.
5. **Sharp at any zoom,** and a canvas that shows live the guests a CLI or
   the MCP owns. **Answers for more plugins** run beside every slice, as
   worlds need them — sqflite first, then what a real app's first screen
   needs.
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
2. **Discovery.** A folder per package, as sketched, or entries in the
   config? The folder matches how scenarios are found.
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
