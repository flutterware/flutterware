# Scenarios

A scenario is a widget test that takes a screenshot at every step. Write the
test you'd write anyway, and you also get a picture of every screen it went
through, on every device and in every language you declare.

![A scenario run drawn as a flow: the demo's shop, one phone screenshot per
step, branching at the menu into a row per drink](screenshots/scenarios.png)

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
`testWidgets` and the rest. Changing the import is the whole migration.

Scenarios are found anywhere under `test/`, next to ordinary tests or mixed
into the same file. `test/scenarios/` is only where `fw run scenarios new`
writes; set `directory:` to look in one folder only.

Discovery reads the source, it never runs it: it looks for a literal
`scenario('name', …)` call. A name built at run time is reported. A helper that
calls `scenario` for you, like `runScenario(name, body)`, leaves no such call
in the file and is not found, so keep the `scenario(` call and its name in the
test file.

## Run them

```shell
fw run scenarios run                     # every scenario, on each folder's default device
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
| `longPress(target)` | presses and holds |
| `enterText(target, text)` | types into a field |
| `drag(target, offset)` | drags by an offset |
| `scrollTo(target)` | scrolls until the target is on screen, then stops |
| `back()` | the Android back button — pops the route |
| `wait(duration)` | moves the fake clock past a timer |
| `screen(name)` | captures without acting |
| `split({...})` | forks the flow |

Everything takes a **target**, which can be a `String` (visible text), a `Key`,
a `Type`, an `IconData`, a `Finder`, or one of:

```dart
await s.tap(Target.label('Add to cart'));          // the semantics label — the
                                                   // handle on an icon that
                                                   // carries no text
await s.tap(Target.tooltip('Delete'));
await s.tap(Target.containing('Buy'));             // text *containing* this,
                                                   // where a plain String
                                                   // matches the whole label
await s.tap(Target.within(ShopKeys.cart, 'Buy'));  // the Buy of *that* card
await s.tap(Target.nth('Buy', 1));                 // the second one
```

They compose, because the scope and the index take targets of their own:
`Target.nth(Target.within(ShopKeys.cart, 'Buy'), 0)`.

When a target matches nothing or matches several things, the error says which
targets *were* on screen and what to reach for instead.

A target that exists but sits below the fold is **scrolled into view first**,
the way the user the verb stands in for would — so one scenario runs unchanged
on a small phone and a tablet, whichever side of the fold the button lands on.
What scrolling cannot fix is refused loudly: a covered widget, or one off
screen with nothing scrolling to it. (`flutter_test` alone prints a console
warning on a missed tap and carries on; a flow that silently diverges is the
one failure a screenshot-per-step tool must not have.) A widget a lazy list
has not built yet matches nothing — that is what `scrollTo` is for.

`s.tester` is the real `WidgetTester` if you need something the verbs do not
have. Frames it draws are counted and reported on the next step, so a flow with
a gap in it says so rather than quietly missing a screen.

## Settling

Every verb takes a `settle:`.

```dart
await s.tap(button);                          // Settle.standard — up to 5 seconds
await s.tap(button, settle: Settle.none);     // don't wait
await s.tap(button, settle: Settle.frames(3));
await s.tap(button, settle: Settle.upTo(Duration(seconds: 30)));
```

The default gives up after five (fake) seconds instead of throwing. This
matters: a screen with a spinner on it **never** settles, and
`pumpAndSettle` throws on one. A scenario that reaches a loading state records
`settled: false` on that step — the GUI says *"still animating"* — and carries
on.

`s.settle()` is the wait without a step: the same policy (or the one you
pass), no capture. It is what a suite ported from raw widget tests maps a
legacy `pumpAndSettle()` onto, and the wait to reach for after work you
pumped through `s.tester` yourself.

`Settle.strict` is the default made red: the same five seconds, the same
landing of real work afterwards, and a screen *still* asking for frames when
both are done fails the step instead of recording a flag. Reach for it where a
spinner in a picture is a bug — `settled: false` is a number in a report, and
a scenario whose assertion finds its widget passes with a spinner in every
frame for as long as nobody reads that number. Say it once for a folder:

```dart
Future<void> testExecutable(FutureOr<void> Function() testMain) =>
    runScenarios(testMain, settle: Settle.strict);
