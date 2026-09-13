## Unreleased

- **A project's own shaders load, and scene text can be painted with one.**
  The shaders a pubspec declares under `flutter: shaders:` were never in the
  bundle flutterware renders from, so `FragmentProgram.fromAsset` failed with
  *"Asset not found"* in every lane — previews, scenarios, scene video, the
  studio's canvases. They are compiled and bundled now, and a `.frag` saved
  while a preview or a scene is open is reloaded in place.

  A scene text layer takes `ShaderPaint('shaders/foil.frag', uniforms: …)`:
  the pass is painted by the shader through the glyphs, over the whole text
  or once per line, with `uSize`, `uColor` and `uTime` set by the renderer
  when the shader declares them. A pass paints nothing until its program has
  loaded. The lanes wait for that themselves; a plain widget test does not,
  so it loads them first with
  `await tester.runAsync(() => precacheSceneShaders(scene));`.

- **A comparison's tree changes lead with the one that started it.** A layout
  change reports every widget it carried along, and the list used to open on
  the containers and the neighbours squeezed to make room — root first, the
  order the walk met them — so a report capped at fifty lines could leave out
  the widget that actually grew. Within a finding, the changes now read from
  the cause outwards: what a widget is, then a size change under unchanged
  constraints (deepest first), then an offset, then a size its parent forced,
  then constraints. The same lines, in `fw compare`, MCP and `index.json`.

- **A compared preview carries its name.** `index.json` rows for previews now
  have the `label` their `@Preview(name:)` declares, as scenario steps already
  did, and the comparison page titles rows by it — `Order placed` rather than
  `shopConfirmation`. A flow's row says which of its steps changed, and a
  step's page names its flow and walks to the steps either side.

- **An exported page opens in about a second, and says what it is.** The
  comparison and scenario pages registered Flutter's retiring service worker
  and waited on it, falling back to a plain script after four seconds, blank
  all the while. They load without one now, show a loading line until the
  first frame, carry a description that fits them rather than the web demo's,
  and name the tab after the verdict — `7 changed — fe642dc against
  origin/master`. Semantics are on, so a screen reader can read them.

## 0.6.0

Development tooling for Flutter projects: a desktop app, a command line and an
MCP server over one set of tools you declare once.

```sh
dart pub add flutterware
dart run flutterware
```

That opens the studio. It also scaffolds `tool/flutterware.dart` and registers
the MCP server in `.mcp.json`. Declare the tools you want in that file and each
one becomes a panel, an `fw` command and an MCP action — the three surfaces run
the same code, so an agent can do what you can do from the window.

- **Previews** — your `@Preview` widgets on real device frames, live, with
  knobs, screenshots and inspection. macOS only for now; everything else runs
  everywhere.
- **Scenarios** — a `flutter_test` that screenshots itself, and draws its flow.
- **Run** — launch an entry point on any device, then drive and inspect it: by
  hand, from `fw`, or from an agent.
- **Store screenshots** — the images a store listing is uploaded from, taken
  from scenarios, per locale and display class.
- **Comparison** — `fw compare` reports what this branch did to the pictures,
  against its base.
- **Scenes** — a scene and its motion in one file, rendered by your app and
  exportable to video.
- Also: dependencies, assets, translations, lints, renders, native splash,
  launcher icon, server inspection, a dev stack and a changes view.

Every capability of every surface: [docs/capabilities.md](docs/capabilities.md).
Needs Flutter 3.47.

## 0.5.1

- Upgrade dependencies

## 0.5.0

- Add Figma integration to `ui_catalog`

## 0.4.2

- Move the devbar button slightly

## 0.4.1

- Increase test_api constraint

## 0.4.0

- Improve `package:flutterware/devbar.dart`

## 0.3.0

- Rename `widget_book` to `ui_book`

## 0.2.1

- Add search field to up-coming `storybook` feature

## 0.2.0

- Support Flutter 3.13

## 0.1.2

- Internal maintenance to improve pub's score.

## 0.1.1

- Allow to start the app from pub cache.

## 0.1.0

- Test runner with screenshots & hot-reload
- Pub dependencies manager
- Launcher icon manager
