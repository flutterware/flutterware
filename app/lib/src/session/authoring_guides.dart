/// What a project *writes*, per plugin — the half of this tool that is Dart in
/// the consuming repository rather than an action to invoke.
///
/// Why this is hand-written when everything around it is generated: the
/// action shapes come out of the analyzer because they describe types this
/// build declares. These describe types a *project* declares, and rules the
/// scanner applies to a project's source: which annotation arguments are read
/// statically, what makes a function eligible, what a canvas prefix matches.
/// No extraction reaches that, and the alternative to writing it down is what
/// happened instead — a consumer read `discovery.dart`, `canvases.dart`,
/// `staging.dart`, `first_party.dart`, two specs and several commit messages,
/// and still guessed two rules wrong.
///
/// Kept beside the renderer and emitted into `docs/capabilities.md` so there is
/// one document to read rather than a second one to find, and so the
/// capabilities test fails when a plugin here no longer exists.
library;

/// Keyed by plugin id. A plugin with nothing to author has no entry.
const authoringGuides = {'flutterware.previews': _previews};

const _previews = r'''
#### Authoring: what you write

A preview is an ordinary function returning a `Widget`, annotated with
**Flutter's own** `@Preview` from `package:flutter/widget_previews.dart`.
Nothing of flutterware's is imported to declare one, and there is no map to
register it in — every `.dart` file in the package is scanned, wherever it
sits. `directory:` narrows that; see the config below.

```dart
// demo/buttons.dart
import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';

@Preview(name: 'Buttons')
Widget buttons() => const Column(children: [Text('Elevated')]);
```

`fw run previews new --name='Buttons'` writes that file for you.

**What the target may be.** A top-level function, a static method, or a
constructor — anything callable with no arguments. A *required* parameter makes
it ineligible, and the scan says so as a diagnostic rather than dropping it
silently. Optional parameters are knobs (below).

**Which annotation arguments the tool reads.** `name`, `group` and `id`, and
only when they are plain string literals — those three are what the scan needs
to build an id and a tree without running anything. Every other argument
(`size`, `wrapper`, `brightness`, …) is passed through untouched and evaluated
as Dart by the guest when the preview renders, which is why `size: kCardSize`
costs the scan nothing and why an `id: someConstant` is not seen.

**Variants.** Two `@Preview`s on one declaration are two entries, told apart by
their position. A file holding more than one entry derives a group from its own
file name (`avatar_tile.dart` → `Avatar tile`); `group:` overrides it.
`MultiPreview` is refused by name: it yields its previews from a run-time
getter, and every entry here is resolved from the source.

**Your own annotation.** Subclass `Preview` and register the subclass with
`previewAnnotations:` below. Arguments are read by name, so an `id:` on your
subclass is still an `id:`.

#### Authoring: knobs

A knob is whatever the preview asks for while it builds. No registration, and
the panel, the CLI and an agent all set the same one.

```dart
import 'package:flutterware/previews.dart'; // for context.knobs

@Preview(name: 'Buttons')
Widget buttons() => Builder(
      builder: (context) {
        var label = context.knobs.string('label', 'A button');
        return FilledButton(onPressed: () {}, child: Text(label));
      },
    );
```

`context.knobs` reads a `BuildContext`, so it goes **inside a widget's build** —
a preview cannot take `BuildContext` as a parameter, because a required
parameter makes it ineligible. A preview's own *optional* parameters are knobs
too: `Widget buttons({String label = 'A button'})` declares the same knob from
the signature.

Unhosted — in the real app, in a test, in Flutter's own previewer — every knob
answers with the default written at the call site, which is what makes one safe
to write in a widget that ships.

#### Authoring: the shell

`wrapper:` names a `Widget Function(Widget)` that puts back what a preview does
not have: `MaterialApp`, theme, localizations, directionality. Wrap it in a
`PreviewShell` and its axes become switches in the catalog's top bar, applying
to every preview and staying put as you move between them.

```dart
// demo/shell.dart
Widget wrapInApp(Widget child) => PreviewShell(
      'app',
      builder: (context, axes) => MaterialApp(
        theme: ThemeData(
          brightness: axes.flag('dark', false) ? Brightness.dark : Brightness.light,
        ),
        home: child,
      ),
    );

@Preview(name: 'Buttons', wrapper: wrapInApp)
Widget buttons() => /* … */;
```

#### Authoring: canvases, and the device a preview is framed as

Without a device a preview renders at 900 × 700 — landscape and desktop-shaped,
where a phone layout does not overflow and does not wrap. A `PreviewCanvas` says
*this subtree renders like this*, which is the fact a package holding two form
factors cannot otherwise express.

```dart
// demo/canvases.dart — no Flutter import, so tool/flutterware.dart can read it
const canvases = [
  PreviewCanvas('demo/mobile', devices: [Devices.iphone16, Devices.iphoneSe]),
  PreviewCanvas('demo/desktop', devices: [Devices.wideWindow]),
];
```

The list belongs to the **project**, not to the tool: keep it in your own
package and hand the same value to `tool/flutterware.dart` and to your tests.

- The prefix is package-relative, in the same coordinates entries are reported
  under. The empty string covers the whole package.
- Matched on **segment boundaries**: `demo/mobile` covers `demo/mobile/tile.dart`
  and pointedly not `demo/mobile_legacy/tile.dart`. A prefix naming a *file* is
  supported for the same reason — the last segment is a file — and is how one
  preview in a directory differs from its neighbours.
- Longest prefix wins. Two canvases with the same prefix are refused: that is
  one rule written twice, and either resolution drops something somebody wrote.
- The device list is the offered set and **its head is the default**. Empty is a
  complete declaration meaning the plain rectangle, which is how a subtree opts
  out of a canvas its parent declared. `orientations:` is crossed with it.

#### Authoring: the config

```dart
// tool/flutterware.dart
const app = Pkg('.');

void main() => Flutterware.configure((fw) {
      fw.use(Previews(packages: [
        PreviewsPackage(
          app,
          directory: 'demo',              // narrows the scan; default is the whole package
          previewAnnotations: ['Preview', 'Tablet'],  // your own subclass, listed with the default
          device: Devices.iphone16,       // a canvas with no prefix
          canvases: canvases,             // or per subtree
        ),
      ]));
    });
```

One declaration per package: a package's path is its identity in the report, in
`fw:///` addresses and in the compiler daemon's address, so a second declaration
of one package is refused rather than merged.

#### Authoring: rendering the whole catalog

Annotations cannot be enumerated at run time — nothing in a running Dart program
can find them, or reach a function it does not name — so anything that wants
*every* preview at once needs the list written as code. You do not write it:
`fw run previews audit` generates a harness under `build/flutterware/`, one
wrapper per entry plus a table, and renders the lot as widget tests.

```sh
fw run previews audit                 # every entry, on its canvas, with real fonts
flutter test build/flutterware/previews_harness.dart   # the same file, as an ordinary suite
```

The second lane is convenient and shardable and inherits `flutter test`'s
`--use-test-fonts`, which boxes every family nobody loads bytes for. The harness
loads them: the project's own from the manifest, and real Roboto under the
platform-default names that text with no explicit family resolves to. So an
overflow verdict from it means something — but Roboto stands in for the Apple
and Windows defaults too, so a pixel-exact question still belongs to `audit`,
which spawns its own tester and omits those flags.

**Expect the first run to find things.** A preview is a widget and not an app:
an entry that only ever worked because something above it supplied a
`Directionality` or a `MediaQuery` fails here and nowhere else. A catalog
migrating from a hand-written map — where the map's own test wrapped every entry
in scaffolding the previews do not have — should expect a few.

For a suite you write yourself, `PreviewEntry` and `runPreviewHarness` are
exported from `package:flutterware/flutter_test.dart`, and `tester.applyCanvas`
stages one entry on its canvas: `PreviewEntry.path` and `PreviewCanvas.prefix`
are in the same coordinates, so `canvasFor(canvases, entry.path)` means the same
thing in a test as in the panel.

The harness is written under `build/`, which is not committed — a fresh clone
has to run `audit` once before that `flutter test` path exists.
''';