```

A scenario's own `settle:` still wins, and so does a verb's — `settle:
Settle.standard` on the one `tap` whose picture is meant to show the spinner.

### Motion that says nothing

A step that never settles runs its whole budget on every replay, and the
run names what kept it going: `settled: false` on the step comes with
`stillTicking`, and the GUI's *"still animating"* notice lists the same —
`CircularProgressIndicator (lib/src/orders/status_cell.dart:42)` for a
framework widget, by the line of the app that built it, or the frame that
started an animation of the app's own.

Most of it is a spinner, a shimmer or a pulsing dot, and the phase it is at
carries no information. Say so in the app, once, where the loader is built:

```dart
import 'package:flutterware/ambient.dart';

Ambient(child: CircularProgressIndicator())
```

Outside a scenario `Ambient` builds its child and nothing else. Inside one,
nothing under it schedules a frame, and every Material progress indicator
without a controller of its own is drawn at one fixed phase — so the step
settles, and the picture is the same on every run and every machine. Anything
else under it freezes at its own start.

`Settle.strict` is not relaxed by it: a step that ends with an `Ambient` on
screen still fails there. Freezing makes the picture deterministic; it does
not make a loader on screen acceptable where the suite says it is not.

### A post-frame callback nothing schedules a frame for

`WidgetsBinding.instance.addPostFrameCallback` does not request a frame — it
appends to a list and waits for the next one, "whenever that may be, if ever"
in the SDK's own words. And the test binding draws no frame at all for a pump
with nothing scheduled. Put the two together and a callback registered while
the tree is quiet **never runs**: not on the next verb, not on `s.settle()`,
not on a raw `s.tester.pumpAndSettle()`, which loops on the same flag.

Registered during a build it is fine — the frame in progress runs it at its
end. Registered *outside* a frame it is stranded, and the shape that bites is
an `initState` that awaits first:

```dart
Future<void> _load() async {
  await repository.fetch();                    // the frame is long over here
  WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
}
```

The fix belongs in the app, because on a device that callback is equally
waiting on somebody else to schedule a frame — it just usually gets one:

```dart
var binding = WidgetsBinding.instance;
binding.addPostFrameCallback((_) => _reveal());
binding.ensureVisualUpdate();                  // schedules one unless one is coming
```

Where the app is not yours to change, ask for the frame from the scenario:

```dart
s.tester.binding.scheduleFrame();
await s.settle();
```

Nothing here is a scenario's doing — a plain widget test strands it the same
way. What scenarios changes is that it strands it *reliably*: `tester.pumpWidget`
leaves a frame scheduled and the stranded callback catches a ride on it, while
every verb here settles to a quiet tree, so there is never a ride going. Put a
`pumpAndSettle()` before the registration in a raw widget test and it stops
firing there too.

### Work on the real event loop

A settle follows frames, and work that resolves on the *real* event loop — an
asset read, a decode on an engine thread, a file, an isolate — schedules none
while it is in flight. Every verb lands what it can see for itself: a pending
`ImageProvider`, an asset read through `s.assets`, and a dozen guessed turns
of the real loop for the rest, which is enough for an SVG and nowhere near
enough for a 6 MB model import. For the rest, the app says so:

```dart
import 'package:flutterware/real_work.dart';

@override
void initState() {
  super.initState();
  _model = RealWork.track(_loadModel(), label: 'scene model');
}
```

`RealWork.track` hands the future straight back; outside a scenario it costs a
set insert and a listener on the future, nothing more. Inside one, every verb that follows waits — real milliseconds, a
pump between turns so the continuations run and the `setState` at the end is
drawn — until it has completed, then photographs. A tracked future that never
completes runs into the scenario's deadline, whose message names the label.

Without it, the shape by hand is poll-and-pump, and the pump is the whole
point:

```dart
while (!scene.ready) {
  await s.tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: 1)));
  await s.tester.pump();
}
```

What does **not** work is awaiting the app's future bare, or inside
`s.runAsync`. A future made under fake time completes through a fake
microtask, and only a pump runs those; the body suspended on that future is
the one thing that could have pumped. Bare, that is thirty seconds of nothing
and then a deadline; inside `s.runAsync`, no pump can run at all and the
watchdog names it after eight. `s.runAsync` is for work that needs the real
clock and nothing else — a database, a socket — never for a future the app
already created.

## Shots

By default every verb captures. `Shot('name')` names the picture; the unnamed
ones are collapsed as detail steps in the flow.

```dart
scenario('Long flow', shots: Shots.manual, (s) async {
  await s.tap(next);                       // no capture
  await s.tap(next, shot: Shot('Summary')); // captured
});

