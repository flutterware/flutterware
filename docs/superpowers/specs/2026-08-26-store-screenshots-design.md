# Store screenshots — design

**Date:** 2026-08-26
**Status:** Built, phases 1–7 (§10b–§10j).
**Builds on:** `scenarios shots` (`app/lib/src/plugins/native/scenarios_core.dart`,
`_shots`), which already runs the suite, keeps the named shots at each device's
real pixel ratio and writes them per language and device. That action is the
floor this stands on, and it stays as the undeclared lane.

A store listing is the one artifact a project ships that nothing in the
toolchain owns. The screenshots in it are of screens the app already has, in
languages the app already speaks, at sizes two companies publish — and they are
still made by hand, once a release, by someone dragging a simulator window
around. The pieces to make them are all here: a harness that runs the app
deterministically with real fonts, a device table whose numbers already land on
Apple's two required sizes, an app that already speaks its own languages, and a
widget renderer.

This is the plugin that puts them together.

## Decisions taken before writing this

Seventeen. Six before the first draft, four before phase 3, two before phase 5,
five looking at the built panel — and five of them reverse a draft of this
document.

1. **No validator.** The first shape of this feature had a panel that inspected
   the output and reported what the stores would reject. It was rejected on the
   grounds `IconSitu`'s doc comment argues for icons: a grid of thumbnails
   answers *what have I got* and cannot answer *is it any good*, that judgement
   being relative and a thumbnail having nothing to be relative to. The same
   holds here — and it holds for correctness too, which is
   **produced, not checked**. A listing declares which store it is, the store's
   sizes come with it, and a set that a store would refuse is not expressible.
   There is nothing to validate because nothing wrong can be written down.
2. **Its own plugin**, `flutterware.store`, in the rail beside Splash screen and
   Launcher icon. Those three are the app's store listing; a scenario is a
   *source* here, not the subject.
3. **The frame widget is in v1**, with a demo in this repo good enough to be the
   default a project gets when it declares no frame of its own.
4. **The stage draws the arrangement, never the chrome.** It reads as a store
   listing because of how it is laid out — icon, name, rating, a three-up
   carousel with the fourth cut off by the edge — in this app's own type ramp
   and palette. Nothing in it is a copy of Apple's or Google's styling, so
   nothing in it goes stale when either restyles.
5. **`StoreShots`, not `Store`.** `Store` is the state-management word; a
   project that exports one from `package:flutterware/plugins.dart` collides
   with half the ecosystem. `StoreShots` also continues the vocabulary the user
   already types — `Shot`, `Shots` — which is the name they will reach for.
   The plugin *id* is `flutterware.store` and the rail says **Store**.
6. **No copy system, and no translation coupling.** A first draft resolved a
   shot's name through the project's translation catalog to produce a localized
   headline. Reversed: a shot's name is an identifier, a headline is display
   copy, and the frame — an ordinary widget in a localized tree — can already
   look copy up however the project keeps it. §2 is the argument.

### Taken before phase 3 (2026-08-26)

7. **Unframed where legal is the default.** A project that declares no `frame:`
   keeps getting raw app pixels wherever a store accepts them, which is every
   App Store set. Only Play's phone gets the built-in composition, because its
   geometry leaves no choice. Two reasons: building the frame must not silently
   change what phase 2 already exports for anybody, and a tool that invents a
   background and a headline band nobody asked for is making a marketing
   decision on a project's behalf.
8. **`frame:` names a file**, and the harness generator imports it the way the
   scenario harness already imports scenario files. Resolves §12's first open
   question against the `@StoreFrame` annotation: a scan is machinery to build
   and keep in sync, and its one advantage — several frames per project — comes
   with nothing to say which is in force.
9. **The demo's headlines live in a `store` catalog of their own**, separate
   from the shop's app strings. It demonstrates the real answer (copy lives
   wherever the project keeps copy), keeps marketing out of the app's string
   table, and gives the Translations panel a second catalog to show rather than
   mixing headlines in beside *Add to cart*.
10. ~~**An export keeps its raw captures**, in `.captures/`, so `store frame`
    recomposes without re-running the app.~~ **Reversed by decision 13.** The
    captures are a scratch the export sweeps; what survives is `unframed/`,
    and it survives because a person wants it rather than because a second
    pass needs it.

### Taken before phase 5 (2026-08-26)

11. **No source scan. The panel shows the last export.** The scan bought a
    skeleton before the first export and cost a parser with a permanent
    maintenance tail; the empty state gets the effort instead. §6 is the
    argument.
12. **Uploading is v2, not never** — reversing what §11 first argued. Both
    stores' APIs are plain REST, have been written in Dart before, and a
    project pushing a listing from flutterware rather than from a Ruby
    toolchain it otherwise has no use for is the consolidation on offer.
    ~~`.itmsp` comes with it.~~ **The `.itmsp` half is reversed** by
    `2026-08-27-store-live-and-upload-design.md` decision 1: Apple no longer
    supports it for app content, so it is not a format anything here may
    target. Out of v1 for sequencing: the images have to be right first, and
    credentials are their own design.

### Taken looking at the panel (2026-08-26)

13. **Capture and framing are one thing. There is no second pass to invoke.**
    The `frame` action is deleted — not demoted to a flag — and `export`
    always runs the app.

    Three findings, and the first two are what settle it. **The
    frame-authoring loop is `previews`**, which renders one composition in
    about a second against this rendering a whole listing in seventeen; the
    action was competing with a better tool that already existed for the one
    job it was for. **An export is a release artifact**, and any affordance
    that reuses what happens to be on disk can ship last week's screenshots —
    a bad trade at any speed. And the speed was nine seconds anyway, once
    §10g moved the PNG codec off the main isolate.

    Which leaves the captures with no reader — so they become a scratch the
    export sweeps, and what survives instead is decision 14.

14. **A composed set keeps its unframed originals**, under
    `unframed/<store>/<class>/<locale>/`. Not a flag and not a declaration:
    composing is precisely the case where the app's own pixels are *not* the
    deliverable, so it is the only case where keeping them says anything. An
    uncomposed set's originals already are the deliverable.

    This is `.captures/` turned from an implementation detail into an output —
    readable names, flattened so they are usable, and a sibling of the store
    trees rather than inside them, because `deliver` and `supply` would upload
    anything they found in `ios/` or `android/`. It also costs *less*: the
    demo kept 120 duplicate images and now keeps 30.

15. **What an export wrote is published**, as
    `package:flutterware/store_report.dart` —
    `StoreShotsReport.read('build/flutterware/store')`. The same shape
    `scenarios_report.dart` has and for the same reason: a CI gate, an
    uploader or a release note should be a few lines over typed classes rather
    than a directory walk written once per project. Plain Dart, version-gated,
    and a reader refuses a version it does not know rather than half-decoding
    it. It is also what the v2 uploader (decision 12) will read.

16. **No detail page; two dialogs.** A listing is a property of the *set*, so
    a page about one shot had a selection it could not justify. See §6.

17. **Nothing invented on the stage.** The rating and the Install button are
    gone. Decision 4's other half: an invented number is read as a fact about
    the app, and a fake Install button invites the panel to be read as a
    preview of a real store page.

### And two taken without asking

- **One frame per package, branching internally.** A phone composition and a
  tablet one genuinely differ, but the frame is handed `shot.canvas`,
  `shot.device` and `shot.index` and a widget branching on its input is what a
  widget is. A frame declared per class would put that branch in the config
  language instead, where it cannot see the pixels.
- ~~**The frame pass runs in the same tester process as the capture pass.**~~
  **Reversed by the compiler** — see §10d. The two passes have different sources
  and therefore different dills, so they are two `TesterHost`s on two build
  directories. Which turns out to be what makes `store frame` cheap to reach: it
  never touches the scenario harness at all.

## 1. The model

### A canvas is not a device

This is the load-bearing distinction, and Google is the reason it exists.

Apple's two required sizes fall straight out of the device table, to the pixel:

| device | logical | physical | Apple's slot |
|---|---|---|---|
| `iphone-16-pro-max` | 440×956 @3 | **1320×2868** | 6.9" iPhone — required |
| `ipad-pro-13` | 1024×1366 @2 | **2048×2732** | 13" iPad — required if the app runs on iPad |

Since the 2024 change you supply only the largest of each family and Apple
scales the rest, so those two are the whole iOS obligation. For Apple, the
canvas **is** the device's native output and nothing has to be composed.

Google Play cannot work that way, and it is not a preference:

