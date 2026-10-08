# Scenarios

A scenario is a widget test that takes a screenshot at every step. Write the
test you'd write anyway, and you also get a picture of every screen it went
through, on every device and in every language you declare.

![A scenario run drawn as a flow: the demo's shop, one phone screenshot per
step, branching where the scenario splits](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/scenarios.webp)

```dart
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('Order a cappuccino', (s) async {
    await s.pumpWidget(const ShopApp());
    await s.tap(ShopKeys.getStarted);
    await s.tap('Cappuccino');
    await s.tap(ShopKeys.addToCart);
    await s.enterText(ShopKeys.cupName, 'Ada');
    await s.tap(ShopKeys.placeOrder);
  });
}
```

`flutter test` runs it like any other test. Under flutterware, every step also
keeps a screenshot, the widget tree, the visible text and the semantics tree
(what a screen reader gets). The studio draws the run as a flow you can walk
through, and the same results are there from the command line and for an agent.

The same runs feed [store screenshots](store_screenshots.md), the pictures in
the translations table, and branch comparisons.

## Turn it on

```dart
// tool/flutterware.dart
fw.use(Scenarios(packages: [.new(app, languages: ['en', 'fr'])]));
```

`package:flutterware/flutter_test.dart` is `package:flutter_test` with the
scenario API added, so an existing test file keeps `expect`, `find`,
`testWidgets` and the rest. To use scenarios in a test file, change its import.

Scenarios are found anywhere under `test/`, next to ordinary tests or in the
same file. `fw run scenarios new` writes new ones to `test/scenarios/`. Set
`directory:` to look in one folder only.

Scenarios are found by reading the source, without running it: flutterware
looks for a literal `scenario('name', …)` call. A name built at run time is
reported as a problem, and that scenario isn't listed. A helper that calls
`scenario` for you, like `runScenario(name, body)`, leaves no such call in the
file, so its scenarios aren't found. Keep the `scenario(` call and its name in
the test file.

## Run them

```shell
fw run scenarios run                     # every scenario, on each folder's default device
                                         # (a real-time folder only when named)
fw run scenarios run --file=test/scenarios/shop_test.dart --language=fr
fw run scenarios run --matrix=declared   # every device and language the folders declare
fw run scenarios read                    # the step the last run failed on
```

In the studio, pick a scenario and press **Run**. The flow shows one frame per
step, with the action that led to it on the arrow. Open a step to see its
screenshot next to its widget tree and texts.

## The verbs

Each one acts, waits for the screen to settle, and captures.

| verb | what it does |
|---|---|
| `pumpWidget(widget)` | mounts the app |
| `tap(target)` | taps |
| `doubleTap(target)` | taps twice, close enough to be one gesture |
| `longPress(target)` | presses and holds |
| `enterText(target, text)` | fills a field, or types into it a key at a time with `typing:` |
| `drag(target, offset)` | drags by an offset |
| `scrollTo(target)` | scrolls until the target is on screen, then stops |
| `hover(target)` / `unhover()` | moves the mouse over it and leaves it there, for tooltips and hover states |
| `secondaryTap(target)` | right-clicks, for a context menu |
| `scroll(target, offset)` | turns the mouse wheel over it, scrolling that pane |
| `key('meta+k')` | presses a key or a chord, such as a shortcut, `escape` or `tab` |
| `back()` | presses the Android back button, which pops the route |
| `wait(duration)` | moves the fake clock past a timer |
| `act(description, body)` | runs something other than a gesture, such as a push, a completer or a backend call, and names the step after it |
| `screen(name)` | captures without acting |
| `split({...})` | forks the flow |

Everything takes a **target**, which can be a `String` (visible text), a `Key`,
a `Type`, an `IconData`, a `Finder`, or one of:

```dart
await s.tap(Target.label('Add to cart'));          // the semantics label, for
                                                   // an icon with no text
await s.tap(Target.tooltip('Delete'));
await s.tap(Target.containing('Buy'));             // text that contains 'Buy'
                                                   // (a plain String must match
                                                   // the whole label)
await s.tap(Target.within(ShopKeys.cart, 'Buy'));  // the Buy inside the cart
await s.tap(Target.nth('Buy', 1));                 // the second one
```

