# Worlds on paper — six invented products against the design

*Since round 2 the scripts below would write their identities themselves — `'ana.${w.id}@example.com'` — rather than through `w.email`, `w.phone` and `w.unique`, which were removed; the cases are kept as they were written.*

**Date:** 2026-09-25
**Question:** does `2026-09-25-worlds-design.md` hold beyond the one consumer
it was drawn from? Six invented products, each chosen to push on a different
part of the design, are written as worlds in its vocabulary and its script API.
A new word, or an API bent out of shape, is a finding.
**Answer:** the words held. Nothing needed a new noun for what is *in* a
world — person, app, device, server, edge, outbox, peripheral, action, knob
covered all six. Two things the design lacked names for came up: people who
**turn up** without being declared, and edges that **ask** rather than tell.
The API grew in eight places, listed at the end. The largest gap is the
device: every case past the first wanted to control something about a
person's device — its location, its network, whether the app is in the
background — and the design treats the device only as *where the app runs*.
**Method:** each case is a product description, the people and devices, a
world script in the design's API (marked **(new)** where the API had to
grow), a walk through what you would do, and what bent. Nothing was built or
run.

The six:

| # | world | what it pushes on |
|---|---|---|
| 1 | Pickup order | the basics: every edge once, and a person with no account yet |
| 2 | Group chat | one app used by three people at once |
| 3 | Team invite | a person in a browser, and a person nobody declared |
| 4 | Delivery | the device as an input: location, network |
| 5 | Heart-rate strap | a peripheral, and an app in the background |
| 6 | Subscription | time, and an edge that has to be answered |

Every script below starts with the same helper the design sketches,
`startLocalServer(w)`, hosting a Dart server in the world's process.

---

## 1. Pickup order

**The product.** Customers order ahead on a phone app and collect at the
counter. Baristas work from a desktop board. Signing up is a phone number and
a code by SMS; the server pushes when an order is ready and emails a receipt
with a PDF attached.

**People.** Ana, a barista on the desktop board, signed in. Leo, a customer
who has never used the app.

```dart
/// A regular walks in, signs up with a code by SMS, orders a flat white and
/// is told when it is ready. Ana runs the counter.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);
  var shop = await server.shop(w.unique('Canal Street'));
  var ana = await shop.staff(w.email('ana'), 'Ana', role: Role.barista);

  w.person(
    'Ana',
    identity: (email: ana.email, userId: ana.id),
    app: Launch('Counter · Local', knobs: {...server.knobs, 'session': ana.token}),
    on: Studio(Devices.macbook),
  );
  w.person(
    'Leo',
    identity: (phone: w.phone()), // (new) no user id: he has no account yet
    app: Launch('Shop · Local', knobs: server.knobs),
    on: Studio(Devices.iphone16),
  );
});
```

**What you do.** Leo types his number — the one on his node, which you copy —
and the server sends a code. The outbox shows *SMS to Leo: 482 913 is your
code*, offering **Type into Leo's app**. He is in; he orders. Ana's board
gains the order without anyone touching it. Ana taps *Start*, then *Ready*;
the outbox shows a push to Leo, you deliver it, and his app opens on the
order. After pickup, an email receipt with a PDF attached.

**What bent.**

- **A person can exist before their account does.** Leo is known to the world
  by a phone number the script chose, and to the server by nothing until he
  signs up. `identity` has to allow any subset of email, phone and user id;
  routing by phone number works before the user id exists.
- **A code is a third kind of delivery.** A link is opened, a push is tapped,
  a code is *typed*. The viewer offers to type it into the person's focused
  field through the drive layer's `enterText`. iOS's one-time-code autofill is
  an OS feature a simulator cannot show; typing is honest about that.
- **A person's credentials belong on their node.** Phone, email, password:
  shown, copyable, and fillable. Without it, a human re-reads the script to
  find the number `w.phone()` made up.
- **An email can carry an attachment.** The email viewer shows the PDF
  through the PDF viewer rather than as a download.

## 2. Group chat

**The product.** A chat app. A group of three friends; mentions notify the
person mentioned; messages appear live for everyone in the group.

**People.** Mia, Noah and Zoe — all on the **same** app.

```dart
/// Three friends in a group. Nobody has written anything yet.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);
  var group = await server.group(w.unique('Saturday ride'));

  for (var name in ['Mia', 'Noah', 'Zoe']) {
    var user = await server.user(w.email(name), name);
    await group.add(user);
    w.person(
      name,
      identity: (email: user.email, userId: user.id),
      app: Launch('Chat · Local', knobs: {...server.knobs, 'session': user.token}),
      on: Simulator('iPhone 16'), // the same kind for all three
    );
  }
});
```

