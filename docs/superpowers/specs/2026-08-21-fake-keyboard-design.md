# The fake keyboard — a phone's keyboard in previews and scenarios

**Date:** 2026-08-21
**Status:** Designed. Three measurements were taken *before* the design, and
two of them changed it (§ What was measured). The owner decided four things on
2026-08-21, marked **owner** where they land. **All three PRs are built.**
What was built differently from what is written below is in § What PR 2 did
differently and § What PR 3 did differently.

**Lineage:** `2026-07-30-scenarios-design.md` (the substrate every scenario
verb runs on), `2026-08-15-previews-audit-on-flutter-tester.md` (the second
previews lane, which is a test binding and therefore shares the scenario
driver), `2026-08-13-screen-handback-design.md` (the screen grammar the
keyboard must not pollute), `2026-05-15-flutter-embedder-step3b-design.md`
(the guest with no platform channels, which is why we already own a
`TextInputControl`).

## The goal

A phone screen is not 844 points tall the moment somebody touches a field —
it is 508. Everything a layout gets wrong about that is invisible in every
tool we have: a preview renders the full screen, and a scenario taps a field
and photographs a screen no phone would ever show.

Two asks, one mechanism:

- **Previews.** A keyboard that behaves the way a phone's does — up when a
  field takes focus, down only when the view lets go of it — plus a toggle in
  the bar for raising it against a layout with nothing focused.
- **Scenarios.** The same, automatic, so a flow that fills a form is a flow a
  phone could have performed, and its shots are pictures a phone could have
  taken.

## What was measured

**A widget test, pinned SDK, iPhone-16 geometry.** Three facts, and the
second is the whole feasibility of the scenario half:

| Probe | Result |
| --- | --- |
| `tester.tap` on a bare `TextField` | `testTextInput.isVisible` → **true** |
| `primaryFocus?.unfocus()` | → **false** |
| `view.viewInsets.bottom = 336×3`, one `pump()` | `Scaffold` body **844 → 508** |

So the focus signal is already there, with no cooperation from the app, and
the inset alone is enough to make a real layout meet the smaller space.

**A live guest**, markers in `GuestTextInput`, driven through the C host with
real pointer events:

```
boot, field has autofocus:1     attach(text) → show
tap field A → field B           detach → attach(multiline) → show    ← no hide
tap field B → field C           detach → attach(text) → show         ← no hide
tap empty background            detach → hide
```

**The SDK source**, which explains that transcript and is the reason this
design has no heuristics in it:

- `TextInput._show()` has exactly one caller, `TextInput._hide()` exactly one
  (`services/text_input.dart:2358`, `:2364`).
- The hide is deferred: `_clearClient()` → `_scheduleHide()` posts a microtask
  that calls `_hide()` **only if nothing re-attached in the meantime**
  (`:2314`). That is why field → field produces no hide, and why nothing here
  needs a debounce of its own.
- `TextInputControl.show()/hide()` (`:2540`) are unimplemented no-ops on our
  `GuestTextInput`, which is installed in every previews guest because the
  guest has no platform IME.

## The mechanism: two signals, one meaning

The keyboard is up between a `show()` and the `hide()` that follows it. That
is the entire state machine, in both lanes:

- **Guest lane** (previews live, headless captures): override `show()` and
  `hide()` on the `TextInputControl` we already install.
- **Test-binding lane** (scenarios, the flutter_tester previews lane): read
  `binding.testTextInput.isVisible`, guarded on `isRegistered`. The harness's
  `_SpyMessenger` sees the same traffic raw, but `isVisible` also works under
  a bare `flutter test`, so one mechanism serves both.

`show()` arrives **twice** per focus (an `EditableText` requests the keyboard
on focus and on tap). The driver is edge-triggered on state, never on calls.

## The arithmetic

Three numbers, and getting only the first is how a fake keyboard ends up with
a `SafeArea` floating 34 points above it:

```
viewInsets.bottom  = keyboardHeight
padding.bottom     = max(0, deviceInsetBottom - keyboardHeight)   // → 0
viewPadding.bottom = deviceInsetBottom                            // untouched
```

This is what a real embedder reports, and `MediaQueryData.fromView` reads
`view.padding` directly rather than deriving it — so a driver that sets the
insets and leaves the padding alone is reporting a phone that does not exist.

In the test binding these are `FakeViewPadding`, which speaks **physical**
pixels while the device table speaks logical — the same trap
`applyScenarioRunArgs` already documents.