`within` and `nth` take targets too, so they combine:
`Target.nth(Target.within(ShopKeys.cart, 'Buy'), 0)`.

When a target matches nothing, or several things, the error lists the targets
that were on screen and what to use instead.

A target that exists but is below the fold is scrolled into view first, as a
user would scroll to it, so one scenario runs unchanged on a small phone and on
a tablet. A target that scrolling can't reach fails the step: a covered widget,
or one off screen with nothing to scroll it into view. (Plain `flutter_test`
only warns on a missed tap, so a test you migrate can start failing here.) A
widget a lazy list hasn't built yet matches nothing. Use `scrollTo` for it. It
also takes a positional finder like `find.text('Row 40').first`, and scrolls to
it the same way as to `'Row 40'`.

`s.tester` is the real `WidgetTester`, for anything the verbs don't cover.
Frames drawn through it are counted and reported on the next step, so the flow
shows where it skipped screens.

### The mouse and the keyboard

`hover`, `secondaryTap` and `scroll` share one mouse, and it stays where it was
left, like a real one. A `tap` after a `hover` still finds the control hovered,
and `unhover()` takes the mouse away. `hover` holds for 600ms of the fake clock
(change it with `hold:`), which is long enough for a tooltip's
`Tooltip.waitDuration`. The tooltip then appears in the step's picture and its
texts like any other widget. Every scenario, and every branch of a `split`,
starts with no mouse on the screen.

`scroll` takes a mouse wheel's offset: a positive `dy` moves down the list,
where `drag` needs a negative one. The wheel scrolls the pane under the mouse,
so on a page with several lists it scrolls the one you target.

`doubleTap` puts 80ms of the fake clock between its taps (change it with
`gap:`), because a double-tap recognizer ignores a second tap within 40ms.

On a desktop device (every `Devices.*Window`), `tap`, `tapAt`, `doubleTap`,
`longPress` and `drag` use that same mouse, and it stays where it clicked, so
the control is still hovered in the next picture. On any other device, and on a
run with no device, they use a finger. Widgets that adapt to the pointer, such
as a text field's selection handles, a tooltip's trigger or a slider's value
label, show the layout their users see. A mouse drag doesn't scroll a list, on
a desktop or here, so use `scroll` or `scrollTo` for that.

`key` is for shortcuts and navigation; to type into a field, use `enterText`.
In a chord, the last key is pressed and the ones before it are held: `meta+k`,
`shift+tab`, `ctrl+s`. A key goes to whatever has focus. If nothing has focus
and nothing handles the key, the step fails. `tap` something first, or give the
widget the shortcut belongs to `autofocus: true`.

`enterText` puts the whole value in with one edit, the way a paste does. A field
that reacts to each edit, such as a search that debounces its query or a code
input that moves to the next box, needs one keystroke at a time. `typing:`
types one character at a time and moves the fake clock that much after each:

```dart
await s.enterText(Keys.search, 'flat white',
    typing: const Duration(milliseconds: 100));
await s.wait(const Duration(milliseconds: 300));   // the debounce's own delay
```

The step then settles as usual. A pending timer doesn't schedule a frame, so
`wait` out the debounce's delay yourself.

## Settling

Every verb takes a `settle:`.

```dart
await s.tap(button);                          // Settle.standard: up to 5 seconds
await s.tap(button, settle: Settle.none);     // don't wait
await s.tap(button, settle: Settle.frames(3));
await s.tap(button, settle: Settle.upTo(Duration(seconds: 30)));
```

The default gives up after five seconds of fake time instead of throwing. A
screen with a spinner on it never settles, and `pumpAndSettle` throws on one.
A scenario that reaches a loading state records `settled: false` on that step,
the studio shows *"still animating"*, and the scenario carries on.

`s.settle()` waits the same way without taking a step: the default policy, or
the one you pass, and no capture. Use it in place of `pumpAndSettle()` in a
test ported from plain widget tests, and after pumping through `s.tester`.

