# Scenario app axes: the switches only the app has, declared per folder

**Status.** Built. User docs: `doc/scenarios.md`, *The app's own axes*.

## The gap

A scenario suite could be run and photographed across devices, languages,
orientations and — since `shots` took `brightness` — light and dark. Every one
of those is an axis flutterware knows. An app with two brand themes, a
high-contrast mode of its own or a feature flag's variant had no way to say so:
the request from a consumer was, in five words, that there was no app-defined
axis. Previews have had one since `PreviewShell` (`2026-07-27-top-bar-axes.md`);
scenarios had none.

## What a project writes

```dart
// test/scenarios/mobile/flutter_test_config.dart
const phones = ScenarioProfile(
  'phones',
  devices: [Devices.iphone16, Devices.iphoneSe],
  axes: {
    'brand': ['coffee', 'tea'],
  },
);

// test/scenarios/mobile/shop_test.dart
scenario('Order a cappuccino', (s) async {
  await s.pumpWidget(ShopApp(theme: switch (s.axis('brand')) {
    'tea' => teaTheme,
    _ => coffeeTheme,
  }));
});
```

And on the command line, `--axes=brand=coffee,tea` on `run`, `shots`, `export`
and (one value per axis) `video`; `--dart-define=fw.axes=…` or `FW_AXES=…`
under a bare `flutter test`; `matrix=declared` picks them up with nothing said.

## The choices

**On the profile, per folder.** The same altitude as `devices`: a folder is
the unit a profile governs, `matrix=declared` already runs each folder's own
points (#423), and the panel already reads each folder's offer off the live
listing. Declaring an axis per scenario would make "which values does this
suite run in" a question nobody could answer without running it; declaring it
in `tool/flutterware.dart` would leave `flutter test` unable to see it.

**Words, not values.** A preview shell's `picker` maps labels to values at
build time, because a shell is code that runs. A profile is a `const`, so it
can only hold what a `const` can — and a `ThemeData` is not one. So the
profile names the values and the scenario maps them. It is the same split the
previews already make on the wire, where only labels cross; here the label is
also what the author writes.

**The first value is the default, and it is written down.** Portrait and light
write nothing to a directory, an address or a test name, because they are the
platform's default and every link saved before the axis existed must keep
naming the same picture. An app axis has no such default: its first value is
the order somebody listed the values in. Leaving it out would make
`iphone-16/` mean coffee today and tea after a reorder, and would leave a
reader of a shots tree to work out which brand the unlabelled directory is.
The cost is that adding an axis to a folder moves that folder's matrix and
shots directories once. A folder that declares none writes exactly what it
wrote before, which is the compatibility that matters: nobody's tree moves
without them having declared something.

**Narrowed per folder, in the harness.** Only the harness knows which folder
declares what — a profile is executed, not parsed. So the host sends the
values the request named and nothing else, and the harness, per file:

- keeps every axis the folder declares, at the named value or the folder's
  first;
- drops a named axis the folder does not declare, because nothing there reads
  it and a picture labelled with it would claim a difference never made;
- fails the file's scenarios, saying which values the folder offers, when the
  named value is not one of them — running it at the default instead is the
  silent wrong picture this whole design avoids;
- and refuses the request outright when no folder of the package declares the
  name or the value, which is what a typo looks like.

Each outcome then reports the `axes` it ran under, beside the `device` it
already reported for the same reason: the folder filled in what the request
left out, so only the outcome can say what ran. `shots` names its set
directories from it, a failure's `rerun` command repeats it, and a step's
address carries it.

**`s.axis` refuses an undeclared name.** It could answer null and let the app
fall back, and a misspelt name would then build the default app on every pass
of a matrix — a set of identical pictures that all pass. The refusal names
the axes the folder does declare.

**One grammar, in one pure-Dart file.** `name=value[,value…]`, where a part
without `=` is another value of the axis before it, and an axis named twice
gathers both — which is what a repeated `--axes` flag joined with commas comes
to. It is a superset of the preview `--axes=` grammar, so `theme=dark` means
the same in both. `lib/src/scenarios/app_axes.dart` holds the parser, the
validation, the slug order and the crossing, and both the guest (`FW_AXES`)
and the plugin (`--axes`) import it, for the reason `selector.dart` is shared:
two lanes that spell a point differently write two directories for one
picture.

**`axis.<name>` on an address.** The prefix preview capture addresses already
use for shell axes. It keeps the project's names apart from the built-in
parameters — an app may well call its axis `theme`, or `contrast` — and it
lets the panel read every app axis on the address without knowing their names
first.

**Values only in a directory name, ordered by axis name.** After the language
in a run's point (`iphone-16-fr-tea`), last in a shots set
(`iphone-16-landscape-dark-tea`), as `-landscape` and `-dark` are written. By
axis name rather than declaration order, so two folders declaring the same
axes in different orders share a directory. Bare values can collide when two
folders declare *different* axes sharing a value; `run` refuses such a matrix
before running anything rather than write one point over another.

**Values a directory can hold.** Letters, digits, `.`, `_` and `-`: a value is
a path segment in every lane and must survive a comma-separated command line.
A profile that breaks this is refused when the harness probes it, and by
`scenarioAssignments` under `flutter test`.

**Explicit lists are an override; `matrix=declared` stands alone.** `--axes`
crosses every file at every point, as `--devices` does, and a folder that does
not declare the axis runs once per point unaffected. `matrix=declared` refuses
`--axes` beside it, as it refuses the other lists.

## Not done, and why

- **Typed values.** A `ScenarioAxis<T>` carrying values would need a
  non-`const` profile or a registry keyed by name, and gains nothing a
  `switch` in a shared helper does not already give.
- **A segmented picker.** The panel draws each axis as the same chip and menu
  as Device, Language and Brightness. A style is additive if a two-value axis
  turns out to be flipped often enough to want one.
- **Per-folder memory of a picked value.** The panel remembers a device per
  folder, because a phone on a desktop folder is wrong. An app axis is only
  sent to folders that declare it, and two folders declaring `brand` almost
  certainly mean the same brand, so a pick follows you like a language does.
- **The web export dialog** offers no app-axis control, as it offers no device
  or language one; the action takes `axes`.
- **Store screenshots** run at each folder's default and do not cross app
  axes. A listing per brand is a different store app, which is a declaration
  of its own rather than an axis of this one.