- each side ≥ 320 and ≤ 3840
- **the longer side may not exceed twice the shorter side**
- JPEG or 24-bit PNG, **no alpha**
- prominent placement wants ≥ 4 shots with the short side ≥ 1080

The alpha rule is the one thing both stores agree on: Apple's screenshot
specifications say *no alpha channels or transparencies* in as many words. So
the opaque encoding is not a Play accommodation, as this document first had it —
there is no listing anywhere that would take a capture as it comes off
`toByteData`.

Every shipping Android phone is 20:9 — 2.222 — which is over the ceiling. **A
truthful full-screen screenshot of a modern Android phone is not a legal Play
screenshot.** That is a geometric fact about Play's rules, not a thing to work
around, and it settles the shape of this feature: on Play the screenshot is a
*composition* whose canvas is legal, with a real phone rendered inside it.

So a set carries two sizes, and they are allowed to differ:

- the **device** — what the app renders as, so the layout is honest
- the **canvas** — the image the store receives, which the frame fills

### The Android numbers, recommended

Asked for outright, so stated outright.

**Play phone: render on `android-tall`, canvas 1080 × 2160.**

`android-tall` is 412×915 @2.625 — that is a Pixel, in dp and in ratio, and it
should not change. 1080×2160 is exactly 2:1, which is the **tallest canvas Play
allows**, so it is the one that letterboxes a 20:9 phone least; and its short
side is exactly the 1080 that the prominent-placement bar wants. Any taller is
rejected, any shorter throws away vertical room the composition can use.

**Play 10" tablet: render on `android-small-tablet`, canvas 1600 × 2560.**

800×1280 @2 is 1600×2560 natively — legal at 1.6:1 and *exactly* Play's
recommended 10" tablet size. Here the frame composes for style, not for
legality; an unframed set at this size is shippable as it stands.

**Play 7" tablet: not in v1.** Play does not require it. If it is wanted later
the device to add is 600×960 @2 → 1200×1920, which is 1.6:1 and legal; nothing
in the table covers 7" today.

**Do not add a phone to the device table to make Play's geometry work.** The
only device whose native output is both ≥1080 on the short side and under 2:1 is
360×640 @3 → 1080×1920 — a 16:9 phone, which stopped shipping around 2016 and
whose layout will read as cramped and dated in every screenshot. Adding it would
buy an unframed Play lane at the cost of an untruthful one.

**Therefore: on Play, the frame is not optional.** That is Play's rule speaking,
not ours. It is worth saying plainly in the docs, because it is the one place
where a project cannot opt out of composition and will want to know why.

The escape hatch, for a project that insists: `PlayListing` accepts an explicit
`device:` and, when that device's native output is canvas-legal, uses it
directly with no frame. `android-big` (960×1706) and `android-small`
(720×1280) both qualify, below 1080. Nothing stops them; nothing recommends them.

### The set

The unit is not a screenshot. It is a **set** — one listing, one device class,
one locale, ordered — because that is what App Store Connect uploads and what
fastlane's folders are shaped like. Four dimensions collapse into one addressable
thing, and every screen in this design is a view over sets.

```dart
class StoreSet {
  final Listing listing;          // App Store | Play
  final StoreDeviceClass class_;  // iphone69 | ipad13 | phone | tablet10
  final String locale;            // the *store's* tag: 'en-US'
  final List<StoreShotImage> shots;
}
```

### Two locale vocabularies, kept apart

`en` is what the app takes. `en-US` is what the store takes. They are different
alphabets and conflating them is the mistake that will hurt in six months, when
a project ships `fr-CA` to a listing that only has `fr`. The declaration maps
one onto the other explicitly and neither is derived from the other.

## 2. The declaration

**Superseded in one respect, 2026-08-27.** `packages:` becomes `apps:` and a
package may carry several, so that a project shipping two products from one
codebase can say so — and so that each can name the store record it belongs
to. Everything below still holds; the entry is renamed and gains a `name` and
an identity per listing. See `2026-08-27-store-live-and-upload-design.md` §1.

Split by rate of change. The listing set — which stores, which locales, which
classes — moves about once a year, so it lives in `tool/flutterware.dart` with
every other plugin. The shots and their words move every release, so they live
in the scenario file, where they already are.

```dart
fw.use(
  StoreShots(
    packages: [
      StoreShotsPackage(
        example,
        // The source. A file, or a directory, exactly as `scenarios run`
        // takes one — the scenario is what drives the app to the screen.
        file: 'test/store/listing_test.dart',
        // The composition. A package-relative file exporting one StoreFrame.
        // Omitted, the built-in frame is used, which is a real design rather
        // than a placeholder — see §4.
        frame: 'tool/store/coffee_frame.dart',
        listings: [
          Listing.appStore(
            classes: [StoreDeviceClass.iphone69, StoreDeviceClass.ipad13],
            locales: {'en': 'en-US', 'fr': 'fr-FR'},
          ),
          Listing.play(
            classes: [StoreDeviceClass.phone, StoreDeviceClass.tablet10],
            locales: {'en': 'en-US', 'fr': 'fr-FR'},
          ),
        ],
      ),
    ],
  ),
);
```

`Listing` is sealed with a named constructor per store, following
`TranslationCatalog` and for its reason: one class with a `store:` field and the
union of both stores' options is a shape where half the fields are always wrong.
`AppStoreListing` knows 1320×2868 and 2048×2732; `PlayListing` knows 1080×2160
and 1600×2560, and that its output carries no alpha. Neither takes a size.

Also on the package, all optional: `tag:` (keep only shots carrying it, for a
project pulling one screen out of a product scenario), `output:`, `layout:`,
`clock:` (pin the status-bar time and any date on screen — a listing that
changes pixels every run is a listing nobody can diff).

### The words on a screenshot are not one thing

Two strings wear the word "caption" in this trade and they have nothing in
common but being text near a screenshot. Keeping them apart is the whole of this
section.

**A headline is pixels.** The marketing line above the phone — *Track every
order* — is painted into the image. **Neither store has a field for it.** It
cannot be edited after upload, a longer language overflows the band it was drawn
in, and it exists at all only because a frame drew it: an unframed set has no
headline in any sense. (Vendors report Apple began OCR-ing screenshot text in
mid-2025 and weighting it for search on the first three shots. That is vendor
observation rather than Apple documentation; it is why wording matters, and it
is not something to build on.)

**Alt text is metadata.** Google Play takes a real per-screenshot string —
"Include alt text with each screenshot… in 140 characters or less", their
example being *The transaction complete screen*. Structured, submitted, editable
after upload, carried by `fastlane supply`. Apple has no equivalent. See §11 for
why it is not in v1.

So the only one v1 has to place is the headline, and:

### flutterware has no opinion about where marketing copy lives

The shot's **name stays an identifier**. It makes the filename, it addresses the
step, it labels the node on the flow canvas. Marketing copy is display text a
non-engineer rewrites three times before launch. Tying them together means
renaming a headline moves an artifact path, and they change at different rates
for different reasons.

Nor does the headline come from us. The frame is project code rendering **inside
a real widget tree at the set's locale**, so the project's own
`AppLocalizations.of(context)`, generated l10n class, `Map`, or JSON file a
copywriter edits *already works there* with no machinery from flutterware. An
earlier draft of this spec resolved the shot's name through the translations
catalog; that invented a coupling to reach something the project could already
reach, and it failed outright for a project with no catalog.

What we hand the frame is what only we know: the image, the slug, the index, the
total, the locale, the device and the canvas. What words to draw is the frame's
business.

```dart
class CoffeeFrame extends StoreFrame {
  const CoffeeFrame(super.shot, {super.key});

  @override
  Widget build(BuildContext context) {
    // Ordinary l10n, because this is an ordinary widget in a localized tree.
    var l = AppLocalizations.of(context);
    var headline = switch (shot.slug) {
      'menu' => l.storeMenuHeadline,
      'drink' => l.storeDrinkHeadline,
      _ => '',
    };
    ...
  }
}
```

`Shot('menu', headline: …)` is the obvious sugar and is deliberately **not**
in v1: the frame can already do the job, and a second place to put the same
string is a second place for it to be stale. If consumers reach for it, it
costs one field.

The **filename** is the slug, numbered by position — `02-drink.png` — so it is
stable across locales and fastlane uploads in the order the names give.

## 3. Two passes, and why that matters

Capture and composition are two passes **inside one export**, and that is the
only place the split is visible. A person invokes `store export`; there is no
way to ask for either half.