`Settle.strict` waits the same way as the default (five seconds, then the wait
for real work), but if the screen still asks for frames after that, it fails
the step instead of flagging it. Use it where a spinner in a picture is a bug:
`settled: false` is only a number in a report, and a scenario whose assertions
pass keeps passing with a spinner in every picture. Set it once for a folder:

```dart
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, settle: Settle.strict);
```

A scenario's own `settle:` still wins, and so does a verb's. Pass
`settle: Settle.standard` to the one `tap` that should show the spinner.

`Settle.until(target)` waits for something to appear instead of for the screen
to go quiet. Data that arrives without scheduling a frame looks the same as an
app with nothing left to do: a row from a sync stream that opened long ago, or
a list that reads its local database after the tap that opened it. The default
settles on the empty state and photographs it. Name what the step waits for:

```dart
await s.tap('Orders', settle: Settle.until('Order #1042'));
await s.act(
  'An order placed on the other device reaches this one',
  () => otherDevice.placeOrder('#1043'),
  settle: Settle.until('Order #1043'),
);
```

It pumps until the target is on screen, then settles the way the default does.
The target can be anything a verb takes, including a positional one:
`find.text('Order #1042').first` with no match yet, or a `Target.nth` past the
rows so far, counts as not there yet. The `timeout` is ten seconds by default,
on the scenario's clock. A target that never appears fails the step, and the
step's picture is the screen when the wait gave up.

### Loaders that never settle

A step that never settles uses its whole settle time on every run, and the run
names what kept it busy: `settled: false` on the step comes with
`stillTicking`, and the studio's *"still animating"* notice lists the same
things. A framework widget is named with the line of your app that built it,
such as `CircularProgressIndicator (lib/src/orders/status_cell.dart:42)`. An
animation of your own is named by the frame that started it.

Usually it's a spinner, a shimmer or a pulsing dot, and the phase it's at
doesn't matter. Mark it in the app, once, where the loader is built:

```dart
import 'package:flutterware/ambient.dart';

Ambient(child: CircularProgressIndicator())
```

Outside a scenario, `Ambient` just builds its child. Inside one, nothing under
it schedules a frame, and every Material progress indicator without its own
controller is drawn at one fixed phase. The step settles, and the picture is
the same on every run and every machine. Any other animation under it stays at
its start.

`Settle.strict` still fails a step that ends with an `Ambient` on screen.

### A post-frame callback that never runs

`WidgetsBinding.instance.addPostFrameCallback` doesn't request a frame. It adds
the callback to a list that the next frame runs, whenever that comes. The test
binding draws no frame for a pump with nothing scheduled. So a callback
registered while the tree is idle never runs: not on the next verb, not on
`s.settle()`, and not on `s.tester.pumpAndSettle()`.

A callback registered during a build is fine, because the frame in progress
runs it at its end. One registered outside a frame is stuck. The usual case is
an `initState` that awaits something first:

```dart
Future<void> _load() async {
  await repository.fetch();                    // the frame has ended by now
  WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
}
```

Fix it in the app, since on a device the callback also depends on something
else scheduling a frame:

```dart
var binding = WidgetsBinding.instance;
binding.addPostFrameCallback((_) => _reveal());
binding.ensureVisualUpdate();                  // schedules one unless one is coming
```

If you can't change the app, ask for the frame from the scenario:

```dart
s.tester.binding.scheduleFrame();
await s.settle();
```

A plain widget test has the same problem, but `tester.pumpWidget` leaves a
frame scheduled and the callback runs on it. Every scenario verb settles to an
idle tree, so no frame is coming. Put a `pumpAndSettle()` before the
registration in a plain widget test and the callback stops running there too.

### Work on the real event loop

Settling follows frames. Work that finishes on the real event loop (an asset
read, an image decode on an engine thread, a file, an isolate) schedules no
frame while it runs. Every verb waits for what it can detect by itself: a
pending `ImageProvider`, an asset read through `s.assets`, and a dozen turns of
the real event loop for anything else. That is enough for an SVG, but not for
importing a 6 MB model. For longer work, tell flutterware about it in the app:

```dart
import 'package:flutterware/real_work.dart';

@override
void initState() {
  super.initState();
  _model = RealWork.track(_loadModel(), label: 'scene model');
}
```

`RealWork.track` returns the future unchanged. Outside a scenario it costs a
set insert and a listener on the future. Inside one, every verb that follows
waits in real time until the future completes, pumping between turns so its
continuations run and the final `setState` is drawn, and then takes its
picture. A tracked future that never completes runs into the scenario's
deadline, and the error names its label.

Without it, poll and pump by hand. The pump is what lets the continuations run:

```dart
while (!scene.ready) {
  await s.tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: 1)));
  await s.tester.pump();
}
```

Don't await the app's future directly, or inside `s.runAsync`. A future created
under fake time completes through a fake microtask, which only a pump runs, and
the body awaiting it can't pump. Awaited directly, it waits until the
scenario's 30-second deadline. Inside `s.runAsync`, no pump can run at all, and
the watchdog reports it after eight seconds. Use `s.runAsync` only for work
that needs the real clock and nothing else, such as a database or a socket, and
never for a future the app already created.

An asset read through `s.assets` counts as done once its bytes are read. A
package that then parses them in an isolate, like Lottie with
`backgroundLoading: true`, needs the app to track that second half. Lottie also
caches each load for the life of the process, so a load one scenario started
would be awaited from the next scenario's zone, where it never completes.
`RealWork.run` starts the work outside every scenario's zone and tracks it:

```dart
final _intro = AssetLottie('assets/intro.json', backgroundLoading: true);

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  RealWork.run(() => _intro.load(context: context), label: 'intro');
}

@override
Widget build(BuildContext context) => LottieBuilder(lottie: _intro);
```

### Work on the fake clock

A future that waits on the fake clock, such as a `Future.delayed`, a debounce
or a repository that answers after a timer, gets stuck the same way. Only a
pump moves the fake clock, so if you await it directly between verbs it never
completes. The deadline error names the timer and the line that started it.
Await it inside `s.act`, which moves the clock for its body:

```dart
await s.act('The search debounce fires', () => search.query('latte'));
```

While the body waits on a timer or a frame, `act` pumps at the settle interval
until the body completes, for up to `timeout:` of fake time (ten seconds by
default). A body still waiting after that fails the step, and the error lists
what the clock still held. A body that needs no time doesn't move the clock. A
verb called inside the body moves the clock itself, and `act` waits for it
instead of pumping at the same time. On the real clock (`ScenarioTime.real`),
the body's timers fire on their own and `act` just awaits it.

## Shots

By default every verb captures. `Shot('name')` names the picture. Unnamed ones
are shown collapsed, as detail steps, in the flow.

A flow doesn't keep the same picture twice. `screen(name)` straight after a
verb puts the name on that verb's picture instead of taking a second one of the
same frame. `wait`, `runAsync`, `scrollTo` and `unhover` take no step when the
screen ends up as it started, whether they drew nothing or redrew the same
pixels. Any other verb that changes nothing keeps its step, marked identical to
the one before, since a `tap` that changes nothing means the flow is stuck.

```dart
scenario('Long flow', shots: Shots.manual, (s) async {
  await s.tap(next);                       // no capture
  await s.tap(next, shot: Shot('Summary')); // captured
});

await s.tap(next, shot: Shot.skip);        // skip just this one
await s.tap(next, shot: Shot('Home', tags: ['store']));
```