In the guest they are applied in the entrypoint's existing `MediaQuery`
override, which today turns the host's view insets into padding because
`FlutterWindowMetricsEvent` has no padding field. The keyboard cannot ride
that same channel for exactly that reason: the guest could not tell a notch
from a keyboard. It arrives as its own fact over the VM service.

## Staging the platform (owner, 2026-08-21)

The measurement's last line — *tap empty background → hide* — is correct
behaviour for what the guest currently is, and wrong for what it is drawn as.
The default tap-outside action (`widgets/editable_text.dart:6882`) unfocuses
on desktop unconditionally, and on mobile for every pointer kind **except**
touch. The guest fails both tests:

| | Guest today | The iPhone it is drawn as |
| --- | --- | --- |
| `defaultTargetPlatform` | macOS — nothing stages it | iOS |
| pointer kind | `kFlutterPointerDeviceKindMouse`, always (`app/native/input.c:50`) | touch |

So a keyboard staged on an iPhone would drop on the first click on the
background. A narrow fix exists — the framework registers that action through
`Action.overridable(context:)` (`editable_text.dart:5811` → `:5506`) precisely
so an ancestor can win, and a fifteen-line `Actions` override in the guest
wrapper would restore the phone rule for tap-outside alone.

**The owner chose the broad fix instead: the guest is staged as the device it
is drawn as.** The narrow one buys the keyboard and nothing else, and it
leaves in place a disagreement that is a bug in its own right — *the scenario
lane already stages the platform* (`applyScenarioRunArgs` sets
`debugDefaultTargetPlatformOverride`) and previews does not. Two lanes,
crossed over the same devices, rendering different apps.

Staging means two things:

1. **`debugDefaultTargetPlatformOverride`** from the staged device, pushed by
   the host through the framework's own `ext.flutter.platformOverride` — the
   switch DevTools' platform selector drives, registered by every debug
   binding, and already spelled in this repo as the `platform` debug flag. Its
   setter reassembles the application, so a `ThemeData` built at the top of a
   demo is rebuilt rather than left describing the machine the studio runs on.
   Debug-only, which every lane here is (the guest is JIT with a VM service;
   flutter_tester is debug). It moves page transitions, scrollbars, selection
   handles, `.adaptive` widgets and the tap-outside rule — every preview
   screenshot moves once, and moves *towards* the truth.

   **A guest-side extension of our own was built first and deleted.** It
   worked, in a widget test and in a live guest, and it was still the wrong
   answer: it did the same thing less completely, and only we would have known
   it existed. Look for the framework's switch before writing one.
2. **Touch pointers** when the staged device is a phone or tablet — the tap
   outside rule needs the kind as well as the platform. One field appended to
   `PointerEventMessage` and one line in `input.c`, following the length-guard
   versioning the file already uses for pan/zoom.

Three consequences to build for, not around:

- **Hover dies on phone staging**, which is faithful — phones do not hover —
  but a `MouseRegion` demo staged on a phone will stop reacting. Desktop
  devices and `Fit` keep the mouse.
- **The wheel must survive.** Plain hover moves are suppressed under touch
  staging; a hover *carrying a scroll signal* is not, or the human loses the
  only way to scroll a list. A phone has no wheel; the human has no phone.
- **A drag inside the picture now scrolls like a phone**, which collides with
  the stage's own pan under zoom. `_setPanning`/`_demoInput` in
  `catalog_view.dart` already arbitrate this; touch staging is what makes the
  arbitration visible, so it gets a test rather than a hope.

**Ordering.** Staging travels over the VM service, like axes and knobs,
because the C host has no channel for arbitrary data — that is why
`CatalogAxes` is pushed rather than passed. The reassemble is what makes that
safe: a push that lands after the guest has already built rebuilds it, so the
first frame of a fresh session is the only one that can be a frame early, and
headless captures await the push before capturing.

## The artwork: a schematic slab (owner, 2026-08-21)

Rows of rounded rectangles at the right height, tinted per platform, light and
dark. **No letters** — they would need a font that differs between the harness
and a bare `flutter test`, and a per-locale layout to not be a lie.

**Glyphs on the keys that identify the keyboard, and no others** (owner,
2026-08-21). `@`, `.`, `/`, `.com` and the digits stand in the same place on an
AZERTY, a Cyrillic and a QWERTY keyboard, so neither objection above reaches
them — and they are exactly what tells one variant from another. Drawn bare, an
email row and a text row differed only in how wide the middle key was, which
nobody reads as a keyboard type. ASCII only: a glyph the rendering font lacks
is a tofu box, which on an otherwise blank key reads as a bug, so the keypad's
backspace is a drawn shape rather than `⌫`. `FakeKeyboardPainter.labels` is the
seam a test asserts on, because a painted label is invisible to every finder.

