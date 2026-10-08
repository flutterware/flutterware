# Lints

Which lint rules your project uses, which it has turned off, and which it has
never considered. Lints reads every `analysis_options.yaml` in your repository
against the full list of rules your Dart SDK offers.

## Turn it on

```dart
// tool/flutterware.dart
fw.use(Lints());
```

There's nothing to configure: every `analysis_options.yaml` in the repository
is read.

## In the studio

One table with every rule your SDK knows, each sorted into one of four
groups:

- enabled in one of your files,
- dismissed: explicitly switched off,
- mentioned only in a comment, which usually means someone thought about it,
- never evaluated: not mentioned anywhere. This is the interesting group.

Names your files use that the SDK doesn't know (typos, or rules that were
removed) are listed separately.

The list of rules is downloaded once for your SDK's version. Offline on the
first run, the table still shows your own files, but can't tell you what's
missing.

## How many issues would a rule find?

```shell
fw run lints count
```

Runs `dart analyze` once with every unused rule turned on and reports how many
issues each would flag in your code today, with up to three examples each. It
takes a full analysis of the repository, so seconds to minutes.

```shell
fw run lints status   # the table, as JSON
```

## Reference

[`flutterware.lints` in the capabilities reference](../docs/capabilities.md#flutterwarelints).
