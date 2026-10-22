## 0.7.0

- Rendering moved to a separate package, `flutterware_render`, added from git.
  See [Renders](doc/renders.md).
- flutterware no longer depends on `pdf`.

## 0.6.0

A fresh start: flutterware is now a desktop studio for your Flutter project,
with a command line and an MCP server over the same tools.

- Previews, scenarios, store screenshots, translations, run, comparison and
  more. The [README](README.md) shows them all; each has a guide in
  [doc/](doc/README.md).
- `dart run flutterware` opens the studio and creates `tool/flutterware.dart`,
  where you pick your tools.
- Needs Flutter 3.47.