**Painted, never built.** A keyboard composed of widgets would put key caps in
front of `find.text`, a hundred nodes into the semantics and transcript
audits, and a wall of junk into `screen()`. A `CustomPainter` under
`ExcludeSemantics` is one leaf, one paint call, and invisible to every finder.

It lives **inside the guest / inside the pumped tree**, above the app, so that
every capture that exists already contains it — embedder captures, tester
captures, scenario shots, motion frames, web exports — with no compositing
step anywhere. Shots come off the render view's layer
(`scenario.dart:1517`), so this is free.

## Occlusion (owner, 2026-08-21)

The slab hit-tests true. A tap that lands on it does not reach the app,
because that is what a keyboard does.

One place must know about it beyond the painter: a scenario's `_resolve`
gains a check for a target whose centre lies under the band, so the failure
says *the keyboard is over this* and names `s.keyboard.dismiss()` — rather
than surfacing as a tap that silently did nothing. A refusal is the feature
here; a warning in a console the flow sails past is not.

## Previews: the control surface

The keyboard is autonomous by default and the bar is an override on top of it:

- **Auto** (default) — exactly what the app asks for, per the two signals.
- **Forced up** — raised with nothing focused, which is how you ask "what does
  this layout do with 336 points less" without hunting for a field. Sticky
  until cleared or dismissed.
- **Forced down**.

`?keyboard=` in the address so a link, a screenshot and the panel agree;
`--keyboard` on `screenshot`, `inspect` and `compare`; `keyboards:` on
`PreviewCanvas` beside `devices:` and `orientations:`, because in previews the
keyboard genuinely is a staging axis — nothing focuses on its own, so crossing
it is how a matrix covers it. (In scenarios it is not an axis; see below.)

**The dismiss key is drawn by the host**, over the keyboard band, inside
`StageSpecimen` (`stage_ground.dart`, rewritten by #233 — the picture now has
a ground and an edge, and this is chrome on that picture). Host-side keeps the
tool's affordances out of the guest's tree and out of every capture, while the
slab itself stays in the guest so the captures contain the keyboard.

Pressing it calls `client.connectionClosed()` in the guest, which is what a
platform sends when the user closes the IME without touching the app — the
framework then unfocuses the field (`editable_text.dart:4213`). It is the only
gesture on a real phone that dismisses a keyboard from outside the app, and it
makes the app *react* rather than making artwork disappear.

**Trap:** on that path `TextInput._clearClient()` never runs, so the control
receives no `detach`. It has to clear its own client and key listener, or the
next keystroke goes to a field that no longer believes it is focused. Built as
`GuestTextInput.dismiss()`, which tears down before it tells the client.

## What PR 2 did differently

Eight departures, each with its reason. Everything else is as written above.

- **The dismiss key is drawn around the guest's picture, not inside
  `StageSpecimen`.** `StageSpecimen` is only reached by the *bodyless* stagings
  — a framed phone goes through `DeviceFrame` instead — so a key put there
  would have been missing from exactly the picture the feature is for.
  `StageKeyboardDismiss` lives in `stage_ground.dart` as designed and wraps the
  guest one level lower, where both paths pass through.

- **Which keyboard to draw is read, not pushed.** PR 1 stages the platform
  through the framework's own `ext.flutter.platformOverride`, so
  `defaultTargetPlatform` in the guest is already the staged phone's — the same
  fact the demo's own `.adaptive` widgets read. A second copy of it on the
  keyboard's wire is a second copy that can disagree.

- **The bar control is a menu of three named rows, not a cycling icon.** Its
  two neighbours in the capsule are switches; this one has three states and the
  default is the interesting one. A cycle would have made *automatic*, *up* and
  *down* indistinguishable until you had clicked twice to find out which you
  were on. The fill still says the one thing its neighbours say — **lit when a
  keyboard is actually up**, which in `auto` is the app's answer and not the
  address's.

- **`--keyboard` is on `screenshot` and `inspect` only.** `compare` declares no
  framing flags at all — no `--device`, no `--orientation` — so a keyboard flag
  there would have been the first, and the canvas declaration is already its
  lever. `audit` runs on the flutter_tester lane, which has no keyboard until
  PR 3.

- **`keyboards:` on `PreviewCanvas` is declared, and crossed by nobody yet.**
  The panel and the headless lane take its head as the default, which is what
  makes it visible today. The *matrix* over it belongs to the harness, and the
  harness is a test binding — PR 3.