The split still earns its keep on the inside. The capture pass runs the app in
a `flutter_tester` at the device's own pixel ratio; the composition pass draws
a frame around the result in a *second* tester, on a build directory of its own
— they have different sources and therefore different dills, and two
`TesterHost`s sharing one tear each other's (§10d). Keeping them apart is what
makes the frame an ordinary Flutter widget rather than something the scenario
harness has to know about.

**What it does not buy is a fast loop**, and an earlier draft of this document
claimed it did. It offered the second pass as a `store frame` action so a
changed headline would not re-run the app. Deleted — decision 13 — because a
frame is authored against `previews`, which renders one composition in about a
second, and because an export that reuses what is on disk can ship last week's
screenshots. The nine seconds it saved were not worth either.

## 4. The frame widget

```dart
/// What a frame is handed — everything only flutterware knows, and nothing
/// else. No headline: what words to draw is the frame's business, and it is an
/// ordinary widget in a localized tree, so it looks them up the way the app
/// does. See §2.
class StoreShot {
  final ImageProvider image;   // the app's own pixels
  final Size imageSize;        // logical size of the capture
  final String slug;
  final int index;             // 1-based
  final int total;
  final Locale locale;
  final Device device;
  final StoreCanvas canvas;
}

abstract class StoreFrame extends StatelessWidget {
  const StoreFrame(this.shot, {super.key});
  final StoreShot shot;
}
```

The declared `frame:` file exports one `StoreFrame` subclass; the harness
generator imports it the way the previews harness already imports a project's
entries. **The frame must fill the canvas opaquely** — it is drawn on an opaque
ground and encoded without an alpha channel, which is what Play requires and
what makes an unframed Apple set safe as well.

Everything a template DSL would have had to invent is already Flutter here: RTL
flipping happens because the locale is in the tree, dark variants because the
theme is, fonts because the harness loads the project's real ones. This is the
whole reason to make it a widget rather than a config format, and it is where
this differs from `fastlane frameit`, whose text layout is JSON and whose device
frames have to be shipped and maintained per device.

### The default frame

A project that declares no `frame:` gets `DefaultStoreFrame`, and it is a real
design, not a placeholder: the device body bleeding off the bottom edge, a solid
ground tinted from the app's seed colour, and a headline band at the top that is
**empty unless the project fills it** — `DefaultStoreFrame` takes an optional
`headline` builder, `(shot) => String?`, and draws nothing where it returns
null. A project with no copy still gets a composed, legal, good-looking set; one
with copy passes three lines. That composition is the standard one because it uses a
2868-pixel-tall canvas well and is hard to make ugly. The device body is
`FramedShot`'s — the same silhouette the flow canvas and previews draw, with the
fake status bar and home indicator already tinted by whatever
`SystemUiOverlayStyle` the app declared at capture time.

## 5. The output tree

fastlane is the only machine-readable consumer, so it is the default — and the
**file name** carries the display class wherever the directory cannot:

```
build/flutterware/store/
  <app>/                                 # 2026-08-27: always, even for one app
    ios/
      en-US/iphone-6-9-01-whole-menu.png # deliver infers the class from size,
      en-US/ipad-13-01-whole-menu.png    # so both classes share this directory
      fr-FR/...
    android/
      en-US/images/phoneScreenshots/01-store-whole-menu.png
      en-US/images/tenInchScreenshots/01-store-whole-menu.png
      fr-FR/...
```

`layout: StoreLayout.plain` writes `<listing>/<class>/<locale>/NN-slug.png`
instead, for a human copying files into a console by hand.

Two siblings sit beside those trees, and neither is read by an uploader:

```
build/flutterware/store/
  ios/ android/         the deliverable
  unframed/             the app's own pixels, where a frame replaced them
    play/phone/en-US/02-menu.png
  .store/manifest.json  what the panel reads
```

`unframed/` appears only for a set that was **composed** — decision 14 — so a
project with no frame gets nothing extra, and Play's phone gets its 1082×2402
original beside the 1080×2160 canvas that shipped. A sibling rather than a
child, because `deliver` and `supply` upload what they find in `ios/` and
`android/`.

The directory is emptied before writing, for the reason `_shots` empties its
own: a store tree is a statement about the app as it is now, and last release's
screenshot of a screen that no longer exists would ship beside this one.

**But an export replaces exactly what it produces**, and the scope of the
invocation is the scope of the deletion — one rule with three consequences:

| invocation | statement | emptied |
| --- | --- | --- |
| `--app` | one app's whole tree | that app's tree |
| un-narrowed | the whole tree | the whole tree |
| `--listing` / `--locale` / `--class` | one set | that set's images |
| `--shot` | one file | nothing |

The middle row is not a nicety. Wiping the root under `--listing=play` would
delete the App Store half of a listing in order to rewrite the Play half — and
`--output` pointing at somebody's `fastlane/metadata` would take their
description files with it. The set's *images* rather than its directory,
because fastlane's iOS tree shares one directory between two classes.

## 6. The UI

Rail entry **Store**, a sub-entry per app, master–detail — following the
launcher icon panel, which is the closest sibling and solved the same problem.
Per *app* since the 2026-08-27 document's §1, and always, including for one.

*Built 2026-09-22.* Until then the panel stacked every app's listings under a
title of `Store` and named the apps only once there were two, so a project with
one app saw *App Store* and *Google Play* with nothing saying whose. The panel
is now titled by the app, with the scenario file it runs under it, and Export,
its per-store entries and the locale switch are that app's.

### Content pane: the sets

A group header per listing; a card per device class; the shots in a row inside
it. The card's corner carries the canvas size and the store's cap — `1320 × 2868
· 4 of 10` — because the cap is a fact about the set, not a warning about it.

Locale is a **switch in the panel header**, not a fourth level of nesting.
Changing it changes every image on screen at once, which is what a switch is for;
nesting it turns four screenshots into sixteen rows.

**The panel is export-backed, and there is no source scan.** Decided
2026-08-26, against a draft of this section that had one.

The scan — the syntactic walk `scenarios list` already does for scenario names,
extended to shot names — bought exactly one thing: a skeleton of dashed
placeholders *before the first export*. After that first export the panel reads
what is on disk, which is better in every respect: real pixels, real order,
real names, real count. So the price was a parser that has to track **both**
naming spellings (`s.screen('Cart')` names a shot with a bare string, and every
verb also takes `shot: Shot('Cart')`), report non-literal names as diagnostics,
and stay in sync with the scenario API forever — and the purchase was a nicer
empty state. Miss one spelling and the skeleton is half a listing, which is
worse than no skeleton at all.

So the empty state is built properly instead, which is a page of layout rather
than a parser with a maintenance tail. See *The empty state* below.

### Looking closer: two dialogs, one question each

There is no detail *page*. There was one — a shot, drawn inside a listing with
itself outlined, over a "Full size" pane — and it answered neither question
cleanly. **A listing is a property of the set, not of a shot**, so the outline
was arbitrary and the page carried a selection it could not justify; and the
pane under it was the *second* question wearing the first one's clothes.

Split, each becomes obvious, and each is a dialog:

- **The shot** — *is this image right?* Click any thumbnail, anywhere. One
  image fitted to the window, arrows and ←/→ through the set, zoom past 1:1.
  Crop, clipped glyph, wrong locale.
- **The listing** — *does this set read?* From the card the set is on. The
  whole set in the arrangement, in order, no selection, with the placement
  chips: **Product page / Search result**.

Dialogs rather than pages also disposes of the navigation question the detail
page raised — no back stack, no route grammar, no stale key.

**Nothing invented on the stage.** It carried a star rating and an Install
button, and both are gone. Decision 4 said we draw the arrangement and never
the chrome; this is the other half of it. A fake `4.6 · 1.2K ratings` is a
*number*, and a number on a screen is read as a fact about the app. An Install
button invites the whole panel to be read as a preview of a real store page
rather than as a layout that shows a screenshot at the size a stranger meets
it. What remains is true: the name and the line under it are the package's own
pubspec, and the icon is a letter, which is plainly a placeholder rather than a
claim.

Panel thumbnails render at 1×; only the export pays for the device's real
ratio. The same split `captureScale` already makes.

### Header and staleness

Title, one summary line, locale switch, and a primary **Export** split button
top-right — the Translations panel's anatomy, which is already the house pattern
for "this panel produces a directory". The split menu holds *Export App Store*,
*Export Google Play*, *Recompose only*, *Reveal in Finder*, *Copy CLI command*.