Tags pick which shots get exported. With `fw run scenarios shots --tag=store`
([Named shots, as files](#named-shots-as-files)) or a `tag:` in
[store screenshots](store_screenshots.md), only shots with that tag are kept.

`s.act` names its step with its description, so every act is a named shot.
`shot: false` keeps the step but drops the name: the flow still shows it, as
`act "…"`, and `shots` and the store export leave it out.

```dart
await s.act('The backend is seeded', shot: false, () => backend.seed());
```

## Splitting a flow

One scenario can cover every path through a screen:

```dart
scenario('Around the shop', (s) async {
  await s.pumpWidget(const ShopApp(), shot: Shot('Welcome'));
  await s.tap(ShopKeys.getStarted, shot: Shot('Menu'));
  await s.split({
    'a cappuccino': () async {
      await s.tap('Cappuccino');
      await s.split({
        'small cup': () async {
          await s.tap(ShopKeys.size(DrinkSize.small));
        },
        'large cup': () async {
          await s.tap(ShopKeys.size(DrinkSize.large));
        },
      });
      await s.tap(ShopKeys.placeOrder, shot: Shot('Order placed'));
    },
    'the empty cart': () async {
      await s.tap(ShopKeys.openCart, shot: Shot('Empty cart'));
    },
  });
});
```

The body is replayed once per path, so each branch starts from exactly the
state the fork was reached in. Steps before the fork are captured once and
shared, and the flow fans out where the app does. Splits nest, and a failure
inside one names the branch that reached it.

Each replay starts the pinned clock at the same time as the first run, so a
record the body dates with `clock.now()` has the same date in every branch,
however long the earlier branches took.

Because the body replays, build anything a branch needs fresh inside the body:
`setUp` runs once per scenario, not once per path.

## Devices and languages

A folder declares its devices and languages once, in the file `flutter test`
already looks for:

```dart
// test/scenarios/mobile/flutter_test_config.dart
import 'dart:async';
import 'package:flutterware/flutter_test.dart';

const phones = ScenarioProfile(
  'phones',
  devices: [Devices.iphone16, Devices.iphoneSe, Devices.androidTall],
  languages: ['en', 'fr'],
);

Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, profile: phones);
```

The first entry of each list is the default, and the whole list is what the
studio offers. Scenarios don't name devices. `test/scenarios/desktop/` can
declare a different profile, and a scenario opened from either folder is framed
the way its folder says. The studio remembers the device you picked per folder,
so picking an iPhone for a phone scenario doesn't carry over to a desktop one.

Devices are chosen per folder. If phone and desktop scenarios share a
directory, split them into two folders. `orientations` is a list of its own,
crossed with `devices`: two devices and two orientations make four points. Name
an iPad once and add `ScreenOrientation.landscape` to `orientations`, instead
of declaring a landscape iPad as a separate device. A device that can't rotate
adds only one point.

`flutter test` runs one pass, at the first entry of each list. To run more, in
CI for example, pass the lists:

```sh
flutter test test/scenarios/mobile \
  --dart-define=fw.devices=iphone-se,android-tall \
  --dart-define=fw.languages=en,fr
```

That declares one test per combination (`Counter [iPhone SE · en]`, and so on)
from a single invocation and a single compile. The environment variables
`FW_DEVICES` and `FW_LANGUAGES` do the same.

With flutterware's runner you don't repeat the lists:
`fw run scenarios run --matrix=declared` reads the folder profiles and runs
every point they declare: each folder's devices, languages, orientations and
[app axes](#the-apps-own-axes), crossed the same way as explicit lists. Each
point runs only the files whose folder declares it, so the phone folder runs on
its phones and the desktop folder on its windows. A point two folders both
declare runs both in one pass, and a folder with no profile runs once, like a
run that names no device. `--file`, `--scenario` and `--tag` narrow it as they
narrow any run. A CI job that uses `--matrix=declared` runs on a new device as
soon as you add it to a profile.

Explicit `--devices` and `--languages` lists work differently: every file runs
on every device and language listed, whatever the folders declare.

Inside a body, `s.assignment` reports what this pass is running as, so an
expectation can adapt to the screen it is on.

## The app's own axes

Devices, languages and orientations are axes flutterware knows about. An app
usually has a few of its own, such as two brand themes, a high-contrast mode or
a feature flag's variants. A folder declares those next to its devices, each
with the values worth running:

```dart
// test/scenarios/mobile/flutter_test_config.dart
const phones = ScenarioProfile(
  'phones',
  devices: [Devices.iphone16, Devices.iphoneSe],
  languages: ['en', 'fr'],
  axes: {
    'brand': ['coffee', 'tea'],
  },
);
```

A scenario reads the value it is running with and builds its app for it:

```dart
scenario('Order a cappuccino', (s) async {
  await s.pumpWidget(ShopApp(
    theme: switch (s.axis('brand')) {
      'tea' => teaTheme,
      _ => coffeeTheme,
    },
  ));
  await s.tap('Cappuccino');
});
```

The values are strings because a profile is `const` and a theme is not, so
turning `tea` into a `ThemeData` is up to the scenario, or a helper its folder
shares. As with devices, the first value is the default: `flutter test`, the
studio and a run that names no value all build the coffee app. `s.axis` throws
on a name the folder doesn't declare, so a typo fails instead of photographing
the default twice under two names.

Run across them the same way as the other lists:

```shell
fw run scenarios run --axes=brand=tea                # one value
fw run scenarios run --axes=brand=coffee,tea         # both: …/coffee/, …/tea/
fw run scenarios run --matrix=declared               # every folder's own values
fw run scenarios shots --axes=brand=coffee,tea       # en/iphone-16-coffee/, en/iphone-16-tea/
flutter test test/scenarios/mobile --dart-define=fw.axes=brand=coffee,tea
```

Several axes are comma-separated too, as in
`--axes=brand=coffee,tea,contrast=high`, and `FW_AXES` is the environment form
of `fw.axes`. An axis only applies where it is declared: a folder without
`brand` ignores `--axes=brand=tea`, a folder that declares `brand` without
`tea` fails its scenarios with a message saying so, and a name or value no
folder declares is refused before anything runs. The web export and the video
take `--axes` as well.

Unlike portrait and light, an axis value is always written out, including the
default: in a matrix directory (`iphone-16-fr-tea`), a test name
(`Counter [iPhone 16 · fr · tea]`), a step's address (`?axis.brand=tea`) and
`s.assignment?.axes`. A folder without axes adds nothing to these names.

In the studio, each axis the open scenario's folder declares gets a picker next
to Device and Language, offering that folder's values.

## Real-time folders

A folder can run on the wall clock instead of the fake one, against a real
backend, with the same `scenario()`, the same verbs and the same report. An
integration suite that needed a device can run this way as a folder of
scenarios. Declare it in the folder's config and in `tool/flutterware.dart`,
since the runner needs to know before it builds anything:

```dart
// integration_test/scenarios/flutter_test_config.dart
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, time: ScenarioTime.real());

// tool/flutterware.dart
fw.use(Scenarios(packages: [
  .new(app),
  .new(app, directory: 'integration_test/scenarios', time: ScenarioTime.real()),
]));
```

A package can have a fake-time folder and a real-time one side by side. Address
the second by its directory: `app/integration_test/scenarios`. Under real time
the network is live by default, and animations run at a tenth of their
duration (`ScenarioTime.real(animations: 1.0)` to film them at full length).
Each scenario gets its own process, and several run at once (`--jobs`).

A real-time scenario can create an account, send an email or text a phone, so
it only runs when you ask for it:

- The studio runs it when you press **Run**, not when you open its page.
- `fw run scenarios run` with no `--package` runs the fake-time folders only,
  and lists the ones it skipped under `notRun`.
- `--package=app/integration_test/scenarios` runs the real-time folder.
- A comparison never runs one.

Each step waits for live requests until their response headers arrive, so no
scenario needs a hand-written wait for an HTTP call. Data that arrives after
that, such as a sync stream's rows or a list that reads its local database once
the tap has opened it, gives no signal. Wait for it with
[`Settle.until`](#settling).

Put work that comes before the flow in a setup step:
`await s.setup('a fresh account', () => api.signUp(...))` is one step, with its
duration and its requests, and no picture.

If a scenario takes its process down (an error that escapes every zone it
owns), that scenario is reported as failed. The report keeps the steps it
captured and the last lines the process printed, and the rest of the run
carries on in a fresh process.

### Traps

- **`split` replays real side effects.** The body runs once per branch, so an
  account created before the fork is created once per branch, and so is every
  email and text. In a real-time folder, prefer separate scenarios.
- **Pump a second device as a new widget.** When two apps share their root
  widget types, a second `pumpWidget` updates the first app's `State` instead
  of mounting a new app, and the screen still shows the first device's data.
  Give each app its own key: `KeyedSubtree(key: UniqueKey(), child: app)`.
- **A second device is a second object.** Pumping the same app object again
  unmounts the first one, but whatever it opened natively stays open. A local
  database opened twice on the same files can warn about it and stall. Give
  each device its own object and its own data directory.

### A shape that works

This is from a suite that replaced its device tests with a real-time folder:
six flows, two apps, and 127 steps in 20 seconds.

- **One object per device.** It holds its own credentials, links and
  database directory, and knows how to build each app that device can run.
- **Check the stack before the first request.** Use a raw socket connection,
  so the check isn't recorded as a request on the step. When nothing answers,
  fail on the first line and name the command that starts the stack.
- **Fresh accounts only, made through the API in `s.setup`.** Nothing depends
  on seed data, so the same folder runs on a developer's stack and on CI's
  empty one.
- **Read mail and texts over HTTP**, from whatever catches them in the dev
  stack.
- **Point every app at the stack through environment variables.**
  `fw run scenarios run` passes its environment on to the scenarios, so CI can
  aim a whole run at an isolated stack with one variable.

## Fonts

`flutter test` always starts its tester with `--use-test-fonts` and
`--disable-asset-fonts`, and no flag turns that off. A font family with no real
font files loaded draws every glyph as the same filled box, and measures each
one at the box's width, roughly double a real glyph. Tests still pass and
layouts still resolve, but the screenshots show text wider than it is.
Headings in a bundled font can look right while the body text next to them, in
the default font, is a row of boxes.

Flutterware loads every family in your `FontManifest.json` before anything
runs, under its own runner and under plain `flutter test`. Under
`flutter test`, the platform's default families (`Roboto`, and the Apple and
Windows system font names) also get real Roboto from the SDK's cache, so text
that names no family measures correctly too. A family you bundle yourself
always uses your font files.

One difference remains: under `flutter test`, a scenario on an iOS device draws
its default text in Roboto, which is close to the iOS system font but not the
same. `fw run scenarios run` starts the tester without those flags, so it uses
the platform's real fonts. Treat its pictures as the reference, and use plain
`flutter test` for assertions.

## What a run leaves behind

![One step of a run: the screen it captured, and the widget tree, semantics,
texts and events recorded with it](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/scenarios-step.webp)

In the studio, opening a scenario runs it and draws the flow. The command line
and an agent use the same actions and get the same results:

```sh
fw run scenarios list
fw run scenarios run --file=test/scenarios/mobile/shop_test.dart
fw run scenarios run --devices=iphone-se,android-tall --languages=en,fr
fw run scenarios run --tag=smoke
```

A matrix writes one directory per point, `<output>/<device>-<language>/`, with
an `index.json` next to them that maps each point to its directory and result.
Each step leaves a PNG, a `.tree.json`, a `.semantics.json` (the merged
semantics tree in reading order, with labels, flags and actions by name) and
its texts. A failing scenario reports its error with the frame captured at the
moment it failed. A scenario that raised more than one exception reports each
one with its own message and stack, where `flutter_test` only says
"Multiple exceptions (2)".

Next to the artifacts is `run.json`: the whole run, every step of every
scenario, in the same shape as the result. The reply the action returns is a
summary. By default it includes only the frame each failing scenario stopped on
(`--steps=all` for every step, `--steps=none` for the summary alone), so a
script that counts steps should read `stepCount`, or the file. A relative
`--output` resolves against the worktree root, and `run.json` is written in the
same directory as the images it names. A failed run has a flat `failed` list at
the top, with the package, file, scenario and first line of the error for each,
so a script can find the failure without walking every package.

Several files run in one process, in the order given: `--file=a,b` or
`--file=a --file=b`. Use this to reproduce a failure that only happens after
another file has run, such as a future one scenario leaves behind in its fake
zone that breaks the scenario after it. Each selector must match something, so
a typo in the second one is refused instead of the run passing on the first.

What the app printed is attached to the steps: `print` and `debugPrint` are
events on the `print` channel, `package:logging` records are on `log`, and
platform messages are on `platform`. Each event is on the step that followed
it, summarized in `eventTitles` and in full with `scenarios read --events`
(`--channel=print` for just the prints). `dart:developer`'s `log` goes only to
the VM's logging stream, here as under `flutter test`.

A scenario that runs past its deadline ends on a failed step it never took.
That step has no picture, holds the events since the last capture, and its
failure explains what happened:

- which verb the body was in, and the line that called it;
- whether a completion is waiting for a pump that nothing runs (track it with
  `RealWork.track`), or nothing is waiting at all (a future from an earlier
  scenario's fake zone, or real-time work; the previous scenario is named);
- which platform messages were sent and never answered, with the app frames
  that sent them.

`scenarios read` takes a step by anything `run` reported for it: the `tree`
path, the `image` path, or the `fw://` address every step carries. All three
name the same step in `run`, `read` and the studio.

`scenario(skip: true)` works as it does under `flutter test`: the body never
runs, the run stays green, and the outcome says `skipped` rather than passed.

Content that is in the tree but not on screen, such as the route you navigated
away from or an `Offstage`, is marked `offstage` in the `.tree.json`, and the
Elements tab folds it away so the tree matches the screenshot.

In the studio, the step page's **Semantics** tab shows the semantics tree: the
words bright and the structure dim, roles as badges, and each row highlighting
its rectangle on the screenshot. It shows what a screenshot can't, such as an
icon button with no label, and it's where to find the strings for
`Target.label(…)`.

`--tag` filters scenarios by `scenario(tags: [...])`, the same tags
`flutter test --tags` uses.

Runs share a warm harness, so the second one skips the compile.
`fw run scenarios restart` drops it when you want a cold start.

## Named shots, as files

For finished store images, framed and sized for each store, use
[Store screenshots](store_screenshots.md). This is the raw material: the named
shots of a run, written as plain PNGs.

```sh
fw run scenarios shots --languages=en,fr --tag=store
```

This keeps only the named shots (here, those tagged `store`), at each device's
own pixel ratio, in:

```
<output>/<language>/<device>/around-the-shop/01-welcome.png
                                              02-menu.png
                                              03-order-placed.png
                             checkout/01-cart.png
```

Each scenario gets a directory named after it, with its shots numbered in flow
order. Adding a shot renumbers only the rest of its own scenario, so the diff
of an export shows only the screens that changed. When two files each have a
scenario with the same name, the file names go in front: `cart-happy-path/`,
`checkout-happy-path/`. Directories sort by scenario name, so prefix the names
(`01 Login`) if they should sort in a particular order.

Without `--devices`, each folder's profile decides, so one command writes a
phone tree for the mobile folder and a window tree for the desktop one. The
output directory is emptied first, so afterwards it holds exactly this run.

`--orientations=portrait,landscape` and `--brightness=light,dark` cross with
the devices and languages. A turned or dark point gets its own directory next
to the device's (`iphone-16-landscape/`, `iphone-16-dark/`,
`iphone-16-landscape-dark/`). Portrait and light are the defaults and add
nothing to the name.

A scenario that fails keeps the shots it took before it failed, and the reply
says why for each set: each entry in `failures` names the scenario, the first
lines of its error, and the `run` command that reproduces it at that device and
language. Use that command to look into it, since the run `shots` does itself
is deleted when it finishes. `fw` exits with 1, so a pipeline stops before it
uploads half a set.

## Standalone captures

Plain `flutter test` can write the pictures too, with no runner or studio:

```sh
flutter test --dart-define=screenshots-destination=build/shots
```

`SCREENSHOTS_DESTINATION` works too. Files go to
`<destination>/<assignment>/<file>/<scenario>/<index>-<name>.png`, where
`<file>` is the file the scenario was declared in, flattened
(`test_scenarios_shop_test.dart`) the same way the runner does it.