await s.tap(next, shot: Shot.skip);        // skip just this one
await s.tap(next, shot: Shot('Home', tags: ['store']));
```

Tags are how the store lane picks its screenshots — see below.

## Splitting a flow

One scenario, every path through it:

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

The body **replays once per path**, so each branch starts from exactly the
state the fork was reached with. Steps before the fork are captured once and
shared; the flow graph fans out where the app does. Splits nest, and a failure
inside one names the branch that reached it.

Because the body replays, anything a branch needs freshly built belongs in the
body — `setUp` runs once per scenario, not once per path.

## Devices and languages

A folder says what it is for, once, in the file `flutter test` already looks
for:

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

**The list is the offered set, and its head is the default.** No scenario
mentions a device. `test/scenarios/desktop/` can name a different profile, and
opening a scenario from either folder frames it the way that folder says — the
GUI remembers a device *per folder*, so picking an iPhone on a phone scenario
never follows you to a desktop one.

The folder is the unit, and that is structural, not a preference: devices are
selected **per folder**, never per scenario. A suite whose phone and desktop
scenarios interleave in one directory has to split into folders before it can
say so. `orientations` is likewise an axis, **crossed** with `devices` — two
devices × two orientations declares four matrix points, not two — so a suite
that used to name `iPadLandscape` as its own device names the device once and
the orientation beside it. (A device that cannot rotate contributes one point,
not two.)

`flutter test` runs one pass at the head of each list. CI brings its own:

```sh
flutter test test/scenarios/mobile \
  --dart-define=fw.devices=iphone-se,android-tall \
  --dart-define=fw.languages=en,fr