The summary line carries the age of the last export and, when the captures are
older than the code they are of, says so as a fact — `exported 4 days ago · 12
files changed since` — beside a Re-export action, the way the Translations aside
carries its state inside the sentence. A fact, not a finding.

## 7. The actions

```sh
fw run store export        # everything the declaration says. No arguments.
fw run store open          # reveal the output
```

`export` taking no arguments is the requirement, not a nicety: the declaration
is the configuration, and an invocation that restates it is an invocation that
will drift from it. Overrides exist and are all *narrowing*, never
re-specification — `--listing=app-store`, `--locale=fr`, `--class=iphone-6-9`,
`--shot=02`, `--output=`, `--open`.

Two of those have a wrinkle worth stating.

`--shot` narrows **what is written, not what is run**: a scenario produces its
shots together or not at all, so on `export` it saves the composition and the
encoding, never the app. Its numbering does not move either — narrowing to
`02` writes `02-…`, and a frame drawing "2 of 4" still says 2 of 4, because the
position is the set's and not the invocation's. Matching is exact on the
position or on the name, never a prefix: `--shot=cart` silently taking both
`cart-empty` and `cart-full` is the shape of bug §10c already shipped once, and
a query matching nothing refuses rather than writing an empty set.

`--output` is the one argument that is not narrowing, and it earns its place by
changing nothing about *what* the deliverable is — only where it lands. The
captures stay under the declared output, so `export --output=…` followed by a
plain `frame` still finds its inputs.

Over MCP the same three, plus the panel projection through `flutterware_status`
so an agent can read the sets without running anything.

`scenarios shots` stays exactly as it is: the lane for a project that has not
declared a listing, and the machinery this plugin's pass one calls.

## 8. The demos

Three, and they are different things.

1. **`app/tool/catalog/demos/store_listing.dart`** — the stage, as a catalog
   entry, fed synthesised bytes. Both listing chromes, both crops, both
   brightnesses, framed and unframed. This is how the stage gets built and
   looked at, per the repo's rule that you render a widget rather than build a
   harness for it.
2. **`DefaultStoreFrame`, previewable on its own.** A `@Preview` entry at
   1320×2868 and at 1080×2160, so the two canvases that differ most are both
   one command away.
3. **The coffee shop's listing in `examples/example`.** `lib/shop/` is already a
   four-beat story — menu → drink → cart → confirmation — and already translated
   to French. A store scenario over it produces the end-to-end proof, and the
   French set demonstrates the thing no mockup can fake: the app inside the
   frame is in French, laid out for French, with French text lengths. Its frame
   looks its headlines up the way any project would — a `switch` on
   `shot.slug` over the shop's own strings — so the demo also documents the
   answer to *where does the copy go*, by being the only answer there is.

Demo 3 is also the honest test of the whole design. If the coffee shop's listing
does not look like something a real app would ship, the frame is wrong and we
will see it before a consumer does.

## 9. Testing

- **Canvas arithmetic**, pure Dart: every declared class resolves to its store's
  exact pixels, and every Play canvas is inside 320..3840 and under 2:1. Not a
  runtime check — a test, so a future edit to the numbers cannot ship.
- **Encoding**: the written files carry no alpha channel. One assertion over the
  PNG header, and it covers the single most likely silent upload failure.
- **The scan**: both spellings — `s.screen('Cart')` and `shot: Shot('Cart')` —
  are found, in order; a non-literal name is reported rather than dropped.
- **Two passes**: `frame` after `export` re-reads the captures and does not
  re-run the suite — assert on the tester's spawn count, since the whole point
  is the absence of a run.
- **The stage and the frame** are Views, so they are widget tests over
  synthesised bytes, plus the catalog demos for looking.

## 10. Phases

1. **Pass one, honestly.** `pixels: named`, declare `orientations`, opaque
   encoding. Small, and one of them is a live upload bug in `scenarios shots`
   today.
2. **The model and the declaration.** `StoreShots`, `Listing`, `StoreSet`,
   canvases, locale mapping. Apple works end to end at the close of this phase,
   unframed, because its canvases are native.
3. **The frame.** `StoreFrame`, the second pass, `DefaultStoreFrame`, its
   previews. Play works at the close of this phase.
4. **The output tree.** fastlane layouts, `plain`, `open`.
5. **The panel.** Scan-populated strip, sets, export button, staleness.
6. **The stage.** Catalog demo first, then wired to the real captures.
7. **The coffee shop listing**, and a screenshot of it in the README.

Phases 1–4 are the CLI feature entire; a project could ship a listing from them
with no GUI at all. 5–7 are what makes it worth opening.

## 10a. The seams, named

Reconnaissance done 2026-08-26 against the tree, so the plan below names files
that exist rather than files that ought to.

### Which half is published

The same split `lib/src/scenarios/` has, and it decides where every type goes.

- **`lib/` is API.** `StoreShots`, `Listing`, `StoreDeviceClass`, `StoreCanvas`
  and `StoreLayout` go in `lib/src/plugins/first_party.dart` beside `Scenarios`
  and `Translations` — **pure Dart, no Flutter import**, because
  `tool/flutterware.dart` runs under a plain `dart run` (the library's own
  header says so). They ride out through `lib/plugins.dart`, which already
  exports that file: no new export line.
- **`StoreShot` and `StoreFrame` import Flutter**, so they cannot live there. A
  project *subclasses* `StoreFrame`, which makes it published surface of the
  same weight as `lib/flutter_test.dart` — a new `lib/store.dart` over
  `lib/src/store/frame.dart`, and changing it afterwards changes what consumers
  compile against.
- **`app/` is free.** Everything below it can move.

### The plugin quartet

Every native plugin is four files plus two registrations, and the smallest one
to copy is splash:

| new file | modelled on |
|---|---|
| `app/lib/src/plugins/native/store_core.dart` | `splash_core.dart` — `const storePluginId = 'flutterware.store'`, `StoreCore extends PluginCore`, `storeCoreFactory` |
| `app/lib/src/plugins/native/store_plugin.dart` | `splash_plugin.dart` — `NativePlugin<StoreCore>`, `buildPanel` and nothing else |
| `app/lib/src/plugins/native/store_results.dart` (+ `.g.dart`) | `scenarios_results.dart` — `StoreExportResult`, `StoreSet`, `StoreShotImage` |
| `app/lib/src/plugins/native/store_address.dart` | `splash_address.dart` — `?listing=`, `?class=`, `?locale=`, `?shot=` |

Two registrations, and the panel registry's own comment warns that missing
either gets a visible `MissingPlugin`:

- `app/lib/src/plugins/native/registry.dart` → `storePluginId: panelFor<StoreCore>(StorePlugin.new)`
- `app/lib/src/session/session.dart:593` `defaultCoreRegistry()` → `storePluginId: storeCoreFactory`

Then `fvm dart app/tool/generate_capabilities.dart`, which writes both
`app/lib/src/session/action_shapes.generated.dart` and `docs/capabilities.md`;
`app/test/session/action_shapes_test.dart` fails until it is run.

### Pass one, inside scenarios

- `lib/src/scenarios/pixels.dart` — add `named` to `ScenarioPixels`, doc'd like
  `keyed` is.
- `lib/src/scenarios/harness.dart` — honour it where `keyed` is honoured.
- `app/lib/src/scenarios/runner.dart:232` already takes `pixels` and forwards it
  at 259; nothing to add.
- `app/lib/src/plugins/native/scenarios_core.dart` `_shots` (~2237) — pass
  `pixels: ScenarioPixels.named`, and declare the `orientations` parameter in
  the action at ~1351, which `_shots` reads today and no caller can pass.
- Opaque encoding: `lib/src/scenarios/scenario.dart:2199` is the one
  `toByteData(format: png)`. The store lane composites onto an opaque ground
  before encoding rather than changing that call, so the debugging lane keeps
  its alpha.

### Pass two, and how the frame gets imported

Exactly the problem `generateHarnessEntrypoint`
(`app/lib/src/scenarios/harness_entrypoint.dart`) already solves: the declared
`frame:` file sits outside `lib/`, so it has no `package:` URI and the generated
entrypoint imports it **relative to its own directory**. Add a `frame:`
parameter to that generator and a `framePass` mode to the harness that pumps
`StoreFrame` over a decoded capture at canvas size — a `MemoryImage` and a
`pumpWidget`, no navigation.

