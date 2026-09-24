# Dependencies

Every pub dependency of your packages in one table: what your pubspec asked
for, what pub resolved it to, and where it came from.

![The dependencies panel: each package with its type, its origin, the
constraint that asked for it and the version pub resolved](https://raw.githubusercontent.com/flutterware/flutterware/media/v0.6.0/dependencies.webp)

## Turn it on

```dart
// tool/flutterware.dart
fw.use(Dependencies(packages: [.new(app)]));
```

In a monorepo, `Dependencies(packages: DependenciesPackage.each([app, core, api]))`
declares every package at once.

## In the studio

One row per dependency, with:

- **Type**: direct, dev, or transitive (pulled in by something else). Direct
  and dev are shown by default; tick **Transitive** to see the rest.
- **Origin**: pub.dev, another package server, git (with its repository and
  ref), a local path, or the Flutter SDK.
- **Constraint**: what the depending pubspec wrote, like `^1.2.0`.
- **Resolved**: the version on disk, from `pubspec.lock`.

Search by name, and sort by package, type, origin or version.

## From the command line or an agent

```shell
fw run dependencies list
fw run dependencies list --transitive=true
```

The counts of direct, dev and transitive packages are always reported, even
when only some are listed.

## Reference

[`flutterware.dependencies` in the capabilities reference](../docs/capabilities.md#flutterwaredependencies).