**What you do.** Mia writes *@Noah are you coming?*. Noah's and Zoe's screens
update live. The outbox shows one push — to Noah only. You deliver it; his app
opens the thread. The agent can play Zoe while you play the other two.

**What bent.**

- **Two people on one app need two of everything.** Three people on
  *iPhone 16* cannot share one simulator: one app, one instance. The script
  names a kind of device; flutterware has to **allocate** one per person —
  `simctl clone`, named after the person, booted on first use. That is a
  cost (a boot per clone) and a cleanup (clones outlive the world unless
  removed).
- **Isolation is a property the world must guarantee, and only one candidate
  gives it for free.** Three macOS windows of one app share one sandbox
  container — preferences, keychain, files. A guest whose platform calls the
  studio answers (the experiment's second candidate) gets a directory per
  person without asking the app for anything. This is the strongest argument
  for that candidate found so far.
- **A world may act but never assert.** *Mia mentions Noah; Noah is
  notified; Zoe is not* is a check. A world that checks is a scenario that
  starts from a world — the live lane's job, later. The line holds, but this
  case is where it would be crossed first.
- **Live updates between people are app-to-server traffic,** usually a
  socket. The Server panel shows HTTP requests; whether it shows socket
  frames decides whether the timeline can say *Zoe's app received it*. Not a
  world question — worth checking in the lab.

## 3. Team invite

**The product.** A team tool. The owner works in a web console; members use a
phone app. The owner invites a colleague by email; the email's magic link
signs them in and joins them to the team.

**People.** Olivia, the owner, in a **browser**. And whoever she invites —
whose address she types.

```dart
/// Olivia's team is just her. She is about to invite a colleague.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);
  var team = await server.team(w.unique('Northwind'));
  var olivia = await team.owner(w.email('olivia'), 'Olivia');

  w.person(
    'Olivia',
    identity: (email: olivia.email, userId: olivia.id),
    app: Launch.web('Console', path: '/team', session: olivia.token), // (new)
    on: Browser(),                                                     // (new)
  );

  // (new) whoever turns up from outside the world gets this app, on this device
  w.newcomers(
    app: Launch('Members · Local', knobs: server.knobs),
    on: Studio(Devices.pixel8),
  );

  w.action('Olivia invites a colleague', () => olivia.api.invite(w.email('sam')));
});
```

**What you do.** In Olivia's console you type *sam@example.com* and press
*Invite*. The outbox shows an email to an address no person in the world
has, offering **Add sam@example.com to the world**. You accept: a new node
appears, a phone running the members app, signed out. You open the magic
link; it lands in that app; Sam is in the team. The agent, which cannot drive
a browser, runs *Olivia invites a colleague* instead.

**What bent.**

- **People turn up.** Anyone can be typed into a form, so a world needs a
  default for newcomers: which app, on which device. Without it, *Add to the
  world* has to ask three questions at the worst moment.
- **A person in a browser is used by hand, and acted for by the script.** Run
  does not drive web today, so the agent's way to be Olivia is a script
  action. That is a general rule, not a web workaround: **actions are how
  anyone — human or agent — acts as a person the drive layer cannot reach,**
  headless people included.
- **A web build is a different launch.** `Launch` names a Run entry point;
  a console served by a web build needs a URL and a session, not a device.
  `Launch.web` is the smallest shape that says so.
- **The address Olivia types is the human's choice, not the world's.** It is
  not unique per world, so the server may already know it from a previous
  run. Newcomers are where fresh identities stop being guaranteed; the
  catcher still keeps any email from leaving the machine.

## 4. Delivery

**The product.** A customer orders from a restaurant; the kitchen accepts on
a tablet; a courier picks up and rides to the customer, who watches the
courier move on a map.

**People.** Leo, the customer; *Kitchen*, a restaurant account on a shared
tablet; Carl, the courier.

```dart
/// Leo has ordered. The kitchen has not accepted yet; Carl is at the depot.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);
  var place = await server.restaurant(w.unique('Noodle Bar'));
  var leo = await server.customer(w.email('leo'), 'Leo', address: canalStreet);
  var carl = await server.courier(w.email('carl'), 'Carl');
  await leo.api.order(place, [Dish.ramen]);

  w.person('Leo', /* … */ on: Studio(Devices.iphone16));
  w.person('Kitchen', /* a shared account */ on: Studio(Devices.ipadAir));
  var courier = w.person(
    'Carl',
    identity: (email: carl.email, userId: carl.id),
    app: Launch('Courier · Local', knobs: {...server.knobs, 'session': carl.token}),
    on: Studio(Devices.iphone16),
    location: depot, // (new) the device is part of the world
  );

  w.action('Carl rides to Leo', () => courier.device.moveAlong(route, speed: 18)); // (new) takes time
  w.knob(Knob('Carl’s network', options: ['online', 'offline']),
      (v) => courier.device.offline = v == 'offline');                              // (new)
});
```

**What you do.** The kitchen accepts. The server pushes *new delivery nearby*
— to a topic, not to a person. Carl accepts. You run *Carl rides to Leo*; his
position moves for a minute, and Leo's map follows. Halfway, you flip Carl's
network off: his app queues, Leo's map freezes, and both recover when you
flip it back.

**What bent.**

- **The device is an input to the world, not just where an app runs.**
  Location, the network, and later battery and permissions. `person.device`
  is the API; the mechanism depends on where the app runs — the studio
  answers the location channel for a guest, `simctl location` drives a
  simulator (it takes a route), `adb emu geo fix` an emulator. The Run device
  strip already sets appearance, language and text size for simulators; this
  is the same idea, owned by the world.
- **Actions take time.** Riding a route lasts a minute: an action needs
  progress, and a way to cancel it. So does anything that streams.
- **An edge must say who a message reached.** A push to a topic has no
  recipient to route by. The edge adapter reports the users the server
  resolved it to, not the raw topic.
- **A map may rule out the guest.** A map drawn by a native view cannot
  render in a guest; one drawn in Flutter from tiles can. The person's device
  is the script's choice for reasons like this one.
- **A person can be an account.** *Kitchen* is a login on a shared tablet,
  not a human. *Person* stretches to cover it; nothing broke, but a reader may
  wince.

## 5. Heart-rate strap

**The product.** A cycling app pairs with a Bluetooth heart-rate strap and
records rides. If a rider's heart rate stays above a threshold, the server
alerts their coach, who watches the rider live on a desktop dashboard.

**People.** Rita, the rider. Tom, the coach. And a strap — a peripheral.

```dart
/// Rita is warming up, the strap paired. Tom has the dashboard open.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w);
  var rita = w.person('Rita', /* … */ on: PhysicalDevice.any); // background Bluetooth: only a phone is honest
  w.person('Tom', /* … */ on: Studio(Devices.macbook));

  var strap = w.peripheral(                         // (later)
    'Strap',
    model: HeartRateStrap(bpm: 72),                 // the standard heart-rate profile
    pairedWith: rita,
  );
  w.action('Rita sprints', () => strap.rampTo(185, over: Duration(seconds: 20)));
  w.knob(strap.battery);
  w.action('Rita locks her phone', () => rita.device.background()); // (new)
});
```

**What you do.** The strap streams 72 bpm; Rita's app shows it, Tom's
dashboard follows. You run *Rita sprints*; the heart rate climbs and holds;
after the threshold, the outbox shows a push to Tom. You lock Rita's phone
mid-sprint: does the app keep streaming in the background?

**What bent.**

- **The peripheral model can be generic.** Heart rate and battery are
  standard Bluetooth profiles; flutterware could ship their models. A custom
  device needs one the project writes — and that model is where drift moves.
- **The transport is the device's business, not the script's.** In a guest or
  a macOS window, a fake at the Bluetooth plugin's interface; on a physical
  phone, the Mac advertising itself as the strap. The script says what the
  strap is, never how it is reached. The iOS simulator has no Bluetooth, so
  it cannot host this person at all.
- **Background is a device state, and only a real phone has an honest one.**
  A guest has no background; a simulator's is real but has no Bluetooth. The
  case that most needs *locked phone, still streaming* is the one only a
  physical device can answer — so a world must mix device kinds, which the
  canvas already assumes.
- **A knob can be continuous.** Battery is a slider, not a picker.
  `KnobKind.number` already exists; the world only has to use it.

## 6. Subscription

**The product.** Shop owners subscribe to a tool. A 14-day trial; a reminder
email the day before it ends; at the end, the card is charged through a
payment provider. A declined card sends a *payment failed* email and puts a
banner in the app; the owner updates the card on the provider's hosted page.

**People.** Paula, the owner. And the payment provider — which is not a
person.

```dart
/// Paula started a trial today. Her card will be declined.
void main(List<String> args) => World.run(args, (w) async {
  var server = await startLocalServer(w); // payments: WorldPayments(w)
  var paula = await server.owner(w.email('paula'), 'Paula', trial: Duration(days: 14));
  w.person('Paula', /* … */ on: Studio(Devices.macbook));

  w.knob(Knob('Next charge', options: ['approve', 'decline', 'ask']));
  w.action('Skip to the day before the trial ends',
      () => w.clock.advance(Duration(days: 13))); // the server's scheduler must read w.clock
});

class WorldPayments implements PaymentService {
  WorldPayments(this.w);
  final World w;

  @override
  Future<ChargeResult> charge(Customer c, Money amount) async {
    var answer = await w.outbox.ask(                 // (new) an edge that asks
      'Charge $amount to ${c.name}',
      choices: ['Approve', 'Decline', 'Ask for 3-D Secure'],
      unless: w.knobValue('Next charge'),            // answered by the knob when set
    );
    return ChargeResult.from(answer);
  }
}
```

**What you do.** You skip thirteen days. The outbox shows the reminder email.
You skip one more: the server charges, and the outbox shows a pending
question — *Charge 29 € to Paula* — with three answers. You decline. The
failure email arrives; Paula's app shows the banner; she opens *Update card*,
which lands on a page the world serves in place of the provider's, and you
approve there.

**What bent.**

- **Some edges ask.** A charge, a 3-D Secure challenge, an OAuth consent
  screen: the server waits for an answer from outside. In the outbox that is
  a pending item with choices, answered by a human, by the agent, or by a knob
  set in advance. Every other edge only tells.
- **Time travel needs the server's help.** Advancing `w.clock` changes what
  Dart code reads, but a scheduler that sleeps on real timers, or asks the
  database for `now()`, never notices. The world can offer *advance* only for
  a server whose scheduler reads the injected clock, plus *run due jobs now*
  as a server panel action. Time is the least generic part of the design.
- **A third party's page is a node that is not a person.** The hosted payment
  page belongs to the provider. The world serves a stand-in and draws it as
  part of the edge — the payment edge's own viewer — so the vocabulary holds
  without a new kind of node.

---

## What the six say about the design

### The words

**Held:** world, person, app, device, server, edge, outbox, peripheral,
action, knob. No case needed a new noun for something *in* a world.

**Needed:** a name for people nobody declared — **newcomers** (case 3) — and
for an edge waiting on an answer — a **question** in the outbox (case 6).
*Person* stretched once, to a shared account (case 4), without breaking.

### The API grew in eight places

| # | growth | cases | where it lands in the design |
|---|---|---|---|
| 1 | `identity` takes any subset of email, phone, user id; a person can precede their account | 1, 3 | the world script · semantics |
| 2 | a person's credentials are shown on their node, copyable and fillable | 1, 3 | the canvas |
| 3 | delivery has three kinds: open a link, tap a push, **type a code** | 1 | delivering into apps |
| 4 | `w.newcomers(app:, on:)` — the default for people who turn up | 3 | the world script; delivering into apps |
| 5 | `person.device` — location, network, background — driven per kind of device | 4, 5 | a new section: the device as an input |
| 6 | actions that take time: progress, cancel | 4, 5 | the world script |
| 7 | edge adapters report resolved recipients; `w.outbox.ask` for edges that ask | 4, 6 | the server in the world |
| 8 | `Launch.web` and `Browser()` for a person in a browser | 3 | where a person's app runs |

### Rules the cases forced into words

- **A world acts; it never asserts.** A world with checks is a scenario
  starting from a world (case 2).
- **Script actions are how anyone acts as a person the drive layer cannot
  reach** — a browser, a headless person, a shared account (cases 3, 4).
- **Where a person's app runs is chosen for what the case needs** — a native
  map, background Bluetooth — so a world mixing device kinds is the normal
  case, as the canvas already assumes (cases 4, 5).
- **Isolation per person is the world's guarantee.** Only a guest whose
  platform calls the studio answers gets it for free; simulators need one
  clone per person; macOS windows of one app share storage (case 2).
- **Time is only as movable as the server lets it be** (case 6).

### What the lab should host, in order

1. **Pickup order** — the base: every edge once, a person before their
   account, codes typed.
2. **Group chat** among the lab's staff — one app, three people: allocation
   and isolation, measured on each device candidate.
3. **Team invite** — newcomers, and a person in a browser.
4. **Subscription** — questions in the outbox, and whether the lab server's
   scheduler can follow the world clock.
5. **Delivery** — the device as an input.
6. **A peripheral** — last, with the rest of the peripheral door. In the lab
   a *pager* that buzzes when an order is ready fits the pickup product
   better than a heart-rate strap.

The findings are not yet folded into the design; each row of the table above
names the section it would change.