```

That declares one real test per combination — `Counter [iPhone SE · en]` … —
from a single invocation and a single compile. `FW_DEVICES` / `FW_LANGUAGES`
do the same for a CI job that would rather set an environment block.

Under the runner, don't restate the lists at all: `fw run scenarios run
matrix=declared` reads the folder profiles and runs every point they declare
— the union of their devices, languages and orientations, crossed the same
way explicit lists are. Adding a device to the declaration then adds it to
CI, instead of silently not.

Inside a body, `s.assignment` reports what this pass is running as, so an
expectation can adapt to the screen it is on.

## Fonts: the lane decides how text measures

`flutter test` launches its tester with `--use-test-fonts
--disable-asset-fonts`, hardcoded — no flag turns it off. Any family nobody
loads real bytes for draws every glyph as an identical filled box **and
measures at the box's width**, roughly double a real glyph. That is the wrong
kind of wrong: the suite still passes, layouts still resolve, and every
screenshot is lying about where text ends. Headings that name a bundled
family look fine while the body text beside them lies.

Flutterware closes this in both lanes. Every family in your
`FontManifest.json` is loaded before anything runs — under the runner and
under bare `flutter test` alike — and under `flutter test` the
platform-default families (`Roboto`, the Apple and Windows system names) get
real Roboto from the SDK's own cache, so text that names *no* family measures
real too. A family you bundle yourself is always left to your bytes.

The residue is why the runner is the lane for pictures: under `flutter test`
an iOS-profile scenario measures its default text as Roboto — close, not SF.
`fw run scenarios run` spawns the tester without those flags, so it renders
and measures the real thing; treat its captures as the authoritative ones,
and bare `flutter test` as the assertion lane it is.

## What a run leaves behind

In the GUI, opening a scenario runs it and draws the flow. From the CLI or an
agent — the same actions, the same shapes:

```sh
fw run scenarios list
fw run scenarios run --file=test/scenarios/mobile/shop_test.dart
fw run scenarios run --devices=iphone-se,android-tall --languages=en,fr
fw run scenarios run --tag=smoke
```

A matrix writes one directory per point — `<output>/<device>-<language>/` —
with an `index.json` beside them mapping each assignment to its directory and
result. Each step leaves a PNG, a `.tree.json`, a `.semantics.json` — the
merged semantics tree in reading order, labels and flags and actions by name —
and its texts; a failing scenario reports the error **with the frame captured
at the failure**, not the one before it. A scenario that raised more than one
exception reports each with its own message and its own stack — never
`flutter_test`'s "Multiple exceptions (2)" counter, which is the sentence it
prints after discarding both.

Beside the artifacts sits `run.json`: the whole run in the result's own
shape, every step of every scenario. The reply the action hands back
summarises — by default only each failure's frame rides along (`steps=`
chooses) — so a script that counts steps reads `stepCount`, or the file. A
relative `--output` resolves against the worktree root, and `run.json` lands
in the same directory as the images it names. A red run carries a flat
`failed` list at the top — package, file, scenario, first line of the error
— so a script finds the red one without walking every package.

Several files run in one process, in the order given — `--file=a,b` or
`--file=a --file=b` — which is how to reproduce a failure that only happens
after another file has run: a future one scenario leaves in its fake zone only
bites the scenario after it. Each selector must match something; a typo in
the second is refused, not run green on the strength of the first.

What the app printed rides the steps: `print` and `debugPrint` are events on
the `print` channel, `package:logging` records on `log`, platform traffic on
`platform` — on the step that followed them, in the `eventTitles` digest and
whole in `scenarios read --events` (`--channel=print` for just the prints).
`dart:developer`'s `log` goes to the VM's logging stream and nowhere else,
here as under `flutter test`. A scenario that runs out its deadline ends on a
**failed step** it never took: no picture, the events since the last capture,
and a diagnosis as its failure — which verb the body was inside and the line
that called it, whether a completion is queued behind a pump nothing runs
(hand it to `RealWork.track`) or nothing is queued at all (a future from an
earlier scenario's fake zone, or real-time work; the previous scenario is
named), and which platform messages went out and were never seen answered,
with the app frames that sent them.

`scenarios read` takes a step by any leg `run` reported — the `tree` path, the
`image` path, or the `fw://` address every step carries — so a step has one
identity across `run`, `read` and the GUI.

`scenario(skip: true)` is honoured the way `flutter test` honours it: the
body never runs, the run stays green, and the outcome says `skipped` instead
of pretending it passed — the same file answers the same way on both lanes.

Content that is in the tree but not on the screen — the route you navigated
away from, an `Offstage` — is marked `offstage` in the `.tree.json`, and the
Elements tab folds it away so what you read is what the screenshot shows.

In the GUI, the step page's **Semantics** tab shows that tree: the words
bright and the structure dim, roles badged, each row lighting its rectangle
up on the screenshot. It is the projection a screenshot cannot show — an icon
button with no label is invisible pixels and an obvious gap in this list —
and it is where the strings for `Target.label(…)` come from.

`--tag` filters scenarios by `scenario(tags: [...])`, the same tag
`flutter test --tags` uses.

Runs share a warm harness, so the second one skips the compile. `restart`
drops it when you want a cold start.

## Named shots, as files

For finished store images, framed and sized for each store, use
[Store screenshots](store_screenshots.md). This is the raw material: the named
shots of a run, written as plain PNGs.

```sh
fw run scenarios shots --languages=en,fr --tag=store
```

Keeps only the **named** shots, at each device's own pixel ratio, into

```
<output>/<language>/<device>/01-welcome.png
                             02-menu.png
                             03-order-placed.png
```

With no `--devices`, each folder's profile answers, so one invocation produces
a phone tree for the mobile folder and a window tree for the desktop one. The
output directory is emptied first: what is in it afterwards is exactly this
run.

## Standalone captures

No runner, no GUI — a bare `flutter test` writes the pictures itself:

```sh
flutter test --dart-define=screenshots-destination=build/shots
```

(`SCREENSHOTS_DESTINATION` works too.) Files land under
`<destination>/<assignment>/<file>/<scenario>/<index>-<name>.png` — the file
the scenario was declared in, flattened (`test_scenarios_shop_test.dart`), as
the runner spells it. A scenario name is unique per file, not per suite, so
without it two files naming the same screen write over each other.
