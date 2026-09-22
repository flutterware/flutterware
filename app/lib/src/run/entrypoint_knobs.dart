import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import '../utils/enum_lookup.dart';
import '../utils/parameter_knobs.dart';
import 'run_files.dart';
import 'wrapper_import.dart';

/// What an entry point's `main` declares it can be launched with.
class EntrypointKnobs {
  const EntrypointKnobs({
    this.knobs = const [],
    this.imports = const [],
    this.undrawable = const [],
    this.required = const [],
  });

  /// One per optional parameter, in signature order — which is the order the
  /// form renders, and the order the signature was written in.
  final List<ParameterKnob> knobs;

  /// The entry point's own imports, as the generated wrapper must write them —
  /// spelled from the wrapper's directory, prefixes kept.
  ///
  /// Here rather than in the generator because both come from the same parse,
  /// and because a wrapper that names a value must import whatever declares it
  /// — `2026-08-12-run-knobs-design.md` § K4.
  final List<String> imports;

  /// Parameters `main` takes that no control can be drawn for, each with the
  /// sentence saying why — a verb phrase whose subject is the parameter, so a
  /// surface can put it after the name it is already showing.
  ///
  /// Keyed by name, because the name is what a surface has. This was a list
  /// of prose that nothing read, so the accurate reason was computed and thrown
  /// away twice over: a control went missing with nothing to explain it, and a
  /// knob declared for one of these was reported as a parameter `main` does not
  /// take — which sent people to the signature to hunt for a typo that was not
  /// there. Both are [RunKnobEntry] lines now, joined on [ParameterKnob.name].
  final List<({String name, String reason})> undrawable;

  /// Named parameters `main` declares `required`, which make it unlaunchable.
  ///
  /// Not knobs, and not skippable either. A knob is optional by definition:
  /// the wrapper writes the ones that were set and leaves the rest to their
  /// defaults, and a parameter with no default has none to leave it to. Nothing
  /// here can invent a value, so the launch is refused by name.
  ///
  /// Carried rather than merely counted because the refusal has to say *which*
  /// one. Before this the parameter was skipped silently and the wrapper took
  /// its no-knobs branch, whose `entry.main as FutureOr<void> Function()` cast
  /// cannot hold a function with a required parameter — so the app died at
  /// startup on a cast error with nothing pointing at the signature.
  final List<String> required;
}

/// Reads [entrypoint]'s `main` — names, types, defaults, and the imports a
/// wrapper calling it will need.
///
/// Parsed, never resolved. The same posture as the catalog scanner, and for
/// the measured reason: resolving one unit of a real project costs 17.3s
/// against 478ms to parse the whole package (`CatalogScanner`), and 5.5s on an
/// entry point that imports Flutter (`2026-08-12-run-knobs-design.md` § E4).
///
/// Per entry point rather than per package, which is the whole point: a
/// signature cannot be wrong about what its own `main` accepts, so nothing here
/// has to guess which knobs belong to which `main`. The define scan it replaces
/// could only answer per package, and put four constants belonging to
/// `main_catalog_dev.dart` on `main_dev.dart`'s launch form.
EntrypointKnobs scanEntrypointKnobs({
  required String packageRoot,
  required String entrypoint,
  RunFiles files = const DiskRunFiles(),
}) {
  var file = p.join(packageRoot, entrypoint);
  CompilationUnit unit;
  try {
    unit = parseString(
      content: files.readString(file)!,
      throwIfDiagnostics: false,
    ).unit;
  } on Object {
    // Absent or unparseable: the build will say so, in better words than a scan
    // can, and an entry point with no readable signature simply offers nothing.
    return const EntrypointKnobs();
  }

  FunctionDeclaration? main;
  for (var declaration in unit.declarations.whereType<FunctionDeclaration>()) {
    if (declaration.name.lexeme == 'main') main = declaration;
  }
  if (main == null) return const EntrypointKnobs();

  var undrawable = <({String name, String reason})>[];
  var knobs = knobsFromParameters(
    main.functionExpression.parameters,
    file: file,
    lookup: EnumLookup(
      selfPackage: _packageNameOf(packageRoot, files: files),
      selfPackageRoot: packageRoot,
    ),
    onSkipped: (parameter, reason) =>
        undrawable.add((name: parameter, reason: reason)),
  );

  return EntrypointKnobs(
    knobs: knobs,
    imports: _importsOf(unit, packageRoot: packageRoot, entrypoint: entrypoint),
    undrawable: undrawable,
    required: [
      for (var parameter
          in main.functionExpression.parameters?.parameters ??
              const <FormalParameter>[])
        if (parameter.isRequired)
          if (parameter.name?.lexeme case var name? when name.isNotEmpty) name,
    ],
  );
}

/// [unit]'s imports, rewritten so they mean the same thing from the wrapper.
///
/// A relative import is relative to the file holding it, and the wrapper does
/// not sit beside that file — it sits in `.dart_tool/flutterware/run/`, where
/// `import 'src/config.dart'` resolves against the wrong directory and fails to
/// compile. Measured, and it is the real layout rather than a hypothetical.
///
/// So each one is resolved against the entry point's own directory and then
/// re-spelled from the wrapper's by [wrapperImportOf] — the same function that
/// spells the import of the entry point itself, because a wrapper whose two
/// halves disagreed about how to name a file in `demo/` would compile one and
/// fail the other. `dart:` and `package:` imports are already absolute and pass
/// through untouched.
///
/// What [wrapperImportOf] declines — a file in another package, reached
/// relatively — is dropped rather than guessed at: the wrapper only fails to
/// compile if a knob's type needed it, and then the error names the type.
List<String> _importsOf(
  CompilationUnit unit, {
  required String packageRoot,
  required String entrypoint,
}) {
  var package = _packageNameOf(packageRoot);
  var directory = p.posix.dirname(entrypoint);
  var imports = <String>[];
  for (var directive in unit.directives.whereType<ImportDirective>()) {
    var uri = directive.uri.stringValue;
    if (uri == null) continue;
    String? resolved;
    if (uri.startsWith('dart:') || uri.startsWith('package:')) {
      resolved = uri;
    } else {
      resolved = wrapperImportOf(
        p.posix.normalize(p.posix.join(directory, uri)),
        package: package,
      );
    }
    if (resolved == null) continue;
    var prefix = directive.prefix?.name;
    imports.add("import '$resolved'${prefix == null ? '' : ' as $prefix'};");
  }
  return imports;
}

String? _packageNameOf(
  String packageRoot, {
  RunFiles files = const DiskRunFiles(),
}) {
  try {
    return Pubspec.parse(files.readString(p.join(packageRoot, 'pubspec.yaml'))!)
        .name;
  } on Object {
    return null;
  }
}