- **Nothing animates in previews.** The height is a pushed fact and it lands in
  one frame. The ~250ms slide over fake time is the scenario lane's, where the
  settle loop already owns a between-frames hook to step it in; a previews-side
  animation would have to be awaited by every headless capture for nothing.

- **`Device.keyboard` and `Device.landscapeKeyboard`, not a `DeviceKeyboard`
  pair.** Two doubles beside the four inset doubles the table already carries,
  and `rotated()` swaps them exactly as it swaps the insets — so everything
  downstream of `oriented()` sees one number and never an orientation.

- **The verification tool is `app/tool/embedder/fake_keyboard_probe.dart`.**
  `keyboard_probe.dart` was taken: that is the *measurement* app at the repo
  root, the one that runs on a simulator to find out how tall a real keyboard
  is. This one takes those numbers as given and asks whether the fake one
  behaves.

### And one thing PR 1 got wrong, found here

`staging_probe.dart` — PR 1's own verification — was calling
`ext.flutterware.setStaging`, an extension deleted the same day the framework's
own switch replaced it. `GuestVmService.callExtension` swallows an unknown
method, so the probe staged **nothing** and passed anyway. Fixed to go through
`stageGuestPlatform`, the panel's own call, and with it a second wrong
assumption surfaced: staging does not remount the demo. `platformOverride`
*reassembles*, which rebuilds while keeping every `State`, so the field carries
what the previous half typed and the probe's expected strings are deltas now
rather than literals.

The rule, since this is the second time: **a probe that spells an extension
itself goes on passing after the code it checks stops using it.** Call what the
product calls.

## Scenarios: a policy, not an axis

Focus drives the keyboard, so crossing it would double every run to produce
the same pictures. It is a policy on the profile.

**On by default, with one off switch (owner, 2026-08-21).** `keyboard: off`
restores today's behaviour byte-for-byte, and it has to cover *both* new
behaviours — the insets and the occlusion — because a suite that fails on one
fails on the other in the same update. `lib/src/scenarios/` is published: this
moves every existing suite's pictures from the first tap on a field onward,
once, and `compareScenarioRuns` is how a consumer reads that delta.

**Where it fires.** Inside the `Settle` pump loop, which already owns a
between-frames hook for landing real work. Each iteration checks the flag;
when it flips, the inset is stepped over ~250ms of *fake* time. The raise
therefore animates, the motion recording shows it slide the way a phone does,
and it costs nothing because the clock is not real.

**Verbs.** `s.keyboard.show()`, `s.keyboard.hide()`, `s.keyboard.dismiss()`
(the platform-closed path above), for a scenario that wants to say it
explicitly.

**Reporting.** The step records `keyboard: up (336)`. The `screen()` reply
carries it as a **note**, not a node — a real phone's keyboard is not in the
app's tree either, and an agent that cannot see why half the screen is gone is
the only reason to mention it at all.

## The heights are declared, not computed

`Device` grows a `DeviceKeyboard(portrait:, landscape:)`, measured, exactly
like `Device.landscape` insets and for the same reason: permuting geometry is
wrong on the devices it matters on. An iPhone's portrait keyboard is not its
landscape one scaled.

A measurement pass produces them — a throwaway app reading
`MediaQuery.viewInsetsOf` on a simulator and an emulator, one number per
device per orientation. **Devices we cannot boot inherit the nearest measured
device of the same platform and size class, and say so in the doc comment**
rather than being quietly interpolated.

### Measured, 2026-08-21

A probe app autofocuses a field and waits for the insets to read the same twice
— the raise animates, and the first frame after it starts is not the height it
lands on — then asks for the other orientation and does it again. Logical
pixels, iOS 26.2 simulators and one Android 15 emulator, predictive bar on,
**hardware keyboard disconnected** (`ConnectHardwareKeyboard`, or the software
keyboard never appears and every reading is a confident zero).

| Device | Screen | Portrait | Landscape |
| --- | --- | --- | --- |
| `iphone-se` | 375×667 | 260 | 200 |
| `iphone-13-mini` | 375×812 | *335* | *248* |
| `iphone-13` | 390×844 | 335 | 248 |
| `iphone-12-pro-max` | 428×926 | 345 | 248 |
| `iphone-16` | 393×852 | 336 | 219 |
| `iphone-16-pro-max` | 440×956 | 346 | 219 |
| `ipad` | 810×1080 | 320 | 408 |
| `ipad-pro-13` | 1024×1366 | 405.5 | 501 |

| `android-small` | 360×640 | 299 | 239 |
| `android-medium` | 412×732 | 332 | 261 |
| `android-tall` | 412×915 | 336.4 | 261.3 |
| `android-big` | 480×853 | 332 | 261 |
| `android-small-tablet` | 800×1280 | 320 | 320 |
| `android-medium-tablet` | 1024×1350 | 320 | 320 |

