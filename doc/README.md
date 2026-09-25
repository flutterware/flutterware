# Flutterware docs

One page per tool: what it's for, how to turn it on in `tool/flutterware.dart`,
and how to use it from the studio, the command line and a coding agent.

Every action and every option is also listed in the
[capabilities reference](../docs/capabilities.md), which is generated from the
code. The guides link into it rather than repeat it.

## Screens and tests

| Tool | What it does |
|:---|:---|
| [Previews](previews.md) | Your `@Preview` widgets on device frames, live, with knobs and an inspector. |
| [Scenarios](scenarios.md) | Widget tests that take a screenshot at every step, on every device and language. |
| [Store screenshots](store_screenshots.md) | App Store and Google Play images made from your scenarios, framed by a widget you write. |
| [Translations](translations.md) | Every key in every language, with a picture of where each string appears. |
| [Comparison](comparison.md) | What a branch changed on screen, against its base, as a page for the pull request. |

## The running app

| Tool | What it does |
|:---|:---|
| [Run](run.md) | Launch the app on any device, inspect it, and drive it from the studio, the command line or an agent. |
| [Server inspection](server_inspection.md) | Requests to your Dart server, the SQL each one ran, and N+1 warnings. |
| [Database watch](database_watch.md) | Your app's SQLite database, readable while the app runs. |
| [Dev stack](dev_stack.md) | Start, stop and watch the local services your app needs. |
| [Worlds](worlds.md) | Several people on your real server, each with their own app, set up by a script. Experimental, macOS only. |

## The project

| Tool | What it does |
|:---|:---|
| [Changes](changes.md) | What your branch changed, the files that matter first, and notes for your agent. |
| [Dependencies](dependencies.md) | Every package, the version pub resolved, and where it came from. |
| [Assets](assets.md) | What ends up in the bundle, how much it weighs, and what's missing. |
| [Lints](lints.md) | Which lint rules you use, which you turned off, and which you never considered. |
| [Native splash](native_splash.md) | What each platform shows at launch, from your `flutter_native_splash` config. |
| [Launcher icon](launcher_icon.md) | Every app icon, as each platform will show it, and what's wrong with them. |

## Drawing

| Tool | What it does |
|:---|:---|
| [Scenes](scenes.md) | Animated designs made with your own widgets, played in the app or exported to video. |
| [Renders](renders.md) | A widget as an SVG, PNG or PDF, from a script or from a server. |

## The same tools, three ways

Everything in these guides works from three places, and they run the same
code:

- **The studio**: `dart run flutterware` with no command opens the desktop app.
- **The command line**: `dart run flutterware run <tool> <action>`. Most people
  alias it: `alias fw='dart run flutterware'`. `fw actions` lists everything
  that can be run.
- **MCP**: the first launch registers flutterware in your project's
  `.mcp.json`. An agent lists actions with `flutterware_actions`, runs them
  with `flutterware_invoke`, and drives a running app with `flutterware_act`.
