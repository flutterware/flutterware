# Top-bar axes: app-wide switches a project declares in its shell

**Status.** Built. The signature-based design this document originally
described was replaced on 2026-07-28 before it shipped; see "What changed, and
why" at the end for what was tried and what it cost.

## What a project writes

```dart
// demo/shell.dart
enum Flavor { dev, staging, prod }

Widget wrapInApp(Widget child) => CatalogShell(
  'app',
  builder: (context, topBar) => MyApp(
    flavor: topBar.picker('flavor', {
      'Dev': Flavor.dev,
      'Staging': Flavor.staging,
      'Production': Flavor.prod,
    }, Flavor.dev),
    locale: topBar.picker('locale', {
      'English': const Locale('en'),
      'Français': const Locale('fr'),
    }, const Locale('en')),
    home: child,
  ),
);
```

And nothing else. `@Demo(wrapper: wrapInApp)` is unchanged and every demo keeps
naming it.

Nothing marks the shell and nothing looks for it. `wrapInApp` is an ordinary
`Widget Function(Widget)` that happens to build a `CatalogShell`, so:

- **Flutter's own previewer is unaffected.** It calls the wrapper through
  `WidgetWrapper`, gets the shell as written, and every axis answers with its
  default.
- **The real app is unaffected**, for the same reason.
- **The catalog** drives the axes by pushing selections into `CatalogAxes`,
  which the next build of the shell reads.

## Scope is the design

`topBar` is handed to the builder rather than read off a `BuildContext`, and
that is the whole reason axes stay tractable.

An axis outlives the entry on screen — it belongs to the shell. If any widget
could declare one, then a demo could file a control under the shell and have it
persist after that demo was gone, and a subtree built lazily (below a list,
behind a tab) would make the top bar grow as you navigated. Knobs can afford to
be read from anywhere precisely because they reset with the entry.

So the confinement is not stylistic. It is what makes "an axis belongs to a
shell" true rather than aspirational.

## Several shells

A project has as many as it needs, and the top bar shows the axes of whichever
shell the entry on screen built. Switching to an entry with a different wrapper
changes the top bar with it.

- A shell is identified by the id it gives itself — `'app'`. A name, not a
  path, so moving or renaming the file does not lose what was set.
- Selections are held **per shell**, on both sides of the wire, so two shells
  that both call something `flavor` cannot inherit each other's.

## Who owns what

The **selection** is the host's. It is UI state, it outlives the entry you are
looking at and the guest itself, and only the host knows what you clicked.

The **set of axes, and their options**, is reported by the guest — it is
whatever the last build of the shell asked for.

What still separates an axis from a knob:

- An axis belongs to a **shell**, so the selection persists across entry
  switches instead of resetting with them.
- An axis is above the entry in the tree, so changing one rebuilds the shell
  rather than the demo alone.
- An axis can only be declared from one place, which is what the section above
  is about.

## Options are values, and only labels cross the wire

`picker<T>(String name, Map<String, T> options, T defaultValue)` takes the
options explicitly, so:

- **`T` is unconstrained.** Enums, `Locale`s, `ThemeData`s, records — anything.
  The earlier design needed the type to be one the tool could enumerate, which
  is where the "axes must be an enum or a bool" rule and its whole family of
  diagnostics came from. All of that is gone.
- **Labels are written, not derived.** `'Production'`, not `prod`.
- It matches `KnobDescriptor` exactly, whose doc already said "only the labels
  cross the wire — the values behind them are whatever the demo said they are,
  and only the demo can turn a label back into one."

`flag(String name, bool defaultValue)` is the toggle. A `bool` is a closed set
of two, which is all an axis needs to be.

Not carried yet, deliberately: `swatch` and `icon`. Both are presentation, both
would need new fields on `KnobDescriptor`, and adding them is additive when it
is wanted.

`PickerStyle` was wanted first, and is carried: `picker(…, style:
PickerStyle.segmented)` on an axis and on a knob alike, as `style` on the
descriptor. A catalog that switched between light and dark with a two-option
segmented control had nothing to write once the old top bar went, and a switch
flipped back and forth while looking is exactly what a menu makes two clicks.
The descriptor writes `style` only when it is not `dropdown`, so a guest that
predates it and a picker that never asked read the same, and a host reads a
style it does not know as `dropdown`. Past five options a segmented picker is
drawn as a dropdown anyway — the bar is one row, and the renderer decides that
through one function, `drawsSegments`, so the studio and a catalog page cannot
disagree.

### What runtime declaration costs

Nothing can list a project's axes without booting a guest. Every operation that
would use the answer boots one anyway — `fw screenshot tile --flavor=Production`
has to render — so it costs those nothing. What it does cost:

- a mistyped `--flavor=Prod` cannot be rejected until a guest is up
- a shell's axes appear only once an entry using it has rendered

Both are what knobs already do.

## Wire

`ext.flutterware.axes` reports `{entry, shell, axes}`. Read after a switch and
retried while the report names another **entry** — the same rule and the same
reason as the knob report: a read landing between the reload and the frame
describes what was there before. Matching on the entry rather than the shell is
what lets an entry whose wrapper is *not* a shell settle: it reports no shell
and no axes, and that is an answer rather than something to keep waiting for.

`ext.flutterware.setAxes` takes `{shellId: {axis: value}}` — **every** shell the
host knows about, not just the one on screen. The host cannot know which shell
an entry uses until that entry has built, so sending the lot means the values
are already in hand when a shell builds for the first time, instead of a frame
of defaults followed by a correction.

## What changed, and why

The original design put the axes in the shell's **signature**, marked with a
`@CatalogShell` annotation:

```dart
@CatalogShell()
Widget wrapInApp(Widget child, {Flavor flavor = Flavor.dev}) => …;
```

It worked, and it had one real advantage this design gives up: the axes were
legible to a scan, so the top bar could in principle be drawn before the first
compile. It was dropped anyway, because making it *correct* required knowing
things a syntactic scan cannot know:

- which function `wrapper: wrapInApp` refers to (matched by bare symbol name,
  so two files declaring `wrapInApp` were an ambiguity the scan had to refuse)
- whether an axis's type was an enum, and what its values were called
- what an axis's default expression evaluated to

Resolution answers all three. It was measured — see
`2026-07-28-resolved-discovery-findings.md` — and rejected on cost: ~19s cold
per project and 164MB of cache per worktree, against a tool whose promise is
that opening a worktree gets you a running demo quickly.

Declaring the axes at runtime removes the questions instead of answering them.
What went with it:

| deleted | why it existed |
|---|---|
| `@CatalogShell` | to mark a shell for discovery |
| `ShellDescriptor`, `ShellAxis` | to carry a signature's axes to the generator |
| `_addShell`, `_linkShells`, `_notEnumerable` | to read and validate those signatures |
| `CatalogEntry.wrapper`, `.shellId` | to point an entry at its shell |
| `_shellBinding`, `_pickCall`, `_flagCall` | to call the shell by name |
| `shells` on `DaemonReady` / `CatalogChanged` | to ship them to clients |
| the demo+shell import union in `_carriedImports` | so `Flavor.values` resolved in generated code |

The last one mattered beyond its size: merging two files' import sets was the
only place two prefixes could collide, and it is gone rather than fixed.