Italics are the one entry that is not a measurement.

**One emulator wears every Android geometry**, through `wm size` and `wm
density` at the ratio each entry declares — there is one AVD, and it is a
Pixel-shaped 412×915 at 420dpi, which is `android-tall` exactly. Its IME is
Gboard rather than the AOSP keyboard, which is what a phone actually has. What
that shows: Gboard settles on **one height per density** — 332/261 on every
phone big enough for it — and only a screen too short to afford that gets less
(`android-small` at 299/239). Density moves it by about four points, not by a
factor, so the dp numbers are stable across the phones in this table.

Three things the pass had to work around, each worth knowing before repeating
it:

- **No simulator will render an app at a mini's geometry.** Both the iPhone 13
  mini and the iPhone 12 mini device types run this app at 320×568 — the
  iPhone-SE-1 compatibility screen — under iOS 26.2, freshly created and after
  an erase. So `iphone-13-mini` inherits `iphone-13`, the nearest measured
  device of its class: a notched phone whose keyboard sits above a home
  indicator. `iphone-se` is the same width and 75 points shorter, because it
  has neither.
- **iPads ignore `setPreferredOrientations`.** A multitasking-capable iPad
  honours only the *app's* declared orientations, so the landscape numbers were
  taken by editing `UISupportedInterfaceOrientations~ipad` in a copy of the
  built bundle — and editing it **before** `simctl install`, because iOS reads
  the plist at install time and an edit to the installed container does
  nothing at all.
- **The landscape keyboard changed with the iPhone 16 family**: 219, where the
  13 and the 12 Pro Max both give 248. Two devices of each generation agree,
  which is why it is in the table rather than treated as a bad reading.
- **Android's first focus after a cold start raises nothing.** The request
  lands before the window has focus and the IME never appears — a reading of
  zero that looks exactly like a device with no keyboard, which is why the
  probe says `NO-KEYBOARD` rather than reporting a number, and why it asks
  again every two seconds until something comes up.

### Safe areas the pass found wrong, and did not touch

The probe reports the view's padding beside the keyboard, so the pass also
measured what the table claims about safe areas. Four entries disagree with
iOS 26.2:

| Entry | Table | Measured |
| --- | --- | --- |
| `iphone-12-pro-max` | `insetTop: 44` | 47 |
| `iphone-16-pro-max` | `insetTop: 59`, landscape sides 59 | 62 |
| `ipad` | `insetTop: 20` | 32 |
| `ipad-pro-13` | screen 1024×1366 | 1032×1376 (the M4) |

**Corrected 2026-10-08**, with the rest of the table, once frames stopped
lending their safe areas: `device_frame`'s bodies now give the drawing and
the table gives the numbers, measured again on iOS 26.2 by
`tool/measure_devices.dart` — see `lib/src/devices.dart`. `tool/device_probe.dart`
replaced `tool/keyboard_probe.dart`, and the mini was dropped. What follows is
why it waited.

**Left alone on purpose.** `app/test/previews/frames_test.dart` pins these
numbers to `device_frame`'s own artwork for the five hand-drawn bodies, so
correcting the table means correcting a drawing — a different piece of work,
with its own screenshot churn, and not one to smuggle into a keyboard change.
The `iphone-13-mini` pixel ratio (2, where the hardware is 3) is the same
story, and its doc comment already said the measurement pass would settle it:
the pass could not, because no simulator renders a mini at a mini's size.

One thing the pass *confirmed*: the iPhone 16 family's landscape insets, which
the table admits were derived from the rule the older phones follow rather than
measured. The sides come back at exactly the declared 59 on an iPhone 16.

### Two rules that turned out not to be one rule

- **A phone's keyboard shrinks when it turns and a tablet's does not.** Every
  phone measured loses height in landscape — 336 → 219 on an iPhone 16, 299 →
  239 on a small Android. An iPad *grows* (320 → 408, 405.5 → 501: a wider
  screen buys bigger keys) and Gboard on a tablet stays exactly where it was.
  `test/devices_test.dart` pins both halves, having first been written with one
  rule for both and failed on the tablets.
- **The keyboard eats the home indicator.** `padding.bottom` read 0 on every
  device while the keyboard was up, on both platforms — which is the arithmetic
  in § The arithmetic, confirmed rather than assumed.

### The intent is on the wire, and one case is not optional