`app/lib/src/scenarios/framed_shot.dart` is where `DefaultStoreFrame` gets the
device body from; it already draws the silhouette, the fake status bar and the
home indicator tinted by the app's declared `SystemUiOverlayStyle`. It is a GUI
file today and the frame is published, so the shared part moves down to
`lib/src/store/` and `framed_shot.dart` reads it from there.

### The panel

`app/lib/src/store/` mirroring `app/lib/src/launcher_icon/`: `screen.dart`
(master–detail), `model/`, and `ui/set_card.dart` + `ui/stage.dart`. Both `ui/`
widgets are **Views** — data and an `ImageProvider` in, pixels out, no
filesystem — which is what lets `app/tool/catalog/demos/store_listing.dart`
drive every surface with synthesised bytes.

The rail's own ordering puts Store beside Splash screen and Launcher icon.

### The demo project

- `examples/example/test/store/listing_test.dart` — the four-beat scenario over
  `lib/shop/`.
- `examples/example/tool/store/coffee_frame.dart` — the frame, looking its
  headlines up from the shop's own strings.
- `tool/flutterware.dart` — one `fw.use(StoreShots(...))` block declaring it,
  which is also the worked example every doc quotes.
- `tool/screenshots.dart` — one more shot, per its "one shot per feature" rule,
  so the README carries the panel.

### Tests, by the file they go in

- `test/store/canvas_test.dart` (root package, pure Dart) — every class resolves
  to its store's exact pixels; every Play canvas is within 320..3840 and under
  2:1.
- `app/test/store/export_test.dart` — the output tree, both layouts; the written
  PNGs carry no alpha; `frame` after `export` spawns no tester.
- `app/test/store/scan_test.dart` — both naming spellings found, in order; a
  non-literal reported.
- `app/test/store/stage_test.dart` — the two Views over synthesised bytes.

Root-package tests run with `fvm flutter test`, not `dart test`.

## 10b. Phase 1, built (2026-08-26)

`pixels: named`, the `orientations` parameter, and opaque output — all three
inside `scenarios shots`, which improve that action whether or not the rest of
this document is ever built.

### The measurement

`test/scenarios/mobile/shop_test.dart` in `examples/example`, staged as
`iphone-16-pro-max` at `capture-scale: 3` — a 6.9" iPhone at its own ratio,
which is what a store run is:

| | `pixels: all` | `pixels: named` |
|---|---|---|
| harness run | 3540 / 3528 ms | 2575 / 2571 ms |
| pictures written | 26 | 15 |
| bytes on disk | 5.6 MB | 3.8 MB |

**27% off the run**, repeatable across alternating passes, for eleven pictures
that `shots` rendered at 1320×2868, encoded, wrote, and then deleted with the
scratch directory. The proportion is a property of the suite — a scenario that
names every shot saves nothing — but the *shape* is not: this is the only mode
whose cost is spent entirely on files nobody will open.

### The trap it turned up

`screen()` **adopts**: where nothing has moved, a name lands on the capture
before it rather than taking a second picture, and 86% of named steps were that
duplicate. Under this mode the capture a name would land on is unnamed by
definition, which is exactly the one skipped — so every named shot would have
adopted an empty frame and the export would have written nothing, silently and
greenly.

The refusal went into `_adoptablePending`, whose doc already promised that "a
refusal added here binds both" adoption paths, and it is narrowed to this mode
alone. The argument for the narrowing is what makes it safe: **every other mode
decides from the screen, and adoption only happens where the screen has not
moved**, so a held capture and the shot adopting it agree by construction. This
one decides from the step. `test/scenarios/named_pixels_test.dart` holds the
control group — the same script under `all` still folds two captures into one.

### And a correction to this document

Shots are named **two** ways: `s.screen('Cart')` with a bare string, and
`shot: Shot('Cart')` on any verb — which is how the example suite names most of
its own. §6's scan claim originally covered only the second. Nothing in phase 1
depends on it, since the runtime reads a `Shot` object either way; the *scan*
that draws the panel's skeleton does, and it would have shipped finding half the
shots.

### Also

`pixels: named` is exposed on the `run` action too, not only used internally by
`shots` — the mode is worth reaching for by hand when a store run's output is
the thing under suspicion, and a harness that accepts a word the action rejects
is a seam nobody can debug across.

## 10c. Phase 2, built (2026-08-26)

The model, the declaration, the plugin, and `store export` writing Apple's two
required sets end to end.

`lib/src/plugins/store.dart` is the published half and it is where decision 1
actually lives: `AppStoreClass` and `PlayClass` are **two enums**, so an App
Store listing naming a Play device class does not compile. There is no
validator anywhere in the plugin because there is nothing a declaration can say
that would need one.

`test/store/canvas_test.dart` is the load-bearing test — it asserts every number
this can produce, including that no Play canvas is outside 320..3840, past 2:1,
or under the 1080 short side. It also guards the coincidence the whole Apple
lane rests on: `iphone-16-pro-max` and `ipad-pro-13` land on Apple's two
required sizes exactly, and nothing but this test makes the device table promise
that.

Measured on `examples/example`: six sets, **90 images**, all opaque, at
1320×2868, 2048×2732 and 1600×2560. Play's phone comes back as a `deferred`
entry naming its own reason, which is §1's argument arriving as output rather
than as prose.

### The bug the counts hid

The first green export reported thirty iOS images and had written fifteen.
fastlane's iOS tree gives every display class **one directory per locale** —
`deliver` reads the class off the image's dimensions rather than off where it
sits — so `ios/en-US/01-welcome.png` was written by the iPhone set and then
overwritten by the iPad set. Nothing errored. The result was green, the count
was right, and the listing was half missing and entirely iPad.

The fix is the file name (`iphone-6-9-01-welcome.png`), but the lesson is the
test: `app/lib/src/store/tree.dart` is now pure — layout, target and locale in,
a path out — and `app/test/store/tree_test.dart` asserts the property rather
than the paths. **No two images of one export share a path**, over every layout,
for a listing shaped exactly like the one that collided. A count cannot catch
this and neither can an eye.

### Two seams that were not what the plan said

- **`run.json` is written by the scenarios core's pipeline, not by the runner.**
  §10a's plan to read a store run back through the published
  `ScenarioRunReport.read` therefore could not work — there is no file. The
  published *types* do the job instead: a runner's raw report is already the
  shape `ScenarioRunOutcome.fromJson` reads, so nothing is reimplemented and
  nothing is kept in sync.
- **The store runner gets a build directory of its own**
  (`build/flutterware/store_harness`), not the scenarios panel's. Two
  `TesterHost`s on one build directory tear each other's dill, which the
  comparison lane already paid for. A store export is deliberate and occasional,
  so a compile of its own is the right side of that trade.

### And a panel, deliberately plain

`store_plugin.dart` lists the declared sets and offers Export. The real panel is
phase 5. A core registered with no panel renders "this build does not have it",
which would be false, and a false sentence is worse than a plain surface.

## 10d. Phase 3, built (2026-08-26)

The frame. `lib/store.dart` over `lib/src/store/frame.dart` is published API —
`StoreShot`, `StoreFrame`, `DefaultStoreFrame`, `StoreFrameStage`. A second
tester program composes with it, `.captures/` survives an export, and
`store frame` recomposes without running the app. Play's phone is exported
rather than deferred.

### Three things the plan got wrong

- **The device body is drawn, not borrowed.** §10a planned to move `FramedShot`
  down out of `app/` so the frame could use it. It cannot: the hand-drawn bodies
  need `flutter_svg`, and the published package does not get a dependency so
  that a *default* can have artwork. `DefaultStoreFrame` draws a rounded body of
  its own — which is what most listings ship anyway, and Apple's guidance is
  against a device frame that is not the device.
- **The frame pass is its own program, not the capture pass's process.** One of
  the two decisions taken without asking, reversed by the compiler: the two
  passes have different sources and therefore different dills, so they are two
  `TesterHost`s on two build directories. That is also what makes `store frame`
  cheap to reach — it never touches the scenario harness at all.
- **`generateStoreFrameEntrypoint` had to move out of the harness.** `fw` links
  the tool half and runs under a bare `dart run` with no `dart:ui`, so one
  import reaching into a Flutter file drags the framework into a program that
  cannot have it, and every Flutter source in the graph fails at once. It lives
  in a pure-Dart `frame_entrypoint.dart` now. The guardrail `tester_host.dart`
  documents caught this within a minute of writing it.

### What rendering it caught that reasoning would not

