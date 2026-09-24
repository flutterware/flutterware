# Assets

What your app's asset bundle contains once it's built: every file your
pubspec declares, what your dependencies add, how much each weighs, and which
screen densities exist for each image.

## Turn it on

```dart
// tool/flutterware.dart
fw.use(Assets(packages: [.new(app)]));
```

`AssetsPackage.each([...])` declares several packages at once.

## In the studio

The tree lists your own assets first, then what each dependency adds
(`package:…`), with sizes at every level. Pick a folder for a grid of its
files, or a file to see its densities, what the file itself says (an image's
pixel size, for instance) and the Dart code that loads it.

The list is what the bundle resolves to, not what's on disk: a file nothing
declares isn't in it, and a declaration that matches nothing is reported.

## Audit

```shell
fw run assets audit
```

Checks the bundle without running the app and reports:

- declarations that resolve to nothing,
- files a directory declaration doesn't reach (subfolders aren't included by
  Flutter unless declared),
- images larger than anything that draws them,
- the total weight of the bundle.

## From the command line or an agent

```shell
fw run assets list
fw run assets list --dependencies=true
fw run assets describe --asset=assets/images/logo.png
```

## Reference

[`flutterware.assets` in the capabilities reference](../docs/capabilities.md#flutterwareassets).