`attach` carries the `TextInputConfiguration` and the test lane's
`setClientArgs` carries the same thing as a map — measured, a phone field
reports `{name: TextInputType.phone}` and a number field reports
`{name: TextInputType.number, signed: false, decimal: false}`. It arrives on
`setClient`, the **first** of the five messages that precede the `show`, so by
the time there is anything to decide the type is already known. Both lanes
have it; neither had been reading it.

**`TextInputType.none` is the case that is a bug rather than a refinement.** It
is a field that opens a connection and wants no system keyboard at all — a
custom pad, a date picker sheet, a calculator's own keys — and the platform
draws nothing for it. `TextInput.show` is still sent, so a control that took
the call at face value put 336 points of keyboard over a screen that has none
on the phone it is imitating. Both lanes read the type now, in `show` rather
than in `attach`, because a field beside a *use the normal keyboard* toggle
changes its mind through `updateConfig` and never re-attaches. The forced modes
still ignore it: they ignore focus already, and they are the human asking about
the layout rather than the app asking for a keyboard.

**Per-input-type heights and per-input-type artwork are built.** What made it
possible was already on the wire and simply not being read: `attach` carries
the `TextInputConfiguration` and the test binding carries the same
`{name, signed, decimal}` map, so one pure-Dart discriminator —
`keyboardVariantForName` — serves both lanes off the identical payload.

**Height and picture are separate consequences of one fact**, and keeping them
separate is what makes the model fit all three platforms. A `KeyboardVariant`
always changes what is drawn; it changes the height only where the device has a
measurement saying it should. An iPad draws a digit pad and stays 405.5 tall;
Gboard draws a digit pad and stays 336.4; an iPhone draws one and loses 27–45
points. `Device.keypadKeyboard` is null wherever there is no shrink, and null
covers three situations that all want the same answer — a device that genuinely
does not shrink, a device with no keyboard, and a cell nobody has measured.

### How many classes there are, measured 2026-08-21

`tool/keyboard_type_probe.dart` — the sibling of the orientation probe, cycling
fifteen input types in portrait. Three simulators and the Gboard emulator.
**There is no single answer: the platforms do not even agree on the shape of
the question.**

| | Classes | The split |
| --- | --- | --- |
| iPhone 16 | **2** | 336 QWERTY · **291** keypad |
| iPhone SE | **2** | 260 QWERTY · **216** keypad |
| iPad Pro 13 | **1** | 405.5, every type |
| Android · Gboard | **2** | 336.4 everything · **370.3** `visiblePassword` |

The keypad class on iPhone is exactly three types — `phone`, `number` and
`number.decimal` — and its membership is identical on both phones.

Four things worth having measured rather than reasoned:

- **The delta is tens of points, not the ~120 this section previously
  guessed** — and it moves with the phone's *generation*, not its size. 44 on
  an iPhone SE and 45 on both 16s; **27** on an iPhone 13 and a 12 Pro Max.
  An earlier draft of this line said "constant across two phones of very
  different sizes", which generalised from two samples that happened to be the
  same generation. Two more devices disproved it.
- **`number.signed` is a QWERTY, not a keypad.** Allowing a minus sign gets the
  full `numbersAndPunctuation` keyboard at full height, on both phones. A table
  derived by reasoning would have put it with the other numbers.
- **An iPad has no split at all.** It shows a full keyboard with a number row
  for everything, so per-type heights buy *nothing* on a tablet — four of the
  fourteen touch entries in the table.
- **Android inverts the premise.** Gboard does not shrink for a keypad; it
  swaps the layout and keeps the height. The one type that differs is
  `visiblePassword`, and it is **taller** — so the single number we carry is
  right for thirteen of fifteen types, and the one case it is wrong about
  under-reports by 34 points. Under-reporting produces a false *pass*, which
  is the harmless direction.

### The keypad column, as far as it is verified

A second pass, one reading per class per orientation. **The letters column is
the control**: where it reproduces the number already in the table, the keypad
reading beside it was taken under the same conditions and is trusted; where it
does not, neither is.

| Device | letters ⟂ | **keypad ⟂** | letters ↔ | **keypad ↔** |
| --- | --- | --- | --- | --- |
| `iphone-se` | 260 ✓ | **216** | 200 ✓ | **162** |
| `iphone-13` | 335 ✓ | **308** | 248 ✗ | *165, unverified* |
| `iphone-12-pro-max` | 345 ✓ | **318** | 248 ✗ | *165, unverified* |
| `iphone-16` | 336 ✓ | **291** | 219 ✓ | **181** |
| `iphone-16-pro-max` | 346 ✓ | **301** | 219 ✓ | **181** |