The frame was previewed before it was wired to anything —
`app/tool/catalog/demos/store_frame.dart`, over a painted stand-in for a capture
— and the first Play render showed **`9:41` reading as `41`**. The fake status
bar sits inside the body's rounded corner, and an Android's 24-point inset
against a 44-point radius loses its first two characters. An iPhone's 59-point
inset hides the problem completely. Solved rather than padded past: at height
*y* down from the top, a corner of radius *r* intrudes `r − √(r² − (r − y)²)`
horizontally, measured at the bar's vertical centre.

The second render caught the other one: with no headline the band still took a
sixth of the canvas, and the device floated below it looking like a mistake. A
set with no headlines anywhere is exactly what a project declaring no frame
gets, so the band is now laid out only when there are words for it.

### The promise, kept and asserted

Decision 7 required Apple's output not to change. `store export` and then
`store frame` over the whole listing — 8 sets, 120 images — hash **identically**
(`9e114aa7…`), which also makes the composition deterministic. And
`storeShouldCompose` is a pure rule in `tree.dart` with the promise written as a
test, because *by construction* is what would have been said about the filename
collision §10c shipped.

### The measurement, and where it went

The first build took **88 s** to export and **61 s** to recompose 120 images,
which is not what anybody expects of composing pictures that already exist. It
was worth finding out why rather than filing it as the cost of doing business,
and the answer was in none of the places this document guessed.

Per image, on a 2048×2732 capture:

| step | before | after |
|---|---|---|
| `img.decodePng` | 140 ms | 140 ms |
| `img.compositeImage` over an opaque ground | **481 ms** | — |
| RGBA→RGB byte copy, alpha checked in the same pass | — | **16 ms** |
| `img.encodePng` | 89 ms | 89 ms |
| **total** | **719 ms** | **250 ms** |

A capture is RGBA because `Image.toByteData(format: png)` gives no other shape,
**not because anything in it is transparent** — an app paints its background. So
every one of those 481 ms was per-pixel alpha blending against an alpha of 255.
Detecting that costs 3 ms over 5.6M pixels with a typed-list scan, and it rides
along in the copy loop, so nothing is paid to find out which case you are in. A
genuinely transparent pixel still falls through to the blend rather than losing
what is under it.

| | before | after |
|---|---|---|
| `store export` — capture and render, 120 images | 88 s | **~48 s** |
| `store frame` — render only, warm | 61 s | **22 s** |
| 30 unframed images | 18.4 s | 6.2 s |
| 15 framed + 15 unframed | 13.7 s | 5.5 s |

And byte-identical output either way — the whole listing still hashes
`9e114aa7…`, which is what makes this an optimisation rather than a change.

**On the remaining 183 ms an image**, which is `package:image`'s PNG decode plus
encode and nothing else: 120 images is not a listing. Apple caps a set at ten,
and the demo's fifteen are a *test suite* being read as one. A real listing —
five shots across eight sets, forty images — lands near **7 s** at this rate.

The lever left, if a listing ever wants it: `.captures/` holds PNGs, so every
render decodes one. `scenarios run` can already capture `format: raw`, which
would remove the decode *and* the capture's own encode, taking an image to about
95 ms. It costs 80–160× the bytes on disk for a directory that is deliberately
kept, which is why it is a lever and not the default.

### A claim this document withdraws

§3 said a recompose was "seconds where a re-run is a minute". Even at 22 s that
is generous, and the shape of the saving is not what was claimed: the render is
most of the work either way, so what the split buys is the capture pass, about
half. The loop is worth having and the architecture is right; the number was
wishful.

## 10e. Phase 4, built (2026-08-26)

The output tree, which was three quarters done before it started: both layouts
landed in phase 2 because the export needed somewhere to put things. What phase
4 actually added is the edge — `open`, `--class`, `--shot`, `--output`,
`--open` — and one rule that turned out to matter more than any of them.

### The bug the narrowing arguments exposed

`export --listing=play` deleted the whole output tree and then wrote the Play
half of it. The App Store half — thirty images, four minutes of tester time —
was gone, silently, in an invocation that said *play*. It had been that way
since phase 2 and nothing caught it, because until this phase there was no
argument that could narrow an export and so no way to notice.

The fix is §5's table: an export replaces exactly what it produces. Which also
answered the `--output` question before it was asked, since a redirect into
somebody's `fastlane/metadata` would otherwise have taken their description
files with it. Verified by planting one: a full redirected recompose wrote
eight sets around a `full_description.txt` and left it alone.

The set-scoped sweep removes the set's **images**, not its directory, and
fastlane's iOS tree is the reason. Both classes live in `ios/<locale>/`, so a
directory delete under `--class=iphone-6-9` would take the iPad set with it.
Planted a stale file of each class and ran the narrowed recompose: the iPhone
one was swept, the iPad one survived.

### What `--shot` narrows

Not what is run — a scenario produces its shots together or not at all — so on
`export` it saves the composition and the encoding and never the app. The
numbering does not move either, because the position belongs to the set: the
filter is a `continue` over the full enumeration, so shot 2 is still written
`02-…` and a frame drawing "2 of 4" still says 2 of 4.

Matching is exact on the position or the name. `--shot=cart` taking both
`cart-empty` and `cart-full` would be the filename collision again in a
different costume — a narrowing argument quietly doing more than it says — and
a query that matches nothing refuses rather than writing empty sets, which is
the same reason.

### Three small things

- **`open` spawns the platform opener** rather than reaching for
  `url_launcher`, because the core runs under `fw` too and the CLI has no
  Flutter. Exit code ignored: `explorer` reports 1 on success, and a desktop
  with no opener installed is not a failed export.
- **`--output` resolves against the worktree**, not the package. A path typed
  on a command line means what it means in the shell that typed it.
- **The `class` choice offers what the project declares**, not both stores'
  vocabularies, so the option list is a fact about this listing.

## 10f. Phase 5, built (2026-08-26)

The panel. `StoreManifest` in `.captures/manifest.json` is what an export
leaves behind for it to read, and `store_plugin.dart` is one layout with two
data states rather than a full screen and an empty one.

### Two truths, from different places

The **structure** is the declaration — which listings, which classes, which
locales, what canvas each is — and it is in hand with no I/O. The **pixels**
are the manifest. The panel walks the first and looks each set up in the
second.

That direction is what makes decision 11 cheap rather than a compromise. A card
with no export still knows its canvas, its device, its locale and whether it
will be composed; the only thing the scan would have added is *how many shots*,
which is why the placeholders fade rightwards instead of being a definite
number. And nothing has to reconcile the two: a manifest entry for a set nobody
declares any more is simply never looked at.

The empty card draws ghost canvases at the set's real aspect ratio, filling the
strip. Four cards on one screen then show a 1:2 Play phone above a 3:4 iPad,
which is §1's canvas-is-not-a-device argument made without a word of it.

### The manifest merges, for the same reason the disk does

`export --listing=play` must not erase the panel's knowledge of the App Store
half, exactly as it must not delete those files. So an export merges its sets
into the file by key and leaves the rest. The key is the **app** locale, not
the store slot: two app locales can map to one slot, and they are two sets.

The images an entry records are read back **from the directory**, not from what
the invocation wrote. Under `--shot` those differ — one file rewritten, fifteen
on disk — and recording the invocation's work would have the panel draw a
listing of one screenshot.

### Two bugs it turned up

- **`frame` swept nothing.** The tree wipe sat inside `if (capture)`, so an
  un-narrowed recompose left every stale file where it was. It cannot simply
  move out: the captures live *inside* the output, so a tree wipe on `frame`
  would delete its own input. A tree wipe is now export-only and `frame` is
  per-set, which is also the honest scope — recomposing is a statement about
  the sets it recomposes. Caught by a planted sentinel from §10e surviving into
  the manifest as a sixteenth image.
- **The panel would have cached the manifest forever.** `fw run store export`
  in a terminal beside the open studio is the ordinary case, and a cache keyed
  on the panel's own actions would have shown yesterday's listing with nothing
  to say it was stale. Keyed on the file's mtime instead: a `stat` per rebuild.

### What is deliberately not here

The staleness clause §6 sketched — *12 files changed since* — needs a source
walk to answer and would be the scan by another name. The age alone (`exported
4 days ago`) is what the manifest can say truthfully, so that is what the
header says.

The detail pane is phase 6. A card's shots are a strip today; the arrangement
that answers *is this listing any good* is the stage.

## 10g. Looking at the panel, 2026-08-26

Nine notes from the first real look. Six were fixed; three are decisions and
sit in §12.

### The markings meant nothing

