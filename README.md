# Flutterware

[![pub package](https://img.shields.io/pub/v/flutterware.svg)](https://pub.dev/packages/flutterware)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Every screen of your Flutter app, on every device and in every language,
without tapping through it.**

Flutterware is a desktop studio that opens on your project. It renders your
`@Preview` widgets live, turns your widget tests into a picture of every
step, builds your store listings from those pictures, and runs your app on a
device you can drive. Everything it does also runs from the terminal, and
from a coding agent over MCP.

[![The studio drawing a test of the demo coffee shop as a flow of phone
screenshots, two App Store images exported from the same tests, and the
commands that produce them](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/hero.webp)](https://flutterware.github.io/flutterware/)

## Try it

**In your browser.** [flutterware.github.io/flutterware](https://flutterware.github.io/flutterware/)
is the studio itself, compiled for the web and opened on a recording of the
demo app. Nothing to install; nothing in it can change.

**On your machine.** Clone the demo, a small coffee shop app with every tool
turned on, and start the studio:

```shell
git clone https://github.com/flutterware/flutterware_example
cd flutterware_example
dart run flutterware
```

The first launch builds the studio, so give it a minute. You need Flutter 3.47
or newer. Live previews are macOS only for now; the rest also runs on Linux and
Windows.

## What's in it

| [Previews](doc/previews.md) | [Scenarios](doc/scenarios.md) |
|:---|:---|
| ![The demo's menu rendered on an iPhone 16 frame, with the list of its screens beside it](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-previews.webp) | ![A test of the demo drawn as a flow of phone screenshots](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-scenarios.webp) |
| Your `@Preview` widgets on a device frame, in a live engine. Change the device, the language or the theme, turn knobs, read the widget tree. | Widget tests that keep a screenshot, the widget tree and the visible text of every step. The studio draws each run as a flow. |
| **[Store screenshots](doc/store_screenshots.md)** | **[Translations](doc/translations.md)** |
| ![App Store and Google Play rows of finished store images](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-store.webp) | ![The translations table, each key beside a picture of it on screen](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-translations.webp) |
| App Store and Google Play images made from your tests, for every language, at the sizes each store asks for. The frame is a widget you write. | Every key in every language, next to a picture of where it appears. Missing and overlong strings are flagged. |
| **[Run](doc/run.md)** | **[Comparison](doc/comparison.md)** |
| ![The steps an agent took through the demo on an iPhone, one of them open](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-run.webp) | ![A branch's comparison: the tests whose screens changed, one open step by step](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-comparison.webp) |
| Your app on a simulator, a phone or the desktop: its logs, network calls, widget tree and permissions, and every tap an agent made, step by step. | What a branch changed on screen. `fw compare` renders both sides from git and exports a page to link from the pull request. |
| **[Changes](doc/changes.md)** | **[Server](doc/server_inspection.md)** |
| ![A branch's files, the ones the project pins first, one open on its diff](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-changes.webp) | ![A Dart server's requests, one open on its queries, an N+1 flagged](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/card-server.webp) |
| Your branch's diff with the files that matter listed first, and notes you can leave for your agent. | The requests your Dart backend handles, the SQL each one ran, and N+1 queries flagged. |

And the rest:

| | |
|:---|:---|
| **[Dependencies](doc/dependencies.md)** | Every package, the version pub picked, and which constraint asked for it. |
| **[Assets](doc/assets.md)** | What ends up in the bundle, how much it weighs, and which densities are missing. |
| **[Lints](doc/lints.md)** | Every rule your SDK knows, and whether your `analysis_options.yaml` uses it. |
| **[Splash](doc/native_splash.md) and [icon](doc/launcher_icon.md)** | What each platform shows at launch, read from the generated files. |
| **[Dev stack](doc/dev_stack.md)** | Start and stop the services your app needs while you work. |
| **[Database watch](doc/database_watch.md)** | Your app's SQLite database, readable while the app runs. |
| **[Scenes](doc/scenes.md)** | Animations drawn with your own widgets and theme, exported to video. |
| **[Renders](doc/renders.md)** | A widget as SVG, PNG or PDF, from a script or from a server. |

Each tool has a guide in [doc/](doc/README.md).

## Scenarios are widget tests

```dart
scenario('Around the shop', (s) async {
  await s.pumpWidget(const ShopApp());
  await s.tap(ShopKeys.getStarted);
  await s.split({
    'a cold brew': () async {
      await s.tap('Cold brew');
      await s.tap(ShopKeys.addToCart);
      await s.tap(ShopKeys.placeOrder);
    },
    'the empty cart': () async {
      await s.tap(ShopKeys.openCart);
    },
  });
});
```

`flutter test` runs this like any other test. Each step waits for the screen to
settle, then keeps what it showed. `s.split` replays the body once per branch,
so one scenario covers every path through a screen, and the flow in the
picture above is exactly that. Store images, translation pictures and branch
comparisons are all built from these runs.

## Your agent gets the same tools

The first launch adds an MCP server to your project's `.mcp.json`. Through it, an
agent can render a preview to check a layout, run your scenarios and read what
each screen showed, or launch the app on a simulator and tap through it, with
every step it takes shown in the studio as it happens.

The same actions are on the command line:

```shell
alias fw='dart run flutterware'

fw run previews screenshot --entry='demo/shop.dart#shopMenu'
fw run scenarios run
fw run store export
```

Every action and option is listed in the
[capabilities reference](docs/capabilities.md).

## Add it to your project

```shell
dart pub add flutterware
dart run flutterware
```

Flutterware runs on the Dart SDK you start it with (`fvm dart run flutterware`
works too) and never installs one of its own. The first launch creates
`tool/flutterware.dart`, where you pick your tools:

```dart
import 'package:flutterware/plugins.dart';

const app = Pkg('.');

void main() => Flutterware.configure((fw) {
  fw.use(Previews(packages: [.new(app)]));
  fw.use(Scenarios(packages: [.new(app, languages: ['en', 'fr'])]));
  fw.use(Dependencies(packages: [.new(app)]));
  fw.use(Assets(packages: [.new(app)]));
});
```

It's a plain Dart file, so the analyzer checks it and your editor completes it.
For a monorepo, declare one `Pkg` per package and give each tool the ones it
applies to. The [demo's config](examples/brewline/tool/flutterware.dart) is
one app's; [this repo's](tool/flutterware.dart) covers a workspace of several
packages.

## Libraries

The package also ships libraries your app and tests can import. They work
without the studio.

| Library | What it's for |
|:---|:---|
| `flutter_test.dart` | Everything in `package:flutter_test`, plus the scenario API. Swap the import and existing tests still compile. |
| `previews.dart` | `PreviewShell` for theme or locale switches in the previews toolbar, and `context.knobs` for knobs. |
| `store.dart` | What a store frame is written with: the shot it frames, and the status bar a capture lacks. |
| `devbar.dart` | A developer overlay inside your app: logs, network, feature flags, device frames. |
| `feature_flag.dart` | Feature flags you can read and override at runtime. |
| `router_outlet.dart` | Nested routing driven by the URL. |
| `server.dart` | Hooks for the server inspector, for Dart backends. |
| `ui_catalog.dart` | A browsable web page of your previews. |
| `plugins.dart` | What `tool/flutterware.dart` is written against. |

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers
the basics and [CLAUDE.md](CLAUDE.md) explains how the repository is laid out.

Every picture of the studio in this file and in `doc/` is a named step of one
of the studio's own scenarios, run over a recording of the demo app. CI renders
them on each push to master and publishes them to the
[`media`](https://github.com/flutterware/flutterware/tree/media) branch, one
folder per version; to look at them locally:

```sh
fvm dart tool/screenshots.dart   # writes build/screenshots/media/
```