**What the control caught.** On two freshly created simulators the landscape
letters height came back as 209 against the table's 248. The same simulator
under the *orientation* probe reads 248, so the device was not the variable —
the reading was. Raised from nothing, an iOS keyboard arrives and grows its
predictive bar a beat later, and a settle rule that stopped at the first
plateau caught it before the bar. The orientation probe never sees this
because it morphs a keyboard that is already open.

Without that column there would now be two wrong numbers in the table and
nothing to say so. It is the reason a measurement pass should always re-measure
something it already knows.

The two unverified cells stay **unset** rather than guessed, and unset means
*no shrink*: those devices keep their letters height for a keypad until
somebody measures them. A keyboard that is too tall is the failure mode this
whole section is about, so leaving two cells conservative is a smaller lie
than filling them from a round whose control failed.

So the pass that was described as "another measured number per device" is
smaller than that: **one extra number per iOS phone**, reaching three input
types, and nothing for tablets or for Android except one taller password
keyboard. Two of the six are already measured above. It still owes the painter
a keypad layout, because a 291-point band drawn with ten-key rows is a lying
picture — and now only on iOS phones, for three types.

## What PR 3 did differently

Six departures, and the first is the one worth reading.

- **The slide is a real `Ticker` in the pumped tree, not a step in the settle
  hook.** The hook was tried first and it does not work, for a reason worth
  writing down: a `Settle` loop asks `hasScheduledFrame` *after* its pump, and
  the frame that writing the view schedules has been consumed by then. So a
  keyboard driven from between the frames stops one frame in — a quarter of the
  way up, with the layout laid out against a screen that never existed. An
  `AnimationController` keeps the binding asking for frames until it lands,
  which is exactly what every settle policy already knows how to wait for, and
  what `pumpAndSettle` waits for too. The hook survives, doing only what it can
  do: reading `testTextInput.isVisible` and pointing the ticker.

- **`keyboard: false`, not `keyboard: off`.** The switch is binary and the
  design's `off` was a value from an enum that does not exist; a `bool` needed
  no new noun. It is on `runScenarios` beside `shots:`, read as the folder
  declares — the same rule, because a matrix declares one body once per
  assignment and each declaration keeps what it was made under.

- **A named-covering hook on the shared resolver, not a scenario-only check.**
  `_ensureReachable` already computes the target's centre and already refuses a
  covered target; the keyboard needed the same refusal with a better sentence.
  So `TargetResolver` takes an optional `namedCovering` that outranks the
  generic one, and the engine goes on knowing nothing about keyboards. The live
  drive layer gets the seam for free when it wants one.

- **`Settle.full` lands once before its loop.** It was the one policy that
  called the hook not at all — `pumpAndSettle` owns its own loop — so a
  scenario written with `settle: Settle.full` would have had no keyboard.
  Landing once *before* the loop is the whole of what a hookless policy can do,
  and it is enough: the sample points the ticker and the SDK's own settle waits
  the slide out like any other animation.

- **The previews harness stages a keyboard, it does not drive one.** The
  `flutter_tester` lane renders each entry cold, and nothing cold ever focuses
  a field — so there is no signal to follow there and no driver. What it does
  have is the canvas: `keyboards: [KeyboardMode.up]` is applied by
  `applyCanvas` as a static height on the view, with the same slab over it. The
  axis is *declared* in PR 2 and *crossed* here, in the one lane where crossing
  it means anything.

- **The verbs are `show` / `hide` / `auto` / `dismiss`, four rather than
  three.** `auto` is what hands the keyboard back to the app after a `show`,
  and without it the only way back was `dismiss`, which also unfocuses the
  field — a bigger hammer than "stop holding it up".

### And a bug in PR 2 that this found

`FakeKeyboard` returned its child bare at zero and wrapped it in a `MediaQuery`
and a `Stack` at 336. That **reparents the app** the moment the keyboard moves:
every `State` under it is disposed and rebuilt. In a scenario it showed up as
`TextInput.show` immediately followed by `clearClient` — the field asked for a
keyboard, the wrapper appearing threw the field away, and the keyboard it had
just asked for went straight back down. In a preview the same thing would have
emptied whatever had been typed into the demo.

The wrappers are unconditional now and only the numbers move; down costs one
`MediaQuery` holding the data it was given and a zero-height band.
`test/ui_catalog/fake_keyboard_test.dart` pins it with a `State` that counts
its own mounts.

The rule: **a widget whose shape depends on a value it also animates will
reparent everything below it.** Keep the shape and move the numbers.

## What the review pass found

Three things, all found by asking what a seam does rather than by reading it.