The corner read `1320×2868 · 15 of 10 · en-US` in amber, and shots past the
tenth were dimmed. Every part of that was a riddle: two numbers with no unit,
a colour warning about something the card never named, and dimming that read as
a rendering fault.

The rule this settles: **a marking that is not a screenshot has to say what it
means where it means it.** So the corner is neutral and unabbreviated —
`1320 × 2868 px · en-US · 15 shots` — and the cap is stated in words, once,
under the strip, and only when it bites: *Only the first 10 are published — App
Store's limit per display class.* Each thumbnail carries its file name on
hover, and a dimmed one says why.

Flat and short on purpose. The first version of that line narrated itself —
*Shots 11–15 are dimmed: … so only the first 10 will appear in the listing* —
which explains the interface to the reader instead of stating the fact. A
program says the fact.

That is not a validator returning by the back door. It is arithmetic against a
published limit, and it is the one thing on the card that changes what ships.

### The locale control, and three helpings of the same space

The header looked empty because it was padded three times: `FwPanelHeader`
applies the gutter and its own top inset, the panel's `ListView` applied both
again, the locale switch added a top pad on top of the header's own gap. Header
pinned outside the list now, which also fixes losing it on scroll.

### A shared component was eating its own border

`FwSplitButton` drew a rounded outline with square corners poking out of it.
`Container` paints `decoration` **behind** the child and `Border.all` strokes
inside the clip path, so the segments' opaque fill covered the border. Moved to
`foregroundDecoration`. Photographed at 6.9" before and after rather than
reasoned about — the artifact is a few pixels and invisible at 1×. Fixes every
use of the control, not just this panel.

### Progress, and the freeze underneath it

Asked for a progress bar; found the reason there could not be one.
`flattenPng` is a synchronous PNG decode-and-encode on the calling isolate,
~250ms per store canvas. Inline, a full export is half a minute in which **no
frame paints** — a bar cannot move, cards cannot fill, and the window is
genuinely wedged. `flattenPngFile` runs it in an isolate, four at a time, and
reads and writes the file *inside* so two paths cross the boundary instead of
two copies of a 5MB image. Output byte-identical; the export also fell from
~48s to ~26s, because four cores now do what one did.

With that clear: the export interleaves capture and render **per set** and
writes the manifest after each one, so cards fill in as their set lands rather
than all at once at the end. The narration is a field on the core plus
`notifyChanged`, which means the same line reaches the panel, the rail, `fw
run` and an MCP client.

Two bugs it exposed:

- **The panel read the core without subscribing to it.** The rail's status line
  moved through a whole export while the panel below sat on the line it had
  built with. `ListenableBuilder` on the plugin — the house pattern.
- **A card matched itself by rendered label.** `working.contains(target.label)`
  put a spinner on Play's *Phone* card every time the *iPhone 6.9"* set ran,
  because one label is a substring of the other. Progress now carries the
  `store/class/appLocale` key the manifest already uses. The general form: a
  display string is not an identifier, and comparing one is a bug waiting for
  the right pair of names.

## 10h. Phase 6, built (2026-08-26)

The stage and the detail page. `StoreStage` and `StoreShotDetail` are Views —
plain data and files in, no core — which is what let both be built and stressed
in `app/tool/catalog/demos/store_stage.dart` before either had an export behind
it.

### §12.1 settled: one arrangement, not one per store

Two chromes would have been two invented layouts to keep current, and — since
decision 4 forbids copying either store's styling — they would have been two of
*our* designs wearing different labels. What genuinely differs, and what a
person needs, is **how many shots are visible and how much of each**. That is
`StorePlacement`: a product page gives a shot its full height, a search result
gives a band off the top, and the question *do my first three carry the
listing* becomes something on screen rather than ASO folklore.

### The carousel is sized by width, not by height

It was a fixed shot height first, and a wide pane then fitted six of a tall
phone's shots — at which point the arrangement was a gallery and the whole
reading ("three, and a hint of more") was gone. Driving the width from the pane
and taking 3.35 shots across means the first three always are the first three,
and a 3:4 tablet simply comes out shorter than a 1:2 phone, which is true.

The row scrolls so the selected shot sits **second**. Both readings matter: a
listing opens at its first shot, so a detail about shot 1 or 2 shows the head
of the carousel (the offset floors at zero), and a detail about shot 6 is
asking how it reads beside its neighbours.

### Full size is the fullscreen view

A zoomable canvas at 1:1, and it answers a different question from the stage —
*is this image right* rather than *does this shot do its job*. A clipped glyph
or a wrong crop is visible there and nowhere else.

### A title is not a file name

The first title the detail ever drew was **`9 02 menu`**, from
`iphone-6-9-02-menu.png`. The class id ends in a number, so the string has
three plausible numbers in it and no reader can tell which is the shot's
position. `storeTitleOf` lives in `tree.dart` — the only file that knows the
class prefix is a prefix — and is asserted to round-trip whatever
`storeFileNameFor` wrote, over every layout and every target.

The general form is the same one the label-matching bug had in §10g: a string
built by a rule can only be taken apart by that rule.

### What the stage puts beside the shot

The package's own pubspec name and description, read once in the core and
cached. Not a new declaration: a listing's real name and subtitle live in a
store console and are not ours to hold. What the stage needs is something true
and roughly the right length, so a screenshot is judged beside a name rather
than beside a placeholder.

The icon is a letter in a rounded square. A real one lives in the launcher icon
plugin, and reaching across plugins for it is a coupling this does not need
yet.

### And the second pass left the menu

Not part of phase 6, but decided looking at it: *Re-frame existing screenshots*
is gone from the split menu — decision 13. What is left is four entries, all
about exporting or about the output, and no headers, because the division the
headers explained no longer exists.

### Not addressed yet

The open shot is panel state, not a route. An address would survive a reload
and be linkable and is the right end state — but it is a second design (route
grammar, back stack, what a stale key does), and the detail should earn its
keep first.

## 10i. The framing, designed 2026-08-26

Phase 7's demo has to be *good*, not merely correct, and the two patterns worth
having are the two `frameit` cannot do.

**Checked, not assumed:** `fastlane frameit` frames a screenshot straight-on and
takes an orientation — `:portrait`, `:landscape_left`, `:landscape_right`. There
is no tilt, no perspective, and nothing that spans more than one screenshot.
That is not a criticism of it; it composites images, and neither is expressible
that way.

**Ours is a widget**, and both fall out of that.

### The tilt

A `Transform` with a perspective entry on the matrix, rotated a few degrees
about Y, is the whole of it — the device body, its shadow and the app's pixels
all tilt together because they are one subtree. `DefaultStoreFrame` gains it as
an **option**, off by default: the default frame stays plain, per its own doc
comment, and a tilt is a style choice a project makes rather than one we make
for it.

### The panorama, which is the interesting one

A listing where one background continues across the screenshots — the device in
shot 2 sitting to the right of the device in shot 1, over a scene that runs the
width of all five. It is a common and expensive-looking pattern, and it is
normally hand-composited in a design tool because no screenshot pipeline can
express it.

A frame already knows `shot.index` and `shot.total`. So a background drawn at
`total` canvases wide and translated by `-index × canvasWidth` **is** a
panorama, in about four lines, with every shot still rendered independently.
Nothing in the pipeline changes: it is one widget reading two integers it is
already handed.

That makes it the demo. The coffee shop listing gets a panorama with a tilted
device, and the point it proves is not that flutterware can draw — it is that
**a composition is a widget**, so the ceiling is Flutter's rather than a
template format's.

### What this costs

Nothing structural. `StoreShot` already carries `index`, `total`, `canvas` and
`device`; `DefaultStoreFrame` gains one optional parameter. The demo frame is a
file in `examples/example`.

## 10j. Phase 7, built (2026-08-26)

The coffee shop's listing, its own frame, and a README that shows what the
frame being a widget actually buys.

### The primitive that was missing, and it was not the obvious one

A background that merely *continues* needs nothing new: `index`, `total` and
`canvas` were already there, so [`StoreShot.panoramaWidth`] and
[`panoramaOffset`] are arithmetic over what a frame is handed.

A device body that **crosses** a boundary is different. The frame drawing shot
2 has to paint part of shot 1's phone — with shot 1's real pixels in it, or the
join is a grey rectangle. So `StoreShot` gains `set`: every image of the set,
in order, lazily, so a frame that ignores it pays nothing.

And the harness had a second gap that only showed up here. It precached
**one** image — `precacheImage(shot.image, …find.byType(Image))`, singular,
correct only while a frame could paint exactly one picture. Under FakeAsync
anything else captures as a hole. It now precaches every `Image` the frame
actually placed, asked of the tree rather than of the job, so the cost still
follows what was drawn.

### Two bugs the preview caught that reasoning would not

- **`StackFit.expand` clamps a panorama to one canvas.** A non-positioned child
  of such a stack is forced to the stack's size, so a `SizedBox` asking for
  five canvases of width silently got one and every shot but the first
  translated an empty strip off its own edge. It renders exactly like a frame
  that forgot to draw. The doc comment on `panoramaOffset` had the same bug in
  its example; both are `Positioned` now.
- **A device that fits inside its canvas never crosses anything.** At 68% of
  the canvas width the listing was five separate pictures sharing a background
  — the panorama was there and the crossing was not. At 104% they crossed and
  read as slabs. 86% with a small stagger is a phone whose shoulder arrives on
  the next screenshot.

Neither is visible in source. Both took one `previews screenshot` of the *whole
listing* — which is why that preview draws five canvases side by side: a frame
that looks right alone can still restart its scene at every boundary, and one
canvas would never show it.

### The headlines

A `store` catalog of its own — `assets/store/*.json`, declared beside the
shop's in `tool/flutterware.dart`, which is decision 9 taken up. Read off disk
synchronously, because a frame's `build` cannot await and a composition that
resolved its words a frame late would be captured before they arrived.

Five headlines against a fifteen-shot suite, and the frame draws no band where
there is none. That is the honest shape: a set is usually longer than the copy
written for it.

### What it costs a project

`frame: 'lib/store_frame.dart'` in the declaration. Everything else in that
file is the project's own — which is the point decision 6 made and this is the
first thing to prove it.

## 11. Not v1, and why

- **Uploading**, and the reconnaissance behind that is worth recording because
  it also settles why §5's default is not an arbitrary pick.

  Neither store has a publishing CLI worth targeting. Apple has **Transporter**
  (`iTMSTransporter`, shipped inside Xcode), which eats an `.itmsp` package —
  ~~the closest thing either store has to a listing *format*~~, and which
  Apple's own guide now says is deprecated for delivering apps and
  **unsupported for updating app content**, leaving it to books, music and
  video — and the **App Store Connect API**, whose screenshot path
  is a reservation dance: create an `appScreenshotSet` for a
  `screenshotDisplayType` under an `appStoreVersionLocalization`, reserve an
  `appScreenshot`, `PUT` the bytes to the upload operations it returns, commit
  with the MD5. Google has **no official CLI at all** — not in `gcloud`, not
  anywhere — only the Play Developer API v3, which is transactional:
  `edits.insert` → `edits.images.upload` → `edits.commit`.

  fastlane is a client of both. `deliver` speaks the App Store Connect API and
  matches each screenshot to a display family **by the image's own
  dimensions**, then replaces the set on the editable version — which is the
  mechanism behind the collision §10c hit, and the reason our filename carries
  the class. `supply` speaks the Play API, and its directory names
  (`phoneScreenshots`, `sevenInchScreenshots`, `tenInchScreenshots`) *are*
  Google's own `AppImageType` enum values spelled on disk.

  So there is no cross-store standard and no format standard on either side.
  The fastlane tree is the de-facto one, and it is de-facto for a better reason
  than habit: half of it is literally the API's vocabulary. Targeting it is
  targeting the only thing there is to target.

  **Uploading is v2, not never** — decided 2026-08-26, reversing what this
  section first argued. The argument here was that pushing the tree buys a
  store-state model on each side against a tool Google already maintains. The
  answer to it is that both APIs are plain REST and have been written in Dart
  before, so the model is a known quantity rather than an open-ended one; that
  a project doing this from flutterware and not from a Ruby toolchain it
  otherwise has no use for is the actual consolidation on offer; and that the
  entry points are the ones every other plugin already has, CLI and GUI.

  ~~`.itmsp` is in scope with it — it is the one listing *format* either store
  has, and writing it is a sibling of writing the tree rather than a new kind
  of work.~~ **Wrong, and struck 2026-08-27.** There is no listing format on
  either side; the fastlane tree above is the whole of what can be targeted.
  The read-first lane that replaces this paragraph's sequencing, the identity
  it needs and the credential design are
  `2026-08-27-store-live-and-upload-design.md`.

  It stays out of v1 for sequencing only: the images have to be right before
  pushing them anywhere is interesting, and a credential store is its own
  design. Until then §6's split menu carries **Copy CLI command**, handing back
  the `deliver`/`supply` invocation pointed at the tree we just wrote.
- **Alt text**, and it is the one deferral worth a paragraph. Play takes a real
  per-screenshot string of 140 characters or fewer, for screen-reader users —
  the only text either store accepts *as text* about a screenshot, and
  `supply` carries it in the same metadata tree §5 writes. It is out of v1
  because the images have to exist before the words about them do, and because
  it is per-locale, which is a second copy question on top of the one §2 just
  declined to answer.
  **What makes it interesting later**: every scenario step already captures the
  semantics tree — literally what a screen reader gets. Alt text is a sentence
  about what a screen reader would say, and we are sitting on the raw material
  for it while every other tool in this space starts from a blank field.
  Turning a semantics tree into a good 140-character sentence is not automatic
  and must not be silent, but a *proposed* alt text per shot, editable, is a
  better start than nothing and nobody else can offer it.
- **A/B variants.** Both stores support them; nothing here would be wrong for
  them, but a second axis before the first one has shipped is speculation.
- **Video previews.** The motion plugin records transitions and App Store
  previews are 15–30s H.264. The pieces almost line up, which is exactly why it
  should wait until the still lane is real.
- **Feature graphic** (Play's 1024×500) and **promo text**. Listing assets, but
  not screenshots, and each is its own set of questions.
- **A template gallery.** The frame is a widget, and a gallery of them is a
  package somebody else can publish.

## 12. Still open

1. ~~**Whether the stage draws Play's listing at all.**~~ **Closed: one neutral
   arrangement (2026-08-26).** See §10h. The axis that survived is placement —
   product page or search result — because that is what changes how much of a
   shot a person actually sees.
2. **7" tablet.** Left out on the grounds Play does not require it. If a
   consumer asks, §1 names the device to add.
3. **Does an export dialog replace the split menu?** Raised looking at the
   panel: the menu's entries are narrowing options in a place nobody looks for
   options, and one of them — *Recompose only*, now spelled *Rebuild frames
   without re-running the app* — is a phase of the machinery rather than
   something a person wants. The alternative is a dialog before the export
   holding listing, locale, class and shot as controls. Against it: §7's
   requirement is that **`export` takes no arguments**, and a dialog every time
   turns the declaration into something you re-answer. A workable shape is
   both — the primary button stays one click and un-narrowed, and one menu
   entry, *Export…*, opens the dialog for the narrowed case.

4. **Is a status bar drawn where there is no frame?** Today the answer falls
   out of decision 7 rather than being chosen: `_StatusBar` lives inside
   `DefaultStoreFrame`, so a composed set gets 9:41 and the indicators, and an
   unframed one — every App Store set, by default — gets nothing, because
   nothing in a `flutter_tester` draws a status bar. So one listing ships with
   a status bar and the other without. Neither store requires one and plenty of
   listings show none, so this is a consistency question, not a compliance one.
   Three answers: leave it (the frame draws chrome, and unframed means no
   chrome), draw it on unframed sets too (a compositing step where there is
   otherwise none), or make it a declaration.

5. ~~**Dark mode.**~~ **Closed, not building it (2026-08-26).** Neither store
   has a dark slot, so there is nothing to ship into and nothing to compare
   against — a dark export would be a second appearance of the same set with
   no place to go. The `Light / Dark` chip in §6 is struck out with it; it was
   this document implying a slot that does not exist, which is how the question
   got asked in the first place. `ScenarioAxes.brightness` stays available to
   the scenarios lane, where a dark run answers a question about the app rather
   than about a listing.

6. ~~**Does `store frame` survive, and with it `.captures/`?**~~ **Closed
   (2026-08-26):** it does not. See decisions 13 and 14 — the action is
   deleted, the captures are a swept scratch, and `unframed/` is what a
   composed set leaves behind.

7. **What `export` does when a scenario fails.** `_shots` today counts failures
   per set and writes what it got. For a store tree that may be the wrong
   default — a listing missing its third screenshot is worse than no listing —
   but refusing to write anything because one locale broke is worse again. Lean
   toward writing, and saying loudly which set is short.