- **A raised keyboard survived into the next branch of a `split`.** The host
  widget clears its own bookkeeping as it unmounts, so the driver believed
  there was nothing left on the view to put back — and the fresh app of the
  second branch was laid out against 336 points of keyboard nobody had asked
  for. The unmount touches nothing now and the reset between replays writes
  unconditionally, from where a metrics change is safe. Pinned by a two-branch
  scenario where one branch types and the other reads the insets.

- **The refusal's own advice did not work.** It offered `s.scrollTo(...)` as a
  way past a covered target; measured, `Scrollable.ensureVisible` stops the
  moment the target is inside the *viewport*, and in the app this refusal
  actually fires on — one that does not resize — the viewport runs under the
  keyboard. So the scroll succeeded, the target was still covered, and the next
  verb was refused again. **The behaviour is right and the sentence was wrong**:
  a row parked at the bottom of a list under a real keyboard is not reachable
  on a real phone either. The message names `dismiss()` and nothing else now,
  and the test asserts it does *not* say `scrollTo`.

- **The dismiss key was dead on a keyboard somebody had held up.** The canvas
  re-pushes what the address says after every frame, so telling the guest alone
  put the keyboard straight back on the next rebuild — and the guest's own
  `up → auto` was undone before it could be seen. Pressing it clears the
  address parameter now, which is where the mode actually lives. Found by
  driving the studio; no test would have caught it, because the bug is the
  round trip.

The last of these settled an open question by construction: **forced-up does
survive an entry switch**, because it is on the address un-namespaced exactly
as `device` is.

## Not in v1

- IME composition, dead keys, CJK. Unchanged from today: the guest has no IME.
- Per-input-type heights (above).
- The accessory / suggestion bar as a separate fact. It is inside the measured
  number.
- Android's `adjustPan`. Flutter defaults to resize and so do we.
- The split and floating iPad keyboards.
- A phone with a hardware keyboard attached, which shows no soft keyboard at
  all. Our fake is always the soft one.
- Web.

## Order of work

Three PRs, each doing something visible on its own (and in this order because
the first is what makes the second faithful):

1. ~~**Stage the platform.**~~ **Built.** `debugDefaultTargetPlatformOverride` pushed with
   the device, touch pointers for phone and tablet staging, the hover and
   wheel rules, the pan arbitration test. Moves every preview screenshot once,
   for its own reasons, before a keyboard is anywhere near it.
2. ~~**The previews keyboard.**~~ **Built.** The shared core (`DeviceKeyboard`, the
   arithmetic, the slab), the guest driver, the tri-state control, the
   address, the canvas axis, the host-drawn dismiss key.
3. ~~**The scenarios keyboard.**~~ **Built.** The test-binding driver, the settle hook, the
   occlusion refusal, the profile switch, the step and `screen()` reporting,
   an example scenario that fills a form on a phone.

The measurement pass for the heights gates PR 2, not PR 1.

## Verification

`app/tool/embedder/fake_keyboard_probe.dart` — the spike tool, returning as a
real check rather than as prints. The transcript in § What was measured is its
contract, and it passes on a real guest: autofocus raises, an outside **touch**
on a phone-staged guest does not dismiss, the dismiss key does — and does it by
making the app let go, which is why the probe asserts `requested` rather than
`height` — a forced mode overrules the app without lying about what the app
asked for, and a stage with no measurement raises nothing however hard it is
asked.

Field → field is the one line of the transcript this probe does not drive: it
needs two field positions, and it is exactly what a widget test can say for
free. `test/ui_catalog/catalog_keyboard_test.dart` counts the flickers.

Written down because this repo has learned it the expensive way: a smoke test
that proves the guest survived a message proves nothing about arrival, which
is how keyboard input looked implemented for months while every key sat in a
framework queue.

## Open, deliberately

- ~~Whether `Fit` (no device) should have a keyboard at all.~~ **Settled by
  building it: no.** It has no device, therefore no measured height, and
  forced-up there raises nothing rather than inventing one. The bar segment
  goes dim and says so, like the rotation on a window.
- ~~Whether forced-up survives an entry switch.~~ **Yes, by construction**: it
  rides the address un-namespaced, exactly as `device` does, so it persists
  across entries and a link carries it. Left as a question the first time it
  was written; answered by building the address parameter the same way its
  neighbours are.
- ~~Whether the scenario off switch also belongs per-scenario, or only per
  profile.~~ **Built per-profile only**, which is the smaller promise and what
  nothing yet asks past. A scenario that wants one picture without a keyboard
  says `await s.keyboard.hide()` and takes it, which turned out to cover the
  case a per-scenario switch was imagined for.
